# A modern application framework on zig-http

Status: design proposal, 2026-09-06. No successor API is implemented by this
document. The implementation sequence and session ledger are in
[APP-API-ROADMAP.md](APP-API-ROADMAP.md).

Build a modern successor to Zap, with a different name, using exact Zig 0.16.0
and zig-http. Keep Zap's pleasant application model: typed shared context,
stateful endpoint structs, named HTTP methods, composable authentication and
short response calls. Use Zig's explicit capabilities and ordinary byte slices
throughout. The new framework should be useful for real application code while
retaining zig-http's bounded ownership and progress contract.

The name is intentionally undecided. `web` below is design notation for the
future public module, not a selected product name or an existing import.
Compatibility is conceptual; source compatibility with Zap is not a goal.

## What we inspected

| Input | Exact baseline and scope |
| --- | --- |
| zig-http | `4b3cd5551d80b422ec6ef763627d019e6f1dfb83`; README, roadmap, handoff, ownership/interfaces/evidence docs, public parser/writer/server contracts and maintained demo. |
| Local Zig 0.16 Zap port | Separate Git repository at `../fi/deps/zap`, clean HEAD `f6099ecec496c7ec623c5913baa5b6b5da2e883d`. Package metadata says `0.10.6`; this local revision, rather than that version label or upstream HEAD, identifies the reviewed port. |
| Zig wiki | Read-only consultation at `362da3b8023e6918d4b72c046821334ebd3722ca`, using its `zig-wiki` skill and query command. Relevant guidance and evidence are linked below. |
| Installed compiler | `zig version` reported `0.16.0`; `zig env` identified the installed release source and `aarch64-macos.26.6.2...26.6.2-none`. Read `std/process.zig`, `std/Io/Reader.zig`, `std/Io/Writer.zig` and `std/json/Stringify.zig`. This is source inspection, not a new runtime gate. |

Zap references below are local sibling links into that reviewed checkout. They
describe public contracts and examples; facil.io internals are not an
implementation template. These planning files stay in zig-http. No wiki source
records or existing native/performance receipts are changed.

## Zap ideas to retain and modernize

| Zap API / example | Useful idea | Successor decision |
| --- | --- | --- |
| [App.Create / register](../../fi/deps/zap/src/App.zig), [basic App](../../fi/deps/zap/examples/app/basic.zig) | One application context type shared by endpoints; endpoint instance state; compile-time signature checks. | `App(Shared)` is a real instance. Register borrowed endpoint pointers before startup. Multiple instances with the same Shared type must work independently. |
| [App.Endpoint method dispatch](../../fi/deps/zap/src/App.zig) | `get`, `post`, `put`, `delete`, `patch`, `head`, `options` methods are easy to discover. | Keep method conventions as optional registration sugar over one router. Endpoint structs need no embedded framework base object or mandatory `error_strategy` field. |
| [Router](../../fi/deps/zap/src/router.zig) | Plain functions and bound struct methods are both useful. | Support both, through the same typed request context and routing rules used by endpoints. |
| [Raw query helpers](../../fi/deps/zap/src/request.zig) (`getParamSlice`, `getParamSlices`) | Borrowed, undecoded text without a preceding parse call. | Make this the primary parameter model; add deliberate duplicate, bare-key and decoding semantics. |
| [Request response helpers](../../fi/deps/zap/src/request.zig) (`sendBody`, `sendJson`, headers, cookies, redirects) | Common responses take little code. | Separate immutable Request from mutable Response; short helpers copy into reserved output, with an explicitly named borrowing alternative. Distinguish pre-encoded JSON from serialization of a Zig value. |
| [App authentication](../../fi/deps/zap/examples/app/auth.zig), [middleware](../../fi/deps/zap/src/middleware.zig) | Typed composition, early responses, application-specific authentication. | One middleware system, typed request locals, explicit continue/respond result, and ordinary endpoint wrappers. |
| [App error example](../../fi/deps/zap/examples/app/errors.zig) | Handlers can use `try`; application policy maps failures. | Preserve error unions; supply a safe default 500 and a configurable error mapper. Never send error traces to clients by default. |
| [App.init](../../fi/deps/zap/src/App.zig) in the local port | Explicit `std.Io` is already threaded into the modernized Zap port. | Keep capability injection and extend it coherently to startup/services and bounded reader/writer interoperability. |

