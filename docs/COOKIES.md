# Cookies and redirects

Cookie reads borrow request bytes. Cookie writes format directly into the
startup-reserved response header area. Neither operation allocates, reads a
clock, starts I/O, or interprets a token's contents.

The [cookie example](../examples/cookies.zig) shows raw inspection. The
[login example](../examples/userpass_session.zig) shows a complete local
login → redirect → protected page → logout flow.

## Read without conversion

```zig
const token = try ctx.request.cookie("sid"); // null if absent; rejects duplicates
const view = try ctx.request.cookiesWithLimits(.{ .max_pairs = 16 });
var pairs = view.iterator();
while (pairs.next()) |cookie| {
    // cookie.name_raw, cookie.value_raw and cookie.quoted
}
```

The entire input is validated before a view is returned, including every repeated
`Cookie` header. Pairs retain wire order and case-sensitive names. `001`, `false`,
percent escapes, plus signs, equals signs and brackets in values stay text.
Enclosing value quotes are excluded as a borrowed sub-slice; `quoted` records them.
Names follow HTTP token syntax, so a bracketed name is invalid. Empty values are
valid. Empty fields, malformed pairs, comma-joined cookies, and trailing separators
are errors. No implicit URL decoding, splitting token claims, or JSON conversion.
Use `web.params.percentDecodeInto` explicitly if your application's cookie format
requires it; cookie `+` is not a form-space convention.

`firstRaw(name)` selects the first descriptor, `allRaw(name)` iterates matches,
and `uniqueRaw(name)` returns an optional value or `DuplicateCookie`.
`request.cookie(name)` is the duplicate-rejecting shortcut with default limits.
Cookies with the same name can originate from different browser paths or domains;
the request contains no scope attributes that let Baz distinguish them reliably.
For authentication, choosing one silently is usually the wrong policy.

Defaults are **8,192 raw Cookie field bytes total, 32 pairs, 256 bytes per name,
and 4,096 bytes per value**. The byte bound includes field whitespace after the
colon, across all Cookie fields. Header syntax and all other request headers are
already bounded by the HTTP engine. Parsing adds no per-pair metadata allocation
or hidden fixed array. Keep the source immutable for the active callback.
Standalone `web.cookies.parse` and `parseHeaders` use the same rules.

Uncaught malformed/duplicate cookie errors map to 400. Cookie byte/count bounds
map to 431; the shared name/value size errors retain Baz's 413 mapping. Examples
may explicitly map every cookie bound to 431. Invalid outgoing cookie options
are application errors, mapped to 500 unless handled.

## Choose a lifetime explicitly

```zig
try ctx.response.setCookie("sid", token, .{}); // browser session
try ctx.response.setCookie("remember", "yes", .{ .max_age = 30 * 24 * 60 * 60 });
try ctx.response.setCookie("until", "yes", .{ .expires = 1893456000 }); // UTC 2030-01-01
try ctx.response.deleteCookie("sid", .{});
```

| Intent | Options | Wire behavior |
| --- | --- | --- |
| Browser session | `max_age = null, expires = null` (defaults) | Neither expiry attribute is emitted. |
| Persistent, relative | `max_age = positive_seconds` | `Max-Age` counts from receipt. |
| Persistent, absolute | `expires = unix_seconds` | An IMF-fixdate in GMT is emitted. |
| Both attributes | Set both explicitly | The browser gives `Max-Age` precedence. Baz does not reconcile them. |
| Delete | `deleteCookie(name, original_options)` | Empty value, `Max-Age=0`, epoch-zero `Expires`; original scope/flags retained. |
| Raw immediate expiry | `max_age <= 0`, or past `expires` without positive Max-Age | Requests removal. Empty value alone does not delete. |

