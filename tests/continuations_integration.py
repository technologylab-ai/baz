#!/usr/bin/env python3
"""ReleaseSafe typed continuation, bounded waiting, and terminal cleanup gates.

The caller reserves the host and supplies a process-tree watchdog. Client sockets,
state polling, timers, and shutdown waits have finite limits. These are correctness
checks; the suite makes no throughput or latency claims.
"""

import argparse
from contextlib import ExitStack
import json
from pathlib import Path
import platform
import sys
import time

from app_integration import request_bytes
from streaming_integration import StreamReader
import wire_support as wire


class ContinuationServer(wire.Server):
    def __init__(self, binary, execution, workers):
        super().__init__(binary)
        self.options = dict(port=0, execution=execution, workers=workers, connections=64, shards=1)
        self.continuations = None

    def __enter__(self):
        super().__enter__()
        try:
            wire.require(any("optimize=ReleaseSafe" in line for line in self.lines), "continuation gates require ReleaseSafe")
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise
        return self

    def __exit__(self, kind, value, tb):
        result = super().__exit__(kind, value, tb)
        if kind is None:
            receipts = [json.loads(line[14:]) for line in self.lines if line.startswith("CONTINUATIONS ")]
            wire.require(len(receipts) == 1, "missing or repeated continuation ownership receipt")
            self.continuations = receipts[0]
            wire.require(self.continuations["initialized"] == self.continuations["locals_cleaned"],
                         "a continuation retained request locals at shutdown")
            wire.require(self.continuations["initialized"] == self.continuations["state_cleaned"],
                         "a continuation failed to destroy its state exactly once")
            wire.require(self.continuations["before"] == self.continuations["cleaned"],
                         "entered continuation middleware did not clean up exactly once")
            wire.require(self.continuations["bad_address"] == 0, "locals or continuation state moved while retained")
        return result

    def connect(self, timeout=5):
        return super().connect(timeout=timeout)


def call(sock, reader, path, status=200, method="GET"):
    sock.sendall(request_bytes(path, method=method))
    response = reader.response(head=method == "HEAD")
    wire.require(response[0] == status, f"{method} {path}: expected {status}, got {response[0]} {response[2][:100]!r}")
    return response


def ping(sock, reader):
    wire.require(call(sock, reader, "/ping")[2] == b"ok", "a waiting continuation retained the callback thread")


def state(sock, reader, slot):
    return json.loads(call(sock, reader, f"/state?slot={slot}")[2])


def wait_state(sock, reader, slot, predicate, timeout=5):
    deadline = time.monotonic() + timeout
    observed = None
    while time.monotonic() < deadline:
        observed = state(sock, reader, slot)
        if predicate(observed):
            return observed
        time.sleep(0.01)
    raise AssertionError(f"continuation slot {slot} did not reach its condition: {observed}")


def reconciled(sock, reader, slot, count=1):
    observed = wait_state(sock, reader, slot, lambda value: value["locals_cleaned"] >= count
                          and value["initialized"] >= count and value["cleaned"] >= count)
    wire.require(observed["initialized"] == observed["locals_cleaned"] == count,
                 f"locals did not initialize and clean up exactly once: {observed}")
    wire.require(observed["before"] == observed["cleaned"] == count and observed["bad_address"] == 0,
                 f"middleware cleanup or retained addresses changed: {observed}")
    wire.require(observed["state_cleaned"] == count, f"state destruction did not run exactly once: {observed}")
    return observed


def begin_hold(sock, slot):
    sock.sendall(request_bytes(f"/events?slot={slot}&mode=hold"))
    reader = StreamReader(sock)
    status, headers = reader.head()
    wire.require(status == 200 and headers.get(b"transfer-encoding") == b"chunked", "hold stream framing changed")
    wire.require(reader.chunk() == b"first\n", "hold stream did not publish its first snapshot")
    return reader


def normal(sock, reader, slot):
    response = call(sock, reader, f"/events?slot={slot}")
    wire.require(response[2] == b"first\nsecond\nthird\n", "continuation response bytes changed")
    return response


