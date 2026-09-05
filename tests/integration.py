#!/usr/bin/env python3
"""Bounded wire/lifecycle tests for the experimental server; Python stdlib only.

The client retains unread TCP suffixes and parses HTTP framing. Socket write
boundaries are deliberately never treated as packet or server-read boundaries.
Every socket, server process and overall test run has a finite deadline.
"""

import argparse
import contextlib
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import threading
import time
import traceback


ROOT = Path(__file__).resolve().parents[1]
PLAINTEXT = b"Hello, World!"
REQUEST = b"GET /plaintext HTTP/1.1\r\nHost: localhost\r\n\r\n"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


class ResponseReader:
    """Small test-side HTTP/1.x parser with explicit storage bounds."""

    def __init__(self, sock, maximum=4 * 1024 * 1024):
        self.sock = sock
        self.buffer = bytearray()
        self.maximum = maximum

    def _receive(self):
        data = self.sock.recv(65536)
        if not data:
            raise EOFError("EOF before complete HTTP response")
        self.buffer.extend(data)
        require(len(self.buffer) <= self.maximum + 65536, "client response buffer limit")

    def _take(self, count):
        require(0 <= count <= self.maximum, "response body exceeds client limit")
        while len(self.buffer) < count:
            self._receive()
        result = bytes(self.buffer[:count])
        del self.buffer[:count]
        return result

    def _line(self, maximum=16384):
        while True:
            end = self.buffer.find(b"\r\n")
            if end >= 0:
                require(end <= maximum, "response line exceeds client limit")
                line = bytes(self.buffer[:end])
                del self.buffer[:end + 2]
                return line
            require(len(self.buffer) <= maximum, "response line exceeds client limit")
            self._receive()

    def response(self, head=False):
        line = self._line()
        parts = line.split(b" ", 2)
        require(len(parts) >= 2 and parts[0] == b"HTTP/1.1", "bad response status line: %r" % line)
        status = int(parts[1])
        headers = {}
        header_bytes = len(line) + 2
        for _ in range(128):
            line = self._line()
            header_bytes += len(line) + 2
            require(header_bytes <= 32768, "response headers exceed client limit")
            if not line:
                break
            require(b":" in line, "malformed response header")
            name, value = line.split(b":", 1)
            name = name.lower()
            require(name not in headers or name not in (b"content-length", b"transfer-encoding"),
                    "duplicate response framing header")
            headers[name] = value.strip()
        else:
            raise AssertionError("too many response headers")
        if head or 100 <= status < 200 or status in (204, 304):
            return status, headers, b""
        require(not (b"content-length" in headers and b"transfer-encoding" in headers),
                "conflicting response framing")
        if b"transfer-encoding" in headers:
            require(headers[b"transfer-encoding"].lower() == b"chunked", "unsupported response coding")
            chunks = []
            total = 0
            for _ in range(self.maximum + 1):
                size = int(self._line().split(b";", 1)[0], 16)
                total += size
                require(total <= self.maximum, "chunked response exceeds client limit")
                if size == 0:
                    for _ in range(128):
                        if not self._line():
                            return status, headers, b"".join(chunks)
                    raise AssertionError("too many response trailers")
                chunks.append(self._take(size))
                require(self._take(2) == b"\r\n", "bad chunk terminator")
            raise AssertionError("too many response chunks")
        require(b"content-length" in headers, "test response must have explicit framing")
        return status, headers, self._take(int(headers[b"content-length"]))


