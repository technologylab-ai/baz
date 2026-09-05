# Ownership and progress in the MVP

This describes the current [server](../src/server.zig),
[application API](../src/api.zig), [parser](../src/http.zig) and
[transport selection](../src/transport.zig), using exact Zig 0.16.0. It is an
experimental execution contract, informed by the [evidence inputs](EVIDENCE.md).
The [module contracts](INTERFACES.md) describe the low-level interfaces.

Every connection has one startup-reserved slot: receive storage, parser state,
request view, one output arena and a bounded array of response descriptors, eight application state
words, deadline and operation identity. The I/O owner is the thread calling
`Server.run`. Inline mode uses this same thread with zero workers. In explicit worker mode a slot is assigned to worker `slot_index % workers`.
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
by the current request. `content_type` has the same lifetime rule. Small borrowed payloads may be copied into the bounded arena as described
below; callers must still honor this uniform lifetime contract. A callback's stack locals are invalid after return;
external pool buffers cannot be reused merely because a callback returned.
There is no application release notification after finish or cancellation, so
those dynamic borrows are not supported even if a successful flush could have
reported their release.

`return writer.flush()` freezes **all currently committed payload bytes**.
The writer and I/O owner finish framing in the reserved arena, send partial
prefixes until that snapshot is exhausted, reset the writer and dispatch
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

Each connection invokes one callback at a time, preserving response order.
Inline mode may retain up to its configured response batch limit (default 128,
range 1–511) while parsing successive already-buffered requests. Each cell
identifies a frozen arena range and optional borrowed span;
all borrowed input stays immutable. The input cursor advances without moving
bytes. After the entire batch drains, the I/O owner compacts any pipelined
suffix once, then resets the parser. This is a measured payload copy
(`pipeline_copy_bytes`), performed only after every prior send borrow ends. Kernel/userspace socket copies also remain; worker
handoff itself publishes descriptors and state rather than copying payloads.

Configured limits are enforced independently: decoded body size, total wire
bytes, header/trailer bytes and count, target bytes, output capacity, cumulative
response bytes, admitted slots, workers and operation records. A maximum body
size does not imply arbitrary chunk framing fits the wire/header budgets.
The current request deadline is absolute, begins at connection admission or the
previous batch's completion when entering a fresh idle cycle. Already buffered requests retain their earlier cycle start; trickled bytes and flushes do not extend it. An accumulating batch retains its oldest unsent deadline.
It includes waiting for the next header, application queue/execution and output.
A bounded 10 ms idle poll interval backs up wake signals; it is not a scheduler
or real-time latency guarantee.

At admission exhaustion, an accepted overflow descriptor is closed without
allocating a slot. Kernel backlog membership is separate from admitted work.
Each slot has independent receive/send operations and one reserved cancellation
cell for each. Tokens
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

Startup computes exact requested framework heap bytes, including the cluster
coordinator, shard arrays, per-shard slot/arena/cell/gather storage, and separately
reserves startup stacks. `Cluster.stackBytes(config)` includes each worker and
each secondary shard; shard 0 uses the caller's existing stack. The demo sets
`Budget.limit_bytes` to `memory_budget_bytes - Cluster.stackBytes(config)`;
`live_bytes` and `peak_bytes` count requested bytes through this allocator, and
allocation/resize/remap growth is refused before exceeding the cap. The requested
stack sizes are reserved separately in that calculation. Pthread/libc resources,
allocator metadata, actual stack mappings, kernel ring/socket storage, application
buffers and startup asset loading remain outside the heap metric. In particular,
Zig 0.16's pthread implementation uses its C allocator for thread bookkeeping
instead of the supplied spawn allocator. These counters do not measure whole
process RSS.

The demo seals the framework allocator after all workers and shard threads
have prepared, before `Cluster.run` releases request I/O; later
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

## Default inline execution and explicit workers

