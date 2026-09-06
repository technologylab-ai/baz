# Baz roadmap

Baz (Bounded Async Zap) builds an application framework on
[bounded/http](https://github.com/technologylab-ai/bounded-http).
The engine's [Pages documentation](https://technologylab-ai.github.io/bounded-http/)
and [roadmap](https://github.com/technologylab-ai/bounded-http/blob/main/ROADMAP.md)
cover its independent server work.

The [detailed roadmap and session ledger](docs/APP-API-ROADMAP.md)
provide bounded tasks, acceptance gates, ownership, and resume instructions.

| Track | State | Next work |
| --- | --- | --- |
| App, routing, request/form views, multipart, responses | First implementation | Preserve bounded ownership while extending composition. |
| Zap examples | 20 supported ports | Keep native behavior coverage and record semantic differences. |
| External dependency | Baz imports `bounded_http` | Maintain an immutable engine pin and upstream generic engine changes. |
| Middleware, locals, cookies | Example helpers available | API-06: establish the public composition contract. |
| Resumable endpoints | Queued | API-07: typed continuation state and retention rules. |
| Standalone repository | Package extracted; publication pending | Finish repository publication when requested. |
| Owned `std.Io` | Deferred | Revisit after the first API MVP. |
| Mustache | Deferred | Evaluate pure Zig libraries with explicit allocation control. |
| WebSockets | Deferred | First define the engine upgrade lifecycle. |
| Windows | Waiting for engine support on main | Add minimal compilation/CI after that session lands support. |

TLS is outside this project's scope. Current runtime evidence covers native Linux
and macOS loopback HTTP/1.1. The framework remains experimental.
