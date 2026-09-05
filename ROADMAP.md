# HTTP experiment roadmap

The current deliverable is a working Linux/macOS MVP to iterate on ownership and
pending/resume. This is a separate project from the evidence wiki.

| Item | State | Boundary |
| --- | --- | --- |
| Fixed startup ownership model | done | One I/O owner, fixed application workers, one request per connection, finite mailboxes and operation/cancel storage. |
| HTTP/1.1 parser and reference routes | done | Bounded framing, lazy optional headers, borrowed bodies, plaintext, preloaded HTML, echo and flush/resume. |
| Linux and macOS runtime slice | done | io_uring and kqueue, Debug/ReleaseSafe unit tests and hostile wire/ownership integration; final receipt records environments. |
| Experiment API | queued | Compare explicit continuations with alternatives; add finish/cancel release notifications for dynamic leases, then consider arbitrary app task integration. |
| Scheduling/copy improvements | in progress | Inline and gathered output are implemented and measured; bounded response cells/deferred compaction pass Mac ownership gates; Linux measurement is next. Constant-time lookup and I/O sharding remain separate experiments; preserve assertions and ownership gates. |
| Reliability qualification | queued | More deterministic fault/schedule injection, long mixed maximum-load runs, syscall failure catalog, full process/kernel resource accounting and shutdown diagnostics. |
| Windows HTTP adapter | queued | Implement IOCP and use hosted Windows runtime gates; no Windows server implementation or runtime is claimed today. |
| Comparative performance | partial | Pinned Linux mrhttp/libreactor comparison: 54 main + 18 client-sensitivity trials; inline and gather A/B sweeps preserved separately. Remaining: batch results, HTML/Mac comparisons, dedicated-host/NIC saturation and qualified request tails; wrk corrected percentiles were rejected. |
| Higher-level features | queued | TLS boundary, routing/middleware, upload protocol and application state APIs after the core experiment. |

The wiki's M3-006 Windows deployment qualification stays postponed by user
decision. It is distinct from this project's future Windows HTTP adapter.