`Config.execution = .inline_event_loop` is the default and requires `workers = 0`. No application
worker threads, worker pipes or worker-stack budget are provisioned. The same
handler receives exclusive request/writer borrows on the I/O owner; it returns
the same frozen flush/finish/close action. Slots with a published callback or
result wait in a FIFO ready ring; one turn services the ring entries present at
its start, at most the effective batch limit per connection and at most
`callbacks_per_turn` per shard (default connections × batch limit, capped at
8192, reported in STATS). Local pending work uses a nonblocking backend poll.
Neither this count nor deadline checks can preempt a callback.

The turn clock is sampled at turn start, after polling and after every 16
callbacks; deadlines, request starts and completion stamps use it, so callback groups add at most 16 completed callbacks' work to the
clock-sampling delay. Polling, OS scheduling and a violating callback can add
unbounded wall-clock delay. Slots the loop touches are
checked against their deadline; every slot is swept every `deadline_sweep_ms`
(default 100), so under progressing callbacks the sweep adds up to one interval plus a turn
of scheduling delay. This is not a wall-clock bound under arbitrary application
code or OS scheduling. Exact per-callback queue/handler timing needs
`callback_timing`, which costs two clock reads per callback; otherwise those
maxima stay zero. Worker mode keeps a full slot scan per turn for results.

Each connection has separate receive and send operation cells, each with its
own cancel cell. With `prearm_receive`, a drain first arms the next receive
into the free input tail, compacting the consumed prefix beforehand when no
frozen cell borrows request input, and then submits the send; with
`submit_batch` the transport submits after that many drains so responses leave
before the turn ends. Both are off by default: the preliminary interleaved experiment on omarx1 found no gain at depths
1, 16 or 128; its sequential Mac samples reported 6–16% lower throughput
with early receive. Those observations do not establish a kernel-wide cause. Bytes that arrive
while that batch is still being sent, or while a flushed request waits to
resume, are held and parsed after the batch completes. Closing cancels both
operations and releases the slot only after every target and cancel
completion has returned. `prearmed_receives`, `turns` and `idle_polls` in STATS
show how often the overlap happened and how often the loop had to wait.

The application promises a bounded, nonblocking callback. The framework cannot
preempt it, isolate a crash or enforce wall-clock deadlines during it. Worker
mode still separates finite blocking callbacks from the I/O owner but does not
isolate arbitrary application code. Per-request optional offload remains a future API decision. Inline sharding
is implemented below. The inline test does not run the blocking
/stall fixture; that demo endpoint explicitly returns501 in this mode.

## Output arena, cells and gathered sends

Each connection owns one contiguous output arena, `output_bytes` long (default
64 KiB). `begin()` writes the response head into the arena immediately, from a
per-owner status/Server/Date prefix refreshed once per second, so the head,
generated body bytes, chunk framing and any copied small borrow of one response
are adjacent, and consecutive responses of one batch form one span. A cell
records a response snapshot as an arena range plus an optional borrowed span
and its insertion offset. The arena prefix up to the last frozen cell and every
borrowed span stay frozen until the batch's terminal send completion, canceled
or not; request input stays immutable while any cell borrows it. The whole
arena and all cells are released together when the batch completes.

`borrow()` copies spans of at most `borrow_copy_threshold` bytes (default 256,
0 disables) into the arena when they fit and counts each copy in
`borrow_copies`; longer spans remain borrowed and become their own vector.
This is the one deliberate copy in the borrowed path: it keeps small responses
in one span and one SEND instead of two vectors. Chunked snapshots reserve a
fixed ten-digit chunk-size field before the data and fill it when frozen.

A drain describes the batch as at most `2 × response_batch_limit + 1` vectors in
per-connection startup storage: adjacent arena runs merge, each borrow is
inserted where its cell recorded it. A one-vector selection uses SEND, several
use SENDMSG; both count as gather-mode operations. The transport references the
caller's vectors without copying them and keeps that reference until the
terminal completion. A positive completion can cross several vectors; the
cursor advances by the aggregate count, capped by send_chunk and i32. A
cancellation acknowledgement alone still cannot release target storage. The
scalar switch exists for controlled comparison with the same ownership rules.

## Bounded response batches and flush barriers

