# Direct Linux operation cells — 2026-09-05

The Linux adapter now addresses established receive/send operations and their
completions directly. The first socket binding and connection close retain
bounded scans. All 48 Linux ABBA trials passed. With 128 active clients, the
candidate's median throughput was 1.139×/1.037×/1.046× baseline at 128 configured
slots and 1.763×/1.287×/1.167× at 1,024 slots, for pipeline depths 1/16/128.
Both adjacent comparison blocks favored the candidate for every workload.
These are bounded throughput observations on one host, with explicit identity
and cancellation ownership preserved.

## Exact candidate and boundary

Candidate **2b971e14f5fd8ed9769b5cdefbea3d86c71d83fc**, baseline
**c0f87766efa310d517d262781a33ce189c4f9f0d**, exact Zig **0.16.0**.
All performance inputs use **ReleaseSafe with assertions**. The separate named
worktree/branch is `zig-http-opcells` / `perf/direct-operation-cells`; the other
agent's architecture worktree is preserved.

The previous Linux admission path scanned every operation cell to find space,
count data/cancel use and assert socket/token uniqueness. Completion lookup
scanned until its matching token. Both execute for ordinary persistent-connection
traffic. The candidate uses accept/cancel cells0/1 and connection data/cancel
cells2+2n/3+2n, with the same fixed count2*(max_connections+1) and unchanged Linux
Operation size. Each gather keeps stable startup metadata at its operation cell.

`transport.Token` makes the existing server encoding an explicit shared contract:
kind bits0–7, slot8–23, reserved zero bits24–31, nonzero generation32–63.
Listener identities are fixed; malformed kinds/generations, out-of-capacity
addresses and mismatched cancellation identities are rejected. Generation
increments remain checked. Low-level callers must use this contract; old opaque
fixture tokens11/12/999 were migrated, not silently reinterpreted.

A completed data cell retains its fd/generation binding until close. The first
binding scans other connection cells to assert fd uniqueness, including idle
bindings; subsequent submissions assert the exact retained fd/generation without
that scan. Close scans to release the binding. CQEs check exact full token,
kind, address and outstanding ownership before releasing the target. Ordinary
single-shot flags remain asserted; transient ring submission/flush handling is
unchanged. No new framework allocation or larger operation record is introduced.

Both target and paired cancellation acknowledgement must drain before reuse,
including reuse of the fixed accept identity. Socket shutdown remains immediate;
descriptor close waits for both terminal owners, preventing fd reuse while the
old binding remains. A valid stale-generation cancellation produces its own
NOENT acknowledgement and cannot retire the currently occupied target.

Mac validates the same logical token/reservation contract but retains pooled
operation scans. This is a Linux lookup optimization, not a demonstrated Mac
speedup. The parser, ordinary callback, batch16/global64 limits, response
construction and borrowed payload paths remain. There is no plaintext cache,
I/O sharding, SEND_ZC, new std.Io guarantee or Windows HTTP adapter in this patch.

## Native evidence

[Native packet](2026-09-05-operation-cells/native.json) and
[raw logs](2026-09-05-operation-cells/native-logs.tar.gz) preserve exact inputs,
commands, environments and narrower failures. Mac maxross: M3 Max arm64,
macOS26.6.2 build25G83. Linux omarx1: x86_64 Omarchy4.0.2,
kernel7.1.9-arch1-2, Intel Core Ultra7 258V, io_uring_disabled=0.

| Gate | Mac | Linux |
| --- | --- | --- |
| Debug | 14/14 steps,58/58 tests | 14/14 steps,58/58 tests |
| ReleaseSafe | 14/14 steps,58/58 tests | 14/14 steps,58/58 tests |
| Batch/gather/inline/generic wire | 22/11/10/26 passed | 22/11/10/26 passed |
| Comparator | 8/8 | 8/8 |
| ReleaseSafe smoke | 30,000 exact bodies | 30,000 exact bodies |

