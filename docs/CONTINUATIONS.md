# Typed continuations

Many waiting responses can share a small worker pool. A typed continuation returns
between snapshots and timers, keeping its bounded State and request locals alive
without retaining a worker stack. It also works on the inline executor.

```zig
const Step = web.continuation.Step;
const Event = web.continuation.Event;
const State = struct { updates: u8 = 0 };

fn start(ctx: *Application.Context, _: *State) !Step {
    var out = try ctx.response.snapshot(200, "text/plain", .{});
    try out.writer().writeAll("Starting\n");
    return .flush;
}

fn advance(ctx: *Application.Context, state: *State, event: Event) !Step {
    if (event == .flushed) return .{ .wait = 500 * std.time.ns_per_ms };
    state.updates += 1;
    var out = try ctx.response.resumeSnapshot();
    try out.writer().print("Update {d}\n", .{state.updates});
    return if (state.updates == 2) .finish else .flush;
}

// App.init options include .max_continuations = 32.
try app.routeContinuation("GET", "/stream", State, start, advance, .{});
```

Run [the complete example](../examples/continuations.zig):

```sh
zig build run-continuations -Doptimize=ReleaseSafe -- --port 8080 --execution workers --workers 1
curl -N http://localhost:8080/stream
```

## Explicit steps

| Step | Result |
| --- | --- |
| `.flush` | Publish the staged bytes, release the executor, and receive `.flushed` after local output borrows return. An empty flush can publish headers. |
| `.{ .wait = nanoseconds }` | Release the executor without publishing. Receive `.timer` when the delay is due. Pending body bytes must be flushed first. |
| `.finish` | Run reverse after hooks once, publish final staged bytes and framing, clean up, and release the continuation slot. There is no extra success callback. |

A wait can precede the first response, including after adding unpublished headers.
Earlier pipelined responses can drain while this request waits. Waits use the
engine owner's monotonic clock and its existing polling cadence (up to 10 ms),
so they may run late. Zero requests another scheduled callback; it is not recursion.
The original request deadline stays fixed across all flushes and waits.

`Snapshot.writer()` is a standard `std.Io.Writer`; `writeAll`, `print`, and the
handle's convenience methods copy into a fixed staging area. Ordinary writer
`flush()` validates local writer state and **does not send an HTTP snapshot**;
return `.flush` to publish. A full snapshot fails with a sticky `ResponseLimit`.
Split larger output across explicit callbacks. There is no automatic blocking
flush. `failure()` reports the underlying error after `WriteFailed`.

`StreamOptions.content_length` optionally checks an exact cumulative length;
default framing is chunked. `ResponseLimits.body_bytes` bounds each snapshot and
`server.max_response_bytes` bounds the whole response. Headers become immutable
at first publication. Before publication errors use the normal mapper; afterward
they close the connection. Final length and write errors cannot be hidden by
catching a writer error and returning finish.

## Retained state and cleanup

`max_continuations` defaults to zero, so applications opt into storage explicitly.
`max_continuation_state_bytes` defaults to 256 and has a 65,536-byte maximum. Each
registered State must be a struct with field defaults and alignment at most 64.
Registration rejects State exceeding the configured bound. Startup accounting
includes records, typed locals, aligned State storage, and one detached response
draft per slot. Memory-budget failure happens before request handling.

A finite acquisition scan returns 503 if all continuation slots are occupied or
contended. This happens before application middleware runs. Ordinary routes do
not consume these slots. Slots are reusable with generation-checked handles;
generations never wrap. Connection slots and execution queues remain separately
bounded by the HTTP engine.

State defaults and locals are initialized once. Global and route before hooks,
authentication, and start run once; later events call only the selected resume
function. Locals and State retain stable addresses. Optional
`pub fn deinit(self: *State, ctx: *Application.Context) void` runs once on every
terminal path, followed by entered middleware cleanup and locals cleanup. Defaults
must be safe to clean up even if initialization or authentication fails. After
hooks run only on successful terminal processing. Cancellation closes without
calling the resume handler and runs cleanup after outstanding kernel borrows
return, on the selected executor. Cleanup cannot publish, wait, or allocate on an
inline owner. Authentication is a snapshot: revalidation after a wait is an
explicit application policy.

Keep Context pointers, snapshot handles and writer pointers inside the active
callback. State may retain borrowed request slices until its cleanup; the engine
retains that input. **State, Locals, and recyclable response storage cannot back
`borrowBody`.** Baz rejects borrows overlapping its continuation pool, including
from error mappers. Eligible immutable server-lifetime assets or original request
input remain valid whole-body choices when returning finish. A borrowed body
cannot be inserted into a snapshot stream; see [response ownership](OWNERSHIP.md).

This API schedules timers and output completion. It does not spawn background
tasks, provide arbitrary I/O futures, or isolate unbounded application code.
Blocking service calls on workers still occupy those workers. For linear handlers
that deliberately retain a worker through each wait, use [worker streaming](STREAMING.md).
Baz continues to use the caller's standard `std.Io` and the
[bounded/http](https://technologylab-ai.github.io/bounded-http/) engine's
io_uring, kqueue and IOCP backends; an owned `std.Io` provider remains deferred.

## Verification

`zig build verify` checks the exact compiler, pool bounds and generation reuse,
response snapshots, package consumers and runnable examples. The continuation
wire gate covers 32 waiting streams with one worker, inline execution, live control
requests at capacity, framing, pipelines, deadlines, disconnect, shutdown, stable
state and exactly-once cleanup. Native platforms and exact revisions are recorded
in [the composition receipt](../reports/2026-09-07-composition.md).
