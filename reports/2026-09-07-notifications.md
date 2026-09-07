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

Chrome 152 passes ten [real application groups](2026-09-07-notifications/browser-jobs.json)
and 17 [website/reader groups](2026-09-07-notifications/browser-site.json), including
1440/390/320 px layouts and the browser's actual deadline-triggered reconnect
with `Last-Event-ID: 9`, followed by the remaining events in order.

Native Baz gates passed on implementation commit
`24f3ebc4d0c5fc2d0e693b7227d5bbdbda0d9219`:
[Linux/macOS](https://github.com/technologylab-ai/baz/actions/runs/34069183444) and
[Windows](https://github.com/technologylab-ai/baz/actions/runs/34069183452).
The [native receipt](2026-09-07-notifications/native.json) and
[downloaded-packet hashes](2026-09-07-notifications/native-packet-sha256.json)
preserve exact environments and results. Later changes add documentation,
preview images and the corrected optional browser harness; all Zig, application
assets and Python runtime test inputs remain identical to that commit.

| Gate | Linux x64 | macOS ARM64 | Windows x64 |
| --- | --- | --- | --- |
| Debug / ReleaseSafe | 189 root + 5 consumer tests each | 189 + 5 each | 189 + 5 each |
| CLI | 343 checks / 29 binaries | 343 / 29 | 343 / 29 |
| New job/SSE groups | 22 | 21 | 22 |
| Previous App / ports / streaming / borrowed bodies | 14 / 20 / 14 / 9 | 14 / 20 / 14 / 9 | 14 / 20 / 14 / 9 |
| Cookies / middleware / sessions / continuations / Mustache | 14 / 15 / 17 / 20 / 12 | 14 / 15 / 17 / 20 / 12 | 14 / 15 / 17 / 20 / 12 |
| Additional Windows handoff/shutdown | — | — | Three native cases with 2 / 3 / 3 owners |

Linux used kernel 6.17.0-1022-azure; hosted macOS used Darwin 25.5.0; Windows
used Server 2025 x64, image win25-vs2026 20260824.214.3. Mac has one HTTP owner;
its multi-shard case is explicitly excluded. Worker execution uses one shard on
all platforms. The new suite separately exercises two workers, and three inline
owners on Linux/Windows.

The [code/input hashes](2026-09-07-notifications/code-sha256.json) identify the
final candidate's code, application assets, harnesses and build inputs. Engine native evidence is preserved for
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
