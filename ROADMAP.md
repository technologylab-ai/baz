# HTTP experiment roadmap

The current deliverable is a working Linux/macOS MVP to iterate on ownership and
pending/resume. This is a separate project from the evidence wiki.

| Item | State | Boundary |
| --- | --- | --- |
| Fixed startup ownership model | done | One I/O owner, fixed application workers, one request per connection, finite mailboxes and operation/cancel storage. |
| HTTP/1.1 parser and reference routes | done | Bounded framing, lazy optional headers, borrowed bodies, plaintext, preloaded HTML, echo and flush/resume. |
| Linux and macOS runtime slice | done | io_uring and kqueue, Debug/ReleaseSafe unit tests and hostile wire/ownership integration; final receipt records environments. |
| Experiment API | queued | Compare explicit continuations with alternatives; add finish/cancel release notifications for dynamic leases, then consider arbitrary app task integration. |
| Scheduling/copy improvements | queued | Replace pipeline compaction, measure batching/lookup costs, consider worker scheduling/sharding; keep correctness and ownership checks. |
| Reliability qualification | queued | More deterministic fault/schedule injection, long mixed maximum-load runs, syscall failure catalog, full process/kernel resource accounting and shutdown diagnostics. |
| Windows HTTP adapter | queued | Implement IOCP and use hosted Windows runtime gates; no Windows server implementation or runtime is claimed today. |
| Comparative performance | queued | Pin selected leading implementations and load generator, run ReleaseSafe-equivalent correctness under identical hardware/OS/workload, measure repeatable saturation and tails. Python smoke is not this gate. |
| Higher-level features | queued | TLS boundary, routing/middleware, upload protocol and application state APIs after the core experiment. |

The wiki's M3-006 Windows deployment qualification stays postponed by user
decision. It is distinct from this project's future Windows HTTP adapter.
