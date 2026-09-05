# Closing the plaintext gap: sharded owners and a contiguous output arena

Status: design proposal, 2026-09-05. Nothing below is measured unless it cites
a report. Model numbers are labeled as such. This document proposes changes to
the maintained MVP so the pinned Linux comparison against libreactor/mrhttp
moves from a 2–6× deficit to parity or better, while keeping every startup
bound, assertion and ownership rule in [OWNERSHIP.md](OWNERSHIP.md).

## 1. What the measurements say

From [the comparison](../reports/2026-09-05-comparison.md) and
[the batching report](../reports/2026-09-05-batch.md), omarx1, ReleaseSafe,
128 connections, medians:

| Setup | Zig | libreactor | Gap |
| --- | ---: | ---: | ---: |
| 3 CPUs allowed, pipeline 1 | 195k/s | 414k/s | 2.1× |
| 3 CPUs allowed, pipeline 16 | 1.22M/s | 4.63M/s | 3.8× |
| 1 CPU, pipeline 16 | 1.16–1.83M/s | 2.62–2.70M/s | 1.4–2.3× |
| 1 CPU, pipeline 128 | 1.19M/s | 7.41M/s | 6.2× |

Two structural facts explain most of it.

**Zig uses one core; libreactor uses every allowed core.** libreactor forks one
process per CPU, each with its own `SO_REUSEPORT` listener. On the three-CPU
mask its 3.8× lead is roughly three cores times a per-core deficit of 1.3×.
With one CPU each, the pipeline-16 gap shrinks to 1.4–2.3×.

**Zig's per-response cost is flat in pipeline depth; libreactor's falls.** At
depth 128 on one core Zig spends about 840 ns per response, libreactor about
135 ns. The pinned libreactor `server.c`/`stream.c` (commit `63fa717`) does,
per readable socket: `recv` up to 64 KiB, parse *every* request in the buffer
with picohttpparser, `memcpy` a precomputed header plus body into one
contiguous output buffer per request, then one `send` for the whole buffer.
One recv and one send per pipeline, regardless of depth; no iovecs.

The Zig server today, for the same 128-deep pipeline: eight `SENDMSG`
operations of 16 responses each (two iovecs per plaintext response, 32 per
batch, out of the 80-span bound), each needing its own submit/completion
turn; a full 128-slot scan per
turn with a 64-callback global budget, so only four connections progress per
turn; and per response, six `clock_gettime` calls, two `std.fmt.bufPrint`
header formats, two full scans of the 258-entry operation table in the adapter
(admission and completion matching) per operation, byte-at-a-time line
scanning in the parser, and 1.05–1.31 GB of suffix compaction per trial
session at depth 128.

A local microbenchmark on the Mac (ReleaseSafe, runtime-variable inputs,
output compared byte for byte) anchors two of these costs. It is a cost model
input, not a server measurement:

| Path | ns per response |
| --- | ---: |
| Current `std.fmt.bufPrint` header (two calls, verbatim format strings) | 88–91 |
| Cached status/Server/Date prefix + memcpy pieces + tiny decimal | 11 |
| One `clock_gettime(MONOTONIC)`; the loop takes six per request | 17 |

Roughly a quarter of the 840 ns is header formatting and clocks. The rest is
the eight-sends-per-pipeline structure, scan and table costs, and the parser.

## 2. Target architecture in one paragraph

Run `N` independent I/O owners (shards), each an instance of today's engine
with its own listener, ring/kqueue, slots, buffers, operation records, date
cache and counters, sharing nothing mutable but the stop flag. Replace the
fixed 16 × 4 KiB response cells with one contiguous per-connection output
arena so a whole pipeline of generated or small responses becomes one
contiguous span and one send. Make the request path constant-work: header
bytes are written at `begin()` from a per-second cached prefix, no `std.fmt`,
one clock sample per turn plus one per callback group, a FIFO ready ring
instead of a slot scan, O(1) token-addressed operation records, and
vectorised line scanning. Everything remains startup-reserved and bounded.

