# Baz — Bounded Async Zap

Use exact Zig 0.16.0 from `.zig-version`. Baz consumes the separate bounded/http
engine through its exported `bounded_http` module. Keep engine parser, transport and scheduler changes in that dependency
and submit an upstream PR. This repository owns App, routing, request/form views,
responses, examples and their tests. The [Zig wiki](https://github.com/technologylab-ai/zigllmwiki)
provides pinned source guidance; a sibling checkout is optional. Preserve its
source/evidence hierarchy. Baz is an independent repository; never push Baz
branches to the bounded/http engine repository.

Preallocate framework threads, buffers, queues and operation state at startup.
Never allocate, spawn threads or perform blocking work on the request I/O loop.
Application workers receive borrowed input and exclusive output reservations;
retain storage until all application and kernel borrows have returned.
Use explicit bounds, checked arithmetic and assertions of ownership invariants.
Malformed HTTP is an ordinary error, never an internal assertion failure.

Compile/test every Zig file with `zig build verify`. Use Debug/ReleaseSafe;
do not disable assertions for benchmarks. Performance tests, including warmups,
must use ReleaseSafe, never Debug (user decision, 2026-09-06). Debug builds are
for correctness checks only. Run Python integration tests for
wire framing, partial progress, overload, deadlines and shutdown. Record exact
platforms; cross compilation is not runtime evidence. All code is experimental
until the named gate passes; do not claim arbitrary application isolation.

Use subagents for independent parser, transport and lifecycle work. Keep file
ownership explicit. The parent owns integration, README, docs and build setup.

Before benchmarks, heavy builds or runtime suites on maxross or omarx1, acquire
`/tmp/zig-http-measurement.lock` with atomic mkdir on the execution host. If it
exists, hold off; owner.json records who and why. Also inspect pre-existing
measurement processes that may not honor the new protocol. Retain your lock
through child cleanup and remove only your own metadata/directory. Never steal
an old lock by age alone. Read the wiki's [full cooperative protocol](https://github.com/technologylab-ai/zigllmwiki/blob/main/docs/platform-testing.md). Mac measurements by another agent take precedence
while that agent holds its reservation. Windows performance remains deferred. The current Windows dependency update
is paused while another session prepares the engine sharding PR. Read HANDOFF.md
for the completed baseline and draft branch before resuming it.
