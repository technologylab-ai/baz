# Server-sent events and application notifications

Baz encodes SSE directly into the existing `std.Io.Writer` response interfaces.
Use a worker `Stream` for a linear handler, or a continuation `Snapshot` when
many waiting clients should share a small worker pool. No event string allocation
or automatic flush is hidden in the encoder.

```zig
var output = try ctx.response.snapshot(200, web.sse.content_type, .{});
try web.sse.write(output.writer(), .{
    .event = "progress",
    .id = "7",
    .data = "Completed step 7 of 10",
    .retry_ms = 1000,
});
return .flush;
```

This is the start of a continuation handler. Register it with
`routeContinuation`, set `max_continuations`, and use `resumeSnapshot()` on
subsequent callbacks. With a worker stream, explicitly `flushAndWait()` after
writing instead. Ordinary writer `flush()` does not publish a continuation.
See [typed continuations](CONTINUATIONS.md) and [worker streaming](STREAMING.md).

## Encoding is explicit

`web.sse.write(writer, Event)` validates UTF-8 and every metadata field before
writing. `data` may contain multiple lines: CRLF, CR and LF become properly
prefixed data lines. Empty data dispatches an empty event; a trailing newline
is preserved. Event names reject CR/LF; IDs reject CR/LF/NUL. These are ordinary
errors. Writer-capacity failures may leave partial output, so terminate the
failed response instead of continuing with another event.

An omitted `event` selects the default browser `message` event. An omitted `id`
preserves the browser's previous ID; an empty ID resets it. `retry_ms` is an
explicit unsigned millisecond reconnect hint, including zero. Neither an ID nor
a retry hint creates a replay queue. `comment(writer, text)` safely prefixes
every comment line; `heartbeat(writer)` writes `:\n\n` without an application
event. The application chooses when to send and flush heartbeats.

These helpers implement the [WHATWG event stream format](https://html.spec.whatwg.org/multipage/server-sent-events.html).
They do not serialize objects, coerce request parameters, add HTTP headers,
or choose authentication, persistence or reconnect policy.

## Wake a waiting continuation

During a retained callback, obtain `try ctx.notification()` and copy the handle
into startup-owned producer/subscription storage. Enqueue or publish the data
**before** calling `handle.signal()`. Return
`.{ .await_notification = null }` to wait for producer activity, or
`.{ .await_notification = 5 * std.time.ns_per_s }` for a heartbeat timeout.
A signal resumes with `.notified`; timeout resumes with `.timer`.

The handle represents a coalescing wake-up, not a message count. `signal()`
returns `notified`, `coalesced`, or `stale`. Repeated signals occupy one pending
bit per engine connection. A signal arriving before the wait, during a callback
or while output is flushing remains pending. It is consumed by notification
waits; timer-only `.wait` keeps its existing behavior. Read the application's
queue/state after waking and do not infer one message per callback. Notifications
schedule callbacks; they do not synchronize arbitrary shared payload bytes.
Use the mailbox or explicit application synchronization for those bytes.

Generation checks prevent an old request's handle from waking a reused slot.
A stale handle is callable only while its engine storage remains alive:
**stop and join every producer before `App.deinit()`**. Handles own no request
bytes and do not extend App lifetime. Never pass Context or response-writer
pointers to producers. Cancellation, fixed request deadlines and output-borrow
reconciliation retain the same [continuation ownership contract](CONTINUATIONS.md).

The engine checks pending signals at its existing owner polling cadence, up to
10 ms plus scheduling/load delays. This first version does not promise an
immediate OS wake-up. No custom `std.Io` provider is involved; Baz keeps caller
`std.Io` and the [bounded/http](https://technologylab-ai.github.io/bounded-http/)
io_uring, kqueue and IOCP transports.

## Bounded messages

`web.Mailbox(T, capacity)` embeds a fixed FIFO. `tryPush` reports `Full`, `Busy`
or `Closed`; `tryPop` returns a copied value or null, reports `Busy` on contention,
and reports `Closed` after queued values drain. `tryClose` rejects further
pushes while preserving queued values. Operations never wait for a lock,
allocate, overwrite old messages or silently discard a value.

The application chooses a policy for each outcome: reject new work, retry from
a bounded producer loop, or explicitly drop/coalesce an update. Bound drain
loops too. If a consumer encounters `Busy`, schedule a short timer retry instead
of assuming another signal will arrive. Notify after enqueue/close, and drain
before waiting again; this handles coalescing without losing queued work. If a
bounded drain reaches its budget with work remaining, schedule a timer retry or
signal yourself before waiting; a future producer signal is not guaranteed.
Slice/pointer message fields keep their original lifetime obligations. Store
owned fixed-size values where practical. Stop all users before resetting or
releasing the mailbox. Never copy a live mailbox. Per-client replay and fanout require their own bounds.

## A complete application

The [jobs example](../examples/jobs.zig) combines startup-parsed Mustache pages,
cookie sessions, a startup producer and notification-driven SSE progress. Read
[its application guide](JOBS.md) for the exact job, replay, session and client
policies. It keeps markup and browser code in separate assets.

New notification/SSE/application native qualification is pending on this branch.
The [composition receipt](../reports/2026-09-07-composition.md) qualifies the prior
timer/flush API only; it is not evidence for these additions.