## 3. Mechanisms

### 3.1 Sharded I/O owners

`Config.shards: u8 = 1`, CLI `--shards N`, range 1–64, validated
`shards <= connections`. `connections` stays the total; each shard admits
`connections / shards` slots (remainder distributed to the first shards).
Requested heap is the per-shard sum; each additional shard adds one requested
stack of `Config.shard_stack_bytes` (default 1 MiB, same as workers).

Each shard owns exactly what `Server` owns today. The coordinator creates all
shards before `start()`, spawns `shards - 1` threads at `start()`, runs shard 0
on the calling thread in `run()`, and joins the others. `requestStop` sets each
shard's flag and calls each backend's `wake()`, the only cross-thread call the
transport contract permits. Stats are merged after every shard has returned:
sums for counters, maxima for maxima, per-shard copies retained in `STATS`.
A shard that cannot reconcile ownership by its shutdown deadline still ends the
whole process with exit 70, exactly as today.

Linux: every shard binds its own listener to the same port with
`SO_REUSEPORT`; the kernel hashes connections across listeners. Optional
`--shard-affinity 1` pins shard `i` to the `i`-th CPU of the allowed mask and
attaches the libreactor-style `SO_ATTACH_REUSEPORT_CBPF` program returning
the current CPU, so loopback connections land on the shard that will serve
them. Affinity is environment policy and stays opt-in; without it plain
reuseport hashing applies.

macOS: XNU's `SO_REUSEPORT` is not documented to distribute TCP connections
across listeners the way Linux does, and this must not be assumed without a
native witness. Phase 1 rejects `shards > 1` on macOS at `validate()`. A later phase gives
shard 0 the listener and hands accepted descriptors to shard `k` through a
bounded single-producer/single-consumer mailbox of capacity `slots_k`, waking
the target with its existing `EVFILT_USER` wake; a full mailbox closes the
descriptor and counts a refusal. Linux is the comparison platform, so this
does not block the measured goal.

Admission changes slightly: a shard with no free slot closes its accepted
descriptor even if another shard has room. `connections` remains the exact
process-wide ceiling. Worker execution with `shards > 1` is rejected in phase
1; inline execution is what the comparison measures.

### 3.2 Contiguous per-connection output arena

Replace `cells: [limit]ResponseCell{ output: [4096]u8, header: [512]u8,
chunk: [32]u8 }` with:

```
arena: []u8            // Config.output_bytes per connection, default 65536
arena_used: u32        // committed bytes of all frozen cells + active writer
cells: []Cell          // Config.response_batch_limit, default 128, range 1–511
Cell { begin: u32, end: u32, borrowed: ?[]const u8, chunk_size_at: ?u32,
       finished: bool, request_started: u64 }
```

Default storage per connection is unchanged (16 × 4 KiB = 64 KiB today).
Cell metadata is about 40 bytes; 128 cells are 5 KiB per connection.

The header is written into the arena at `begin()`, not after the callback.
Everything the header needs is known then: status, content type, content
length or chunked, `Connection: close` from the parsed request, HEAD from the
parsed request, and the cached date. `begin()` therefore reserves and commits
the header bytes itself; the body follows contiguously. The response header
loses `Connection: keep-alive`, which HTTP/1.1 implies; `Connection: close` is
still emitted when closing. libreactor sends no Connection field at all.

Chunked responses reserve a fixed 10-byte chunk-size field (`%08x\r\n`) before
each snapshot's data at `begin()`/resume and fill it at freeze; leading zeros
are valid chunk-size syntax. The `\r\n` after the data and the final `0\r\n\r\n`
are appended contiguously at freeze. No separate `chunk` buffer.

`Writer.reserve(n)` returns `arena[arena_used..][0..n]` and `WouldBlock` when
the arena is full, which flushes as today. Handlers can now generate up to the
whole arena before flushing instead of 4 KiB.

