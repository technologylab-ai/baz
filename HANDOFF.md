# HTTP experiment handoff — 2026-09-05

Current performance checkpoints:

- `b8a3afe1bcfd7dd933060e1064cab55c4f7a41c3`: unchanged MVP versus pinned
  Round23 leaders, 113k/s versus mrhttp3.20M/libreactor4.04M at128connections,
  pipeline16. All54+18 trials passed; raw wrk latency percentiles rejected.
- `a164d42badb05e3d5cb11d3ea3789f06ffcd196d`: optional inline execution,
  24-trial same-sweep gain from117k to134k/s; zero application workers.
- `ca2eccf262632eda943615b119573c23e0f6e4fc`: inline and gather become defaults.
  A12-trial same-sweep comparison measured125k scalar-inline versus344k gather.
  Mac/Linux native wire/cancellation evidence is in reports/2026-09-05-gather.md.
- Generic bounded response batching is implemented with default 16 inline
  cells, a global 64-callback turn budget, delayed compaction and flush barriers.
  Mac Debug/ReleaseSafe: 52 unit tests and 26 generic + 10 inline + 11 gather +
  15 batch cases passed per mode. Linux throughput evidence is pending.
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
compaction copies are measured and remain an optimization target.

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
