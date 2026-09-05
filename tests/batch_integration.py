#!/usr/bin/env python3
"""Bounded generic response batches: wire ordering, cell leases and cancellation.

Single writes do not prove a particular TCP read shape. Counters explicitly
witness batching; timing is only a watchdog, never a throughput measurement.
"""
import argparse
import contextlib
import json
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time
import traceback

import integration as wire


class BatchServer(wire.Server):
    def __init__(self, binary, **options):
        options.setdefault("response_batch_limit", 16)
        options.setdefault("send_chunk", 65536)
        super().__init__(binary, execution="inline", workers=0, **options)

    def __exit__(self, kind, value, tb):
        result = super().__exit__(kind, value, tb)
        if kind is None:
            wire.require(self.stats["worker_dispatches"] == 0, "unexpected worker dispatch")
            wire.require(self.stats["max_batch_responses"] <= self.options["response_batch_limit"], "response batch limit exceeded")
            wire.require(self.stats["max_inline_callbacks_per_turn"] <= 64, "global callback turn limit exceeded")
        return result


def get(target, method=b"GET", close=False):
    return method + b" " + target + b" HTTP/1.1\r\nHost: localhost\r\n" + (b"Connection: close\r\n" if close else b"") + b"\r\n"


def mixed(count):
    html = (wire.ROOT / "assets/index.html").read_bytes()
    requests, expected = [], []
    for index in range(count):
        choice = index % 6
        if choice == 0:
            requests.append(wire.REQUEST)
            expected.append((False, wire.PLAINTEXT))
        elif choice == 1:
            target = b"/buffered?unique=" + str(index).encode() + b"-" + b"x" * index
            requests.append(get(target))
            expected.append((False, target))
        elif choice == 2:
            requests.append(get(b"/index.html"))
            expected.append((False, html))
        elif choice == 3:
            requests.append(get(b"/index.html", method=b"HEAD"))
            expected.append((True, b""))
        elif choice == 4:
            payload = bytes([index % 256]) * (index + 5)
            requests.append(b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: " + str(len(payload)).encode() + b"\r\n\r\n" + payload)
            expected.append((False, payload))
        else:
            requests.append(get(b"/chunks"))
            expected.append((False, b"first second third"))
    return b"".join(requests), expected


def run(binary, emit, sessions):
    for invalid in (0, 17):
        result = subprocess.run([str(binary), "--response-batch-limit", str(invalid)], cwd=wire.ROOT, capture_output=True, timeout=5)
        wire.require(result.returncode != 0 and b"InvalidConfiguration" in result.stderr, "invalid batch limit admitted")
    emit("batch_limit_configuration_rejected")

    for limit, cap in ((1, 65536), (2, 65536), (4, 65536), (16, 65536), (16, 1), (16, 17)):
        with BatchServer(binary, response_batch_limit=limit, send_chunk=cap) as server:
            for count in (31, 32):
                with server.connect() as sock:
                    encoded, expected = mixed(count)
                    sock.sendall(encoded + get(b"/plaintext", close=True))
                    reader = wire.ResponseReader(sock)
                    for head, body in expected:
                        status, headers, received = reader.response(head=head)
                        wire.require(status == 200 and received == body, "mixed pipeline body/cell corruption")
                        wire.require(b"date" in headers, "missing response date")
                    wire.require(reader.response()[2] == wire.PLAINTEXT, "final close response lost")
                    wire.expect_closed(sock)
        wire.require(server.stats["completed"] == 65, "mixed pipeline missing finished response")
        wire.require(server.stats["max_send_bytes"] <= cap, "aggregate submission cap exceeded")
        if limit > 1:
            wire.require(server.stats["max_batch_responses"] > 1 and server.stats["batched_finished_responses"] > 0, "fixture did not witness response batching")
        sessions.append(dict(phase="mixed", limit=limit, cap=cap, stats=server.stats))
        emit("mixed_31_32_limit_%d_aggregate_%d" % (limit, cap))

    for limit in (1, 16):
        with BatchServer(binary, response_batch_limit=limit) as server:
            with server.connect() as sock:
                # Every finished output is different; sharing one writer buffer
                # across frozen cells would corrupt these responses.
                targets = [b"/buffered?cell=" + str(i).encode() for i in range(32)]
                sock.sendall(b"".join(get(target) for target in targets))
                reader = wire.ResponseReader(sock)
                for target in targets:
                    wire.require(reader.response()[2] == target, "frozen generated response reused another cell")
        sessions.append(dict(phase="generated_pipeline", limit=limit, stats=server.stats))
        if limit == 16:
            wire.require(server.stats["max_batch_responses"] > 1, "generated fixture did not batch")
            wire.require(server.stats["gather_send_operations"] < 32, "batching failed to reduce sends")
        emit("distinct_generated_output_cells_limit_%d" % limit)

    with BatchServer(binary) as server:
        with server.connect() as sock:
            sock.sendall(wire.REQUEST * 7 + b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhe")
            reader = wire.ResponseReader(sock)
            for _ in range(7):
                wire.require(reader.response()[2] == wire.PLAINTEXT, "finished prefix waited for incomplete suffix")
            sock.sendall(b"llo" + wire.REQUEST)
            wire.require(reader.response()[2] == b"hello", "split next-request body corrupted")
            wire.require(reader.response()[2] == wire.PLAINTEXT, "split next-request ordering corrupted")
        with server.connect() as sock:
            sock.sendall(wire.REQUEST * 7 + b"POST /echo HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n")
            reader = wire.ResponseReader(sock)
            for _ in range(7):
                wire.require(reader.response()[2] == wire.PLAINTEXT, "100 Continue overtook an earlier response")
            wire.require(reader.response()[0] == 100, "missing ordered 100 Continue")
            sock.sendall(b"hello" + wire.REQUEST)
            wire.require(reader.response()[2] == b"hello", "Expect body corrupted")
            wire.require(reader.response()[2] == wire.PLAINTEXT, "Expect next request corrupted")
        with server.connect() as sock:
            sock.sendall(wire.REQUEST * 7 + b"GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n")
            reader = wire.ResponseReader(sock)
            for _ in range(7):
                wire.require(reader.response()[2] == wire.PLAINTEXT, "rejection overtook valid prefix")
            wire.require(reader.response()[0] == 400, "bad suffix accepted")
            wire.expect_closed(sock)
        with server.connect() as sock:
            sock.sendall(wire.REQUEST * 7 + get(b"/buffered?close", close=True) + wire.REQUEST)
            reader = wire.ResponseReader(sock)
            for _ in range(7):
                wire.require(reader.response()[2] == wire.PLAINTEXT, "close overtook valid prefix")
            wire.require(reader.response()[2] == b"/buffered?close", "closing output cell corrupt")
            wire.expect_closed(sock)
        wire.plaintext(server)
    sessions.append(dict(phase="ordered_boundaries", stats=server.stats))
    emit("incomplete_expect_rejection_and_close_preserve_prefix_order")

    with BatchServer(binary, send_chunk=23) as server:
        with server.connect() as sock:
            payloads = [bytes([index]) * (index + 1) for index in range(32)]
            sock.sendall(b"".join(b"POST /borrowed-body HTTP/1.1\r\nHost: localhost\r\nContent-Length: " + str(len(payload)).encode() + b"\r\n\r\n" + payload for payload in payloads))
            reader = wire.ResponseReader(sock)
            for payload in payloads:
                status, headers, body = reader.response()
                wire.require(status == 200 and body == payload and headers[b"content-length"] == str(len(payload)).encode(), "retained request body or header cell was overwritten")
            sock.sendall(b"POST /borrowed-body HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n" + wire.REQUEST)
            wire.require(reader.response()[0] == 501, "fixed-body fixture accepted chunked input")
            wire.require(reader.response()[2] == wire.PLAINTEXT, "unsupported fixture input lost pipeline suffix")
    wire.require(server.stats["max_batch_responses"] > 1 and server.stats["completed"] == 34, "multi-request borrowed-body batch was not exercised")
    sessions.append(dict(phase="borrowed_finished_cells", stats=server.stats))
    emit("distinct_finished_request_bodies_and_headers_survive_partial_sends")

    with BatchServer(binary, output_bytes=32) as server:
        with server.connect() as sock:
            sock.sendall(wire.REQUEST * 3 + get(b"/buffered?" + b"x" * 32) + wire.REQUEST)
            reader = wire.ResponseReader(sock)
            for _ in range(3):
                wire.require(reader.response()[2] == wire.PLAINTEXT, "buffer boundary overtook prefix")
            status, _, body = reader.response()
            wire.require(status == 413 and body == b"", "oversized buffered demo target did not return 413")
            wire.require(reader.response()[2] == wire.PLAINTEXT, "buffer rejection lost next request")
    sessions.append(dict(phase="output_boundary", stats=server.stats))
    emit("buffered_demo_output_limit_returns_ordered_413")

    with BatchServer(binary, connections=8) as server:
        with contextlib.ExitStack() as stack:
            busy = [stack.enter_context(server.connect()) for _ in range(7)]
            later = stack.enter_context(server.connect())
            for sock in busy:
                sock.sendall(wire.REQUEST * 512)
            later.sendall(get(b"/buffered?later-slot"))
            wire.require(wire.ResponseReader(later).response()[2] == b"/buffered?later-slot", "busy early slots starved a later slot")
            for sock in busy:
                reader = wire.ResponseReader(sock)
                for _ in range(512):
                    wire.require(reader.response()[2] == wire.PLAINTEXT, "busy connection lost progress")
    wire.require(server.stats["completed"] == 3585 and server.stats["max_inline_callbacks_per_turn"] <= 64, "global callback budget/progress accounting differs")
    sessions.append(dict(phase="fairness", stats=server.stats))
    emit("global_callback_budget_rotates_busy_connections")

    with BatchServer(binary, response_batch_limit=16, send_chunk=19) as server:
        with server.connect() as sock:
            # Suppressed body snapshots still resume without recursion or idle
            # sleeps, and preserve their request while preceding cells drain.
            sock.sendall(wire.REQUEST * 5 + b"HEAD /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" + b"1\r\nx\r\n" * 128 + b"0\r\n\r\n" + wire.REQUEST * 20)
            reader = wire.ResponseReader(sock)
            for _ in range(5):
                wire.require(reader.response()[2] == wire.PLAINTEXT, "HEAD prefix lost")
            wire.require(reader.response(head=True)[2] == b"", "HEAD emitted bytes")
            for _ in range(20):
                wire.require(reader.response()[2] == wire.PLAINTEXT, "empty flush consumed later request")
    wire.require(server.stats["resumed"] == 128 and server.stats["completed"] == 26, "empty flush resume accounting differs")
    sessions.append(dict(phase="empty_flushes", stats=server.stats))
    emit("batch_flush_barrier_and_128_empty_resumes")

    with BatchServer(binary, connections=8, max_body=2 * 1024 * 1024, timeout_ms=1000,
                     socket_send_buffer=4096) as server:
        with contextlib.ExitStack() as stack:
            slow = stack.enter_context(server.connect())
            slow.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
            payload = b"z" * (2 * 1024 * 1024)
            slow.sendall(wire.REQUEST * 7 + b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2097152\r\n\r\n" + payload)
            wire.plaintext(server)
            time.sleep(1.25)
            wire.plaintext(server)
            incomplete = stack.enter_context(server.connect())
            incomplete.sendall(wire.REQUEST * 3 + b"GET /plaintext HTTP/1.1\r\nHost:")
            server.process.send_signal(signal.SIGINT)
            server.process.wait(timeout=5)
    wire.require(server.stats["gather_cancel_requests"] >= 1, "slow reader did not retain a cancellable gather")
    wire.require(server.stats["bytes_received"] >= len(payload) and server.stats["timeouts"] >= 1, "borrowed payload deadline was not reached")
    wire.require(server.stats["bytes_sent"] < len(payload), "slow reader fixture did not retain a partial payload")
    sessions.append(dict(phase="cancel_shutdown", stats=server.stats))
    emit("borrowed_batch_slow_reader_deadline_recovery_shutdown")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", type=Path, default=wire.ROOT / "zig-out/bin/zig-http")
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    wire.require(1 <= args.timeout <= 300, "finite suite watchdog required")
    receipt = dict(schema_version=1, tool="zig-http-batch-integration", ok=False,
                   platform=sys.platform, server=str(args.server.resolve()), tests=[], sessions=[])
    started = time.monotonic()
    def watchdog(number, frame):
        raise TimeoutError("batch suite watchdog expired")
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
