# Ownership and progress in the MVP

This describes the current [server](../src/server.zig),
[application API](../src/api.zig), [parser](../src/http.zig) and
[transport selection](../src/transport.zig), using exact Zig 0.16.0. It is an
experimental execution contract, informed by the [evidence inputs](EVIDENCE.md).
The [module contracts](INTERFACES.md) describe the low-level interfaces.

Every connection has one startup-reserved slot: receive storage, parser state,
request view, output storage, response framing storage, eight application state
words, deadline and operation identity. The I/O owner is the thread calling
`Server.run`. A slot is assigned to application worker `slot_index % workers`.
There is no unbounded task queue; each slot holds at most one ready/running
callback. The I/O owner and a worker communicate by publishing atomic phases
with release/acquire ordering. Wake signals are hints; the phase is authoritative.

| Phase | Permitted access |
| --- | --- |
| I/O receive/parse | I/O owner appends initialized receive bytes and advances the parser. One transport operation may borrow the destination. |
| Ready/running callback | Assigned worker borrows the immutable request and exclusively mutates its writer/state. The I/O owner can set the atomic cancellation flag and close networking, but cannot recycle the slot. |
| Published callback result | I/O owner acquires the committed writer snapshot and action; the worker stops accessing request/writer/state until another dispatch. |
| Sending | I/O owner advances partial-send cursors. Committed payload storage stays immutable until every send using it completes. |
| Flushed | Writer storage is released/reset and the same handler is dispatched with `.flushed`; the request and continuation state remain borrowed. |
| Finished/closing | No continuation is promised. Slot storage is reused only after the callback has returned and all target/cancel completions have drained. |

The receive buffer stays at a stable address through parsing and all callbacks
for that request. `Request.method`, `target`, `headers`, `header(name)` results,
`body_wire` and each body-iterator span borrow it. Chunked decoding removes no
bytes and builds no second payload buffer. The request is complete before its
first callback; `Expect: 100-continue` is decided by the parser/I/O path after
header validation. Unknown optional header values remain uninterpreted until
application lookup.

The application must not retain `Context` pointers, request/writer/state pointers
or slices after the response ends. It must not mutate the input or hand these
borrows to a background task. A future dynamic lease/task API would need explicit
completion and cancellation ownership; this MVP intentionally has none.
Shared `application` state is the application's synchronization responsibility.

`Writer.begin(status, content_type, length)` starts response metadata once.
A known length selects Content-Length; null selects chunked response framing
except bodyless statuses. `reserve(n)` borrows unused writable output storage;
`commit(n)` commits only initialized bytes and ends the reservation. `write`
performs a payload copy; reserve/commit lets the application generate bytes in
place. One outstanding reservation or one borrowed payload is permitted, and
borrowed and buffered payloads cannot be mixed in one flush snapshot.

`borrow(bytes)` permits only immutable server-lifetime storage or bytes owned
by the current request. `content_type` has the same lifetime rule. Both are
slices rather than copies. A callback's stack locals are invalid after return;
external pool buffers cannot be reused merely because a callback returned.
There is no application release notification after finish or cancellation, so
those dynamic borrows are not supported even if a successful flush could have
reported their release.

`return writer.flush()` freezes **all currently committed payload bytes**.
The I/O owner generates framing in separate reserved buffers, sends partial
prefixes until that snapshot is exhausted, resets the writer and dispatches
`.flushed`. The callback cannot append while the snapshot is frozen. Returning
from `flush()` itself only creates the action; the handler must immediately
return that action to yield execution. A successful resumed event establishes
local transport acceptance, not remote delivery or application processing.
For HEAD, body bytes are suppressed, so this completion does not imply a body
was sent.

`return writer.finish()` sends the last snapshot, verifies any declared
Content-Length, emits the terminating chunk when required, and ends the
response. No `.flushed` callback follows finish. An empty flush sends no zero
chunk; only finish ends a chunked body. A callback can return `.close` to abandon
the connection. Mismatched response lengths, exceeded response budgets or other
handler failures close the connection; the framework does not invent a success
response after partial output.