`Writer.borrow(bytes)` keeps its contract for large spans: a borrowed span
becomes its own iovec between arena runs and the request input stays immutable
until the batch's terminal completion. For spans of at most
`Config.borrow_copy_threshold_bytes` (default 256, `0` disables) with room in
the arena, `borrow` copies instead. Copying 13 bytes costs a few nanoseconds;
describing them to the kernel as an iovec costs tens plus 16 bytes of metadata
and breaks contiguity. This is an explicit, measured exception to "no copies in
the borrowed path", reported by a `borrow_copies` counter and switchable for a
same-binary A/B.

Drain conditions stay exactly as documented: cell exhaustion, no complete
buffered request, flush, close, or callback budget exhausted. One new one: the
arena has fewer than `Config.min_response_reserve_bytes` (default 1 KiB) free
before dispatching the next buffered request. Never wait to fill a batch, so
the larger default limit adds no latency at depth 16; wrk's 16-request segment
still yields a 16-response batch.

The send parts list is built once per drain by walking the cells in order and
merging adjacent arena runs. All-generated or all-small batches produce exactly
one span, so the adapter can use `SEND` instead of `SENDMSG`. Mixed batches
alternate arena runs and borrowed spans; the bound is
`2 × response_batch_limit + 1 <= 1023 < IOV_MAX`. Gather metadata is sized per
connection slot (one send in flight per slot) rather than per operation
record: 128 connections × 257 iovecs × 16 B ≈ 0.5 MiB, versus today's
258 × 80 × 16 B ≈ 0.3 MiB. Partial-send cursors, `selectSendParts` and
`advanceSendParts` are unchanged.

Ownership is unchanged in kind: the arena prefix `[0..arena_used)` and every
borrowed span are frozen from the first unsent cell until the batch's terminal
completion, including a canceled target; input bytes stay immutable while any
cell borrows them; `completeBatch` resets `arena_used` to 0 and releases all
cells at once; a flush is still a barrier over all preceding cells. What
changes is granularity: one arena instead of sixteen cells, and header bytes
written before the callback returns rather than after.

### 3.3 Constant-work request path

- **Header prefix cache.** Each shard keeps, per status it has served,
  `"HTTP/1.1 {status} {reason}\r\nServer: zig-http\r\nDate: {date}"` rebuilt
  when `refreshDate` changes the second. `begin()` memcpys prefix,
  `"\r\nContent-Type: "`, type, `"\r\nContent-Length: "` or
  `"\r\nTransfer-Encoding: chunked"`, a hand-written decimal, and the tail.
  No `std.fmt` on the request path anywhere; `reason()` stays a table.
- **Clocks.** `turn_now` is sampled at turn start, after `poll`, and after
  every 16 callbacks. Deadline checks, `queued_at`, `request_started` and
  `completed_at` use it. Staleness is bounded by 16 callbacks' work, and the
  contract already states a violating callback cannot be preempted. Exact
  per-callback `handler_ns`/`queue_ns` maxima move behind
  `Config.callback_timing = false`; when off, `max_handler_ns` reports the
  maximum per 16-callback group, and the stat says so.
- **Ready ring.** A FIFO of slot indexes with capacity `slots`. A slot is
  pushed when it becomes `.ready` and popped by the loop; each pop runs up to
  `response_batch_limit` callbacks for that slot as today. Turn cost becomes
  O(ready) instead of O(slots). FIFO order gives the fairness the rotating
  scan start provided.
- **Callback budget.** The global budget becomes
  `Config.callbacks_per_turn`, default `connections × response_batch_limit`
  divided by shards, still fixed at startup and still reported as
  `max_inline_callbacks_per_turn`. One turn is one pass over the ready ring
  snapshot; slots readied during the turn wait for the next one. The worst
  turn duration is bounded by budget × callback bound, and the budget also
  sets how many SQEs one `io_uring_enter` carries. Tests asserting
  `max_inline_callbacks_per_turn <= 64` must compare against the configured
  value reported in `STATS`.
