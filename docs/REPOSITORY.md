# Standalone Baz repository

Baz has an independent [GitHub repository](https://github.com/technologylab-ai/baz)
and [GitHub Pages site](https://technologylab-ai.github.io/baz/).
Its local Git repository has its own object storage and branch configuration.
The local checkout is `../baz`; its primary branch is `main`.
The original `zig-http-app-api` worktree remains a preserved source checkpoint.
The publication name is `technologylab-ai/baz`. Website source and its Pages
workflow live in this repository. The `baz-website` directory is a linked
worktree for the website branch, not a separate website repository.

## History and package boundary

The repository retains the original commit identities and authors.
Its history includes the engine case study and the first Baz prototype.
Commits `c152e59` and `b3d4d8a` remain reachable for their recorded evidence.
The working tree contains Baz's API, examples, docs, and application receipts.
Engine-only benchmark preparation and September 5 engine reports remain upstream and in Git history.
The Baz/Zap comparison and all its raw inputs remain unchanged.

`bounded_http` is a pinned external dependency. No sibling checkout is needed to build Baz.
The [dependency record](DEPENDENCY.md) explains module identity and the selected revisions.
The [MIT license](../LICENSE) covers Baz's code; adapted examples retain [Zap's notice](../examples/LICENSE-ZAP).
Historical third-party archives retain their original notices and terms.

## Branches

| Branch | Contents | Evidence |
| --- | --- | --- |
| `main` | Pure Zig Baz framework, native Linux/macOS/Windows support, MIT license, and the Pages website | [Native three-platform receipt](../reports/2026-09-06-windows-baz.md), including Baz’s Windows App/example/shard checks. |
| `work/windows-update` | Integration branch for the completed engine update and Windows support | Executed runtime/test source `6dcbf2d`; its earlier paused draft receipts remain in history. |
| `docs/website` | Original website implementation branch | Integrated into `main`; subsequent site updates live in Baz. |

The Windows integration replaces the provisional engine pin with the merged
sharding revision. Read [HANDOFF.md](../HANDOFF.md) for the next API work.

## CI and publication

[CI](../.github/workflows/ci.yml) installs exact Zig 0.16.0 from the official download index and verifies the archive checksum.
It runs Debug and ReleaseSafe verification on GitHub-hosted Linux and macOS runners.
It also builds and exercises all supported examples with ReleaseSafe binaries.
Hosted logs are retained for 14 days; preserve material runtime evidence in dated reports.
The [native Windows workflow](../.github/workflows/windows-build.yml) verifies
both build modes, the consumer, all App/example suites, and three handoff/shutdown
cases. Windows x64 is supported; production qualification remains outside these gates.
Hosted runs provide separate evidence from the existing local receipts.
Check [Actions](https://github.com/technologylab-ai/baz/actions) for their results.

Baz’s `origin` points to its own repository. The engine repository URL appears
as the dependency and documentation destination. Keep the engine independently
usable and submit engine changes upstream.

[The website workflow](../.github/workflows/pages.yml) builds a checked static
artifact on pull requests and publishes `main` to GitHub Pages. It uses repository
Markdown, maintained example source, original benchmark summaries, and local
browser libraries with preserved notices. See [website maintenance](WEBSITE.md)
for local preview, verification, and publication details.
