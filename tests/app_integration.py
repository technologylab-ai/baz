#!/usr/bin/env python3
"""Native App wire gates. Uses the existing finite server/process harness."""
import argparse
import json
from pathlib import Path
import time

import wire_support as wire


class AppServer(wire.Server):
    def __init__(self, binary, **options):
        super().__init__(binary)
        self.options = dict(port=0, connections=16, execution="inline", workers=0,
                            shards=1, max_body=8192, max_header=2048,
                            timeout_ms=3000, send_chunk=7, output_bytes=16384,
                            response_body=8192)
        self.options.update(options)


def request_bytes(path, method="GET", body=b"", headers=()):
    rows = [f"{method} {path} HTTP/1.1", "Host: localhost"]
    rows += [f"{name}: {value}" for name, value in headers]
    if body:
        rows += [f"Content-Length: {len(body)}"]
    return ("\r\n".join(rows) + "\r\n\r\n").encode() + body


def check_response(server, path, expected_status, expected_body=None, **kwargs):
    result = wire.request(server, request_bytes(path, **kwargs), head=kwargs.get("method") == "HEAD")
    wire.require(result[0] == expected_status, f"{path}: status {result[0]}, expected {expected_status}")
    if expected_body is not None:
        wire.require(result[2] == expected_body, f"{path}: body {result[2]!r}")
    return result