- **Deadline sweep.** Deadlines are 5 s. Check a slot's deadline whenever the
  loop touches it, and sweep all slots only when `turn_now - last_sweep` is at
  least `Config.deadline_sweep_ms` (default 100). Maximum overshoot is one
  sweep interval plus one turn; the documentation states it.
- **Parser scanning.** `nextLine` finds `\n` with `std.mem.findScalarPos`
  (vectorised) and then rejects a bare `\r` inside the line with one more
  scalar search, keeping every existing error and the no-rescan rule.
  `isToken`, `validateTarget` and field-value checks use 256-entry lookup
  tables instead of per-byte branch chains. Semantics are unchanged; the
  existing hostile-framing suites are the witness.
- **Slot layout.** `parts[80][]const u8` (1.3 KiB) and `header_buffer[512]`
  leave `Slot`; parts live in the per-slot gather metadata and the header in
  the arena. Touching a slot then costs a few cache lines.

### 3.4 Transport adapter

The [handoff](../HANDOFF.md) already names token-addressed operation cells as
the next isolated transport experiment: index data operations by slot, cancel
operations by `slot + slots`, accept and cancel-accept at fixed indexes, keep
the generation/kind/token assertions, and make admission and CQE matching
O(1). This design depends on it but does not duplicate it. Three adapter
details matter for the arena and sharding work and are listed for whoever
owns `transport_linux.zig`:

1. `sendv` with one span should issue `SEND`; `SENDMSG` only for several.
2. Idle waiting should be one syscall: `submit_and_wait(1)` with the wake
   eventfd read through the ring instead of `submit()` + `poll(2)` +
   `copy_cqes`. Under load this rarely matters; at pipeline 1 it does.
3. Probe and use `IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN`
   (and `COOP_TASKRUN`) when the kernel supports them, falling back silently.
   One issuer per ring is exactly this design's rule.

`transport.listen` needs a `reuse_port: bool` parameter; that is the only
shared-file change sharding requires.

### 3.5 Deferred

- **Concurrent recv and send per connection.** Arm the next `RECV` into
  `input[received..]` while the batch send is in flight, submitted in the same
  `io_uring_enter`. wrk is closed-loop per connection, so the next pipeline
  arrives only after the previous one is answered; the gain is one loop turn
  of latency per pipeline, not a throughput multiplier. It needs two data
  operations per slot and a compaction rule that waits for both to be idle.
  Measure after 3.1–3.3 before deciding.
- **macOS shard distribution** (3.1) and **worker mode with shards**.
- **Provided buffers, multishot, `SEND_ZC`.** Outside the caller-buffer,
  single-shot contract; not proposed.

## 4. Contract changes, stated plainly

Unchanged: startup-only allocation and thread creation; one owner per
connection; borrowed input immutable while any response references it;
frozen output retained through terminal completion including cancellation;
flush as a barrier; drain-never-wait; finite operation and cancel reserves;
malformed HTTP as an ordinary error; assertions on in ReleaseSafe; exit 70 on
unreconciled shutdown ownership.

Changed:

| Today | Proposed | Consequence |
| --- | --- | --- |
| 16 cells × 4 KiB per connection | one 64 KiB arena, up to 128 cells | Same bytes; a handler may generate up to 64 KiB per snapshot. |
| Header formatted after the callback | header bytes committed at `begin()` | `begin()` becomes fallible on arena space; status/type/length are final at `begin()` as they already are. |
| `Connection: keep-alive` emitted | omitted | 24 fewer bytes per response; HTTP/1.1 default. |
| Every `borrow` is an iovec | spans ≤ 256 B copied into the arena (configurable, `0` disables) | Explicit counted copies; large spans still borrowed. |
| Deadline checked every turn for every slot | checked on touch plus a 100 ms sweep | Overshoot bound is documented. |
| Six clock reads per request | one per turn plus one per 16 callbacks | Per-callback timing is an explicit diagnostic option. |
| Global 64 callbacks per turn | configured, default connections × batch limit per shard | Longer bounded turns, more SQEs per syscall. |
| One I/O owner | `shards` owners, each fully independent | Per-shard admission; connections stays the process ceiling. |

