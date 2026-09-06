#!/usr/bin/env python3
"""Native streaming correctness gates with finite socket and process deadlines.

The fixture requires ReleaseSafe. Delays coordinate ownership checks; this suite
does not measure throughput or publish performance comparisons. The caller must
hold the shared host reservation and supply an overall process-tree watchdog.
"""

import argparse
from contextlib import ExitStack
import json
import platform
from pathlib import Path
import socket
import time

from app_integration import request_bytes
from examples_integration import ExampleServer
import wire_support as wire


class StreamServer(wire.Server):
    def __init__(self, binary, **options):
        super().__init__(binary)
        self.options = dict(port=0, connections=16, execution="workers", workers=2,
                            shards=1, max_body=1024, max_header=2048,
                            timeout_ms=3000, shutdown_ms=3000, send_chunk=7,
                            output_bytes=16384, response_body=8192, stall_ms=20,
                            max_response=64 * 1024 * 1024)
        self.options.update(options)
        self.fixture = None
        self.observations = {}

    def __enter__(self):
        super().__enter__()
        try:
            wire.require(any("optimize=ReleaseSafe" in line for line in self.lines),
                         "streaming wire gates require a ReleaseSafe binary")
        except BaseException:
            import sys
            self.__exit__(*sys.exc_info())
            raise
        return self

    def __exit__(self, kind, value, tb):
        result = super().__exit__(kind, value, tb)
        if kind is None:
            rows = [line[len("FIXTURE "):] for line in self.lines if line.startswith("FIXTURE ")]
            wire.require(len(rows) == 1, "missing or repeated fixture ownership receipt")
            self.fixture = json.loads(rows[0])
            wire.require(self.fixture["started"] == self.fixture["finished"],
                         "a streaming callback retained its worker at shutdown")
        return result


class StreamReader(wire.ResponseReader):
    """Read HTTP headers and individual chunks without waiting for completion."""

    def head(self):
        line = self._line()
        parts = line.split(b" ", 2)
        wire.require(len(parts) >= 2 and parts[0] == b"HTTP/1.1", "invalid streaming status line")
        status = int(parts[1])
        headers = {}
        total = len(line) + 2
        for _ in range(128):
            line = self._line()
            total += len(line) + 2
            wire.require(total <= 32768, "streaming head exceeds client bound")
            if not line:
                wire.require(not (b"content-length" in headers and b"transfer-encoding" in headers),
                             "conflicting streaming framing")
                return status, headers
            wire.require(b":" in line, "invalid streaming header")
            name, value = line.split(b":", 1)
            name = name.lower()
            wire.require(name not in headers or name not in (b"content-length", b"transfer-encoding"),
                         "duplicate streaming framing header")
            headers[name] = value.strip()
        raise AssertionError("streaming head has too many fields")

    def chunk(self):
        line = self._line()
        wire.require(b";" not in line, "fixture unexpectedly emitted a chunk extension")
        count = int(line, 16)
        wire.require(0 <= count <= self.maximum, "chunk exceeds client bound")
        if not count:
            wire.require(self._line() == b"", "fixture unexpectedly emitted trailers")
            return None
        data = self._take(count)
        wire.require(self._take(2) == b"\r\n", "invalid streaming chunk terminator")
        return data

    def unfinished(self):
        wire.require(not self.buffer, "failed stream emitted extra framing or a replacement response")
        wire.expect_closed(self.sock)


def exchange(sock, reader, path, method="GET"):
    sock.sendall(request_bytes(path, method=method))
    result = reader.response(head=method == "HEAD")
    wire.require(result[0] == 200, "%s returned %d" % (path, result[0]))
    return result


def state(sock, reader):
    return json.loads(exchange(sock, reader, "/state")[2])


def wait_state(sock, reader, predicate, timeout=2.0):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = state(sock, reader)
        if predicate(last):
            return last
        time.sleep(0.01)
    raise AssertionError("fixture state did not reach its condition: %r" % last)


def pair(server, clients, small_window=False):
    if small_window:
        data = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        clients.callback(data.close)
        data.settimeout(3.0)
        data.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        data.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        data.connect(("127.0.0.1", server.port))
    else:
        data = clients.enter_context(server.connect())
    data_reader = StreamReader(data)
    wire.require(exchange(data, data_reader, "/ping")[2] == b"ok\n", "first admission failed")
    control = clients.enter_context(server.connect())
    control_reader = wire.ResponseReader(control)
    wire.require(exchange(control, control_reader, "/ping")[2] == b"ok\n", "second admission failed")
    # Consecutive admitted slots use different fixed workers with one I/O owner.
    return data, data_reader, control, control_reader


