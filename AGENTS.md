# Bounded Zig HTTP MVP

Use exact Zig 0.16.0 from `.zig-version`. This standalone M4 implementation is
informed by `../zigllmwiki`; runnable server code belongs here under `src/` and
tests, not copied into wiki pages. Preserve the wiki's source/evidence hierarchy.

Preallocate framework threads, buffers, queues and operation state at startup.
Never allocate, spawn threads or perform blocking work on the request I/O loop.
Application workers receive borrowed input and exclusive output reservations;
retain storage until all application and kernel borrows have returned.
Use explicit bounds, checked arithmetic and assertions of ownership invariants.
Malformed HTTP is an ordinary error, never an internal assertion failure.

Compile/test every Zig file with `zig build verify`. Use Debug/ReleaseSafe;
do not disable assertions for benchmarks. Run Python integration tests for
wire framing, partial progress, overload, deadlines and shutdown. Record exact
platforms; cross compilation is not runtime evidence. All code is experimental
until the named gate passes; do not claim arbitrary application isolation.

Use subagents for independent parser, transport and lifecycle work. Keep file
ownership explicit. The parent owns integration, README, docs and build setup.
