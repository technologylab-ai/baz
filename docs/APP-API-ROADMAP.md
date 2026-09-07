# Baz implementation roadmap

Status: composition MVP merged and natively qualified; bounded notifications, SSE
and a complete application are in development, 2026-09-07.
Exact target: Zig 0.16.0. See the [implemented API](APP-API.md),
[21 example ports](../examples/README.md), and
[composition native receipt](../reports/2026-09-07-composition.md) for exact evidence and limits.

Build Baz (Bounded Async Zap) with Zap's typed App/endpoint ergonomics, borrowed-byte
request APIs, modern Zig capabilities, and the external [bounded/http](https://technologylab-ai.github.io/bounded-http/) engine.
The detailed API decisions are in [APP-API-DESIGN.md](APP-API-DESIGN.md).
[STD-IO-DECISION.md](STD-IO-DECISION.md) evaluates supplying our own std.Io.
The separate [engine roadmap](https://github.com/technologylab-ai/bounded-http/blob/main/ROADMAP.md)
tracks transport reliability, performance, and platform work. Its
[Pages documentation](https://technologylab-ai.github.io/bounded-http/) explains the engine contracts.

## Resume here

- Repository: standalone `baz` checkout; main branch `main`.
- Windows support integrated from `work/windows-update`; [native three-platform receipt](../reports/2026-09-06-windows-baz.md).
- See [repository preparation](REPOSITORY.md) and [handoff](../HANDOFF.md) for current state.
- Starting engine commit: `4b3cd5551d80b422ec6ef763627d019e6f1dfb83`.
- Reviewed Zap port: `../fi/deps/zap` at
  `f6099ecec496c7ec623c5913baa5b6b5da2e883d` (its own Git repository).
- API-01–05 are implemented as the first bounded one-shot slice. Twenty-one of
  23 original example targets are ported/adapted, including Mustache pages with
  startup parsing and bounded typed rendering. See [MUSTACHE.md](MUSTACHE.md).
  TLS is out of scope; WebSockets needs upgrade support.
- Worker streaming is implemented and passed native gates on all three platforms;
  see [STREAMING.md](STREAMING.md). Typed continuations pass the native APP-RESUME gates; see [the guide](CONTINUATIONS.md).
- API-09 Mustache passed all three native gates; see the
  [verification report](../reports/2026-09-06-mustache.md). The user prioritized
  real application templating ahead of composition work.
- API-06 and API-07 now pass native gates: public middleware/locals, reusable
  expiring sessions and typed continuations with timed waits.
  Baz now consumes an external engine package; repository and Pages publication are complete.
  IO-01–04 remains deferred, explicitly reaffirmed by the user on 2026-09-07.
- Active: API-10 producer notifications and SSE, then API-11 complete live-job application.
- Consult the receipt/session ledger for native gates and cleanup state. The
  separate [basic Zap comparison](../reports/2026-09-06-basic-zap.md) records
  native ReleaseSafe results at 1 and 32 connections; it does not isolate API
  overhead or establish capacity.
- Other agents are writing architecture documentation in separate worktrees.
  Reconcile their landed docs/current engine contracts before the next session;
  preserve this plan's baseline and re-evaluate changed ownership assumptions.

Use `git branch --list` to inspect the local integration branches.
Read AGENTS.md, the current ownership contract and the two design documents.
Inspect Git state before editing; do not overwrite another session's work.

## Decisions carried forward

| Topic | Working decision |
| --- | --- |
| Product | Baz (Bounded Async Zap), package/import `baz`, external dependency/import `bounded_http`. Repository: [technologylab-ai/baz](https://github.com/technologylab-ai/baz), with its [Pages documentation](https://technologylab-ai.github.io/baz/). [bounded/http](https://technologylab-ai.github.io/bounded-http/) stays independently usable. No Zap source-compatibility layer. |
| Platform/version | Exact Zig 0.16.0; plain HTTP/1.1 on Linux, macOS, and native Windows x64. Public bind addresses need later qualification. TLS is out of scope. |
| Windows | Supported natively on x64 with CI: Debug/ReleaseSafe verification, 14 App groups, 20 ported-example groups, 14 streaming groups, and three shard/shutdown cases. Windows performance remains deferred; Baz remains experimental. |
| App | Real instances; typed Shared; borrowed endpoint instances; startup-only registration; one routing/context model. |
| Input | Raw immutable slices, ordered duplicates, no coercion, no bracket-array syntax, no merged query/body/JSON bag. |
| Decoding | Explicit caller destination; percent and form-plus decoding are separately named; raw bytes remain available. |
| Bodies/forms | Contiguous form parsers; explicit logical-body copy for segmented input. Flat multipart Part iterator. No implicit disk writes or receive streaming. |
| Responses | One-shot handlers with capacity secured before execution; same-handler streaming through std.Io.Writer on fixed workers. Typed continuations release the executor between flushes and timers. Never replay application side effects. |
| std.Io now | Inject caller capabilities; standard bounded Reader/Writer interoperability; explicit workers for blocking services. |
| std.Io provider | IO-01–04 remains deferred by user decision (reaffirmed 2026-09-07); an optional bounded cooperative provider remains a candidate. |
| Memory | Framework storage reserved at startup; fixed buffers/reservations and optional bounded locals/scratch, no growable request arena or hidden heap fallback. |
| Ownership | Input/output/task borrows survive until their real terminal transitions; scratch cannot become a dynamic output borrow without a later lease protocol. |

The product and public import are Baz and `baz`. Future API spellings remain
proposals until implemented. Record semantic changes and their evidence in the ledger.

## Milestones and dependencies

Each item is a bounded deliverable, not a promise to finish in one session.
Split implementation across sessions at its named gate and record exact state.

| ID | State | Deliverable | Depends on | Acceptance gate |
| --- | --- | --- | --- | --- |
| API-00 | complete: inspection/design only | Public Zap analysis, framework design, this roadmap, std.Io exploration. | — | Documentation/source review; no runtime qualification. |
| API-01 | implemented; scoped receipt | Public raw target/request/query views and explicit codecs. | API-00 | APP-TEXT-OWNERSHIP |
| API-02 | implemented; scoped receipt | Bounded response drafts, pre-dispatch reservation, custom headers and standard writer integration. | API-00 | APP-RESPONSE, APP-STDIO-WRITER |
| API-03 | implemented; scoped receipt | App instances, one router, endpoint methods, typed Shared and startup/stop lifecycle. | API-01, API-02 | APP-COMPOSITION |
| API-04 | implemented; scoped receipt | Body adapters and explicit URL-encoded form API. | API-01, API-03 | APP-FORM, APP-STDIO-READER |
| API-05 | implemented; scoped receipt | Flat multipart fields/files over retained input. | API-04 | APP-MULTIPART |
| API-06 | implemented; native gates passed | Typed locals, middleware and authentication composition: [guide](MIDDLEWARE.md). Public cookie/redirect helpers: [guide](COOKIES.md). | API-02, API-03 | APP-MIDDLEWARE |
| API-07 | typed continuations implemented; native gates passed | Typed start/resume callbacks, timed waits, startup State/Locals/draft pool; [guide](CONTINUATIONS.md). | API-03, API-06 | APP-RESUME |
| API-08 | composition MVP qualified and merged | 21 supported ports, worker streaming and typed continuations, standalone package and Pages; explicit exclusions below. | API-01–07 | APP-NATIVE |
| API-09 | implemented; native gates passed | Pure Zig Mustache: startup template/partial ownership, bounded typed rendering into reserved HTML, original Zap compatibility and official core fixtures. | API-02, API-03 | APP-MUSTACHE |
| API-10 | implementing; native gates pending | Bounded producer notifications, fixed mailboxes and SSE encoding; explicit saturation, lifetime and replay policy. | API-07 | APP-NOTIFICATIONS, APP-SSE |
| API-11 | implementing; native gates pending | Complete Mustache/session/live-job application with fixed jobs and replay, revocation, slow clients and disconnects. | API-09, API-10 | APP-JOBS |
| IO-01–04 | deferred by user on 2026-09-07 | Owned std.Io feasibility, isolated prototype, HTTP integration and adoption decision. | First API MVP; see STD-IO-DECISION | STDIO-PROTOTYPE, STDIO-HTTP-OWNERSHIP, STDIO-ADOPTION |

API-01 and API-02 can proceed independently after agreeing on module exports.
API-04 and API-06 can proceed independently after API-03. The user selected the
ordinary App API first; owned std.Io compatibility/design work resumes after
the API MVP. If the owned runtime becomes a product requirement,
add its adoption gate to the relevant release milestone explicitly.

The first useful vertical slice is API-01–03: one runnable App with typed Shared,
two endpoints, raw query access, a decoded value copied into a response, bounded
JSON output, and instance-specific shutdown. This is an intermediate experimental
checkpoint. The successor MVP additionally needs forms/uploads, middleware and
the migration/native gates.

### API-01 — raw request views and explicit text codecs

Deliver a thin public Request view over validated `http.Request`, a target view,
header iteration alongside first-header lookup, raw query iteration and lookup,
and strict percent/form decoding into caller-provided destinations. All helpers
are lazy or bounded scans; no parameter hash map or parse-cache allocation.

Fix semantics before choosing convenience names: absent versus empty query,
bare key versus `key=`, duplicate order, first `=`, literal bracket names, exact
raw key comparison, strict decoding, and explicit type/UTF-8 interpretation.
Centralize target splitting used by the new router; do not copy the demo's path
logic into several layers. Keep authority/asterisk forms distinguishable.

Gate APP-TEXT-OWNERSHIP checks pointer identity against original receive input,
unchanged source bytes, repeats, empty names/values, bare keys, empty separator
components, absolute/origin/asterisk/authority targets, and encoded delimiters.
Test `%26`, `%3D`, `%2520`, `%2B`, literal `+`, malformed/truncated escapes,
decoded NUL/non-UTF-8, exact/insufficient destination sizes, pair-count bounds,
and no accidental mixing with body fields. Helpers must return ordinary errors
for untrusted malformed data, never ownership assertions.

Suggested ownership: parser agent owns new request/target/query/codec modules
and their Zig tests; parent owns public exports, examples and build registration.
Avoid changing core framing except for an agreed public-view seam.

### API-02 — response reservation and standard writers

Add the smallest engine seam that reserves a configured one-shot response extent
before any user handler or middleware runs. Drain earlier batches when needed.
Keep request/deadline ownership while waiting; a side-effecting endpoint executes
exactly once. Start with an App-wide reservation and measure before adding
per-route sizing. Preserve the original direct Handler behavior/defaults.

Define bounded draft metadata and header count/bytes; checked head/body size
arithmetic; validation before publication; copying, explicit borrowing and
direct-generation response paths. Give output construction an unpublished
rollback boundary. An error must not discard/rewrite earlier frozen cells just
to make a 500. Keep generic fallback space available within the selected budget.

Integrate `std.Io.Writer.fixed` over exclusive reserved output for formatting and
`std.json.Stringify.value`. Use distinct APIs for a pre-encoded JSON byte string
and serialization of a Zig value. A full fixed writer can contain a partial
prefix; commit only successful construction. Standard writer flush and HTTP
flush have different contracts. No serializing twice as an unexamined size probe
when custom serializers can have side effects.

Gate APP-RESPONSE exercises side effects once under near-full batches, exact and
over-limit body/head sizes, bounded fallback, repeated headers, CR/LF injection,
invalid header names/values, reserved framing-header rejection, HEAD, bodyless
statuses, declared-length errors, two attempted terminal responses, and errors
before/after publication. Preserve old framing/partial-send suites.
Gate APP-STDIO-WRITER checks formatting/JSON exact fit and one-byte overflow,
escaping, custom serializer failure, no partial success on the wire, and bounded
allocation behavior for the supplied adapters (not arbitrary user serializers).

Suggested ownership: lifecycle agent owns `src/api.zig`, response modules and
the agreed `src/server.zig` admission/draft seam; parent owns integration/build.
No transport rewrite is expected. Add a transport agent only if changes actually
reach operation storage or platform completion semantics.

### API-03 — App, endpoints and routes

Provide real `App(Shared)` instances, plain/bound route registration, endpoint
HTTP methods, typed request context, and one-shot error propagation/mapping.
Make endpoints ordinary structs. Registration is checked/frozen at startup;
route/context/endpoint lifetimes and instance address stability are documented.
Add exact routing and bounded segment captures with deterministic precedence,
404/405/Allow, explicit HEAD fallback and OPTIONS behavior.

Implement `init/start/run/requestStop/deinit` on the existing Cluster startup
gate and budget. Pass caller I/O to actual startup/service operations; keep
`std.process.Init` at example main. Enforce valid inline/worker/shard options;
do not claim per-route blocking offload. Signals belong to the executable.
Include registration/adapter storage in the startup resource ledger and seal
the framework allocator before admission.

Gate APP-COMPOSITION runs two Apps of the same Shared type with distinct state
and ports, proves one stop does not stop the other, checks registration freeze
and duplicate/ambiguous routes, GET/HEAD/OPTIONS/405 behavior, raw captures and
query-independent routing, and demonstrates no callbacks before the startup
release gate. Test partial initialization/start failure, safe cleanup, supported
inline/worker modes, and shared-state concurrency using an appropriate fixture.

Deliver the first compiled App example at this milestone. It must use only the
public module and demonstrate bounded output and caller-supplied capabilities.
Parent owns App/router integration, README, build and example. Delegate pure
route matching or lifecycle changes only with explicit file boundaries.

### API-04 — body adapters and URL-encoded forms

Add logical-body `contiguous()`/`copyTo()` helpers and standard Reader support
for completed bodies. Add `urlencoded.parse(bytes, limits)` plus a media-type
checked request convenience. Segmented input is handled by a deliberate caller
copy, with the destination lifetime explicit. Copying is optional for already
contiguous payloads. Do not provision a second maximum-body buffer by default.

Gate APP-FORM checks raw pair semantics for fixed-length and chunked requests,
each split around separators and escapes, `BodyNotContiguous` then successful
explicit copy/parse, source/destination pointer ownership, field/count/body
bounds, empty bodies, malformed or ambiguous Content-Type, and independent query
and form keys with the same spelling. Unsupported encodings fail explicitly.
APP-STDIO-READER checks bounded body reads/EOF and that adapters do not consume
chunk framing/trailers or issue socket reads. Any span reader uses caller-bounded
scratch and has a defined insufficient-contiguous-read outcome.

Parser agent owns pure body/form/media-type helpers; parent owns wire fixtures
and public examples. No receive-streaming or transport work belongs here.

### API-05 — multipart without synthetic arrays

Implement a bounded contiguous multipart parser and flat Part iterator. Repeated
names/files remain repeated parts in wire order. Expose raw disposition metadata,
optional filename/media type, headers and payload slices, with explicit unquoting
into caller buffers. Use API-04's explicit body copy when HTTP chunks fragment
the payload. Publish the supported modern form-data profile and its limits.

Gate APP-MULTIPART includes repeated fields/files, one versus many uploads with
the same caller code, empty files, missing/empty filename, absent content type,
quoted boundary/metadata, binary NUL, boundary-like payload bytes, truncated or
missing final boundary, malformed/duplicate required metadata and exact/over
part-count/header/part-byte limits. Start with universal max_part_bytes; any
later field/file-specific bound needs an explicit classification policy.
Exercise all relevant HTTP-chunk and wire-fragment
splits. Validate adversarial boundary scan work against input/boundary limits.
Show that invalid terminal syntax is detected before the example commits form
side effects and that no upload is written to disk implicitly.

Parser agent owns multipart/metadata helpers and pure tests; parent owns upload
wire examples and integration. Keep contiguous public text slices simple; a
separate segmented parser is later work if measured copies justify it.

### API-06 — request locals, middleware and small web conveniences

Add optional typed request locals with explicit initialization and startup
storage accounting. Introduce a fixed ordered middleware chain with named
continue/respond behavior and endpoint/authentication wrappers. Hooks operate
on one request context, with no hidden parameter parsing or generic context bag.

The cookie/redirect slice is implemented: borrowed views, validated Set-Cookie,
explicit lifetime/scope, deletion and empty redirect helpers. The [guide](COOKIES.md)
records the source/fixture profile and session/JWT boundary. APP-COOKIES covers
codec/response/consumer tests and native HTTP/session gates.
Authentication policy/storage stays in application services. Include a fake
in-memory authenticator to demonstrate composition without requiring external
credentials or a database.

Gate APP-MIDDLEWARE checks ordering, early response, unauthorized/default error
behavior, typed local isolation across requests and concurrent connections,
malformed cookies as ordinary errors, repeated Set-Cookie wire lines, and
Location validation. Hooks may not introduce blocking logging on inline owners.
Define cancellation/reset behavior before adding scratch or resource-owning
locals; do not imply callback-complete means delivered-to-peer.

Parent owns composition/examples; lifecycle agent owns any slot-storage seam.
Parser helper work remains separately owned.

### API-07 — resumable endpoints and typed continuation state

Same-handler worker streaming now has a standard writer, explicit flush,
cancellation-aware sleep, and [native ownership gates](../reports/2026-09-06-streaming.md).
That linear API retains one fixed worker through each wait. The separate typed
continuation API is now implemented; [its guide](CONTINUATIONS.md) records the
flush/wait/finish contract. APP-RESUME native gates passed on Linux, macOS and Windows.
The design and gate requirements follow.

Expose an explicit advanced registration/handler shape using the current
request/flushed events and flush/finish/close actions. Keep route selection,
locals and authentication established once; resumptions enter the selected
continuation rather than replaying the initial middleware chain.

Provide checked size/alignment for typed continuation state and adapter metadata.
Start with the existing eight words only when a checked layout truly fits;
otherwise reserve a clearly configured slot region at startup. Do not identify
slots through undocumented pointer arithmetic. Optional scratch must be explicitly
bounded and remain separate from frozen output.

Gate APP-RESUME covers distinct generated/copied/borrowed bodies across depth-128
pipelines, partial sends, empty flush, multiple resumes, terminal finish with no
extra callback, cancellation between turns, error after first flush, same-slot
reuse, and stop while output is pending. Verify no middleware/side-effect replay,
no scratch borrow into pending output, no retained Context pointer, and zero
remaining application/kernel owners on clean shutdown. Preserve deadline values
across resumptions. Dynamic leases and background tasks remain a different gate.

Lifecycle agent owns state/adapter/server transitions; parent owns public
streaming example and integration. Transport agent reviews independently if
new completion paths are introduced.

### API-08 — migration examples and successor MVP qualification

The composition MVP is complete at merged Baz `c5f4be7`, with its exact native
[composition receipt](../reports/2026-09-07-composition.md). This reconciles the
original checklist; newer additions below still need their own qualification.

| Original checklist | Landed evidence / boundary |
| --- | --- |
| Independent package, pinned engine, MIT and Pages | Published; [dependency guide](DEPENDENCY.md) and [repository record](REPOSITORY.md). |
| App, endpoints, routing, raw parameters/forms/uploads, JSON | Supported example ports and [API receipt](../reports/2026-09-06-app-api.md). |
| Cookies, redirects, middleware, auth, locals | [Cookies](COOKIES.md), [middleware](MIDDLEWARE.md), native composition receipt. |
| Explicit resumable output | Worker streaming and typed continuations; native composition receipt. |
| Templating | Pure Zig Mustache fork; [native Mustache receipt](../reports/2026-09-06-mustache.md). |
| Blocking service example | Worker-only bounded CRUD endpoint. No general asynchronous outbound-service runtime is claimed. |
| Migration and deliberate differences | [Migration guide](APP-API.md#from-zap) and [example inventory](../examples/README.md). |
| Native verification | Exact Debug/ReleaseSafe Linux, macOS and Windows x64 receipts; Windows performance remains deferred. |
| Deliberate exclusions | TLS out of scope; WebSockets awaits engine upgrade lifecycle; custom std.Io deferred. These are not unfinished supported ports. |


Baz now imports the separate engine through its public `bounded_http` module.
The [dependency record](DEPENDENCY.md) documents the immutable URL/hash pin and upstream PR.
App, routing, forms, responses, examples, and application tests remain in Baz.
Engine framing, scheduling, transports, and core suites belong upstream.
The independent consumer imports both packages using one engine module identity.

The user selected the product name and package name on 2026-09-06.
Baz’s independent repository and GitHub Pages site are published.
Keep the original case-study history and port attribution available.
Future dependency updates require native Linux/macOS/Windows x64 verification of the selected revision.

Provide compiled examples for App + Shared + endpoint state, exact/captured
routes, raw query + explicit decoding, URL-encoded forms, one/many file uploads,
JSON output, cookies/redirects, middleware/authentication and explicit resumable
output. Include an explicitly selected worker example for a finite blocking
service. Use exact 0.16 APIs; do not copy stale Zap examples unchanged.

The migration guide maps `App.Create`, `register`, `getParamSlice`, `parseQuery`,
`parseBody`, typed parameter lists, `sendBody`/`sendJson`, authentication and
single/array uploads to the new API. Explain changed semantics with before/after
request data, particularly duplicates, raw escape spelling and copy lifetimes.
List unsupported old features and actual deployment limits.

Gate APP-NATIVE runs all relevant checks below on exact recorded native
Linux/macOS environments and the final source identity. Each advertised feature
must have its named gate passed. Keep the framework experimental until then;
passing this MVP gate is not arbitrary application isolation or full production
qualification. Record framework memory and optional controlled low-level versus
App comparisons separately from API correctness. Do not claim zero API overhead
without measurements or use old engine receipts as new App evidence.

## Response copy follow-up

The large-borrow fix separates `borrowBody` length from copied-body staging.
`server.max_response_bytes` bounds the borrowed span while pre-dispatch head/error
reservation stays small. `Response.finish` forms a staging slice only for
copied/generated bodies. Direct response users have an explicit
`Response.initWithLimit` constructor; App supplies the server limit.
The [large-borrow receipt](../reports/2026-09-06-large-borrow.md) records passing
native Linux, macOS, and Windows ownership gates for the PR.

Further copy reduction remains separate work:

1. Support the desired write/flush → borrow a large span → continue-streaming
   sequence through a future explicit stream operation. The current `borrowBody`
   only selects a whole response body and cannot provide this sequence. Consider
   direct generation into final output and synchronous borrowed stream writes. Any new lifetime/release API needs explicit cancellation and
   kernel-completion gates. Dynamic heap/pool leases are not implied by the
   immutable-asset path.
2. Make copy accounting comprehensive before publishing a total-copy claim or
   assessing an optimization. Preserve the original prototype performance data.

## Verification and shared-host protocol

Planning-only edits need source/link review and `git diff --check`; they do not
establish new Zig/runtime evidence. Every implementation step registers all new
Zig modules and examples in `zig build verify`, including instantiated generic
APIs. The current build formats `src`, `examples` and named build files, and
compiles all 21 port executables, the streaming example, and its wire fixture through `verify`.

Before heavy builds or runtime suites on maxross/omarx1, inspect existing
measurement processes and acquire `/tmp/zig-http-measurement.lock` atomically
on the execution host. Follow the wiki's
[full protocol](https://github.com/technologylab-ai/zigllmwiki/blob/362da3b8023e6918d4b72c046821334ebd3722ca/docs/platform-testing.md#cooperative-host-measurement-lock).
Hold off if busy, including incomplete/stale-looking metadata; never steal by
age. Record ownership, retain the reservation through child cleanup, and remove
only the owner's metadata/directory. Other agents' Mac measurements take
precedence while reserved. Windows performance remains deferred. Native Windows
correctness and publication gates are active following the merged engine sharding PR.

Baseline commands once the host is reserved and exact compiler is selected:

```sh
zig version
zig build verify -Doptimize=Debug
zig build verify -Doptimize=ReleaseSafe
zig build install examples -Doptimize=ReleaseSafe
python3 tests/app_integration.py
python3 tests/examples_integration.py
python3 tests/streaming_integration.py
```

The maintained App integration suite and all supported example ports now have
the invocations above. The required coverage includes wire framing,
fragmented progress, overload/recovery, deadlines, shutdown and changed ownership
paths. Use finite process watchdogs. Run the engine's comparator, core wire, and
smoke gates in its own repository when changing the engine. Documentation edits
do not require performance load.

Performance comparisons and their warmups must use ReleaseSafe, never Debug,
by explicit user decision on 2026-09-06. Keep assertions enabled and verify the
binary's build mode before timing; Debug is for correctness checks only.

Record compiler version, commit/source hash, architecture, OS/kernel, backend,
execution/shard configuration, assertions mode, command, results and skipped or
unavailable gates in a dated report. Separate compile evidence, native runtime
results, benchmarks, proposals and known limits. Do not promote a queued gate.

## Session ledger

Append a row after each session and update the milestone state above. A future
agent should be able to identify the next concrete change without reconstructing
the conversation.

| Date / session | Work completed | Validation | Next step |
| --- | --- | --- | --- |
| 2026-09-06: API planning | New `roadmap/app-api` worktree; inspected current engine and local Zap public API; used zig-wiki; specified modern framework, raw forms/uploads, response reservation and std.Io provider research. | Source review and document checks only; no Zig code added, builds/runtime suites/benchmarks not run. | API-01; independently design API-02 reservation and IO-01 compatibility matrix. |
| 2026-09-06: first implementation | API-01–05: typed App/router, raw request/form/multipart views, explicit codecs, reserved one-shot Response and standard memory I/O adapters. Core changes confined to response headers/reservation/copy accounting. Added 20 supported example ports and maintained wire harnesses. Parent owned integration/build/docs; parser, lifecycle and composition work had explicit agent file ownership. | [Native receipt](../reports/2026-09-06-app-api.md): Debug and ReleaseSafe, 51/51 steps on each host; Linux 194/194 test executions, Mac 190/194 with four Linux-only skips. Each host passed 14 App, 20 example, 84 core, 8 comparator checks and 30,000 exact smoke bodies. [63-file source identity](../reports/2026-09-06-app-api-source.sha256). | API-06 public middleware/locals/cookies; then API-07 resumable endpoints and API-08 extraction/remaining qualification. Caller std.Io remains; own provider deferred. |
| 2026-09-06: basic comparison | Isolated fixture using the public App API versus pinned Zig 0.16 Zap; ReleaseSafe only, c1/t1 and c32/t2, three alternating pairs per profile on each host. TLS excluded; Mustache postponed with a pure Zig shortlist; Windows waits for the engine session. | [Raw trials, results and cleanup](../reports/2026-09-06-basic-zap.md). All 24 measured trials completed with zero wrk socket/non-2xx-or-3xx errors. Owned server groups are gone and both host reservations released. Benchmark fixture remains separate from framework dependencies. | No benchmark is left running. Continue the API roadmap; reconcile incoming engine/docs changes before extraction. |
| 2026-09-06: Baz package extraction | Selected Baz (Bounded Async Zap), package/import `baz`. Removed copied engine sources and switched to URL/hash-pinned `bounded_http`. Added a separate consumer fixture and public draft/signal methods through [engine PR #1](https://github.com/technologylab-ai/bounded-http/pull/1). Reconciled current engine contracts and linked its repository/Pages site. | [Package receipt](../reports/2026-09-06-baz-extraction.md): native macOS/Linux, Debug and ReleaseSafe, 41/41 steps and 60/60 root tests per mode, independent consumers, 14 App and 20 example groups. [50-file source manifest](../reports/2026-09-06-baz-extraction-source.sha256.json). Engine gates passed separately. Prototype performance evidence remains unchanged and explicitly predates extraction. | API-06 public composition, then API-07 resumable endpoints. Merge/update the engine pin through the normal upstream process. Publish Baz's repository separately when requested. |
| 2026-09-06: standalone repository preparation | Created an independent local Baz repository with full reachable history, MIT license, public source links, and Linux/macOS CI. Moved engine-only working-tree material back to upstream references. Preserved the paused Windows changes on `work/windows-update`. | Git integrity and object independence, unchanged runtime/evidence bytes on `main`, local Markdown links, manifest formatting, actionlint, and CI installer syntax. No runtime gates restarted while the Windows update is paused. | Await the engine sharding PR for the draft branch. Publish Baz's GitHub repository when requested; continue API-06 independently. |
| 2026-09-06: Baz website and publication | Integrated the website worktree into Baz: landing page, ownership diagrams, source-backed App excerpt, 20 example links, prototype performance comparison, Markdown/source reader, and GitHub Pages workflow. User authorized publication in `technologylab-ai/baz`. | [Website receipt](../reports/2026-09-06-website.md): static checks, 14 browser groups, 58 documents, desktop/mobile/keyboard/print, and malicious-input checks. Runtime source, engine pin, and benchmark receipts unchanged. | Continue API-06. Windows dependency work still awaits the engine sharding PR and resumed Baz gates. |
| 2026-09-06: native Windows support | Integrated [bounded/http](https://technologylab-ai.github.io/bounded-http/) PR #2 through pin `7c240039`, portable exits and counted console borrows, native Windows harness control, and three finite App shard cases. Promoted pure Zig implementation and native Windows support in README/site alongside a prominent engine-site link. | [Native receipt](../reports/2026-09-06-windows-baz.md): candidate `6dcbf2d`, all three native hosts passed Debug/ReleaseSafe 41/41 root steps, 60/60 tests plus the consumer; 14 App and 20 example groups each, plus three Windows shard/shutdown cases. Original benchmark evidence unchanged. | API-06 public composition, then API-07. Windows x64 is supported; production/performance claims remain outside these correctness gates. |
| 2026-09-06: worker streaming | Added std.Io.Writer response streams, same-handler flushes, cancellation-aware sleep, and a runnable example beside App basics on the website. Engine seam submitted as PR #3 and pinned by immutable URL/hash. | [Streaming receipt](../reports/2026-09-06-streaming.md): native Linux/macOS/Windows, Debug and ReleaseSafe, 62 root tests and one consumer test per mode, 14 App, 20 ported-example, and 14 streaming groups per platform; Windows also passes three shard cases. Engine gates passed separately. | API-06 composition; typed inline continuations remain API-07. PR #3 is merged; future dependency updates retain the normal native gates. |
| 2026-09-06: large borrowed bodies | Decoupled borrowed size from staging capacity, retained explicit lifetime rules, and added a third website example using the compiled 5 MiB fixture. | [Native receipt](../reports/2026-09-06-large-borrow.md): all three platforms passed 68 root tests plus one consumer per mode, nine borrowed-body groups and existing App/example/streaming gates; Windows adds three shard cases. Website: 16 groups, 65 documents. | Review/merge Baz PR #1. Direct generation and dynamic leases remain separate copy-reduction work. |

For each implementation session add: commit(s), owned/changed files, decisions,
named gates passed/pending and exact receipts, remaining blocker (if any), and
the next bounded task. Refresh [HANDOFF.md](../HANDOFF.md) briefly when this track
becomes the active implementation. Keep historical engine evidence intact.


### API-09 — bounded Mustache pages

The user prioritized templating over the other open features. The first slice
uses the [pure Zig library selection](MUSTACHE-CANDIDATES.md), immutable startup
owners, explicit partial sources, and `Response.mustache` into private output
storage. There is no rendered-string allocation or extra scratch-body copy;
the existing publication compaction remains. See [the guide](MUSTACHE.md).

APP-MUSTACHE requires Debug/ReleaseSafe wrapper and response tests, an independent
package consumer, all 136 official core cases and original Zap array/slice/partial
outputs, plus 12 native HTTP groups on Linux/macOS/Windows. Output overflow,
empty-output work exhaustion, partial cycles, parser nesting/path limits,
concurrent template reuse, terminal ownership, and no framework allocation after
startup are separate checks. Template startup storage is an explicit application
allocation outside the engine's heap statistics. Lambdas, inheritance, dynamic
partials and implicit filesystem lookup remain outside this slice.


| Session | Completed work | Evidence | Next |
| --- | --- | --- | --- |
| 2026-09-06: Mustache pages | API-09: pure Zig fork, bounded cached rendering, startup owners, reserved HTML response helper, concise real page and partial, documentation/preview. Dependency PR #1 and Baz PR #3 merged in order. | [Native receipt](../reports/2026-09-06-mustache.md): 136 core cases at two capacities, four Zap cases, 346 library tests; Baz 90 root/two consumer tests per mode, 12 Mustache groups and existing suites on Linux/macOS/Windows. Five example-browser and 17 site-browser groups. | API-06 composition; retain fork ownership and explicit template limits. |
| 2026-09-07: composition and continuations | Public middleware/locals, reusable sessions with expiry and revocation, typed start/resume handlers and bounded retained storage. | [Composition receipt](../reports/2026-09-07-composition.md): Debug/ReleaseSafe, 161 root and five consumer tests per mode on Linux/macOS/Windows; 15 middleware, 17 session, 20 continuation and all existing wire groups. | APP-MIDDLEWARE and APP-RESUME passed; own std.Io remains deferred. |