def expect_chunked(reader):
    status, headers = reader.head()
    wire.require(status == 200 and headers.get(b"transfer-encoding") == b"chunked",
                 "unknown-length stream did not use chunked framing")
    return headers


def await_backpressure(control, reader):
    deadline = time.monotonic() + 2.0
    previous = None
    stable = 0
    while time.monotonic() < deadline:
        current = state(control, reader)
        wire.require(current["finished"] == 0, "pressure fixture ended before its blocked flush")
        counts = (current["flush_started"], current["flush_returned"])
        if counts[0] == counts[1] + 1 and counts == previous:
            stable += 1
            if stable == 3:
                return current
        else:
            stable = 0
        previous = counts
        time.sleep(0.03)
    raise AssertionError("stopped reader did not hold one flush across four control observations")


def check_canceled_flush(server, final):
    blocked = server.observations["blocked_flush"]
    wire.require(final["flush_canceled"] == 1, "the outstanding flush was not canceled")
    wire.require(final["flush_started"] == final["flush_returned"] + 1,
                 "cancellation did not reconcile exactly one outstanding flush")
    wire.require(final["flush_started"] >= blocked["flush_started"]
                 and final["flush_returned"] >= blocked["flush_returned"],
                 "flush counters moved backward after observed backpressure")
    # A TCP stack can make later progress without an application read. These
    # receipts preserve both observations without assuming uninterrupted stasis.
    server.observations["canceled_flush"] = final