def run(binary):
    cases = []

    def passed(name):
        cases.append(name)
        print("PASS " + name, flush=True)

    with AppServer(binary) as server:
        check_response(server, "/hello", 200, b"Hello from the App API")
        check_response(server, "/hello?name=Hello%20Zig%2B0.16", 200, b"Hello Zig+0.16")
        check_response(server, "/hello?name=x+y", 200, b"x+y")
        check_response(server, "/hello?name", 200, b"")
        check_response(server, "/raw-value?value=001&value=false", 200, b"001")
        check_response(server, "/raw-query?a%5B%5D=1&a%5B%5D=2", 200, b"a%5B%5D=1&a%5B%5D=2")
        check_response(server, "http://localhost/hello?name=absolute", 200, b"absolute")
        check_response(server, "http://localhost?name=empty-absolute-path", 200, b"empty-absolute-path")
        check_response(server, "/raw-value?" + "a=&" * 257, 413)
        passed("raw query bytes, explicit decode and borrowed target forms")

        response = check_response(server, "/users/a%2Fb?unused=1", 200)
        wire.require(json.loads(response[2]) == {"kind": "user", "id": "a%2Fb"}, "capture was decoded or coerced")
        check_response(server, "/Hello", 404)
        check_response(server, "/hello/", 404)
        head = check_response(server, "/hello", 200, b"", method="HEAD")
        wire.require(int(head[1][b"content-length"]) == len(b"Hello from the App API"), "HEAD lost GET representation length")
        rejected = check_response(server, "/hello", 405, method="POST")
        wire.require(set(rejected[1][b"allow"].split(b", ")) == {b"GET", b"HEAD", b"OPTIONS"}, "incorrect Allow")
        check_response(server, "/hello", 204, b"", method="OPTIONS")
        options = check_response(server, "*", 204, b"", method="OPTIONS")
        wire.require(b"POST" in options[1][b"allow"], "OPTIONS * missing registered method")
        passed("typed endpoint, raw captures, case/trailing-slash routing, HEAD and Allow")

        for prefix in ("left", "right"):
            check_response(server, f"/{prefix}/fixed/fixed", 200, b"earlier static")
        check_response(server, "/right/fixed/fixed", 405, method="POST")
        check_response(server, "/extension", 200, b"earlier static", method="M-SEARCH")
        explicit = check_response(server, "/head", 200, b"", method="HEAD")
        wire.require(explicit[1][b"x-handler"] == b"explicit HEAD" and explicit[1][b"content-length"] == b"4", "explicit HEAD was replaced by GET")
        passed("crossing routes in both registration orders, explicit HEAD and extension method")

        content_type = (("Content-Type", "application/x-www-form-urlencoded"),)
        check_response(server, "/form?value=query", 200, b"x y+z", method="POST",
                       body=b"value=x+y%2Bz&value=second", headers=content_type)
        check_response(server, "/form", 400, method="POST", body=b"value=%GG", headers=content_type)
        check_response(server, "/form", 415, method="POST", body=b"value=x",
                       headers=(("Content-Type", "application/json"),))
        check_response(server, "/form", 413, method="POST", body=b"value=" + b"x" * 4091, headers=content_type)
        chunked = (b"POST /form HTTP/1.1\r\nHost: localhost\r\n"
                   b"Content-Type: application/x-www-form-urlencoded\r\nTransfer-Encoding: chunked\r\n\r\n"
                   b"8\r\nvalue=a%\r\n4\r\n20b+\r\n1\r\nc\r\n0\r\n\r\n")
        status, _, body = wire.request(server, chunked)
        wire.require(status == 200 and body == b"a b c", "explicit chunked form copy/decode failed")
        passed("URL-encoded forms remain separate; explicit copy spans HTTP chunks")

        multipart = (b'--B\r\nContent-Disposition: form-data; name="files[]"\r\n\r\n001\r\n'
                     b'--B\r\nContent-Disposition: form-data; name="files[]"; filename="one.bin"\r\n'
                     b'Content-Type: application/octet-stream\r\n\r\n\x00\xff\r\n--BX\r\n'
                     b'--B\r\nContent-Disposition: form-data; name="files[]"; filename=""\r\n\r\n\r\n--B--\r\n')
        multipart_headers = (("Content-Type", 'multipart/form-data; boundary="B"'),)
        uploaded = json.loads(check_response(server, "/upload", 200, method="POST", body=multipart, headers=multipart_headers)[2])
        expected_parts = [
            dict(name_raw="files[]", filename_raw=None, content_type_raw=None, size=3, byte_sum=sum(b"001")),
            dict(name_raw="files[]", filename_raw="one.bin", content_type_raw="application/octet-stream", size=8, byte_sum=sum(b"\x00\xff\r\n--BX")),
            dict(name_raw="files[]", filename_raw="", content_type_raw=None, size=0, byte_sum=0),
        ]
        wire.require(uploaded == dict(accepted=1, parts=expected_parts), "flat upload metadata or bytes changed")
        # Every body byte is a separate HTTP chunk, including boundary syntax.
        chunked_upload = (b'POST /upload HTTP/1.1\r\nHost: localhost\r\n'
                          b'Content-Type: multipart/form-data; boundary=B\r\nTransfer-Encoding: chunked\r\n\r\n'
                          + b"".join(b"1\r\n" + bytes([byte]) + b"\r\n" for byte in multipart) + b"0\r\n\r\n")
        result = wire.request(server, chunked_upload)
        wire.require(result[0] == 200 and json.loads(result[2]) == dict(accepted=2, parts=expected_parts), "segmented upload copy changed parts")
        check_response(server, "/upload", 400, method="POST", body=multipart[:-8], headers=multipart_headers)
        wire.require(json.loads(check_response(server, "/upload-count", 200)[2])["accepted"] == 2, "malformed upload applied side effects")
        check_response(server, "/upload", 400, method="POST", body=multipart,
                       headers=(("Content-Type", "multipart/form-data; boundary=B; boundary=B"),))
        check_response(server, "/upload", 415, method="POST", body=multipart,
                       headers=multipart_headers + (("Content-Encoding", "gzip"),))
        passed("flat repeated fields/files, binary and empty uploads, chunk splits and validation before side effects")

        payload = bytes(range(256)) * 8
        check_response(server, "/echo", 200, payload, method="POST", body=payload)
        check_response(server, "/borrow", 200, payload, method="POST", body=payload)
        passed("copied and explicitly borrowed binary response bodies")

        with server.connect() as sock:
            sock.sendall(request_bytes("/headers"))
            data = b""
            while b"\r\n\r\n" not in data:
                data += sock.recv(4096)
                wire.require(len(data) <= 32768, "header fixture exceeded bound")
            head = data.split(b"\r\n\r\n", 1)[0]
            wire.require(head.count(b"\r\nSet-Cookie:") == 2, "cookies were merged")
            wire.require(b"X-App-Value: temporary\r\n" in head + b"\r\n", "header did not copy temporary bytes")
        redirect = check_response(server, "/redirect", 303, b"")
        wire.require(redirect[1][b"location"] == b"/hello", "redirect Location mismatch")
        passed("copied header metadata, repeated Set-Cookie and redirect framing")

        for path in ("/fail", "/invalid-header", "/too-large", "/no-response", "/twice"):
            result = check_response(server, path, 500)
            wire.require(b"Injected" not in result[2] and b"DemoFailure" not in result[2], "error details exposed")
        # Local decode capacity is a server-side failure, not invalid client data.
        check_response(server, "/hello?name=" + "a" * 1100, 500)
        check_response(server, "/service", 501)
        passed("unpublished response failures recover; inline service I/O is explicit")

        with server.connect() as sock:
            reader = wire.ResponseReader(sock)
            fragments = request_bytes("/hello?name=fragmented")
            for start in range(0, len(fragments), 3):
                sock.sendall(fragments[start:start + 3])
            wire.require(reader.response()[2] == b"fragmented", "fragmented request changed body")
            sock.sendall(request_bytes("/hello") + request_bytes("/invalid-header") + request_bytes("/hello?name=after"))
            wire.require(reader.response()[0] == 200, "earlier response lost")
            wire.require(reader.response()[0] == 500, "failed draft did not become 500")
            wire.require(reader.response()[2] == b"after", "connection was not reusable after draft error")
        passed("fragmented input and ordered recovery around a failed draft")

    with AppServer(binary, output_bytes=4096, response_body=1024) as server:
        with server.connect() as sock:
            sock.sendall(request_bytes("/count", method="POST") * 128 + request_bytes("/count"))
            reader = wire.ResponseReader(sock)
            values = [json.loads(reader.response()[2])["count"] for _ in range(129)]
            wire.require(values == list(range(1, 129)) + [128], "endpoint replay or state loss under output pressure")
        check_response(server, "/hello", 200)
    wire.require(server.stats["response_batches"] > 1, "reservation pressure did not drain batches")
    wire.require(server.stats["max_batch_responses"] > 1, "App silently disabled batching")
    passed("128 side-effecting requests execute once across bounded arena drains")

    with AppServer(binary, execution="workers", workers=2, stall_ms=150) as server:
        check_response(server, "/service", 200, b"worker service complete")
        check_response(server, "/hello?name=worker", 200, b"worker")
    passed("caller std.Io works in explicitly selected fixed workers")

    with AppServer(binary, timeout_ms=80) as server:
        with server.connect() as sock:
            sock.sendall(b"GET /hello HTTP/1.1\r\nHost:")
            wire.expect_closed(sock)
        check_response(server, "/hello", 200)
    wire.require(server.stats["timeouts"] >= 1, "request deadline did not fire")
    passed("incomplete-request deadline and subsequent recovery")

    with AppServer(binary, connections=2, timeout_ms=1000) as server:
        held = [server.connect(), server.connect()]
        try:
            for sock in held:
                sock.sendall(b"G")
            time.sleep(0.05)
            with server.connect() as overflow:
                wire.expect_closed(overflow)
        finally:
            for sock in held:
                sock.close()
        time.sleep(0.05)
        check_response(server, "/hello", 200)
    passed("connection overload refusal and admitted-slot recovery")

    with AppServer(binary, execution="workers", workers=1, timeout_ms=50, stall_ms=200) as server:
        with server.connect() as sock:
            sock.sendall(request_bytes("/service"))
            wire.expect_closed(sock)
    passed("deadline during worker service retains storage through callback return and shutdown")
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", type=Path, default=wire.ROOT / "zig-out/bin/baz")
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    cases = run(args.server.resolve())
    result = {"passed": len(cases), "cases": cases}
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
