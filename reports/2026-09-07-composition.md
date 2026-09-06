# Middleware, sessions and typed continuations

Status: APP-MIDDLEWARE and APP-RESUME native gates passed on `feat/middleware-locals`.
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

## Local correctness and browser checks

On macOS 26.6.2 ARM64 / kqueue, ReleaseSafe binaries passed 15 middleware,
17 session and 20 continuation groups. The latter includes 32 waiting streams with
one worker, ordinary-route responsiveness at capacity, State/Locals address
stability, rejected pool-backed borrows (including error mappers), and terminal
cleanup. Existing gates passed 331 CLI checks across 28 binaries, 14 App groups,
20 ported-example groups, 14 worker-streaming, nine borrowed-body, 14 cookie and
12 Mustache groups. [Raw local receipts](2026-09-07-composition/local-wire.json).

The generated website passed link/source checks and 17 Chrome 152 browser groups:
desktop/mobile, tabs, source identity, all published documents, print, no-JavaScript
behavior and network/error checks. The continuation section was visually reviewed
beside the worker-streaming example. [Browser receipt](2026-09-07-composition/browser.json).

Local verification passed Debug 59/59 steps and ReleaseSafe verify/install/examples
89/89 steps, with 161 unit test executions and five independent package-consumer
tests in each mode. The final pipeline/header regression also passed the 20-group
ReleaseSafe continuation suite. Hosted native CI also passed, as recorded below. [Zig source hashes](2026-09-07-composition/zig-sources.sha256)
identify the final application source independently of documentation-only commits.

## Engine qualification

Engine candidate `6f6af03e828159455b91cece6ba468201651e1f6` passed
[native Linux/macOS CI](https://github.com/technologylab-ai/bounded-http/actions/runs/34064210181)
and [native Windows CI](https://github.com/technologylab-ai/bounded-http/actions/runs/34064209778).
Both Debug and ReleaseSafe passed: Linux 109/111 executions (two platform skips),
macOS 107/111 (four skips), Windows 122/126 (four skips). Existing core wire suites
passed on all three. The new timer suite passed nine groups on Linux/Windows;
macOS passed eight and explicitly skipped unsupported multiple-owner topology.
Windows also passed nine shard cases and 30,000 correctness responses.

## Final Baz CI

Exact implementation commit: `ee36286526c075ad58947619c826885d28d2c765`.
[Linux/macOS run 34065133713](https://github.com/technologylab-ai/baz/actions/runs/34065133713)
and [Windows run 34065133700](https://github.com/technologylab-ai/baz/actions/runs/34065133700)
passed on that direct-push commit. The PR builds also passed: Linux/macOS
34065136187 and Windows 34065136189. Both build modes passed 59/59 root steps,
161/161 test executions and 5/5 independent consumer tests on each platform.

Every platform passed 331 CLI checks across 28 binaries, 14 App groups,
20 ported-example groups, 14 worker-streaming, nine borrowed-body, 14 cookie,
12 Mustache, 15 middleware, 17 session and 20 continuation groups. Windows
additionally passed its three shard/handoff/shutdown cases. All wire fixtures
used ReleaseSafe. The shared harnesses check terminal ownership and no framework
allocations after startup; these tests make no throughput claim.

The [native receipt](2026-09-07-composition/native.json) preserves environment,
commit identity, build summaries and structured wire results. GitHub run artifacts
contain the full transcripts. Later commits finalize documentation and receipts;
the 52-file Zig source/build identity above remains unchanged. Both
[engine PR #4](https://github.com/technologylab-ai/bounded-http/pull/4) and
[Baz PR #5](https://github.com/technologylab-ai/baz/pull/5) remain unmerged;
merge the engine first.

Cross-compilation is not runtime evidence. These are bounded correctness gates,
not production isolation or performance claims. The original Zap comparison
remains tied to its historical prototype revision.
