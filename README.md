# Baz

**Bounded Async Zap.**

[Website & documentation](https://technologylab-ai.github.io/baz/) · [API guide](docs/APP-API.md) · [21 examples](examples/README.md)

A **pure Zig** successor to [Zap](https://github.com/zigzap/zap), built in **Zig 0.16.0**
on [bounded/http](https://technologylab-ai.github.io/bounded-http/). It keeps Zap's typed
App and endpoint ergonomics, with explicit memory ownership and simpler request
data.
Both Baz and its HTTP engine are implemented in Zig. Baz replaces Zap’s
facil.io C foundation with [bounded/http](https://technologylab-ai.github.io/bounded-http/).
The engine's [GitHub Pages documentation](https://technologylab-ai.github.io/bounded-http/)
explains its architecture, embedding API, and ownership model; the
[engine source](https://github.com/technologylab-ai/bounded-http) is a separate repository.

The first implementation provides:

- **Streaming responses:** write, flush, sleep, and write again inside one handler,
  through a standard `std.Io.Writer`. See the [streaming guide](docs/STREAMING.md)
  and [runnable example](examples/streaming.zig).
- Real `App(Shared)` instances, plain endpoint structs and one router.
- Borrowed query and form text, ordered duplicates and explicit decoding into
  caller buffers. Values such as `001` and `false`, and names such as `a[]`,
  keep their spelling.
- Flat multipart parts: fields and files use one iterator, with optional filename
  metadata and borrowed bytes.
- Bounded one-shot responses, JSON and copied headers; output capacity is secured
  before the handler runs.
- Caller-supplied `std.Io` and standard memory readers/writers, on [bounded/http](https://technologylab-ai.github.io/bounded-http/)'s
  io_uring, kqueue, and IOCP transports. Blocking services use explicit fixed workers.

Baz is a separate framework package with a pinned external engine dependency.
The package and public import are `baz`; the engine import is `bounded_http`.
The engine remains independently usable as a standalone case study.
Baz has its own [GitHub repository](https://github.com/technologylab-ai/baz) and
[GitHub Pages site](https://technologylab-ai.github.io/baz/).
The [package boundary](docs/DEPENDENCY.md) and [roadmap](docs/APP-API-ROADMAP.md)
record the dependency, upstream changes, and remaining work.
See the [repository record](docs/REPOSITORY.md) for branches, history, CI, and publication status.

## Platform support

**Linux, macOS, and native Windows x64 are supported.** Baz adds native Windows
support beyond [Zap’s facil.io-based platform support](https://github.com/zigzap/zap/blob/master/README.md).
Both the framework and its [bounded/http](https://technologylab-ai.github.io/bounded-http/) engine are written in Zig.

All three platforms passed Debug and ReleaseSafe verification, the independent
package consumer, all 14 App groups, all 20 ported-example groups, and all 14
streaming groups—including the runnable example—plus nine large-borrow groups.
Windows also passed three
native shard-handoff and console-shutdown cases. See the
[large-borrow and three-platform receipt](reports/2026-09-06-large-borrow.md)
for exact environments and evidence. Windows is supported within Baz’s overall
experimental status; this is correctness coverage, not production qualification.

## Try it

Watch a response arrive incrementally:

```sh
zig build run-streaming -Doptimize=ReleaseSafe -- --port 8080
# In another terminal; use curl.exe on Windows:
curl -N http://127.0.0.1:8080/
```

The [handler](examples/streaming.zig) sends three updates with pauses between them.
Each stream uses one fixed application worker and bounded output storage.
The HTTP I/O loop continues while the worker waits. Response size and request
deadlines still apply; [the guide](docs/STREAMING.md) explains cancellation and framing.
Response helpers have explicit copying and borrowing paths; the
[copy contract](docs/OWNERSHIP.md#response-copies-and-borrowing) describes their
costs and lifetimes. `borrowBody` can serve a large immutable asset directly from
retained memory, bounded by the total response limit rather than staging capacity.
It selects the whole body; inserting a borrowed image between streaming writes
is [currently unsupported](docs/STREAMING.md#current-limit-borrowed-bodies-cannot-be-inserted-into-a-stream).

Use exact Zig 0.16.0 from [.zig-version](.zig-version), with Python 3 installed:

```sh
zig build run-app -Doptimize=ReleaseSafe -- --port 8080
```

In another terminal (use `curl.exe` on Windows):

```sh
curl 'http://127.0.0.1:8080/hello?name=Hello%20Zig'
curl --data 'value=x+y%2Bz' http://127.0.0.1:8080/form
curl -F 'files[]=@.zig-version' http://127.0.0.1:8080/upload
```

Start with the [API guide](docs/APP-API.md) and [compiled App example](src/app_demo.zig).
There are [20 ports of Zap's examples](examples/README.md), including endpoints,
authentication, middleware, sessions, JSON, query/form data and uploads:

```sh
zig build examples -Doptimize=ReleaseSafe
./zig-out/bin/hello --port 8080
zig build run-http_params -Doptimize=ReleaseSafe -- --port 8080
```

Middleware/authentication/cookie composition is currently demonstrated through
typed example helpers; the public composition API and typed resumable endpoints
are the next roadmap steps.

## Basic performance comparison with Zap

Native results from the initial App prototype at `c152e59` on 2026-09-06,
before package extraction. These compare the public App/Response API
with its predecessor [Zap](https://github.com/zigzap/zap), using the local Zig
0.16 port pinned at `f6099ecec496c7ec623c5913baa5b6b5da2e883d`.

| Host | Connections / client threads | Baz prototype requests/s | Zap requests/s | App / Zap |
| --- | --- | ---: | ---: | ---: |
| macOS, Apple M3 Max | 32 / 2 | 254,261 | 245,054 | 1.038× |
| Linux, Intel Core Ultra 7 258V | 32 / 2 | 363,594 | 205,310 | 1.771× |
| macOS, Apple M3 Max | 1 / 1 | 33,199 | 52,809 | 0.629× |
| Linux, Intel Core Ultra 7 258V | 1 / 1 | 74,386 | 72,575 | 1.025× |

These are medians of three alternating paired trials: one-second warmup,
three-second measurement, 13-byte plaintext, keep-alive without pipelining,
one server thread and 128 connection slots. **Every benchmark and warmup used
ReleaseSafe; Zig assertions stayed enabled.** All 24 measured trials completed
with zero reported wrk socket/non-2xx-or-3xx errors.

The 32-connection results show similar throughput on this Mac and higher App
throughput on this Linux host; the one-connection baseline is lower for App on
Mac. These short same-host loopback runs establish neither capacity nor latency,
and do not isolate API overhead. Clients were unpinned and wrk revisions differ
between hosts. Zap retained its original facil.io C flags, including `-Os` and
`-fno-sanitize=undefined`. Exact bodies were checked before and after timing,
not individually for every timed response. See the
[full protocol, ranges, source identities and raw receipts](reports/2026-09-06-basic-zap.md).

## Status and documentation

This is an experimental first implementation. Runtime source at `86249ad` passed
native Linux, macOS, and Windows large-borrow, streaming, and regression gates. The
[large-borrow receipt](reports/2026-09-06-large-borrow.md) identifies the exact sources
and retains the raw results. The engine passed its own native gates separately.
The [package receipt](reports/2026-09-06-baz-extraction.md) records external-dependency
verification and source identity. The [prototype receipt](reports/2026-09-06-app-api.md)
preserves the earlier combined engine/framework gates.

Current deployment is IPv4 loopback, plain HTTP/1.1. TLS is out of scope.
Mustache is postponed pending a [pure Zig library choice](docs/MUSTACHE-CANDIDATES.md).
WebSockets needs an engine upgrade lifecycle. Native Windows x64 now has its own
[CI gate](.github/workflows/windows-build.yml), alongside Linux and macOS.
An owned `std.Io` provider is deferred until after the first API MVP.

- [Implemented API and migration from Zap](docs/APP-API.md)
- [API design and predecessor analysis](docs/APP-API-DESIGN.md)
- [Multi-session roadmap and ledger](docs/APP-API-ROADMAP.md)
- [std.Io decision](docs/STD-IO-DECISION.md)
- [Engine commands, limits and low-level API](docs/ENGINE-REFERENCE.md)
- [Ownership contract](docs/OWNERSHIP.md) and [engine evidence](docs/EVIDENCE.md)
- [Session handoff](HANDOFF.md)

Framework storage is reserved at startup; borrowed input and output remain alive
until their owners finish. Application services and the caller's I/O provider
have their own resource responsibilities. Read the ownership contract before
retaining slices or introducing asynchronous work.

## License

Baz is [MIT licensed](LICENSE). The adapted Zap examples retain their
[original copyright and license notice](examples/LICENSE-ZAP).
