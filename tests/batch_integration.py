#!/usr/bin/env python3
"""Bounded generic response batches: wire ordering, cell leases and cancellation.

Single writes do not prove a particular TCP read shape. Counters explicitly
witness batching; timing is only a watchdog, never a throughput measurement.
"""
import argparse
import contextlib
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import traceback

import integration as wire


class BatchServer(wire.Server):
    def __init__(self, binary, **options):
        options.setdefault("response_batch_limit", 16)
        options.setdefault("inline_callback_budget", 64)
        options.setdefault("send_chunk", 65536)
        super().__init__(binary, execution="inline", workers=0, **options)

    def __exit__(self, kind, value, tb):
        result = super().__exit__(kind, value, tb)
        if kind is None:
            wire.require(self.stats["worker_dispatches"] == 0, "unexpected worker dispatch")
            wire.require(self.stats["max_batch_responses"] <= self.options["response_batch_limit"], "response batch limit exceeded")
            budget = self.options["inline_callback_budget"]
            wire.require(self.stats["inline_callback_budget"] == budget, "configured callback budget not reported")
            wire.require(self.stats["max_inline_callbacks_per_turn"] <= budget, "global callback turn limit exceeded")
            wire.require(any(" inline_callback_budget=%d " % budget in line for line in self.lines if line.startswith("READY ")),
                         "READY omitted the configured callback budget")
        return result


def get(target, method=b"GET", close=False):
    return method + b" " + target + b" HTTP/1.1\r\nHost: localhost\r\n" + (b"Connection: close\r\n" if close else b"") + b"\r\n"


@contextlib.contextmanager
def paused(server):
    """Queue bounded loopback input before accept/recv without assuming packets.

    Observe the child stop with a one-second watchdog and always resume it,
    including when connect/send fails. Counter assertions remain the evidence
    that a full batch was actually frozen/submitted after resumption.
    """
    server.process.send_signal(signal.SIGSTOP)
    deadline = time.monotonic() + 1
    try:
        while time.monotonic() < deadline:
            pid, status = os.waitpid(server.process.pid, os.WNOHANG | os.WUNTRACED)
            if pid:
                wire.require(os.WIFSTOPPED(status), "server exited while preparing queued input")
                break
            time.sleep(0.001)
        else:
            raise TimeoutError("server stop acknowledgement deadline")
        yield
    finally:
        if server.process.poll() is None:
            server.process.send_signal(signal.SIGCONT)


def maximum_cells(binary, emit, sessions):
    # A nonempty chunked finish owns header, chunk-size, body, CRLF and final
    # chunk spans. Both output ownership forms must reach the native sendmsg
    # path with 64 * 5 descriptors; sizeof/compilation alone is insufficient.
    for kind in ("generated", "borrowed_body"):
        for cap in (65536, 23):
            with BatchServer(binary, response_batch_limit=64, inline_callback_budget=256,
                             max_body=32768, send_chunk=cap) as server:
                with contextlib.ExitStack() as stack:
                    expected, requests = [], []
                    for index in range(64):
                        if kind == "generated":
                            body = b"/buffered-chunked?cell=" + str(index).encode() + b"&value=" + b"x" * index
                            requests.append(get(body))
                        else:
                            body = index.to_bytes(2, "big") + bytes([index]) * (index + 1)
                            requests.append(b"POST /borrowed-body-chunked HTTP/1.1\r\nHost: localhost\r\nContent-Length: " +
                                            str(len(body)).encode() + b"\r\n\r\n" + body)
                        expected.append(body)
                    encoded = b"".join(requests)
                    wire.require(len(encoded) <= 16384, "maximum-cell input exceeded its finite queue bound")
                    with paused(server):
                        sock = stack.enter_context(server.connect())
                        sock.sendall(encoded)
                    reader = wire.ResponseReader(sock)
                    for index, expected_body in enumerate(expected):
                        status, headers, body = reader.response()
                        wire.require(status == 200 and body == expected_body and
                                     headers.get(b"transfer-encoding") == b"chunked" and b"content-length" not in headers,
                                     "%s cell %d lost generated/borrowed bytes or framing" % (kind, index))
                    # Partial-send progress must release every old cell before
                    # a flush/resume barrier and an ordered closing suffix.
                    sock.sendall(get(b"/buffered?prefix") + get(b"/chunks") +
                                 get(b"/buffered?close", close=True) + wire.REQUEST)
                    for expected_body in (b"/buffered?prefix", b"first second third", b"/buffered?close"):
                        wire.require(reader.response()[2] == expected_body, "maximum-cell reuse/flush/close order corrupted")
                    wire.require(not reader.buffer, "closing response emitted a pipelined suffix")
                    wire.expect_closed(sock)
            stats = server.stats
            wire.require(stats["completed"] == 67 and stats["max_batch_responses"] == 64,
                         "fixture failed to freeze all 64 distinct cells")
            wire.require(stats["flushes"] == stats["resumed"] == 3, "flush barrier lost a continuation")
            wire.require(stats["max_send_bytes"] <= cap, "maximum-cell aggregate send cap exceeded")
            if cap == 65536:
                wire.require(stats["max_send_parts"] == 320, "native gather did not submit all 320 response spans")
            else:
                wire.require(stats["gather_send_operations"] > 64, "partial-cap fixture did not split frozen responses")
            sessions.append(dict(phase="maximum_cells", kind=kind, cap=cap, wire_bytes=len(encoded), stats=stats))
            emit("maximum_64_%s_cells_quantum_256_cap_%d" % (kind, cap))


