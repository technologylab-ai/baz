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

The untouched merged baseline passed 62 tests per build mode on the M3 Max,
76 wire cases, eight comparator tests and 30,000 checked smoke bodies. The
hardened native gate and qualified comparison receipts will be added before
main publication. Windows HTTP has no implementation; Windows gates remain
deferred by user decision. All timings use exact Zig 0.16.0 ReleaseSafe.