## 5. Configuration and budget

| Knob | Default | Range | Notes |
| --- | --- | --- | --- |
| `--shards` | 1 | 1–64 | Linux only above 1 in phase 1; inline execution only. |
| `--shard-affinity` | 0 | 0/1 | Linux: pin shard i to allowed CPU i and attach the CPU-index CBPF. |
| `--output-bytes` | 65536 | 1 KiB–1 MiB | Arena per connection; replaces per-cell size. |
| `--response-batch-limit` | 128 | 1–511 | Parts bound `2 × limit + 1 < IOV_MAX`. |
| `--borrow-copy-threshold` | 256 | 0–4096 | 0 keeps every borrow an iovec. |
| `--callbacks-per-turn` | connections × limit / shards | 1–65536 | Reported in STATS. |
| `--callback-timing` | 0 | 0/1 | Exact per-callback maxima. |
| `--deadline-sweep-ms` | 100 | 1–1000 | Full deadline sweep interval. |

`heapBytes` gains: cells × `@sizeOf(Cell)`, per-slot gather metadata
`(2 × limit + 1) × @sizeOf(iovec)`, the ready ring, and per-shard `Server`
structs; it loses the per-operation gather array. `validate()` adds
`(shards - 1) × shard_stack_bytes` to the stack term. Default 128 connections
stay near today's 29.6 MB peak; 4096 connections at defaults remain over the
512 MiB budget because of the unchanged 148 KiB wire buffer per slot, exactly
as today.

## 6. Expected effect (model, not measurement)

Per-response cost model on omarx1, one core, ReleaseSafe. "Kernel" is the
loopback TCP send/recv path per response; "user" is everything else.

| Depth | Today user + kernel | Proposed user + kernel | Model rate | libreactor measured |
| --- | ---: | ---: | ---: | ---: |
| 16 | ~600 + ~250 ns | ~150 + ~250 ns | 2.3–2.8M/s | 2.62–2.70M/s |
| 128 | ~600 + ~200 ns | ~120 + ~60 ns | 4.5–6M/s | 7.41M/s |
| 1 | mostly kernel | mostly kernel | ~200–230k/s | 222k/s |

At depth 16 both servers are kernel-bound per core, so parity is the ceiling
without changing syscall count; io_uring's cross-connection submit batching may
edge ahead. At depth 128 the remaining gap is picohttpparser plus a memcpy
against a bounds-checked parser plus assertions; 60–80% of libreactor is the
realistic single-core target.

With three shards on the three-CPU mask the model gives 6–8M/s at depth 16
against libreactor's measured 4.63M/s. At that point the four wrk threads on
one P-core and four E-cores are the likely limit; the comparison report already
notes 155% client CPU at 4.6M/s. The result should be stated as "client-bound
above X" rather than as a server number.

Pipeline 1 gains come only from sharding: about 3× on three CPUs, kernel-bound.

## 7. Phasing, A/B flags and evidence

Each phase is one commit series, measured same-binary against its own flag,
and gated by the existing Debug and ReleaseSafe suites on Mac and Linux plus
the wire suites at depths 16/32/64/128.

1. **Constant-work path (3.3, no contract change).** Header prefix, clocks,
   ready ring, budget, sweep, parser tables. Flags: `--callback-timing`,
   `--callbacks-per-turn`. Expected: 20–30% per core. Tests: all existing;
   update the two `<= 64` assertions to the reported budget; add a deadline
   overshoot fixture with a 1 s timeout and 100 ms sweep.
