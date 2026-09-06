# Baz handoff — 2026-09-06

Work from the independent `baz` repository, primary branch `main`.
Public repository: <https://github.com/technologylab-ai/baz>.
GitHub Pages: <https://technologylab-ai.github.io/baz/>.
Baz and its [bounded/http](https://technologylab-ai.github.io/bounded-http/) engine are implemented in Zig. Baz is MIT licensed.
The website, reader, diagrams, and publishing workflow belong to this repository.

## Verified current baseline

**Native Windows x64, Linux, and macOS are supported, including streaming.**
Runtime/test source `79021c5f6f896b4e8e2c034dbaa9face54b90e87` passed all three
hosted gates: Debug/ReleaseSafe verification (62 root tests and one independent
consumer test per mode), 14 App groups, 20 ported-example groups, and 14 streaming
groups including the runnable example. Windows additionally passed three native
shard-handoff and console-shutdown cases. The [streaming receipt](reports/2026-09-06-streaming.md)
retains source identity, environments, logs, and ownership statistics. Later
website/docs edits preserve those runtime/test inputs.

The engine pin is `2a269ef57301b21df22f1c616d02d6d244e5d6ca`, package hash
`bounded_http-0.1.0-N3A1uD4IEQBXzMxjafNtPTuGXAGeklCjLXIInMVXvL9e`.
Engine PRs #1 and #2 are merged. [Engine PR #3](https://github.com/technologylab-ai/bounded-http/pull/3)
provides the worker flush seam and merged as `86e8ec2` on 2026-09-06. The pin
is its tested head revision, whose complete tree matches the merge. Baz consumes the public module as an external dependency. The engine’s
own native gates remain separate from Baz’s evidence.
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

The integrated streaming implementation provides imperative worker streaming,
a standard response writer, cancellation-aware sleep, and a runnable streaming
example beside App basics on the website. Read [STREAMING.md](docs/STREAMING.md).
The engine seam is [PR #3](https://github.com/technologylab-ai/bounded-http/pull/3),
pinned by immutable URL/hash. Native streaming gates passed on all three platforms. The website presents
App basics and Streaming response as adjacent tabs; `#streaming` opens the latter.

Read the [API guide](docs/APP-API.md), [ownership contract](docs/OWNERSHIP.md), and
[multi-session roadmap](docs/APP-API-ROADMAP.md). API-01–05 and 20 example ports
are implemented. API-06 adds public middleware, typed locals, and cookie
composition; API-07 adds typed resumable endpoints and their ownership gates.

The [response copy review](docs/OWNERSHIP.md#response-copies-and-borrowing)
records current copying paths. The large-borrow change separates the total
response bound from staging capacity: immutable 5 MB assets can use `borrowBody`
with a small arena. Native verification is being recorded for this PR; the
streaming receipt above describes the earlier baseline, not this change.
Ordinary stream writes still copy. Do not claim minimum copies.

Caller std.Io remains the MVP capability; an owned provider is deferred.
TLS is out of scope. Mustache awaits a pure Zig library choice. WebSockets needs
an engine upgrade lifecycle. The [Zap comparison](reports/2026-09-06-basic-zap.md)
measures prototype `c152e59`, before package extraction. Its raw inputs and
statistics are unchanged. Never benchmark or warm up a Debug build.