The new API removes the combined query/body parameter bag, Bool/Int/Float
coercion, conversion back into owned strings, and the `Hash_Binfile` versus
`Array_Binfile` distinction visible in
[request.zig](../../fi/deps/zap/src/request.zig) and the
[upload example](../../fi/deps/zap/examples/bindataformpost/bindataformpost.zig).
It also replaces App's public singleton restriction, implicit prefix matching,
per-thread growable request arenas, and separate App/Endpoint/Middleware context
mechanisms with explicit instances, routes, bounded storage and one context model.

## Architecture and Zig 0.16 integration

```text
application: Shared services + endpoint structs + route/middleware policy
    |
new public framework: App / Router / Request / Response / codecs
    |
bounded_http: Cluster / api.Handler / Writer / parser / startup budget
    |
existing custom io_uring (Linux) or nonblocking kqueue (macOS)

main(std.process.Init) -> caller's std.Io + allocator -> startup / services
retained input and reserved output <-> std.Io.Reader / std.Io.Writer
```

Implement the framework as modules in this repository first, with a distinct
public root and the existing `bounded_http` module still usable directly.
Extracting a separate package can follow a useful vertical slice. Do not make
package extraction, branding or a transport replacement prerequisites for API work.

`std.process.Init` belongs in executable examples. Libraries receive the narrow
capabilities they need: an allocator for startup, the caller's `std.Io` where
I/O is performed, validated options, and typed shared services. No hidden global
I/O implementation, event loop or allocator is created by a convenience method.

The first reader adapter reads only the complete retained HTTP body. A
contiguous body can use `std.Io.Reader.fixed`; a later span adapter can traverse
existing payload spans with explicit bounded scratch. Neither initiates socket
reads. The response adapter writes only an exclusive output reservation using
`std.Io.Writer.fixed`, allowing Zig formatting and `std.json.Stringify.value`.
On overflow a fixed writer may already contain a prefix: discard the draft or
roll it back; publish only fully initialized successful output. Its `flush()`
does not yield an HTTP response. HTTP flush/resume stays an explicit operation.

`std.Io` is a capability interface, not an evented-execution guarantee. Keep
inline callbacks short, nonblocking and free of dynamic allocation. Potentially
blocking service operations use explicitly selected startup workers and finite
application deadlines. The current server supports this policy for the whole
server, with one shard in worker mode; it has no per-route offload. Passing
`std.Io` does not change that. `io.async`/`io.concurrent`, background work and
bridging HTTP cancellation into service I/O require a later owned-job design.
The existing atomic cancellation flag does not cancel an arbitrary `std.Io` call.

Supplying our own bounded `std.Io` is a separate, explicitly requested design
track. [STD-IO-DECISION.md](STD-IO-DECISION.md) evaluates an optional managed
runtime, exact-release alternatives, required task/operation ownership and
prototype gates. The initial capability-injection design keeps that option open.

These distinctions follow the wiki's
[std.Io](../../zigllmwiki/wiki/std-io.md),
[process capabilities](../../zigllmwiki/wiki/process-init-and-capabilities.md),
[small truthful API contracts](../../zigllmwiki/wiki/lower-dimensional-api-contracts.md)
and [startup allocation](../../zigllmwiki/wiki/static-allocation-and-constant-work.md)
guidance. The installed exact release source remains authoritative for Zig API
spellings; synthesized guidance does not replace source or runtime evidence.

## Proposed application shape

Design notation only: these signatures express intent, are not compiled Zig,
and must become maintained compiled examples during implementation.

