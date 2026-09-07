# Notifications, SSE and the complete job application

This change adds generation-safe producer wake-ups, a fixed FIFO mailbox, SSE
encoding and an authenticated Mustache/live-job application. Standard caller
`std.Io` remains unchanged; its owned-provider prototype is explicitly deferred.
No benchmark or throughput claim is added.

## Source and platform identity

The engine is independently pinned at
`886b728bec79c36ca1ec69345b609a725617a9ea` through
[engine PR #5](https://github.com/technologylab-ai/bounded-http/pull/5).
Engine native [Linux/macOS run](https://github.com/technologylab-ai/bounded-http/actions/runs/34068510490)
and [Windows run](https://github.com/technologylab-ai/bounded-http/actions/runs/34068532335)
passed at that revision. Engine tests and the Baz consumer gates establish
separate claims.

Local development host: macOS 26.6.2 (25G83), Darwin 25.6.0 arm64, exact
Zig 0.16.0, Python 3.9.6. Heavy builds and all runtime/browser gates acquire
`/tmp/zig-http-measurement.lock`; an outer watchdog retains the reservation
through child-process cleanup. Tests execute ReleaseSafe server binaries.
Debug is used only for correctness verification.

## Baz qualification

Local Debug verification passes 68/68 steps; ReleaseSafe verification and
installation pass 99/99 steps. Both execute 189 root tests and five independent
package-consumer tests. All 24 examples and five fixtures compile. All existing
wire suites pass, as do 21 new macOS [job/SSE groups](2026-09-07-notifications/local-jobs.json)
and 343 CLI checks across 29 executables. Real kernel backpressure remains
covered by the existing 14-group streaming suite.

Hosted Baz native and browser gates are pending at this checkpoint. The
[code/input hashes](2026-09-07-notifications/code-sha256.json) identify the source
being qualified. Engine native evidence is preserved for
[Linux/macOS](2026-09-07-notifications/engine-posix.json) and
[Windows](2026-09-07-notifications/engine-windows.json).

The new gates cover:

- SSE UTF-8 validation, line framing, metadata injection, empty/trailing data,
  IDs/retry/comments and bounded writer failure.
- Mailbox capacity, FIFO wraparound, contention, close and drain semantics.
- Fixed job storage, per-owner access, expiry, generation retirement and finite replay.
- Real producer notifications with inline callbacks, workers and supported shards;
  reconnect cursors, replay gaps, heartbeat timeouts, job/subscriber exhaustion,
  session expiry/revocation, disconnect and terminal cleanup.
- The complete browser application and the existing documentation/site reader.

The prior App, ports, CLI, Mustache, cookies, middleware, sessions, worker-stream,
whole-body borrow and continuation suites remain required regression gates.

## Limits of this evidence

A notification coalesces wake-ups; it does not synchronize arbitrary payload
bytes or acknowledge application processing. Handles remain callable only until
App/engine teardown; application producers must stop and join first. Polling
uses the existing owner cadence rather than an immediate OS wake-up.

The job demo retains eight jobs and eight events per job, with 32 subscribers
and sessions. Each response keeps the original 10-second deadline and a 64 KiB
cumulative limit. Its producer has one explicit startup thread and a 512 KiB
stack outside the framework allocator's ledger. Reconnect and auth policies are
example-local; neither durable delivery nor a general identity service is claimed.

Eleven small progress events may fit in the kernel send buffer. Delayed-reader
checks in this example do not establish transport saturation; existing streaming
backpressure gates remain separate. Cross-compilation is never native evidence.
Windows performance remains deferred; all framework claims remain experimental.