New transport fixtures cover malformed/bounded identities, occupied/reused data
and cancellation cells, stale cancellation preserving a current target, and
gather metadata after either first terminal event. The gather test permits the
normal-versus-canceled race; it is not a new forced-pending-cancellation witness.
The existing multi-cell slow-reader, partial-send, ordering, fairness and
shutdown fixtures remain in the wire gate. They are bounded witnesses, not
production or starvation guarantees.

Review added an explicit accept-pair reuse guard. The first compile attempt then
found a test switch label requiring explicit comptime construction; it was fixed
before the successful native gates, and its compiler log remains. Independent
review of the integrated candidate found no further issues.

## Completed paired comparison

The fresh pinned Linux preparation completed 67/67 commands at baseline
`c0f8776`. Candidate `2b971e1` was archived/built separately in the same validated
root. The timing controller verified the three binary hashes before each
capacity's workload. The harness and pipeline script came from the candidate
commit for both binaries; wrk source is pinned at
`a211dd5a7050b1f9e8a9870b95513060e72ac4a0`.

| Input | SHA-256 |
| --- | --- |
| Baseline Linux binary | `860764caee352c76ec4be68fa2588a58c89dd60a8982acf0ecc394fef65cd102` |
| Candidate Linux binary | `a2e125146cb655a882580f02ee7c04a94ab98f76de01551f66457e05e31d799e` |
| wrk | `c8000cec3cb25e87292c983828ecfcfd4108ce39d2bb01b9cd313f17dcf290af` |
| Zig compiler | `2317bbb91798556d9d0f38aabdac23db83f0979b25f767259ae474546724087c` |
| Comparison harness | `1d8157a51358d97f803cd6fa6ab4c70c37fbad80d72465873bc3442a82d921c5` |
| Pipeline Lua | `e0f744cdccc03668a7cbbcd5b09e175f8ef271e9708d9d055794ba752852c935` |

[Configuration 128](2026-09-05-operation-cells/configuration-128.json) and
[configuration 1024](2026-09-05-operation-cells/configuration-1024.json) reserve
128 or 1,024 server slots while keeping **128 active clients in both cases**.
The server uses CPU 0; four wrk threads share CPUs 3–7. The mode is inline with
zero application workers, gather sends enabled, 16 response cells per connection
and a global limit of 64 callbacks per turn. Each trial starts a fresh server,
validates exact bodies and headers at depth `max(16, trial depth)` twice, warms
up for 1 second, then measures for 5 seconds. The target is loopback
`/plaintext`, with the ordinary callback returning the 13-byte `Hello, World!`
body. The client timeout is 2 seconds; the server has a 120,000 ms duration limit.

The ordering is A/B/B/A, with baseline A and direct cells B. Seed `20260905`
shuffles whole equal-workload blocks. Two blocks per depth produce four samples
per binary: 24 trials at each capacity, 48 total, with none excluded. The
128-slot receipt spans 19:27:20.663360–19:30:21.714905 UTC; the 1,024-slot receipt
spans 19:30:21.783593–19:33:25.251813 UTC on 2026-09-05. These intervals include
preflight, warmup and shutdown, not only the measured client interval.

### Throughput

Rates are raw completed requests × 1,000,000 / raw duration in microseconds.
Each throughput cell is the median and full minimum–maximum range of four
samples, rounded to whole responses/second. The median ratio divides the two
four-sample medians. Each block ratio divides the arithmetic mean of its two B
rates by the mean of its two A rates; block IDs are zero-based receipt positions.
These two ratios per workload are shown separately because the range includes
noticeable time variation, especially at 128 configured slots.

