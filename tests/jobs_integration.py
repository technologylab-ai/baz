#!/usr/bin/env python3
"""ReleaseSafe session, background-job, and server-sent event wire gates.

The caller reserves the host and supplies a process-tree watchdog. Client storage,
connections, reads, polling, and shutdown waits have explicit limits.
These checks establish correctness. They make no performance claims.
"""

import argparse
from contextlib import ExitStack
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import platform
import re
import socket
import sys
import threading
import time

from app_integration import request_bytes
from cookies_integration import CookieReader, FORM, cookies, rows
from streaming_integration import StreamReader
import wire_support as wire


class JobsServer(wire.Server):
    def __init__(self, binary, execution, workers, **options):
        super().__init__(binary)
        self.options = dict(port=0, execution=execution, workers=workers,
                            connections=48, shards=1)
        self.options.update(options)

    def __enter__(self):
        super().__enter__()
        try:
            wire.require(any("optimize=ReleaseSafe" in line for line in self.lines),
                         "job gates require ReleaseSafe")
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise
        return self

    def __exit__(self, kind, value, tb):
        result = super().__exit__(kind, value, tb)
        if kind is None:
            receipts = [re.fullmatch(r"JOBS started=([0-9]+) cleaned=([0-9]+)", line)
                        for line in self.lines if line.startswith("JOBS ")]
            wire.require(len(receipts) == 1 and receipts[0] is not None,
                         "missing or repeated job ownership receipt")
            started, cleaned = map(int, receipts[0].groups())
            wire.require(started == cleaned, "a job subscription did not clean up exactly once")
            self.jobs_receipt = dict(started=started, cleaned=cleaned)
        return result

    def connect(self, timeout=8):
        return super().connect(timeout=timeout)


class Events:
    """Incremental browser-style SSE parser above arbitrary HTTP chunk boundaries."""
    def __init__(self, sock, previous_id=""):
        self.reader = StreamReader(sock, maximum=65536)
        self.pending = bytearray()
        self.last_id = previous_id
        self.retry = None
        self.comments = 0
        self.total = 0
        self.ended = False

    def head(self):
        status, headers = self.reader.head()
        if status != 200:
            wire.require(b"content-length" in headers, "rejected SSE response lacks explicit framing")
            body = self.reader._take(int(headers[b"content-length"]))
            raise StreamRejected(status, body)
        wire.require(headers.get(b"content-type", b"").split(b";")[0] == b"text/event-stream",
                     "event stream MIME type is wrong")
        wire.require(headers.get(b"transfer-encoding") == b"chunked",
                     "event stream lacks chunk framing")
        wire.require(headers.get(b"cache-control") == b"no-store", "event stream can be cached")
        return headers

    def next(self):
        for _ in range(1024):
            separator = self.pending.find(b"\n\n")
            if separator < 0:
                if self.ended:
                    wire.require(not self.pending, "stream ended with an incomplete SSE event")
                    return None
                chunk = self.reader.chunk()
                if chunk is None:
                    self.ended = True
                    continue
                self.total += len(chunk)
                wire.require(self.total <= 65536, "SSE stream exceeds client storage bound")
                self.pending.extend(chunk)
                continue
            block = bytes(self.pending[:separator]).decode("utf-8", "strict")
            del self.pending[:separator + 2]
            wire.require("\r" not in block, "encoder failed to normalize line endings")
            data = []
            event_type = "message"
            for line in block.split("\n"):
                if line.startswith(":"):
                    self.comments += 1
                    continue
                name, separator, value = line.partition(":")
                if separator and value.startswith(" "):
                    value = value[1:]
                if name == "data":
                    data.append(value)
                elif name == "event":
                    event_type = value or "message"
                elif name == "id" and "\x00" not in value:
                    self.last_id = value
                elif name == "retry" and re.fullmatch(r"[0-9]+", value):
                    self.retry = int(value)
            if data:
                return dict(event=event_type, data="\n".join(data), id=self.last_id)
        raise AssertionError("SSE parser exceeded its finite block budget")

    def all(self):
        result = []
        for _ in range(64):
            event = self.next()
            if event is None:
                return result
            result.append(event)
        raise AssertionError("SSE stream exceeded 64 application events")


class StreamRejected(Exception):
    def __init__(self, status, body):
        self.status = status
        self.body = body
        super().__init__(f"event stream returned {status}: {body[:100]!r}")


