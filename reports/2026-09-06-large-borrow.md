# Large borrowed response bodies — 2026-09-06

The Baz change in [PR #1](https://github.com/technologylab-ai/baz/pull/1) allows a
5 MiB immutable asset to use `borrowBody` with a 4 KiB per-connection output arena.
Borrowed-body length now follows `server.max_response_bytes`, independently of
copied/generated staging capacity. The existing engine already supports this;
no transport or engine source changes are needed.

## API and ownership

App passes the configured total limit to `Response.initWithLimit`. Direct
Response users can select that constructor, while the original `init` retains
its conservative staging-sized total bound. Copied/generated responses still
obey `response.body_bytes`, and streaming still uses that fixed staging buffer.
Finalization forms a staging slice only for copied/generated output.

Eligible bodies remain retained request input or immutable server-lifetime
assets. A startup heap allocation can qualify if it stays alive and unchanged
through terminal App shutdown. A per-request buffer freed on handler return
does not qualify. This change adds no dynamic release callback.

Above the engine's small-borrow threshold (256 bytes by default), the payload is
sent from the original retained span without copying it into another framework
buffer. Header construction and ordinary kernel/network transfers remain.
See the [copy and lifetime contract](../docs/OWNERSHIP.md#response-copies-and-borrowing).

## Source and commands

The candidate for hosted native verification is
`86249ad4ea6a85407dd9463b43311c0c2be1e293`. The preceding implementation commit
`ae25240737a714c07629df0667971d4fdc2107e9` differs only in the wording of one
wire-case name, which now acknowledges deadline fallback after peer disconnect.
Local gates executed the earlier wording; retained receipts preserve it.

The external [bounded/http](https://technologylab-ai.github.io/bounded-http/) pin
remains `2a269ef57301b21df22f1c616d02d6d244e5d6ca`, package hash
`bounded_http-0.1.0-N3A1uD4IEQBXzMxjafNtPTuGXAGeklCjLXIInMVXvL9e`.
[Engine PR #3](https://github.com/technologylab-ai/bounded-http/pull/3) is merged.
Its merge commit has the same complete tree as this tested pin. The
[streaming receipt](2026-09-06-streaming.md) retains the separate engine gates.

```sh
zig build verify -Doptimize=Debug -j2 --summary all
zig build verify -Doptimize=ReleaseSafe -j2 --summary all
zig build install examples -Doptimize=ReleaseSafe -j2
python3 tests/app_integration.py
python3 tests/examples_integration.py
python3 tests/streaming_integration.py
python3 tests/borrow_integration.py
# Native Windows additionally:
python tests/windows_smoke.py
```

All commands use exact Zig 0.16.0. Every wire fixture uses ReleaseSafe with
assertions enabled; Debug is used for unit/package correctness only. No
performance comparison or Debug timing workload was run.

## Gate coverage

Three new unit groups check a 5 MiB retained pointer with **zero body staging**
and a 1 KiB arena, GET/HEAD metadata, unchanged earlier output, bodyless statuses,
one-byte-over-total rejection, private error fallback, discard, and unchanged
copied/generated limits. The standard constructor remains conservative.

The native borrowed-body suite has nine groups:

1. Exact binary GET and HEAD in inline execution, followed by another response.
2. The same checks using a fixed worker.
3. Complete output across forced 997-byte send submissions.
4. A stopped reader holds a pipelined marker until the complete asset drains.
5. Copied bodies still reject the 5 MiB source against 1 KiB staging.
6. Borrowed bodies reject a source exceeding the server's separate total bound.
7. A deadline cancels pending output and permits reuse of the exact freed slot.
8. Peer disconnect reconciles the borrow within the original request deadline
   and permits slot reuse; the deadline may be the observed cancellation cause.
9. Shutdown reconciles a pending gather send before storage release.

The 5,242,880-byte asset contains NUL, high bytes, and CRLF. Its SHA-256 is
`3a7f4e46eab3f5458399ce8d0fee49dd2ee0216f0f23399db1c97f31937a6d0f`.
The client validates its full length, digest, and exact bytes under an explicit
5 MiB + 64 KiB reader bound. Forced send caps establish repeated submissions;
they do not themselves establish kernel short completions.

Backpressure tests use acknowledged control responses to observe the undelivered
asset's queued marker. Cancellation checks incomplete payload transmission,
pending gather cancellation where required, and admission of a new connection
while the other slot remains occupied. This demonstrates actual slot reuse.
A cancellation completion can race with an ordinary terminal send completion.

For non-error cases, `borrow_copies` and `response_draft_copy_bytes` stay zero.
These counters cover the named small-borrow and draft-compaction paths, not all
memory copies. Pointer-identity unit tests and source review additionally verify
that the large payload is retained directly. Error cases legitimately copy their
small fallback body. Terminal connection, operation, and after-start framework
allocation counters must be zero for every case.

## Results

Local macOS arm64 (Apple M3 Max, macOS 26.6.2 / Darwin 25.6.0, Python 3.9.6)
passed Debug and ReleaseSafe verification: 68 root tests and one independent
consumer test per mode. Debug `verify` used 44/44 root steps; combined ReleaseSafe
`verify install examples` used 70/70. All 14 App, 14 streaming, and nine borrowed-body
groups passed. The cooperative host reservation was held through child cleanup
and released by its owner.

All three hosted native gates passed. Each executed the PR merge checkout
`4239e052cc569dc3b89c3a821a4df5db126788a1`; its complete Git tree
`addf88eb3b1352d94db6fc6842903f223199ecc8` equals candidate `86249ad`.
Later report/website changes preserve all 56 runtime/build/CI/test/example inputs.
The [retained packet](2026-09-06-large-borrow/) includes source identity, original
logs, run/artifact metadata, structured results, and local cleanup/preview context.
Archive digests are preserved; redundant ZIP files are excluded.

| Native gate | Linux x86_64 | macOS arm64 | Windows x64 |
| --- | --- | --- | --- |
| Debug and ReleaseSafe, each | 44/44 root steps; 68/68 tests | 44/44; 68/68 | 44/44; 68/68 |
| Independent consumer, each mode | 3/3 steps; 1/1 test | 3/3; 1/1 | 3/3; 1/1 |
| App / ported examples / streaming / borrowed-body groups | 14 / 20 / 14 / 9 | 14 / 20 / 14 / 9 | 14 / 20 / 14 / 9 |
| Windows shard/shutdown cases | Not applicable | Not applicable | 3/3 |

The [Linux/macOS run](https://github.com/technologylab-ai/baz/actions/runs/34050620006)
and [Windows run](https://github.com/technologylab-ai/baz/actions/runs/34050619965)
are distinct from the canceled redundant push runs, which are not passing evidence.
All 27 borrowed-body cases ended with zero connection/operation owners and
zero after-start framework allocations. All 21 healthy/cancellation cases had
zero small-borrow copies and draft-body compaction. Error cases correctly copied
their private fallback. The existing streaming and Windows shard ownership checks
also ended at zero.

| Runner | Recorded environment | Artifact SHA-256 |
| --- | --- | --- |
| Linux | Kernel 6.17.0-1022-azure x86_64, Python 3.12.3; io_uring | `d237e6f81818dc6b5f808ede7cf9d746c22dd167f1f460a7be47cb1083cea42e` |
| macOS | Darwin 25.6.0 arm64, Python 3.14.7; kqueue | `0778af6efb280fb107c8a5bb8d99f1c3b49763c692772e7ab8f27583aa2eeddc` |
| Windows | Server 2025 Datacenter x64 build 26100, image win25-vs2026 / 20260824.214.3; IOCP | `a8e00e65caa6c8db1189079ea5c343be81fe959e87b9c1ce0cbdfa220f0f3416` |

Baz remains experimental. These gates address correctness and bounded ownership;
they do not establish production qualification, performance, or zero-copy networking.

## Website presentation

The PR adds Borrowed asset as the third option beside App basics and Streaming
response. Its call is extracted from the compiled 5 MiB fixture, and its prose
explains the total bound, storage lifetime, small-borrow threshold, and continuing
copying behavior of the default helpers. `#borrowed` opens it directly. Pages
builds the PR for validation and deploys only after integration into `main`.

The local preview passed all 16 browser groups across 65 documents, including
exact excerpt identity, all three tabs, keyboard wrap/Home/End, repeated deep
links, 390/320-pixel layouts, print, and no-JavaScript fallback. The browser and
preview server stopped before their cooperative reservation was released.
The preview is separate from the native HTTP tests and the currently live site.