class Server:
    def __init__(self, binary, **options):
        self.binary = binary
        self.options = dict(execution="workers", port=0, connections=16, workers=2, max_body=1024,
                            max_header=2048, timeout_ms=3000, stall_ms=1000,
                            send_chunk=7)
        self.options.update(options)
        self.process = None
        self.port = None
        self.backend = None
        self.stats = None
        self.lines = []
        self.ready = threading.Event()
        self.reader_thread = None

    def _read_log(self):
        try:
            for raw in iter(self.process.stderr.readline, b""):
                line = raw.decode("utf-8", "replace").rstrip()
                self.lines.append(line[:8192])
                del self.lines[:-200]
                ready = re.search(r"\bREADY port=(\d+) backend=(\S+)", line)
                if ready:
                    self.port = int(ready.group(1))
                    self.backend = ready.group(2)
                    self.ready.set()
                if line.startswith("STATS "):
                    self.stats = json.loads(line[6:])
        except Exception as error:
            self.lines.append("client log reader failed: %r" % error)
        finally:
            self.ready.set()

    def __enter__(self):
        command = [str(self.binary)]
        for key, value in self.options.items():
            command += ["--" + key.replace("_", "-"), str(value)]
        self.process = subprocess.Popen(command, cwd=ROOT, stdin=subprocess.DEVNULL,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                        start_new_session=(os.name == "posix"))
        self.reader_thread = threading.Thread(target=self._read_log, daemon=True)
        self.reader_thread.start()
        if not self.ready.wait(8) or self.port is None:
            self._kill()
            raise AssertionError("server did not become ready:\n" + "\n".join(self.lines))
        require(0 < self.port <= 65535, "invalid bound port")
        return self

    def connect(self, timeout=3.0):
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=timeout)
        sock.settimeout(timeout)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        return sock

    def _kill(self):
        if self.process and self.process.poll() is None:
            if os.name == "posix":
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(self.process.pid, signal.SIGKILL)
            else:
                self.process.kill()
            self.process.wait(timeout=3)

    def __exit__(self, kind, value, tb):
        failure = None
        try:
            if self.process.poll() is None:
                self.process.send_signal(signal.SIGINT)
            try:
                code = self.process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                self._kill()
                raise AssertionError("server exceeded eight-second shutdown watchdog")
            self.reader_thread.join(timeout=2)
            require(code == 0, "server exited %d:\n%s" % (code, "\n".join(self.lines)))
            require(isinstance(self.stats, dict), "server did not emit final STATS JSON")
            for field in ("accepted", "completed", "rejected", "timeouts", "flushes", "resumed",
                          "bytes_received", "bytes_sent", "live_connections", "peak_connections",
                          "live_operations", "peak_operations", "workers", "allocation_calls_after_start"):
                require(type(self.stats.get(field)) is int and self.stats[field] >= 0,
                        "missing/non-integer/negative stats field: " + field)
            require(self.stats["live_connections"] == 0, "connection ownership leaked at shutdown")
            require(self.stats["live_operations"] == 0, "operation ownership leaked at shutdown")
            require(self.stats["peak_connections"] <= self.options["connections"], "connection cap exceeded")
            require(self.stats["workers"] == self.options["workers"], "worker provisioning differs from config")
            require(self.stats["allocation_calls_after_start"] == 0, "framework allocated after startup")
            heap_fields = ("framework_heap_peak_bytes", "framework_heap_limit_bytes")
            if any(field in self.stats for field in heap_fields):
                for field in heap_fields:
                    require(type(self.stats.get(field)) is int and self.stats[field] >= 0,
                            "missing/non-integer/negative heap stats field: " + field)
                require(self.stats[heap_fields[0]] <= self.stats[heap_fields[1]],
                        "framework heap exceeded its startup limit")
        except BaseException as error:
            failure = error
        finally:
            self._kill()
            self.process.stderr.close()
        if failure and kind is None:
            raise failure
        if failure:
            print("Shutdown also failed: %s" % failure, file=sys.stderr)
        return False


def request(server, data, head=False):
    with server.connect() as sock:
        sock.sendall(data)
        return ResponseReader(sock).response(head=head)


def plaintext(server):
    status, headers, body = request(server, REQUEST)
    require(status == 200 and body == PLAINTEXT, "plaintext status/body mismatch")
    require(headers.get(b"content-length") == b"13", "plaintext length mismatch")
    require(headers.get(b"content-type", b"").startswith(b"text/plain"), "plaintext content type missing")
    require(b"date" in headers and b"server" in headers, "Date and Server headers required for baseline")


def expect_closed(sock):
    try:
        require(sock.recv(1) == b"", "unexpected bytes after connection-close response")
    except ConnectionResetError:
        pass