def call(sock, reader, path, status=200, method="GET", body=b"", headers=()):
    # The startup producer shares a try-lock. Busy rejects before any mutation.
    deadline = time.monotonic() + 2
    for _ in range(200):
        sock.sendall(request_bytes(path, method=method, body=body, headers=headers))
        result = reader.response(head=method == "HEAD")
        busy = result[0] == 503 and result[2] == b"Application state is busy"
        if not busy:
            wire.require(result[0] == status,
                         f"{method} {path}: expected {status}, got {result[0]} {result[2][:100]!r}")
            return result
        wire.require(time.monotonic() < deadline, "application guard did not release within the bounded retry window")
        time.sleep(0.01)
    raise AssertionError("application guard retry budget exhausted")


def authenticate(sock, reader, username="zap"):
    response = call(sock, reader, "/login", status=303, method="POST", headers=FORM,
                    body=f"username={username}&password=awesome".encode())
    wire.require(rows(response, b"location") == [b"/"], "login did not redirect to the job page")
    values = cookies(response)
    wire.require(len(values) == 1, "login must set exactly one session cookie")
    name, token, attrs = values[0]
    wire.require(len(token) == 64 and all(c in b"0123456789abcdef" for c in token),
                 "session token is not opaque hexadecimal")
    wire.require(attrs.get(b"path") == b"/" and b"httponly" in attrs
                 and attrs.get(b"samesite") == b"Strict", "session cookie scope changed")
    wire.require(b"expires" not in attrs and b"max-age" not in attrs,
                 "example session cookie became persistent")
    return (("Cookie", (name + b"=" + token).decode()),)


def create_job(sock, reader, auth):
    response = call(sock, reader, "/jobs", status=201, method="POST", headers=auth)
    value = json.loads(response[2])
    wire.require(isinstance(value.get("id"), str) and re.fullmatch(r"[0-9]+-[0-9]+", value["id"]),
                 f"job ID is not an opaque slot-generation handle: {value}")
    return value["id"]


def subscribe(sock, job, auth, cursor=None):
    extra = () if cursor is None else (("Last-Event-ID", cursor),)
    deadline = time.monotonic() + 2
    for _ in range(200):
        sock.sendall(request_bytes(f"/jobs/{job}/events", headers=auth + extra))
        stream = Events(sock, previous_id=cursor or "")
        try:
            stream.head()
            return stream
        except StreamRejected as error:
            if error.status != 503 or error.body != b"Application state is busy":
                raise
            wire.require(time.monotonic() < deadline, "SSE guard retry deadline exceeded")
            time.sleep(0.01)
    raise AssertionError("SSE guard retry budget exhausted")


def health(sock, reader):
    wire.require(call(sock, reader, "/health")[2] == b"ok", "parked streams retained the callback worker")


def progress_events(events, terminal=True):
    wire.require(events, "job stream emitted no progress")
    sequence = []
    values = []
    for event in events:
        wire.require(event["event"] in ("progress", "done"), f"unexpected event: {event}")
        wire.require(re.fullmatch(r"[1-9][0-9]*", event["id"]), "event ID is not canonical decimal")
        value = json.loads(event["data"])
        wire.require(type(value.get("progress")) is int and 0 <= value["progress"] <= 100,
                     f"invalid progress value: {value}")
        wire.require(type(value.get("done")) is bool and value["done"] == (value["progress"] == 100),
                     "completion state differs from progress")
        wire.require((event["event"] == "done") == value["done"], "completion event type differs from payload")
        sequence.append(int(event["id"]))
        values.append(value["progress"])
    wire.require(sequence == list(range(sequence[0], sequence[-1] + 1)), "SSE cursor skipped or repeated a sequence")
    wire.require(values == sorted(set(values)), "progress repeated or moved backwards")
    if terminal:
        wire.require(events[-1]["event"] == "done" and values[-1] == 100, "job never completed")
    return sequence


