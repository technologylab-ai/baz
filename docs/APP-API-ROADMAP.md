# Modern Zap successor: implementation roadmap

Status: first implementation and supported example ports, 2026-09-06.
Exact target: Zig 0.16.0. See the [implemented API](APP-API.md),
[20 example ports](../examples/README.md), and
[native receipt](../reports/2026-09-06-app-api.md) for exact evidence and limits.

Build a framework with a new name, Zap's typed App/endpoint ergonomics, sane
borrowed-byte request APIs, modern Zig capabilities, and zig-http underneath.
The detailed API decisions are in [APP-API-DESIGN.md](APP-API-DESIGN.md).
[STD-IO-DECISION.md](STD-IO-DECISION.md) evaluates supplying our own std.Io.
This track complements the [engine roadmap](../ROADMAP.md); it does not replace
the engine's unfinished reliability, performance or platform work.

## Resume here

- Worktree: `/Users/rs/code/github.com/technologylab.ai/zig-http-app-api`.
- Branch: `roadmap/app-api`.
- Starting engine commit: `4b3cd5551d80b422ec6ef763627d019e6f1dfb83`.
- Reviewed Zap port: `../fi/deps/zap` at
  `f6099ecec496c7ec623c5913baa5b6b5da2e883d` (its own Git repository).
- API-01–05 are implemented as the first bounded one-shot slice. Twenty of the
  23 original example targets are ported/adapted, with explicit differences.
  TLS is out of scope; WebSockets needs upgrade support; Mustache is postponed
  pending a [pure Zig library evaluation](MUSTACHE-CANDIDATES.md).
- Next bounded work: finish API-06's public composition/locals/cookie contract,
  using the example-local wrappers as real use cases; then API-07 and extraction.
  IO-01–04 remains deferred until after the first API MVP by user decision.
- Consult the receipt/session ledger for native gates and cleanup state. The
  separate [basic Zap comparison](../reports/2026-09-06-basic-zap.md) records
  native ReleaseSafe results at 1 and 32 connections; it does not isolate API
  overhead or establish capacity.
- Other agents are writing architecture documentation in separate worktrees.
  Reconcile their landed docs/current engine contracts before the next session;
  preserve this plan's baseline and re-evaluate changed ownership assumptions.

Use `git worktree list` to locate the branch if the local directory changes.
Read AGENTS.md, the current ownership contract and the two design documents.
Inspect Git state before editing; do not overwrite another session's work.

## Decisions carried forward

| Topic | Working decision |
| --- | --- |
| Product | New name and public module; modern successor, no Zap source-compatibility layer. Prototype here, then extract into its own repository with a pinned zig-http dependency. zig-http remains a standalone engine/case study (user direction, 2026-09-06). |
| Platform/version | Exact Zig 0.16.0; initial plain HTTP/1.1 on the existing Linux/macOS engine. Public bind addresses need later qualification. TLS is out of scope. |
| Windows | Await the other session's engine support on main before adding framework compilation/CI checks; no Windows work in this checkpoint (user correction, 2026-09-06). |
| App | Real instances; typed Shared; borrowed endpoint instances; startup-only registration; one routing/context model. |
| Input | Raw immutable slices, ordered duplicates, no coercion, no bracket-array syntax, no merged query/body/JSON bag. |
| Decoding | Explicit caller destination; percent and form-plus decoding are separately named; raw bytes remain available. |
| Bodies/forms | Contiguous form parsers; explicit logical-body copy for segmented input. Flat multipart Part iterator. No implicit disk writes or receive streaming. |
| Responses | Easy one-shot handlers with capacity secured before execution; explicit advanced resumable handlers. Never replay application side effects. |
| std.Io now | Inject caller capabilities; standard bounded Reader/Writer interoperability; explicit workers for blocking services. |
| std.Io provider | IO-01–04 deferred until after the first API MVP by user decision (2026-09-06); an optional bounded cooperative provider remains a candidate. |
| Memory | Framework storage reserved at startup; fixed buffers/reservations and optional bounded locals/scratch, no growable request arena or hidden heap fallback. |
| Ownership | Input/output/task borrows survive until their real terminal transitions; scratch cannot become a dynamic output borrow without a later lease protocol. |