def maximum_pressure(binary, emit, sessions):
    asset_bytes = 65535  # Startup asset readFileAlloc's 65536 bound is exclusive.
    with tempfile.TemporaryDirectory(prefix="zig-http-quantum-pressure-") as directory:
        asset = Path(directory) / "index.html"
        asset.write_bytes(b"q" * asset_bytes)
        with BatchServer(binary, connections=2, index=asset, response_batch_limit=64,
                         inline_callback_budget=256, timeout_ms=1000,
                         socket_send_buffer=4096) as server:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as slow:
                slow.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
                slow.settimeout(3)
                with paused(server):
                    slow.connect(("127.0.0.1", server.port))
                    slow.sendall(get(b"/index.html") * 64)
                wire.require(slow.recv(1, socket.MSG_PEEK), "maximum frozen batch made no initial send progress")
                wire.plaintext(server)
                time.sleep(1.25)
                wire.plaintext(server)
        stats = server.stats
        wire.require(stats["max_batch_responses"] == stats["max_canceled_batch_responses"] == 64,
                     "deadline cancellation did not retain all 64 frozen response cells")
        wire.require(stats["gather_cancel_requests"] >= 1 and stats["timeouts"] >= 1 and
                     0 < stats["bytes_sent"] < asset_bytes * 64,
                     "maximum-cell deadline failed to cancel a partially sent gather")
        sessions.append(dict(phase="maximum_cell_cancel", asset_bytes=asset_bytes, pipeline_depth=64, stats=stats))
        emit("maximum_64_frozen_cells_pending_cancel_and_recovery_quantum_256")

        hot_count, depth, cold_timeout = 7, 128, 2.0
        with BatchServer(binary, connections=hot_count + 1, index=asset, response_batch_limit=64,
                         inline_callback_budget=256, timeout_ms=5000,
                         socket_send_buffer=4096) as server:
            with contextlib.ExitStack() as stack:
                busy = []
                # Warm each admitted slot with a response so all seven data
                # owners can receive their deep pipelines during the same turn.
                for _ in range(hot_count):
                    sock = stack.enter_context(socket.socket(socket.AF_INET, socket.SOCK_STREAM))
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
                    sock.settimeout(3)
                    sock.connect(("127.0.0.1", server.port))
                    sock.sendall(wire.REQUEST)
                    wire.require(wire.ResponseReader(sock).response()[2] == wire.PLAINTEXT,
                                 "hot connection warmup failed")
                    busy.append(sock)
                encoded = get(b"/index.html") * depth
                wire.require(len(encoded) <= 8192, "saturated pipeline input exceeded its finite queue bound")
                with paused(server):
                    for sock in busy:
                        sock.sendall(encoded)
                # A peek witnesses initial service without releasing the small
                # receive windows; pending deep output stays under backpressure.
                for sock in busy:
                    wire.require(sock.recv(1, socket.MSG_PEEK), "hot pipeline received no service")
                started = time.monotonic()
                with server.connect(timeout=cold_timeout) as cold:
                    cold.sendall(get(b"/buffered?cold-after-saturation", close=True))
                    wire.require(wire.ResponseReader(cold).response()[2] == b"/buffered?cold-after-saturation",
                                 "cold connection lost service among saturated deep pipelines")
                    wire.expect_closed(cold)
                cold_seconds = time.monotonic() - started
                wire.require(cold_seconds < cold_timeout, "cold service exceeded the explicit finite bound")
                # Close the hot sockets with unread output; normal shutdown must
                # retire all target/cancel owners and preserve allocator sealing.
        stats = server.stats
        wire.require(stats["accepted"] == hot_count + 1 and stats["max_batch_responses"] == 64,
                     "cold witness did not admit eight connections and full hot batches")
        wire.require(stats["bytes_sent"] < hot_count * depth * asset_bytes and
                     stats["completed"] < hot_count * (depth + 1) + 1,
                     "deep hot pipelines completed before the saturation witness")
        wire.require(64 < stats["max_inline_callbacks_per_turn"] <= 256,
                     "saturated fixture did not exercise the enlarged global quantum")
        sessions.append(dict(phase="saturated_cold_service", hot_connections=hot_count,
                             pipeline_depth=depth, asset_bytes=asset_bytes,
                             cold_timeout_seconds=cold_timeout, cold_seconds=cold_seconds, stats=stats))
        emit("cold_connection_served_among_saturated_deep_pipelines_quantum_256")


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
    for invalid in (0, 65):
        result = subprocess.run([str(binary), "--response-batch-limit", str(invalid)], cwd=wire.ROOT, capture_output=True, timeout=5)
        wire.require(result.returncode != 0 and b"InvalidConfiguration" in result.stderr, "invalid batch limit admitted")
    emit("batch_limit_configuration_rejected")

    for invalid in (0, 257):
        result = subprocess.run([str(binary), "--inline-callback-budget", str(invalid)], cwd=wire.ROOT, capture_output=True, timeout=5)
        wire.require(result.returncode != 0 and b"InvalidConfiguration" in result.stderr, "invalid callback budget admitted")
    emit("inline_callback_budget_configuration_rejected")

    for limit, budget in ((16, 64), (16, 256), (64, 64), (64, 256), (64, 1)):
        with BatchServer(binary, response_batch_limit=limit, inline_callback_budget=budget) as server:
            with server.connect() as sock:
                sock.sendall(wire.REQUEST * 128 + get(b"/plaintext", close=True))
                reader = wire.ResponseReader(sock)
                for _ in range(129):
                    wire.require(reader.response()[2] == wire.PLAINTEXT, "configured callback quantum lost pipeline progress")
                wire.expect_closed(sock)
        wire.require(server.stats["completed"] == 129 and server.stats["max_batch_responses"] <= min(limit, budget),
                     "response accumulation exceeded the available per-turn callbacks")
        sessions.append(dict(phase="batch_quantum_configuration", limit=limit, budget=budget, stats=server.stats))
    emit("same_binary_batch_16_64_quantum_64_256_and_minimum_quantum")

    maximum_cells(binary, emit, sessions)
    maximum_pressure(binary, emit, sessions)

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

    # Client pipeline depth and server batch capacity are independent limits.
    # Deep pipelines must cross repeated cell reuse and receive compaction while
    # the server retains at most sixteen frozen response cells at any time.
    for depth in (32, 64, 128):
        for kind in ("generated", "borrowed_body"):
            with BatchServer(binary, response_batch_limit=16) as server:
                with server.connect() as sock:
                    expected, requests = [], []
                    for index in range(depth):
                        if kind == "generated":
                            body = (b"/buffered?depth=" + str(depth).encode() +
                                    b"&index=" + str(index).encode() + b"&value=" + b"x" * index)
                            requests.append(get(body))
                        else:
                            body = depth.to_bytes(2, "big") + index.to_bytes(2, "big") + bytes([index]) * (index + 1)
                            requests.append(b"POST /borrowed-body HTTP/1.1\r\nHost: localhost\r\nContent-Length: " +
                                            str(len(body)).encode() + b"\r\n\r\n" + body)
                        expected.append(body)
                    encoded = b"".join(requests)
                    wire.require(len(encoded) <= 65536, "deep pipeline fixture exceeded its write bound")
                    sock.sendall(encoded)
                    reader = wire.ResponseReader(sock)
                    for index, expected_body in enumerate(expected):
                        status, headers, body = reader.response()
                        wire.require(status == 200 and body == expected_body and
                                     headers.get(b"content-length") == str(len(expected_body)).encode(),
                                     "%s depth %d response %d lost order or retained bytes" % (kind, depth, index))
                    # Reuse this exact connection after all deep responses have
                    # arrived; another request must not see stale parser/cell state.
                    reused = (b"/buffered?reused=" + kind.encode() + b"-" + str(depth).encode())
                    sock.sendall(get(reused) + get(b"/plaintext", close=True))
                    status, headers, body = reader.response()
                    wire.require(status == 200 and body == reused and
                                 headers.get(b"content-length") == str(len(reused)).encode(),
                                 "deep pipeline left stale state on its reused connection")
                    wire.require(reader.response()[2] == wire.PLAINTEXT, "reused connection lost final response")
                    wire.expect_closed(sock)
            stats = server.stats
            wire.require(stats["accepted"] == 1 and stats["completed"] == depth + 2,
                         "deep pipeline did not complete on one reused connection")
            wire.require(stats["response_batch_limit"] == 16 and 1 < stats["max_batch_responses"] <= 16,
                         "deep client pipeline changed or failed to exercise the server batch bound")
            wire.require(stats["max_inline_callbacks_per_turn"] <= 64,
                         "deep pipeline exceeded the global callback turn budget")
            wire.require(stats["allocation_calls_after_start"] == 0 and
                         stats["live_connections"] == stats["live_operations"] == 0,
                         "deep pipeline leaked ownership or allocated after startup")
            sessions.append(dict(phase="deep_pipeline", kind=kind, pipeline_depth=depth,
                                 response_batch_limit=16, wire_bytes=len(encoded), stats=stats))
            emit("deep_%s_pipeline_%d_batch_limit_16_and_reuse" % (kind, depth))

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

    # An incomplete large request can drain its earlier finished prefix before
    # its own send stalls. Instead, pipeline complete, small requests for a
    # startup-loaded asset so multiple response cells remain frozen together.
    # Zig 0.16 readFileAlloc's .limited(65536) bound is exclusive.
    asset_bytes = 65535
    pipeline_depth = 16
    with tempfile.TemporaryDirectory(prefix="zig-http-batch-cancel-") as directory:
        asset = Path(directory) / "index.html"
        asset.write_bytes(b"a" * asset_bytes)
        with BatchServer(binary, connections=2, index=asset, timeout_ms=1000,
                         socket_send_buffer=4096) as server:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as slow:
                # Set the receive window before connect rather than relying on
                # reducing an already negotiated TCP window after the handshake.
                slow.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
                slow.settimeout(3)
                slow.connect(("127.0.0.1", server.port))
                slow.sendall(get(b"/index.html") * pipeline_depth)
                wire.plaintext(server)
                time.sleep(1.25)
                wire.plaintext(server)
        wire.require(server.stats["gather_cancel_requests"] >= 1,
                     "asset slow reader did not retain a cancellable gather")
        wire.require(1 < server.stats["max_canceled_batch_responses"] <= pipeline_depth,
                     "canceled send did not retain multiple frozen response cells")
        wire.require(server.stats["timeouts"] >= 1 and
                     0 < server.stats["bytes_sent"] < asset_bytes * pipeline_depth,
                     "asset pipeline did not reach its deadline with partial output")
        # A cancel can race a normal terminal completion. Server.__exit__ checks
        # both target/cancel drainage through zero live operations/connections.
        sessions.append(dict(phase="multi_cell_cancel", asset_bytes=asset_bytes,
                             pipeline_depth=pipeline_depth, stats=server.stats))
    emit("multi_cell_frozen_batch_deadline_cancel_and_recovery")

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