| Configured slots | Depth | Baseline responses/s, median (range) | Direct cells responses/s, median (range) | Median ratio B/A | Both block ratios B/A |
| --- | --- | --- | --- | --- | --- |
| 128 | 1 | 289,309 (255,080–292,565) | 329,521 (309,743–330,676) | 1.139× | 1.136× [block 0], 1.173× [block 3] |
| 128 | 16 | 1,776,401 (1,575,000–1,895,773) | 1,842,778 (1,720,471–1,966,434) | 1.037× | 1.037× [block 1], 1.065× [block 5] |
| 128 | 128 | 1,828,908 (1,737,648–1,914,899) | 1,913,043 (1,761,195–1,989,817) | 1.046× | 1.042× [block 2], 1.031× [block 4] |
| 1,024 | 1 | 163,869 (161,010–165,178) | 288,881 (283,731–293,514) | 1.763× | 1.763× [block 0], 1.770× [block 3] |
| 1,024 | 16 | 1,365,770 (1,348,160–1,381,520) | 1,758,112 (1,717,493–1,883,658) | 1.287× | 1.289× [block 1], 1.317× [block 5] |
| 1,024 | 128 | 1,599,844 (1,584,163–1,616,224) | 1,867,307 (1,828,977–1,876,998) | 1.167× | 1.167× [block 2], 1.158× [block 4] |

The source change removes the Linux hot admission and completion scans; the
larger observed gain with more reserved slots is consistent with that change.
The measurements do not attribute a precise share of runtime to those scans.
Cold first-bind and close scans, the server's control scans, callback/response
construction and kernel/userspace copies remain. This comparison exercises
1,024 reserved slots with 128 clients; it does not establish throughput with
1,024 active connections.

### CPU, allocation and correctness counters

CPU cells give the four-sample median (minimum–maximum), as a percentage of one
logical CPU. Server CPU comes from the server thread's `/proc` tick delta;
client CPU comes from the measured child usage delta. These process counters
do not include all system activity on the shared host and are not equivalent
to CPU isolation or proof that the client is unconstrained.

| Configured slots | Depth | Baseline server CPU % | Direct cells server CPU % | Baseline client CPU % | Direct cells client CPU % |
| --- | --- | --- | --- | --- | --- |
| 128 | 1 | 66.5 (66.3–67.5) | 61.5 (61.3–62.4) | 125.9 (113.1–126.1) | 142.5 (136.8–145.8) |
| 128 | 16 | 83.6 (82.8–84.5) | 82.6 (81.8–82.8) | 99.1 (92.3–105.8) | 105.3 (99.2–111.0) |
| 128 | 128 | 79.7 (79.4–79.9) | 78.9 (78.5–79.0) | 74.8 (72.4–78.3) | 77.7 (72.7–80.8) |
| 1,024 | 1 | 80.6 (80.5–80.6) | 63.0 (62.5–63.1) | 72.1 (71.9–72.7) | 129.2 (127.3–129.3) |
| 1,024 | 16 | 87.6 (87.4–87.8) | 84.6 (83.8–86.3) | 72.1 (71.5–74.1) | 88.8 (80.1–92.5) |
| 1,024 | 128 | 83.8 (83.5–84.1) | 80.9 (80.8–81.2) | 57.9 (57.6–58.7) | 67.1 (66.2–67.3) |

All 48 measured clients and 48 warmups returned zero connect/read/write/status/
timeout errors. The timed clients completed **301,290,349** responses; warmups
completed **65,102,390**. The separate preflights validated **5,120** exact bodies
and required headers, including an advancing Date. Timed wrk validates framing
and status, rather than comparing every timed body byte.

All servers exited zero with one STATS record, a stable single server thread,
zero late framework allocations, zero worker dispatches, zero rejections and
timeouts, and zero live connections/operations after shutdown. Peak connections
were exactly 128 in every trial. Peak operations ranged from 113 to 129, within
the reserved 258/2,050 records at capacities 128/1,024. Maximum batch size was
16; maximum callbacks per turn ranged from 54 to 64. The largest observed send
used 32 parts and 2,512 bytes. No scalar sends, short-send completions, gather
cancel requests or canceled gather completions occurred in these throughput
trials; their correctness coverage comes from the native fixtures above.

Requested framework peak heap was identical for both binaries in every trial:
**29,618,632 bytes** at 128 slots and **236,924,360 bytes** at 1,024 slots, against
a **536,870,912-byte** limit. These counts exclude kernel allocations, allocator
bookkeeping and unrelated application allocations; they are not process RSS.
Per-trial RSS observations are retained in the receipts and derived packet.
Server STATS covers the server lifetime, including preflight and warmup, so its
completed-response counters are not the timed wrk counts.

