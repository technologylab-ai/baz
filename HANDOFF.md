# HTTP experiment handoff — 2026-09-05

Active continuation: `perf/batch-quantum` in
`/Users/rs/code/github.com/technologylab.ai/zig-http-batchq`, based on tested
operation-cell candidate2b971e14f5fd8ed9769b5cdefbea3d86c71d83fc.
Parent Codex /root owns this worktree; batch_quantum agent implements only
startup response-batch16/64 and global-callback64/256 tuning plus meaningful
ownership/fairness fixtures. No performance gain or runtime validation of that
new tuning is established yet. The prior direct-cell ABBA comparison runs from
immutable binaries in /tmp/zig-http-compare.PIwh35 under the Linux host lock;
no builds may overlap it. The external architecture agent's worktree is separate.
Use `git worktree list` and each branch's HANDOFF.md to resume; do not duplicate,
discard or implicitly merge another worktree. Source edits only until parent
coordinates native gates. Existing lower sections describe the prior checkpoint.


Active experiment (2026-09-05): parent Codex /root owns branch
`perf/direct-operation-cells` in
`/Users/rs/code/github.com/technologylab.ai/zig-http-opcells`, based on pushed
c0f87766efa310d517d262781a33ce189c4f9f0d. This named Git worktree is discoverable
with `git worktree list`; it is separate from the other agent's
`.claude/worktrees/perf-architecture` tree. Do not delete or merge the other
agent's work. Current scope: replace Linux hot operation-table admission/CQE
searches with explicit addressed cells, preserve socket/token/generation and
separate target/cancel ownership, then perform a controlled ReleaseSafe A/B at
configured capacities128/1024 with128 active clients. No improvement is measured
yet. Mac baseline at the unchanged starting commit passed14/14 steps and52/52
ReleaseSafe tests with exact Zig0.16.0 under the host lock; the lock is released.
The prior full native publication gates remain in the wiki's durable receipt.
Current stage: direct-addressing implementation and ABBA harness are complete.
The source implementation agent finished; Linux preparation finished67/67
commands at /tmp/zig-http-compare.PIwh35 and released its reservation. Parent
owns Linux native validation and timing next. Mac development gates passed58/58
test executions in both Debug/ReleaseSafe,69 wire cases,8 comparator tests and
30,000 ReleaseSafe smoke bodies. An initial fixture switch-label comptime error
was fixed before that successful native run; failed logs are retained.
No Linux runtime or throughput gain is established for the new code yet.
All heavy work must acquire `/tmp/zig-http-measurement.lock` on its execution
host. This progress record exists so interruptions do not orphan work.


Latest measurement: [recorded performance-profile depth sweep](reports/2026-09-05-power-profile.md)
at exact bda54040bb0b809c82824b87a782e96826f05dff, Zig 0.16.0 ReleaseSafe.
All 24 trials/warmups passed: 643,222,112 timed responses, 2,880 exact preflights.
One-core Zig medians at depths 16/32/64/128 were 1.746/1.742/1.919/1.923M/s;
libreactor 4.298/7.263/10.938/13.627M/s. Server batch/callback limits remain 16/64;
zero final owners/late allocations/timeouts/refusals. Both are faster than the
preceding unqualified profile sweep, but no controlled profile A/B is established.
All power-profile and EPP endpoints read performance; governor remained powersave.
Current-frequency observations are untimed endpoints, not average active clocks.

The preparation agent and Linux timed sweep finished. No timed runner remains
active. Mac/Windows timings were not run. Windows gates are deferred while tuning
this Linux/macOS-only HTTP implementation, per the user's explicit decision.
Another agent takes Mac measurements: use the host-local atomic directory
`/tmp/zig-http-measurement.lock` on both hosts before load/build/runtime suites.
If it exists or an earlier benchmark process is active, hold off. Record
owner.json metadata, keep your lock through child cleanup, then remove only your
own reservation. The sweep's initial trials predated this new protocol; the
Linux lock was acquired during the sweep and released after zero owned processes.
Full protocol: sibling wiki docs/platform-testing.md. Do not assume the hosts
remain free after an earlier check.

Current performance checkpoints:

- `b8a3afe1bcfd7dd933060e1064cab55c4f7a41c3`: unchanged MVP versus pinned
  Round23 leaders, 113k/s versus mrhttp3.20M/libreactor4.04M at128connections,
  pipeline16. All54+18 trials passed; raw wrk latency percentiles rejected.
- `a164d42badb05e3d5cb11d3ea3789f06ffcd196d`: optional inline execution,
  24-trial same-sweep gain from117k to134k/s; zero application workers.
- `ca2eccf262632eda943615b119573c23e0f6e4fc`: inline and gather become defaults.
  A12-trial same-sweep comparison measured125k scalar-inline versus344k gather.
  Mac/Linux native wire/cancellation evidence is in reports/2026-09-05-gather.md.
- `b7ac35558dea3e418e7dab5e41b1d3bb9054ca73`: generic response batching,
  default16 cells, global64-callback budget, deferred compaction and flush
  barriers. Same-binary pipeline16: batch1 234k/s, batch16 1.22M/s. Separate
  one-core experiment: Zig1.83M/s versus libreactor2.62M/s. All24+12 trials passed.
