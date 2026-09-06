# Unmeasured reproducer revision

This runner is a cleanup-only revision of the runner in `../fixture.tar.gz`.
It did not produce the published throughput numbers. The measured archive,
its SHA-256 and every original macOS/Linux receipt remain unchanged.

For a future comparison, extract the measured archive into a new directory and
copy this `runner.py` over the extracted `basic-zap/runner.py`. The fixtures,
build graph, ReleaseSafe guards, preflight checks and workload are unchanged.
Follow `../PROTOCOL.md`; the runner must acquire a fresh measurement reservation
or validate a supplied token for an existing coordinated reservation.

The revision waits for the original process group to disappear, including when
its leader exits first. TERM and KILL have separate finite deadlines. Permission
errors do not prove disappearance. Uncertain ownership stays registered, cleanup
failure keeps the reservation, and repeated cleanup does not signal a discharged
numeric PGID. This controls descendants that remain in the original group; it
does not provide containment for processes that deliberately escape the group.

`complete` starts false and is published true only after the workload, process
cleanup and release of an owned reservation succeed. An external reservation is
left untouched. Cleanup errors and remaining original PGIDs are written to the
summary; the CLI reports failure. Cleanup continues through all registered
children when one cleanup fails. Repeated INT/TERM signals cannot interrupt the
bounded final reconciliation.

Validation is synthetic and macOS-only. Run `python3 -B test_cleanup.py` from
this directory. Its 30-second suite watchdog covers ten small subprocess and
fault-injection checks; it does not build Zig, start HTTP servers or invoke wrk.
The passed log, initial failure and source hashes are retained beside this file.
The initial test run observed EPERM during process-group exit; the final revision
treats that as uncertain existence and keeps polling until disappearance or the
cleanup deadline. No benchmark was repeated for this revision.