`max_age` is `?i64`; **null and zero mean different things**. `expires` is `?u64`
Unix seconds from 1970 through the last second of year 9999. It accepts past dates
without consulting a clock. Bad dates/options fail before any header is written.
Max-Age precedence and session-cookie semantics follow
[RFC 6265 §4.1.2](https://www.rfc-editor.org/rfc/rfc6265.html#section-4.1.2).

There is **no reliable “never expires” cookie**. Choose an explicit persistent
lifetime and a renewal policy when needed. Browsers can cap retention, evict
cookies, or let users remove them; even a distant Expires cannot promise forever.
The [current cookie draft §5.5](https://datatracker.ietf.org/doc/html/draft-ietf-httpbis-rfc6265bis-22#section-5.5)
recommends a maximum of 400 days or less. A browser defines when its session ends;
closing a window is not a reliable server-side logout or expiry mechanism.

## Scope and browser flags

`web.cookies.Options` defaults to `Path=/`, no Domain, no expiry, `HttpOnly`,
`SameSite=Lax`, and `secure=false` for Baz's local HTTP examples.

| Option | Contract |
| --- | --- |
| `path` | Absolute ASCII path; null omits Path and uses browser default-path rules. Semicolons, controls and trailing spaces are rejected. |
| `domain` | Null produces a host-only cookie. Otherwise use an ASCII DNS name without leading/trailing dots; IDNs need explicit ASCII conversion. Baz validates spelling, not public-suffix or current-host eligibility. |
| `secure` | Emit Secure explicitly when the browser-facing connection is HTTPS, including a TLS-terminating proxy. Baz does not infer this from forwarded headers. |
| `http_only` | Defaults true; false deliberately permits browser script access where browser policy allows it. |
| `same_site` | `.strict`, `.lax`, `.none`, or null to omit. `.none` requires `secure=true`. |

`__Secure-` names require Secure. `__Host-` names require Secure, explicit `Path=/`,
and no Domain. Prefix checks ignore case while preserving the supplied name,
matching [the current cookie draft §5.4](https://datatracker.ietf.org/doc/html/draft-ietf-httpbis-rfc6265bis-22#section-5.4).
Browser host/domain/public-suffix and transport acceptance remain browser decisions.
Path is a delivery scope, not an authorization boundary. Deletion must match the
original name, Path and Domain/host-only scope; deleting `/` does not clear `/app`.

Values use cookie-octet syntax: no controls, whitespace, quotes, comma, semicolon,
backslash or non-ASCII bytes. Baz never encodes them automatically. Use an explicit
application format such as hex or base64url for binary data. Each `setCookie` adds
an independent field; Baz never comma-folds `Set-Cookie`. There is no automatic
replacement of another same-name field. Browser cookie-size limits can be lower
than your configured response header capacity.

This first typed API covers these common attributes. Partitioned/CHIPS, Priority,
and newer prefix extensions are not typed conveniences yet. The generic validated
`header` API remains available for application-authored extension fields.

## Redirect and response composition

```zig
fn logout(ctx: *Application.Context) !void {
    // Application code authenticates the request and revokes its server session.
    try ctx.response.deleteCookie("sid", .{ .same_site = .strict });
    try ctx.response.header("Cache-Control", "no-store");
    return ctx.response.redirect(303, "/login");
}
```

`redirect(status, location)` prepares one empty body and copies Location unchanged.
It accepts **301, 302, 303, 307 and 308**. Use 303 after a form submission to navigate
to a retrieval; 307/308 preserve the method, while 301/302 permit historical POST
rewriting. See [RFC 9110 §15.4](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.4).
The destination must be a trusted, already encoded URI reference. Baz rejects
empty values, controls, spaces, non-URI ASCII spelling, backslashes and malformed
percent escapes; it does not parse a complete URI or enforce an origin/scheme
allowlist. Relative, absolute, network-path and fragment references are accepted.
Do not pass arbitrary user-controlled destinations without application validation.
No URL decoding, redirect following, HTML body or cache policy is implicit.

An existing Location makes `redirect` fail with `DuplicateLocation`. A second body
choice fails with `InvalidState`. Generic `header` calls remain caller-controlled;
do not append another Location afterward. Validation, capacity and alias errors
leave cookie/redirect draft bytes and metadata unchanged, so a caught error can
prepare an alternative. Header inputs may use stack storage: the call copies them.

Cookies can accompany text, JSON, Mustache, a borrowed body, or a stream. Add them
before publication; streams freeze headers at their first flush. They cannot be
sent as new cookies halfway through a flushed response. Redirect is itself the
whole-body choice, so it cannot be combined with another body or a stream.
Every field counts against `ResponseLimits.header_bytes` and `max_headers`.
Header formatting/copying is separate from the body-copy counter; see
[ownership and response copies](OWNERSHIP.md#response-copies-and-borrowing).

## Sessions and JWTs

Cookie expiry controls browser retention, **not server session validity**. Applications
own server-side expiry, revocation, credential checks and storage. A JWT can be a
cookie value, just like an opaque token. Baz does not verify signatures or interpret
claims; JWT verification and expiry policy belong to the application or a separately
chosen library. Merely reading a cookie never authenticates it.

Run `zig build run-userpass_session -Doptimize=ReleaseSafe -- --port 8080`, then open
`http://localhost:8080/login`. The public demo credentials are `zap` / `awesome`.
The styled [login](../examples/assets/session_login.html) and
[protected page](../examples/assets/session_home.html) are separate embedded assets.
The example reserves **32 concurrent sessions** at startup. Expired or revoked
slots are reusable; live sessions are never evicted. Each session has a fixed
server lifetime of 30 minutes, configurable with `--session-ttl-ms`. Reading a
session does not extend that deadline. The browser cookie deliberately remains a
session cookie: server expiry is independent of browser retention.

Login rotates the presented session while preserving other devices. Logout revokes
one token; “Log out all devices” revokes every token for that identity. Expiry,
revocation and restart invalidate server-side access. A full store returns 503,
including rotation when no free slot remains. Authentication copies the identity
under a bounded try-lock; contention returns 503. Revocation affects subsequent
authentication, not a request that already obtained its identity snapshot.

The [example store](../examples/endpoint/session_store.zig) uses a startup-generated
secret and checked counter to derive opaque HMAC-SHA256 tokens without request-time
entropy or allocation. Never copy a live store or reset its counter under the same
key. Store operations take explicit monotonic timestamps; the example reads its
boot clock while holding the guard. This is an in-memory application example,
not a persistent identity service. [Middleware and locals](MIDDLEWARE.md) keep
credential checks separate from the protected handlers.

Unsafe POST handlers accept absent `Sec-Fetch-Site` for CLI clients, or exact
`same-origin`/`none`; they reject other values and duplicate fields with 403 before
state changes. This is a narrow browser check using
[Fetch Metadata](https://www.w3.org/TR/fetch-metadata/#sec-fetch-site-header), not a
complete CSRF policy for clients that omit it. SameSite and HttpOnly do not replace
authentication, authorization or an application's CSRF protections.

## Verification

`zig build verify` compiles the codec, request/response tests, independent consumer,
and examples. `tests/cookies_integration.py` checks actual HTTP fields and the
session workflow with ReleaseSafe binaries; `tests/session_integration.py` adds
expiry, reuse, revocation, capacity and concurrent-client checks; existing CLI, App, example, streaming,
borrow and Mustache suites remain required. CI runs these gates natively on Linux,
macOS and Windows. See [the wire fixture](../examples/cookie_fixture.zig) for the
supported profile. Browser expiry policies are documented semantics, not simulated
by the raw-wire suite.
