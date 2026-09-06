# Basic Zap/App comparison

This package is an indicative local-loopback throughput comparison, not a
capacity, latency, SLO or production assessment. The client shares the machine
with each server and can constrain the result. Do not infer bottleneck causes
from the request-rate numbers.

Use exact Zig 0.16.0 and `zig build verify -Doptimize=ReleaseSafe
-Dframework-root=/absolute/frozen/zig-http`. The verify target compiles every
new fixture Zig source and the build graph. No framework sources are modified.
`deps/zap` is an unmodified git archive of
`f6099ecec496c7ec623c5913baa5b6b5da2e883d` from the user's Zig 0.16 Zap port.
The inherited facil.io build uses no TLS and C flags `-Os`,
`-Wno-return-type-c-linkage`, `-fno-sanitize=undefined`,
`-DFIO_HTTP_EXACT_LOGGING` (and `-D_LARGEFILE64_SOURCE` for musl only).
Zig assertions remain enabled; the inherited C sanitizer exclusion is recorded,
not claimed equivalent to Zig safety instrumentation.

Both serve `GET /plaintext`: status 200, Content-Type text/plain, exactly
13 bytes `Hello, World!`. No request logging. App uses its public one-shot
Response.bytes API, its normal defaults apart from one inline I/O shard,
zero application workers and 128 connection slots. Zap uses Request.setContentType
and sendBody with a method/path check, max_clients=128, threads=1, workers=1.
These settings do not imply equal process/thread models; the runner records
actual processes and threads. HTTP response headers and internal defaults may
differ. The negative-route preflight checks 404 and 405 separately.

Before builds and runtime, acquire `/tmp/zig-http-measurement.lock` by atomic
mkdir and inspect existing measurement processes. The runner does this for
itself, or validates the supplied `--lock-token` of an existing coordinated
reservation and leaves that reservation untouched. The measured runner used finite process watchdogs and group termination;
actual cleanup is recorded separately in the receipts. For future runs, the
unmeasured `reproducer/runner.py` revision waits for original groups to disappear
before reporting completion or releasing its own reservation. The measured
archive remains unchanged; see `reproducer/README.md`.
An unrelated live benchmark makes the runner stop. A busy lock is never stolen.

Run `python3 runner.py --framework-root /absolute/frozen/tree --wrk /path/to/wrk
--output /absolute/receipts` (optional `--lock-token TOKEN` for an existing lock).
The runner records exact build and client commands, compiler/client versions,
platform/CPU/power-policy metadata, source and binary SHA-256, original server
logs, process/thread layouts, preflight records and full raw wrk output.

For c1/t1 then c32/t2, run three paired repetitions of App and Zap. Restart the
server for each trial. Both fixtures must pass the mode and exact-wire preflight
before any warmup or timing begins. Each trial repeats its preflight, one-second wrk
warmup, then a three-second wrk measurement. Alternate first contender in
successive pairs across the whole sequence: App/Zap, Zap/App, App/Zap,
Zap/App, App/Zap, Zap/App. No client HTTP pipelining or custom Lua script.
Require status 200 in exact-wire preflight. Reject a nonzero wrk
`Non-2xx or 3xx responses` counter, nonzero socket errors, missing request counts,
failed processes or watchdog expiry; preserve failures. That wrk counter does
not reject 3xx responses; these fixed fixture handlers contain no redirect path. Report request counts and
requests/second for each trial, per-contender median RPS and App/Zap ratio of
medians. Raw wrk latency output is retained solely as an unendorsed raw receipt;
it does not establish request latency or tail percentiles.
