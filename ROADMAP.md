# HTTP experiment roadmap

The current deliverable is a working Linux/macOS MVP to iterate on ownership and
pending/resume. This is a separate project from the evidence wiki.

| Item | State | Boundary |
| --- | --- | --- |
| Fixed startup ownership model | done | One I/O owner, default inline/zero workers or explicit startup workers, one callback per connection with bounded retained response cells, finite mailboxes and operation/cancel storage. |
| HTTP/1.1 parser and reference routes | done | Bounded framing, lazy optional headers, borrowed bodies, plaintext, preloaded HTML, echo and flush/resume. |
| Linux and macOS runtime slice | done | io_uring and kqueue, Debug/ReleaseSafe unit tests and hostile wire/ownership integration; final receipt records environments. |
| Experiment API | queued | Compare explicit continuations with alternatives; add finish/cancel release notifications for dynamic leases, then consider arbitrary app task integration. |
| Scheduling/copy improvements | running | Direct Linux operation addressing is complete: Mac/Linux native gates and48 paired trials passed; see operation-cell report. Batch/callback-limit experiment source is checkpointed on perf/batch-quantum; its handoff owns pending native/timing gates. Output representation and sharding remain separate experiments. |
| Reliability qualification | queued | More deterministic fault/schedule injection, long mixed maximum-load runs, syscall failure catalog, full process/kernel resource accounting and shutdown diagnostics. |
| Windows HTTP adapter | queued | Implement IOCP and use hosted Windows runtime gates; no Windows server implementation or runtime is claimed today. |
| Comparative performance | partial | Pinned Linux mrhttp/libreactor comparison: 54 main + 18 client-sensitivity trials; inline and gather A/B sweeps preserved separately. Batch1/16 and one-core comparisons are complete; client depths32/64/128 and a separate recorded-performance-profile sweep are complete. Preserve the unresolved fixed-batch gap and prior unknown-profile observations. Remaining: HTML/Mac comparisons, dedicated-host/NIC saturation and qualified request tails; wrk corrected percentiles were rejected. |
| Higher-level features | queued | TLS boundary, routing/middleware, upload protocol and application state APIs after the core experiment. |

The wiki's M3-006 Windows deployment qualification stays postponed by user
decision. It is distinct from this project's future Windows HTTP adapter.

Current cadence: macOS correctness and Linux runtime/performance, with Windows
publication runs deferred by user decision during HTTP tuning. Coordinate host
load via `/tmp/zig-http-measurement.lock`; another agent also measures on the Mac.
The performance-profile sweep is complete; no queued architecture experiment is
an active agent or runner.
