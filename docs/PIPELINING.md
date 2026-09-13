# Pipelining and browser asset downloads

Baz supports HTTP/1.1 pipelining. Its current engine processes application
requests serially within each connection and can batch completed responses.
That supports ordered pipelines, but it leaves later requests waiting behind
a slow handler or an unfinished stream on the same connection.

This is a source and existing-evidence assessment dated 2026-09-13, against the
[engine source](https://github.com/technologylab-ai/bounded-http/blob/886b728bec79c36ca1ec69345b609a725617a9ea/src/server.zig)
named in [Baz's dependency manifest](../build.zig.zon). It introduces no runtime
change or new performance measurement. Start with [limits and backpressure](LIMITS.md)
for the individual resource bounds.

## Three ways to fetch four images

Once a browser discovers image URLs in HTML, the negotiated protocol and its
connection pool determine how the downloads share the network.

| Connection pattern | How requests and responses progress | Current Baz support |
| --- | --- | --- |
| Several HTTP/1.1 connections | Each connection carries its own ordered responses. Network transfers on different connections can progress concurrently. | Yes, within connection and execution limits. |
| One HTTP/1.1 pipeline | The client sends several requests without waiting for each response. Responses must arrive in request order. | Yes; one active application request per connection, with optional batching of finished responses. |
| HTTP/2 or HTTP/3 multiplexing | Independent streams share a connection, allowing bytes from different responses to be interleaved. | No native support in the current engine. |

Chromium's [pipelining status](https://www.chromium.org/developers/design-documents/network-stack/http-pipelining/#status)
documents removal of its pipelining option. For ordinary browser HTTP/1.1 asset
loading, plan around multiple reusable connections rather than a pipelined
connection. The browser's scheduling, cache, and connection policy determine
the actual number; four images do not imply four new connections in every load.

HTTP/1.1 permits parallel processing of safe pipelined requests, but still requires
responses in request order. HTTP/2 introduces independently scheduled streams;
HTTP/3 maps request/response exchanges to QUIC streams. These are protocol
capabilities, not effects of increasing a server's request limit.
See [RFC 9112 §9.3.2](https://www.rfc-editor.org/rfc/rfc9112.html#section-9.3.2),
[RFC 9113 §5](https://www.rfc-editor.org/rfc/rfc9113.html#section-5), and
[RFC 9114 §4](https://www.rfc-editor.org/rfc/rfc9114.html#section-4).

## What the current scheduler does

In inline execution, the engine can finish handler A, finish handler B, and
transmit both completed responses in one ordered batch. It need not finish
transmitting A before invoking B. Before every initial Baz handler call, enough
arena space must be free for the configured response draft. Older output drains
first if that reservation cannot fit. Output pressure does not replay handler
side effects.

`server.response_batch_limit` limits retained finished responses. It is not the
number of requests a client may pipeline. A pipeline longer than one batch is
processed through successive bounded drains. The output arena and Baz's draft
reservation can force a drain before the configured response count is reached.

Worker execution currently fixes the effective batch size at one. Each response
drains before the next request on that connection is dispatched. Worker mode
also assigns each connection slot to a fixed worker by slot index modulo worker
count, without work stealing. A blocked callback can delay other connections
assigned to that worker.

A flush or continuation wait keeps the current request active. A continuation
releases the executor so other connections can progress, but does not let a
later request on the same connection overtake it. Earlier completed responses
can drain before the continuation waits. The engine's
[execution guide](https://technologylab-ai.github.io/bounded-http/docs/read.html?file=docs/ARCHITECTURE.md#topology-and-execution)
and Baz's [continuation guide](CONTINUATIONS.md) describe these ownership boundaries.

## Where this can limit performance

For short, nonblocking handlers, serial inline execution can prepare a batch
with little scheduling overhead. The implementation and correctness coverage
support this path; they do not establish browser page-load latency.

For expensive handlers, serial preparation on one connection prevents overlap
of independent application work. For a large response or slow reader, later
responses on that connection wait behind earlier bytes. For a long-lived stream,
later requests on that connection remain behind the active request. Parallel
preparation could address some application wait, but HTTP/1.1 response ordering
would still prevent a later image from overtaking an earlier unfinished response.

The browser HTML-plus-four-images example therefore does not by itself identify
a missing concurrency setting. Across several connections, the more relevant
questions are available connection slots, handler cost, worker occupancy, output
sizes, and whether a long-lived stream shares workers with short requests.

If the requirement is interleaved responses on one browser connection, evaluate
HTTP/2 or HTTP/3 at the front end. A reverse proxy could terminate that protocol
and use a pool of HTTP/1.1 connections to Baz; its upstream pool and queue bounds
would need their own review. That deployment has not been qualified here.

## Evidence and its limits

Existing maintained wire checks cover:

- [App integration](../tests/app_integration.py): 128 side-effecting POST requests
  followed by a GET on one connection, each mutation occurring once across
  small-arena drains, with batching still enabled.
- [Streaming integration](../tests/streaming_integration.py): several pipelined
  streaming responses, ordered bodies, retained request input, and a trailing ping.
- [Continuation integration](../tests/continuations_integration.py): a ping,
  waiting continuation, and another ping retain their response order.
- [Borrowed-body integration](../tests/borrow_integration.py): a stopped reader
  holds a pipelined marker behind a large asset; cancellation does not dispatch
  that marker.
- [Engine batch checks](https://github.com/technologylab-ai/bounded-http/blob/886b728bec79c36ca1ec69345b609a725617a9ea/tests/batch_integration.py):
  client pipeline depths 32, 64, and 128 with batch capacity 16, ordered responses,
  connection reuse, and bounded cleanup.

The [composition](../reports/2026-09-07-composition.md) and
[notification receipts](../reports/2026-09-07-notifications.md) record prior native
Linux, macOS, and Windows gates and exact revisions. The source review above
does not rerun those gates or extend them to browser page-load performance.

## Current decision

The 2026-09-13 decision is to keep serial request processing per connection for
Baz's current HTTP/1.1 scope. HTTP/1.1 permits parallel preparation of safe
requests, but requires ordered responses; serial processing is a valid design
choice, not a protocol requirement. No new per-connection concurrency setting
or HTTP/2 implementation is planned as part of this documentation change.

Keep the existing settings. Raising the connection ceiling permits more
connections. Raising inline batch capacity retains more finished responses and
increases reserved metadata; it does not create parallel handlers. More workers
allow more callbacks across connections but do not change ordering within one.

If page-load performance needs investigation later, a useful gate would use one
HTML page and four known assets, with
fast handlers, a delayed first response, and a slow reader as separate cases.
Compare the browser's actual HTTP/1.1 connection pattern with a synthetic
single-connection pipeline, in inline and worker execution. Record protocol,
connection IDs, settings, page completion, per-response latency, CPU, and memory.
Use ReleaseSafe for every performance run and warmup, acquire the cooperative
host reservation, and preserve raw results with the exact platform and revision.

If those measurements identify serial application preparation as the bottleneck,
an upstream design for parallel preparation would need bounds on active requests
per connection, retained input, independent response reservations, and completed
responses waiting for their turn. It would also need rules for safe methods,
side-effect ordering, deadlines, cancellation, and cleanup. That is an engine
scheduler and ownership change, not a new Baz option alone.
