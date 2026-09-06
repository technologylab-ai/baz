# Middleware and typed request locals

`AppWithLocals(Shared, Locals)` gives each request default-initialized typed state
at a stable address. `App(Shared)` remains the shortcut with empty locals. Locals
must be a struct with field defaults, at most 4,096 bytes and alignment at most 64.
Synchronous handlers retain their locals through worker stream flushes.

```zig
const Application = web.AppWithLocals(Shared, struct { user_id: ?u64 = null });

fn authenticate(ctx: *Application.Context) !Application.Decision {
    ctx.locals.user_id = try ctx.shared.authenticate(ctx.request);
    if (ctx.locals.user_id == null) {
        try ctx.response.redirect(303, "/login");
        return .respond;
    }
    return .continue_request;
}

// During startup:
try app.routeWith("GET", "/account", account, .{
    .middleware = &.{.{ .before = authenticate }},
});
```

The authentication operation is application-owned; it must obey the selected
executor's blocking and allocation constraints. Runnable examples are
[app authentication](../examples/app_auth.zig), [endpoint authentication](../examples/endpoint_auth.zig),
[middleware](../examples/middleware.zig), and [sessions](../examples/userpass_session.zig).

## Order and ownership

The application copies global `Options.middleware` and per-route descriptors into
startup storage. `max_middleware` bounds their combined count, default 128 and
maximum 4,096. `routeWith`, `bindWith`, and `endpointWith` accept `RouteOptions`;
endpoint registration copies its chain per method and rolls back atomically on
failure. Bound instances and shared services remain borrowed through App teardown.

Each request runs `init_locals`, global before hooks, routing, route before hooks,
and its handler. Route after hooks then run in reverse order, followed by global
after hooks in reverse order. Global hooks run even for generated routing errors
and OPTIONS responses; captures become available to the chosen route's hooks.

A before hook returns `.continue_request` without choosing a response body, or
`.respond` after preparing one. It may append headers before continuing. Invalid
combinations are ordinary handler errors. A short circuit unwinds only entered
hooks. A hook counts as entered before its before callback runs, including when
that callback throws. Empty descriptors are rejected at registration.

Cleanup runs once in reverse entered order, followed by `cleanup_locals`, on
success, short circuit, error, or observed cancellation. Locals cleanup also runs
when initialization fails, so field defaults must represent safe cleanup state.
Cleanup releases resources and cannot change the completed response. After hooks
run on successful processing; an after error stops the remaining after hooks.
The normal error handler sees locals before cleanup. Published streams cannot be
replaced by an error response and close instead. Header changes must precede the
first stream flush.

Framework storage is reserved before callbacks. Locals and callback stacks cannot
back a borrowed response body. Shared data needs application synchronization;
request locals are exclusively owned by their active callback. The framework does
not make arbitrary application code nonblocking or allocation-free.

## Verification

`zig build verify` checks registration rollback, bounds, default initialization,
error unwinding and independent package consumption. The middleware wire suite
covers inline and worker execution, routing, pipelines, concurrent requests,
stream flushes, errors, deadlines, disconnect and shutdown cleanup.
