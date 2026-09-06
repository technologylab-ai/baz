# Deferred pure Zig Mustache evaluation

Source review: 2026-09-06. The user prefers Zig libraries over C wrappers so
startup parsing, allocator use and request output memory remain controllable.
No dependency was installed or integrated; these are candidates, not qualified
runtime features. Mustache integration follows the current API/examples work.

| Candidate and pinned source | Memory/API fit | Evidence and remaining work |
| --- | --- | --- |
| [corvohq/zigstache](https://github.com/corvohq/zigstache/tree/2d59501af015bc470e7fb4b5dbeee37b6d5fb205) | Pure Zig, MIT. Template storage is a configured fixed array (default 1,024 elements), with a bounded parse stack (default 64). Rendering accepts caller output storage and returns overflow; the examined path needs no allocator. | Best first memory-shape candidate. The reviewed CI targets Zig 0.15.2 and package minimum is 0.14.0; exact 0.16.0 compatibility is unverified. Parser nesting bounds do not prove bounded recursive partial rendering. No published release found; pin the reviewed commit. |
| [limistah/mustache-zig](https://github.com/limistah/mustache-zig/tree/50ff8d472afed5c6907379476f88089639d9bd4e) | Pure Zig. Parsing takes an allocator and owns an arena, suitable for startup. Ordinary rendering targets `*std.Io.Writer`, suitable for a fixed unpublished response. Extended lambda rendering can allocate/reparse and needs a separate policy. | Exact 0.16.0 is declared and exercised by [CI](https://github.com/limistah/mustache-zig/actions/runs/26158127497). Tests were not reproduced here. No license was found in the reviewed tree, so do not adopt without clarification. Rendering/partial work bounds also need qualification. Pin a commit because release and package version labels differ. |

Primary implementation evidence:
[zigstache source](https://github.com/corvohq/zigstache/blob/2d59501af015bc470e7fb4b5dbeee37b6d5fb205/src/zigstache.zig),
[zigstache CI](https://github.com/corvohq/zigstache/blob/2d59501af015bc470e7fb4b5dbeee37b6d5fb205/.github/workflows/ci.yml),
[mustache-zig renderer](https://github.com/limistah/mustache-zig/blob/50ff8d472afed5c6907379476f88089639d9bd4e/src/render.zig),
[mustache-zig package](https://github.com/limistah/mustache-zig/blob/50ff8d472afed5c6907379476f88089639d9bd4e/build.zig.zon).

Evaluate zigstache first under exact 0.16.0 Debug/ReleaseSafe. Require the
original Zap example's changed delimiters, list sections, dotted lookup, escaped
and unescaped interpolation. Check startup storage exhaustion, exact-fit and
one-byte-overflow output, malformed templates, input escaping, partial cycles
and nesting/work bounds. Start with bounded acyclic templates and no lambdas;
render into an unpublished fixed response and discard any overflow prefix.
Use allocator instrumentation where applicable. Do not add a renderer merely
because its simplest greeting compiles; preserve official-spec evidence and
native framework ownership tests separately.
