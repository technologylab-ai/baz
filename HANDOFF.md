# MVP handoff — 2026-09-05

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
fixed startup application workers with slot affinity. Callback state survives
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