### Environment and interpretation limits

All 96 before/after measurement profile endpoints report `performance` without
profile errors. The 768 CPU policy observations report active `intel_pstate`,
the `powersave` governor and `performance` energy preference. The recorded
driver settings are `no_turbo=0`, `min_perf_pct=8`, `max_perf_pct=100`. The
complete receipts also preserve instantaneous frequency samples, host CPU
ticks, environment snapshots and preflight dates. Endpoints do not establish
frequency residency throughout a trial, and there is **no causal power-profile
comparison** here.

The corrected wrk percentile ordering check passed all 16 depth-1 and all 16
depth-16 measured results and failed **all 16 depth-128 results**. Raw values
and flags remain preserved. No latency percentiles are promoted to per-response
tails or open-loop SLO evidence. This is a closed-loop throughput comparison
with two ABBA blocks per workload, without confidence intervals, an isolated
host, an unconstrained-client proof, production capacity, or a Mac speedup claim.

## Reproducible evidence and reservation

[Combined manifest](2026-09-05-operation-cells/packet.json) pins the separate
native and timed packets and archives for later wiki citation.
[Timed packet](2026-09-05-operation-cells/timed.json),
[128-slot receipt](2026-09-05-operation-cells/abba-128.json),
[1,024-slot receipt](2026-09-05-operation-cells/abba-1024.json) and
[raw timing archive](2026-09-05-operation-cells/timed-logs.tar.gz) preserve all
48 trials. The archive contains 144 raw server/warmup/wrk logs, eight controller
and preparation records, and the three source files for the harness, preflight
reader and pipeline script. Its 155 entries have deterministic archive metadata.
The packet hashes every archive member and its supporting artifacts.

[summarize.py](2026-09-05-operation-cells/summarize.py) independently reads the
raw RESULT and STATS lines, checks them against the copied receipts, validates
identities/order/counts/profile/counters, recomputes rates and every table's
summary values, and checks the packet's hashes. It performs no workload,
extraction or network operation. From the repository root:

```text
python3 reports/2026-09-05-operation-cells/summarize.py
python3 reports/2026-09-05-operation-cells/summarize.py --json
```

| Evidence | SHA-256 |
| --- | --- |
| Timed packet | `97a53b818b1cbc48baccd4f70e1882df43dd545e2a8962d5a04ccf4d3de8e712` |
| Raw timing archive | `6f5fc50cbdc4d5b5a9de8cd518f749410d1508971186b67789828abf1445b0bb` |
| Native packet, unchanged | `759a5179a43263deeae677b5814eb80150eda899fa1ee50fb42787b597b0aa63` |
| Native raw archive, unchanged | `2cd116fa8e790c0ab0e8704c34065c8f16916ffa6866b0b8a6ebdfce3f88a333` |

[SHA256SUMS](2026-09-05-operation-cells/SHA256SUMS) lists all report-directory
artifacts. The native packet deliberately retains `timed_trials_started:false`:
it is the **capture-before-timing snapshot**. The separate timed packet owns the
later completed result and does not rewrite that earlier evidence.

The first launch stopped at the other agent's lock before any timed trial.
The successful [controller](2026-09-05-operation-cells/controller.json)
acquired `/tmp/zig-http-measurement.lock` atomically at
19:27:20.606041 UTC under owner token `27a7a6e7082a4de4a9574ba5c8a0f5e2`,
PID 1021751, Linux start ticks 48037359. Its pre-existing workload list was
empty, both comparison commands exited zero, and it retained the reservation
through cleanup. At 19:33:25.268271 UTC it recorded no remaining owned processes
and `lock_released:true`. This cooperative reservation does not prove the host
had no unrelated activity.

The architecture agent also uses wrk/libreactor from
`/tmp/zig-http-compare.PIwh35`; **that shared root remains preserved** until
coordinated cleanup is possible. The native packet's removed ephemeral
publication root is the separate `/tmp/zig-http.f11eLI` native verification
checkout. It is not a deletion receipt for the shared comparison root.
