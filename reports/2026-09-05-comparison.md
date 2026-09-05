# Linux plaintext comparison — 2026-09-05

The unchanged first MVP is substantially slower than the selected TechEmpower
plaintext leaders in this local test. With 128 connections and pipeline depth
16, median throughput was **113,342 responses/s for zig-http**, **3,204,940 for
mrhttp**, and **4,035,781 for libreactor**: about **28.3× and 35.6×** the MVP's
throughput. Without pipelining the corresponding medians were 107,752,
334,860 and 352,742: approximately 3.1× and 3.3×.

These are same-host experimental comparisons, not an official TFB result,
production capacity measurement, or the cost of safety guarantees in isolation.
The server implementation was not optimized or otherwise changed for the test.

## Inputs and scope

- zig-http implementation `6d622009abee5807eb0829e558c3173635e077ea`, unchanged
  at starting checkpoint `c41e0a3919794431b1222a93655945699386b17e`.
  Exact Zig **0.16.0**, **ReleaseSafe**, assertions enabled, default linker.
- TechEmpower **Round 23 plaintext**, result display date 2025-02-24,
  submission commit `523534bb61450e3522d775a749ad060753e26e3a`.
  mrhttp is published plaintext #1 and libreactor #3; this is not an overall
  framework ranking. Their published approximately 28M/s server/NIC results
  are not used as denominators for our local ratios.
- Full source/dependency/image/binary hashes and adaptations:
  [libreactor/wrk manifest](2026-09-05-comparison/libreactor-build-manifest.json),
  [mrhttp manifest](2026-09-05-comparison/mrhttp-manifest.json).
  libreactor uses native GCC 16.2.1 instead of the submitted GCC 10 environment.
  mrhttp uses the exact Python 3.8.12 image, hashed native wheels and Debian 11
  container userland with host networking. Wheel compiler flags were not rebuilt.
- Host: **omarx1**, Intel Core Ultra 7 258V, x86_64, Omarchy 4.0.2,
  kernel **7.1.9-arch1-2**, glibc **2.44**, GCC **16.2.1 20260810**,
  io_uring_disabled=0. Full lscpu, CPU/memory/OS and frequency policy are in JSON.
- Same IPv4 TCP loopback host; server affinity **CPUs 0–2**, client affinity
  **CPUs 3–7**. Server budget is three P cores: ours has one I/O owner and
  two application workers; each contender has three serving processes plus
  an idle parent. Load generation uses four wrk threads. Client CPUs include
  one P core and four E cores. Affinity is not exclusive CPU isolation.
- Normal desktop processes were left running. Frequency/thermal state was not
  fixed, and these short trials show variation. No builds overlapped timed runs.
  Three repetitions do not support a tight confidence interval.

## Workload and protocol checks

All use GET /plaintext, HTTP/1.1 keep-alive, 8/32/128 connections, pipeline
1 or16, with the same pinned **wrk4.2.0** commit
`a211dd5a7050b1f9e8a9870b95513060e72ac4a0`. Each of 54 shuffled trials starts a
fresh server, validates 32 exact bodies plus status/framing, text/plain,
Content-Length, Server and a fresh/advancing Date, warms up for one second,
then measures five seconds. Seed20260905; three repetitions per cell; no
outliers discarded. Startup, validation and warmup are outside wrk's timed interval.

Our response and libreactor's are exactly `Hello, World!`, 13 bytes, no newline.
mrhttp's original is `Hello, world!`: the same length with lowercase w, which
TFB accepts. We preserve and validate that difference. Generated header sizes
and policies remain each implementation's own; equal body length is not equal
wire length or identical callback/resource semantics.

Timed wrk checks HTTP parsing/status and transport errors, with no per-response
Lua body validation. Exact bodies are checked in the separate preflight; do not
claim every timed body was compared byte for byte. Its cached request Lua still
incurs a dynamic Lua callback and request-buffer work once per pipeline batch.
Throughput counts completed responses directly, never batches multiplied by16.

All **54 trials and warmups passed with zero connect/read/write/status/timeout
errors**. Preflight validated **1,728 exact responses**. Each Zig shutdown
returned zero, with no late framework allocation attempts, zero live connection
or operation owners, and connection peaks within128. Complete counters include
preflight/warmup and response tails at client cutoff, so are not wrk's timed count.
The 64KiB body/16KiB header/4KiB output/16MiB response/5s request deadline and
512MiB requested startup budget remain unchanged. Competitors were not changed
to enforce equivalent limits; no hostile-input or reliability equivalence is claimed.

## Full measured matrix

Median of three measured trials; range includes all three. Units: responses/s.

| Connections | Server | Pipeline | Median | Min–max |
| --- | --- | --- | ---: | ---: |
| 8 | zig-http | 1 | 82,376 | 79,213–82,644 |
| 8 | zig-http | 16 | 100,341 | 85,925–101,123 |
| 8 | mrhttp | 1 | 257,678 | 216,721–268,190 |
| 8 | mrhttp | 16 | 2,483,382 | 2,332,011–2,637,255 |
| 8 | libreactor | 1 | 261,749 | 247,113–263,769 |
| 8 | libreactor | 16 | 2,895,211 | 2,842,499–3,255,723 |
| 32 | zig-http | 1 | 102,648 | 90,240–106,908 |
| 32 | zig-http | 16 | 115,755 | 110,898–119,610 |
| 32 | mrhttp | 1 | 318,178 | 310,860–337,650 |
| 32 | mrhttp | 16 | 3,345,848 | 2,659,032–3,389,717 |
| 32 | libreactor | 1 | 394,733 | 322,779–693,658 |
| 32 | libreactor | 16 | 3,826,486 | 3,774,196–3,945,032 |
| 128 | zig-http | 1 | 107,752 | 100,139–108,522 |
| 128 | zig-http | 16 | 113,342 | 112,210–172,531 |
| 128 | mrhttp | 1 | 334,860 | 315,422–376,396 |
| 128 | mrhttp | 16 | 3,204,940 | 3,121,284–3,412,039 |
| 128 | libreactor | 1 | 352,742 | 335,647–371,252 |
| 128 | libreactor | 16 | 4,035,781 | 3,896,107–4,094,436 |

