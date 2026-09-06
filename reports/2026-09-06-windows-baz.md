# Baz native Windows support — 2026-09-06

**Baz supports native Windows x64, alongside Linux and macOS.** This is Baz
application/runtime evidence, including all supported examples. It does not
rely on cross-compilation or the engine’s separate gate alone.
Baz remains experimental; these correctness checks are not production or
Windows performance qualification.

## Source and upstream integration

The executed Baz candidate is `6dcbf2d8f5e1cb73b6dadd5acb0e3380af7b0ad9`.
Its [51-file source manifest](2026-09-06-windows-baz/source.json) records build
inputs, framework/example source, and wire harnesses. Later publication edits
change documentation and website content, not those runtime/test inputs. The
[publication source check](2026-09-06-windows-baz/publication-source-check.json)
records 50 unchanged entries and the example catalog’s documentation-only update.

The external bounded/http pin is `7c24003924bcc76b2a3808cc2fae194082a40105`;
its Zig package hash is `bounded_http-0.1.0-N3A1uJjOEAD4Yg0JPgeoRomLUpBJeFlfujb4gpSUDcgc`.
[Engine PR #2](https://github.com/technologylab-ai/bounded-http/pull/2) adds
bounded accepted-socket handoff to Windows IOCP shards. Its merge
`1c74a4e379c365ec0a201e6fe3df1a5a9718d504` matches the verified feature tree
`419de5445901a87ea6973020df5b13a420917483`; main’s subsequent changes are docs.
The engine’s [native gate](https://github.com/technologylab-ai/bounded-http/actions/runs/34044844060)
is independent of Baz’s results below.

Baz adds portable fail-fast exits and counted console-handler borrows. On
teardown it unregisters its Windows handler, clears the published App pointer,
and waits for earlier borrows before destruction. The test harness allocates a
control console when needed, launches a process group, and uses Ctrl-Break for
clean shutdown. `zig build check` supports compilation without running target
binaries; native verification still uses `zig build verify`.

## Native gates

All hosts used exact Zig 0.16.0. Debug and ReleaseSafe each passed 41/41 root
steps, 60/60 root test executions, and the independent consumer’s 3/3 steps and
1/1 test. All 21 executables compiled. ReleaseSafe installation then supplied
the binaries used for the wire suites. No timed performance workload ran.

| Native host | Transport | App groups | Example groups | Additional Windows groups |
| --- | --- | ---: | ---: | ---: |
| Windows Server 2025 Datacenter, x64, build 26100; hosted image `win25-vs2026` / `20260824.214.3` | IOCP | 14 | 20 | 3 |
| macOS runner, arm64, Darwin 25.5.0; Python 3.14.6 | kqueue | 14 | 20 | — |
| Ubuntu runner, x86_64, Linux 6.17.0-1022-azure; Python 3.12.3 | io_uring | 14 | 20 | — |

- [Native Windows run](https://github.com/technologylab-ai/baz/actions/runs/34046203144),
  [job receipt](2026-09-06-windows-baz/windows-run.json),
  [environment](2026-09-06-windows-baz/windows/environment.txt),
  [Debug](2026-09-06-windows-baz/windows/Debug.log),
  [ReleaseSafe](2026-09-06-windows-baz/windows/ReleaseSafe.log),
  [App](2026-09-06-windows-baz/windows/app_integration.log), and
  [examples](2026-09-06-windows-baz/windows/examples_integration.log).
- [Native Linux/macOS run](https://github.com/technologylab-ai/baz/actions/runs/34046203105)
  and [job receipt](2026-09-06-windows-baz/native-run.json).
  [Linux logs](2026-09-06-windows-baz/linux/) and
  [Mac logs](2026-09-06-windows-baz/macos/) preserve both build modes and suites.
- [Receipt hashes](2026-09-06-windows-baz/receipt.sha256.json) cover the retained packet.

## Windows handoff and shutdown

The Windows-only suite ran three finite cases, with six simultaneous connections,
16 total connection slots, inline callbacks, and no application workers:

| Case | Completed responses | Handoffs sent / received | Final live connections / operations |
| --- | ---: | ---: | ---: |
| Borrowed binary pipelines and typed shared-state updates, 2 shards | 19 | 3 / 3 | 0 / 0 |
| The same behavior, 3 shards | 19 | 4 / 4 | 0 / 0 |
| Ctrl-Break shutdown after acknowledged admission, with incomplete requests, 3 shards | 6 | 4 / 4 | 0 / 0 |

[Structured statistics](2026-09-06-windows-baz/windows/shards.json) and the
[original output](2026-09-06-windows-baz/windows/windows_smoke.log) show zero
framework allocations after startup, matching handoff publication/receipt counts,
and clean terminal ownership. The pipeline checks compare every borrowed binary
body, preserve raw query `+`, and require exactly six shared-state updates.
Admission acknowledgments precede partial requests in the shutdown case.
Aggregate counters demonstrate transfers; they do not prove per-owner workload
distribution or Windows throughput.

Hosted jobs had 25-minute watchdogs. Each shared wire harness imposed startup,
socket, and shutdown deadlines and stopped its server in cleanup. The new
multi-shard suite retained client sockets through server shutdown and verified
closure. These runs used GitHub-hosted machines; no shared Mac/Linux host lock
or external performance client was involved.

## Supported scope

Native Windows x64 is supported and exercised by repository CI. Other Windows
architectures and OS releases are not established by this packet. Linux and
macOS passed fresh regressions on the same runtime/test source. The API remains
the bounded one-shot implementation; resumable typed endpoints, TLS, Mustache,
and an owned std.Io provider keep their separately documented dispositions.
The historical Baz/Zap comparison remains unchanged and covers only its named
Mac/Linux prototype experiment.