def run(binary):
    cases = []

    def passed(name, server):
        cases.append(dict(name=name, backend=server.backend, options=server.options,
                          stats=server.stats, continuations=server.continuations))
        print("PASS " + name, flush=True)

    for execution, workers in (("inline", 0), ("workers", 1)):
        with ContinuationServer(binary, execution, workers) as server:
            with server.connect() as sock:
                sock.sendall(request_bytes("/stream"))
                reader = StreamReader(sock)
                status, headers = reader.head()
                wire.require(status == 200 and headers.get(b"transfer-encoding") == b"chunked", "public example is not chunked")
                wire.require(reader.chunk() == "Starting…\n".encode(), "first public snapshot changed")
                wire.require(reader.chunk() == b"Completed step 1 of 2\n", "timer update changed")
                wire.require(reader.chunk() == b"Done.\n" and reader.chunk() is None, "final snapshot or terminator changed")
                ping(sock, reader)
        passed("public example flushes three snapshots and preserves keep-alive in " + execution, server)

        with ContinuationServer(binary, execution, workers) as server:
            with server.connect() as sock:
                reader = StreamReader(sock)
                normal(sock, reader, 0)
                observed = reconciled(sock, reader, 0)
                wire.require(observed["starts"] == observed["after"] == 1 and observed["resumes"] == 4
                             and observed["flushed"] == observed["timers"] == 2,
                             f"normal continuation event sequence changed: {observed}")
                known = call(sock, reader, "/events?slot=1&mode=known")
                wire.require(known[2] == b"first\nsecond\nthird\n" and known[1].get(b"content-length") == b"19"
                             and b"transfer-encoding" not in known[1], "known-length snapshots changed wire framing")
                reconciled(sock, reader, 1)
                sock.sendall(request_bytes("/events?slot=2&mode=known", method="HEAD") + request_bytes("/ping"))
                head = reader.response(head=True)
                wire.require(head[0] == 200 and head[2] == b"" and head[1].get(b"content-length") == b"19",
                             "HEAD lost its representation metadata")
                wire.require(reader.response()[2] == b"ok", "HEAD emitted continuation body bytes into the pipeline")
                reconciled(sock, reader, 2)
        passed("typed events, stable state/locals, known lengths and HEAD pipeline framing in " + execution, server)

        with ContinuationServer(binary, execution, workers) as server:
            with server.connect() as sock:
                reader = StreamReader(sock)
                sock.sendall(request_bytes("/ping") + request_bytes("/events?slot=0&mode=wait_first") + request_bytes("/ping"))
                first = reader.response()
                wire.require(first[0] == 200 and first[2] == b"ok", "initial response did not precede the waiting continuation")
                delayed = reader.response()
                wire.require(delayed[0] == 200 and delayed[2] == b"after timer\n", "first timer could not prepare the response")
                wire.require(delayed[1].get(b"x-wait") == b"retained", "initial-wait arena rebasing lost private response headers")
                final = reader.response()
                wire.require(final[0] == 200 and final[2] == b"ok", "queued request overtook a waiting continuation")
                observed = reconciled(sock, reader, 0)
                wire.require(observed["starts"] == observed["timers"] == observed["resumes"] == observed["after"] == 1
                             and observed["flushed"] == 0, "wait-before-first dispatched extra callbacks")
        passed("a timer can precede first publication without losing pipelined requests in " + execution, server)

        with ContinuationServer(binary, execution, workers) as server:
            with server.connect() as control:
                inspect = StreamReader(control)
                with ExitStack() as waiters:
                    for slot in range(32):
                        begin_hold(waiters.enter_context(server.connect()), slot)
                    ping(control, inspect)
                    for slot in range(32):
                        observed = state(control, inspect, slot)
                        wire.require(observed["starts"] == 1 and observed["locals_cleaned"] == observed["after"] == 0,
                                     "a waiting continuation completed before capacity inspection")
                    rejected = call(control, inspect, "/events?slot=32&mode=hold", status=503)
                    wire.require(b"first" not in rejected[2], "continuation admission overflow ran the handler")
                    ping(control, inspect)
                for slot in range(32):
                    observed = reconciled(control, inspect, slot)
                    wire.require(observed["after"] == 0, "cancelled wait ran success-only after hooks")
                normal(control, inspect, 0)
                reconciled(control, inspect, 0, count=2)
        passed("32 parked continuations release one callback thread, reject overflow, and reclaim capacity in " + execution, server)

        with ContinuationServer(binary, execution, workers) as server:
            with server.connect() as sock:
                reader = StreamReader(sock)
                for slot, mode in enumerate(("error_before", "staged_wait")):
                    response = call(sock, reader, f"/events?slot={slot}&mode={mode}", status=500)
                    wire.require(response[2] == b"Continuation failed" and b"transfer-encoding" not in response[1],
                                 "unpublished continuation bytes escaped error rollback")
                    observed = reconciled(sock, reader, slot)
                    wire.require(observed["errors"] == 1 and observed["after"] == 0, "draft failure bypassed its mapper or cleanup")
                    normal(sock, reader, slot)
                    reconciled(sock, reader, slot, count=2)
                    ping(sock, reader)
        passed("unpublished errors and staged-body waits roll back without losing slot reuse in " + execution, server)

        with ContinuationServer(binary, execution, workers) as server:
            with server.connect() as sock:
                reader = StreamReader(sock)
                for slot, mode in enumerate(("forbidden_state", "forbidden_locals", "mapper_borrow")):
                    response = call(sock, reader, f"/events?slot={slot}&mode={mode}", status=500)
                    if mode == "mapper_borrow":
                        wire.require(b"LLLL" not in response[2] and len(response[2]) < 512,
                                     "the error mapper published its borrowed request-local payload")
                    else:
                        wire.require(response[2] == b"Continuation failed", "response borrowed retained application storage after its destruction")
                    observed = reconciled(sock, reader, slot)
                    wire.require(observed["starts"] == observed["errors"] == 1, "forbidden borrow bypassed its handler or error mapper")
                    normal(sock, reader, slot)
                    reconciled(sock, reader, slot, count=2)
                for slot, mode in ((3, "init_error"), (4, "before_error")):
                    call(sock, reader, f"/events?slot={slot}&mode={mode}", status=500)
                    observed = wait_state(sock, reader, slot, lambda value: value["locals_cleaned"] == 1)
                    wire.require(observed["initialized"] == observed["state_cleaned"] == observed["locals_cleaned"] == 1
                                 and observed["starts"] == observed["after"] == observed["bad_address"] == 0
                                 and observed["errors"] == 1, "initializer/before error lost default state destruction or valid locals")
                    expected_before = int(mode == "before_error")
                    wire.require(observed["before"] == observed["cleaned"] == expected_before,
                                 "failed initialization cleaned middleware that never entered")
                ping(sock, reader)
        passed("state destruction precedes locals cleanup and retained-storage borrows are rejected in " + execution, server)

        with ContinuationServer(binary, execution, workers) as server:
            with server.connect() as control:
                inspect = StreamReader(control)
                with server.connect() as sock:
                    reader = StreamReader(sock)
                    sock.sendall(request_bytes("/events?slot=0&mode=error_after"))
                    wire.require(reader.head()[0] == 200 and reader.chunk() == b"first\n", "published failure lost the first snapshot")
                    reader.unfinished()
                observed = reconciled(control, inspect, 0)
                wire.require(observed["after"] == observed["errors"] == 0,
                             "published failure ran success hooks or attempted a replacement response")
                normal(control, inspect, 0)
                reconciled(control, inspect, 0, count=2)
        passed("errors after publication close the stream without a replacement response in " + execution, server)

        with ContinuationServer(binary, execution, workers) as server:
            with server.connect() as control:
                inspect = StreamReader(control)
                for slot, mode in enumerate(("hold", "wait_hold")):
                    with server.connect() as sock:
                        if mode == "hold":
                            begin_hold(sock, slot)
                        else:
                            sock.sendall(request_bytes(f"/events?slot={slot}&mode=wait_hold"))
                        wait_state(control, inspect, slot, lambda value: value["starts"] == 1)
                    observed = reconciled(control, inspect, slot)
                    wire.require(observed["after"] == 0, "disconnected request ran success hooks")
                    normal(control, inspect, slot)
                    reconciled(control, inspect, slot, count=2)
        passed("disconnect before and after publication releases retained state exactly once in " + execution, server)

        with ContinuationServer(binary, execution, workers) as server:
            with server.connect() as sock:
                reader = begin_hold(sock, 0)
                reader.unfinished()  # The 3-second request deadline precedes the 10-second timer.
            # The earlier control connection would expire while idle at the same deadline.
            with server.connect() as control:
                inspect = StreamReader(control)
                observed = reconciled(control, inspect, 0)
                wire.require(observed["timers"] == observed["after"] == 0, "timed-out wait resumed or ran success hooks")
                normal(control, inspect, 0)
                reconciled(control, inspect, 0, count=2)
        passed("request deadlines cancel parked streams and release their continuation slot in " + execution, server)

        with ContinuationServer(binary, execution, workers) as server:
            with ExitStack() as sockets:
                control = sockets.enter_context(server.connect())
                inspect = StreamReader(control)
                published = sockets.enter_context(server.connect())
                reader = begin_hold(published, 0)
                unpublished = sockets.enter_context(server.connect())
                unpublished.sendall(request_bytes("/events?slot=1&mode=wait_hold"))
                wait_state(control, inspect, 1, lambda value: value["starts"] == 1)
                server.request_stop()
                wire.require(server.process.wait(timeout=5) == 0, "shutdown retained a parked continuation")
                reader.unfinished()
                wire.expect_closed(unpublished)
        passed("shutdown retires published and unpublished waits before shared storage is released in " + execution, server)

    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=wire.ROOT / "zig-out/bin/continuations")
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
