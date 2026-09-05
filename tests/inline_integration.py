#!/usr/bin/env python3
"""Wire and ownership gates for explicit bounded/nonblocking inline execution.

Reuse the existing bounded HTTP client and process watchdog; a passing suite
establishes no preemption or isolation of arbitrary application callbacks.
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

from integration import (PLAINTEXT, REQUEST, ROOT, ResponseReader, Server,
                         expect_closed, plaintext, request, require)


class InlineServer(Server):
    def __init__(self, binary, **options):
        super().__init__(binary, execution="inline", workers=0, **options)

    def __exit__(self, kind, value, tb):
        result = super().__exit__(kind, value, tb)
        if kind is None:
            require(self.stats["execution"] == "inline_event_loop", "wrong execution mode")
            require(self.stats["worker_dispatches"] == 0, "inline mode dispatched a worker")
        return result


def run_suite(binary, emit, sessions):
    start = time.monotonic()
    process = subprocess.run([str(binary), "--execution", "inline", "--port", "0",
                              "--duration-ms", "10"], cwd=ROOT, capture_output=True, timeout=8)
    require(process.returncode == 0 and b"workers=0 execution=inline_event_loop" in process.stderr,
            "--execution inline must provision zero application workers")
    for options in (("--execution", "inline", "--workers", "2"), ("--workers", "0")):
        process = subprocess.run([str(binary), *options], cwd=ROOT, capture_output=True, timeout=8)
        require(process.returncode != 0 and b"InvalidConfiguration" in process.stderr,
                "contradictory execution/worker configuration accepted")
    emit("explicit_inline_configuration_and_zero_worker_default", time.monotonic() - start)

    with InlineServer(binary) as server:
        def check(name, function):
            start = time.monotonic()
            function()
            emit(name, time.monotonic() - start)

        check("inline_plaintext", lambda: plaintext(server))

        def pipeline():
            with server.connect() as sock:
                sock.sendall(REQUEST * 15 + b"GET /plaintext HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                reader = ResponseReader(sock)
                for index in range(16):
                    status, _, body = reader.response()
                    require(status == 200 and body == PLAINTEXT, "pipeline response %d mismatch" % index)
                expect_closed(sock)
        check("inline_pipeline_16_partial_sends_and_close", pipeline)

        def echo():
            body = bytes(range(256)) * 4
            status, _, received = request(server, b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1024\r\n\r\n" + body)
            require(status == 200 and received == body, "exact body limit echo differs")
        check("inline_borrowed_echo_at_body_limit", echo)

        def chunks():
            with server.connect() as sock:
                sock.sendall(b"GET /chunks HTTP/1.1\r\nHost: localhost\r\n\r\n" + REQUEST)
                reader = ResponseReader(sock)
                status, headers, body = reader.response()
                require(status == 200 and body == b"first second third" and headers.get(b"transfer-encoding") == b"chunked",
                        "flush/resume response or framing differs")
                require(reader.response()[2] == PLAINTEXT, "resumed writer corrupted pipelined request")
        check("inline_chunked_flush_resume_then_pipeline", chunks)

        def empty_flushes():
            # HEAD suppresses every body span. After the first header completes,
            # 128 flushes must resume through bounded loop turns without a
            # transport completion, worker wake, recursion or 10 ms idle waits.
            data = (b"HEAD /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" +
                    b"1\r\nx\r\n" * 128 + b"0\r\n\r\n" + REQUEST)
            with server.connect(timeout=0.75) as sock:
                sock.sendall(data)
                reader = ResponseReader(sock)
                status, headers, body = reader.response(head=True)
                require(status == 200 and headers.get(b"content-length") == b"128" and body == b"", "HEAD echo framing differs")
                require(reader.response()[2] == PLAINTEXT, "local empty flush continuation failed to progress")
        check("inline_128_empty_flushes_without_idle_poll_wait", empty_flushes)

        def rejected():
            malformed = b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n"
            with server.connect() as sock:
                sock.sendall(malformed)
                require(ResponseReader(sock).response()[0] == 400, "ambiguous framing accepted")
                expect_closed(sock)
            require(request(server, b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1025\r\n\r\n")[0] == 413,
                    "body overflow accepted")
            plaintext(server)
        check("inline_malformed_and_oversize_rejection_then_recovery", rejected)
        check("inline_blocking_demo_route_disabled", lambda: require(
            request(server, b"GET /stall HTTP/1.1\r\nHost: localhost\r\n\r\n")[0] == 501,
            "deliberately blocking fixture must be unavailable inline"))
    require(server.stats["inline_dispatches"] >= 150 and server.stats["resumed"] >= 132,
            "inline callback and empty flush transitions not observed")
    sessions.append(dict(phase="wire", backend=server.backend, stats=server.stats))

    start = time.monotonic()
    with InlineServer(binary, connections=2, timeout_ms=200, send_chunk=65536) as server:
        with contextlib.ExitStack() as stack:
            held = [stack.enter_context(server.connect()) for _ in range(2)]
            for sock in held:
                sock.sendall(b"GET /plaintext HTTP/1.1\r\nHost:")
            time.sleep(0.05)
            try:
                with server.connect(timeout=0.1) as extra:
                    extra.sendall(REQUEST)
                    require(ResponseReader(extra).response()[0] == 503, "connection beyond slot cap admitted")
            except (TimeoutError, socket.timeout, EOFError, ConnectionError):
                pass
            for sock in held:
                expect_closed(sock)
        plaintext(server)
    require(server.stats["peak_connections"] == 2 and server.stats["timeouts"] >= 2,
            "capacity and incomplete-request deadline boundary not reached")
    sessions.append(dict(phase="capacity_deadline", backend=server.backend, stats=server.stats))
    emit("inline_connection_cap_deadlines_and_recovery", time.monotonic() - start)

    start = time.monotonic()
    with InlineServer(binary, connections=4, max_body=2 * 1024 * 1024, timeout_ms=5000,
                      socket_send_buffer=4096, send_chunk=65536) as server:
        with contextlib.ExitStack() as stack:
            slow = stack.enter_context(server.connect())
            slow.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
            body = b"s" * (2 * 1024 * 1024)
            slow.sendall(b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2097152\r\n\r\n" + body)
            incomplete = stack.enter_context(server.connect())
            incomplete.sendall(b"GET /plaintext HTTP/1.1\r\nHost:")
            plaintext(server)
            time.sleep(0.1)
            server.process.send_signal(signal.SIGINT)
            server.process.wait(timeout=5)
    require(server.stats["bytes_received"] >= len(body) and server.stats["flushes"] >= 1,
            "shutdown fixture never published the borrowed response")
    require(server.stats["bytes_sent"] < len(body) and server.stats["completed"] == 1,
            "shutdown fixture must retain a partial response alongside a completed control request")
    sessions.append(dict(phase="shutdown", backend=server.backend, stats=server.stats))
    emit("inline_shutdown_with_live_receive_and_partial_send_borrows", time.monotonic() - start)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", type=Path, default=ROOT / "zig-out/bin/zig-http")
    parser.add_argument("--timeout", type=int, default=45)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    require(args.timeout > 0, "positive watchdog required")
    results = []
    receipt = dict(schema_version=1, tool="zig-http-inline-integration", ok=False,
                   server=str(args.server.resolve()), platform=sys.platform,
                   python=sys.version.split()[0], tests=results, sessions=[])

    def emit(name, elapsed):
        results.append(dict(name=name, ok=True, seconds=round(elapsed, 6)))
        print("PASS " + name, file=sys.stderr, flush=True)

    def watchdog(signum, frame):
        raise TimeoutError("whole-suite watchdog expired")

    previous = signal.signal(signal.SIGALRM, watchdog)
    signal.alarm(args.timeout)
    start = time.monotonic()
    try:
        require(args.server.is_file(), "build server first")
        run_suite(args.server.resolve(), emit, receipt["sessions"])
        receipt["ok"] = True
    except Exception as error:
        receipt["error"] = "%s: %s" % (type(error).__name__, error)
        traceback.print_exc(file=sys.stderr)
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)
    receipt["seconds"] = round(time.monotonic() - start, 6)
    receipt["passed"] = len(results)
    encoded = json.dumps(receipt, sort_keys=True)
    print(encoded)
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(encoded + "\n", encoding="utf-8")
    return 0 if receipt["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
