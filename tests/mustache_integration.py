#!/usr/bin/env python3
"""ReleaseSafe wire checks for the public Mustache example.

The caller holds the shared host reservation and supplies an overall process-tree
watchdog. Socket, startup, shutdown, and client-thread waits are finite. These
checks verify correctness and terminal ownership, without performance claims.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import html
import json
from pathlib import Path
import platform
import re
import sys
import threading
import time
from urllib.parse import quote_plus

from app_integration import request_bytes
import wire_support as wire


class MustacheServer(wire.Server):
    def __init__(self, binary, execution="inline", workers=0, connections=1):
        super().__init__(binary)
        self.options = dict(port=0, execution=execution, workers=workers,
                            connections=connections, shards=1)

    def __enter__(self):
        super().__enter__()
        try:
            wire.require(any("optimize=ReleaseSafe" in line for line in self.lines),
                         "Mustache wire checks require a ReleaseSafe binary")
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise
        return self

    def connect(self, timeout=5.0):
        return super().connect(timeout=timeout)


def reader_for(sock):
    return wire.ResponseReader(sock, maximum=16384)


def page(response, name="friend"):
    status, headers, body = response
    wire.require(status == 200, f"page returned {status}: {body[:120]!r}")
    wire.require(headers.get(b"content-type") == b"text/html; charset=utf-8",
                 "Mustache response lost its HTML content type")
    wire.require(headers.get(b"content-length") == str(len(body)).encode(),
                 "rendered representation length differs from the wire body")
    wire.require(b"transfer-encoding" not in headers, "ordinary template response became chunked")
    text = body.decode("utf-8")
    escaped = html.escape(name, quote=False).replace('"', "&quot;").replace("'", "&#39;")
    wire.require(text.startswith("<!doctype html>\n") and text.endswith("</html>\n"),
                 "rendered page is incomplete")
    wire.require(f"<h1>Hello, {escaped}!</h1>" in text, "greeting changed or was not escaped")
    wire.require(f'name="name" value="{escaped}"' in text, "form value changed or escaped its attribute")
    wire.require('<form action="/" method="get">' in text, "greeting form missing")
    wire.require("<title>A little company. — Baz</title>" in text, "nested page title missing")
    cards = re.findall(r'<article class="user" data-user-id="(\d+)">(.*?)</article>', text, re.S)
    wire.require([item[0] for item in cards] == ["1", "6"], "typed users array did not render through its partial")
    for (_, card), user, role in zip(cards, ("Rene", "Caro"),
                                    ("Making things work.", "Making things wonderful.")):
        wire.require(f"<h2>{user}</h2>" in card and f"<p>{role}</p>" in card,
                     "partial lost the section context or nested user field")
        wire.require("<small>The Baz community</small>" in card,
                     "partial lost the parent context")
    wire.require("{{" not in text, "Mustache tags remained in the rendered page")
    return body


def exchange(sock, reader, path="/", method="GET"):
    sock.sendall(request_bytes(path, method=method))
    return reader.response(head=method == "HEAD")


def healthy_reconnect(server):
    # The one-slot server can admit this request only after retiring the rejected target.
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        try:
            with server.connect(timeout=0.3) as sock:
                reader = reader_for(sock)
                sock.sendall(request_bytes("/", headers=(("Connection", "close"),)))
                page(reader.response())
                wire.expect_closed(sock)
            return
        except (OSError, EOFError):
            time.sleep(0.03)
    raise AssertionError("malformed request target did not release its connection slot")


def run(binary):
    cases = []

    def passed(name, server):
        cases.append(dict(name=name, backend=server.backend, options=server.options, stats=server.stats))
        print("PASS " + name, flush=True)

    for execution, workers in (("inline", 0), ("workers", 1)):
        with MustacheServer(binary, execution, workers) as server:
            with server.connect() as sock:
                reader = reader_for(sock)
                body = page(exchange(sock, reader))
                page(exchange(sock, reader, "/?name=Ren%C3%A9+%2B+Caro"), "René + Caro")
                page(exchange(sock, reader, "/?name=O%27Reilly"), "O'Reilly")
                page(exchange(sock, reader, "/?name=%25"), "%")
                hostile = '<script>alert("x")</script>& Bob'
                escaped_body = page(exchange(sock, reader, "/?name=" + quote_plus(hostile)), hostile)
                wire.require(b"<script>" not in escaped_body, "untrusted greeting became script markup")
                page(exchange(sock, reader, "/?name=" + "a" * 2048), "a" * 2048)
                sock.sendall(request_bytes("/", method="HEAD") + request_bytes("/"))
                status, headers, head_body = reader.response(head=True)
                wire.require(status == 200 and head_body == b"" and
                             headers.get(b"content-length") == str(len(body)).encode(),
                             "HEAD lost the rendered GET length")
                wire.require(headers.get(b"content-type") == b"text/html; charset=utf-8",
                             "HEAD lost the HTML content type")
                page(reader.response())  # A successful next parse also proves HEAD emitted no body.
        passed("typed partials, escaping, form decoding, exact input bound and HEAD in " + execution, server)

        for malformed in ("%", "%GG"):
            with MustacheServer(binary, execution, workers) as server:
                with server.connect() as sock:
                    reader = reader_for(sock)
                    sock.sendall(request_bytes("/?name=" + malformed) + request_bytes("/"))
                    status, headers, body = reader.response()
                    wire.require(status == 400 and body == b"" and headers.get(b"connection") == b"close",
                                 "malformed raw target did not receive the engine's empty 400/close response")
                    wire.require(not reader.buffer, "engine dispatched the request after a malformed target")
                    wire.expect_closed(sock)
                healthy_reconnect(server)
            passed("engine rejects malformed target " + malformed + " and releases its slot in " + execution, server)

        with MustacheServer(binary, execution, workers) as server:
            with server.connect() as sock:
                reader = reader_for(sock)
                invalid = ("name=%FF", "name=%C3", "name=%C0%AF",
                           "name=%ED%A0%80", "name=" + "a" * 2049,
                           "name=one&name=two", "&".join("x=1" for _ in range(9)))
                for query in invalid:
                    sock.sendall(request_bytes("/?" + query) + request_bytes("/"))
                    status, headers, body = reader.response()
                    wire.require(status == 400 and headers.get(b"content-type", b"").startswith(b"text/plain"),
                                 f"invalid greeting did not return ordinary 400: {query[:80]!r}")
                    wire.require(b"<!doctype" not in body, "invalid input published a template prefix")
                    page(reader.response())
        passed("invalid query and UTF-8 return 400 with connection reuse in " + execution, server)

        with MustacheServer(binary, execution, workers) as server:
            with server.connect() as sock:
                reader = reader_for(sock)
                # Both insertions expand to 11,200 bytes, exceeding the 8 KiB body reservation.
                overflow = "/?name=" + "%3C" * 1400
                for method in ("GET", "HEAD"):
                    sock.sendall(request_bytes(overflow, method=method) + request_bytes("/"))
                    status, headers, body = reader.response(head=method == "HEAD")
                    wire.require(status == 500, "escaped output exceeded the response bound without failing")
                    wire.require(headers.get(b"content-type", b"").startswith(b"text/plain"),
                                 "failed render leaked its draft HTML headers")
                    wire.require(body == (b"Internal Server Error" if method == "GET" else b""),
                                 "failed render published a partial page or private error detail")
                    page(reader.response())
        passed("output overflow discards the entire draft and reuses its connection in " + execution, server)

        clients = 4
        with MustacheServer(binary, execution, 4 if workers else 0, connections=clients) as server:
            ready = threading.Barrier(clients)

            def render_client(index):
                with server.connect() as sock:
                    reader = reader_for(sock)
                    ready.wait(timeout=5)
                    for batch in range(4):
                        names = [f"guest {index}-{batch}-{item} <&> ✓" for item in range(2)]
                        sock.sendall(b"".join(request_bytes("/?name=" + quote_plus(name)) for name in names))
                        for name in names:
                            page(reader.response(), name)

            with ThreadPoolExecutor(max_workers=clients) as pool:
                futures = [pool.submit(render_client, index) for index in range(clients)]
                for future in futures:
                    future.result(timeout=20)
        wire.require(server.stats["completed"] == 32, "concurrent render responses were lost or repeated")
        passed("four clients reuse one immutable template with isolated data in " + execution, server)

    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=wire.ROOT / "zig-out/bin/mustache")
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    if sys.platform == "win32" and binary.suffix.lower() != ".exe":
        binary = binary.with_name(binary.name + ".exe")
    cases = run(binary)
    result = dict(passed=len(cases), cases=cases, platform=platform.platform(),
                  python=sys.version, binary=str(binary), binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest())
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
