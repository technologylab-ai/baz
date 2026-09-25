# HTTPS with `tailscale serve`

Baz serves plain HTTP/1.1 and has no TLS; that remains out of scope. You can still
reach a Baz application over HTTPS with a real certificate: let
[Tailscale](https://tailscale.com/kb/1312/serve) terminate TLS on the same machine
and forward to Baz on loopback. Tailscale also tells the application **who** is
calling, so a single-user or small-team service needs no password handling.

The [tailscale_https example](../examples/tailscale_https.zig) shows the whole
arrangement: a loopback listener, an identity middleware with typed request
locals, a `/whoami` route, and a server-sent event stream that browsers resume
with `Last-Event-ID`.

```sh
zig build run-tailscale_https -Doptimize=ReleaseSafe -- --port 8080 --login you@example.com
# In another terminal on the same machine (no sudo if you are the Tailscale operator):
tailscale serve --bg --https=8443 http://127.0.0.1:8080
```

Open `https://<node>.<tailnet>.ts.net:8443/` from any device on your tailnet.
The page names the signed-in user and counts live ticks. Stop publishing with
`tailscale serve --https=8443 off`.

## What each side does

| | Responsibility |
| --- | --- |
| Tailscale | Accepts HTTPS on the tailnet with a certificate for `<node>.<tailnet>.ts.net`, speaks HTTP/2 to browsers, and forwards HTTP/1.1 to `127.0.0.1:8080` |
| Tailscale | Adds `Tailscale-User-Login` and `Tailscale-User-Name` for requests from tailnet users, **replacing** any values the client sent |
| Baz | Listens on IPv4 loopback only (the example has no `--bind-address`) |
| Baz | Route middleware compares `Tailscale-User-Login` with `--login`; a missing or different login receives 403 before the handler runs |

The middleware stores the borrowed header values in typed locals, so handlers
read `ctx.locals.login` instead of parsing headers again. See
[middleware and request locals](MIDDLEWARE.md). The check is attached with
`routeWith`/`routeContinuation` options rather than globally, so protocol-level
`OPTIONS *` keeps its ordinary response. Tailscale sends `Tailscale-User-Name`
RFC 2047-encoded when it contains non-ASCII characters; decode it before display
if that matters to you.

## Trust model

- **Loopback is the boundary.** Only `tailscale serve` should be able to reach the
  listener. Any other process on the same machine can connect to `127.0.0.1` and
  send a forged `Tailscale-User-Login`. That is acceptable on a single-user machine,
  not on a shared host.
- **Never use Tailscale Funnel for this.** Funnel publishes the service to the
  public internet; requests from there carry no tailnet identity, so the
  example refuses them, but you would be exposing the listener for no benefit.
- Tagged devices (servers with ACL tags) do not get user identity headers.
  They receive 403 from the example.
- Starting without `--login` refuses every request, rather than allowing everyone.

## Server-sent events through the proxy

`tailscale serve` does not buffer event streams: events arrive as Baz flushes
them. Baz's `server.timeout_ms` covers the whole request cycle, including a stream,
so a long-lived stream must end. The example ends each stream itself after ten
ticks, well before its deadline, so the response terminates cleanly; the browser's
`EventSource` reconnects after the advertised `retry` hint and sends
`Last-Event-ID`, and the stream continues from the next tick. Design streams so
that a reconnect is harmless: resume from an ID, never from "whatever the client
saw last".

**Idle connections:** `tailscale serve` pools its backend connections, so a
stream often starts on a connection that waited idle. A request deadline starts at
the request's first byte, so that idle time does not shorten the stream.
`server.idle_timeout_ms` bounds the idle wait separately (zero selects `timeout_ms`).
Before [bounded/http PR #7](https://github.com/technologylab-ai/bounded-http/pull/7),
idle time counted: with a 15-second `timeout_ms`, a stream after an 8-second idle gap
delivered 6 of 10 ticks, and after 12 seconds 2 of 10. The
[verification receipt](../reports/2026-09-25-tailscale-https.md) records those
measurements. To give only the stream route a longer deadline, use
`RouteOptions.timeout_ms` (see [SSE](SSE.md#long-streams-and-the-request-deadline)).

## First request and certificates

Tailscale obtains the certificate from Let's Encrypt when the first HTTPS request
arrives. That request can take around 30 seconds; later ones take milliseconds.
Warm it up once with `curl` after running `tailscale serve`. HTTPS certificates
must be enabled for the tailnet (Tailscale admin console → DNS → HTTPS).

## Without Tailscale: a TLS reverse proxy

Any TLS-terminating reverse proxy works the same way: the proxy owns the
certificate and forwards to Baz on loopback. With Caddy:

```
notes.example.com {
    reverse_proxy 127.0.0.1:8080 {
        flush_interval -1
    }
}
```

`flush_interval -1` disables response buffering, which event streams need.
A generic proxy does not know who the user is, so identity has to come from
somewhere else: a login and session in the application (see
[cookies, redirects, and sessions](COOKIES.md)), or an authenticating proxy
(for example an OAuth2 proxy or mutual TLS) that sets a header **and** strips any
client-supplied copy of it. Check that header in a middleware exactly as the
example checks `Tailscale-User-Login`, and never trust such a header on a listener
the proxy does not exclusively front.
