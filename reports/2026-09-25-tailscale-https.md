# HTTPS through `tailscale serve`

Status: the `tailscale_https` example passed local correctness gates and a live
tailnet check on `examples/https-tailscale`, based on Baz `2258ff87c668`.
Exact Zig: 0.16.0. Correctness builds only; no performance measurements.

## Environment

omarx1: Linux 7.2.5 x86_64 (Omarchy), io_uring backend, Tailscale 1.102.3,
Chromium 152.0.7977.82, node 26.7.0. The Tailscale operator is the local user,
so `tailscale serve` ran without elevation. HTTPS certificates are enabled for the tailnet.

## Repository gates

- `zig build verify` (Debug): 71/71 steps, 244/244 tests.
- `zig build install examples -Doptimize=ReleaseSafe`, then
  `tests/examples_integration.py`: 23 groups pass, including the new
  `tailscale_https` group (missing and wrong login → 403, identity locals in
  `/whoami`, page, `/events` resumed after `Last-Event-ID: 41` with ids 42–51 and a
  clean chunked end, malformed and overflowing `Last-Event-ID` → 400).
- `tests/cli_integration.py`: 392 checks across 32 executables, including
  `--tick-ms=0` → `InvalidLifetime` and a rejected `--bind-address`.
- `tools/build_pages.py`: static checks passed (27 examples; 155 files, 112 documents).
  `tools/check_site_browser.mjs` in Chromium 152: 28/28 checks, the same as an
  unchanged `origin/main` worktree built and checked the same way.

## Live tailnet check

The ReleaseSafe example ran on `127.0.0.1:18943` with `--login` set to the
operator's login and was published with
`tailscale serve --bg --https=9443 http://127.0.0.1:18943`.

| Check | Result |
| --- | --- |
| `GET /whoami` through `https://omarx1.<tailnet>.ts.net:9443` | 200, login and name from Tailscale identity headers |
| Same request with a forged `Tailscale-User-Login: evil@x` | 200 with the **real** login: serve replaced the header |
| Loopback, no identity header | 403 |
| Loopback, wrong login | 403 |
| First HTTPS request | 9 ms: this node already held a certificate from earlier use, so the first-issue delay (~30 s, observed on the same node on 2026-09-25) did not recur |
| SSE through serve, fresh connection, 3 runs | 10 ticks each, clean end (curl exit 0) |
| Chromium via DevTools protocol, 24 s on the page | Signed-in name shown; ticks 2 → 21 continued across 3 connections (reconnects at the ten-tick boundaries, resumed with `Last-Event-ID`) |

Afterwards `tailscale serve --https=9443 off` restored an empty serve
configuration and the example stopped with its terminal STATS.

## Finding: idle keep-alive time counts toward the next deadline

A stream that started on a pooled backend connection ended early and without its
final chunk (curl exit 92). Controlled runs through serve, `timeout_ms` 15000:

| Idle before the stream | Ticks of 10 | Ended after |
| --- | --- | --- |
| 0 s | 10 | 10.1 s, clean |
| 8 s | 6 | 7.0 s |
| 0 s | 10 | 10.1 s, clean |
| 8 s | 6 | 7.1 s |
| 12 s | 2 | 3.0 s |

The same happens without Tailscale on one loopback keep-alive socket (0 s idle: 10
ticks, clean; 8 s idle: 6 ticks, unclean end after 6.8 s). The engine starts a new
idle cycle when the preceding send finishes and derives the next request's deadline
from it (`src/server.zig`, "A fresh idle cycle starts after the preceding send
finishes"), so idle wait and request share one `timeout_ms`. Browsers recover
through `Last-Event-ID`; [the HTTPS guide](../docs/HTTPS.md) documents the
behavior. A deadline measured from the request's arrival (or a separate
keep-alive idle timeout) would remove it; that belongs to the engine.