The configured response-cell limit is 1–511, default 128; worker mode's
effective limit is always 1. The scheduler dispatches the next buffered request
into the same batch only while the arena keeps `header_reserve_bytes` free, so
`begin()` never lacks head space. A reservation larger than the remaining arena
returns WouldBlock; the handler flushes and retries in an emptied arena, and
`Writer.capacity()` names the body size that always fits after a flush.

Drain when the next request needs input, the cell/global callback limit is
reached, the arena is nearly full, or a handler flushes/closes. Never delay
output waiting to fill a batch. A flush drains preceding finished responses and
the current snapshot, releases the arena and cells, then resumes the same active
request/state at the arena start with the head already sent. Later malformed
input or an Expect handshake waits behind prior output in wire order.

Completed-request counts and request-cycle maxima are recorded at whole-batch
drain. A sent prefix of a subsequently canceled batch may be omitted. These
metrics intentionally do not claim individual response completion timestamps.
The batch integration suite checks distinct generated/borrowed bodies at client
depths up to 128, barriers, fairness and pending cancellation; these fixtures
are finite witnesses, not starvation or production latency guarantees.

A handler's explicit `.close`, invalid response or expiration aborts its
connection and may discard earlier finished-but-unsent cells in that batch.
This differs from a parser rejection or Connection: close response, which drains
its valid prefix in wire order. No completed-send guarantee follows from the
handler merely returning finish. The cancellation test separately witnesses
multiple frozen cells at a pending gather cancel; a large incomplete request
alone can drain its prefix first and is insufficient evidence for that case.

## Shards: several I/O owners

`Config.shards` runs that many complete, independent servers on one port, each
with its own listener (`SO_REUSEPORT`), transport, slots, arenas, operation
cells, clock and counters. They share admission, stop/start coordination, the startup allocator and the
application pointer; shard 0 runs on the
calling thread and the others on threads created at start with fixed stacks.
Every shard reserves the full `connections` slot capacity, because the kernel's
hash can place more than an even share on one listener; the process-wide
ceiling is enforced by one shared admission counter touched on accept and
release, so `connections` stays the exact limit and `peak_connections` reports
the shared peak. Zero selects one shard per CPU the process may run on (Linux,
at most 16 because each shard reserves full storage) and one elsewhere. Optional `shard_affinity` pins shard i to the i-th allowed CPU.
Only inline execution supports several shards. Linux reuse-port distributes connections across listeners in the tested
configuration. The preliminary M3 Max fixture observed all connections at the
last-bound listener; macOS currently rejects more than one shard. This fixture
is not a universal claim about every XNU version or socket configuration. Merged STATS sum counters
and take maxima; per-shard admission is printed separately. A shard that cannot
reconcile ownership by the shutdown deadline still ends the whole process.


`Cluster.start()` prepares every owner behind a gate; no accepts or callbacks
run before `Cluster.run()` releases it. A partial spawn failure aborts and joins
prepared owners, then drains started-but-unrun servers. Coordinator/array bytes
are included in the exact startup budget. Failure of a secondary shard requests
stop across the cluster, including when duration is unlimited. Exit acknowledgements
precede joins and have a finite watchdog; unreconciled owners cause process exit
70. The framework cannot preempt an inline callback on the calling thread; an
external watchdog remains necessary for an application that violates that contract.

Multiple inline shards can call the same application's handler concurrently on
different connections. The application must synchronize mutable shared state;
request/writer ownership is exclusive per slot, not process-wide. In worker mode,
dispatch snapshots the owner's Date/header prefix into slot-exclusive storage
before release publication, so a worker never races the owner's cache refresh.

A received write-half EOF ends input, not pending responses. Complete buffered
requests and output drain in order; an incomplete suffix receives 400 after the
valid prefix. A prearmed body arriving before an interim 100 SEND completion
waits for that send, then parsing resumes from the bytes already buffered.
Deterministic Zig tests force both completion orders; the finite
`tests/arena_lifecycle_integration.py` suite also exercises these wire paths.
