#!/usr/bin/env python3
"""ReleaseSafe middleware order, request-local lifetime, and cleanup wire gates.

The caller holds the shared host reservation and supplies a process-tree watchdog.
All socket/state waits are finite. These are correctness checks, not benchmarks.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
import json
from pathlib import Path
import platform
import sys
import threading
import time

from app_integration import request_bytes
from streaming_integration import StreamReader
import wire_support as wire


EVENTS = dict(zip("IABCDHdcba4321Z", range(1, 16)), E=0)
NORMAL = "IABCDHdcba4321Z"
PLAIN = "IABHba21Z"
GLOBALS = "IABba21Z"


def encoded(trace):
    result = 0
    for event in trace:
        result = (result << 4) | EVENTS[event]
    return result


class MiddlewareServer(wire.Server):
    def __init__(self, binary, execution="inline", workers=0, connections=1):
        super().__init__(binary)
        self.options = dict(port=0, execution=execution, workers=workers, connections=connections, shards=1)
        self.hooks = None

    def __enter__(self):
        super().__enter__()
        try:
            wire.require(any("optimize=ReleaseSafe" in line for line in self.lines), "middleware gates require ReleaseSafe")
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise
        return self

    def __exit__(self, kind, value, tb):
        result = super().__exit__(kind, value, tb)
        if kind is None:
            receipts = [json.loads(line[6:]) for line in self.lines if line.startswith("HOOKS ")]
            wire.require(len(receipts) == 1, "missing or repeated middleware cleanup receipt")
            self.hooks = receipts[0]
            wire.require(self.hooks["initialized"] == self.hooks["locals_cleaned"], "initialized locals were not cleaned exactly once")
            wire.require(self.hooks["bad_address"] == 0, "locals moved while borrowed or the fixed trace overflowed")
        return result

    def connect(self, timeout=5.0):
        return super().connect(timeout=timeout)


def call(sock, reader, path, status=200, method="GET"):
    sock.sendall(request_bytes(path, method=method))
    response = reader.response(head=method == "HEAD")
    wire.require(response[0] == status, f"{method} {path}: expected {status}, got {response[0]} {response[2][:100]!r}")
    return response


def state(sock, reader, slot):
    return json.loads(call(sock, reader, f"/state?slot={slot}")[2])


def expect_record(sock, reader, slot, trace, count=1, handlers=None, afters=None, cleanups=None,
                  errors=None, cancelled=0, timeout=3.0):
    deadline = time.monotonic() + timeout
    observed = None
    while time.monotonic() < deadline:
        observed = state(sock, reader, slot)
        if observed["locals_cleaned"] >= count:
            break
        time.sleep(0.01)
    wire.require(observed is not None and observed["initialized"] == observed["locals_cleaned"] == count,
                 f"slot {slot} did not reconcile its locals exactly once: {observed}")
    wire.require(observed["trace"] == encoded(trace), f"slot {slot} hook order differs from {trace}: {observed}")
    wire.require(observed["cancelled"] == cancelled and observed["bad_address"] == 0, "locals cancellation/address accounting changed")
    for name, expected in (("handlers", handlers), ("afters", afters), ("cleanups", cleanups), ("errors", errors)):
        if expected is not None:
            wire.require(observed[name] == expected, f"slot {slot}: {name}={observed[name]}, expected {expected}")
    return observed


def payload(response, identity, value="", instance="plain", trace=NORMAL):
    wire.require(json.loads(response[2]) == dict(id=identity, value=value, sentinel=0x600D, instance=instance),
                 "handler lost its capture, initialized locals, or bound instance")
    before_cleanup = trace[:trace.find("4") if "4" in trace else trace.find("3") if "3" in trace else trace.find("2")]
    wire.require(response[1].get(b"x-trace") == f"{encoded(before_cleanup):x}".encode(), "after hooks ran out of order")


def ping(sock, reader):
    wire.require(call(sock, reader, "/ping")[2] == b"ok", "control request failed")


def fresh_ping(server, inspect=None):
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        try:
            with server.connect(timeout=0.3) as sock:
                reader = wire.ResponseReader(sock)
                ping(sock, reader)
                if inspect is not None:
                    inspect(sock, reader)
            return
        except (OSError, EOFError):
            time.sleep(0.02)
    raise AssertionError("the retired connection slot could not be reused")


def run(binary):
    cases = []

    def passed(name, server):
        cases.append(dict(name=name, backend=server.backend, options=server.options, stats=server.stats, hooks=server.hooks))
        print("PASS " + name, flush=True)

    for execution, workers in (("inline", 0), ("workers", 1)):
        with MiddlewareServer(binary, execution, workers) as server:
            with server.connect() as sock:
                reader = wire.ResponseReader(sock)
                routes = (("normal", "plain", NORMAL), ("plain", "plain", PLAIN),
                          ("bound", "bound", NORMAL), ("endpoint", "endpoint", NORMAL),
                          ("after-only", "plain", "IABHcba321Z"))
                for slot, (route, instance, trace) in enumerate(routes):
                    response = call(sock, reader, f"/{route}/item?slot={slot}&value=kept")
                    payload(response, "item", "kept", instance, trace)
                    expect_record(sock, reader, slot, trace, handlers=1, errors=0)
                original = call(sock, reader, "/normal/head?slot=5")
                payload(original, "head")
                head = call(sock, reader, "/normal/head?slot=5", method="HEAD")
                wire.require(head[2] == b"" and head[1].get(b"content-length") == str(len(original[2])).encode(), "HEAD lost the handler's representation length")
                ping(sock, reader)
                expect_record(sock, reader, 5, NORMAL, count=2, handlers=2, afters=8, cleanups=8, errors=0)
        passed("copied descriptors, route/bound/endpoint hooks, after-only hooks and HEAD in " + execution, server)

        with MiddlewareServer(binary, execution, workers) as server:
            with server.connect() as sock:
                reader = wire.ResponseReader(sock)
                global_response = call(sock, reader, "/early-global/hidden?slot=1")
                wire.require(global_response[2] == b"global response", "global early response did not stop routing")
                expect_record(sock, reader, 1, "IAa1Z", handlers=0, afters=1, cleanups=1, errors=0)
                route_response = call(sock, reader, "/early-route/captured?slot=2")
                wire.require(route_response[2] == b"captured", "route middleware did not see its raw capture")
                expect_record(sock, reader, 2, "IABCcba321Z", handlers=0, afters=3, cleanups=3, errors=0)
                for slot, (path, method, status) in enumerate((("/missing", "GET", 404), ("/normal/id", "POST", 405), ("/normal/id", "OPTIONS", 204)), 3):
                    response = call(sock, reader, f"{path}?slot={slot}", status=status, method=method)
                    wire.require(response[1].get(b"x-trace") == f"{encoded('IABba'):x}".encode(), "global hooks missed a routing-generated response")
                    expect_record(sock, reader, slot, GLOBALS, handlers=0, afters=2, cleanups=2, errors=0)
                call(sock, reader, "*", status=204, method="OPTIONS")
                expect_record(sock, reader, 0, GLOBALS, handlers=0, afters=2, cleanups=2, errors=0)
        passed("early decisions and globals on404/405/OPTIONS without route leakage in " + execution, server)

        with MiddlewareServer(binary, execution, workers) as server:
            with server.connect() as sock:
                reader = wire.ResponseReader(sock)
                probes = (("init-error", "InitFailed", "IEZ", 0, 0, 0),
                          ("init-body", "InvalidMiddlewareResponse", "IEZ", 0, 0, 0),
                          ("before-error", "BeforeFailed", "IAE1Z", 0, 0, 1),
                          ("respond-empty", "InvalidMiddlewareResponse", "IAE1Z", 0, 0, 1),
                          ("continue-body", "InvalidMiddlewareResponse", "IAE1Z", 0, 0, 1),
                          ("route-before-error", "RouteBeforeFailed", "IABCE321Z", 0, 0, 3),
                          ("handler-error", "HandlerFailed", "IABCDHE4321Z", 1, 0, 4),
                          ("after-error", "AfterFailed", "IABCDHdE4321Z", 1, 1, 4),
                          ("global-after-error", "GlobalAfterFailed", "IABCDHdcbE4321Z", 1, 3, 4),
                          ("early-route-after-error", "EarlyAfterFailed", "IABCcE321Z", 0, 1, 3))
                for slot, (route, error, trace, handlers, afters, cleanups) in enumerate(probes):
                    result = call(sock, reader, f"/{route}/id?slot={slot}", status=500)
                    wire.require(result[2] == error.encode() and result[1].get(b"x-error-locals") == b"retained", "error mapper lost initialized locals or the originating error")
                    wire.require(b"x-trace" not in result[1], "private error response retained a discarded header")
                    expect_record(sock, reader, slot, trace, handlers=handlers, afters=afters, cleanups=cleanups, errors=1)
                    ping(sock, reader)
        passed("initializer/before/handler/after errors skip remaining work and clean entered hooks in " + execution, server)

        with MiddlewareServer(binary, execution, workers) as server:
            with server.connect() as sock:
                reader = wire.ResponseReader(sock)
                requests = [("normal", "long-secret"), ("plain", ""), ("normal", "x"), ("plain", "")]
                sock.sendall(b"".join(request_bytes(f"/{route}/next?slot=0&value={value}") for route, value in requests))
                for route, value in requests:
                    result = reader.response()
                    wire.require(result[0] == 200, "pipelined middleware request failed")
                    payload(result, "next", value, trace=NORMAL if route == "normal" else PLAIN)
                expect_record(sock, reader, 0, PLAIN, count=4, handlers=4, afters=12, cleanups=12, errors=0)
        passed("pipelined requests reset typed defaults and do not inherit route hooks or scratch in " + execution, server)

        with MiddlewareServer(binary, execution, 4 if workers else 0, connections=4) as server:
            ready = threading.Barrier(4)

            def client(number):
                with server.connect() as sock:
                    reader = wire.ResponseReader(sock)
                    ready.wait(timeout=5)
                    for batch in range(4):
                        entries = [(16 + number * 8 + batch * 2 + item, f"client{number}-{batch}-{item}") for item in range(2)]
                        sock.sendall(b"".join(request_bytes(f"/normal/{name}?slot={slot}&value={name}") for slot, name in entries))
                        for slot, name in entries:
                            result = reader.response()
                            wire.require(result[0] == 200, "concurrent middleware response failed")
                            payload(result, name, name)
                        for slot, _ in entries:
                            expect_record(sock, reader, slot, NORMAL, handlers=1, afters=4, cleanups=4, errors=0)

            with ThreadPoolExecutor(max_workers=4) as pool:
                futures = [pool.submit(client, number) for number in range(4)]
                for future in futures:
                    future.result(timeout=30)
        wire.require(server.hooks["initialized"] == 32, "concurrent requests lost or replayed local initialization")
        passed("four clients retain isolated locals and exactly-once cleanup in " + execution, server)

    with MiddlewareServer(binary, "workers", 1) as server:
        with server.connect() as sock:
            reader = StreamReader(sock)
            result = call(sock, reader, "/stream/id?slot=0&value=retained")
            wire.require(result[2] == b"first\nlast:retained\n" and result[1].get(b"transfer-encoding") == b"chunked", "locals or streaming output changed across flush")
            expect_record(sock, reader, 0, NORMAL, handlers=1, afters=4, cleanups=4, errors=0)
            ping(sock, reader)
    passed("successful stream retains local storage through flush, after hooks and cleanup", server)

    with MiddlewareServer(binary, "workers", 1) as server:
        with server.connect() as sock:
            reader = StreamReader(sock)
            sock.sendall(request_bytes("/stream-after-error/id?slot=0"))
            status, headers = reader.head()
            wire.require(status == 200 and b"x-too-late" not in headers and reader.chunk() == b"first\n", "published stream head or first chunk changed")
            reader.unfinished()
        fresh_ping(server, lambda sock, reader: expect_record(sock, reader, 0, "IABCDHd4321Z", handlers=1, afters=1, cleanups=4, errors=0))
    passed("after-header mutation closes a published stream and releases its only slot", server)

    for cause in ("deadline", "peer", "shutdown"):
        with ExitStack() as clients:
            with MiddlewareServer(binary, "workers", 2, connections=2) as server:
                data = clients.enter_context(server.connect())
                stream_reader = StreamReader(data)
                control = clients.enter_context(server.connect())
                control_reader = wire.ResponseReader(control)
                ping(control, control_reader)
                data.sendall(request_bytes("/stream-sleep/id?slot=0&value=borrowed"))
                status, _ = stream_reader.head()
                wire.require(status == 200 and stream_reader.chunk() == b"first\n", "cancelable stream did not publish its first chunk")
                deadline = time.monotonic() + 2
                pending = None
                while time.monotonic() < deadline:
                    pending = state(control, control_reader, 0)
                    if pending["sleeping"] == 1:
                        break
                    time.sleep(0.01)
                wire.require(pending["sleeping"] == 1 and pending["initialized"] == 1 and pending["locals_cleaned"] == 0,
                             "stream locals ended before the held handler was canceled")
                if cause == "shutdown":
                    server.request_stop()
                else:
                    if cause == "peer":
                        data.close()
                    expect_record(control, control_reader, 0, "IABCDH4321Z", handlers=1, afters=0, cleanups=4, errors=0, cancelled=1)
                    if cause == "deadline":
                        stream_reader.unfinished()
                    # The admitted control socket occupies the other slot.
                    fresh_ping(server)
            wire.require(server.hooks["initialized"] == server.hooks["locals_cleaned"] == server.hooks["cancelled"] == 1 and
                         server.hooks["cleanups"] == 4 and server.hooks["afters"] == 0, "stream cancellation duplicated or omitted cleanup")
        label = "request deadline" if cause == "deadline" else "peer close reconciled within the request deadline" if cause == "peer" else "shutdown"
        passed(label + " reconciles all entered middleware and local storage", server)

    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=wire.ROOT / "zig-out/bin/baz-middleware")
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    cases = run(args.binary.resolve())
    result = dict(passed=len(cases), cases=cases, platform=platform.platform(), python=sys.version)
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
