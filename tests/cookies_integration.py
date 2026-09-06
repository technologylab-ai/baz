#!/usr/bin/env python3
"""ReleaseSafe cookie, redirect, and session wire gates.

The caller reserves the host and supplies an overall process-tree watchdog.
The shared harness bounds sockets and server startup/shutdown, then checks final
ownership and framework allocations. No timing or performance claims are made.
"""

import argparse
import json
from pathlib import Path
import platform
import sys

from app_integration import request_bytes
import wire_support as wire


class CookieServer(wire.Server):
    def __init__(self, binary, execution="inline", workers=0):
        super().__init__(binary)
        self.options = dict(port=0, execution=execution, workers=workers, connections=1, shards=1)

    def __enter__(self):
        super().__enter__()
        try:
            wire.require(any("optimize=ReleaseSafe" in line for line in self.lines),
                         "cookie wire gates require a ReleaseSafe binary")
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise
        return self


class CookieReader(wire.ResponseReader):
    """Retain individual header rows while using the shared bounded HTTP parser."""
    def __init__(self, sock):
        super().__init__(sock, maximum=16384)
        self.record_head = False
        self.rows = []

    def _line(self, maximum=16384):
        line = super()._line(maximum)
        if self.record_head:
            if not line:
                self.record_head = False
            elif not line.startswith(b"HTTP/1.1 "):
                wire.require(b":" in line, "malformed header in cookie response")
                name, value = line.split(b":", 1)
                self.rows.append((name.lower(), value.strip()))
        return line

    def response(self, head=False):
        self.rows = []
        self.record_head = True
        result = super().response(head=head)
        return (*result, tuple(self.rows))


def rows(response, name):
    return [value for key, value in response[3] if key == name]


def cookies(response):
    parsed = []
    for value in rows(response, b"set-cookie"):
        pair, *attributes = value.split(b"; ")
        name, separator, content = pair.partition(b"=")
        wire.require(separator == b"=", "Set-Cookie is missing its name/value separator")
        attrs = {}
        for attribute in attributes:
            key, separator, val = attribute.partition(b"=")
            key = key.lower()
            wire.require(key not in attrs, "duplicate cookie attribute")
            attrs[key] = val if separator else None
        parsed.append((name, content, attrs))
    return parsed


def call(sock, reader, path, status=200, method="GET", body=b"", headers=()):
    sock.sendall(request_bytes(path, method=method, body=body, headers=headers))
    response = reader.response(head=method == "HEAD")
    wire.require(response[0] == status, f"{method} {path}: expected {status}, got {response[0]} {response[2][:100]!r}")
    return response


def ping(sock, reader):
    response = call(sock, reader, "/ping")
    wire.require(response[2] == b"ok" and not rows(response, b"set-cookie"), "previous cookie draft leaked into the next request")


def redirect(response, status, location):
    wire.require(response[0] == status and response[2] == b"", "redirect has the wrong status or a body")
    wire.require(rows(response, b"location") == [location], "redirect changed or duplicated Location")
    wire.require(response[1].get(b"content-length") == b"0" and b"transfer-encoding" not in response[1],
                 "empty redirect has incorrect framing")


def session_cookie(response):
    fields = cookies(response)
    wire.require(len(fields) == 1 and fields[0][0] == b"demo-session", "login did not set one session cookie")
    name, token, attrs = fields[0]
    wire.require(len(token) == 64 and all(byte in b"0123456789abcdef" for byte in token), "session token is not opaque hex")
    wire.require(attrs.get(b"path") == b"/" and b"httponly" in attrs and attrs.get(b"samesite") == b"Strict",
                 "session cookie scope or security defaults changed")
    wire.require(b"max-age" not in attrs and b"expires" not in attrs and b"domain" not in attrs,
                 "session cookie unexpectedly became persistent or domain-scoped")
    return (name + b"=" + token).decode()


def deletion(response):
    fields = cookies(response)
    wire.require(len(fields) == 1 and fields[0][0:2] == (b"demo-session", b""), "logout did not clear its session cookie")
    attrs = fields[0][2]
    wire.require(attrs.get(b"max-age") == b"0" and attrs.get(b"expires") == b"Thu, 01 Jan 1970 00:00:00 GMT",
                 "logout deletion lacks immediate Max-Age and epoch expiry")
    wire.require(attrs.get(b"path") == b"/" and b"httponly" in attrs and attrs.get(b"samesite") == b"Strict",
                 "deletion did not retain the cookie scope and security options")


FORM = (("Content-Type", "application/x-www-form-urlencoded"),)
CREDENTIALS = b"username=zap&password=awesome"