```text
App(Shared).init({ allocator, io, shared: *Shared, server, limits }) -> App
app.route(method, path, handler)
app.endpoint(path, &endpoint)
app.start()                 # freezes registration and prepares all resources
app.run()                  # releases admission; waits for terminal ownership
app.requestStop()           # asks this instance to stop
app.deinit()                # legal only after safe stop or safe startup unwind

Users.get(self: *Users, ctx: *RequestContext(Shared)) !void
ctx.shared                 # typed application services/state
ctx.request                # immutable borrowed request view
ctx.response               # exclusive draft response
ctx.response.text(200, "hello")
ctx.response.jsonValue(200, value)
```

Register functions and endpoint methods into one immutable startup-built route
table. Caller-owned Shared, endpoints and middleware stay at stable addresses
through terminal shutdown. Prefer in-place initialization or an explicitly
owned stable App pointer once internal callbacks reference the instance. App
owns its registration tables and adapter state, not the caller's services.
Do not install process-global signal handlers in the library. Examples use an
explicitly signal-safe stop notification; do not assume arbitrary `requestStop()`
machinery is safe inside an OS signal handler.

Shared is process/application scope. Endpoint fields are endpoint scope.
`ctx.locals` is optional typed request scope, initialized once and retained
across any resumptions. It is not a dictionary of `anyopaque` values. Support
an empty default locals type and an explicit initializer when a custom type
needs one. Keep the common App spelling small; settle its second type parameter
or options spelling when the middleware example is compiled.

Inline shards and worker callbacks can access Shared/endpoints concurrently.
Types do not make mutable state thread-safe. Use immutable values, bounded
nonblocking synchronization for inline use, or service APIs with the documented
execution policy. No application isolation is claimed.

### Routing decisions

- Exact method and path matching is the default, case-sensitive for both.
  Query bytes never participate in route matching. Do not silently decode,
  lowercase, resolve dot segments or merge trailing slashes in paths.
- Publish a target view that distinguishes origin, absolute, authority and
  asterisk forms. Preserve the complete raw target and absent versus empty
  query. An absolute target with no path may use an explicitly documented `/`
  routing default; that default is not a slice that occurred on the wire.
  Parsing authority/Upgrade syntax does not enable tunnels/upgrades.
- Add explicit segment captures such as `/users/:id`; captures are raw slices.
  Static segments take precedence over captures. Reject ambiguous duplicate
  patterns at registration. Keep `/users` and `/users/new` usable together.
- A mount/prefix route is an explicit later option and respects segment
  boundaries: `/users` must not incidentally match `/users-old`. Begin without
  regexes or automatic route-parameter coercion.
- Unknown path gets 404. A known path with an unsupported method gets 405 with
  `Allow`. Prefer an explicit HEAD method, otherwise use GET and let the core
  suppress body bytes. Define generated OPTIONS/Allow from the frozen table;
  handle `OPTIONS *` separately. Keep unsupported CONNECT/upgrade behavior
  explicit. Preserve extension method tokens for explicit registration.

