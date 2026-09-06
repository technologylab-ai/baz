# Pure Zig Mustache selection

Source review: 2026-09-06. Baz adopts an MIT-licensed Zig 0.16 library and extends
its cached renderer with work/depth bounds. The user prefers Zig over C so startup
parsing, allocator use, and generated response memory remain under application control.
See the [integration guide](MUSTACHE.md) for the public API and limits.

| Candidate and reviewed source | Decision |
| --- | --- |
| [diogok/mustache-zig at eb023612](https://github.com/diogok/mustache-zig/tree/eb023612e85774861e6a9be18e674a497a340f0f) | Selected. Pure Zig, MIT, exact Zig 0.16.0, cached templates and `std.Io.Writer`, typed contexts, a substantial inherited test suite. Baz's [fork](https://github.com/technologylab-ai/mustache-zig) adds bounded cached APIs, parser guards, and independent specification/Zap tests. |
| [corvohq/zigstache at 2d59501a](https://github.com/corvohq/zigstache/tree/2d59501af015bc470e7fb4b5dbeee37b6d5fb205) | Attractive fixed storage and small API. Its 47 baseline tests passed locally with Zig 0.16, but source review exposed incomplete array/context/partial behavior and no render-work bound. Qualifying it would require replacing too much of the renderer. |
| [limistah/mustache-zig at 50ff8d47](https://github.com/limistah/mustache-zig/tree/50ff8d472afed5c6907379476f88089639d9bd4e) | Zig 0.16 and writer API fit. No license in the reviewed tree; not adopted. |
| [batiati/mustache-zig](https://github.com/batiati/mustache-zig) | The selected library's older upstream lineage. Its existing Zig 0.16 fork avoids a new full compiler port. Attribution remains in the dependency. |

The selected baseline's local Debug suite passed 329 tests with 29 upstream
comptime-disabled skips. Those skips are not counted as core-spec evidence.
The independent runner vendors the six official core JSON suites at
[`e8ec001d`](https://github.com/mustache/spec/tree/e8ec001db7f594521e773c34866aca2b5d6b0037):
136 cases, each rendered with normal and exact output capacity, without skips.
It uncovered inherited standalone-partial indentation bugs, repaired in the fork.

The fork's additive bounded API disallows lambdas, inheritance/blocks, and dynamic
partials. Nodes, iterations (even empty ones), lookups, and source/output bytes
consume a finite shared budget. Depth limits cover recursion through sections,
partials, and context lookup. Parser recursion is guarded before descent. Failed
renders can leave a writer prefix; Baz keeps response output private until success.

Original Zap behavior is pinned to
[`f6099ece`](https://github.com/zigzap/zap/tree/f6099ecec496c7ec623c5913baa5b6b5da2e883d).
Compatibility tests preserve its exact typed array/slice output, raw versus
escaped interpolation, changed delimiters, separately parsed partials, dotted
lookup, and final-newline differences. The runnable Baz example presents those
capabilities as a small real HTML page with concise Zig source.
