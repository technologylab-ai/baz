# Baz standalone repository handoff — 2026-09-06

Work from the independent `baz` repository now. The primary branch is `main`.
The original `zig-http-app-api` worktree is preserved, including its uncommitted Windows draft.
Read [repository preparation](docs/REPOSITORY.md), the [API guide](docs/APP-API.md),
and the [roadmap](docs/APP-API-ROADMAP.md).

Baz is MIT licensed. Git history, Zap attribution, benchmark inputs, and Baz's native receipts remain intact.
Baz’s public repository is [technologylab-ai/baz](https://github.com/technologylab-ai/baz),
with [GitHub Pages documentation](https://technologylab-ai.github.io/baz/).
Website source, its build/check scripts, and Pages workflow belong to Baz’s main branch.
See [website maintenance](docs/WEBSITE.md) and [Actions](https://github.com/technologylab-ai/baz/actions)
for publishing and hosted verification. The separate Windows draft remains paused.

## Verified baseline

Main retains the runtime source and engine pin from `b3d4d8a`.
[The package receipt](reports/2026-09-06-baz-extraction.md) records native macOS/Linux Debug and ReleaseSafe verification,
independent consumers, 14 App groups, and 20 example groups.
[bounded/http PR #1](https://github.com/technologylab-ai/bounded-http/pull/1) is merged.
Main keeps its tested immutable engine pin until the paused dependency update is qualified.
Repository preparation changes documentation and package contents, not runtime behavior.

## Windows integration candidate

The user resumed this update after [bounded/http PR #2](https://github.com/technologylab-ai/bounded-http/pull/2)
merged. Candidate branch `work/windows-update` pins engine main
`7c24003924bcc76b2a3808cc2fae194082a40105`, with package hash
`bounded_http-0.1.0-N3A1uJjOEAD4Yg0JPgeoRomLUpBJeFlfujb4gpSUDcgc`.
The engine’s native Windows gate ran at `419de5445901a87ea6973020df5b13a420917483`;
its tree matches merge `1c74a4e379c365ec0a201e6fe3df1a5a9718d504`.
The later main commit changes documentation only.

This candidate retains the original portable exits, counted console-handler
borrows, target-aware compile checks, and Windows CI. It adds Windows process
group/control-console handling to the wire harness and three finite native
multi-shard App checks. Existing App and example suites remain shared across
platforms. New native Windows, Linux, and macOS gates must pass before merging.
No cross-compilation or engine receipt alone qualifies Baz runtime behavior.

The old paused draft’s [partial receipts](reports/2026-09-06-windows-draft/README.md)
remain intact. Its earlier x64 Debug cross-compilation passed; the stopped
ReleaseSafe run was not a pass. No timing experiment is part of this update.

## Next API sessions

API-06 adds public middleware, typed locals, and cookie composition.
API-07 adds typed resumable endpoints and their ownership gates.
Caller `std.Io` remains the MVP capability; an owned provider is deferred.
TLS is out of scope. Mustache awaits a pure Zig library choice.
The [Zap comparison](reports/2026-09-06-basic-zap.md) measures prototype `c152e59`, before package extraction.
