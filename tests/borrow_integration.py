#!/usr/bin/env python3
"""Finite ReleaseSafe wire gates for a startup-owned 5 MiB borrowed asset.

The caller supplies the shared host reservation and an overall process-tree
watchdog. These tests check correctness, not performance. The copy counters cover
the named framework operations only; they do not measure all memory or OS copies.
"""

import argparse
from contextlib import ExitStack
import hashlib
import json
from pathlib import Path
import platform
import socket
import time

from app_integration import request_bytes
import wire_support as wire


PATTERN = b"\x00\x01\x7f\x80\xffBAZ\r\nasset!"
ASSET_SIZE = 5 * 1024 * 1024
ASSET = PATTERN * (ASSET_SIZE // len(PATTERN))
ASSET_SHA256 = hashlib.sha256(ASSET).hexdigest()
CLIENT_LIMIT = ASSET_SIZE + 65536


class BorrowServer(wire.Server):
    def __init__(self, binary, **options):
        super().__init__(binary)
        self.options = dict(port=0, execution="workers", workers=1, connections=1,
                            shards=1, max_body=1024, max_header=2048,
                            output_bytes=4096, response_body=1024,
                            max_response=6 * 1024 * 1024, timeout_ms=15000,
                            shutdown_ms=3000, send_chunk=65536,
                            socket_send_buffer=65536)
        self.options.update(options)
        self.control_responses = 0
        self.observations = {}

    def connect(self, timeout=10.0):
        return super().connect(timeout=timeout)

    def __enter__(self):
        super().__enter__()
        try:
            wire.require(any("optimize=ReleaseSafe" in line for line in self.lines),
                         "borrowed-body wire gates require a ReleaseSafe binary")
        except BaseException:
            import sys
            self.__exit__(*sys.exc_info())
            raise
        return self


def reader_for(sock):
    # The common reader defaults to 4 MiB. This fixture needs a larger bound.
    return wire.ResponseReader(sock, maximum=CLIENT_LIMIT)


def asset_head(reader):
    # Parse only the head now, including for GET. The caller reads the body later.
    status, headers, body = reader.response(head=True)
    wire.require(status == 200 and body == b"", "large borrowed response did not start with 200")
    wire.require(headers.get(b"content-length") == str(ASSET_SIZE).encode(), "borrowed body length changed")
    wire.require(headers.get(b"content-type") == b"application/octet-stream", "borrowed content type changed")
    wire.require(b"transfer-encoding" not in headers, "one-shot borrowed asset became chunked")
    return headers


def validate_body(body):
    wire.require(len(body) == ASSET_SIZE, "borrowed asset was truncated")
    wire.require(hashlib.sha256(body).hexdigest() == ASSET_SHA256, "borrowed asset digest changed")
    wire.require(body == ASSET, "borrowed binary bytes changed")


def empty_response(server, sock, reader, path="/ping"):
    sock.sendall(request_bytes(path))
    status, headers, body = reader.response()
    wire.require(status == 204 and body == b"", "control response failed")
    server.control_responses += 1
    return headers


def query_state(server, sock, reader):
    headers = empty_response(server, sock, reader, "/state")
    return dict(asset_requests=int(headers[b"x-asset-requests"]), markers=int(headers[b"x-markers"]))


def check_copy_counters(server):
    wire.require(server.stats["borrow_copies"] == 0, "large asset entered the small-borrow copy path")
    wire.require(server.stats["response_draft_copy_bytes"] == 0, "borrowed payload entered draft-body compaction")


def pending_asset(server, clients):
    data = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    clients.callback(data.close)
    data.settimeout(10.0)
    data.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
    data.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    data.connect(("127.0.0.1", server.port))
    reader = reader_for(data)
    empty_response(server, data, reader)
    control = clients.enter_context(server.connect())
    control_reader = reader_for(control)
    wire.require(query_state(server, control, control_reader) == dict(asset_requests=0, markers=0),
                 "fixture did not start from empty counters")
    data.sendall(request_bytes("/asset") + request_bytes("/marker"))
    asset_head(reader)
    prefix = reader._take(256)
    wire.require(prefix == ASSET[:256], "pending asset prefix changed")
    observations = []
    for _ in range(4):
        observed = query_state(server, control, control_reader)
        wire.require(observed == dict(asset_requests=1, markers=0),
                     "the pipelined marker ran before the stopped reader released the asset")
        observations.append(observed)
        time.sleep(0.03)
    server.observations["stopped_reader_controls"] = observations
    return data, reader, prefix, control, control_reader


def await_slot_reuse(server, control, reader):
    # Both slots are admitted. Only the canceled asset slot can admit this ping.
    deadline = time.monotonic() + 3.0
    attempts = 0
    while time.monotonic() < deadline:
        wire.require(query_state(server, control, reader) == dict(asset_requests=1, markers=0),
                     "cancellation dispatched the asset's pipelined marker")
        attempts += 1
        try:
            with server.connect(timeout=0.2) as probe:
                empty_response(server, probe, reader_for(probe))
            server.observations["reuse_attempts"] = attempts
            return
        except (EOFError, OSError):
            time.sleep(0.03)
    raise AssertionError("the canceled asset slot did not become reusable")


def canceled_counters(server, needs_cancel_request):
    check_copy_counters(server)
    wire.require(0 < server.stats["bytes_sent"] < ASSET_SIZE,
                 "cancellation did not interrupt an incomplete large response")
    wire.require(server.stats["completed"] == server.control_responses,
                 "the canceled asset or its marker completed unexpectedly")
    if needs_cancel_request:
        wire.require(server.stats["gather_cancel_requests"] >= 1,
                     "the gate did not cancel a pending gather send")
    # A cancellation request can race with an ordinary terminal send result.
    # A positive gather_canceled_completions count is therefore not required.


def run(binary):
    cases = []

    def passed(name, server, copy_counters=False):
        if copy_counters:
            check_copy_counters(server)
        cases.append(dict(name=name, backend=server.backend, options=server.options,
                          stats=server.stats, observations=server.observations,
                          copy_counter_scope="small-borrow copies and draft-body compaction only" if copy_counters else None))
        print("PASS " + name, flush=True)

    for execution, workers in (("inline", 0), ("workers", 1)):
        with BorrowServer(binary, execution=execution, workers=workers) as server:
            with server.connect() as sock:
                reader = reader_for(sock)
                sock.sendall(request_bytes("/asset"))
                asset_head(reader)
                validate_body(reader._take(ASSET_SIZE))
                sock.sendall(request_bytes("/asset", method="HEAD") + request_bytes("/ping"))
                asset_head(reader)
                status, _, body = reader.response()
                wire.require(status == 204 and body == b"", "HEAD emitted asset bytes before the next response")
        wire.require(server.stats["completed"] == 3, "GET, HEAD and following response did not complete")
        passed("5 MiB exact binary body and HEAD with a 4 KiB arena in " + execution, server, True)

    with BorrowServer(binary, send_chunk=997) as server:
        with server.connect() as sock:
            reader = reader_for(sock)
            sock.sendall(request_bytes("/asset"))
            asset_head(reader)
            validate_body(reader._take(ASSET_SIZE))
    wire.require(server.stats["send_completions"] >= (ASSET_SIZE + 996) // 997,
                 "the configured send cap did not force repeated send progress")
    # This cap forces submission boundaries, not kernel short completions.
    passed("large borrowed body survives 997-byte send submissions", server, True)

    with BorrowServer(binary, connections=2, workers=2, socket_send_buffer=4096) as server:
        with ExitStack() as clients:
            data, reader, prefix, control, control_reader = pending_asset(server, clients)
            data.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 262144)
            validate_body(prefix + reader._take(ASSET_SIZE - len(prefix)))
            status, _, body = reader.response()
            wire.require(status == 204 and body == b"", "pipelined marker did not follow the complete asset")
            wire.require(query_state(server, control, control_reader) == dict(asset_requests=1, markers=1),
                         "drained asset did not release the queued marker")
    wire.require(server.stats["completed"] == server.control_responses + 2,
                 "backpressure replayed or omitted a response")
    passed("stopped reader retains the borrowed asset until reading resumes", server, True)

    with BorrowServer(binary) as server:
        with server.connect() as sock:
            reader = reader_for(sock)
            sock.sendall(request_bytes("/copied") + request_bytes("/ping"))
            status, _, body = reader.response()
            wire.require(status == 500 and len(body) < 1024, "copied bodies escaped the 1 KiB staging bound")
            wire.require(reader.response()[0] == 204, "copied-body rejection prevented connection reuse")
    passed("copied bodies retain their staging limit", server)

    with BorrowServer(binary, max_response=4 * 1024 * 1024) as server:
        with server.connect() as sock:
            reader = reader_for(sock)
            sock.sendall(request_bytes("/asset") + request_bytes("/ping"))
            status, headers, body = reader.response()
            wire.require(status == 500 and len(body) < 1024 and b"x-asset" not in headers,
                         "oversized borrowed body was published instead of rejected privately")
            wire.require(reader.response()[0] == 204, "borrowed total-limit rejection prevented connection reuse")
    passed("borrowed bodies obey the separate server total limit", server)

    with BorrowServer(binary, connections=2, workers=2, socket_send_buffer=4096, timeout_ms=1200) as server:
        with ExitStack() as clients:
            _, _, _, control, control_reader = pending_asset(server, clients)
            await_slot_reuse(server, control, control_reader)
    wire.require(server.stats["timeouts"] >= 1, "pending borrowed body escaped its request deadline")
    canceled_counters(server, True)
    passed("deadline cancels a pending borrowed send and releases its exact slot", server, True)

    with BorrowServer(binary, connections=2, workers=2, socket_send_buffer=4096, timeout_ms=1200) as server:
        with ExitStack() as clients:
            data, _, _, control, control_reader = pending_asset(server, clients)
            data.close()
            await_slot_reuse(server, control, control_reader)
    canceled_counters(server, False)
    passed("peer disconnect reconciles the pending borrow within the request deadline before exact slot reuse", server, True)

    with ExitStack() as clients:
        with BorrowServer(binary, connections=2, workers=2, socket_send_buffer=4096) as server:
            pending_asset(server, clients)
            server.request_stop()
        canceled_counters(server, True)
    passed("shutdown reconciles the pending borrowed send before storage release", server, True)
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", type=Path, default=wire.ROOT / "zig-out/bin/baz-borrow")
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    cases = run(args.server.resolve())
    result = dict(passed=len(cases), cases=cases, platform=platform.platform(),
                  optimize="ReleaseSafe", performance_comparison=False,
                  asset=dict(bytes=ASSET_SIZE, sha256=ASSET_SHA256, client_maximum=CLIENT_LIMIT))
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
