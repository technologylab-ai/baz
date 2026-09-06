# Baz ownership contract

Baz uses the [bounded/http engine](https://github.com/technologylab-ai/bounded-http).
The engine's [ownership contract](https://github.com/technologylab-ai/bounded-http/blob/main/docs/OWNERSHIP.md)
and [documentation website](https://technologylab-ai.github.io/bounded-http/) define network and scheduler ownership.
This document adds Baz's application boundary.

## Startup and App lifetime

`App.init` allocates a stable App owner and bounded registration storage.
App accounting includes that owner, routes, copied names, engine heap, and requested startup stacks.
Shared state and endpoint instances remain application-owned.
Keep their addresses stable through App destruction.

Register routes before `App.start`.
Startup prepares engine threads and buffers behind the request-processing barrier.
Baz seals its allocator before `App.run` releases that barrier.
The framework performs no heap growth or thread creation on the request I/O loop.

A successful run reconciles engine owners before destruction.
A failed run can retain application or kernel borrows.
Keep the entire App alive or terminate the process; do not free its storage on that path.

`requestStop` requests normal shutdown while the App remains alive.
`requestStopFromSignal` delegates to the engine's atomic-only helper.
Signal handlers must not log, allocate, or call ordinary shutdown methods.
Neither method promises delivery of the stopping request's response.

## Request access

Context and request access last only for the active callback.
Targets, captures, headers, query fields, and contiguous form fields borrow input bytes.
Multipart parts borrow the original body or an explicit caller copy.
Decoding writes into caller-provided storage.

Do not retain those values in background tasks or mutable shared state.
An explicit response borrow can keep engine storage alive after callback return.
That retention does not grant later application access.

## Unpublished responses

The engine reserves the configured draft capacity before initial callback dispatch.
Older output drains first when the reservation cannot fit.
The engine preserves the request and does not replay the handler.

Response uses `draftStorage`, `discardDraft`, and `writeDraftBody`.
Those checked methods expose only the current unpublished response.
Baz does not call internal writer lifecycle methods.

Headers and ordinary body helpers copy caller data during the call.
A failed handler discards its unpublished draft before error mapping.
Earlier frozen responses remain unchanged.
The engine counts staged body copies in `response_draft_copy_bytes`.

`borrowBody` accepts request-owned input or immutable server-lifetime assets.
Callback stack buffers, mutable shared buffers, and external recycled pools cannot escape through that method.
The engine retains eligible borrowed output until terminal completion.
Peer delivery is not implied by callback return or local socket acceptance.

## Execution and resources

Inline handlers must remain bounded and nonblocking.
Shared state must be immutable or synchronized across concurrent callbacks.
Explicit fixed workers permit finite blocking application services.
HTTP cancellation is cooperative and does not automatically cancel the caller's `std.Io` operation.

The sealed allocator counts framework requests through that allocator.
It does not intercept application allocators or the caller's I/O provider.
Kernel buffers, allocator metadata, and actual thread mappings remain outside that ledger.
These limits do not establish arbitrary application isolation.

The [API guide](APP-API.md), [roadmap](APP-API-ROADMAP.md), and dated receipts record supported behavior and remaining gates.
