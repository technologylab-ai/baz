# Should the framework provide its own std.Io?

Status: source-based exploration and accepted sequencing decision, 2026-09-06, exact
Zig 0.16.0. No custom std.Io implementation or prototype is added here.
This accompanies the [framework design](APP-API-DESIGN.md) and
[implementation roadmap](APP-API-ROADMAP.md).

User decision: ship the first App/API MVP using caller-supplied standard
`std.Io`, bounded memory Reader/Writer integration, and the existing custom
io_uring/kqueue HTTP engine. Defer our own std.Io implementation and its research
track until after that API work. See the implemented [App guide](APP-API.md).

A bounded, framework-owned `std.Io` provider remains an explicit
research track. It could make ordinary Zig service libraries usable with
cooperative I/O on the framework's owners. First ship the App API using the
existing engine and standard memory readers/writers, and run a small runtime
prototype before making an owned provider a release dependency or a default.
Keep the public API open to either caller-provided or framework-owned I/O.

This is an accepted sequencing decision, not a decision that a custom provider is
unnecessary. If the prototype establishes the benefits and ownership gates,
an opt-in managed execution mode is a useful target for this successor to Zap.

## What zig-http actually uses

| Layer | Current implementation |
| --- | --- |
| Startup asset loading | `std.process.Init.io` is passed to `std.Io.Dir` operations in [main.zig](../src/main.zig). |
| HTTP engine | [server.zig](../src/server.zig) drives its own transport contract and callback phases. |
| Linux transport | [transport_linux.zig](../src/transport_linux.zig) owns a `std.os.linux.IoUring`, submits accept/recv/send/sendmsg/cancel, and reports cell/token completions. |
| macOS transport | [transport_macos.zig](../src/transport_macos.zig) uses nonblocking sockets and kqueue under the same contract. |
| Application execution | Direct inline callbacks or fixed startup workers, with `.request`/`.flushed` events and `.flush`/`.finish`/`.close` actions. |

Using a Zig standard-library io_uring wrapper is different from implementing
`std.Io`. The current engine has neither a `std.Io.VTable` nor a `.io()` provider
for application network/file calls. Its transport is single-owner except for
`wake()`, and its operation-cell budget is specific to HTTP connections.

The source baseline is zig-http
`4b3cd5551d80b422ec6ef763627d019e6f1dfb83`. The installed compiler reported
`0.16.0`; inspection used its `lib/std/Io.zig`, `Io/Uring.zig`,
`Io/Reader.zig`, `Io/Writer.zig`, and the wiki's
[stdlib source record](../../zigllmwiki/sources/zig-0.16.0-stdlib.md).
Existing engine runtime receipts are linked by
[EVIDENCE.md](EVIDENCE.md); they are not evidence for a std.Io provider.

## What an owned provider buys

Application services could accept `io: std.Io` and use standard network, file,
timer and synchronization operations while the runtime suspends a waiting task
and serves other requests. Existing Zig libraries using those interfaces would
need less framework-specific callback glue, subject to the provider's supported
operation set. The same injected interface helps testing and backend selection.

For example, an endpoint could call a service that writes a query to an outbound
socket and reads its result in ordinary sequential Zig code. The HTTP owner
would keep serving unrelated connections while that task waits. Achieving this
behavior would be a material advance beyond today's server-wide worker mode.

It does not automatically improve plaintext throughput, eliminate kernel copies,
preempt CPU-bound callbacks, or make arbitrary libraries allocation-free. Each
claim needs its own scope and evidence.

## Why it is more than a transport adapter

In exact 0.16.0, `std.Io` contains a userdata pointer and a broad `VTable`:
tasks/futures/groups, cancellation, futexes, clocks, sleep, entropy, filesystem,
processes and networking. Its sequential `netRead`/`netWrite` methods return
completed results, not a framework `.pending` action.

Our transport submits an operation and reports completion later. On the inline
HTTP owner, a sequential service call therefore needs a way to suspend its
ordinary Zig call stack and resume it after completion. Candidate mechanisms are
preallocated stackful tasks/fibers or bounded worker execution. A plain vtable
wrapper cannot supply that missing execution model. Spinning on completion,
blocking the owner, or recursively pumping the HTTP loop from `netRead` is not
an acceptable substitute under the current ownership contract.