- `5620905193e496af1c4b297a576c4fe7edd6c4a9`: separate multi-cell pending-cancel
  witness; both Mac and Linux retained16 cells and drained every owner. Both
  hosts pass52 tests in Debug/ReleaseSafe,26+10+11+16 wire cases,30k smoke bodies.
- `3f1963f21a8d5c84b08efed94c90e1cbb9434330`: deeper client pipeline support
  in the harness and distinct-body wire tests at32/64/128. All22 batch cases
  pass on Mac/Linux; runtime server source is unchanged from5620905.
  The24-trial one-core depth16/32/64/128 sweep passed, but Zig plateaued near
  1.06–1.19M/s while libreactor reached7.41M/s at128. The depth16 control also
  regressed versus the preceding sweep; retain its follow-up old/current binary
  control before attributing that change to code. That control also varied:
  unchanged current binary1.02–1.81M/s, original0.96–1.16M/s. It cannot isolate
  a code regression; all6 trials passed and the variation remains explicit.
  Preserve all earlier checkpoints; do not relabel their data as the new code.

Inline application callbacks must be bounded and nonblocking. Worker mode is
explicit; per-request optional offload and multiple I/O owners remain future
work. Gather metadata and all borrowed payloads survive target completion,
independently of cancellation acknowledgements. See current code/docs and the
next batching packet before changing ownership. Read ROADMAP.md for scope.

This is the first working Zig 0.16.0 HTTP/1.1 experiment. Start with README.md,
AGENTS.md, docs/OWNERSHIP.md, docs/EVIDENCE.md and ROADMAP.md. The current code is
the maintained runnable example; the adjacent zigllmwiki stores reusable
source-pinned guidance. Do not restart the project or copy its Zig into wiki text.

Use ReleaseSafe for every timing experiment. Debug is a separate correctness
gate. On omarx1 the default Debug ELF linker rejects R_X86_64_PC64 in GCC 16's
crt1.o .sframe. The user suggested ReleaseSafe, and its default selection passed
without linker overrides. build.zig selects LLVM/LLD only for Linux Debug to
retain both correctness gates. Do not upgrade Zig to work around this.

Core model: one I/O owner, raw io_uring on Linux/nonblocking kqueue on macOS,
inline callbacks by default, optional fixed startup workers with slot affinity. Callback state survives
`return writer.flush()`, which sends all committed bytes before `.flushed`.
`finish()` ends framing. Borrow only request-owned input or immutable
server-lifetime assets; dynamic completion/release notifications are pending.
Timeouts close networking but retain storage until running handlers return.
Unreconciled ownership at the shutdown deadline requires whole-process exit70.

The integration suite exercises malformed framing, exact/over limits,
pipelining, forced partial sends, worker isolation/recovery and shutdown. The
slow-reader witness must show bytes_sent below its 2MiB payload; Linux otherwise
can finish the echo into kernel buffers and merely time out the next idle read.
SO_SNDBUF4096 is an OS request used to force that witness, not a portable exact
kernel allocation size.

Budget tracks/refuses framework allocator growth and counts late attempts.
It excludes libc/pthread metadata, actual stack mappings, kernel socket/ring
storage, allocator overhead and application allocations; do not call it an RSS
cap. No extra workers or request queues appear under load. Pipeline suffix
compaction happens only after batch completion, remains measured, and is still
an optimization target for deeper client pipelines.

Mac maxross is preferred for expensive portable work; Linux runtime uses
`tools/verify_linux_ssh.sh omarx1`, which streams into a validated temporary
directory and preserves remote authoring checkouts. From Linux use ssh maxross
when available; continue on omarx1 during travel outages. Windows is queued.
Final validation details belong in reports/; preserve earlier failed/narrower
results rather than silently relabeling them. All contributors finish before
publication; no queued roadmap item implies a running agent.

The first pinned implementation and native gate packet is in
[reports/2026-09-05-mvp.md](reports/2026-09-05-mvp.md): 44 test executions in
each mode and 26 integration cases per host. Full finite smoke runs validated
30,000 responses per host in ReleaseSafe. See ROADMAP.md for remaining work.

The next isolated architecture experiment is token-addressed Linux operation
cells: preserve exact slot/generation/kind checks and cancellation reserve while
removing admission/CQE searches. The single-owner thread, whole-slot scheduler
scan, six per-request clock reads and generic header formatting remain current
costs, not profiled bottlenecks. Tune server batch limits separately from client
pipeline depth. I/O sharding, optional offload and dynamic release remain queued.

Latest evidence is [the batching report](reports/2026-09-05-batch.md), including
24 batch-limit,12 one-core,24 deeper-pipeline and6 old/current trials. All72
baseline/client trials and the separate inline/gather checkpoints remain intact.
All agents and timed runners finished. Use the final clean pushed documentation
revision for local and Linux publication gates. Windows HTTP remains unimplemented;
the sibling wiki's hosted Windows checks cover its lifecycle proofs only.
