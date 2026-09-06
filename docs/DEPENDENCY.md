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
The current engine pin is `2a269ef57301b21df22f1c616d02d6d244e5d6ca`, with Zig package hash
`bounded_http-0.1.0-N3A1uD4IEQBXzMxjafNtPTuGXAGeklCjLXIInMVXvL9e`.
It adds same-callback worker flushes through [engine PR #3](https://github.com/technologylab-ai/bounded-http/pull/3).
`Context.flushAndWait()` keeps the worker stack live while the I/O owner sends a snapshot.
Baz supplies the standard writer and cancellation-aware sleep described in [STREAMING.md](STREAMING.md).
It includes the package rename and [Windows shard handoff from PR #2](https://github.com/technologylab-ai/bounded-http/pull/2).
The current pin passed Baz’s native Linux, macOS, and Windows x64 verification,
App/example suites, all 14 streaming groups, and Windows shard/shutdown checks.
The [streaming receipt](../reports/2026-09-06-streaming.md) preserves those results
and the separate engine gates. PR #3 merged as `86e8ec2` on 2026-09-06.
The pin retains its exact tested head, which is an ancestor of that merge and
has the same complete Git tree.
The preceding `7c240039` pin passed Baz’s native Windows x64, Linux, and macOS gates,
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

## Executable CLI dependency

The [zli fork](https://github.com/renerocksai/zli), pinned to
`4f17b1f1eacda7b87c49461e34b1520c392788b2` from its [Init adapter PR](https://github.com/renerocksai/zli/pull/1), supplies typed command-line
parsing for all public examples and the App/streaming/borrow fixture executables.
Its `parseInit(init, Options)` entry point consumes Zig 0.16 `std.process.Init`,
using the supplied I/O and process arena. The [example guide](../examples/README.md#typed-cli-options-with-process-initialization)
records syntax, ownership, and startup behavior.

The dependency is pure Zig under [Apache-2.0](https://github.com/renerocksai/zli/blob/main/LICENSE),
with no dependencies of its own. Baz retains its MIT license. The public `baz`
and `bounded_http` modules have no zli import; application code chooses its own
CLI parser. The package dependency may still be fetched when Zig evaluates the
Baz build graph. No zli code runs on the request I/O loop.


## Mustache templates

Baz's public `web.mustache` adapter consumes the immutable URL/hash-pinned
[pure Zig Mustache fork](https://github.com/technologylab-ai/mustache-zig). The
module is imported internally as `mustache_engine`; consumers use Baz's wrapper.
The library is MIT licensed and requires exact Zig 0.16.0. Its parser/runtime
changes and core-spec tests belong in that separate repository. Baz owns startup
storage limits, response integration, examples, and native HTTP gates.
See [MUSTACHE.md](MUSTACHE.md) for API, lifetime, output-copy, and feature limits.
