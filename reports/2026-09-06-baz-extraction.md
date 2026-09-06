# Baz external dependency verification — 2026-09-06

Baz (Bounded Async Zap) is an application framework on the separate
[bounded/http server](https://github.com/technologylab-ai/bounded-http).
The engine's [Pages site](https://technologylab-ai.github.io/bounded-http/) supplies its architecture reader.
Both destinations were verified after the repository rename; Pages returned HTTP 200.

Baz now exports `baz` and imports the external `bounded_http` module.
The package pin is engine commit `e52f09f723388685263d14a9bfa265f2456a3744`, proposed in
[bounded/http PR #1](https://github.com/technologylab-ai/bounded-http/pull/1).
The PR is open at this checkpoint; the package uses its immutable commit URL.
The Zig hash is `zig_http-0.1.0-N3A1uPSxDgCdGi1-281VXQB_4LNfMRgQ5asPchYB99xv`.
The prefix reflects the selected engine revision's package metadata.

## Scope and source identity

The [50-file manifest](2026-09-06-baz-extraction-source.sha256.json) covers Baz's source, build, tests, tools, and example inputs.
Its SHA-256 is `efc717de434032960de5a95266866f62808674ee51e4e0756ac25eaa4f76d53e`.
The framework source starts from the first prototype at `c152e59`.
Documentation and raw receipts are outside the source manifest and were completed after native verification.

The extraction removes copied engine source files and the engine demonstration executable.
App, routing, request/form/multipart views, responses, and 20 supported example ports remain in Baz.
Application code now uses public draft and stop methods instead of engine fields or lifecycle methods.
An independent consumer imports both packages and checks engine type identity, raw query behavior, and App initialization.

The [engine PR receipt](https://github.com/technologylab-ai/bounded-http/blob/e52f09f723388685263d14a9bfa265f2456a3744/reports/2026-09-06-app-response-reservation.md)
records separate engine Debug/ReleaseSafe, embedding, core wire, comparator, and smoke gates on both hosts.
Those gates remain upstream.

## Native results

| Gate | macOS | Linux |
| --- | --- | --- |
| Exact compiler | Zig 0.16.0 | Zig 0.16.0 |
| Host/backend | Apple M3 Max, arm64, macOS 26.6.2 (25G83), kqueue | omarx1, Core Ultra 7 258V, x86_64, Linux 7.1.9-arch1-2, io_uring |
| Debug verify | 41/41 steps; 60/60 root test executions | 41/41 steps; 60/60 root test executions |
| ReleaseSafe verify | 41/41 steps; 60/60 root test executions | 41/41 steps; 60/60 root test executions |
| Independent package consumer | Passed in both modes | Passed in both modes |
| ReleaseSafe App suite | 14 groups passed | 14 groups passed |
| ReleaseSafe examples suite | 20 groups passed | 20 groups passed |

`verify` compiles the Baz executable and all 20 supported example targets.
Its separate consumer command adds one test outside the root summary's 60 executions.
Wire suites cover raw queries/forms/uploads, response errors and bounds, routing, composition, and instance shutdown.
The source manifest matches after verification.

The Mac build used the pinned URL dependency; a separate project fetched it with no existing package directory.
An initial fetch probe in an empty non-project directory failed because Zig requires `build.zig` in its project lookup.
The recorded retry copied the package build files and returned the exact expected hash.
This was a fetch setup correction, not a native test failure.

The archive helper was updated during the Mac build gate to exclude generated `zig-pkg` directories.
That helper was not invoked by those Mac gates; all Zig, build, and test inputs stayed unchanged.
The final manifest includes the helper change. Generated package directories are ignored by Git.

Linux started with an empty global cache and no project package directories or sibling engine.
Its explicit fetch returned the exact pinned hash. All eight fetched engine Zig sources matched the independently tested engine.
The Linux run recorded both independent consumer commands and hashed all 21 installed ReleaseSafe binaries.

## Receipts and cleanup

The [Mac packet](2026-09-06-baz-extraction/macos/) contains commands, platform metadata, raw output, and cleanup evidence.
Build commands had 600-second watchdogs; the combined App/example suite had a 180-second watchdog.
The wire wrapper observed 26 server process groups, all absent after the suites.
The final Mac audit found all 36 observed session groups absent and no active measurement processes.
The owner released the cooperative host reservation, and its keeper process was absent afterward.
The executed Mac command wrapper uses the preserved benchmark cleanup-runner snapshot through its original local path.

The [Linux packet](2026-09-06-baz-extraction/linux/) records all six successful commands, source checks, and process identities.
Its complete run took 3m57s, from 14:08:04 to 14:12:02 UTC.
The combined engine/Baz audit found all 38 observed process groups absent and no workspace children.
Build commands used 600-second watchdogs; each wire suite used 180 seconds.
The Linux owner released its reservation at 14:14:49 UTC after cleanup.
The keeper process, lock directory, and owner metadata were absent afterward.

No new performance comparison was run for naming or package extraction.
The [Zap comparison](2026-09-06-basic-zap.md) remains evidence for prototype `c152e59` only.
All load and warmups use ReleaseSafe with assertions; Debug is only for correctness.

This checkpoint does not complete public middleware, typed resumable endpoints, or a custom `std.Io` provider.
TLS remains out of scope. Mustache is postponed for a pure Zig library evaluation.
Framework Windows work waits for the engine session's support on main.
Baz has not been published as its own repository.
