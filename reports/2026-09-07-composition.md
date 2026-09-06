# Middleware, sessions and typed continuations

Status: implementation and native verification in progress on `feat/middleware-locals`.
Exact Zig: 0.16.0. Correctness builds use Debug and ReleaseSafe; no performance
measurements are part of this work.

## Changes

Public global/route middleware, default-initialized request locals and reverse
cleanup replace example-specific wrappers. The session example reserves 32 reusable
slots, enforces fixed server expiry and supports one-session/all-device revocation.
Typed continuations reserve state and detached response storage at startup, return
between flushes and timers, and preserve authentication without replay. Pool-backed
body borrows are rejected before publication, including from error mappers.

The engine seam is [PR #4](https://github.com/technologylab-ai/bounded-http/pull/4).
It provides timed waits and cancellation notification after outstanding kernel
borrows return. Timer arming uses a fresh monotonic timestamp. Terminal callback
results disarm cancellation before publishing their worker result.

## Verification pending

Required: `zig build verify` in Debug and ReleaseSafe, independent consumer, all
existing wire/CLI suites, middleware/session/continuation lifecycle suites, native
Linux/macOS/Windows CI, and generated-site link/browser checks. Exact final
revisions, results and evidence links will replace this paragraph after completion.

Cross-compilation is not runtime evidence. These are bounded correctness gates,
not production isolation or performance claims. The original Zap comparison
remains tied to its historical prototype revision.