def run_suite(binary, emit, sessions):
    with Server(binary) as server:
        def check(name, function):
            start = time.monotonic()
            function()
            emit(name, time.monotonic() - start)

        check("plaintext", lambda: plaintext(server))

        def head():
            with server.connect() as sock:
                reader = ResponseReader(sock)
                sock.sendall(b"HEAD /plaintext HTTP/1.1\r\nHost: localhost\r\n\r\n" + REQUEST)
                status, headers, body = reader.response(head=True)
                require(status == 200 and headers.get(b"content-length") == b"13" and body == b"", "HEAD mismatch")
                require(reader.response()[2] == PLAINTEXT, "HEAD emitted body or corrupted next response")
        check("head_then_keepalive", head)

        def asset():
            expected = (ROOT / "assets/index.html").read_bytes()
            status, headers, body = request(server, b"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n")
            require(status == 200 and body == expected, "preloaded HTML differs from checked-in asset")
            require(headers.get(b"content-type", b"").startswith(b"text/html"), "HTML content type missing")
        check("startup_loaded_html", asset)
        check("unknown_route", lambda: require(request(server, b"GET /absent HTTP/1.1\r\nHost: localhost\r\n\r\n")[0] == 404, "unknown route must return 404"))

        def absolute_uri():
            for target, expected in (
                    (b"HTTP://localhost/plaintext?ignored=1", PLAINTEXT),
                    (b"hTtPs://localhost/index.html?ignored=1", (ROOT / "assets/index.html").read_bytes())):
                status, _, body = request(server, b"GET " + target + b" HTTP/1.1\r\nHost: localhost\r\n\r\n")
                require(status == 200 and body == expected,
                        "case-insensitive absolute URI scheme/query routing mismatch: %r" % target)
        check("absolute_uri_case_insensitive_scheme_and_query", absolute_uri)

        def fragmented():
            body = b"a\x00bc\xffdef"
            data = b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 8\r\nX-Lazy: untouched\r\n\r\n" + body
            with server.connect() as sock:
                for byte in data:
                    sock.sendall(bytes([byte]))
                    time.sleep(0.0002)
                status, _, response = ResponseReader(sock).response()
                require(status == 200 and response == body, "incremental binary echo mismatch")
        check("fragmented_headers_and_binary_body", fragmented)

        def boundary():
            body = bytes(range(256)) * 4
            status, _, response = request(server, b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1024\r\n\r\n" + body)
            require(status == 200 and response == body, "exact configured body cap must work")
        check("exact_body_limit", boundary)

        def chunked():
            with server.connect() as sock:
                reader = ResponseReader(sock)
                data = b"POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nTrailer: X-Checksum\r\n\r\n4;part=one\r\nWiki\r\n5\r\npedia\r\n0\r\nX-Checksum: none\r\n\r\n"
                for index in range(0, len(data), 3):
                    sock.sendall(data[index:index + 3])
                sock.sendall(REQUEST)
                require(reader.response()[2] == b"Wikipedia", "chunked body spans/framing mismatch")
                require(reader.response()[2] == PLAINTEXT, "chunked consumed pipelined suffix")
        check("chunked_echo_and_pipeline_suffix", chunked)

        def expect_continue():
            with server.connect() as sock:
                reader = ResponseReader(sock)
                sock.sendall(b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n")
                require(reader.response()[0] == 100, "server must decide 100-continue before body arrives")
                sock.sendall(b"hello")
                status, _, body = reader.response()
                require(status == 200 and body == b"hello", "body following 100-continue mismatch")
        check("expect_100_continue", expect_continue)

        def pipeline():
            with server.connect() as sock:
                sock.sendall(REQUEST * 15 + b"GET /plaintext HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                reader = ResponseReader(sock)
                for index in range(16):
                    status, _, body = reader.response()
                    require(status == 200 and body == PLAINTEXT, "pipeline response %d mismatch" % index)
                expect_closed(sock)
        check("pipeline_16_and_connection_close", pipeline)

        def chunks():
            with server.connect() as sock:
                reader = ResponseReader(sock)
                sock.sendall(b"GET /chunks HTTP/1.1\r\nHost: localhost\r\n\r\n" + REQUEST)
                status, _, body = reader.response()
                require(status == 200 and body == b"first second third", "flush/resume body mismatch")
                require(reader.response()[2] == PLAINTEXT, "finish corrupted next response")
        check("multiple_flushes_partial_sends_and_resume", chunks)

        bad_requests = [
            ("oversize_content_length", b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1025\r\n\r\n", {413}),
            ("oversize_expect_without_100", b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1025\r\nExpect: 100-continue\r\n\r\n", {413}),
            ("oversize_header_block", b"GET /plaintext HTTP/1.1\r\nHost: localhost\r\nX-Large: " + b"a" * 2100 + b"\r\n\r\n", {431}),
            ("conflicting_framing", b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n", {400}),
            ("conflicting_lengths", b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nxx", {400}),
            ("missing_host", b"GET /plaintext HTTP/1.1\r\n\r\n", {400}),
            ("whitespace_before_field_colon", b"GET /plaintext HTTP/1.1\r\nHost : localhost\r\n\r\n", {400}),
            ("unsupported_expectation", b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nExpect: surprise\r\n\r\n", {417}),
            ("cumulative_chunked_body_limit", b"POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n200\r\n" + b"x" * 512 + b"\r\n201\r\n" + b"y" * 513 + b"\r\n0\r\n\r\n", {413}),
        ]
        for name, data, expected in bad_requests:
            def rejected(data=data, expected=expected):
                with server.connect() as sock:
                    sock.sendall(data)
                    status, _, _ = ResponseReader(sock).response()
                    require(status in expected, "expected %r, got %d" % (expected, status))
                    expect_closed(sock)
                plaintext(server)
            check(name, rejected)

        def slow_handler():
            with server.connect() as stalled:
                stalled.sendall(b"GET /stall HTTP/1.1\r\nHost: localhost\r\n\r\n")
                time.sleep(0.1)
                start = time.monotonic()
                plaintext(server)
                elapsed = time.monotonic() - start
                require(elapsed < 0.75, "healthy worker/network progress stalled behind 1000ms handler: %.3fs" % elapsed)
                require(ResponseReader(stalled).response()[2] == b"done", "finite slow handler failed")
        check("healthy_progress_while_other_worker_stalls", slow_handler)
    require(server.stats["flushes"] >= 3 and server.stats["resumed"] >= 2, "flush/resume transitions were not observed")
    sessions.append(dict(phase="wire", backend=server.backend, stats=server.stats))

    start = time.monotonic()
    with Server(binary, connections=2, timeout_ms=2000, send_chunk=65536) as server:
        with contextlib.ExitStack() as stack:
            held = [stack.enter_context(server.connect()) for _ in range(2)]
            for sock in held:
                sock.sendall(b"GET /plaintext HTTP/1.1\r\nHost:")
            time.sleep(0.1)
            try:
                extra = stack.enter_context(server.connect(timeout=0.2))
                extra.sendall(REQUEST)
                status, _, _ = ResponseReader(extra).response()
                require(status == 503, "excess connection was admitted while both slots were occupied")
            except (TimeoutError, socket.timeout, EOFError, ConnectionError):
                # TCP backlog membership is not server-owned admission. Bounded
                # pause, refusal and close are all allowed at this boundary.
                pass
        time.sleep(0.1)
        plaintext(server)
    require(server.stats["peak_connections"] == 2, "capacity test did not reach its configured maximum")
    sessions.append(dict(phase="capacity", backend=server.backend, stats=server.stats))
    emit("connection_cap_and_recovery", time.monotonic() - start)

    start = time.monotonic()
    with Server(binary, connections=4, workers=2, max_body=1024, timeout_ms=2000,
                send_chunk=65536) as server:
        with contextlib.ExitStack() as stack:
            bodies = [bytes([ord("a") + index]) * 1024 for index in range(4)]
            held = [stack.enter_context(server.connect()) for _ in bodies]
            for sock, body in zip(held, bodies):
                sock.sendall(b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1024\r\n\r\n" + body[:-1])
            time.sleep(0.1)
            try:
                with server.connect(timeout=0.2) as extra:
                    extra.sendall(REQUEST)
                    status, _, _ = ResponseReader(extra).response()
                    require(status == 503, "fifth request admitted while four maximum-sized requests held all slots")
            except (TimeoutError, socket.timeout, EOFError, ConnectionError):
                pass
            for sock, body in zip(held, bodies):
                sock.sendall(body[-1:])
            for sock, expected in zip(held, bodies):
                status, _, body = ResponseReader(sock).response()
                require(status == 200 and body == expected,
                        "simultaneous exact-limit request lost ownership, bytes or progress")
        time.sleep(0.1)
        plaintext(server)
    require(server.stats["peak_connections"] == 4 and server.stats["completed"] == 5,
            "combined boundary fixture did not exercise four owned requests and recovery")
    sessions.append(dict(phase="combined_capacity", backend=server.backend, stats=server.stats))
    emit("simultaneous_connection_and_body_limits_then_recovery", time.monotonic() - start)

    start = time.monotonic()
    with Server(binary, connections=4, workers=1, timeout_ms=150, stall_ms=600,
                send_chunk=65536) as server:
        with server.connect(timeout=2) as incomplete:
            incomplete.sendall(b"GET /plaintext HTTP/1.1\r\nHost:")
            expect_closed(incomplete)
        plaintext(server)
        with server.connect(timeout=2) as stalled:
            stalled.sendall(b"GET /stall HTTP/1.1\r\nHost: localhost\r\n\r\n")
            expect_closed(stalled)
            time.sleep(0.65)
        plaintext(server)
    require(server.stats["timeouts"] >= 2, "idle/worker deadlines were not both observed")
    sessions.append(dict(phase="deadlines", backend=server.backend, stats=server.stats))
    emit("incomplete_and_handler_deadlines_then_recovery", time.monotonic() - start)

    start = time.monotonic()
    with Server(binary, connections=4, max_body=2 * 1024 * 1024, timeout_ms=1000,
                send_chunk=65536, socket_send_buffer=4096) as server:
        with server.connect(timeout=3) as slow:
            slow.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
            body = b"s" * (2 * 1024 * 1024)
            slow.sendall(b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2097152\r\n\r\n" + body)
            # This socket intentionally never reads its response. Request a
            # small server send buffer as well: Linux may otherwise absorb the
            # entire body, finish the response and only expire an idle receive.
            # SO_SNDBUF is an OS request (Linux adjusts its accounting), not a
            # portable assertion that the actual kernel buffer is 4096 bytes.
            # A separate connection must progress while output is held.
            plaintext(server)
            time.sleep(1.25)
            plaintext(server)
    require(server.stats["timeouts"] >= 1, "slow-reader fixture did not reach a response deadline")
    require(server.stats["bytes_received"] >= len(body) and server.stats["flushes"] >= 1,
            "slow-reader fixture did not receive and publish the echo response")
    require(server.stats["bytes_sent"] < len(body),
            "slow-reader fixture sent the entire body; an idle timeout is not a response-stall witness")
    require(server.stats["completed"] == 2,
            "only the two healthy control requests should complete in slow-reader fixture")
    sessions.append(dict(phase="slow_reader", backend=server.backend, stats=server.stats))
    emit("slow_reader_bounded_output_and_deadline", time.monotonic() - start)

    start = time.monotonic()
    with Server(binary, connections=4, stall_ms=300, send_chunk=1) as server:
        with contextlib.ExitStack() as stack:
            incomplete = stack.enter_context(server.connect())
            incomplete.sendall(b"GET /plaintext HTTP/1.1\r\nHost:")
            stalled = stack.enter_context(server.connect())
            stalled.sendall(b"GET /stall HTTP/1.1\r\nHost: localhost\r\n\r\n")
            time.sleep(0.05)
            # SIGINT while the two client sockets and finite worker borrow are
            # live. Keep them open until process shutdown has reconciled owners.
            server.process.send_signal(signal.SIGINT)
            server.process.wait(timeout=5)
    sessions.append(dict(phase="shutdown", backend=server.backend, stats=server.stats))
    emit("shutdown_with_live_receive_and_worker_borrows", time.monotonic() - start)
    return sessions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", type=Path, default=ROOT / "zig-out/bin/zig-http")
    parser.add_argument("--timeout", type=int, default=90, help="whole-suite watchdog seconds")
    parser.add_argument("--json", type=Path, help="also save the final JSON receipt")
    args = parser.parse_args()
    require(args.timeout > 0, "positive watchdog required")
    results = []
    receipt = dict(schema_version=1, tool="zig-http-integration", ok=False,
                   server=str(args.server.resolve()), platform=sys.platform,
                   python=sys.version.split()[0], tests=results, sessions=[])

    def emit(name, elapsed):
        results.append(dict(name=name, ok=True, seconds=round(elapsed, 6)))
        print("PASS " + name, file=sys.stderr, flush=True)

    def watchdog(signum, frame):
        raise TimeoutError("whole-suite watchdog expired after %d seconds" % args.timeout)

    previous = None
    if hasattr(signal, "SIGALRM"):
        previous = signal.signal(signal.SIGALRM, watchdog)
        signal.alarm(args.timeout)
    start = time.monotonic()
    try:
        require(args.server.is_file(), "build server first: zig build")
        run_suite(args.server.resolve(), emit, receipt["sessions"])
        receipt["ok"] = True
    except Exception as error:
        receipt["error"] = "%s: %s" % (type(error).__name__, error)
        traceback.print_exc(file=sys.stderr)
    finally:
        if previous is not None:
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
