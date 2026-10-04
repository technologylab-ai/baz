//! Typed continuations release the callback thread between writes and timer events.
//! Try `curl -N localhost:8080/stream` with inline execution or one worker.
//! `/long-stream` outlives the 3-second server deadline with its own route timeout.
const std = @import("std");
const web = @import("baz");
const support = @import("example_support");
const fixture = @import("endpoint/continuation_fixture.zig");

const Application = fixture.Application;
const Context = Application.Context;
const Step = web.continuation.Step;
const State = struct { completed: u8 = 0 };

fn start(ctx: *Context, _: *State) !Step {
    try ctx.response.header("Cache-Control", "no-cache");
    var output = try ctx.response.snapshot(200, "text/plain; charset=utf-8", .{});
    try output.writer().writeAll("Starting…\n");
    return .flush;
}

fn advance(ctx: *Context, state: *State, event: web.continuation.Event) !Step {
    return step(ctx, state, event, 500 * std.time.ns_per_ms);
}

/// Two 2-second pauses exceed `timeout_ms`; the route's `timeout_ms` covers them.
fn advanceSlowly(ctx: *Context, state: *State, event: web.continuation.Event) !Step {
    return step(ctx, state, event, 2 * std.time.ns_per_s);
}

fn step(ctx: *Context, state: *State, event: web.continuation.Event, pause_ns: u64) !Step {
    if (event == .flushed) return .{ .wait = pause_ns };
    state.completed += 1;
    var output = try ctx.response.resumeSnapshot();
    if (state.completed == 2) {
        try output.writer().writeAll("Done.\n");
        return .finish;
    }
    try output.writer().print("Completed step {d} of 2\n", .{state.completed});
    return .flush;
}

pub fn main(init: std.process.Init) !void {
    var shared: fixture.Shared = .{};
    var config = try support.config(init);
    config.timeout_ms = 3000;
    // Routes may select a longer deadline up to this bound.
    config.max_timeout_ms = 10_000;
    config.shutdown_ms = 1000;
    const app = try Application.init(.{
        .allocator = init.gpa,
        .io = init.io,
        .shared = &shared,
        .server = config,
        .max_continuations = 32,
        .max_continuation_state_bytes = 256,
        .init_locals = fixture.initLocals,
        .cleanup_locals = fixture.cleanupLocals,
        .middleware = &.{fixture.middleware},
        .on_error = fixture.onError,
    });
    defer app.deinit();
    try app.routeContinuation("GET", "/stream", State, start, advance, .{});
    try app.routeContinuation("GET", "/long-stream", State, start, advanceSlowly, .{ .timeout_ms = 10_000 });
    try fixture.register(app);
    try support.run(app, init);
    fixture.report(&shared);
}
