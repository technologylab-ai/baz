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

## Paused Windows work

The local `work/windows-update` branch preserves the paused draft.
Its [partial receipts](reports/2026-09-06-windows-draft/README.md) are retained on that branch.
It adds portable process exits, counted console-handler borrows, target-aware compile-only checks, and Windows build/unit CI.
Its provisional engine pin is `bb14d98756152936fadb6e8353852a686e8d315d`.
The user paused this update while another agent implements bounded connection handoff to Windows shards.
Wait for that PR and its native evidence before choosing the final pin and resuming verification.

Windows x64 Debug cross-compilation passed all 33 root steps and the consumer's two steps before the pause.
ReleaseSafe cross-compilation was stopped at the user's request; no Windows Baz executable has run.
The draft has no new native Mac/Linux regression evidence.
All owned builds stopped and both host reservations were released.
The original partial receipts are under `/tmp/baz-windows-macos-20260906/` and
`omarx1:/tmp/baz-windows-linux.0h7c_368/`.

## Next API sessions

API-06 adds public middleware, typed locals, and cookie composition.
API-07 adds typed resumable endpoints and their ownership gates.
Caller `std.Io` remains the MVP capability; an owned provider is deferred.
TLS is out of scope. Mustache awaits a pure Zig library choice.
The [Zap comparison](reports/2026-09-06-basic-zap.md) measures prototype `c152e59`, before package extraction.
