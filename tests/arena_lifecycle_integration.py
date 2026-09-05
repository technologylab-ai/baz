#!/usr/bin/env python3
"""Finite wire witnesses for arena EOF, worker ownership and interim progress.

Synthetic Zig unit tests force the formerly failing completion order and cache
publication sequence. These native cases validate the resulting bytes, flush
continuations and shutdown; TCP write boundaries do not establish CQE order.
"""

import argparse
from email.utils import parsedate_to_datetime
import json
from pathlib import Path
import signal
import socket
import sys
import time
import traceback

import integration as wire
from batch_integration import get, paused


def checked_response(reader, expected, head=False):
    status, headers, body = reader.response(head=head)
    wire.require(status == 200 and body == expected, "response framing/body changed across EOF")
    date = headers.get(b"date", b"")
    wire.require(len(date) == 29 and date.endswith(b" GMT"), "missing or malformed Date header")
    parsedate_to_datetime(date.decode("ascii"))


def run(binary, emit, sessions):
    # Queue complete requests and FIN before the I/O owner resumes. Borrowed
    # input, generated output, HEAD and flush/resume all survive peer write EOF.
    # A small aggregate cap keeps output pending across multiple completions.
    for execution in ("inline", "workers"):
        for overlap in (0, 1):
            with wire.Server(binary, execution=execution, workers=0 if execution == "inline" else 2,
                             shards=1, prearm_receive=overlap, send_chunk=7,
                             borrow_copy_threshold=0) as server:
                payload = bytes(range(256)) * 2 + b"!"
                target = b"/buffered?after-peer-write-eof"
                requests = (wire.REQUEST +
                            b"POST /borrowed-body-chunked HTTP/1.1\r\nHost: localhost\r\nContent-Length: " +
                            str(len(payload)).encode() + b"\r\n\r\n" + payload +
                            get(b"/chunks") + get(b"/index.html", method=b"HEAD") + get(target))
                with server.connect() as sock:
                    with paused(server):
                        sock.sendall(requests)
                        sock.shutdown(socket.SHUT_WR)
                    reader = wire.ResponseReader(sock)
                    checked_response(reader, wire.PLAINTEXT)
                    checked_response(reader, payload)
                    checked_response(reader, b"first second third")
                    checked_response(reader, b"", head=True)
                    checked_response(reader, target)
                    wire.require(not reader.buffer, "unexpected response after complete EOF pipeline")
                    wire.expect_closed(sock)
            stats = server.stats
            wire.require(stats["completed"] == 5 and stats["timeouts"] == stats["rejected"] == 0,
                         "valid EOF pipeline was rejected or lost")
            wire.require(stats["flushes"] == stats["resumed"] == 3, "EOF lost a flush continuation")
            wire.require(stats["max_send_bytes"] <= 7, "partial-send cap was exceeded")
            if overlap:
                wire.require(stats["prearmed_receives"] > 0, "prearmed EOF path was not exercised")
            name = "half_close_%s_prearm_%d" % (execution, overlap)
            sessions.append(dict(phase=name, stats=stats))
            emit(name)

    # Native counterpart to the deterministic body-before-interim-completion
    # unit test. A client may send its body as soon as it observes the interim
    # bytes, before the server has collected their send completion.
    for overlap in (0, 1):
        with wire.Server(binary, execution="inline", workers=0, shards=1,
                         prearm_receive=overlap, send_chunk=7) as server:
            with server.connect() as sock:
                with paused(server):
                    sock.sendall(wire.REQUEST + b"POST /echo HTTP/1.1\r\nHost: localhost\r\n"
                                 b"Expect: 100-continue\r\nContent-Length: 4\r\n\r\n")
                reader = wire.ResponseReader(sock)
                checked_response(reader, wire.PLAINTEXT)
                wire.require(reader.response()[0] == 100, "missing ordered interim response")
                sock.sendall(b"body")
                sock.shutdown(socket.SHUT_WR)
                checked_response(reader, b"body")
                wire.require(not reader.buffer, "interim path duplicated a response")
                wire.expect_closed(sock)
        wire.require(server.stats["completed"] == 2 and server.stats["timeouts"] == 0,
                     "buffered Expect body stalled or lost its response")
        name = "expect_body_and_eof_prearm_%d" % overlap
        sessions.append(dict(phase=name, stats=server.stats))
        emit(name)

    # EOF can make an incomplete suffix terminal; it must neither hang waiting
    # for impossible bytes nor discard the complete response before that suffix.
    for overlap in (0, 1):
        with wire.Server(binary, execution="inline", workers=0, shards=1,
                         prearm_receive=overlap, send_chunk=7) as server:
            with server.connect() as sock:
                with paused(server):
                    sock.sendall(wire.REQUEST + b"POST /echo HTTP/1.1\r\nHost: localhost\r\n"
                                 b"Content-Length: 9\r\n\r\nshort")
                    sock.shutdown(socket.SHUT_WR)
                reader = wire.ResponseReader(sock)
                checked_response(reader, wire.PLAINTEXT)
                wire.require(reader.response()[0] == 400, "incomplete EOF suffix did not get an ordered rejection")
                wire.require(not reader.buffer, "unexpected bytes after EOF rejection")
                wire.expect_closed(sock)
        wire.require(server.stats["completed"] == 1 and server.stats["rejected"] == 1 and
                     server.stats["timeouts"] == 0, "EOF rejection changed prefix ownership")
        name = "incomplete_eof_preserves_prefix_prearm_%d" % overlap
        sessions.append(dict(phase=name, stats=server.stats))
        emit(name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", type=Path, default=wire.ROOT / "zig-out/bin/zig-http")
    parser.add_argument("--timeout", type=int, default=90)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    wire.require(1 <= args.timeout <= 300, "finite suite watchdog required")
    receipt = dict(schema_version=1, tool="zig-http-arena-lifecycle-integration", ok=False,
                   platform=sys.platform, server=str(args.server.resolve()), tests=[], sessions=[])
    started = time.monotonic()

    def watchdog(number, frame):
        raise TimeoutError("arena lifecycle suite watchdog expired")

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