def login(sock, reader, extra=()):
    result = call(sock, reader, "/login", status=303, method="POST", body=CREDENTIALS, headers=FORM + extra)
    redirect(result, 303, b"/normal_page")
    wire.require(result[1].get(b"cache-control") == b"no-store", "login response can be cached")
    return session_cookie(result)


def home(sock, reader, token):
    result = call(sock, reader, "/normal_page", headers=(("Cookie", token),))
    wire.require(b"You are logged in!" in result[2] and result[1].get(b"cache-control") == b"no-store",
                 "active session did not open its uncached protected page")
    return result


def run(directory):
    cases = []

    def passed(name, server):
        cases.append(dict(name=name, backend=server.backend, options=server.options, stats=server.stats))
        print("PASS " + name, flush=True)

    for execution, workers in (("inline", 0), ("workers", 1)):
        fixture = directory / "baz-cookies"
        with CookieServer(fixture, execution, workers) as server:
            with server.connect() as sock:
                reader = CookieReader(sock)
                result = call(sock, reader, "/set")
                fields = cookies(result)
                wire.require([field[0] for field in fields] == [b"session", b"remember", b"zero", b"negative", b"retired", b"minimal", b"repeat", b"repeat"],
                             "Set-Cookie rows were folded, lost, or reordered")
                session = fields[0]
                wire.require(session[1] == b"opaque%2B+001" and session[2] == {b"path": b"/", b"httponly": None, b"samesite": b"Lax"},
                             "session defaults or raw cookie value changed")
                wire.require(fields[1][2] == {b"path": b"/prefs", b"domain": b"example.test", b"max-age": b"3600", b"expires": b"Tue, 01 Jan 2030 00:00:00 GMT", b"secure": None, b"samesite": b"Strict"},
                             "persistent cookie attributes changed")
                wire.require(fields[2][2].get(b"max-age") == b"0" and b"expires" not in fields[2][2], "zero Max-Age was omitted or gained implicit Expires")
                wire.require(fields[3][2].get(b"max-age") == b"-7", "negative Max-Age lost its sign")
                wire.require(fields[4][1] == b"" and fields[4][2] == {b"path": b"/account", b"domain": b"example.test", b"max-age": b"0", b"expires": b"Thu, 01 Jan 1970 00:00:00 GMT", b"secure": None, b"httponly": None, b"samesite": b"None"},
                             "deleteCookie did not override expiry while retaining its scope")
                wire.require(fields[5] == (b"minimal", b"raw", {}), "explicit omitted attributes were restored")
                wire.require([(item[1], item[2][b"path"]) for item in fields[6:]] == [(b"first", b"/one"), (b"second", b"/two")], "same-name cookies lost distinct paths")
                expiry_fields = cookies(call(sock, reader, "/expires-only"))
                wire.require(len(expiry_fields) == 1 and expiry_fields[0][2].get(b"expires") == b"Tue, 01 Jan 2030 00:00:00 GMT" and
                             b"max-age" not in expiry_fields[0][2], "Expires alone unexpectedly gained Max-Age")
                head = call(sock, reader, "/set", method="HEAD")
                wire.require(head[2] == b"" and head[1].get(b"content-length") == b"7" and rows(head, b"set-cookie") == rows(result, b"set-cookie"),
                             "HEAD changed cookies or emitted a body")
                ping(sock, reader)
                if workers:
                    streamed = call(sock, reader, "/stream-cookie")
                    wire.require(streamed[1].get(b"transfer-encoding") == b"chunked" and streamed[2] == b"first|InvalidState|last",
                                 "cookie mutation after first flush changed or interrupted the stream")
                    wire.require([(item[0], item[1]) for item in cookies(streamed)] == [(b"stream", b"initial")],
                                 "stream published a cookie after its first flush")
                    ping(sock, reader)
        passed("separate Set-Cookie fields, session/persistent options, deletion and HEAD in " + execution, server)

        with CookieServer(fixture, execution, workers) as server:
            with server.connect() as sock:
                reader = CookieReader(sock)
                headers = (("Cookie", 'sid=a%20+b; quoted="001"; empty='), ("cOoKiE", "other=false; other=001; SID=case"))
                data = json.loads(call(sock, reader, "/inspect", headers=headers)[2])
                wire.require(data["count"] == 6 and data["sid"] == "a%20+b", "Cookie headers were decoded or merged")
                wire.require(data["items"][1] == dict(name_raw="quoted", value_raw="001", quoted=True), "quoted cookie view lost raw text or quote state")
                wire.require([item["name_raw"] for item in data["items"]] == ["sid", "quoted", "empty", "other", "other", "SID"], "request cookies lost wire order or case")
                wire.require(json.loads(call(sock, reader, "/cookie", headers=headers)[2]) == {"sid": "a%20+b"}, "Request.cookie changed raw data")
                for value, expected in (("sid=", ""), ("sid=%GG+001", "%GG+001"), ("SID=only", None)):
                    wire.require(json.loads(call(sock, reader, "/cookie", headers=(("Cookie", value),))[2]) == {"sid": expected}, "unique cookie changed missing/empty/case semantics")
                wire.require(json.loads(call(sock, reader, "/cookie")[2]) == {"sid": None}, "missing cookie did not return null")
                duplicates = ((("Cookie", "sid=a; sid=a"),), (("Cookie", "sid="), ("Cookie", "sid=")))
                for route in ("/inspect", "/cookie", "/default-cookie"):
                    for duplicate in duplicates:
                        call(sock, reader, route, status=400, headers=duplicate)
                        ping(sock, reader)
                for value in ("", "broken", "=value", 'sid="open', "sid=a b", "sid=a,b", "sid=a;", "other=bad\\value"):
                    for route in ("/inspect", "/cookie", "/default-cookie"):
                        result = call(sock, reader, route, status=400, headers=(("Cookie", value),))
                        wire.require(not rows(result, b"set-cookie"), "malformed request emitted a response cookie")
                        ping(sock, reader)
        passed("borrowed raw request cookies, duplicate rejection and malformed-header recovery in " + execution, server)

        with CookieServer(fixture, execution, workers) as server:
            with server.connect() as sock:
                reader = CookieReader(sock)
                for value in ("a=1; b=2; c=3; d=4", "n" * 16 + "=v", "sid=" + "v" * 32):
                    call(sock, reader, "/bounded", headers=(("Cookie", value),))
                bounds = [((("Cookie", "a=1; b=2; c=3; d=4; e=5"),), b"TooManyCookies", 431),
                          ((("Cookie", "n" * 17 + "=v"),), b"NameTooLarge", 413),
                          ((("Cookie", "sid=" + "v" * 33),), b"ValueTooLarge", 413),
                          (tuple(("Cookie", f"k{index}=" + "v" * 30) for index in range(3)), b"CookiesTooLarge", 431)]
                for headers, error, default_status in bounds:
                    result = call(sock, reader, "/bounded", status=431, headers=headers)
                    wire.require(result[2] == error, "explicit cookie bounds reported the wrong limit")
                    call(sock, reader, "/default-bounded", status=default_status, headers=headers)
                    call(sock, reader, "/inspect", headers=headers)  # The default limits accept the same bytes.
                    ping(sock, reader)
                call(sock, reader, "/default-bounded", status=400, headers=(("Cookie", "broken"),))
                call(sock, reader, "/default-bounded", status=400, headers=(("Cookie", "sid=a"), ("Cookie", "sid=b")))
                ping(sock, reader)
        passed("cookie bounds and uncaught App400/413/431 mapping in " + execution, server)

        with CookieServer(fixture, execution, workers) as server:
            with server.connect() as sock:
                reader = CookieReader(sock)
                probes = dict(name="InvalidCookieName", value="InvalidCookieValue", path="InvalidCookiePath", domain="InvalidCookieDomain",
                              expiry="InvalidCookieExpiry", insecure="InsecureCookie", secure_prefix="InvalidCookiePrefix", host_prefix="InvalidCookiePrefix", header_limit="ResponseLimit")
                for probe, error in probes.items():
                    result = call(sock, reader, "/invalid-cookie/" + probe)
                    wire.require(result[2] == error.encode(), "cookie validation returned the wrong error")
                    wire.require([(item[0], item[1]) for item in cookies(result)] == [(b"before", b"kept"), (b"after", b"kept")],
                                 "failed cookie mutation changed existing or subsequent headers")
                    wire.require(b"injected" not in result[1], "cookie validation allowed header injection")
                    ping(sock, reader)
                result = call(sock, reader, "/limit-count")
                wire.require(result[2] == b"ResponseLimit" and rows(result, b"set-cookie") == [f"c{index}=1".encode() for index in range(8)],
                             "cookie header count overflow lost or appended a header")
                ping(sock, reader)
        passed("cookie validation and byte/count bounds fail atomically in " + execution, server)

        with CookieServer(fixture, execution, workers) as server:
            with server.connect() as sock:
                reader = CookieReader(sock)
                for status in (301, 302, 303, 307, 308):
                    for method in ("GET", "POST", "HEAD"):
                        result = call(sock, reader, f"/redirect/{status}", status=status, method=method,
                                      body=b"kept as request data" if method == "POST" else b"")
                        redirect(result, status, b"https://example.test/next?raw=a%2Bb#part")
                for probe in ("status", "empty", "space", "backslash", "escape", "non_ascii", "crlf", "quote", "brackets", "duplicate"):
                    result = call(sock, reader, "/invalid-redirect/" + probe)
                    wire.require(result[2] == (b"DuplicateLocation" if probe == "duplicate" else b"InvalidRedirect"), "invalid redirect returned the wrong error")
                    wire.require(rows(result, b"location") == ([b"/kept"] if probe == "duplicate" else []), "invalid redirect changed Location")
                    wire.require([(item[0], item[1]) for item in cookies(result)] == [(b"before", b"kept"), (b"after", b"kept")], "invalid redirect changed unrelated cookies")
                    wire.require(b"injected" not in result[1], "redirect allowed header injection")
                    ping(sock, reader)
        passed("301/302/303/307/308 redirects and atomic destination validation in " + execution, server)

        session = directory / "userpass_session"
        with CookieServer(session, execution, workers) as server:
            with server.connect() as sock:
                reader = CookieReader(sock)
                redirect(call(sock, reader, "/", status=303), 303, b"/login")
                wire.require(b'name="username"' in call(sock, reader, "/login")[2], "login browser form missing")
                denied = call(sock, reader, "/login", status=401, method="POST", body=b"username=zap&password=wrong", headers=FORM)
                wire.require(not rows(denied, b"set-cookie"), "failed login created a cookie")
                first = login(sock, reader)
                home(sock, reader, first)
                get_logout = call(sock, reader, "/logout", headers=(("Cookie", first),))
                wire.require(not rows(get_logout, b"set-cookie"), "GET logout changed session cookies")
                home(sock, reader, first)
                ambiguous = (("Cookie", first), ("Cookie", first))
                redirect(call(sock, reader, "/normal_page", status=303, headers=ambiguous), 303, b"/login")
                home(sock, reader, first)
                second = login(sock, reader, (("Cookie", first),))
                wire.require(first != second, "replacement login reused a retired token")
                redirect(call(sock, reader, "/normal_page", status=303, headers=(("Cookie", first),)), 303, b"/login")
                home(sock, reader, second)
                logged_out = call(sock, reader, "/logout", status=303, method="POST", headers=(("Cookie", second),))
                redirect(logged_out, 303, b"/login")
                deletion(logged_out)
                redirect(call(sock, reader, "/normal_page", status=303, headers=(("Cookie", second),)), 303, b"/login")
                third = login(sock, reader)
                wire.require(third not in (first, second), "logout replay revived a retired token")
                home(sock, reader, third)
        passed("session cookie login, replacement, duplicate rejection, logout and replay invalidation in " + execution, server)

        with CookieServer(session, execution, workers) as server:
            with server.connect() as sock:
                reader = CookieReader(sock)
                token = login(sock, reader)
                origins = [(("Sec-Fetch-Site", value),) for value in ("cross-site", "same-site", "unknown", "")]
                origins.append((("Sec-Fetch-Site", "same-origin"), ("sec-fetch-site", "same-origin")))
                for origin in origins:
                    for route in ("/login", "/normal_page", "/logout", "/logout-all", "/stop"):
                        result = call(sock, reader, route, status=403, method="POST", body=b"invalid form",
                                      headers=(("Content-Type", "text/plain"), ("Cookie", token)) + origin)
                        wire.require(result[2] == b"Cross-origin POST rejected" and not rows(result, b"set-cookie"),
                                     "Fetch Metadata guard ran after parsing or changed session cookies")
                        home(sock, reader, token)  # Rejected logout/stop/login must not retire or replace it.
                replacement = login(sock, reader, (("Cookie", token), ("Sec-Fetch-Site", "same-origin")))
                home(sock, reader, replacement)
                logout = call(sock, reader, "/logout", status=303, method="POST",
                              headers=(("Cookie", replacement), ("Sec-Fetch-Site", "none")))
                deletion(logout)
                redirect(call(sock, reader, "/normal_page", status=303, headers=(("Cookie", replacement),)), 303, b"/login")
        passed("Fetch Metadata rejects unsafe POSTs before parsing or session mutation in " + execution, server)

    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", type=Path, default=wire.ROOT / "zig-out/bin")
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    cases = run(args.bin_dir.resolve())
    result = dict(passed=len(cases), cases=cases, platform=platform.platform(), python=sys.version)
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
