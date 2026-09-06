# Baz roadmap

Baz (Bounded Async Zap) builds an application framework on
[bounded/http](https://technologylab-ai.github.io/bounded-http/).
The engine's [Pages documentation](https://technologylab-ai.github.io/bounded-http/)
and [roadmap](https://github.com/technologylab-ai/bounded-http/blob/main/ROADMAP.md)
cover its independent server work.

The [detailed roadmap and session ledger](docs/APP-API-ROADMAP.md)
provide bounded tasks, acceptance gates, ownership, and resume instructions.

| Track | State | Next work |
| --- | --- | --- |
| App, routing, request/form views, multipart, responses | First implementation | Preserve bounded ownership while extending composition. |
| Zap examples | 21 supported ports plus worker streaming | Keep native behavior coverage and record semantic differences. |
| External dependency | Baz imports `bounded_http` | Maintain an immutable engine pin and upstream generic engine changes. |
| Cookies and redirects | Public helpers implemented | Preserve raw views, explicit lifetimes and [cookie/session gates](docs/COOKIES.md). |
| Middleware and locals | Example helpers available | API-06: establish the remaining public composition contract. |
| Resumable endpoints | Worker streaming implemented | API-07: typed inline continuation state and retention rules. |
| Standalone repository | Published GitHub repository and Pages, MIT licensed | Maintain package, documentation and native CI. |
| Owned `std.Io` | Deferred | Revisit after the first API MVP. |
| Mustache | Implemented; native Linux/macOS/Windows gates passed | Maintain the Baz-specific pure Zig fork, explicit template bounds and [compatibility/ownership coverage](reports/2026-09-06-mustache.md). |
| WebSockets | Deferred | First define the engine upgrade lifecycle. |
| Windows x64 | Supported natively, including Mustache and streaming | Preserve CI, shard handoff and shutdown coverage; performance remains deferred. |

TLS is outside this project's scope. Current runtime evidence covers native Linux,
macOS, and Windows x64 HTTP/1.1. The framework remains experimental.
