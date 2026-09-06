# HTTP experiment roadmap

The current deliverable is a working Linux/macOS MVP to iterate on ownership and
pending/resume. This is a separate project from the evidence wiki.

| Item | State | Boundary |
| --- | --- | --- |
| Fixed startup ownership model | done | One I/O owner per shard, default inline/zero workers or explicit startup workers, one callback per connection with bounded retained response cells, finite mailboxes and operation/cancel storage. |
| HTTP/1.1 parser and reference routes | done | Bounded framing, lazy optional headers, borrowed bodies, plaintext, preloaded HTML, echo and flush/resume. |
| Linux and macOS runtime slice | done | io_uring and kqueue, Debug/ReleaseSafe unit tests and hostile wire/ownership integration; final receipt records environments. |
| Experiment API | queued | Compare explicit continuations with alternatives; add finish/cancel release notifications for dynamic leases, then consider arbitrary app task integration. |
| Scheduling/copy improvements | partial | Direct Linux operation cells and configurable batch/callback budgets were measured on the pre-arena implementation (reports/2026-09-05-operation-cells.md, reports/2026-09-05-batch-quantum.md). The adopted arena/shard base (reports/2026-09-05-arena-adoption.md; original reference report preserved) supersedes them: output arena with heads written at begin, ready-ring scheduler, lane-scanning parser, cell-addressed transport with caller-owned vectors, and a reuse-port shard cluster, gated on Mac/Linux. Adoption hardens worker cache ownership, prearmed EOF/interim ordering, partial startup and secondary-shard failure, with exact coordinator/stack accounting. Remaining: profiled per-request efficiency at one core (parser attribution unproven), SINGLE_ISSUER/DEFER_TASKRUN ring modes, macOS shard distribution. |
| Reliability qualification | queued | Startup-failure and forced completion-order witnesses now exist. Remaining: broader deterministic fault/schedule injection, long mixed maximum-load runs, syscall failure catalog, full process/kernel resource accounting and shutdown diagnostics. |
| Windows HTTP adapter | queued | Implement IOCP and use hosted Windows runtime gates; no Windows server implementation or runtime is claimed today. |
| Comparative performance | partial | Pinned Linux mrhttp/libreactor comparison: 54 main + 18 client-sensitivity trials; inline and gather A/B sweeps preserved separately. Batch1/16 and one-core comparisons are complete; client depths32/64/128 and a separate recorded-performance-profile sweep are complete. Preserve the unresolved fixed-batch gap and prior unknown-profile observations. The integrated arena/shard candidate adds36 qualified Linux trials: three-core Zig/libreactor median ratios0.957/0.909/0.860 at depths1/16/128, one-core1.106/0.778/0.596; raw ranges and ownership checks retained. Remaining: HTML/Mac comparisons, dedicated-host/NIC saturation and qualified request tails; wrk corrected percentiles were rejected. |
| Modern application framework | planned | New-name Zap successor on Zig 0.16.0 and this engine: typed App/endpoints, raw parameters, explicit decoding, flat uploads and bounded responses. Design and staged gates: [App API roadmap](docs/APP-API-ROADMAP.md). |
| Framework-owned std.Io | research planned | Current HTTP uses custom io_uring/kqueue adapters, not a std.Io provider. [Exploration and prototype gates](docs/STD-IO-DECISION.md) cover a bounded optional runtime, service I/O and task/cancellation ownership. |
| Higher-level features | queued | TLS boundary, routing/middleware, upload protocol and application state APIs after the core experiment. |

The wiki's M3-006 Windows deployment qualification stays postponed by user
decision. It is distinct from this project's future Windows HTTP adapter.

Current cadence: macOS correctness and Linux runtime/performance, with Windows
publication runs deferred by user decision during HTTP tuning. Coordinate host
load via `/tmp/zig-http-measurement.lock`; another agent also measures on the Mac.
The performance-profile sweep is complete; no queued architecture experiment is
an active agent or runner.
