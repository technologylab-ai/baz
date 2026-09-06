# Baz examples and Zap ports

[streaming.zig](streaming.zig) demonstrates Baz's incremental response writer.
It writes, flushes, sleeps, and writes again before the handler returns.
Run `zig build run-streaming -Doptimize=ReleaseSafe -- --port 8080`, then use
`curl -N http://127.0.0.1:8080/` in another terminal.
See the [streaming guide](../docs/STREAMING.md) for its worker and lifetime bounds.
This new example accompanies the 21 Zap ports below, for 22 examples in total.

These examples adapt the public behavior of our predecessor
[Zap](https://github.com/zigzap/zap), using the local Zig 0.16 port at
`f6099ecec496c7ec623c5913baa5b6b5da2e883d`, using the new `baz` API and
the external [bounded/http](https://technologylab-ai.github.io/bounded-http/) engine. Original source: [the pinned Zap examples](https://github.com/zigzap/zap/tree/f6099ecec496c7ec623c5913baa5b6b5da2e883d/examples).
Zap's copyright/license is preserved in [LICENSE-ZAP](LICENSE-ZAP).

The 21 Zap ports are standalone executables on Linux, macOS, and native
Windows x64. The original 20 passed the [native three-platform gate](../reports/2026-09-06-windows-baz.md). Each uses the public
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
Common flags: `-h`/`--help`, `-p`/`--port`, `--duration-ms`, `--connections`, `--execution`,
`--workers`, and `--shards`. The CRUD `endpoint` example requires workers and
one shard. IPv4 loopback/plain HTTP restrictions apply to all.
Use Ctrl-C for a clean drain (SIGINT/SIGTERM on POSIX; Ctrl-C/Ctrl-Break console
events on Windows). Windows binaries have an `.exe` suffix; use `curl.exe` for
HTTP examples in PowerShell. READY and final STATS use the same finite
test harness as the engine. A handler-triggered stop may close its own response
before delivery; only terminal shutdown establishes released storage.

## Typed CLI options with process initialization

All 22 public examples use [zli](https://github.com/renerocksai/zli) through
[shared executable support](support.zig). The main App demonstration and both
wire fixtures use the same parser with their own typed option structs. Each
entry point receives Zig 0.16's `std.process.Init`:

```zig
pub fn main(init: std.process.Init) !void {
    const options = try zli.parseInit(init, Options);
    // Use options to configure your application before App.init/start.
}
```

`Options` is an ordinary struct with typed fields, defaults, aliases, and a
`pub const help` string. See [support.Options](support.zig) for the shared
server flags and [app_demo.zig](../src/app_demo.zig) for a complete direct use.
`max_body` becomes `--max-body`; integer fields enforce their declared ranges,
and enum fields reject unknown values.

Both `--port 8080` and `--port=8080` work. Public examples also accept `-p 8080`.
Use `zig build run-hello -Doptimize=ReleaseSafe -- --help` to see the options
without starting a server. Help is handwritten in the struct, not generated.
Unknown, missing, and repeated options are errors. Explicit `--workers N` is
independent of its position relative to `--execution workers`; when omitted,
the count defaults to two in worker mode and zero in inline mode.

`parseInit` uses the supplied `init.io` for diagnostics and retains normalized
arguments in `init.arena` where needed, including on Windows. String options
borrow that storage until arena reset/deinitialization. CLI work happens at
startup, before App starts; zli adds no request-loop parsing or allocation.
The framework module itself does not import zli. The dependency uses Apache-2.0;
Baz's own code remains MIT.

The finite CLI regression suite is `python3 tests/cli_integration.py` after
`zig build install examples -Doptimize=ReleaseSafe`. It checks help and invalid
arguments before startup, both option spellings, worker defaults, and shutdown.

| Original target | Port | Preserved purpose and deliberate adaptation |
| --- | --- | --- |
| `mustache` | [mustache.zig](mustache.zig) | Real HTML with typed lists, dotted/parent lookup, escaped text, and explicit partials. Startup parsing and bounded rendering; exact original outputs also have library compatibility tests. |
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

## Mustache pages

[mustache.zig](mustache.zig) serves a greeting form and typed user cards, with
[page markup](assets/mustache.html) and a [user partial](assets/mustache-user.html)
in separate files. Parse once at startup, then call `ctx.response.mustache`.
The renderer writes directly into the reserved response draft, with no allocated
rendered string. See the [guide](../docs/MUSTACHE.md) for limits, escaping, and copying.

```sh
zig build run-mustache -Doptimize=ReleaseSafe -- --port 8080
python3 tests/mustache_integration.py
```

Two original targets are deliberately absent:

| Target | Disposition |
| --- | --- |
| `https` | TLS is out of scope by user decision. |
| `websockets` | Requires HTTP upgrade and WebSocket connection/message ownership, absent from the current engine; queued separately. |

The [Mustache selection record](../docs/MUSTACHE-CANDIDATES.md) records provenance,
pure Zig alternatives, and the independent original-Zap and official-core tests.

The [framework roadmap](../docs/APP-API-ROADMAP.md) tracks repository publication
with a pinned [bounded/http](https://technologylab-ai.github.io/bounded-http/) dependency, public middleware/resumable API work and
remaining qualification. The engine remains a standalone case study.