def run(binary):
    cases = []

    def passed(name, server):
        cases.append(dict(name=name, backend=server.backend, options=server.options, stats=server.stats,
                          jobs=server.jobs_receipt))
        print("PASS " + name, flush=True)

    for execution, workers in (("inline", 0), ("workers", 1)):
        with JobsServer(binary, execution, workers, tick_ms=100) as server:
            with server.connect() as control:
                reader = CookieReader(control)
                public = call(control, reader, "/login")
                wire.require(b"<form" in public[2], "login page lacks its form")
                call(control, reader, "/", status=303)
                call(control, reader, "/jobs", status=401, method="POST")
                call(control, reader, "/jobs/0-1/events", status=401)
                call(control, reader, "/login", status=401, method="POST", headers=FORM,
                     body=b"username=zap&password=wrong")
                for metadata in ((("Sec-Fetch-Site", "cross-site"),),
                                 (("Sec-Fetch-Site", "same-site"),),
                                 (("Sec-Fetch-Site", "same-origin"), ("Sec-Fetch-Site", "same-origin"))):
                    call(control, reader, "/login", status=403, method="POST", headers=FORM + metadata,
                         body=b"username=zap&password=awesome")
                auth = authenticate(control, reader)
                call(control, reader, "/jobs", status=403, method="POST",
                     headers=auth + (("Sec-Fetch-Site", "cross-site"),))
                page = call(control, reader, "/", headers=auth)
                wire.require(b"{{" not in page[2] and b"/jobs.js" in page[2]
                             and b"zap" in page[2], "Mustache page lost rendered identity or live client")
                script = call(control, reader, "/jobs.js")
                wire.require(b"EventSource" in script[2], "browser asset lost its SSE client")
                wire.require(page[1].get(b"cache-control") == b"no-store", "protected page can be cached")
                first = create_job(control, reader, auth)
                other = authenticate(control, reader, "baz")
                call(control, reader, f"/jobs/{first}/events", status=404, headers=other)
                call(control, reader, f"/jobs/{first}/events", status=204, method="HEAD", headers=auth)
                health(control, reader)
                call(control, reader, "/jobs/8-1/events", status=404, headers=auth)
                for bad in ("x", "00-1", "0-01", "0-0", "65536-1", "0-18446744073709551616"):
                    call(control, reader, f"/jobs/{bad}/events", status=400, headers=auth)
                for extra in ((("Last-Event-ID", "01"),), (("Last-Event-ID", "-1"),),
                              (("Last-Event-ID", ""),),
                              (("Last-Event-ID", "12"),), (("Last-Event-ID", "a%0Ab"),),
                              (("Last-Event-ID", "18446744073709551616"),),
                              (("Last-Event-ID", "1"), ("Last-Event-ID", "1"))):
                    call(control, reader, f"/jobs/{first}/events", status=400, headers=auth + extra)
                health(control, reader)
        passed("rendered application, authentication, job ownership, HEAD and strict raw cursors in " + execution, server)

        with JobsServer(binary, execution, workers, tick_ms=100) as server:
            with server.connect() as control, server.connect() as client:
                reader = CookieReader(control)
                auth = authenticate(control, reader)
                job = create_job(control, reader, auth)
                events = subscribe(client, job, auth)
                first = events.next()
                wire.require(first["id"] == "1" and json.loads(first["data"])["progress"] == 0,
                             "new stream lost its initial snapshot")
                health(control, reader)
                all_events = [first] + events.all()
                wire.require(progress_events(all_events) == list(range(1, 12)), "complete job lost an update")
                health(client, CookieReader(client))
                wire.require(events.retry is not None, "example omitted its explicit browser reconnect hint")
        passed("background producer publishes ordered SSE and keep-alive with a free callback worker in " + execution, server)

        with JobsServer(binary, execution, workers, tick_ms=100) as server:
            with server.connect() as control:
                reader = CookieReader(control)
                auth = authenticate(control, reader)
                job = create_job(control, reader, auth)
                with server.connect() as client:
                    stream = subscribe(client, job, auth)
                    first = stream.next()
                    second = stream.next()
                    progress_events([first, second], terminal=False)
                    cursor = second["id"]
                with server.connect() as client:
                    resumed = subscribe(client, job, auth, cursor)
                    sequence = progress_events(resumed.all())
                    wire.require(sequence[0] == int(cursor) + 1 and sequence[-1] == 11,
                                 "reconnect did not start after the acknowledged cursor")
                # The retained ring holds eight of eleven updates after completion.
                call(control, reader, f"/jobs/{job}/events", status=409,
                     headers=auth + (("Last-Event-ID", "1"),))
                call(control, reader, f"/jobs/{job}/events", status=204,
                     headers=auth + (("Last-Event-ID", "11"),))
                with server.connect() as client:
                    recent = subscribe(client, job, auth, "9")
                    wire.require(progress_events(recent.all()) == [10, 11], "retained replay suffix changed")
                health(control, reader)
        passed("disconnect, cursor replay, bounded replay gaps and terminal reconnect policy in " + execution, server)

        with JobsServer(binary, execution, workers, tick_ms=500) as server:
            with server.connect() as control, ExitStack() as clients:
                reader = CookieReader(control)
                auth = authenticate(control, reader)
                job = create_job(control, reader, auth)
                peers = []
                for _ in range(32):
                    client = clients.enter_context(server.connect())
                    events = subscribe(client, job, auth)
                    wire.require(events.next()["event"] == "progress", "subscriber did not receive a snapshot")
                    peers.append(client)
                health(control, reader)
                call(control, reader, f"/jobs/{job}/events", status=503, headers=auth)
                health(control, reader)
                # Closing all peers must eventually return every retained continuation.
                for client in peers:
                    client.close()
            deadline = time.monotonic() + 5
            while True:
                with server.connect() as client:
                    client.sendall(request_bytes(f"/jobs/{job}/events", method="HEAD", headers=auth))
                    observed = CookieReader(client).response(head=True)
                    if observed[0] == 204:
                        break
                    wire.require(observed[0] == 503 and time.monotonic() < deadline,
                                 f"subscriber storage did not recover: {observed[0]}")
                time.sleep(0.01)
            with server.connect() as client:
                stream = subscribe(client, job, auth)
                wire.require(stream.next()["event"] == "progress", "reused continuation did not receive producer output")
        passed("32 parked subscribers, exact exhaustion, ordinary requests and disconnect reuse in " + execution, server)

        with JobsServer(binary, execution, workers, tick_ms=20, job_ttl_ms=800) as server:
            with server.connect() as control:
                reader = CookieReader(control)
                auth = authenticate(control, reader)
                jobs = [create_job(control, reader, auth) for _ in range(8)]
                wire.require(len(set(jobs)) == 8, "live jobs share a handle")
                call(control, reader, "/jobs", status=503, method="POST", headers=auth)
                deadline = time.monotonic() + 5
                while True:
                    control.sendall(request_bytes("/jobs", method="POST", headers=auth))
                    observed = reader.response()
                    if observed[0] == 201:
                        replacement = json.loads(observed[2])["id"]
                        break
                    wire.require(observed[0] == 503 and time.monotonic() < deadline,
                                 "expired jobs did not return bounded storage")
                    time.sleep(0.025)
                wire.require(replacement not in jobs, "reused job slot repeated its generation")
                call(control, reader, f"/jobs/{jobs[0]}/events", status=404, headers=auth)
                health(control, reader)
        passed("fixed job storage rejects overflow and retires stale handles after expiry in " + execution, server)

        with JobsServer(binary, execution, workers, tick_ms=150, session_ttl_ms=800) as server:
            with server.connect() as control, server.connect() as client:
                reader = CookieReader(control)
                auth = authenticate(control, reader)
                job = create_job(control, reader, auth)
                stream = subscribe(client, job, auth)
                received = stream.all()
                wire.require(received[-1]["event"] == "session-expired"
                             and json.loads(received[-1]["data"]) == {}, "waiting stream ignored server-side session expiry")
                wire.require(not any(item["event"] == "done" for item in received),
                             "job completed through an expired session")
                call(control, reader, f"/jobs/{job}/events", status=401, headers=auth)
                health(control, reader)
        passed("each resume revalidates absolute session expiry before sending progress in " + execution, server)

        with JobsServer(binary, execution, workers, tick_ms=250) as server:
            with server.connect() as control, server.connect() as client:
                reader = CookieReader(control)
                auth = authenticate(control, reader)
                job = create_job(control, reader, auth)
                stream = subscribe(client, job, auth)
                stream.next()
                result = call(control, reader, "/logout", status=303, method="POST", headers=auth)
                wire.require(rows(result, b"location") == [b"/login"], "logout redirected outside login")
                deleted = cookies(result)
                wire.require(len(deleted) == 1 and deleted[0][1] == b""
                             and deleted[0][2].get(b"max-age") == b"0", "logout did not delete its browser cookie")
                received = stream.all()
                wire.require(received and received[-1]["event"] == "session-expired",
                             "revoked stream continued without a terminal auth event")
                call(control, reader, f"/jobs/{job}/events", status=401, headers=auth)
                health(control, reader)
        passed("logout revokes an active SSE stream and deletes its cookie in " + execution, server)

        with JobsServer(binary, execution, workers, tick_ms=2000) as server:
            with server.connect() as control, server.connect() as client:
                reader = CookieReader(control)
                auth = authenticate(control, reader)
                job = create_job(control, reader, auth)
                stream = subscribe(client, job, auth)
                received = []
                for _ in range(4):
                    received.append(stream.next())
                    if stream.comments:
                        break
                wire.require(stream.comments > 0, "notification timeout did not publish a comment heartbeat")
                progress_events(received, terminal=False)
                health(control, reader)
        passed("notification timeout sends a comment heartbeat without inventing a progress event in " + execution, server)

        with JobsServer(binary, execution, workers, tick_ms=100) as server:
            with server.connect() as control, server.connect() as delayed:
                reader = CookieReader(control)
                auth = authenticate(control, reader)
                job = create_job(control, reader, auth)
                stream = subscribe(delayed, job, auth)
                # This delays application reads. Small events do not saturate the kernel send buffer.
                for _ in range(12):
                    health(control, reader)
                    time.sleep(0.1)
                progress_events(stream.all())
                health(control, reader)
        passed("a delayed reader preserves event framing while ordinary requests complete in " + execution, server)

        with JobsServer(binary, execution, workers, tick_ms=500) as server:
            with server.connect() as control, server.connect() as client:
                reader = CookieReader(control)
                auth = authenticate(control, reader)
                job = create_job(control, reader, auth)
                stream = subscribe(client, job, auth)
                stream.next()
                # Keep the authorized stop socket open through process exit.
                control.settimeout(0.5)
                for _ in range(100):
                    control.sendall(request_bytes("/stop", method="POST", headers=auth))
                    try:
                        stopped = reader.response()
                    except (EOFError, ConnectionResetError, socket.timeout):
                        break  # A successful stop can end transport before response delivery.
                    if stopped[0] == 503 and stopped[2] == b"Application state is busy":
                        time.sleep(0.01)
                        continue
                    wire.require(stopped[0] == 200, f"authorized stop failed: {stopped[0]}")
                    break
                else:
                    raise AssertionError("stop contention retry budget exhausted")
                wire.require(server.process.wait(timeout=5) == 0, "shutdown retained a producer or subscription")
        passed("authorized shutdown joins the producer and retires parked subscriptions in " + execution, server)

    topologies = [("workers", 2, 1)]
    if sys.platform.startswith("linux") or sys.platform == "win32":
        topologies.append(("inline", 0, 3))
    for execution, workers, shards in topologies:
        with JobsServer(binary, execution, workers, tick_ms=500, shards=shards) as server:
            with server.connect() as control:
                reader = CookieReader(control)
                auth = authenticate(control, reader)
                job = create_job(control, reader, auth)
                for _ in range(3):
                    with ExitStack() as clients:
                        peers = [clients.enter_context(server.connect()) for _ in range(8)]
                        start = threading.Barrier(8)

                        def open_stream(client):
                            start.wait(timeout=5)
                            stream = subscribe(client, job, auth)
                            first = stream.next()
                            wire.require(first["event"] == "progress", "concurrent subscriber lost initial progress")
                            return stream

                        with ThreadPoolExecutor(max_workers=8) as pool:
                            futures = [pool.submit(open_stream, client) for client in peers]
                            streams = [future.result(timeout=8) for future in futures]
                        health(control, reader)
                        wire.require(len(streams) == 8, "concurrent open lost a subscriber")
                        close = threading.Barrier(8)

                        def close_stream(client):
                            close.wait(timeout=5)
                            client.close()

                        with ThreadPoolExecutor(max_workers=8) as pool:
                            futures = [pool.submit(close_stream, client) for client in peers]
                            for future in futures:
                                future.result(timeout=8)
                    health(control, reader)
        passed(f"concurrent subscriber admission, producer wakeups and cleanup reuse with {execution}, {workers} workers, {shards} shards", server)
        cases[-1]["concurrent_clients"] = 8
        cases[-1]["admission_cleanup_rounds"] = 3

    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=wire.ROOT / "zig-out/bin/jobs")
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    cases = run(args.binary.resolve())
    result = dict(passed=len(cases), cases=cases, platform=platform.platform(), python=sys.version,
                  unsupported_topologies=["workers with multiple shards"]
                  + (["multiple macOS shards"] if sys.platform == "darwin" else []))
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
