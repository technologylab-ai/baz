# Bounded batch and callback experiment — 2026-09-05

This experiment makes two existing startup bounds configurable without changing
the default 16 response cells or 64 callbacks per event-loop turn. It follows the
separate direct-operation-cell change. Exact measured/native source is
**dbb639859e4c8503310933a2e53f0aaf45e2fca0**, Zig **0.16.0**, ReleaseSafe with
assertions. Debug remains a separate correctness gate. All 24 Linux matrix
trials completed successfully. At depth 128, B64/Q256 reached a median
2,779,508 responses/s against 1,950,970 for the same binary at B16/Q64, with
greater reserved heap and a broader sample range. Three shuffled samples per
configuration do not justify changing the defaults, which remain **B16/Q64**.

## Contract and resource cost

`--response-batch-limit` accepts 1–64 (default 16); worker mode still uses one cell.
`--inline-callback-budget` accepts 1–256 (default 64), counts globally across
connections, and is reported in READY/STATS. Each connection remains limited
by its batch bound. The existing rotating scan start, ordinary callback path,
framing, compaction and immediate partial-batch drain triggers remain unchanged.
No callback preemption, new worker, sharding or dynamic lease API is added.

Raising the compiled gather maximum 80→320 increases each 64-bit Slot's span
array and each Gather's iovec array by 3840 bytes, including at configured batch16.
There are connections Slots and 2*(connections+1) Gathers when gathering is enabled.
The temporary SendSelection stack array also grows 3840 bytes. Config.heapBytes
includes actual struct sizes and counts; the unit gate compares its result with
actual requested startup allocation, including exact-budget acceptance and
one-byte-short refusal. B16→64 adds connections*48*(output_bytes+sizeof(ResponseCell))
within this binary. Q alone changes no allocation. Requested heap remains
separate from kernel rings/socket memory, allocator overhead, libc/pthread,
application allocations, actual stack mappings and RSS.

Retained response cells, request input and gather metadata remain immutable
until their terminal owners drain. Target completion and cancellation
acknowledgement are separate owners. Flush drains every preceding finished cell
and the current committed snapshot before continuation; close preserves the
existing ordered barrier/discard rules. Neither Q nor deadlines can preempt a
callback that violates the bounded nonblocking application contract.

## Native evidence and vector boundary

[Native packet](2026-09-05-batch-quantum/native.json) and
[logs](2026-09-05-batch-quantum/native-logs.tar.gz) preserve exact inputs and runs.
Mac maxross: M3 Max arm64, macOS 26.6.2 build 25G83. Linux omarx1: Core Ultra 7 258V,
x86_64 Omarchy 4.0.2, kernel 7.1.9-arch1-2, io_uring_disabled=0.
Both hosts passed 14/14 build steps and 59/59 tests in Debug and ReleaseSafe,
8 comparator tests, 30 batch + 11 gather + 10 inline + 26 generic wire cases,
and 30,000 exact ReleaseSafe smoke responses.

The new generated-output and borrowed-input chunked-finish routes exercise the
ordinary Writer API. Each nonempty response has five spans; both native suites
actually submitted 320 spans from 64 distinct cells and checked every response's
bytes/framing/order. The same ownership forms passed with a 23-byte send cap,
then reused the connection across a three-flush continuation and closing suffix.
A 65,535-byte startup asset and small requested socket buffers retained 64 cells
while deadline cancellation was requested; all owners subsequently drained.
Both hosts recorded one gather cancel request in that fixture. Mac recorded
one canceled target completion; Linux recorded zero canceled target completions,
consistent with the ordinary completion racing cancellation. Linux had sent
only 5,498 bytes, less than 64 × 65,535, while retaining 64 cells at cancellation.
The evidence proves the retained-cell and drain path without requiring both
platforms to return ECANCELED for the target.
Seven backpressured depth 128 pipelines and a cold eighth connection exercised
Q256 with a finite 2s cold-service watchdog and unfinished hot output. This is a
bounded service witness, not a starvation proof or request-tail SLO.
The recorded cold response times were 0.000674625 s on Mac and approximately
0.000066181 s on Linux; both recorded a maximum of 256 callbacks per turn.