HEAD and 405/Allow behavior are based on
[RFC 9110 §§9.3.2, 10.2.1 and 15.5.6](https://www.rfc-editor.org/rfc/rfc9110.html).
Route syntax, precedence and normalization choices above are proposed project
policy, not claims that HTTP specifies a router API.

## Parameters are bytes

### Query and URL-encoded fields

Use one small ordered pair view for both encodings, in separate namespaces:

```text
Param { name_raw: []const u8, value_raw: []const u8, has_equals: bool }
request.query().iterator()
request.query().firstRaw(name) -> ?Param
request.query().allRaw(name) -> Iterator
percentDecodeInto(source, destination) -> decoded destination slice
formDecodeInto(source, destination) -> decoded destination slice
```

Raw access never allocates, decodes or converts types. `firstRaw` uses exact,
case-sensitive raw name comparison; `%61` and `a` differ. An explicitly decoded
name lookup can be added when needed, with its own bound and duplicate policy.
Returning a Param preserves absence versus a present bare key. Callers that
require uniqueness must reject duplicates explicitly; no implicit last-wins map.

| Input | Raw interpretation |
| --- | --- |
| `n=001&ok=false` | Strings `001` and `false`; numeric/boolean interpretation is application code. |
| `tag=a&tag=b` | Two ordered entries with the same name. |
| `a[]=1&a[]=2` | Two entries named literally `a[]`; no synthetic array. |
| `flag&flag=` | Both have an empty value; `has_equals` is false, then true. |
| `=x&a=b=c` | Empty name with `x`, then name `a` with value `b=c`. |
| `a=%26%3D&b=x+y` | Preserve escape spelling and `+`; split before decoding. |
| `&&a=1&` | Skip empty separator components by policy; full raw query remains available. |

This table describes the pair parser, including URL-encoded body input. The
current HTTP target parser rejects unescaped brackets in a wire query; use
`a%5B%5D=1&a%5B%5D=2` there, retaining `a%5B%5D` in the raw name view.
API helpers do not implicitly widen the engine's accepted target grammar.

`percentDecodeInto` preserves `+`; `formDecodeInto` additionally converts raw
`+` to space. Both decode `%HH` exactly once into the supplied destination,
leave source untouched, reject malformed escapes and insufficient destination
capacity, and return byte slices. A destination overlapping immutable request
input is not supported. Define all-or-error destination publication in the
codec contract; preflight can prevent a partially decoded public result.
NUL and non-UTF-8 results remain bytes, with explicit validation if text is
required. There is no Unicode normalization or automatic integer parsing.

Form-style query decoding is an explicit choice too: applications handling
browser form queries may call `formDecodeInto`, while raw query access stays
unchanged. RFC 3986 supplies URI percent syntax; the WHATWG form algorithm
supplies form `+` behavior and ordered pair splitting. Our raw byte API and
strict malformed-escape policy deliberately differ from its automatic string
decoding/permissive percent-decoding. See
[RFC 3986 §§2–3](https://www.rfc-editor.org/rfc/rfc3986.html) and
[URL Standard §5.1](https://url.spec.whatwg.org/#urlencoded-parsing), consulted
2026-09-06; the latter is a living specification, not a pinned wiki record.

### Body encoding stays explicit

`request.body()` exposes logical payload spans as it does today. Add
`contiguous()` and `copyTo(destination)` conveniences. `contiguous()` succeeds
when the logical payload occupies one source slice, including a single payload
chunk; otherwise it returns absence. Empty bodies have a documented empty view.
`copyTo` copies payload only, checks the complete destination bound and returns
the caller-owned slice. Never parse chunk framing as form content.

The initial form APIs take contiguous bytes:
`urlencoded.parse(bytes, limits)` and `multipart.parse(bytes, boundary, limits)`.
Request conveniences validate the declared media type and use the contiguous
body, returning `BodyNotContiguous` when necessary. The caller can explicitly
copy the bounded logical body once, then parse that slice. Fixed-length forms
borrow receive input; copied forms borrow the caller's destination. No hidden
flattening, allocation, or second body buffer per connection.

This is the initial simplicity tradeoff: a field split across HTTP chunks cannot
be one slice of the original buffer. Support that request through an explicit
copy, rather than infecting every ordinary field with a fragment-list type.
If real workloads justify avoiding that copy, add a separate range/spans API
later without changing the simple contiguous parser's contract.

Select URL-encoded and multipart parsing explicitly. Check media types and
quoted parameters with a bounded parser; do not silently sniff JSON or interpret
arbitrary body data as a form. Missing, unsupported or ambiguous Content-Type is
an ordinary reported error. `text/plain` bodies stay bytes. JSON uses an explicit
JSON parser into an application-selected type/storage; it never joins query or
form fields. Compressed request bodies are not automatically decompressed.

### Multipart and uploads

Expose a flat ordered iterator of `Part` views:

```text
Part {
    name_raw: []const u8,
    filename_raw: ?[]const u8,
    content_type_raw: ?[]const u8,
    headers_raw: []const u8,
    data: []const u8
}
```

Every repeated upload is another Part, whether one file or ten arrived under
the same name. Empty files are valid. Missing and empty filenames differ, and
absence of filename does not prove that a payload is text. Multipart payloads
are already content bytes; do not URL-decode them as a side effect. Preserve
missing media type in raw metadata; an explicit effective-type helper may
apply a protocol default. These choices follow
[RFC 7578 §§4.2–4.4 and 5.2](https://www.rfc-editor.org/rfc/rfc7578.html).

Raw disposition parameter views exclude enclosing quotes but retain quoted-pair
escapes; explicit `unquoteInto` produces decoded metadata in caller storage.
No automatic percent-decoding, charset conversion, MIME sniffing, path cleanup
or disk writes. A filename is metadata, never an authorized filesystem path.
The first release supports a documented modern form-data profile; deprecated
nested multipart and Content-Transfer-Encoding decoding are unsupported with
explicit errors, not flattened into invented upload arrays. Record that profile
as a limitation rather than claiming all historical MIME compatibility.

Bound part count, per-part header bytes/count and universal `max_part_bytes`
within the core body/wire limits. Separate field/file limits require an explicit
application or metadata classification policy, since filename absence cannot
classify a part reliably. Boundary and header scanning must have a finite work
bound under adversarial near-matches. Validate the terminal boundary before
application code commits irreversible form side effects; a cheap validation
pass or a validated parser constructor can make iteration safe to consume.

This is retained-body multipart parsing. zig-http currently delivers a request
only after its entire bounded body arrives. Uploads larger than that limit,
network-streamed uploads and automatic spooling require a separate receive and
file-operation lifecycle milestone.

## Convenient responses with honest progress

Provide two explicit handler contracts:

| Contract | Application behavior | Framework obligation |
| --- | --- | --- |
| Ordinary endpoint, `!void` | Executes once, prepares exactly one bounded response; no manual flush. | Secure output capacity before execution, finalize after success, or discard the unpublished draft on error. Never replay application effects. |
| Resumable endpoint, `!Action` | Uses a retained typed state and request/flushed events; explicitly yields. | Keep route, request, state and output ownership across every flush/finish/close. |

Start with a configured App-wide one-shot output reservation, including bounded
headers and generated body allowance. If earlier batched responses leave too
little space, drain them before invoking any user endpoint or middleware. Do not
call the endpoint, encounter WouldBlock, then rerun it. A future per-route
reservation can refine utilization after measurement; the first implementation
can keep admission mechanically simple.

This needs an explicit core integration change: the current scheduler guarantees
only `api.header_reserve_bytes` before dispatch, and `Writer.begin` serializes
the head immediately. A Response draft must support bounded custom headers,
all-or-error body construction, and rollback of only the current unpublished
response. Never reset older frozen response cells. Keep the direct low-level
Handler contract available.

Short helpers copy stack/scratch bytes into owned output or generate directly
there. `borrowBody` is separately named and accepts only the core's eligible
request-input/server-lifetime sources. Never return a descriptor that points at
a handler's local buffer and defer its copy until after the handler returns.

Headers use validated names and values, finite byte/count budgets, and explicit
append/replace behavior. Repeated `Set-Cookie` lines remain separate. The core
owns Content-Length, Transfer-Encoding and connection framing; application
headers cannot contradict them. Add cookies and redirect helpers on this header
surface, rather than constructing unvalidated wire text. A one-shot helper
larger than its configured allowance reports a response-limit error before
publication; callers choose the resumable contract for larger generated output.

Unmapped handler failures yield a bounded generic 500 if no output was published.
Input helper failures have explicit mappings, such as malformed form/escape to
400, body/form size policy to 413, and unsupported media type to 415. Target and
header bounds retain 414/431. Insufficient caller decode/copy storage is a local
capacity error, not automatically a client 400/413. Output exhaustion
is a server response failure, not evidence that the client's body was too large.
After an HTTP flush has published any part of the current response, an error
closes that response/connection; it cannot replace the status with a fresh 500.
Returning successfully without preparing a response is an application error,
not an implicit 200. Error reporting must itself be bounded and nonblocking on
inline owners; a custom logging sink is an application capability.

## Storage, middleware and lifetime

| Storage | Lifetime and permitted response use |
| --- | --- |
| Raw request slices / form parts parsed directly from receive input | Borrow receive input; usable while the active handler/continuation owns the request. The core may retain an eligible output borrow longer, but that grants no later application access. |
| Caller decode/copy buffer and form parts parsed from it | Tied to that buffer's owner, not receive storage. Stack buffers end at callback return. Copy into Response before returning; derived parts do not qualify for current borrowBody. |
| Optional request scratch / typed locals / continuation state | Preallocated per slot and reset at defined request transitions, with application borrows reconciled. Survives resumptions if that API promises it; cannot be borrowed into finished output that outlives reuse. |
| Response draft and frozen output | Exclusive while drafted; immutable after publication until all applicable kernel borrows return. |
| Shared, endpoints, startup assets | Owned by application through terminal App shutdown; shared mutation needs the execution policy's synchronization. |

Prefer caller buffers, fixed typed locals and direct output generation first.
If convenience scratch is added, give it an explicit byte/alignment budget and
checked reserve operations, with no growable backing arena or heap fallback.
Include all App metadata, route storage and per-shard/per-slot capacities in
startup accounting. A configured process-wide connection ceiling does not
remove the current engine's per-shard storage multiplier.

Do not emulate Zap's reset-after-handler arena lifetime. A callback can flush
and resume, and earlier finished responses may still be pending when the next
request reuses a slot's application state. Scratch is never eligible for the
current output borrow contract. Dynamic leases and terminal release hooks are
a separate prerequisite for any future exception.

Middleware runs a fixed startup-registered chain once on initial dispatch. Use
a named continue/respond result, not a bool whose interpretation depends on
`isFinished()`. Resumptions go to the selected continuation without repeating
authentication or initialization. Request locals carry typed authentication
results; application policy determines sessions, tokens and storage. No automatic
form parsing, password coercion or built-in authentication database is required.

Initially offer request and error hooks only. An after-handler hook is not a
delivery notification. Do not promise a sent/cancel/finalizer hook until every
terminal path, execution owner and retained borrow has a defined lifecycle.

App startup freezes routing, validates combined resource bounds, prepares all
workers/shards and seals framework allocation before serving. App shutdown
preserves [OWNERSHIP.md](OWNERSHIP.md): cancellation does not preempt callbacks,
and uncertain ownership must not unwind and free live buffers. Keep the core's
fatal/retain boundary explicit in embedding and compiled examples.

## Evidence boundary and deliberate later work

The current engine's implementation and measured scope are in
[INTERFACES.md](INTERFACES.md), [OWNERSHIP.md](OWNERSHIP.md),
[EVIDENCE.md](EVIDENCE.md), and the
[arena adoption report](../reports/2026-09-05-arena-adoption.md). The wiki's
[adoption source record](../../zigllmwiki/sources/zig-http-arena-adoption-2026-09-05.md)
pins those receipts. They establish neither this proposed framework nor a
performance cost for its future conveniences.

Defer dynamic leases/offload, request-body streaming, sendfile/spooling,
TLS, WebSockets, HTTP/2, general static-file hosting, compression, automatic
session storage and Windows HTTP to separately scoped work. Public bind-address
configuration and deployment documentation need their own transport-facing
gate; the initial successor inherits loopback-only plain HTTP/1.1. Existing
Windows evidence in the wiki is not HTTP runtime evidence. The user has deferred
Windows performance/publication during Linux/macOS tuning.

The useful first result is a small named framework with a complete application
example, predictable bytes and errors, and the engine's ownership guarantees.
The roadmap makes each piece independently reviewable across sessions.