A callback stores its continuation position in the eight `context.state` words,
which begin at zero for each request and survive flush/resume. The maintained
[demo callback](../src/main.zig) exercises a borrowed body iterator in `/echo`
and direct output reservations in `/chunks`. `WouldBlock` means output capacity
is exhausted, so the callback must flush committed bytes and resume later. It
must split any individual write larger than the total output buffer. Workers
do not wait for clients to drain socket output.

Each connection processes one request at a time, preserving response order.
After finish, the I/O owner may compact an already-received pipelined suffix to
buffer offset zero, then reset the parser. This is a measured payload copy
(`pipeline_copy_bytes`). It happens only after the preceding request's worker
and send borrows have ended. Kernel/userspace socket copies also remain; worker
handoff itself publishes descriptors and state rather than copying payloads.

Configured limits are enforced independently: decoded body size, total wire
bytes, header/trailer bytes and count, target bytes, output capacity, cumulative
response bytes, admitted slots, workers and operation records. A maximum body
size does not imply arbitrary chunk framing fits the wire/header budgets.
The current request deadline is absolute, begins at connection admission or the
previous response's completion, and is not extended by trickled bytes or flushes.
It includes waiting for the next header, application queue/execution and output.
A bounded 10 ms idle poll interval backs up wake signals; it is not a scheduler
or real-time latency guarantee.

At admission exhaustion, an accepted overflow descriptor is closed without
allocating a slot. Kernel backlog membership is separate from admitted work.
Each slot has a single data operation and reserved cancellation capacity. Tokens
combine slot index, generation and operation kind. Generation increments are
checked rather than wrapped silently. A cancellation acknowledgement is distinct
from the target operation's terminal completion; neither alone permits releasing
all owners.

On stop or deadline, the I/O owner marks cancellation, shuts down networking and
cancels outstanding transport work. A callback may inspect
`context.cancelled.load(.acquire)` and return `.close`. Closing the socket does
not terminate a running callback. Its request and output remain allocated until
it returns. Workers have fixed affinity and do not steal work, so one blocking
callback delays other slots on its worker, even when another worker is idle.
No thread is forcibly killed or replaced, and no extra worker is spawned under
load. Arbitrary application code can still allocate, block, corrupt shared
memory or terminate the process.

Shutdown stops new admission, drains accepted work through cancellation, waits
for live connection/operation counts to reach zero, stops workers and joins
them. `deinit` is legal only after a successful `run` or before workers started.
The drain deadline is finite. If `run` fails while ownership is uncertain, the
demo uses process exit 70 instead of unwinding/freeing live storage. An embedding
application must preserve that boundary or deliberately retain the entire
server until all outstanding owners are otherwise proven finished.

Startup checks a conservative pool/stack reservation estimate. The demo then
sets `Budget.limit_bytes` to `memory_budget_bytes - workers * worker_stack_bytes`;
`live_bytes` and `peak_bytes` count requested bytes through this allocator, and
allocation/resize/remap growth is refused before exceeding the cap. The requested
stack sizes are reserved separately in that calculation. Pthread/libc resources,
allocator metadata, actual stack mappings, kernel ring/socket storage, application
buffers and startup asset loading remain outside the heap metric. In particular,
Zig 0.16's pthread implementation uses its C allocator for thread bookkeeping
instead of the supplied spawn allocator. These counters do not measure whole
process RSS.

The demo seals the framework allocator after all workers have started; later
allocation attempts through it are refused and counted. Embedding applications
that want these checks must use the same budget/sealing lifecycle; passing an
arbitrary allocator to `Server.init` does not establish a heap cap. This wrapper
also does not intercept unrelated application allocators. See
[budget.zig](../src/budget.zig) and [README](../README.md) for configuration.

The metrics describe observations, not guaranteed throughput: server queue and
handler maxima, completed request-cycle maxima, processing time and ownership
peaks; the Python smoke client records closed-loop response latencies. The
server's loop-processing metric excludes the backend poll/wait interval. More
complete latency histograms, dynamic borrow release, alternative continuation
styles, worker scheduling and controlled external framework comparisons remain
experiments to perform before making production or capacity claims.
