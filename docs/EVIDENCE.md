# Baz evidence inputs

Baz owns the application API and its verification. The
[dependency record](DEPENDENCY.md) identifies the selected external engine.
[bounded/http](https://technologylab-ai.github.io/bounded-http/) maintains the server
contracts and core evidence; its [Pages site](https://technologylab-ai.github.io/bounded-http/)
provides the architecture reader.

The original [App correctness receipt](../reports/2026-09-06-app-api.md) and
[Zap comparison](../reports/2026-09-06-basic-zap.md) describe the prototype before extraction.
Their source manifests and raw measurements remain historical records.
The [package receipt](../reports/2026-09-06-baz-extraction.md) records external-dependency verification.
The engine inputs below explain that lineage; they do not replace Baz-specific evidence.


Authoritative API source: installed exact Zig 0.16.0 standard library, especially
`std/os/linux/IoUring.zig`, `std/Thread.zig`, `std/atomic.zig`, `std/c.zig`.
Protocol: immutable RFC 9110, RFC 9112 and RFC 6585, as pinned and scoped by
the wiki's [framing record](https://github.com/technologylab-ai/zigllmwiki/blob/362da3b8023e6918d4b72c046821334ebd3722ca/sources/http11-framing-and-limits.md)
and [overload record](https://github.com/technologylab-ai/zigllmwiki/blob/362da3b8023e6918d4b72c046821334ebd3722ca/sources/http-overload-refusal.md).
URI grammar: [RFC 3986](https://www.rfc-editor.org/rfc/rfc3986.html), published
January 2005; notably scheme case-insensitivity is separate from path semantics.

OS and design inputs already pinned in the wiki before implementation:

- [liburing manuals](https://github.com/axboe/liburing/tree/4cf73437863c2e492d2a1d0f24330f391c0f075b/man)
  for single-shot submission, terminal completions and separate cancellation.
- [Apple kqueue manual](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/man/man2/kqueue.2)
  for readiness, one-shot registrations and filters.
- [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/47aeb2212a255273dda508288412e537d11e4b7c/docs/TIGER_STYLE.md)
  for explicit limits, startup allocation, checked arithmetic and ownership assertions.
- [TechEmpower plaintext driver](https://github.com/TechEmpower/FrameworkBenchmarks/blob/57d92fbec6f8fd7431bc77326dd0484e60c96e20/toolset/test_types/plaintext/plaintext.py)
  for the plaintext validator and pipeline depth 16. The demo uses exactly
  `Hello, World!` (13 bytes), dynamic Date refreshed each second, and Server.
- [Zig 0.16 release notes](https://ziglang.org/download/0.16.0/release-notes.html#x86-Backend)
  explain the default x86 Debug backend. The new ELF linker/default backend
  distinction matters for Linux CRT compatibility; see the verification report.

The underlying engine began as an experimental bounded HTTP/1.1 implementation. Source
inputs do not establish runtime or performance. Test reports name exact
commits, compiler, OS/kernel, commands, limits and unexercised paths.

Safety assertions stay enabled for both Debug correctness tests and ReleaseSafe
measurements. Function size/style cleanup, deterministic schedule/fault injection,
fairness under sustained high connection counts, external dynamic buffer release,
and full kernel/process resource accounting remain work; this is an applied
TigerStyle experiment, not a claim of complete TigerStyle conformance.

The first source-hashed native result is
[the MVP receipt](https://github.com/technologylab-ai/bounded-http/blob/4b3cd5551d80b422ec6ef763627d019e6f1dfb83/reports/2026-09-05-mvp.md).

## Native Windows, Linux, and macOS integration

[The Windows integration receipt](../reports/2026-09-06-windows-baz.md) records
Baz’s own native x64 Windows IOCP gate, including Debug/ReleaseSafe compilation
and unit tests, all App/example groups, and three finite handoff/shutdown cases.
Linux and macOS passed fresh regressions on the same runtime/test source.
Native Windows is supported; cross-compilation alone is not this evidence.