2. **Arena (3.2).** Flags: `--response-batch-limit 16` and
   `--borrow-copy-threshold 0` reproduce today's shape for comparison.
   Expected: depth 128 from 8 sends to 1 per pipeline; compaction bytes to
   near zero. Tests: distinct generated bodies filling the arena mid-batch
   (`WouldBlock` then flush), a 65,535-byte borrowed HTML between two small
   inlined responses (order and partial sends across the boundary with
   `--send-chunk 19`), chunked flush/resume across arena runs, HEAD and
   204/304 with the header-at-begin path, a pending-cancel witness with 128
   frozen cells, `borrow_copies` equals the count of small borrows.
3. **Sharding (3.1) on Linux.** Flag: `--shards 1` is today's topology.
   Tests: total admission equals `connections` across shards, per-shard
   refusal, shutdown drains every shard to zero owners, SIGINT stops all
   shards, merged STATS equals the per-shard sums, `--shards 2` rejected on
   macOS and with `--execution workers`. Measure `--shards 1/3` at 128
   connections, depths 1/16/128, and the one-core control.
4. **Adapter items (3.4)** land from the transport owner and are measured
   independently, first with `--shards 1`.
5. **Deferred items (3.5)** only with a measured reason.

Report each phase the way the existing reports do: exact commit, binary hash,
CPU mask, power profile (now `performance` on omarx1; earlier numbers were
taken under the previous profile and are not directly comparable), client
threads, ranges, and the same-binary flag control. Never relabel earlier data.

## 8. Coordination with the parallel agent

Two agents are active. The [handoff](../HANDOFF.md) assigns the other agent
token-addressed operation cells, batch/capacity tuning experiments and the
harness. To avoid conflicting edits and corrupted measurements:

- **File ownership.** Transport agent: `src/transport_linux.zig`,
  `src/transport_macos.zig`, `tools/compare.py`, `benchmarks/`, `tests/test_compare.py`.
  This design: `src/server.zig` scheduling and output, `src/api.zig`,
  `src/http.zig`, `src/main.zig`, a new `src/shard.zig` or equivalent, and
  `docs/`. Shared and therefore announced before editing: `src/transport.zig`
  (only `listen(reuse_port)` and a `Gather` capacity parameter),
  `README.md`, `ROADMAP.md`, `HANDOFF.md` (append-only sections, one per agent).
- **Branches.** This work lives on `worktree-perf-architecture` in
  `.claude/worktrees/perf-architecture` and rebases onto `main` whenever the
  transport agent lands. Each mechanism is its own commit so it can be
  reverted or measured alone.
- **The Linux host is one shared instrument.** No timed run starts while
  another is running. Check `pgrep -fa 'wrk|zig-http|libreactor|compare.py'`
  on omarx1 first; if anything is listed, wait. Until the user says the host
  is free, this branch uses Mac Debug/ReleaseSafe gates only.
- **Sequencing.** Phase 1 and the transport agent's O(1) cells are
  independent and can land in either order. Phase 2 changes how `sendv` is
  called (one span → `SEND`) and how gather metadata is sized; agree the
  `Backend.sendv` signature before either side commits it. Phase 3 needs
  `listen(reuse_port)`.

## 9. Open questions for the user

1. Is copying borrowed spans of at most 256 bytes into the arena acceptable
   under the "minimal copying" requirement, given it is counted, bounded and
   switchable? Without it, plaintext stays at two iovecs per response.
2. Shards as threads in one process (proposed: shared budget accounting,
   one STATS, one exit code) or as forked processes like libreactor
   (stronger isolation, separate accounting)?
3. Should the default topology stay `--shards 1` so the existing comparison
   series remains directly comparable, with `--shards 3` measured as an
   explicit variant, or should the default follow the allowed CPU count?
4. May phase 1 change the two hard-coded `<= 64` callback assertions in
   `tests/batch_integration.py` to the configured budget, or should the
   default budget remain 64 with the larger value opt-in?
