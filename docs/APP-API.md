# Application API, first implementation

Baz means **Bounded Async Zap**. It is a modern successor to
[Zap](https://github.com/zigzap/zap), built on the separate
[bounded/http](https://technologylab-ai.github.io/bounded-http/) engine.
The package and public import are `baz`. The engine import is `bounded_http`.
The engine's [GitHub Pages documentation](https://technologylab-ai.github.io/bounded-http/)
covers architecture, embedding, and ownership.
Baz consumes a pinned external engine package; it does not contain engine sources.
See the [dependency boundary](DEPENDENCY.md) and [extraction plan](APP-API-ROADMAP.md#api-08--migration-examples-and-successor-mvp-qualification).
This experimental API uses exact Zig **0.16.0**, the Linux io_uring /
macOS kqueue / Windows IOCP HTTP engine, caller-supplied `std.Io`, and bounded standard memory
readers/writers. An owned `std.Io` provider is deferred until after the API MVP.

Run the maintained, compiled [example](../src/app_demo.zig):

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/baz --port 8080
curl 'http://127.0.0.1:8080/hello?name=Hello%20Zig'
curl 'http://127.0.0.1:8080/users/a%2Fb'
curl --data 'value=x+y%2Bz' http://127.0.0.1:8080/form
curl -F 'files[]=first' -F 'files[]=@.zig-version' http://127.0.0.1:8080/upload
```

On Windows, use `zig-out/bin/baz.exe` and `curl.exe`.

The upload example has an 8 KiB body limit; choose a smaller file if needed.
It returns part metadata, lengths and byte sums, and does not save files.
`zig build run-app -- --port 8080` also runs the example. It binds IPv4
loopback and serves plain HTTP/1.1; inherited deployment limits remain in
[README](../README.md). Public module exports are in [web.zig](../src/web.zig).

## App and endpoint composition

The core shape below is exercised by the maintained example:

```zig
const std = @import("std");
const web = @import("baz");

const Shared = struct { greeting: []const u8 };
const Application = web.App(Shared);

const Hello = struct {
    pub fn get(_: *Hello, ctx: *Application.Context) !void {
        const query = try ctx.request.query();
        if (query.firstRaw("name")) |field| {
            var destination: [1024]u8 = undefined;
            const name = try web.params.percentDecodeInto(field.value_raw, &destination);
            return ctx.response.text(200, name);
        }
        return ctx.response.text(200, ctx.shared.greeting);
    }
};
```

In `main(init: std.process.Init)`, initialize an App with
`.allocator = init.gpa`, `.io = init.io`, `.shared = &shared`, and optional
`.server` / `.response` limits. Register with `try app.endpoint("/hello", &hello)`
or `try app.route("GET", "/path", handler)`. `bind` registers an arbitrary
stateful method. `endpoint` recognizes public `get`, `post`, `put`, `delete`,
`patch`, `head` and `options` methods; failed registration rolls back atomically.

`init` returns a stable, owned App pointer. Registration copies method/path
bytes into startup storage. Shared and endpoint instances are borrowed and must
remain at stable addresses through `deinit`. There is no global per-type App.
Independent instances of the same type can use distinct state, ports and stop
flags. State shared between callbacks must be immutable or synchronized.

Lifecycle is `init → register → start → run → deinit`. `start` prepares the
engine behind its startup gate and seals the framework allocator; `run` begins
admission. Registration is closed after `start`. `requestStop` requests a drain;
the signal-specific helper only sets atomic stop flags. Signal installation
belongs in the executable. A failed `run` may leave application/kernel owners
outstanding: the example terminates with `engine.failFast(70)` and does not free borrowed
storage. The normal `deinit` path waits for clean terminal ownership.

Use `ctx.param("id")` for a raw capture from `/users/:id`. Matching preserves
case, trailing slash, repeated slash and percent spelling; `%2F` remains inside
one segment. Earlier static segments outrank captures, independently of
registration order. The winning path family determines method selection;
there is no fallback to a less-specific route just because its method matches.
Equivalent patterns with the same method are rejected even when capture names
differ. Routes have at most 32 segments and 16 captures.

GET supplies implicit HEAD unless an explicit HEAD handler exists. The engine
suppresses HEAD body bytes while retaining representation length. Implicit
OPTIONS and method failures supply `Allow`; OPTIONS `*` lists App methods.
Unknown paths get 404 and unsupported methods on known paths get 405. An App
can supply `not_found` and `on_error` handlers. Error hooks receive the same typed
context after discarding the unpublished draft; failure in a hook produces a
bounded generic 500. CONNECT is currently 501.

## Borrowed request bytes

`Request` is a view of the complete validated engine request. No helper performs
socket I/O or allocates a parameter map. Application access to borrowed slices
ends when the callback returns. The engine may retain storage longer to finish
an explicit response borrow; that does not permit later application access.
Do not retain the Context, a request view, capture, header, form field or upload
part in a background task.

| Access | Semantics |
| --- | --- |
| `request.method()` | Raw method token. |
| `request.target()` | Distinguishes origin, absolute, authority and asterisk forms; raw target, optional path/query/authority slices. |
| `request.header(name)` / `headers()` | Case-insensitive first lookup or ordered repeated headers. Values remain borrowed. |
| `try request.query()` | Bounded, validated pair view with default limits. |
| `queryWithLimits(limits)` | Caller-selected byte/pair/name/value limits. |
| `fields.iterator()` | Ordered `name_raw`, `value_raw`, `has_equals`. |
| `fields.firstRaw(name)` / `allRaw(name)` | Exact raw-name matching; returns the first pair / an iterator over repeats. |
| `params.percentDecodeInto(raw, dst)` | Strict percent decoding; literal `+` stays `+`. |
| `params.formDecodeInto(raw, dst)` | Strict percent decoding plus `+` → space. |

`x=001&x=false&a[]=1&a[]=2` stays four text pairs. There are no automatic
numbers, booleans, JSON values, objects or arrays. A bare `x` differs from `x=`
through `has_equals`; empty separators are skipped. Decoding is explicit and
preserves the source. Invalid escapes and insufficient/overlapping destinations
are errors; decoding does not partially modify the destination on failure.
Decoded bytes can contain NUL or invalid UTF-8. Type and encoding interpretation
belongs to the caller.

## Bodies, forms and uploads

`request.body().iterator()` yields logical payload spans without chunk framing
or trailers. `contiguous()` returns a single borrowed payload when possible.
`copyTo(destination)` explicitly joins spans into caller storage. `reader()`
returns a fixed `std.Io.Reader` for contiguous payloads and otherwise returns
`BodyNotContiguous`; it never reads from the network. Make an explicit copy
first when a library needs a contiguous standard reader.

`request.formUrlEncoded(limits)` checks Content-Type and Content-Encoding before
returning a raw pair view. It does not merge query parameters into body fields.
For segmented bodies, explicitly copy and call `web.form.parse(bytes, limits)`;
the compiled example demonstrates that fallback. Parsing preserves `%` escapes
and `+` until `formDecodeInto` is called.

`request.formMultipart(limits)` validates the entire contiguous body, then
returns a view with a flat `.iterator()`. For segmented bodies, use `multipartBoundaryInto(dst)`,
an explicit body copy, and `web.multipart.parse(body, boundary, limits)`.
Boundaries are copied into a fixed 70-byte parser record; fields and file data
remain slices of the original input or the explicit caller copy.

Each part has `name_raw`, optional `filename_raw`, optional `content_type_raw`,
`headers_raw`, and `data`. One file and several files use the same loop. Repeated
names and literal `[]` suffixes keep their wire order and spelling. Missing
filename and empty filename are distinct; classification is an application
decision. Surrounding quotes are removed from `name_raw` and `filename_raw`,
while quoted-pair escapes remain. `content_type_raw` retains the complete raw
Content-Type value. Use `form.unquoteInto` explicitly to interpret names and
filenames when needed.

The supported profile is bounded modern `multipart/form-data`: no
preamble/epilogue, nested multipart, part transfer encodings, or `filename*`.
Part count, whole-body bytes, per-part bytes, headers and metadata parameters
have explicit limits. Unsupported encodings return ordinary errors. Full
validation precedes iteration, allowing applications to reject malformed final
syntax before acting on any part. Retain immutable backing bytes while using
the validated iterator. Neither form helper receives streams or writes to disk.

## Responses and capacity

`ctx.response` begins as an unpublished draft backed by the connection's
startup output arena. The scheduler secures its entire configured reservation
before invoking a handler. If older output fills the arena it drains that output
first, preserving the request and running application side effects once.

| Method | Behavior |
| --- | --- |
| `header(name, value)` | Validates and copies a header immediately; ordered repeats remain separate. |
| `text(status, bytes)` / `bytes(status, content_type, bytes)` | Copies caller data immediately, including stack data. |
| `jsonBytes(status, encoded)` | Copies pre-encoded JSON. |
| `jsonValue(status, value)` | Serializes once into a bounded fixed standard writer. |
| `print(status, content_type, format, args)` | Standard formatting into the reserved body. |
| `borrowBody(status, content_type, bytes)` | Explicit body borrow from retained request input or immutable server-lifetime assets, bounded by server.max_response_bytes rather than staging. |
| `stream(status, content_type, options)` | Worker response with a standard writer, incremental flushes, and bounded staging. |

For a one-shot response, return after preparing a body. App finalizes it on successful handler return.
Headers can be appended before or after preparing the body. A second body,
missing response, invalid header, overflow or failed serializer becomes a
generic error before publication. No success prefix is sent. Earlier finished
responses in a pipeline remain intact. The default mapper uses 400 for invalid
input, 413 for input-policy limits, 415 for unsupported encodings and 500 for
application/draft failures. Caller scratch exhaustion remains a 500; choose
scratch limits consistent with accepted input or handle that error explicitly.

Defaults are 2,048 serialized extra-header bytes, 32 extra headers and 8,192
copied/generated body bytes (also streaming staging capacity). Borrowed bodies
use `server.max_response_bytes` independently. Reservation is `384 + 128 + header_bytes + body_bytes` and
must fit `server.output_bytes`. `server.max_response_bytes` must cover the body
limit. Header names/values/Content-Type are copied. Generated/copied bodies
move once within the arena at finalization, counted by
`Stats.response_draft_copy_bytes`; that counter is not total copy volume.
See [response copies and borrowing](OWNERSHIP.md#response-copies-and-borrowing)
for each path, asset lifetimes, and how to serve a large retained asset with a
small output arena.

Content-Length, Transfer-Encoding and other canonical framing fields belong to
the engine. Use repeated `header("Set-Cookie", ...)` or a validated Location
header for now; cookie parsing/builders and a redirect helper belong to API-06.
Use [streaming responses](STREAMING.md) to write, flush, sleep, and write again
inside the same fixed worker callback. The returned handle exposes `writer()`,
`flush()`, and `finish()`. Headers become immutable after the first flush.
`body_bytes` bounds staging; `server.max_response_bytes` bounds the whole stream.
The advanced raw `engine.api.Handler` remains available for explicit
return-and-resume continuations. Typed inline continuations remain future work.

## std.Io and resource boundaries

`App.Options.io` stores the caller's implementation. Standard memory readers and
writers work inline without I/O. `ctx.serviceIo()` is available only when the
App explicitly selects fixed workers; it returns `IoRequiresWorkers` inline.
The example `/service` uses finite `io.sleep` under
`--execution workers --workers 2 --shards 1`.

The chosen provider and arbitrary application/service code can allocate, create
tasks, block, or ignore cancellation. Those behaviors are outside the sealed
framework allocator. Workers preserve HTTP owner progress but cannot preempt
arbitrary application code. Engine deadline cancellation is a cooperative
`ctx.cancelled` flag; it is not automatically a std.Io cancellation token.
Pass finite service deadlines and obey the flag where appropriate. Avoid blocking
logging or service calls on inline owners. Startup and caller services can use
ordinary std.Io; HTTP transport operations still use the existing custom engine.

App/route strings, generated Allow values, engine queues, threads and buffers
are included in startup budgeting. There is no implicit request heap arena.
Example stack scratch is application-owned and bounded; account for it when
choosing worker stack sizes. Shared services, allocator metadata, std.Io provider
internals and kernel buffers are outside the framework's requested-byte ledger.

## From Zap

The predecessor is [Zap](https://github.com/zigzap/zap). The public API review
and ports use the local Zig 0.16 revision recorded in the design and receipts.
Baz and [bounded/http](https://technologylab-ai.github.io/bounded-http/) are implemented in Zig, replacing the facil.io C foundation.
Baz additionally supports native Windows x64, with [its own native gate](../reports/2026-09-06-windows-baz.md).

| Old API concept | Current replacement |
| --- | --- |
| facil.io C HTTP foundation; no native Windows | Zig framework and HTTP engine; native Windows x64, Linux, and macOS support. |
| `App.Create(...)`, registration globals | Instance `web.App(Shared)`, borrowed typed Shared and endpoints. |
| Embedded endpoint base/path/error fields | Plain endpoint struct; `app.endpoint(path, &instance)`; App error hook. |
| `parseQuery`, `getParamSlice`, typed param variants | `query`, raw pair iterators, explicit decode and caller interpretation. |
| Merged `parseBody` parameter bag | Explicit URL-encoded or multipart parser, separate from query/JSON. |
| One-file-versus-array upload representation | Flat ordered parts, optional filename, borrowed payload. |
| `sendBody` / `sendJson` | Copying `text`/`bytes`, distinct `jsonBytes` and `jsonValue`. |
| Borrowing an arbitrary response slice | `borrowBody` restricted to retained input or server-lifetime assets. |
| Global start/stop | App instance lifecycle on the existing Cluster. |
| Incremental response output | `response.stream()` and `std.Io.Writer`, on fixed workers. |
| Public authentication middleware / typed inline continuation | Follow-up API-06 / API-07; low-level engine remains usable. |

Use the [roadmap](APP-API-ROADMAP.md) for the next session and named verification
gates. The [20 supported Zap example ports](../examples/README.md) are implemented.
This remains an experimental checkpoint before complete successor-MVP
qualification and public middleware/resumable APIs. Baz’s independent repository
and GitHub Pages site are published.

## Basic performance comparison

Results from the initial App prototype at `c152e59`, before package extraction,
on 2026-09-06 against the pinned Zig 0.16 port of Zap, in requests/s:

| Host | Connections / client threads | Baz prototype median | Zap median | App / Zap |
| --- | --- | ---: | ---: | ---: |
| macOS, Apple M3 Max | 32 / 2 | 254,261 | 245,054 | 1.038× |
| Linux, Intel Core Ultra 7 258V | 32 / 2 | 363,594 | 205,310 | 1.771× |
| macOS, Apple M3 Max | 1 / 1 | 33,199 | 52,809 | 0.629× |
| Linux, Intel Core Ultra 7 258V | 1 / 1 | 74,386 | 72,575 | 1.025× |

Three alternating pairs per profile, one-second warmup and three-second timing,
13-byte plaintext, one server thread, 128 slots, keep-alive without pipelining.
All warmups and measurements used exact Zig 0.16.0 ReleaseSafe with Zig assertions
enabled. The 24 measured trials reported zero wrk socket/non-2xx-or-3xx errors.
These short unpinned loopback runs do not establish capacity, latency or API
overhead. wrk revisions differ across hosts; Zap retains its inherited `-Os`
and `-fno-sanitize=undefined` C flags. Bodies were checked before and after timing,
not individually throughout the load. The [full receipt](../reports/2026-09-06-basic-zap.md)
contains all ranges, source identities, commands, raw trials and cleanup records.
