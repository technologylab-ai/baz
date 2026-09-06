#!/usr/bin/env python3
"""Native behavior and terminal-ownership checks for the supported Zap ports."""
import argparse
from contextlib import contextmanager
import json
from pathlib import Path

import wire_support as wire
from app_integration import request_bytes


class ExampleServer(wire.Server):
    def __init__(self, binary, workers=0):
        super().__init__(binary)
        self.options = dict(port=0, connections=16, execution="workers" if workers else "inline",
                            workers=workers, shards=1)


def call(server, path="/", status=200, expected=None, **kwargs):
    response = wire.request(server, request_bytes(path, **kwargs), head=kwargs.get("method") == "HEAD")
    wire.require(response[0] == status, f"{server.binary.name} {path}: expected {status}, got {response[0]} {response[2]!r}")
    if expected is not None:
        wire.require(response[2] == expected, f"{server.binary.name} {path}: unexpected body {response[2]!r}")
    return response


def run(directory):
    passed = []

    @contextmanager
    def case(name, workers=0):
        with ExampleServer(directory / name, workers=workers) as server:
            yield server
        passed.append(name)
        print("PASS " + name, flush=True)

    with case("hello") as server:
        wire.require(b"<h1>Hello" in call(server)[2], "greeting missing")
        call(server, method="HEAD", expected=b"")
        call(server, "/missing", status=404)

    with case("hello2") as server:
        wire.require(b"<form" in call(server)[2], "browser form missing")
        result = json.loads(call(server, "/inspect?value=001&value=false", method="POST", body=b"name=x+y%20z",
                                 headers=(("Special-Header", "present"),))[2])
        wire.require(result["query_raw"] == "value=001&value=false" and result["body_raw"] == "name=x+y%20z"
                     and result["special_header"] == "present" and result["method"] == "POST", "inspection changed raw bytes")
        call(server, "/inspect", status=413, method="POST", body=b"x" * 2049)

    with case("hello_json") as server:
        wire.require(json.loads(call(server, "/user/1")[2])["first_name"] == "renerocksai", "user lookup failed")
        call(server, "/user/abc", status=400)
        call(server, "/user/999999999999999999999999999", status=400)
        call(server, "/user/3", status=404, expected=b"null")

    with case("simple_router") as server:
        call(server, "/geta", expected=b"A value is 1\n")
        call(server, "/inca", method="POST", expected=b"incremented A")
        call(server, "/geta", expected=b"A value is 2\n")
        call(server, "/getb", expected=b"B value is 2\n")
        call(server, "/missing", status=404)

    with case("routes") as server:
        wire.require(b"STATIC" in call(server, "/static")[2], "static route missing")
        wire.require(b"# 1" in call(server, "/dynamic")[2], "first state update wrong")
        wire.require(b"# 2" in call(server, "/dynamic")[2], "second state update wrong")
        wire.require(b"/dynamic" in call(server, "/menu-fallback")[2], "custom fallback missing")

    with case("serve") as server:
        assets = wire.ROOT / "examples/assets"
        call(server, expected=(assets / "serve_index.html").read_bytes())
        call(server, "/two.html", expected=(assets / "serve_two.html").read_bytes())
        call(server, "/../build.zig", status=404)

    with case("sendfile") as server:
        result = call(server, "/testfile.txt", expected=(wire.ROOT / "examples/assets/sendfile.txt").read_bytes(),
                      headers=(("Range", "bytes=0-2"),))
        wire.require(result[1][b"accept-ranges"] == b"none", "file example claimed unsupported ranges")

    with case("senderror") as server:
        wire.require(json.loads(call(server, status=500)[2]) == {"error": "request failed"}, "private error leaked")

    with case("accept") as server:
        wire.require(call(server)[1][b"content-type"] == b"text/html", "default representation differs")
        preferred = call(server, headers=(("Accept", "text/html;q=0, */*;q=0.2, application/json;q=0.9"),))
        wire.require(preferred[1][b"content-type"] == b"application/json" and preferred[1][b"vary"] == b"Accept", "weighted content negotiation failed")
        excluded = call(server, headers=(("Accept", "text/html;q=0, text/*;q=1"),))
        wire.require(excluded[1][b"content-type"] == b"text/plain", "wildcard overrode specific exclusion")
        call(server, status=406, headers=(("Accept", "image/png"),))
        call(server, status=400, headers=(("Accept", "text/html;q=1.5"),))
        call(server, status=431, headers=(("Accept", ",".join(["text/plain"] * 33)),))

    with case("app_basic") as server:
        result = call(server, "/test")[2]
        wire.require(b"db connection established!" in result and b"some endpoint specific data" in result, "typed instance state missing")
        with server.connect() as sock:
            sock.sendall(request_bytes("/stop"))
        wire.require(server.process.wait(timeout=3) == 0, "instance stop failed")

    for name in ("app_auth", "endpoint_auth"):
        with case(name) as server:
            unauthorized = call(server, "/test", status=401)
            wire.require(b"bearer" in unauthorized[1][b"www-authenticate"].lower(), "bearer challenge missing")
            call(server, "/test", headers=(("Authorization", "Bearer ABCDEFG"),))
            call(server, "/test", status=401, headers=(("Authorization", "Bearer wrong"),))
            call(server, "/test", status=401, headers=(("Authorization", "Bearer ABCDEFG"), ("Authorization", "Bearer ABCDEFG")))

    with case("app_errors") as server:
        for _ in range(2):
            result = call(server, "/error", status=500)
            wire.require(b"x-unpublished" not in result[1] and result[1][b"x-error-handled"] == b"app", "draft rollback lost mapper isolation")
        wire.require(json.loads(call(server, "/state")[2])["errors"] == 2, "error mapper was not instance-owned")

    with case("cookies") as server:
        result = call(server, headers=(("Cookie", 'ZIG_ZAP=a%20+b; other="001"; other=false'),))
        data = json.loads(result[2])
        wire.require(data["zig_zap"] == "a%20+b" and data["count"] == 3 and data["cookies"][1]["quoted"], "cookies were decoded or merged")
        wire.require(b"HttpOnly" in result[1][b"set-cookie"], "cookie response missing")
        call(server, status=400, headers=(("Cookie", "ZIG_ZAP=a; ZIG_ZAP=b"),))
        call(server, status=400, headers=(("Cookie", "broken"),))

    for name in ("middleware", "middleware_with_endpoint"):
        with case(name) as server:
            result = call(server)
            wire.require(result[1][b"x-middleware-order"].startswith(b"user, session,") and b"renerocksai" in result[2], "middleware order/context lost")
            denied = call(server, status=403, headers=(("X-Deny", "1"),))
            wire.require(b"x-middleware-order" not in denied[1], "middleware continued after early response")
            wire.require(b"renerocksai" in call(server)[2], "locals leaked into next request")

    with case("http_params") as server:
        result = json.loads(call(server, "/?one=001&string=a+b%2Bc&flag&tag=a&tag=b")[2])
        wire.require(result["one_raw"] == "001" and result["form"] is None and len(result["query"]) == 5, "parameter values changed")
        wire.require(result["string"] == dict(raw="a+b%2Bc", percent_decoded="a+b+c", form_decoded="a b+c"), "explicit decoding differs")
        wire.require(result["query"][2]["has_equals"] is False, "bare key lost")
        result = json.loads(call(server, "/?one=query", method="POST", body=b"one=form&bool=false",
                                 headers=(("Content-Type", "application/x-www-form-urlencoded"),))[2])
        wire.require(result["one_raw"] == "query" and result["form"][0]["value_raw"] == "form", "query/form were merged")
        call(server, "/?" + "a=&" * 9, status=413)

    with case("bindataformpost") as server:
        payload = (b'--B\r\nContent-Disposition: form-data; name="img"; filename="a.bin"\r\n\r\n\x00\xff\r\n'
                   b'--B\r\nContent-Disposition: form-data; name="img"; filename=""\r\n\r\n\r\n--B--\r\n')
        content_type = (("Content-Type", "multipart/form-data; boundary=B"),)
        parts = json.loads(call(server, method="POST", body=payload, headers=content_type)[2])["parts"]
        wire.require(len(parts) == 2 and [part["name_raw"] for part in parts] == ["img", "img"], "upload became synthetic array fields")
        wire.require(parts[0]["data_preview_hex"] == "00ff" and parts[0]["byte_sum"] == 255 and parts[1]["filename_raw"] == "" and parts[1]["size"] == 0, "binary/empty upload changed")
        call(server, status=400, method="POST", body=payload[:-8], headers=content_type)

    with case("endpoint", workers=2) as server:
        users = json.loads(call(server, "/users")[2])
        wire.require([user["id"] for user in users] == [1, 2], "seeded user table differs")
        json_type = (("Content-Type", "application/json"),)
        created = json.loads(call(server, "/users", status=201, method="POST",
                                  body=b'{"first_name":"Ada","last_name":"Lovelace"}', headers=json_type)[2])
        wire.require(created["id"] == 3, "first user ID differs")
        call(server, "/users/3", method="PATCH", body=b'{"last_name":"Byron"}', headers=json_type)
        user = json.loads(call(server, "/users/3")[2])
        wire.require(user == dict(id=3, first_name="Ada", last_name="Byron"), "partial update or retained name ownership failed")
        call(server, "/users/3", status=413, method="PATCH",
             body=json.dumps(dict(first_name="changed", last_name="x" * 65)).encode(), headers=json_type)
        wire.require(json.loads(call(server, "/users/3")[2]) == user, "failed update partially changed the user")
        call(server, "/users", status=400, method="POST", body=b"{bad", headers=json_type)
        call(server, "/users/bad", status=400)
        call(server, "/users/3", method="DELETE")
        call(server, "/users/3", status=404)
        for index in range(14):
            call(server, "/users", status=201, method="POST", body=json.dumps(dict(first_name=f"user{index}")).encode(), headers=json_type)
        call(server, "/users", status=503, method="POST", body=b'{"first_name":"overflow"}', headers=json_type)
        wire.require(len(json.loads(call(server, "/users")[2])) == 16, "table capacity drifted")
        call(server, "/users", method="HEAD", expected=b"")
        call(server, "/users", method="OPTIONS", status=204, expected=b"")

    with case("userpass_session") as server:
        wire.require(call(server, status=303)[1][b"location"] == b"/login", "anonymous request not redirected")
        wire.require(b"<form" in call(server, "/login")[2], "login form missing")
        form_type = (("Content-Type", "application/x-www-form-urlencoded"),)
        call(server, "/login", status=401, method="POST", body=b"username=zap&password=wrong", headers=form_type)

        def login():
            result = call(server, "/login", status=303, method="POST", body=b"username=zap&password=awesome", headers=form_type)
            wire.require(result[1][b"location"] == b"/normal_page", "login redirect missing")
            cookie = result[1][b"set-cookie"].split(b";", 1)[0].decode()
            token = cookie.split("=", 1)[1]
            wire.require(len(token) == 64 and all(c in "0123456789abcdef" for c in token), "session token malformed")
            return cookie

        first = login()
        wire.require(b"You are logged in!" in call(server, "/normal_page", headers=(("Cookie", first),))[2], "session did not authenticate")
        call(server, "/logout", status=303, method="POST", headers=(("Cookie", first),))
        call(server, "/normal_page", status=303, headers=(("Cookie", first),))
        second = login()
        wire.require(first != second, "retired session token was reused")
        tokens = {first, second}
        for _ in range(30):
            tokens.add(login())
        wire.require(len(tokens) == 32, "startup token pool repeated a token")
        call(server, "/normal_page", status=303, headers=(("Cookie", second),))
        call(server, "/login", status=503, method="POST", body=b"username=zap&password=awesome", headers=form_type)

    return passed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", type=Path, default=wire.ROOT / "zig-out/bin")
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    cases = run(args.bin_dir.resolve())
    result = dict(passed=len(cases), cases=cases)
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
