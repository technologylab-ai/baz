//! HTTPS for a loopback Baz app: `tailscale serve` terminates TLS and names the user.
//! Baz itself stays plain HTTP on 127.0.0.1. Tailscale publishes it on your tailnet as
//! https://<node>.<tailnet>.ts.net:<port> with a real certificate and adds identity
//! headers, which a route middleware checks against `--login`.
//!
//!   zig build run-tailscale_https -Doptimize=ReleaseSafe -- --port 8080 --login you@example.com
//!   tailscale serve --bg --https=8443 http://127.0.0.1:8080
//!
//! Read docs/HTTPS.md for the trust model and a generic reverse-proxy alternative.
const std = @import("std");
const web = @import("baz");
const support = @import("example_support");

/// The shared support flags, minus the bind address (this example is loopback-only),
/// plus the one tailnet login allowed in.
const Options = struct {
    port: u16 = 8080,
    duration_ms: u32 = 0,
    execution: enum { @"inline", workers } = .@"inline",
    workers: ?u16 = null,
    connections: u16 = 16,
    shards: u8 = 1,
    login: []const u8 = "",
    tick_ms: u32 = 1000,

    pub const help =
        \\Baz example — Zig 0.16.0
        \\Usage: tailscale_https --login you@example.com [options]
        \\
        \\  -h, --help                    Show this help and exit
        \\  -p, --port N                  Loopback listen port; 0 selects an available port (default: 8080)
        \\      --login EMAIL             The Tailscale login allowed in; empty refuses everyone (default: empty)
        \\      --tick-ms N               Interval between event-stream ticks, positive (default: 1000)
        \\      --duration-ms N           Stop after N milliseconds; 0 waits for shutdown
        \\      --execution inline|workers
        \\      --workers N               Worker count (default: 2 for workers, 0 for inline)
        \\      --connections N           Connection slots (default: 16)
        \\      --shards N                I/O shards (default: 1)
        \\
        \\Always listens on 127.0.0.1. Publish it with:
        \\  tailscale serve --bg --https=8443 http://127.0.0.1:PORT
        \\
    ;
    pub const aliases = .{ .port = "p" };
};

const Shared = struct { login: []const u8, tick_ns: u64 };
/// Identity headers are borrowed request bytes, valid while this request is handled.
const Locals = struct { login: ?[]const u8 = null, name: ?[]const u8 = null };
const Application = web.AppWithLocals(Shared, Locals);
const Context = Application.Context;

/// Streams end before the request deadline, so reconnects are clean and expected.
const ticks_per_stream = 10;

const identity: Application.Middleware = .{ .before = requireIdentity };

/// `tailscale serve` sets Tailscale-User-Login for tailnet users and replaces any
/// client-supplied value. Requests that did not come through it carry no header.
fn requireIdentity(ctx: *Context) !Application.Decision {
    const login = ctx.request.header("Tailscale-User-Login") orelse {
        try ctx.response.text(403, "No Tailscale identity: reach this app through tailscale serve.\n");
        return .respond;
    };
    if (ctx.shared.login.len == 0 or !std.mem.eql(u8, login, ctx.shared.login)) {
        try ctx.response.text(403, "This tailnet login is not allowed.\n");
        return .respond;
    }
    ctx.locals.login = login;
    ctx.locals.name = ctx.request.header("Tailscale-User-Name");
    return .continue_request;
}

fn page(ctx: *Context) !void {
    try ctx.response.header("Cache-Control", "no-store");
    try ctx.response.borrowBody(200, "text/html; charset=utf-8", @embedFile("assets/tailscale_https.html"));
}

fn whoami(ctx: *Context) !void {
    try ctx.response.header("Cache-Control", "no-store");
    try ctx.response.jsonValue(200, .{ .login = ctx.locals.login, .name = ctx.locals.name });
}

const Ticks = struct { tick: u64 = 0, sent: u8 = 0 };

fn startTicks(ctx: *Context, state: *Ticks) !web.continuation.Step {
    // EventSource resends the last id after a reconnect; continue from there.
    if (ctx.request.header("Last-Event-ID")) |raw| {
        // Leave room for this stream's ticks, so resuming can never overflow.
        const last = std.fmt.parseInt(u64, raw, 10) catch std.math.maxInt(u64);
        if (last > std.math.maxInt(u64) - ticks_per_stream) {
            try ctx.response.text(400, "Last-Event-ID must be a decimal tick\n");
            return .finish;
        }
        state.tick = last;
    }
    try ctx.response.header("Cache-Control", "no-store");
    var output = try ctx.response.snapshot(200, web.sse.content_type, .{});
    try web.sse.comment(output.writer(), "ticks through tailscale serve");
    return .flush;
}

fn nextTick(ctx: *Context, state: *Ticks, event: web.continuation.Event) !web.continuation.Step {
    if (event == .flushed) {
        if (state.sent == ticks_per_stream) return .finish;
        return .{ .wait = ctx.shared.tick_ns };
    }
    state.tick += 1;
    state.sent += 1;
    var id: [20]u8 = undefined;
    var data: [40]u8 = undefined;
    var output = try ctx.response.resumeSnapshot();
    try web.sse.write(output.writer(), .{
        .event = "tick",
        .id = try std.fmt.bufPrint(&id, "{d}", .{state.tick}),
        .data = try std.fmt.bufPrint(&data, "{{\"tick\":{d}}}", .{state.tick}),
        .retry_ms = if (state.sent == 1) 1000 else null,
    });
    return .flush;
}

pub fn main(init: std.process.Init) !void {
    const options = try support.parseOptions(init, Options);
    if (options.tick_ms == 0) return error.InvalidLifetime;
    var config = try support.configFromOptions(options, false);
    // One stream lasts ticks_per_stream ticks; leave five seconds of headroom before the deadline.
    config.timeout_ms = try std.math.add(u32, try std.math.mul(u32, options.tick_ms, ticks_per_stream), 5000);
    config.shutdown_ms = 1000;

    var shared: Shared = .{ .login = options.login, .tick_ns = @as(u64, options.tick_ms) * std.time.ns_per_ms };
    const app = try Application.init(.{
        .allocator = init.gpa,
        .io = init.io,
        .shared = &shared,
        .server = config,
        .max_continuations = 16,
    });
    defer app.deinit();
    const guarded: Application.RouteOptions = .{ .middleware = &.{identity} };
    try app.routeWith("GET", "/", page, guarded);
    try app.routeWith("GET", "/whoami", whoami, guarded);
    try app.routeContinuation("GET", "/events", Ticks, startTicks, nextTick, guarded);
    if (options.login.len == 0) std.debug.print("tailscale_https: no --login given; every request is refused\n", .{});
    try support.run(app, init);
}
