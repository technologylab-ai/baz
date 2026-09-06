# Native streaming response gate — 2026-09-06

Baz can write, flush, wait, and write again inside one fixed-worker handler.
The public `std.Io.Writer` example and its ownership tests passed on native
Linux/io_uring, macOS/kqueue, and Windows x64/IOCP. Baz remains experimental.
These checks establish correctness for the recorded configurations; they do not
measure throughput, peer processing, arbitrary application isolation, or production readiness.

## Source identity

- Baz runtime, examples, build, and tests: `79021c5f6f896b4e8e2c034dbaa9face54b90e87`.
- External [bounded/http](https://technologylab-ai.github.io/bounded-http/) engine:
  `2a269ef57301b21df22f1c616d02d6d244e5d6ca`, Zig package hash
  `bounded_http-0.1.0-N3A1uD4IEQBXzMxjafNtPTuGXAGeklCjLXIInMVXvL9e`.
- Engine change: [PR #3](https://github.com/technologylab-ai/bounded-http/pull/3),
  merged as `86e8ec2cc5fbe9f5d08ed01c496d61ae519cf261`. The package pin
  retains the exact tested head; it is an ancestor of the merge with an identical
  complete Git tree.
- Exact compiler: Zig 0.16.0. Unit/package verification used Debug and ReleaseSafe.
  Every wire fixture and smoke run used ReleaseSafe with assertions enabled.

Later report and website changes preserve the executed Zig/build/test inputs.
The [retained packet](2026-09-06-streaming/) records input hashes, original logs,
run and artifact metadata, structured results, and cleanup. Its selection record
identifies omitted archives; original archive digests remain available without
committing redundant ZIP/tar files.

## Baz native results

| Gate | Linux x86_64 | macOS arm64 | Windows x64 |
| --- | --- | --- | --- |
| Debug root verification | 43/43 steps; 62/62 tests | 43/43; 62/62 | 43/43; 62/62 |
| ReleaseSafe root verification | 43/43 steps; 62/62 tests | 43/43; 62/62 | 43/43; 62/62 |
| Independent consumer, each mode | 3/3 steps; 1/1 test | 3/3; 1/1 | 3/3; 1/1 |
| App wire groups | 14/14 | 14/14 | 14/14 |
| Ported-example groups | 20/20 | 20/20 | 20/20 |
| Streaming groups, including runnable example | 14/14 | 14/14 | 14/14 |
| Windows shard/console cases | Not applicable | Not applicable | 3/3 |

The immutable [Linux/macOS run](https://github.com/technologylab-ai/baz/actions/runs/34049191530)
and [Windows run](https://github.com/technologylab-ai/baz/actions/runs/34049191487)
executed the same Baz revision. Logs and extracted JSON are retained under
[baz-native](2026-09-06-streaming/baz-native/).

| Runner | Environment recorded by the native run | Artifact SHA-256 |
| --- | --- | --- |
| Linux | Kernel 6.17.0-1022-azure, x86_64, Python 3.12.3; io_uring | `46af8a4043bb554b9c1d1d02600e895436f8b2775ac3468dedd644f68a4a0d55` |
| macOS | Darwin 25.6.0, arm64, Python 3.14.7; kqueue | `8cfa890f6db7479bb3b3d9ee3e048b5a0bc0df1441d36c6cfb576994de4aa36b` |
| Windows | Server 2025 Datacenter 10.0.26100 x64, runner image win25-vs2026 / 20260824.214.3; IOCP | `dc4da85a83bec50655f6b2b9b491d3dddc7c28db665ffedc49e7ccf491deff4f` |

The Windows shard cases received 19 responses with two I/O owners, 19 with three,
and six before console shutdown across three owners. Handoff counts reconciled
at 3/3, 4/4, and 4/4 respectively. All streaming/shard cases ended with zero live
connections, live operations, and after-start framework allocations. Every
streaming fixture callback returned before teardown.

## What the streaming suite checks

The first-chunk test uses a client-controlled release: the handler cannot write
its next part until the client has read the first part and observed that the
handler is unfinished. This directly checks delivery before handler return.
It does not infer streaming from total elapsed time or a final concatenated body.

The remaining cases cover:

- Standard writer and repeated/empty flushes, normal-return completion, explicit
  finish, and immutable headers after publication.
- Stack-source mutation after writes; borrowed binary request data retained
  across flushes and sleep; a subsequent pipelined request.
- Known Content-Length, HEAD, bodyless statuses, pre-publication error mapping,
  and closing after an error in an already published response.
- Cumulative size bounds, bounded automatic staging flushes, and rejection of
  streaming from inline execution.
- Request deadlines, disconnects, shutdown, and cancellation while sleeping or
  waiting for output completion, followed by actual connection-slot reuse.
- The maintained [streaming example](../examples/streaming.zig), with three exact
  output parts, two explicit flushes, and final HTTP framing.

Backpressure receipts retain counters around several acknowledged control
requests while the streaming callback has an outstanding flush. They do not
assert that the same original flush stays blocked without intermediate kernel
progress. Cancellation retains kernel borrows until completion, then wakes the
worker to unwind; callback return is required before the slot can be reused.

The suite uses finite socket/process watchdogs. A stream occupies one fixed
worker and uses startup-reserved staging; it does not allocate a request thread
or provide arbitrary application preemption. See [the streaming contract](../docs/STREAMING.md).

## Separate engine regression gates

The worker flush seam changed engine ownership transitions. Its original
callback-returning API and transport paths therefore received separate native
verification and wire regression checks.

| Engine gate | macOS arm64 | Linux x86_64 | Windows x64 |
| --- | --- | --- | --- |
| Debug and ReleaseSafe verification, each | 16/16 steps; 100/104 tests, 4 Linux-only skips | 16/16; 102/104, 2 Windows-only skips | 16/16; 115/119, 4 POSIX skips |
| Comparator checks | 9 | 9 | 9 |
| Core wire cases | 84 | 84 | 89, including Windows shard cases |
| Exact smoke bodies | 30,000 | 30,000 | 30,000 |

Core wire case totals exclude the comparator row. Each smoke gate comprises
three 10,000-response plaintext/HTML pipeline profiles; these are correctness
smokes, not a new Baz/Zap performance comparison. Terminal ownership and framework
allocation counters reconciled to zero.

The Mac host was Apple M3 Max arm64, macOS 26.6.2 / Darwin 25.6.0, Python 3.9.6.
The Linux host was omarx1, Intel Core Ultra 7 258V x86_64, Omarchy 4.0.2,
kernel 7.1.9-arch1-2, glibc 2.44, Python 3.14.7. Host reservations were acquired
atomically, held through child cleanup, and released only by their owners.
The [native engine Windows run](https://github.com/technologylab-ai/bounded-http/actions/runs/34048745802)
used Server 2025 Datacenter x64, build 26100.33296, image
win25-vs2026 / 20260824.214.3, Python 3.12.10. Compiler and server were native PE x64.

Linux executed engine commit `62c238a76ff3fd09ec425066a8a8d7dc3449e733` before
Git reference repair. The retained source archive identity and equivalence record
prove its complete Git tree equals candidate `2a269ef`:
`2465f8b25ce564cfc81e72daffe890b77c62a832`.
The original executed revision is preserved rather than relabeled.
Windows and the Mac core suites executed candidate `2a269ef` directly.

## Website and retained evidence

App basics and Streaming response share the section headed “A struct. A method.
A clear place for everything.” The streaming excerpt is extracted from the
compiled example at site build time. Keyboard tabs, the `#streaming` deep link,
mobile layouts, no-JavaScript fallback, and print presentation are maintained
in the repository. The local candidate preview passed all 15 browser check
groups across 62 reader documents; the retained receipt identifies that preview,
not the later published site or subsequently added report.

The [website guide](../docs/WEBSITE.md) describes rebuild/publication checks.
The [earlier Zap comparison](2026-09-06-basic-zap.md) remains unchanged and measures
the initial App prototype only. No streaming throughput claim is made here.
