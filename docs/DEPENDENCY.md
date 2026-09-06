# Baz and [bounded/http](https://technologylab-ai.github.io/bounded-http/)

Baz means **Bounded Async Zap**.
It provides application composition over the separate [bounded/http](https://technologylab-ai.github.io/bounded-http/) server.

- [engine repository](https://github.com/technologylab-ai/bounded-http)
- [bounded/http GitHub Pages documentation](https://technologylab-ai.github.io/bounded-http/)
- [Engine embedding guide](https://github.com/technologylab-ai/bounded-http/blob/main/docs/USING.md)
- [Engine architecture](https://github.com/technologylab-ai/bounded-http/blob/main/docs/ARCHITECTURE.md)

## Package boundary

The package and public framework module are `baz`.
The dependency key and imported engine module are `bounded_http`.
[build.zig.zon](../build.zig.zon) identifies the exact dependency revision and package hash.
[build.zig](../build.zig) passes Baz's selected target and optimization mode to that dependency.

Baz imports the module returned by `dependency.module("bounded_http")`.
Every Baz module and test uses that same engine module object.
`baz.engine` reexports the module; the build also exports it for direct consumers.
The [independent consumer](../examples/embedding/build.zig) tests both imports together.

The dependency owns HTTP framing, connection storage, scheduling, transports, and kernel completion handling.
Baz owns App, routing, request/form conveniences, response drafts, examples, and their tests.
Baz's source tree contains no copied engine implementation or engine demonstration executable.
Historical benchmark archives retain their original source snapshots.
Core engine suites run upstream; Baz retains its application wire and example suites.

## Public adapter contract

Baz requires configurable output reservation before callback dispatch.
The engine drains earlier output when the complete draft cannot fit.
This preserves each request and prevents replay of application side effects.

Response uses checked `Writer.draftStorage`, `discardDraft`, and `writeDraftBody` methods.
It does not inspect writer fields or call internal lifecycle methods.
`beginWithHeaders` validates and copies Content-Type and additional header lines synchronously.
Generated-body compaction contributes to `Stats.response_draft_copy_bytes`.

App delegates signal stopping to `Cluster.requestStopFromSignal`.
That helper only stores atomic stop flags and performs no wake or other system call.
The callback-progress and external-watchdog limits still apply.

These generic extensions landed through [engine PR #1](https://github.com/technologylab-ai/bounded-http/pull/1).
PR #1 merged on 2026-09-06 as `c90281b600deb699a667e2bcc115da32862c794f`.
The current engine pin is `7c24003924bcc76b2a3808cc2fae194082a40105`, with Zig package hash
`bounded_http-0.1.0-N3A1uJjOEAD4Yg0JPgeoRomLUpBJeFlfujb4gpSUDcgc`.
It includes the package rename and [Windows shard handoff from PR #2](https://github.com/technologylab-ai/bounded-http/pull/2).
Baz passed its own native Windows x64, Linux, and macOS gates on this pin,
including all supported examples. The [native receipt](../reports/2026-09-06-windows-baz.md)
records exact source identity, environments, and Windows handoff/shutdown behavior.
The older tested `e52f09f` pin and provisional `bb14d987` draft remain in history.
The [repository record](REPOSITORY.md) describes branches and publication.

## Future updates

Update the engine URL, commit, and package hash together in `build.zig.zon`.
Keep the `bounded_http` source import stable when the engine repository name changes.
Read the selected engine revision's contracts before changing the pin.
Verify Baz on native Linux, macOS, and Windows x64, including the independent
consumer, App/example wire suites, and Windows handoff/shutdown checks.
Run engine gates upstream when the engine changes.

The original App/Zap throughput receipt measured `c152e59` before package extraction.
It does not measure the extracted package or these additional adapter methods.
No throughput comparison is rerun solely for package naming or documentation.
