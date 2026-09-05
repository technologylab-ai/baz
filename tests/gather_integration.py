#!/usr/bin/env python3
"""Finite gather-send wire, operation-count, partial-progress and cancellation gates.

The send_chunk cases force submitted aggregate boundaries, not kernel short
completions. Zig unit tests separately inject positive short completion counts.
Slow-reader counters distinguish a requested send cancellation from a canceled
terminal result; shutdown may win the race with another terminal socket error.
"""

import argparse
import json
from pathlib import Path
import signal
import socket
import sys
import time
import traceback

import integration as wire


def run(binary, emit, sessions):
    for mode, workers in (("inline", 0), ("workers", 2)):
        for gathered in (0, 1):
            with wire.Server(binary, execution=mode, workers=workers,
                             response_batch_limit=1, gather_send=gathered, send_chunk=65536,
                             borrow_copy_threshold=0) as server:
                wire.plaintext(server)
            expected = 1 if gathered else 2
            wire.require(server.stats["completed"] == 1 and
                         server.stats["send_completions"] == expected,
                         "single plaintext response did not use expected terminal operation count")
            wire.require(server.stats["short_send_completions"] == 0,
                         "operation-count fixture saw a kernel short completion; cannot claim 2-to-1 witness")
            wire.require(server.stats["gather_send_operations"] == (1 if gathered else 0) and
                         server.stats["scalar_send_operations"] == (0 if gathered else 2),
                         "gather/scalar mode did not select its requested path")
            wire.require(server.stats["max_send_parts"] == (2 if gathered else 1),
                         "plaintext header and body did not share a two-vector submission")
            sessions.append(dict(phase="operation_count", execution=mode,
                                 gather_send=gathered, stats=server.stats))
            emit("%s_plaintext_%s_operation_count" % (mode, "gather" if gathered else "scalar"))

    with wire.Server(binary, execution="inline", workers=0, response_batch_limit=1, gather_send=1,
                     send_chunk=65536) as server:
        with server.connect() as sock:
            sock.sendall(wire.REQUEST)
            response = b""
            while b"\r\n\r\n" not in response:
                chunk = sock.recv(4096)
                wire.require(chunk, "EOF in header boundary fixture")
                response += chunk
                wire.require(0 < len(response) <= 4096, "bounded header fixture")
            header_bytes = response.index(b"\r\n\r\n") + 4
            while len(response) < header_bytes + len(wire.PLAINTEXT):
                chunk = sock.recv(4096)
                wire.require(chunk, "EOF in body boundary fixture")
                response += chunk
            wire.require(response[header_bytes:] == wire.PLAINTEXT, "header boundary fixture body")
    for cap in (1, 7, header_bytes - 1, header_bytes, header_bytes + 1, 65536):
        with wire.Server(binary, execution="inline", workers=0, response_batch_limit=1, gather_send=1, borrow_copy_threshold=0,
                         send_chunk=cap) as server:
            with server.connect() as sock:
                reader = wire.ResponseReader(sock)
                sock.sendall(wire.REQUEST * 16)
                for _ in range(16):
                    status, _, body = reader.response()
                    wire.require(status == 200 and body == wire.PLAINTEXT, "gather pipeline mismatch")
                sock.sendall(b"HEAD /plaintext HTTP/1.1\r\nHost: localhost\r\n\r\n" + wire.REQUEST)
                wire.require(reader.response(head=True)[2] == b"", "HEAD emitted payload")
                wire.require(reader.response()[2] == wire.PLAINTEXT, "HEAD consumed next response")
                sock.sendall(b"GET /chunks HTTP/1.1\r\nHost: localhost\r\n\r\n" + wire.REQUEST)
                wire.require(reader.response()[2] == b"first second third", "chunk framing/resume mismatch")
                wire.require(reader.response()[2] == wire.PLAINTEXT, "chunk finish consumed next response")
                payload = bytes(range(256)) * 4
                sock.sendall(b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1024\r\n\r\n" + payload)
                wire.require(reader.response()[2] == payload, "borrowed gather echo mismatch")
                sock.sendall(b"GET /index.html HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                wire.require(reader.response()[2] == (wire.ROOT / "assets/index.html").read_bytes(),
                             "startup asset gather mismatch")
                wire.expect_closed(sock)
        wire.require(server.stats["max_send_bytes"] <= cap, "aggregate send_chunk exceeded")
        wire.require(server.stats["scalar_send_operations"] == 0, "gather mode used scalar SEND")
        wire.require(server.stats["max_send_parts"] <= 5, "gather vector bound exceeded")
        wire.require(server.stats["completed"] == 22, "missing gather wire response")
        sessions.append(dict(phase="wire_boundaries", send_chunk=cap,
                             plaintext_header_bytes=header_bytes, stats=server.stats))
        emit("gather_wire_aggregate_cap_%d" % cap)

    with wire.Server(binary, execution="inline", workers=0, response_batch_limit=1, gather_send=1,
                     connections=4, max_body=2 * 1024 * 1024, timeout_ms=1000,
                     send_chunk=65536, socket_send_buffer=4096) as server:
        with server.connect(timeout=3) as slow:
            slow.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
            payload = b"s" * (2 * 1024 * 1024)
            slow.sendall(b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2097152\r\n\r\n" + payload)
            wire.plaintext(server)
            time.sleep(1.25)
            wire.plaintext(server)
    wire.require(server.stats["gather_cancel_requests"] >= 1,
                 "slow reader did not witness cancellation of a pending gather send")
    wire.require(server.stats["bytes_received"] >= len(payload) and
                 server.stats["bytes_sent"] < len(payload), "slow-reader fixture did not hold response output")
    wire.require(server.stats["completed"] == 2 and server.stats["timeouts"] >= 1,
                 "healthy controls or response deadline were not observed")
    wire.require(server.stats["live_connections"] == server.stats["live_operations"] == 0,
                 "gather cancellation failed to drain ownership")
    sessions.append(dict(phase="pending_gather_cancellation", stats=server.stats))
    emit("pending_gather_send_cancellation_drains_owners_and_recovers")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", type=Path, default=wire.ROOT / "zig-out/bin/zig-http")
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    wire.require(1 <= args.timeout <= 300, "finite suite watchdog 1..300 seconds required")
    receipt = dict(schema_version=1, tool="zig-http-gather-integration", ok=False,
                   platform=sys.platform, server=str(args.server.resolve()), tests=[], sessions=[])
    started = time.monotonic()

    def watchdog(number, frame):
        raise TimeoutError("gather suite watchdog expired")

    def emit(name):
        receipt["tests"].append(dict(name=name, ok=True))
        print("PASS " + name, file=sys.stderr, flush=True)

    previous = signal.signal(signal.SIGALRM, watchdog)
    signal.alarm(args.timeout)
    try:
        wire.require(args.server.is_file(), "build the selected Debug/ReleaseSafe server first")
        run(args.server.resolve(), emit, receipt["sessions"])
        receipt["ok"] = True
    except Exception as error:
        receipt["error"] = "%s: %s" % (type(error).__name__, error)
        traceback.print_exc(file=sys.stderr)
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)
    receipt["seconds"] = round(time.monotonic() - started, 6)
    receipt["passed"] = len(receipt["tests"])
    encoded = json.dumps(receipt, sort_keys=True)
    print(encoded)
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(encoded + "\n", encoding="utf-8")
    return 0 if receipt["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