The task vtable also specifies thread-safe async/concurrent/await/cancel entry
points. `async` may execute immediately; `concurrent` must assign independent
progress or return `ConcurrencyUnavailable`. A bounded implementation has to
handle pool exhaustion and arbitrary context/result sizes and alignments while
honoring those contracts. It cannot silently turn exhausted concurrent work into
an inline blocking call. Even permitted eager `async` fallback has stack and
execution-policy consequences.

Some vtable methods have no unsupported error channel, including time, random,
close and several cancellation/task operations. A partial provider needs an
operation-by-operation compatibility matrix and honest supported errors. Copying
`std.Io.failing`, panicking for ordinary library calls, or returning invented
errors does not produce a generally usable runtime. Forwarding selected methods
to a second provider also requires coherent handle, task, cancellation and
thread ownership; copying another implementation's function pointers with the
wrong userdata is invalid.

## Exact-release alternatives

| Approach | Benefit | Cost / limit | Proposed disposition |
| --- | --- | --- | --- |
| Caller-supplied std.Io plus existing engine | Smallest useful App; caller controls service dependencies; works with current explicit workers. | Sequential blocking service calls still cannot run on inline owners. | Initial API baseline. |
| Standard memory Reader/Writer adapters | Formatting, JSON and retained-body readers compose with Zig libraries now. | They do not provide task scheduling or a std.Io backend; writer overflow and HTTP flush remain separate. | Implement early. |
| Owned bounded worker provider / audited worker fallback | Ordinary call stacks, portable path for operations without asynchronous support. | Worker affinity/queue limits, cancellation and task records still need design; Threaded defaults do not establish startup-only allocation or a fixed thread count. | Candidate fallback for the runtime prototype, not an inline shortcut. |
| Owned bounded cooperative provider using native drivers | Sequential service APIs can yield without occupying an OS worker; potential reuse of transport expertise. | Task stacks, scheduler, timers, thread-safe submission, operation pools, cancellation and library coverage are a new runtime project. | Prototype as opt-in managed execution. |
| Adopt/fork std.Io.Evented from Zig 0.16 | Existing stack-switching/task machinery to study. | The exact release is incomplete and does not meet our bounded contract by inspection. Requires an explicit gap audit, not a configuration switch. | Reference/comparison candidate, not the default. |

The exact installed `Io.zig` selects `Io.Uring` for Linux Evented, Dispatch for
macOS, and Kqueue for the listed BSDs when fiber support is present. That differs
from zig-http's macOS kqueue transport. In installed `Io/Uring.zig`, `.io()`
maps netAccept/netRead/netWrite to functions returning `NetworkDown`, task
creation can allocate, and `Fiber.min_stack_size` is 60 MiB. Selected batch paths
still contain TODO panics. These source facts are enough to reject an untested
drop-in adoption; they are not a benchmark or a judgment about later Zig releases.
See the wiki's [evented landscape](../../zigllmwiki/wiki/evented-io-backends.md)
and [async/concurrent contract](../../zigllmwiki/wiki/async-vs-concurrent.md).

## Proposed owned-runtime boundary

Keep the HTTP codec and response API independent of who supplies service I/O.
A future managed execution mode can own a bounded std.Io provider whose lifetime
is tied to App, while startup may still use caller-supplied `init.io`. Label both
owners explicitly. Do not let future/task handles escape or move between I/O
providers without an established interoperability contract.

Reuse driver mechanics only below clear ownership boundaries. Today's
`4 * connections + 2` transport cells are already assigned to HTTP operations;
they are not spare capacity for database clients, files, timers or nested tasks.
Provision separate service-operation and cancellation budgets. One owner drains
each ring/queue and demultiplexes completions. Never let the existing HTTP loop
and a new std.Io provider race to consume the same CQ.

