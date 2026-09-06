#!/usr/bin/env python3
"""Finite native Windows checks for Baz over the engine's socket handoff path.

The normal App and example suites cover the public API with one owner.
These cases add multiple owners, borrowed pipelines, and console shutdown.
Aggregate handoff counters prove transfers, not per-owner distribution.
The caller must supply an external process-tree watchdog.
"""

import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import platform
import sys

from app_integration import AppServer, request_bytes
import wire_support as wire


class WindowsServer(AppServer):
    def __enter__(self):
        super().__enter__()
        try:
            wire.require(self.backend == "iocp", "the native Windows IOCP backend is required")
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise
        return self


def record(server, name):
    wire.require(server.stats["shards"] == server.options["shards"], "configured owner count changed")
    wire.require(server.stats["worker_dispatches"] == 0, "inline callbacks unexpectedly used workers")
    wire.require(server.stats["handoffs_sent"] > 0, "the socket handoff path was not exercised")
    print("PASS " + name, flush=True)
    return dict(name=name, backend=server.backend, options=server.options, stats=server.stats)


def run(binary):
    cases = []
    for shards in (2, 3):
        with ExitStack() as clients:
            with WindowsServer(binary, shards=shards, timeout_ms=6000) as server:
                sockets = [clients.enter_context(server.connect()) for _ in range(6)]
                readers = [wire.ResponseReader(sock) for sock in sockets]
                expected = []
                for index, sock in enumerate(sockets):
                    payload = bytes([index]) + bytes(range(256)) * 3
                    expected.append(payload)
                    sock.sendall(request_bytes("/borrow", method="POST", body=payload)
                                 + request_bytes("/count", method="POST")
                                 + request_bytes("/hello?name=raw+plus"))
                counts = set()
                for reader, payload in zip(readers, expected):
                    status, _, body = reader.response()
                    wire.require(status == 200 and body == payload, "borrowed binary response changed")
                    status, _, body = reader.response()
                    wire.require(status == 200, "count response failed")
                    counts.add(json.loads(body)["count"])
                    status, _, body = reader.response()
                    wire.require(status == 200 and body == b"raw+plus", "pipeline query response changed")
                wire.require(counts == set(range(1, 7)), "shared side effects were omitted or replayed")
                sockets[0].sendall(request_bytes("/count"))
                status, _, body = readers[0].response()
                wire.require(status == 200 and json.loads(body) == {"count": 6}, "final shared count changed")
            for sock in sockets:
                wire.expect_closed(sock)
        wire.require(server.stats["completed"] == 19, "pipeline completion count changed")
        cases.append(record(server, "borrowed pipelines and typed shared state with %d owners" % shards))

    with ExitStack() as clients:
        with WindowsServer(binary, shards=3, timeout_ms=6000) as server:
            sockets = [clients.enter_context(server.connect()) for _ in range(6)]
            for sock in sockets:
                # A complete acknowledgment establishes admission before the
                # next request leaves a receive pending on the same connection.
                sock.sendall(request_bytes("/hello?name=admitted"))
                status, _, body = wire.ResponseReader(sock).response()
                wire.require(status == 200 and body == b"admitted", "admission acknowledgment failed")
                sock.sendall(b"POST /borrow HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1024\r\n\r\npending")
            server.request_stop()
        for sock in sockets:
            wire.expect_closed(sock)
    wire.require(server.stats["completed"] == 6, "an incomplete request was dispatched")
    cases.append(record(server, "console shutdown with pending receives across three owners"))
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", type=Path, default=wire.ROOT / "zig-out/bin/baz.exe")
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("this suite requires native Windows; cross-compilation is not runtime evidence")
    cases = run(args.server.resolve())
    result = dict(passed=len(cases), cases=cases, platform=platform.platform(),
                  execution="native Windows IOCP", performance_comparison=False)
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
