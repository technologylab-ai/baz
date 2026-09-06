#!/usr/bin/env python3
"""ReleaseSafe bounded session lifecycle gates for inline and worker execution.

The caller reserves the host and supplies an overall process-tree watchdog.
Clock boundaries use unit tests. Wire tests use finite waits to check real expiry.
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
from cli_integration import exits_before_ready
from cookies_integration import (CookieReader, CookieServer, CREDENTIALS, FORM,
                                 call, deletion, home, login, redirect, rows, session_cookie)
import wire_support as wire


class SessionServer(CookieServer):
    def __init__(self, binary, execution, workers, ttl_ms=1800000):
        super().__init__(binary, execution, workers)
        self.options["connections"] = max(1, workers)
        self.options["session_ttl_ms"] = ttl_ms


def logged_out(sock, reader, token):
    redirect(call(sock, reader, "/normal_page", status=303, headers=(("Cookie", token),)), 303, b"/login")


def logout(sock, reader, token, all_devices=False):
    response = call(sock, reader, "/logout-all" if all_devices else "/logout", status=303,
                    method="POST", headers=(("Cookie", token),))
    redirect(response, 303, b"/login")
    deletion(response)


def run(directory):
    cases = []

    def passed(name, server):
        cases.append(dict(name=name, backend=server.backend, options=server.options, stats=server.stats))
        print("PASS " + name, flush=True)

    binary = directory / "userpass_session"
    for execution, workers in (("inline", 0), ("workers", 2)):
        with SessionServer(binary, execution, workers) as server:
            with server.connect() as sock:
                reader = CookieReader(sock)
                first = login(sock, reader)
                second = login(sock, reader)
                home(sock, reader, first)
                home(sock, reader, second)
                replacement = login(sock, reader, (("Cookie", first),))
                wire.require(len({first, second, replacement}) == 3, "rotation repeated a token")
                logged_out(sock, reader, first)
                home(sock, reader, second)
                home(sock, reader, replacement)
                logout(sock, reader, replacement)
                logged_out(sock, reader, replacement)
                home(sock, reader, second)
                third = login(sock, reader)
                logout(sock, reader, second, all_devices=True)
                logged_out(sock, reader, second)
                logged_out(sock, reader, third)
                fresh = login(sock, reader)
                wire.require(fresh not in (first, second, replacement, third), "account revocation reused a token")
                home(sock, reader, fresh)
        passed("independent devices, presented-token rotation, logout and account revocation in " + execution, server)

        concurrent_server = SessionServer(binary, execution, workers)
        concurrent_server.options["connections"] = 8
        with concurrent_server as server:
            with ExitStack() as clients:
                peers = []
                for _ in range(8):
                    sock = clients.enter_context(server.connect())
                    reader = CookieReader(sock)
                    call(sock, reader, "/login")  # Admit every connection before the concurrent request wave.
                    peers.append((sock, reader))
                start = threading.Barrier(8)

                def concurrent_login(peer):
                    sock, reader = peer
                    start.wait(timeout=3)
                    sock.sendall(request_bytes("/login", method="POST", body=CREDENTIALS, headers=FORM))
                    response = reader.response()
                    if response[0] == 303:
                        redirect(response, 303, b"/normal_page")
                        return session_cookie(response)
                    wire.require(response[0] == 503 and response[2] == b"Session state is busy",
                                 "concurrent login failed outside the documented session guard")
                    wire.require(not rows(response, b"set-cookie") and not rows(response, b"location"),
                                 "contended login published a partial session response")
                    return None

                with ThreadPoolExecutor(max_workers=8) as workers_pool:
                    futures = [workers_pool.submit(concurrent_login, peer) for peer in peers]
                    results = [future.result(timeout=8) for future in futures]
                tokens = [token for token in results if token is not None]
                wire.require(tokens and len(set(tokens)) == len(tokens), "concurrent login produced no valid or distinct tokens")
                sock, reader = peers[0]
                for token in tokens:
                    home(sock, reader, token)
                # Failed contenders must not consume slots. Fill the exact remaining capacity.
                concurrent_successes = len(tokens)
                for _ in range(32 - concurrent_successes):
                    tokens.append(login(sock, reader))
                wire.require(len(set(tokens)) == 32, "concurrent session state corrupted later token generation")
                full = call(sock, reader, "/login", status=503, method="POST", body=CREDENTIALS, headers=FORM)
                wire.require(not rows(full, b"set-cookie"), "full storage changed cookies after concurrent logins")
                for token in tokens:
                    home(sock, reader, token)
        passed("eight concurrent clients preserve session tokens and exact capacity in " + execution, server)
        cases[-1]["concurrent_results"] = dict(successful=concurrent_successes, contended=8 - concurrent_successes)

        with SessionServer(binary, execution, workers) as server:
            with server.connect() as sock:
                reader = CookieReader(sock)
                tokens = [login(sock, reader) for _ in range(32)]
                wire.require(len(set(tokens)) == 32, "concurrent sessions share a token")
                for extra in ((), (("Cookie", tokens[0]),)):
                    full = call(sock, reader, "/login", status=503, method="POST", body=CREDENTIALS, headers=FORM + extra)
                    wire.require(not rows(full, b"set-cookie"), "full storage changed the browser cookie")
                for token in tokens:
                    home(sock, reader, token)
                logout(sock, reader, tokens[0])
                replacement = login(sock, reader)
                wire.require(replacement not in tokens, "freed slot restored an old token")
                logged_out(sock, reader, tokens[0])
                home(sock, reader, replacement)
                for token in tokens[1:]:
                    home(sock, reader, token)
        passed("32 concurrent sessions reject overflow without eviction and logout frees one slot in " + execution, server)

        with SessionServer(binary, execution, workers) as server:
            with server.connect() as sock:
                reader = CookieReader(sock)
                retired = set()
                for _ in range(64):
                    token = login(sock, reader)
                    wire.require(token not in retired, "sequential login reused a retired token")
                    home(sock, reader, token)
                    logout(sock, reader, token)
                    logged_out(sock, reader, token)
                    retired.add(token)
        passed("64 sequential login/logout cycles reuse storage without reviving tokens in " + execution, server)

        with SessionServer(binary, execution, workers, ttl_ms=1000) as server:
            with server.connect() as sock:
                reader = CookieReader(sock)
                token = login(sock, reader)  # The helper checks absence of Max-Age and Expires.
                home(sock, reader, token)
                deadline = time.monotonic() + 3
                while True:
                    sock.sendall(request_bytes("/normal_page", headers=(("Cookie", token),)))
                    response = reader.response()
                    wire.require(not rows(response, b"set-cookie"), "authentication silently renewed the cookie")
                    if response[0] == 303:
                        redirect(response, 303, b"/login")
                        break
                    wire.require(response[0] == 200, "expiry check returned an unexpected status")
                    wire.require(time.monotonic() < deadline, "authenticated page visits extended the server deadline")
                    time.sleep(0.15)
                logged_out(sock, reader, token)
                fresh = login(sock, reader)
                wire.require(fresh != token, "expired token was reused")
                home(sock, reader, fresh)
        passed("server expiry is independent of browser-session cookies and never slides in " + execution, server)

        with SessionServer(binary, execution, workers, ttl_ms=1000) as server:
            with server.connect() as sock:
                reader = CookieReader(sock)
                expired = [login(sock, reader) for _ in range(32)]
                time.sleep(1.1)  # Start after the final login response; every server deadline has passed.
                fresh = login(sock, reader)  # Creation itself must collect expired capacity.
                wire.require(fresh not in expired, "expiry reused an old token")
                home(sock, reader, fresh)
                for token in expired:
                    logged_out(sock, reader, token)
        passed("new login reclaims expired capacity without logout or a prior lookup in " + execution, server)

        with SessionServer(binary, execution, workers) as server:
            with server.connect() as sock:
                reader = CookieReader(sock)
                token = login(sock, reader)
                for raw in ("demo-session=", "demo-session=short", "demo-session=" + "A" * 64,
                            "demo-session=" + "g" * 64, "demo-session=" + "0" * 64):
                    logged_out(sock, reader, raw)
                    home(sock, reader, token)
                ambiguous = (("Cookie", token), ("Cookie", token))
                failed = call(sock, reader, "/login", status=400, method="POST", body=CREDENTIALS,
                              headers=FORM + ambiguous)
                wire.require(not rows(failed, b"set-cookie"), "ambiguous login changed a session")
                failed = call(sock, reader, "/login", status=401, method="POST",
                              body=b"username=zap&password=wrong", headers=FORM + (("Cookie", token),))
                wire.require(not rows(failed, b"set-cookie"), "failed credentials changed a session")
                home(sock, reader, token)
        passed("invalid tokens, ambiguous cookies and failed credentials preserve live sessions in " + execution, server)

        with SessionServer(binary, execution, workers) as server:
            with server.connect() as sock:
                reader = CookieReader(sock)
                redirect(call(sock, reader, "/stop", status=303, method="POST"), 303, b"/login")
                token = login(sock, reader)
                # requestStop may retire this connection before its prepared response is sent.
                # Authorization and terminal ownership are the guarantees under test here.
                sock.sendall(request_bytes("/stop", method="POST", headers=(("Cookie", token),)))
                wire.require(server.process.wait(timeout=5) == 0, "authenticated shutdown did not finish")
        passed("only an authenticated request can stop the session example in " + execution, server)

    executable = SessionServer(binary, "inline", 0).binary
    exits = []
    for arguments, diagnostic in ((["--session-ttl-ms=0"], "InvalidSessionTtl"),
                                  (["--session-ttl-ms=4294967296"], "session-ttl-ms"),
                                  (["--session-ttl-ms=-1"], "session-ttl-ms"),
                                  (["--session-ttl-ms=1", "--session-ttl-ms=2"], "duplicate")):
        exits.append(exits_before_ready(executable, arguments, 1, diagnostic))
    cases.append(dict(name="invalid session lifetime arguments fail before startup", exits=exits))
    print("PASS invalid session lifetime arguments fail before startup", flush=True)
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