Start the prototype on one owner and one platform in isolation. Before combining
it with HTTP, decide whether it shares an extracted driver and event pump or
uses a separate owned runtime reached through a bounded bridge. Sharing one
reactor may ultimately be attractive, but must not be assumed to follow from
both implementations using io_uring.

A useful managed task design needs startup bounds for task count, stack bytes,
context/result bytes and alignments, nested work, pending operations, timers,
waiters, cross-owner messages and cancellation completion reserve. Include them
in the resource ledger and define exhaustion before retaining new borrows.

Map request timeout/disconnect/stop into cooperative service cancellation, then
join/drain every child task and terminal kernel operation before reusing request
storage. Extend the server's execution phases for suspended service calls; its
existing `.flush` action describes HTTP output and cannot stand in for waiting
on a database. Preserve one active application owner per request. Shared services
must obey shard/thread ownership too.

Regular-file operations, DNS, process operations and entropy need separate
coverage decisions. In particular, do not infer asynchronous regular-file
semantics from macOS socket readiness. Any worker fallback must be prestarted,
bounded and observable. An unsupported operation must never silently block an
HTTP owner. A capability profile is useful documentation, but ordinary std.Io
types do not statically prevent callers from reaching other vtable methods.

## Research sequence and decision gates

The entire IO-01–04 sequence below is deferred until after the first API MVP,
by the user's 2026-09-06 decision. The queued dependencies describe that later
sequence; none is active work in this implementation session.

| Item | State | Deliverable and acceptance gate |
| --- | --- | --- |
| IO-00: source comparison | complete (inspection only) | This document distinguishes current drivers from std.Io, enumerates options, and identifies the missing execution/cancellation machinery. |
| IO-01: compatibility and resource design | queued | Select one real service/library use case; enumerate every vtable entry it can reach, including error/cleanup paths. Specify task and operation bounds, exhaustion behavior, execution ownership, and caller/owned-I/O API shapes. Produce a go/no-go prototype plan. |
| IO-02a: bounded suspension/task prototype | queued; after IO-01 | Compile every fixture via `zig build verify`. With synthetic completions, prove two tasks progress independently, stack locals survive suspension, resume occurs once, task/context/result/alignment limits and nested work have correct exhaustion behavior, cancellation/cleanup reconciles owners, and no post-start backing allocation/thread growth occurs. Gate: `STDIO-SUSPEND`. |
| IO-02b: native TCP/timer prototype | queued; after IO-02a | Demonstrate standard TCP connect/write/read plus a timer on one owner, EOF/short I/O, operation-pool exhaustion, cancellation-before-submit and raced target/cancel completions, with all task/operation/storage budgets accounted. Gate: `STDIO-NETWORK`; both subgates establish `STDIO-PROTOTYPE`. |
| IO-03: HTTP integration experiment | queued; after IO-02 and APP-RESUME | A waiting outbound-service request coexists with fast HTTP requests; disconnect/deadline/stop drains all tasks and I/O before reuse. Preserve response batching and no endpoint replay. Gate: `STDIO-HTTP-OWNERSHIP`. |
| IO-04: native compatibility and adoption | queued; after IO-03 | Implement/qualify the selected macOS counterpart/fallback, library coverage, multi-shard ownership and controlled mixed-workload comparisons. Decide whether to ship an optional provider, make managed execution default, or retain caller I/O + workers. Gate: `STDIO-ADOPTION`. |

IO-02 may compare a small owned scheduler against a bounded worker baseline and
the exact-release Evented gaps; it need not implement the entire process/file
API first. Its supported profile must remain explicit. No incomplete prototype
is exported as general-purpose std.Io compatibility.

Measure both the benefit (unrelated requests progress during service waits) and
the cost (stacks, operation state, shutdown work, CPU/latency and retained input).
Preserve the current engine as the reference until integration gates pass. Use
the host measurement-lock protocol before any builds/runtime/load, exact
Debug/ReleaseSafe, and native Linux/macOS receipts. Cross-compilation does not
establish runtime evidence; Windows HTTP remains deferred.

The first public API design should make room for this direction without
pretending that `std.Io` support alone supplies a bounded cooperative runtime.
