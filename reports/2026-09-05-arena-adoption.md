# Arena/shard adoption — 2026-09-05

Integration adopts `perf/arena-shards-plus-main` at
`d5b6d9b102996ed7844a73d9f6508e7eb3aa92e4`, preserving the original measured
reference branch and its report. The new base includes the arena, FIFO ready
ring, lane parser, caller-owned transport vectors and Linux shard cluster, plus
main's comparator, chunked-route and batch-limit witnesses.

Review found and fixed worker header-cache sharing, prearmed receive/interim
ordering, write-half EOF response loss, a 17-versus-16 callback clock interval,
partial startup unwind, secondary-shard stop propagation and omitted cluster
heap bytes. Tests force the completion and startup failures, with finite
watchdogs. Shared application state may be accessed concurrently across inline
shards; the ownership contract now states that explicitly.

The original report contains preliminary interleaved pairs and a sequential Mac
ladder. Low aggregate server CPU alone does not prove a client bottleneck. The
one-core depth-128 gap does not identify the parser as its sole cause. Keep
those causal explanations as hypotheses pending profiling/controlled ablation.

## Qualified Linux comparison

Measured source: **bbcec8aa9516efc470238b9edeea4f01b1f4a6d7**, exact Zig
0.16.0 ReleaseSafe with assertions. Linux binary SHA-256:
`7305b3e2edb99a30c434a9793c18dcddfdacea923d1e7a30ff4736bc177553e3`.
The later publication changes documentation, evidence packaging and archive
exclusions; server/parser/writer/transports/tests/build/harness are unchanged.

Each mask has 18 default-shuffled trials (seed 20260905): three samples per
contender/depth, 128 active connections, client depths 1/16/128, a one-second
warmup followed by five timed seconds, four wrk threads on CPUs 3–7. Server
affinity is CPU0 or CPUs0–2; auto shards resolve to one or three. Both serve
`Hello, World!` (13 bytes), with exact required-header/body preflights before
each trial. Timed wrk validates framing/status/errors, not every response body.

Defaults: inline/zero application workers, gather enabled, 128 response
descriptors, 64 KiB output arena per connection, 256-byte borrow-copy threshold,
8192 callbacks per shard per turn, prearm off, eager submit off. Shard affinity
is not individually pinned. Libreactor's pinned implementation forks one
worker per allowed CPU; these are different resource/application contracts.

| Server CPUs / depth | Zig median (min–max), responses/s | libreactor median (min–max), responses/s | Ratio of medians | Median server CPU, Zig/libreactor |
| --- | ---: | ---: | ---: | ---: |
| 1 / 1 | 364,447 (362,423–366,211) | 329,510 (329,350–330,812) | 1.106 | 58.9% / 56.2% |
| 1 / 16 | 3,404,295 (3,360,874–3,412,642) | 4,374,097 (4,280,703–4,452,351) | 0.778 | 72.0% / 62.3% |
| 1 / 128 | 8,653,315 (6,887,168–8,707,278) | 14,517,670 (14,417,633–14,602,107) | 0.596 | 89.7% / 82.2% |
| 3 / 1 | 558,216 (553,249–568,547) | 583,309 (576,265–588,287) | 0.957 | 179.7% / 143.8% |
| 3 / 16 | 5,630,758 (5,615,917–5,646,356) | 6,195,784 (6,190,575–6,198,996) | 0.909 | 196.8% / 138.9% |
| 3 / 128 | 11,937,031 (11,897,279–11,988,298) | 13,875,065 (13,767,128–14,025,376) | 0.860 | 214.0% / 123.3% |

All **36 trials and warmups passed**, with **1,053,649,993 timed responses**
and **3,840 exact preflight responses**. Final live owners, late framework
allocations, workers, refusals and timeouts were zero. Actual shards and
batch/callback maxima matched their limits. Requested framework heap peaks
were **29,635,986 bytes** with one shard and **88,907,590 bytes** with three;
the three-shard topology separately reserves two 1 MiB secondary-owner stacks.
The process-wide connection cap remains128 while each shard reserves full
slot capacity. These requested-byte metrics exclude allocator/libc/pthread
overhead, actual stack mappings, kernel rings/socket queues and application
allocations; they are not RSS limits.

This qualifies the repeated local comparison, not production capacity or
TechEmpower rank. The headline three-core depth16 ratio is0.909 in this session;
the preliminary reference reported about0.93 under different conditions.
The one-core depth128 ratio is0.596 and its Zig samples span6.89–8.71M/s.
Neither a speedup/regression versus the reference nor a parser-only cause
follows from cross-session absolute rates. Low total CPU does not isolate
client, kernel, scheduler or per-shard imbalance. wrk corrected latency
percentiles remain unsuitable for request-tail/SLO claims.

Environment: omarx1, x86_64 Omarchy4.0.2, kernel7.1.9-arch1-2, Core Ultra7
258V (eight logical CPUs), glibc2.44, io_uring_disabled0. Every recorded profile
and EPP endpoint is performance; governor powersave, driver intel_pstate.
Endpoint frequency is not average active frequency or proof of an isolated host.
The cooperative lock covered builds, warmups, measurements and child cleanup.
No builds overlapped timed work. Original retained wrk/libreactor tools remain
under `/tmp/zig-http-compare.PIwh35`; no shared-root deletion is claimed.

The packet retains exact source/archive/binary/compiler pins and the original
TFB/libreactor/wrk preparation provenance. Reproduce the read-only checks with
`python3 reports/2026-09-05-arena-adoption/summarize.py --json`; it starts no load.
See the adjacent packet for raw logs, sample order, CPU/task/heap observations
and host endpoints. Original reports and reference branches remain unchanged.

## Native ownership gates

Both gates ran from clean pushed **bbcec8a** before publication: Mac M3 Max
arm64, macOS26.6.2 build25G83 (Darwin25.6.0); Linux as above. Exact Zig0.16.0:

| Gate | Mac | Linux |
| --- | --- | --- |
| Debug and ReleaseSafe | 14/14 steps,67/69 tests per mode;2 Linux-only skips | 14/14 steps,69/69 tests per mode |
| Comparator receipts | 8/8 | 8/8 |
| Arena lifecycle/batch/gather/inline/generic wire | 8/29/11/10/26 =84 | 8/29/11/10/26 =84 |
| ReleaseSafe smoke | 30,000 exact bodies | 30,000 exact bodies;8auto shards |

New deterministic tests force cache refresh after worker publication, the
16th-callback clock refresh, body-before-interim-send, EOF-before-output-drain,
exact heap/stack budgets, second-shard spawn failure after first entry, and
secondary-owner failure with duration0. Multi-shard failure witnesses skip on
Mac because multiple Mac shards are unsupported. Client/process watchdogs are
finite witnesses, not preemption of arbitrary application code.

Artifact extraction initially failed because the Mac's Python3.9 tarfile API
lacks `filter=`. The already completed raw download was retained; extraction
and reservation cleanup were recovered without rerunning trials. The packet
keeps that orchestration failure separately from the successful native/timed
gates. Final clean main publication gates are recorded by the wiki's adoption
receipt after these source/report files are committed and pushed.

Windows HTTP has no implementation and Windows tuning/publication runs remain
deferred by user decision. Remaining work includes profiled one-core efficiency,
dynamic lease release/optional offload, broader fault and combined-limit
qualification, HTML/Mac/NIC comparisons and trustworthy request tails. M4 is
not complete.
