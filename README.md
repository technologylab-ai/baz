# Bounded Zig HTTP

An experimental HTTP/1.1 framework and reference server for **Zig 0.16.0**.
Linux uses a custom single-shot `io_uring` adapter; macOS uses nonblocking
sockets with `kqueue`. Application callbacks can run on the I/O owner or on fixed startup workers.
Inline execution is the default for trusted bounded, nonblocking handlers;
blocking callbacks must explicitly select fixed startup workers. Windows support is pending and currently produces
a compile error. This is the M4 implementation informed by the adjacent
[Zig LLM Wiki](https://github.com/technologylab-ai/zigllmwiki/blob/main/wiki/bounded-http-server-design.md).

The first goal is a working ownership and pending/resume model that we can
measure and change. This is not a production qualification or a TechEmpower
ranking. It listens on **IPv4 loopback only**, speaks plain HTTP/1.1, and has no
TLS, proxy protocol, upgrade/tunnel implementation or general file server.

Run these commands from the repository root with the exact `zig` compiler on
`PATH`; `verify` checks that its version matches [.zig-version](.zig-version).
Python 3 is needed for the version check, integration suite and smoke client.
ReleaseSafe is the preferred experiment mode; assertions remain enabled.

```sh
zig version
zig build verify -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseSafe
./zig-out/bin/zig-http --port 8080 --connections 128
```

The version must print `0.16.0`. The server prints `READY` to stderr after
startup. Use Ctrl-C/SIGINT or SIGTERM to stop it; `--duration-ms 30000` requests
shutdown after a finite run. `--port 0` asks the OS for an available loopback
port, reported in `READY`. The HTML file is loaded before serving starts.

| Route | Behavior |
| --- | --- |
| `/plaintext` | `Hello, World!`, exactly 13 bytes, `text/plain`. |
| `/` and `/index.html` | The startup-loaded [assets/index.html](assets/index.html); `--index FILE` selects another file, limited to 65,535 bytes (the current file-reader bound is exclusive). |
| `/echo` | Echoes the complete bounded request body through borrowed spans; accepts Content-Length or chunked framing. |
| `/chunks` | Three flush/resume turns followed by finish, producing `first second third` with chunked response framing. |
| `/stall` | Worker-mode blocking fixture; inline returns 501. |
| `/buffered` | Writes its distinct raw request target into reserved output; 413 if it exceeds output capacity. |
| `/borrowed-body` | Borrows a fixed-length request body through finish; chunked input receives 501. |
| Other paths | 404. CONNECT receives 501; no tunnel is opened. |

HEAD follows the handler path but suppresses response body bytes. Keep-alive
and ordered pipelining are supported, with one active callback per connection and a bounded batch of frozen finished responses.
The parser validates all framing/header syntax and interprets only the fields
needed for framing and connection control. `request.header(name)` performs a
lazy, case-insensitive lookup; its first matching value is borrowed, not copied
or combined with repeated fields. Chunk trailers are validated and discarded.

Run the wire/ownership suite against the installed binary, and optionally check
Debug as well:

```sh
python3 tests/integration.py --server zig-out/bin/zig-http --json .zig-cache/integration.json
zig build verify -Doptimize=Debug
```

For Linux Debug, `build.zig` explicitly selects bundled LLVM/LLD after the native
ELF linker rejected `.sframe` relocations in the Linux test host's GCC 16 CRT.
ReleaseSafe uses Zig's default toolchain selection. ReleaseFast and ReleaseSmall
are deliberately rejected. The integration suite
launches its own finite server instances and tests wire framing, fragmentation,
16-request pipelining, partial sends, flush/resume, overload recovery, worker
stall separation, request deadlines, slow readers and shutdown ownership. Its
client deadlines and process watchdogs are test bounds, not latency promises.
See [evidence inputs](docs/EVIDENCE.md) for source scope. Native Linux and macOS
gates establish their own results; cross-compilation never replaces them.

To use the framework, import the `bounded_http` module exported by
[build.zig](build.zig), provide an [api.Handler](src/api.zig), and follow the
startup/run/stop lifecycle in [src/main.zig](src/main.zig). Its actual demo
callback is the maintained example. [src/server.zig](src/server.zig) exposes
`Config`, `Server`, `api` and `Budget`; builds link libc. Treat this API as
experimental and read the [ownership contract](docs/OWNERSHIP.md) before
retaining slices or adding asynchronous application work.

The default `./zig-out/bin/zig-http` uses inline execution, gather sends and up to 16 responses per batch.
`--execution inline` selects it explicitly.
It provisions **zero application workers** and runs the same handler/writer path
on the I/O owner. Callbacks and flush resumptions must be short and nonblocking;
they must not sleep, perform blocking I/O or wait for work. The server cannot
preempt a violating callback or enforce deadlines while that callback runs.
The demo `/stall` route therefore returns501 in inline mode. Explicit
`--execution inline --workers 2` is rejected. Worker mode is selectable
with `--execution workers --workers 2`; this is an execution-policy experiment,
not yet a per-request offload API or multiple I/O shards.

Run `python3 tests/inline_integration.py` for inline framing, partial sends,
empty flush/resume, bounds and shutdown gates. Execution mode and separate
inline/worker dispatch counters accompany READY/STATS. Both modes retain all
safety assertions, borrowed payload ownership and configured connection limits.

A callback receives `event = .request` after the complete request has arrived,
a writer, eight zeroed state words for its continuation, an application pointer
and a cooperative cancellation flag. Use `begin` once; then `reserve/commit`
to produce bytes directly in output storage, or `borrow` for eligible existing
bytes. `write` is the explicit convenience-copying path.

**`return writer.flush()` means send everything currently committed.** It
freezes that output snapshot and yields the callback. Partial sends continue on
the I/O owner. Once all earlier batched responses and this snapshot have been accepted by the local socket, the
handler resumes with `event = .flushed` and an empty writable buffer. Success
means the local socket accepted the bytes; it does not prove peer receipt.
`return writer.finish()` sends the remaining bytes and completes HTTP framing,
without another application callback. No later writes belong to that response.

`borrow` and `begin`'s `content_type` currently require request-owned input or
immutable server-lifetime storage. There is no dynamic lease-release callback
on finish/cancellation. Stack locals and externally recycled buffers must not
escape a callback this way. If `reserve` returns `WouldBlock`, flush the existing
committed bytes and continue from `context.state` on resume; a reservation larger
than the entire configured output buffer must be split. Commit only initialized
bytes and return immediately after flush/finish.

The default startup limits are explicit:

| Resource | Default | Configuration |
| --- | --- | --- |
| Admitted connections/request slots | 128 | `--connections`; 1–4096. |
| Application workers | 0 | Inline default; `--execution workers` selects 2 unless `--workers` sets 1–64, at most the connection count. |
| Request body | 64 KiB | `--max-body`; at most 16 MiB, cumulative after chunk decoding. |
| Header bytes | 16 KiB | `--max-header`; 128 bytes–64 KiB, including request line and shared trailer budget. |
| Header/trailer count | 64 combined | `Config.max_headers`; 1–1024. |
| Request target | 8192 bytes | Fixed MVP parser setting, also subject to the header budget. |
| Receive wire buffer per slot | `max_header + 2 * max_body + 4096` | Checked startup derivation; chunk framing consumes this independent bound. |
| Writable output per response cell | 4 KiB | `--output-bytes`; 1 byte–64 KiB. |
| Response cells per connection | 16 inline, 1 workers | `--response-batch-limit`; 1–16, effective limit 1 in worker mode. |
| Inline callbacks per event-loop turn | 64 globally | Fixed fairness budget; each connection gets at most its response batch limit, with rotating scan start. |
| Logical response body | 16 MiB | `--max-response`; counted across flushes. |
| Request cycle deadline | 5000 ms | `--timeout-ms`; includes receive, worker queue/execution and response sending. |
| Shutdown drain deadline | 5000 ms | `Config.shutdown_ms`; positive. |
| Worker stack request | 1 MiB each | `Config.worker_stack_bytes`; at least 64 KiB. |
| Startup memory budget | 512 MiB | `--memory-budget`; see the accounting boundary below. |
| Requested socket send buffer | 64 KiB | `--socket-send-buffer`; positive, up to 16 MiB. The OS may adjust this request. |
| Bytes per send operation | 64 KiB | `--send-chunk`; positive, useful for forcing partial progress in tests. |

Startup rejects inconsistent or over-budget configurations. The configured
connection count bounds admitted slots, not the kernel TCP backlog. The server
may accept one extra descriptor and immediately close it when all slots are
occupied; it creates no extra request state and does not promise an HTTP 503.
There is one data operation per connection and separately reserved cancellation
capacity, bounded by `2 * (connections + 1)` operation records. Admission resumes
when the old application and transport owners have actually released a slot.

The demo caps requested live bytes through its framework allocator at
`memory_budget_bytes - workers * worker_stack_bytes`, reserving the requested
worker stack budget separately. `Budget` tracks live/peak requested bytes and
refuses allocation, resize or remap growth beyond that heap cap. Startup also
checks exact requested framework heap bytes plus requested worker stacks before allocation, including every response cell and gather descriptor. This is not an RSS limit: allocator
metadata, libc/pthread metadata and actual stack mappings, mapped kernel rings,
socket queues, loaded assets and arbitrary application allocations require
separate accounting. Zig 0.16's pthread implementation uses its C allocator for
thread bookkeeping despite the supplied spawn allocator. The demo seals its
framework allocator after startup and counts/refuses subsequent allocation
attempts through it. See [Budget](src/budget.zig) for the implementation.

Worker separation keeps a finite slow handler off the I/O thread, but is not
isolation from arbitrary application code. Slots have fixed worker affinity;
a blocked callback delays other requests assigned to the same worker. Threads
share memory and process fate. Deadlines set cancellation and close networking;
they cannot safely preempt arbitrary code or recycle its borrowed buffers.
If shutdown cannot recover all owners within its deadline, the demo terminates
the process with exit code 70 instead of freeing storage still in use.

For a first measurement, keep the server running and use a second terminal:

```sh
python3 tools/benchmark.py http://127.0.0.1:8080/plaintext --connections 8 --requests 10000 --pipeline 16 --json .zig-cache/plaintext-smoke.json
python3 tools/benchmark.py http://127.0.0.1:8080/index.html --connections 8 --requests 1000 --expect-file assets/index.html --json .zig-cache/html-smoke.json
```

This Python client checks bodies and records throughput and closed-loop pipeline
latencies; it may be the bottleneck. It is a smoke experiment, not server
capacity or an open-loop service-level measurement. The separate
[Linux contender comparison](reports/2026-09-05-comparison.md) measures pinned
Round23 mrhttp/libreactor with wrk: our unchanged MVP is substantially slower,
especially under pipelining. Subsequent inline/gather and batching experiments preserve that baseline. Its CPU budget, different callback/resource
contracts and rejected tail-latency evidence are explicit.
The subsequent [bounded batching report](reports/2026-09-05-batch.md) preserves
inline/gather improvements, one-core comparisons, deeper-pipeline plateaus and
run-to-run variation.
The demo emits `STATS` JSON on clean shutdown: connection/operation peaks,
refusals, timeouts, flush/resume counts, byte counters, maximum queue/handler/
request-cycle durations, loop processing time, pipeline bytes copied,
`framework_heap_peak_bytes`, `framework_heap_limit_bytes` and late framework
allocation attempts. It does not yet provide latency histograms,
per-reason rejection metrics or a live metrics endpoint.

Zero-copy here describes borrowed parsing and worker/transport payload handoff.
Gather sends submit buffered framing and payload spans together using stable
startup metadata; the body remains borrowed through terminal completion.
`--gather-send 0` retains the scalar path for controlled comparison.
Ordinary socket I/O still copies across the kernel boundary; this MVP does not
use `SEND_ZC`, zero-copy receive or file `sendfile`. Pipelined suffix compaction
copies the remaining suffix once after a whole batch drains and is counted explicitly.
The Linux adapter uses raw `std.os.linux.IoUring`, not `std.Io.Evented` or
`std.Io.Threaded`; the kernel's own resources are outside the fixed application
worker count.

Reproduce all three finite smoke workloads with `python3 tools/smoke.py`. It
checks the running binary reports ReleaseSafe. For isolated Linux verification
from the Mac, run `tools/verify_linux_ssh.sh omarx1`; use a clean pushed checkout
for publication evidence.

Response batching uses the ordinary handler and writer for every request; there
is no cached plaintext response path. Each finished response keeps separate
header/output/chunk storage until terminal sends release the whole batch. A
batch drains at its configured limit, when the available pipeline ends, on
flush/close, or when the callback budget is exhausted. It never waits for a
batch to fill. `--response-batch-limit 1` gives a controlled unbatched comparison.
At most 80 spans (five per cell) are described by the gather metadata; the
aggregate `--send-chunk` limit still applies. Request input stays immutable
while any response borrows it.

Run `python3 tests/batch_integration.py` for distinct generated and borrowed
bodies, mixed routes, small send caps, flush/order barriers, fairness and
cancellation; `tests/gather_integration.py` tests transport operations separately.
The server counts completed requests and cycle maxima when their containing
batch fully drains. A successfully sent prefix of a later canceled batch may
therefore be omitted; these are conservative batch completion observations,
not exact per-request latency measurements.

The Linux wrk harness accepts pipeline depths 1,16,32,64,128; its default remains
1/16 for the original TechEmpower comparison. Deeper client pipelines do not
raise the server's configured response-cell limit. Preflight validates two
complete pipelines at each measured depth (at least16), followed by timed wrk
framing/status/error checks. The independent batch wire suite checks distinct
bodies and ordering through repeated bounded drains.

Comparison receipts record the power profile, CPU driver/governor/EPP, frequency
bounds, instantaneous endpoint frequency and Intel pstate limits before and after
each timed trial. An optional `expected_power_profile` configuration field rejects
an absent or changed endpoint profile. Those snapshots are outside the timed
region; they do not measure average frequency, residency, or continuous policy.

For two-binary experiments, `tools/compare.py --order abba` runs adjacent
A/B/B/A trials at identical connections and pipeline depth; the configuration's
first server is A. It shuffles whole blocks only. `--repeats 2` means two blocks
and therefore four samples per server/workload. Receipts identify each block,
position and sample count. This reduces linear time-order bias; it does not
isolate the host or remove thermal/client variation. The default shuffled
ordering retains its original one-sample-per-repeat behavior. Use host-local
`/tmp/zig-http-measurement.lock` reservations for preparation and timed runs,
and finish all builds before measuring.

The direct-operation-cell experiment makes Linux established recv/send admission
and CQE dispatch use addressed cells. First fd binding and connection close still
perform bounded scans. Structured tokens and retained fd/generation bindings
preserve ownership checks; both target and cancellation terminal events must
drain before reuse or close. Mac honors the same token contract but keeps its
pooled scans. This changes the low-level transport token contract; see
[INTERFACES.md](docs/INTERFACES.md). No measured throughput gain is claimed until
the paired comparison report is complete.