[Primary JSON](2026-09-05-comparison/primary.json) contains every command,
raw summary, per-thread CPU delta, whole-host CPU utilization and per-process
RSS snapshot. CPU percentages use the outer subprocess duration, whereas RPS
uses wrk's internal duration; CPU numbers are approximate. All observed server
thread sets were stable across each timed trial. RSS snapshots include shared
forked pages and must not be summed as unique physical memory or called a cap.

## Client sensitivity

A separate completed sweep used two wrk threads with the same allowed client
CPUs,128connections, both pipeline depths and three5-second repetitions:
18trials, all error-free,576 exact preflight responses. The
[second packet](2026-09-05-comparison/client-2.json) preserves every run.

| Server | Pipeline | Median responses/s | Min–max | Approx. client CPU |
| --- | --- | ---: | ---: | ---: |
| libreactor | 1 | 291,748 | 284,564–294,989 | 130% |
| libreactor | 16 | 2,902,494 | 2,887,557–4,537,344 | 155% |
| mrhttp | 1 | 278,725 | 273,389–281,196 | 133% |
| mrhttp | 16 | 2,679,850 | 2,578,783–2,681,876 | 157% |
| zig-http | 1 | 112,764 | 112,615–114,903 | 96% |
| zig-http | 16 | 128,628 | 126,460–177,323 | 76% |

Rates change with client parallelism and run conditions; neither suite
establishes unconstrained server capacity. The fastest contenders use much more
client CPU than our MVP. The large ordering gap persists in both sweeps, while
exact ratios vary. Later runs are not paired simultaneously with earlier ones;
thermal/desktop variation prevents attributing every difference to thread count.

## Latency evidence rejected

Some wrk pipeline percentiles are **zero despite positive means/maxima**. The
pinned `src/stats.c` explains this: `stats_correct()` adds synthetic histogram
counts below the original `min` without lowering it; `stats_percentile()` ranks
against the enlarged count while scanning from the unchanged minimum, then can
return its zero fallback. A single100us sample corrected with expected10us
has nine total counts but the scan from100 sees one; p99 returns0.

Raw outputs remain preserved; none of these corrected percentile summaries is
promoted to reliable request-tail evidence. Independently, wrk timestamps whole
pipeline batches and applies a correction, so even an internally consistent
value is not directly measured individual-request latency or an open-loop SLO.
Response counts and elapsed throughput are independent of that histogram.
A qualified tail-latency experiment remains queued.

## What the gap suggests

Source-visible differences give us concrete experiments; they are not a profile
proving how much of the gap each one causes:

1. libreactor handles requests inline in each worker, accumulates responses from
   a pipelined read and flushes a batch. Ours hands every request to another
   thread and back, and completes that response before processing the next
   request on the connection.
2. Our small response sends headers and borrowed body as separate operations.
   Test bounded scatter/gather or response batching while preserving ownership.
3. Our Linux adapter linearly scans bounded operation storage when reserving
   and reconciling operations; workers scan assigned slots and exchange pipe /
   eventfd wakeups. Profile these paths before selecting a scheduling/index change.
4. mrhttp's cached route evaluates its Python handler during startup, then
   serves the cached body without the ordinary Python callback per request.
   It still copies body/headers and constructs transport output. Our measured
   endpoint traverses the ordinary application-worker callback/writer path.

The lesson is not that io_uring or borrowed payloads are inherently slow.
They do not automatically provide response batching, cheap dispatch or multicore
request processing. Removing assertions or bypassing the measured application
contract would change the experiment rather than explain this baseline.

## Reproduction and remaining scope

Use [preparation instructions](../benchmarks/prepare/README.md), then run
`python3 tools/compare.py PATH/comparison-config.json --output NEW_DIRECTORY`.
The finite harness refuses occupied ports and non-ReleaseSafe Zig readiness,
stops owned groups/containers and retains partial failure packets. The original
manual build recipes/logs and measured harness revisions are preserved in the
supporting archive. The generalized preparation script has a separate verification
status; do not infer it ran just because the original builds succeeded.

An initial pilot caught a harness startup race: the port could open before READY.
A later sensitivity attempt stopped after14 successful trials because the next
trial observed a just-killed forked listener during teardown. The harness now
waits for READY and for listener closure. These narrower/failed attempts are
retained and excluded from the primary54-trial table.

This completes the initial Linux plaintext comparison slice. Preloaded-HTML
contender comparisons, native Mac contenders, longer dedicated-host/NIC runs,
verified individual-request tails, mixed hostile workloads, profiler attribution
and actual scheduling/copy optimizations remain. Windows HTTP support is still
queued; the wiki's Windows workflow validates existing wiki proofs only.
