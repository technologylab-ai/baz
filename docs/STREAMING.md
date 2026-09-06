# Streaming responses

Baz can send response bytes while a handler remains active. Write through a
standard `std.Io.Writer`, flush, do finite work or sleep, then write again.
The [runnable example](../examples/streaming.zig) sends three updates:

```sh
zig build run-streaming -Doptimize=ReleaseSafe -- --port 8080
curl -N http://127.0.0.1:8080/
```

Run curl in another terminal; use `curl.exe` on Windows. The first line arrives
before the handler produces the next one.

## Writer and lifecycle

Call `ctx.response.stream(status, content_type, options)` to obtain a `baz.Stream`.
Its `writer()` returns `*std.Io.Writer`. Standard `writeAll`, `print`, and `flush`
work; `Stream` also provides convenience `writeAll`, `print`, and `flush` methods.

Every write copies input bytes before returning. Stack buffers are valid sources.
Writes use the connection's startup-reserved staging buffer. Payload bytes then
move once more into the final snapshot layout. See [the copy and borrowing
contract](OWNERSHIP.md#response-copies-and-borrowing), including `borrowBody`
for large preexisting assets with a suitable lifetime. Filling that buffer
automatically flushes it before accepting more data. Explicit `flush()` sends a
partial buffer and waits for local transmission completion. An empty flush sends
pending headers but does not terminate a chunked response.

`stream.finish()` ends application writes. App publishes final HTTP framing when
the handler returns. Returning normally also finishes a healthy open stream.
Keep the handle and its writer inside the original handler. Do not move the
handle while a returned writer pointer is in use, or share it with another task.

Headers added with `ctx.response.header` stay editable until the first flush.
After that flush, response metadata is final. An error can close the connection;
it cannot replace transmitted bytes with a new 500 response. Before publication,
the normal App error mapper can discard the private draft and replace it.

Errors from this response writer remain recorded even if application code
catches `WriteFailed`. Inspect `stream.failure()` for the underlying error.
The convenience methods return that error directly. Propagate errors from custom
formatters and source readers used through the raw writer; those errors can occur
outside the response writer's methods.

## Framing and bounds

The default `.content_length = null` selects HTTP/1.1 chunked framing. Supply a
known length when appropriate. Baz checks cumulative writes against that length
and requires an exact match at finish. HEAD follows the handler but suppresses
payload transmission. Statuses 204, 205, and 304 reject nonempty output.

`response.body_bytes` controls per-stream staging capacity and the copied/generated
one-shot body limit. Borrowed one-shot bodies use `server.max_response_bytes`. `server.max_response_bytes` controls the entire streaming response. A zero
staging allowance permits only empty output. Large writes may publish accepted
prefixes before encountering an error; they are not transactional.

Flushes retain the original request deadline. Repeated writes or sleeps cannot
extend `server.timeout_ms`. A flush completes after the local transport releases
its output borrow; it does not prove peer receipt or application processing.

## Workers, sleep, and cancellation

Select `.server.execution = .workers` and a positive worker count at startup.
Inline execution rejects streaming before publication. The example selects two
fixed workers through its executable support helper.

One active streaming callback occupies one preallocated worker throughout its
writes, flush waits, and sleeps. Other connections assigned to that worker wait.
The HTTP I/O owner continues processing network events. Baz creates no request
thread, output allocation, or custom `std.Io` provider for streaming.

`ctx.sleep(duration)` uses the caller's standard `std.Io`. It checks the
connection's cancellation flag between waits of at most five milliseconds.
The provider controls clock and sleep behavior. Arbitrary application work still
needs its own progress and resource limits.

Disconnects, deadlines, and shutdown can cancel a stream. A disconnected client
may only be recognized by a later send or the request deadline. A canceled flush
retains storage until outstanding kernel operations return. The callback then
unwinds; the slot is reusable only after callback and kernel borrows both end.

The engine operation is provided by [bounded/http](https://technologylab-ai.github.io/bounded-http/)
through [engine PR #3](https://github.com/technologylab-ai/bounded-http/pull/3).
PR #3 is merged. Baz pins its exact tested head revision; the engine remains a separate package.
The existing callback-returning engine API remains available for explicit continuations.

## Native verification

The [streaming receipt](../reports/2026-09-06-streaming.md) records 14 passing
streaming groups on native Linux/io_uring, macOS/kqueue, and Windows x64/IOCP.
The tests gate later writes on the client's receipt of the first chunk, retain
stack and request data across flushes, exercise backpressure and cancellation,
and verify final callback return and zero remaining connection/operation owners.
All timed wire fixtures use ReleaseSafe with assertions enabled. These are
correctness gates; the earlier Zap throughput comparison is unchanged.