Names and spellings in the design are provisional. These semantic decisions can
change with evidence or user direction; record a short dated decision when they
do. Do not wait for naming decisions to implement the first vertical slice.

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
| API-06 | queued | Typed locals, middleware, authentication composition, cookies and redirects. | API-02, API-03 | APP-MIDDLEWARE |
| API-07 | queued | Typed explicit resumable endpoints and retention rules. | API-03, API-06 | APP-RESUME |
| API-08 | partial: 20 examples ported | Finish public migration examples, package naming/extraction and native successor MVP qualification. | API-01–07 | APP-NATIVE |
| IO-01–04 | deferred | Owned std.Io feasibility, isolated prototype, HTTP integration and adoption decision. | First API MVP; see STD-IO-DECISION | STDIO-PROTOTYPE, STDIO-HTTP-OWNERSHIP, STDIO-ADOPTION |

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

Provide raw cookie iteration plus bounded validated Set-Cookie and redirect
helpers on API-02 headers. Request cookie parsing does not apply URL decoding
by default; cookie semantics need their own source/fixture review at this step.
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

Choose the project/module name and extract the framework into its own repository
with a pinned zig-http dependency. The user wants zig-http to remain the first
standalone case study; this framework takes the next step. Current development
imports engine sources inside this worktree, and `http_app` / `bounded_http`
temporarily share one module identity. This is not yet an external dependency.

Land the independently useful engine changes (pre-dispatch output reservation,
transactional custom headers and copy accounting) in zig-http with their core
tests. Move App, routing, request/form/multipart conveniences, Response, examples
and their tests to the new repository. Replace relative engine source imports
with the exported `bounded_http` package surface, make any signal/ownership seam
explicit, and pin the qualified engine commit in `build.zig.zon`. Do not copy
and maintain a private fork of the engine. Verify both repositories independently
on native Linux/macOS; exercise importing the raw engine and framework together
without duplicate type identities. Record license/source attribution for the
ported examples and keep the case-study history intact.

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

## Verification and shared-host protocol

Planning-only edits need source/link review and `git diff --check`; they do not
establish new Zig/runtime evidence. Every implementation step registers all new
Zig modules and examples in `zig build verify`, including instantiated generic
APIs. The current build formats `src`, `examples` and named build files, and
compiles all 20 port executables through `verify`.

Before heavy builds or runtime suites on maxross/omarx1, inspect existing
measurement processes and acquire `/tmp/zig-http-measurement.lock` atomically
on the execution host. Follow the wiki's
[full protocol](../../zigllmwiki/docs/platform-testing.md#cooperative-host-measurement-lock).
Hold off if busy, including incomplete/stale-looking metadata; never steal by
age. Record ownership, retain the reservation through child cleanup, and remove
only the owner's metadata/directory. Other agents' Mac measurements take
precedence while reserved. No Windows performance/publication runs during the
current Linux/macOS tuning loop.

Baseline commands once the host is reserved and exact compiler is selected:

```sh
zig version
zig build verify -Doptimize=Debug
zig build verify -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseSafe
python3 tests/integration.py --server zig-out/bin/zig-http
python3 tests/inline_integration.py
python3 tests/gather_integration.py
python3 tests/batch_integration.py
python3 tests/arena_lifecycle_integration.py
zig build examples -Doptimize=ReleaseSafe
python3 tests/app_integration.py
python3 tests/examples_integration.py
```

The maintained App integration suite and all supported example ports now have
the invocations above. The required coverage includes wire framing,
fragmented progress, overload/recovery, deadlines, shutdown and changed ownership
paths. Use finite process watchdogs. Retain existing comparator/smoke gates for
native publication where required by the current engine runbook; do not run
performance load merely to validate a documentation edit.

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

For each implementation session add: commit(s), owned/changed files, decisions,
named gates passed/pending and exact receipts, remaining blocker (if any), and
the next bounded task. Refresh [HANDOFF.md](../HANDOFF.md) briefly when this track
becomes the active implementation. Keep historical engine evidence intact.
