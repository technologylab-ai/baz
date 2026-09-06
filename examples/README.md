# Zap example ports

These examples adapt the public behavior of our predecessor
[Zap](https://github.com/zigzap/zap), using the local Zig 0.16 port at
`f6099ecec496c7ec623c5913baa5b6b5da2e883d`, using the new `baz` API and
the external [bounded/http](https://technologylab-ai.github.io/bounded-http/) engine. Original source: [the pinned Zap examples](https://github.com/zigzap/zap/tree/f6099ecec496c7ec623c5913baa5b6b5da2e883d/examples).
Zap's copyright/license is preserved in [LICENSE-ZAP](LICENSE-ZAP).

The 20 supported examples are standalone executables on Linux, macOS, and native
Windows x64. All 20 passed the [native three-platform gate](../reports/2026-09-06-windows-baz.md). Each uses the public
framework import and [shared executable support](support.zig); there is no
facil.io dependency. Names retain the original build targets for easy comparison.

```sh
zig build examples -Doptimize=ReleaseSafe
./zig-out/bin/hello --port 8080
zig build run-http_params -Doptimize=ReleaseSafe -- --port 8080
python3 tests/examples_integration.py
```

`zig build verify` compiles every example in addition to running the framework
tests. `zig build NAME` installs just that example; `zig build run-NAME` runs it.
Common flags: `--port`, `--duration-ms`, `--connections`, `--execution`,
`--workers`, and `--shards`. The CRUD `endpoint` example requires workers and
one shard. IPv4 loopback/plain HTTP restrictions apply to all.
Use Ctrl-C for a clean drain (SIGINT/SIGTERM on POSIX; Ctrl-C/Ctrl-Break console
events on Windows). Windows binaries have an `.exe` suffix; use `curl.exe` for
HTTP examples in PowerShell. READY and final STATS use the same finite
test harness as the engine. A handler-triggered stop may close its own response
before delivery; only terminal shutdown establishes released storage.

| Original target | Port | Preserved purpose and deliberate adaptation |
| --- | --- | --- |
| `hello` | [hello.zig](hello.zig) | Minimal HTML response with an explicit route. |
| `hello2` | [hello2.zig](hello2.zig) | GET/POST inspection of method, raw query, headers and bounded body; response inspection replaces blocking callback logging. |
| `hello_json` | [hello_json.zig](hello_json.zig) | Small JSON user lookup with explicit ID parsing. |
| `simple_router` | [simple_router.zig](simple_router.zig) | Functions and bound stateful routes; synchronized counter. |
| `routes` | [routes.zig](routes.zig) | Static and dynamic responses in one router. |
| `serve` | [serve.zig](serve.zig) | Explicit embedded-file routes. There is no arbitrary filesystem/public-directory lookup on the I/O loop. |
| `sendfile` | [sendfile.zig](sendfile.zig) | File content as an immutable embedded asset. This is a response-content port; no sendfile syscall, compression or range feature is claimed. |
| `senderror` | [senderror.zig](senderror.zig) | Controlled error response with no client-visible stack trace. |
| `accept` | [accept.zig](accept.zig) | Explicit bounded content negotiation for the original media types; supported range/quality profile is documented in source. |
| `app_basic` | [app_basic.zig](app_basic.zig) | Typed Shared, ordinary endpoint state and instance stop. |
| `app_auth` | [app_auth.zig](app_auth.zig) | Typed bearer-authentication wrapper with early unauthorized response. |
| `app_errors` | [app_errors.zig](app_errors.zig) | App error mapping, discarded private draft and synchronized error count. |
| `endpoint` | [endpoint.zig](endpoint.zig) | Bounded in-memory user CRUD. A mutex protects shared state on explicit workers; JSON scratch uses a fixed buffer allocator. |
| `endpoint_auth` | [endpoint_auth.zig](endpoint_auth.zig) | Stateful endpoint wrapped by a typed bearer check. |
| `middleware` | [middleware.zig](middleware.zig) | Ordered ordinary Zig middleware functions and typed stack locals. |
| `middleware_with_endpoint` | [middleware_with_endpoint.zig](middleware_with_endpoint.zig) | The same composition around an endpoint, with an early-stop path. |
| `userpass_session` | [userpass_session.zig](userpass_session.zig) | Bounded local login/logout/session demonstration; source states its finite demo policy. |
| `cookies` | [cookies.zig](cookies.zig) | Raw ordered request cookies and copied Set-Cookie output; explicit duplicate policy. |
| `http_params` | [http_params.zig](http_params.zig) | Separate query/form lists, raw duplicates and explicitly compared percent/form decoding. |
| `bindataformpost` | [bindataformpost.zig](bindataformpost.zig) | One flat loop for fields, one file or repeated files; binary hex previews, no implicit saving. |

The middleware/auth/cookie utilities are example-local implementations. They
demonstrate typed composition while API-06's public middleware/locals/cookie
facilities remain queued. Demo credentials and session policy are local example
choices, not a general authentication service. Application scratch and services
have explicit bounds but remain outside the framework allocator's ledger.

The parameter example accepts 512 bytes and eight pairs per query/form;
`001` and `false` stay text. Its JSON display deliberately validates UTF-8.
The upload example accepts a 32 KiB body, eight parts, and 512 header bytes per
part; each binary preview is limited to 64 bytes. The underlying framework raw
views and explicit decoders preserve arbitrary bytes. Unsupported Content-Type
or Content-Encoding produces an ordinary error.

Three original targets are deliberately absent:

| Target | Disposition |
| --- | --- |
| `https` | TLS is out of scope by user decision. |
| `websockets` | Requires HTTP upgrade and WebSocket connection/message ownership, absent from the current engine; queued separately. |
| `mustache` | Postponed until a suitable pure Zig library is selected. Prefer explicit allocator, startup parsing and rendering into caller-bounded output. The original exercises sections, changed delimiters, escaped/raw interpolation and nested lookup; static HTML would not preserve that example. |

The source-reviewed [Mustache shortlist](../docs/MUSTACHE-CANDIDATES.md) records
two pure Zig candidates and their unresolved exact-version, license and work-bound
questions. No renderer dependency has been added.

The [framework roadmap](../docs/APP-API-ROADMAP.md) tracks repository publication
with a pinned [bounded/http](https://technologylab-ai.github.io/bounded-http/) dependency, public middleware/resumable API work and
remaining qualification. The engine remains a standalone case study.
