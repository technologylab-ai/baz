# Arena output, constant-work request path and shards — 2026-09-05

Branch `worktree-perf-architecture`, final measured commit
`ad424c7` (Linux ReleaseSafe binary SHA-256
`643da6810ff6b8b2e0c557021d53abbc5de9a435a13c0b4a85a2f6227798250d`), exact
Zig 0.16.0, assertions enabled. Design rationale is in
[docs/PERF-ARCHITECTURE.md](../docs/PERF-ARCHITECTURE.md); the ownership
consequences are in [docs/OWNERSHIP.md](../docs/OWNERSHIP.md).

These are direction-finding measurements taken while the host was in desktop
use, one or two repetitions per cell, each Zig run immediately followed by a
libreactor run under the same CPU mask so the pair shares conditions. They are
not the qualified 3-repetition shuffled harness runs of the earlier reports,
and libreactor itself varied between 5.5M/s and 7.8M/s across sessions on the
same cell. Ratios within a pair are the usable signal; absolute numbers are not.

## What changed

1. One contiguous output arena per connection replaces sixteen 4 KiB cells.
   The response head is written at `begin()` from a per-second cached prefix
   with no `std.fmt`; generated bodies follow it; borrowed spans of at most
   256 bytes are copied (counted in `borrow_copies`); larger borrows stay
   separate vectors. A pipeline of small responses is one span and one SEND.
   Cells are 40-byte ranges; the default batch limit is 128 (max 511).
2. The event loop services a FIFO ready ring instead of scanning every slot,
   samples the clock once per turn plus every 16 callbacks, sweeps deadlines
   every 100 ms, pops free slots from a stack and has a configured callback
   budget (default connections × batch limit, capped at 8192).
3. The parser scans each header line with one 16-byte lane pass that checks
   CR/LF placement in the same pass, classifies token/path/host/value octets
   with tables, dispatches interpreted field names by length and compares
   fixed names as masked integers, and parses into the slot's request in place.
4. Transport operations are addressed by fixed cells (receive, send and their
   cancel cells per connection, plus accept and cancel-accept), so admission
   and completion matching are O(1); gather vectors live in per-connection
   startup storage that the adapter references without copying; a one-vector
   batch uses SEND. The Linux ring requests COOP_TASKRUN with a fallback.
5. A shard cluster runs one complete server per allowed CPU on Linux (each
   with its own SO_REUSEPORT listener, ring, slots and arenas), with full slot
   capacity per shard and a shared atomic admission ceiling so `--connections`
   stays exact. macOS keeps one shard because XNU delivers every connection to
   the last-bound listener (observed with the SHARDS counters).
6. Measured and left off by default: pre-armed receives and eager submission
   (`--prearm-receive`, `--submit-batch`); see below.

## Mac ladder (M3 Max, kqueue, one thread, 4 wrk threads, 128 connections, 4 s)

| Commit | Depth 16 | Depth 128 |
| --- | ---: | ---: |
| bda5404 baseline (main) | 1.43–1.44M/s | 1.17M/s |
| 9d0ddfc arena + cells + ready ring | 2.66–2.75M/s | 5.26–5.32M/s |
| 8ea7f96 parser lane scan | 3.02M/s | 6.67M/s |
| bf4e66d head-build trim | 3.17M/s | 7.30M/s |
| 257a73a parse in place, masked names | 3.20M/s | 7.60M/s |
| 1967b5e pre-armed receive (on) | 2.86M/s | 7.00M/s |

The pre-armed receive costs a failed `recv` plus a `kevent` registration per
pipeline on kqueue, hence the regression and the off default there.

## Linux final cells (omarx1, performance profile, interleaved pairs)

Server under `taskset`, wrk 4 threads on CPUs 3–7, 128 connections, 1 s warmup,
5 s measured. CPU is the server's utime+stime over the measured interval.

| Cell | Zig (CPU) | libreactor (CPU) | Ratio |
| --- | ---: | ---: | ---: |
| CPUs 0–2, depth 16, 3 shards | 7.17M / 7.03M (162–166%) | 7.71M / 7.58M (122%) | 0.93 |
| CPU 0, depth 16 | 3.73M / 3.52M (71%) | 4.37M / 3.29M (62%) | 0.85 / 1.07 |
| CPU 0, depth 128 | 6.90M / 6.57M (89%) | 9.99M / 10.0M (82%) | 0.69 / 0.66 |
| CPUs 0–2, depth 128, 3 shards | 11.5M / 11.1M (202–204%) | 13.2M / 13.2M (122%) | 0.87 / 0.84 |
| CPUs 0–2, depth 1, 3 shards | 588k / 549k (177%) | 558k / 568k (142%) | 1.05 / 0.97 |
| CPU 0, depth 1 (earlier sessions) | 368k, 317k | 283k, 286k | 1.30 / 1.11 |

For scale, the pinned starting points were 1.22M/s versus 4.63M/s at the
three-CPU depth-16 cell and 1.19M/s versus 7.41M/s at one-core depth 128
(older power profile), and 1.75M/s versus 4.30M/s and 1.92M/s versus 13.6M/s
at bda5404 under the performance profile.

At every multi-core cell both servers use far less than the allowed CPU, so
the wrk client is the limit there and the residual is per-pipeline latency.
At one core and depth 128 both are near saturation and libreactor completes
about 1.5× the responses per CPU second; that is the remaining per-request
efficiency gap (bounds-checked parsing and validation, arena bookkeeping,
scheduler atomics), not a structural one.

## Experiments that did not pay

- Pre-armed receives and eager submission on Linux: at depths 1, 16 and 128
  the paired ratios were unchanged (0.83–0.92 at depth 16 with or without) and
  CPU rose from ~170% to ~180–210%. A receive armed before data exists takes
  io_uring's asynchronous completion path instead of completing inline.
- Smaller callback budgets per turn (256, 64): no gain, and 64 hurt.
- Shard CPU pinning: within noise of the unpinned run.

## Correctness evidence

Mac (M3 Max, macOS 26.6.2): Debug and ReleaseSafe unit tests (62 executions
each), 26 generic, 10 inline, 11 gather and 25 batch wire cases including the
overlap variants. Linux (omarx1, kernel 7.1.9, io_uring enabled): the same
unit gates in both modes, 25 + 11 + 10 + 26 wire cases with eight auto shards
and the shared admission ceiling in force, and the 30,000-response smoke.
Fixtures that witnessed the old two-vector send shape pass
`borrow_copy_threshold=0`; the callback-budget assertions compare against the
reported budget; the output-boundary fixture uses a 1 KiB arena.

## Not done

Qualified 3-repetition shuffled harness runs of this branch against the
pinned contenders; HTML and Mac contender comparisons; SINGLE_ISSUER or
DEFER_TASKRUN ring modes (they need the ring enabled on the shard thread);
per-request efficiency work on the parser's validation loops; macOS shard
distribution through an acceptor mailbox.
