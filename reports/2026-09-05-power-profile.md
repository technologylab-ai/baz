# Linux depth sweep with recorded performance profile — 2026-09-05

With the user's performance power profile in effect, Zig measured **1.74–1.92M
responses/s** across client depths 16–128; libreactor measured **4.30–13.63M**.
The fixed server batch limit remains 16. The higher observed rates do not remove
the substantial gap or prove how much the power-profile change contributed:
the preceding runs did not capture their profile/EPP, and the desktop was not
isolated. Preserve [those earlier observations](2026-09-05-batch.md).

## Exact input and environment

Measured source commit: **bda54040bb0b809c82824b87a782e96826f05dff**, exact Zig
**0.16.0 ReleaseSafe**, assertions enabled. The server's Zig source is unchanged
from 5620905193e496af1c4b297a576c4fe7edd6c4a9. This checkpoint adds power-state
capture/profile enforcement to the maintained comparator and fixes preparation
to launch the current inline/zero-worker default explicitly.

Linux omarx1: Intel Core Ultra 7 258V, eight logical CPUs, x86_64 Omarchy 4.0.2,
kernel 7.1.9-arch1-2, glibc 2.44, GCC 16.2.1 20260810, io_uring_disabled=0.
The fresh isolated preparation at `/tmp/zig-http-compare.1FQK18` completed all
67 pinned preparation commands with two build jobs. The maintained recipe,
exact pins, hashes and logs accompany [the packet](2026-09-05-power-profile/packet.json).
No Linux build overlapped timed load; no machine power setting was changed by
the harness or this agent.

| Binary | SHA-256 |
| --- | --- |
| zig-http | `8352eb4e11a272bdf95438bcf0d4b9214d8c2bf95a9ebb0cda22208f8842d73f` |
| libreactor | `28a29517c5864a16e62a50b05121a7b8bceaea779cdc861712677e4fc2e67624` |
| wrk | `ec4ba590234163a893cb99b2c0874219e9672408d3e52b2851b1f4868ac78658` |

The preparation manifest SHA-256 is
`f218ce331e9fc9be7c1246128bbc1d9a1913d7760f284717ccf19dd68e8481c6`.
Pinned source and workload differences remain as disclosed in
[the initial comparison](2026-09-05-comparison.md). This sweep includes Zig and
libreactor only. The prepared mrhttp command still uses three workers/CPUs 0–2,
so it was excluded from this one-core experiment.

## Workload and results

Run: **18:36:38–18:39:38 UTC**. Both servers were restricted to CPU0: Zig had
one I/O/handler thread and no application workers; libreactor had one serving
child plus its idle parent. Four wrk threads used CPUs 3–7. Each configuration
used 128 connections, three shuffled repetitions, seed 20260905, one-second
warmup and five-second measurement. Client depths were 16, 32, 64 and 128.
Every trial preflight verified two full pipelines of exact `Hello, World!`
bodies, framing, Server and advancing Date. Timed wrk checks parsing/status and
transport errors, not every body byte. It already counts responses; never
multiply its response rate by pipeline depth.

| Client depth | Zig median responses/s (min–max) | libreactor median (min–max) |
| --- | ---: | ---: |
| 16 | 1,745,599 (1,649,155–1,842,546) | 4,298,496 (4,295,876–4,323,170) |
| 32 | 1,742,345 (1,629,794–1,769,123) | 7,263,306 (7,260,947–7,389,032) |
| 64 | 1,918,780 (1,889,912–1,936,787) | 10,938,293 (10,832,169–11,027,781) |
| 128 | 1,922,797 (1,915,961–1,926,582) | 13,627,467 (10,302,756–14,755,787) |

All **24 trials and warmups passed**, with **643,222,112 timed responses**,
**2,880 exact preflight responses**, and zero reported transport/status errors.
All Zig trials ended with zero connection/operation owners, late allocations,
timeouts and refusals. Observed batch/callback maxima stayed 16/64; every send
held at most 32 spans/2,512 bytes. Requested framework heap peaked at
29,618,632 bytes; that excludes kernel, libc/pthread, application and allocator
overhead and is not an RSS cap. Whole-session counters include warmup/preflight.

Suffix-copy totals were zero at depth 16, 247–264 MB at 32, 840–859 MB at 64 and
1.98–2.02 GB at 128. These totals rise with both depth and completed work. The
depth-16 gap already occurs without compaction; copying alone cannot explain
the whole gap. The 16-response send boundary still holds at every client depth.

## Power observations and measurement limits

The initial snapshot and all 48 before/after trial snapshots report
`powerprofilesctl get = performance`. All eight CPU policies report EPP
`performance`, driver `intel_pstate` and governor `powersave`; these are separate
observed controls. Turbo was permitted (`no_turbo=0`, min/max performance
percentages 8/100). CPU0 limits were 400,000–4,800,000 kHz. Its untimed endpoint
current-frequency samples ranged from 399,665 to 4,689,268 kHz. They are neither
average active clocks nor evidence of frequency residency during the trial.

The harness rejects a missing or mismatched expected profile. Endpoint checks
cannot detect a transient change that reverses between observations. Earlier
runs recorded a governor label but not profile/EPP: do not call them balanced,
powersaver or a controlled baseline for a power-profile speedup. Both servers
are faster in this new run, but this comparison does not isolate the cause.

Approximate outer-interval server CPU ranged 79–84% for Zig and 62–83% for
libreactor; client CPU ranged 78–107% and 207–314% respectively. These counters
are not cycles/request. Affinity is not CPU reservation, loopback shares the
host with the generator, and libreactor's depth-128 range remains broad.
No profiler was run. The pinned wrk corrected-percentile defect still prevents
using its raw percentile output for request-tail claims. Deeper pipelines are
a different workload from the usual depth-16 comparison, and none is an official
TechEmpower score or production capacity guarantee.

## Correctness and host coordination

Before the sweep, the exact archived commit passed native Linux ReleaseSafe
verification: **14/14 build steps, 52/52 test executions**, installed build,
**22/22 batch wire cases** and **5/5 comparator tests**. The new comparator test
requires rejection when a configured power profile changes or disappears.
Mac/Linux's previous full Debug/ReleaseSafe and ownership gates remain recorded
at their exact checkpoints in the batching report; this sweep itself adds no
Mac timing, Windows HTTP or portable `std.Io` guarantee.

The user requested a cooperative host lock while another agent measures on the
Mac. Use `/tmp/zig-http-measurement.lock` on each host, acquired atomically with
mkdir, with owner/PID/token/purpose metadata in owner.json. A lock's existence
means hold off on benchmarks/heavy builds/runtime suites; retain it through
child cleanup and remove only your own reservation. Do not steal by age alone.
This Linux sweep had already begun when the protocol was requested, so initial
trials predate its acquisition at 18:37:33 UTC. The owner released it only after
the comparison and every owned server/client process stopped. This is
cooperative exclusion, not isolation or proof that all other tools honor it.

Windows measurements/publication runs are deferred by user decision during the
current Mac/Linux HTTP tuning loop. Mac work also waits for the other agent's
measurement reservation/processes. Token-addressed operations and the proposed
batch16/64 × callback64/256 experiment remain queued; no runtime architecture
change is part of this power-state measurement checkpoint.
