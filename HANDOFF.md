# Baz handoff — 2026-09-06

Work from the independent `baz` repository, primary branch `main`.
Public repository: <https://github.com/technologylab-ai/baz>.
GitHub Pages: <https://technologylab-ai.github.io/baz/>.
Baz and its [bounded/http](https://technologylab-ai.github.io/bounded-http/) engine are implemented in Zig. Baz is MIT licensed.
The website, reader, diagrams, and publishing workflow belong to this repository.

## Verified current baseline

**Native Windows x64, Linux, and macOS are supported.** Candidate runtime/test
source `6dcbf2d8f5e1cb73b6dadd5acb0e3380af7b0ad9` passed all three hosted gates:
Debug/ReleaseSafe verification, independent consumer, 14 App groups, and all 20
example groups. Windows additionally passed three native shard-handoff and
console-shutdown cases. The [native receipt](reports/2026-09-06-windows-baz.md)
retains source identity, environments, logs, and statistics. Later website/docs
edits preserve those runtime/test inputs.

The engine pin is `7c24003924bcc76b2a3808cc2fae194082a40105`, package hash
`bounded_http-0.1.0-N3A1uJjOEAD4Yg0JPgeoRomLUpBJeFlfujb4gpSUDcgc`.
Engine PRs #1 and #2 are merged. Baz consumes its public module as an external
dependency. The engine’s own gate remains separate from Baz’s evidence.
The [dependency guide](docs/DEPENDENCY.md) records the boundary and update rules.

Windows uses counted console-handler borrows and portable fail-fast exits.
The shared Python harness supports process groups and Ctrl-Break. `zig build check`
compiles without running target binaries; cross-compilation is not native evidence.
Windows performance remains deferred. Baz as a whole remains experimental.

## Repository and website

The `baz-website` directory is a linked worktree for the original `docs/website`
branch. Its website is integrated into Baz’s `main`; it is not another repository.
The `baz-windows` worktree holds the completed `work/windows-update` integration.
The original `zig-http-app-api` worktree and old paused draft receipts remain
preserved for history. Continue new work from current Baz, not those checkpoints.

[Website maintenance](docs/WEBSITE.md) describes local preview and deployment.
[Website evidence](reports/2026-09-06-website.md) records desktop/mobile/keyboard/print,
reader, sanitization, and live file-hash checks. The `.zig-version` reader entry
uses a public alias because Pages hides dot-prefixed paths.
The README and site explicitly identify pure Zig implementation, Windows support,
and both the [bounded/http](https://technologylab-ai.github.io/bounded-http/) website and source repository.

## Next API sessions

Read the [API guide](docs/APP-API.md), [ownership contract](docs/OWNERSHIP.md), and
[multi-session roadmap](docs/APP-API-ROADMAP.md). API-01–05 and 20 example ports
are implemented. API-06 adds public middleware, typed locals, and cookie
composition; API-07 adds typed resumable endpoints and their ownership gates.

Caller std.Io remains the MVP capability; an owned provider is deferred.
TLS is out of scope. Mustache awaits a pure Zig library choice. WebSockets needs
an engine upgrade lifecycle. The [Zap comparison](reports/2026-09-06-basic-zap.md)
measures prototype `c152e59`, before package extraction. Its raw inputs and
statistics are unchanged. Never benchmark or warm up a Debug build.