[Exact header evidence](2026-09-05-batch-quantum/vector-source-evidence.json)
records full-file hashes and excerpts: Linux's installed Zig 0.16 syscall/UAPI
constants and Apple SDK 26.5 IOV_MAX are 1024, while Zig 0.16 std.c conservatively
lists 16 for macOS (Apple's _XOPEN_IOV_MAX is 16). The 320-span runtime witness is
specific to these custom sendmsg adapters/hosts. It does not establish a
portable std.c/std.Io vector guarantee. No Windows or kernel/NIC zero-copy
runtime claim follows.

## Controlled matrix

Here **B** is the maximum response cells per connection and **Q** is the global
callback count per event-loop turn. The same immutable Linux binary ran
B16/B64 × Q64/Q256 at **128 configured slots and 128 active clients**, with
client pipeline depths 16/128. The server used CPU 0; four wrk threads shared
CPUs 3–7. The mode was inline, with zero application workers and gather sends
enabled. Every configuration used the ordinary `/plaintext` callback and the
13-byte `Hello, World!` response; no route cache was added.

[Configuration](2026-09-05-batch-quantum/configuration.json) and
[complete results](2026-09-05-batch-quantum/results.json) preserve all commands,
environments and counters. Three repeats per configuration were shuffled with
seed `20260905`, giving eight groups of three samples and 24 trials total.
Every trial started a new server, validated two exact-body/header pipelines,
warmed up for 1 second, then measured for 5 seconds. The client timeout was
2 seconds and server duration limit 120,000 ms. None of the samples was
excluded. The receipt spans **19:46:30.155833–19:49:31.158425 UTC** on 2026-09-05,
including preflight, warmup and cleanup as well as measured intervals.

The controller checked the binary hashes before starting the matrix. The exact
Zig compiler was 0.16.0, and all servers reported ReleaseSafe with assertions.
The harness, preflight reader and Lua script are archived with the logs. wrk
source remains pinned at `a211dd5a7050b1f9e8a9870b95513060e72ac4a0`.

| Input | SHA-256 |
| --- | --- |
| Shared Linux server binary, all four configurations | `be0d15486773cd986dcc31a44d85fa44feb559751f911f9ef1f4769a6b2716a0` |
| Zig compiler | `2317bbb91798556d9d0f38aabdac23db83f0979b25f767259ae474546724087c` |
| wrk | `c8000cec3cb25e87292c983828ecfcfd4108ce39d2bb01b9cd313f17dcf290af` |
| Comparison harness | `1d8157a51358d97f803cd6fa6ab4c70c37fbad80d72465873bc3442a82d921c5` |
| Pipeline Lua | `e0f744cdccc03668a7cbbcd5b09e175f8ef271e9708d9d055794ba752852c935` |

### Throughput and sample variation

Rates are raw completed requests × 1,000,000 / raw duration in microseconds.
Cells show the median and full minimum–maximum range of three samples, rounded
to whole responses/second. Ratios divide each group's median by this binary's
B16/Q64 median at the same client depth. Indices are zero-based positions in
the receipt, retained to make timing order visible.

| Client depth | B | Q | Responses/s, median (range) | Ratio to B16/Q64 | Trial indices |
| --- | --- | --- | --- | --- | --- |
| 16 | 16 | 64 | 1,700,614 (1,676,603–1,953,552) | 1.000× | 14, 19, 22 |
| 16 | 16 | 256 | 2,048,490 (2,043,918–2,060,565) | 1.205× | 4, 5, 9 |
| 16 | 64 | 64 | 1,730,203 (1,632,596–1,915,378) | 1.017× | 18, 21, 23 |
| 16 | 64 | 256 | 2,053,499 (2,029,529–2,084,071) | 1.208× | 0, 12, 16 |
| 128 | 16 | 64 | 1,950,970 (1,942,795–1,967,415) | 1.000× | 7, 8, 13 |
| 128 | 16 | 256 | 2,024,634 (2,015,306–2,028,032) | 1.038× | 3, 6, 11 |
| 128 | 64 | 64 | 2,577,426 (2,575,268–2,608,414) | 1.321× | 1, 2, 10 |
| 128 | 64 | 256 | 2,779,508 (2,513,178–2,788,822) | 1.425× | 15, 17, 20 |

At depth 16 every configuration's maximum observed batch was 16; reserving
64 cells did not create larger batches for this workload. At depth 128 the
B64 configurations actually reached batches of 64, with a maximum 128 spans
and 10,048 bytes per send. B16 reached 16 responses, 32 spans and 2,512 bytes.
Every configuration reached its exact configured Q without exceeding it.
The native five-span response fixtures above own the separate 320-span witness.

The depth-128 B64 rows show higher observed throughput than B16 at both Q
settings. The largest median is B64/Q256, but its range extends down to
2,513,178 responses/s and overlaps the B64/Q64 range. At depth 16, Q64 samples
occur late while B16/Q256 samples occur early; the ranges for Q64 also widen.
Three shuffled repeats are not a balanced time-order comparison, and these
medians alone do not distinguish configuration effects from host drift.
No confidence interval, additive B/Q effect or general throughput gain is
claimed. The defaults remain 16 response cells and 64 callbacks per turn.

### Resources and ownership

CPU values are percentages of one logical CPU, shown as median (full range).
Server values use the server thread's `/proc` tick delta; client values use
measured child CPU usage. RSS is a per-trial process observation in KiB.
These process counters differ from total host CPU usage and from the requested
framework allocation counter.

| Client depth | B/Q | Server CPU % | Client CPU % | RSS KiB, median (range) |
| --- | --- | --- | --- | --- |
| 16 | 16/64 | 83.3 (82.3–83.4) | 97.3 (97.2–110.3) | 32,928 (32,916–32,932) |
| 16 | 16/256 | 82.8 (82.6–82.8) | 105.4 (105.3–105.7) | 32,932 (32,908–32,936) |
| 16 | 64/64 | 83.3 (82.4–83.4) | 98.1 (95.7–110.0) | 60,960 (60,948–60,964) |
| 16 | 64/256 | 82.4 (82.1–82.4) | 105.5 (105.1–107.3) | 60,944 (60,940–60,964) |
| 128 | 16/64 | 79.2 (78.8–79.3) | 79.2 (78.4–79.5) | 32,932 (32,896–32,932) |
| 128 | 16/256 | 79.2 (79.0–79.5) | 76.2 (75.7–77.6) | 32,904 (32,904–32,932) |
| 128 | 64/64 | 91.0 (90.8–91.1) | 83.1 (82.6–86.0) | 60,964 (60,956–60,964) |
| 128 | 64/256 | 91.1 (90.8–91.6) | 86.4 (80.2–86.6) | 60,964 (60,956–60,968) |

Every B16 trial requested **31,100,880 bytes** of peak framework heap; every
B64 trial requested **59,805,648 bytes**, against a **536,870,912-byte** limit.
B64 therefore reserved **28,704,768 additional bytes** at 128 connections.
Changing Q alone added zero requested heap. The old direct-operation-cell
binary's B16 footprint was 29,618,632 bytes: this new binary already adds
**1,482,248 bytes at B16**, including its larger compiled span/iovec storage and
struct layout. The matrix compares settings within one binary; it is not a
same-footprint comparison with the older binary or proof that the expanded
compiled limits are free when configured at B16.

All 24 measured clients and 24 warmups reported zero connect/read/write/status/
timeout errors. Timed clients completed **254,542,464** responses, warmups
completed **52,708,384**, and separate preflights validated **3,456** exact
bodies and required headers, including an advancing Date. Timed wrk checks
framing and status rather than comparing every response body byte.

All server/client exits were zero. Each server recorded one STATS result and
a stable single thread on CPU 0, with zero late framework allocations, worker
dispatches, rejections and timeouts. Final live connections and operations
were zero; peak connections were exactly 128, with peak operations ranging
from 120 to 129 against 258 reserved records. B/Q limits in commands, READY,
STATS and observed maxima agree for every sample. These throughput trials
recorded no scalar sends, short-send completions, gather cancel requests or
canceled gather completions. Native fixtures provide that distinct coverage.
Server STATS spans preflight and warmup as well as measured traffic; its
completed count is not the timed wrk count.

### Environment and limits

All **48 before/after profile endpoints** report `performance` without errors.
All **384 CPU policy observations** report `intel_pstate`, the `powersave`
governor and `performance` EPP. Driver endpoints record active mode,
`no_turbo=0`, `min_perf_pct=8`, `max_perf_pct=100`. Instantaneous frequencies,
system CPU ticks and full host metadata remain in the receipt. They do not
establish frequency residency, and this matrix makes **no causal power-profile
claim**.

The corrected percentile ordering check passed only **6/12 depth-16** and
**3/12 depth-128** measured samples; warmups had the same counts. All raw values
and flags remain preserved, but no corrected wrk tail is promoted to a
per-response percentile, open-loop latency or SLO claim. Desktop CPU affinity
and the cooperative lock do not establish host isolation or an unconstrained
client. These 5-second loopback trials and finite native ownership/service
witnesses do not establish starvation freedom or production capacity. Mac
contender/HTML, dedicated-host/NIC and qualified tails remain open.

## Reproducible evidence and reservation

[Combined packet](2026-09-05-batch-quantum/packet.json) pins the unchanged native
packet, native logs and header evidence together with the completed
[timed packet](2026-09-05-batch-quantum/timed.json).
[Raw timing archive](2026-09-05-batch-quantum/timed-logs.tar.gz) contains all
72 server/warmup/wrk logs, six controller/configuration records and three source
files for the harness, preflight reader and pipeline script. Its 81 entries use
deterministic archive metadata, and the timed packet hashes every member.

[summarize.py](2026-09-05-batch-quantum/summarize.py) reads the raw RESULT/STATS
lines, checks copied receipts, exact shuffled identities, B/Q configuration and
maxima, ownership/error/profile counters and artifact hashes, then reproduces
every table's derived values. It performs no workload, extraction or network
operation. From the repository root:

```text
python3 reports/2026-09-05-batch-quantum/summarize.py
python3 reports/2026-09-05-batch-quantum/summarize.py --json
```

| Evidence | SHA-256 |
| --- | --- |
| Timed packet | `dac26d215074eb7064e00cb84667448a5ac48b0ce799f50883a3eeebb76cb1b3` |
| Raw timing archive | `3d41de3018c54899afbffd14368d089532be11c8def89f1dd3b3ca2d4ad3badd` |
| Native packet, unchanged | `08120add1a40b3175f8679a89b764ee7d6b8d657208526a55f54c462a97e7b21` |
| Native raw archive, unchanged | `7f8f2729405b001b498bff05776a5af4a7bb68c311212e34a68fe4bd3a56c21f` |

[SHA256SUMS](2026-09-05-batch-quantum/SHA256SUMS) lists every report-directory
artifact. The native packet and vector evidence remain unchanged; the timed
packet describes this later matrix separately.

The [controller](2026-09-05-batch-quantum/controller.json) acquired
`/tmp/zig-http-measurement.lock` at **19:46:30.109054 UTC**, with owner token
`2aaeb0454a9446d2bf2cebbf18b072e6`, PID 1033416 and Linux start ticks 48152307.
It found no pre-existing measurement workloads, ran the comparison successfully,
validated all B/Q counters, and retained the lock through child cleanup. At
**19:49:31.189208 UTC** it recorded no remaining owned processes and
`lock_released:true`. All builds preceded this timed reservation; the empty
workload check is not a claim that the desktop had no unrelated activity.

The external architecture agent remains independent. The shared
`/tmp/zig-http-compare.PIwh35` root and its wrk/libreactor tools remain preserved
until cleanup is coordinated; this report does not claim their deletion.
Windows tuning gates remain deferred by the user's current Linux/macOS focus.