def run(binary, example=None):
    cases = []

    def passed(name, server):
        cases.append(dict(name=name, backend=server.backend, options=server.options,
                          stats=server.stats, fixture=getattr(server, "fixture", None),
                          observations=getattr(server, "observations", {})))
        print("PASS " + name, flush=True)

    with StreamServer(binary, connections=2) as server:
        with ExitStack() as clients:
            data, reader, control, control_reader = pair(server, clients)
            data.sendall(request_bytes("/gated"))
            headers = expect_chunked(reader)
            wire.require(headers.get(b"x-stream") == b"gated", "pre-flush header disappeared")
            wire.require(reader.chunk() == b"first\n", "first flush was not readable")
            observed = state(control, control_reader)
            wire.require(observed["started"] == 1 and observed["finished"] == 0
                         and not observed["released"], "first chunk arrived only after handler completion")
            with server.connect() as overflow:
                wire.expect_closed(overflow)
            exchange(control, control_reader, "/release", method="POST")
            wire.require(reader.chunk() == b"second\n", "empty flush terminated the stream")
            wire.require(reader.chunk() == b"final\n" and reader.chunk() is None,
                         "final chunk or terminal framing changed")
            wire.require(exchange(data, reader, "/ping")[2] == b"ok\n", "stream connection was not reusable")
            wait_state(control, control_reader, lambda value: value["finished"] == 1)
    wire.require(server.stats["flushes"] >= 3, "flush ownership path was not exercised")
    passed("first chunk precedes callback return; second worker releases the handler", server)

    with StreamServer(binary) as server:
        with server.connect() as sock:
            reader = StreamReader(sock)
            sock.sendall(request_bytes("/stream") + request_bytes("/empty")
                         + request_bytes("/auto") + request_bytes("/late-header")
                         + request_bytes("/ping"))
            for expected in (b"first\nsecond\nfinal\n", b"body\n", b"auto\ndone\n", b"before\nlocked\n", b"ok\n"):
                status, headers, body = reader.response()
                wire.require(status == 200 and body == expected, "stream pipeline body or ordering changed")
                wire.require(b"x-late" not in headers, "published stream headers were mutable")
            payload = bytes(range(256)) * 2
            sock.sendall(request_bytes("/echo", method="POST", body=payload) + request_bytes("/ping"))
            wire.require(reader.response()[2] == payload, "request storage changed across a flush and sleep")
            wire.require(reader.response()[2] == b"ok\n", "stream input borrow damaged pipelined request bytes")
    passed("write, flush, sleep, empty flush, auto-finish and immutable headers", server)

    with StreamServer(binary) as server:
        with server.connect() as sock:
            reader = StreamReader(sock)
            for method, path in (("GET", "/known"), ("HEAD", "/known"), ("HEAD", "/stream")):
                sock.sendall(request_bytes(path, method=method) + request_bytes("/ping"))
                status, headers, body = reader.response(head=method == "HEAD")
                wire.require(status == 200, "known-length or HEAD stream failed")
                wire.require(body == (b"" if method == "HEAD" else b"first\nsecond\nfinal\n"),
                             "known-length or HEAD response body changed")
                if path == "/known":
                    wire.require(headers.get(b"content-length") == b"19" and b"transfer-encoding" not in headers,
                                 "known-length stream framing changed")
                wire.require(reader.response()[2] == b"ok\n", "HEAD leaked body bytes into the next response")
    passed("known-length and HEAD streams preserve the following response", server)

    with StreamServer(binary, response_body=1024, output_bytes=4096) as server:
        with server.connect() as sock:
            reader = StreamReader(sock)
            wire.require(exchange(sock, reader, "/large-write")[2] == b"s" * 1025,
                         "a write larger than staging did not drain and continue")
            sock.sendall(request_bytes("/fail-before") + request_bytes("/ping"))
            status, _, body = reader.response()
            wire.require(status == 500 and b"private" not in body, "private stream failure was published")
            wire.require(reader.response()[2] == b"ok\n", "private failure prevented connection reuse")
    passed("large writes drain bounded staging; private failures remain replaceable", server)

    with StreamServer(binary, connections=1, workers=1) as server:
        for path in ("/fail-after", "/short", "/long"):
            with server.connect() as sock:
                reader = StreamReader(sock)
                sock.sendall(request_bytes(path))
                status, headers = reader.head()
                wire.require(status == 200, "published failure lost its original status")
                if b"transfer-encoding" in headers:
                    wire.require(reader.chunk() == b"first\n", "published first chunk changed")
                else:
                    wire.require(reader._take(6) == b"first\n", "known-length prefix changed")
                reader.unfinished()
        wire.require(wire.request(server, request_bytes("/ping"))[2] == b"ok\n", "failed streams blocked slot reuse")
    passed("published errors and length mismatches close without a replacement response", server)

    with StreamServer(binary, connections=1, workers=1, response_body=1024, max_response=1024, output_bytes=4096) as server:
        with server.connect() as sock:
            reader = StreamReader(sock)
            sock.sendall(request_bytes("/cumulative-limit"))
            expect_chunked(reader)
            wire.require(reader.chunk() == b"b" * 512 and reader.chunk() == b"b" * 512,
                         "accepted cumulative prefix changed")
            reader.unfinished()
        wire.require(wire.request(server, request_bytes("/ping"))[2] == b"ok\n", "limit failure prevented slot reuse")
    passed("cumulative body bound spans repeated flushes", server)

    with StreamServer(binary, execution="inline", workers=0) as server:
        result = wire.request(server, request_bytes("/stream"))
        wire.require(result[0] == 500, "inline streaming did not reject worker-only I/O")
        wire.require(wire.request(server, request_bytes("/ping"))[2] == b"ok\n", "inline rejection damaged the I/O owner")
    passed("inline execution rejects streaming before publication", server)

    with StreamServer(binary, connections=2, timeout_ms=400) as server:
        with ExitStack() as clients:
            data, reader, control, control_reader = pair(server, clients)
            data.sendall(request_bytes("/sleep"))
            expect_chunked(reader)
            wire.require(reader.chunk() == b"sleeping\n", "sleep fixture did not publish its prefix")
            wait_state(control, control_reader, lambda value: value["sleep_started"] == 1)
            observed = wait_state(control, control_reader, lambda value: value["finished"] == 1)
            wire.require(observed["sleep_canceled"] == 1, "deadline did not cancel worker sleep")
            reader.unfinished()
            wire.require(wire.request(server, request_bytes("/ping"))[2] == b"ok\n", "deadline retained a dead slot")
    wire.require(server.stats["timeouts"] >= 1, "sleep did not retain the original request deadline")
    passed("request deadline cancels sleep and releases the callback borrow", server)

    with StreamServer(binary, connections=2, timeout_ms=1500, send_chunk=65536, socket_send_buffer=4096) as server:
        with ExitStack() as clients:
            data, reader, control, control_reader = pair(server, clients, small_window=True)
            data.sendall(request_bytes("/pressure"))
            expect_chunked(reader)
            wire.require(reader.chunk() == b"p" * 8192, "pressure prefix changed")
            server.observations["blocked_flush"] = await_backpressure(control, control_reader)
            observed = wait_state(control, control_reader, lambda value: value["finished"] == 1, timeout=2.0)
            check_canceled_flush(server, observed)
            wire.require(wire.request(server, request_bytes("/ping"))[2] == b"ok\n", "blocked send retained a dead slot")
    wire.require(server.stats["timeouts"] >= 1, "blocked flush escaped the original deadline")
    passed("stopped reader applies backpressure; deadline cancels the outstanding flush and permits slot reuse", server)

    for path, canceled_field in (("/sleep", "sleep_canceled"), ("/pressure", "flush_canceled")):
        with StreamServer(binary, connections=2, timeout_ms=1500, send_chunk=65536, socket_send_buffer=4096) as server:
            with ExitStack() as clients:
                data, reader, control, control_reader = pair(server, clients, small_window=path == "/pressure")
                data.sendall(request_bytes(path))
                expect_chunked(reader)
                wire.require(reader.chunk() == (b"sleeping\n" if path == "/sleep" else b"p" * 8192),
                             "disconnect fixture did not publish its prefix")
                if path == "/sleep":
                    wait_state(control, control_reader, lambda value: value["sleep_started"] == 1)
                else:
                    server.observations["blocked_flush"] = await_backpressure(control, control_reader)
                data.close()
                # With no receive pending, a sleeping handler can discover the
                # disconnect only at its original request deadline.
                observed = wait_state(control, control_reader, lambda value: value["finished"] == 1)
                wire.require(observed[canceled_field] == 1, "disconnect left an active streaming borrow")
                if path == "/pressure":
                    check_canceled_flush(server, observed)
                wire.require(wire.request(server, request_bytes("/ping"))[2] == b"ok\n", "disconnect prevented slot reuse")
        passed("peer disconnect releases " + ("sleep" if path == "/sleep" else "a blocked flush") + " within the request deadline", server)

    for path, canceled_field in (("/sleep", "sleep_canceled"), ("/pressure", "flush_canceled")):
        with ExitStack() as clients:
            with StreamServer(binary, timeout_ms=5000, send_chunk=65536, socket_send_buffer=4096) as server:
                data, reader, control, control_reader = pair(server, clients, small_window=path == "/pressure")
                data.sendall(request_bytes(path))
                expect_chunked(reader)
                wire.require(reader.chunk() == (b"sleeping\n" if path == "/sleep" else b"p" * 8192),
                             "shutdown fixture did not publish its prefix")
                if path == "/sleep":
                    wait_state(control, control_reader, lambda value: value["sleep_started"] == 1)
                else:
                    server.observations["blocked_flush"] = await_backpressure(control, control_reader)
                server.request_stop()
            wire.require(server.fixture[canceled_field] == 1, "shutdown did not cancel its active streaming operation")
            if path == "/pressure":
                check_canceled_flush(server, server.fixture)
        passed("shutdown cancels " + ("sleep" if path == "/sleep" else "a blocked flush") + " before storage release", server)

    if example is not None:
        with ExampleServer(example, workers=2) as server:
            wire.require(any("optimize=ReleaseSafe" in line for line in server.lines),
                         "streaming example gate requires a ReleaseSafe binary")
            with server.connect() as sock:
                reader = StreamReader(sock)
                sock.sendall(request_bytes("/"))
                headers = expect_chunked(reader)
                wire.require(headers.get(b"cache-control") == b"no-cache", "example cache header disappeared")
                for expected in ("Starting…\n".encode(), b"Completed step 1 of 2\n", b"Done.\n"):
                    wire.require(reader.chunk() == expected, "runnable example changed its flushed update")
                wire.require(reader.chunk() is None, "runnable example omitted final framing")
        wire.require(server.stats["flushes"] == 2 and server.stats["completed"] == 1,
                     "runnable example did not complete two flush barriers and one response")
        passed("runnable streaming example sends three framed updates", server)

    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", type=Path, default=wire.ROOT / "zig-out/bin/baz-streaming")
    parser.add_argument("--example", type=Path, default=wire.ROOT / "zig-out/bin/streaming")
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    cases = run(args.server.resolve(), args.example.resolve())
    result = dict(passed=len(cases), cases=cases, platform=platform.platform(),
                  optimize="ReleaseSafe", performance_comparison=False)
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
