//! Endpoint failures reach an instance-specific error mapper.
const std = @import("std");
const web = @import("baz");
const support = @import("example_support");

const Shared = struct {
    db_connection: []const u8 = "db connection established!",
    errors: std.atomic.Value(u64) = .init(0),
};
const Application = web.App(Shared);
const ErrorEndpoint = struct {
    pub fn get(_: *ErrorEndpoint, ctx: *Application.Context) !void {
        try ctx.response.header("X-Unpublished", "discard this draft");
        return error.DemoFailure;
    }
};

fn mapError(ctx: *Application.Context, err: anyerror) !void {
    _ = ctx.shared.errors.fetchAdd(1, .monotonic);
    if (err == error.DemoFailure) {
        try ctx.response.header("X-Error-Handled", "app");
        return ctx.response.jsonValue(500, .{ .error_message = "The example endpoint failed" });
    }
    return ctx.response.jsonValue(web.defaultErrorStatus(err), .{ .error_message = "Request failed" });
}

fn form(ctx: *Application.Context) !void {
    _ = try ctx.request.formUrlEncoded(.{ .max_bytes = 32, .max_pairs = 2 });
    try ctx.response.text(200, "ok");
}

fn upload(ctx: *Application.Context) !void {
    var boundary: [70]u8 = undefined;
    _ = try ctx.request.multipartBoundaryInto(&boundary);
    try ctx.response.text(200, "ok");
}

fn state(ctx: *Application.Context) !void {
    return ctx.response.jsonValue(200, .{ .db_connection = ctx.shared.db_connection, .errors = ctx.shared.errors.load(.monotonic) });
}

fn stop(ctx: *Application.Context) !void {
    try ctx.response.text(200, "Stop requested");
    ctx.app.requestStop();
}

pub fn main(init: std.process.Init) !void {
    var shared: Shared = .{};
    const app = try Application.init(.{ .allocator = init.gpa, .io = init.io, .shared = &shared, .server = try support.config(init), .on_error = mapError });
    defer app.deinit();
    var endpoint: ErrorEndpoint = .{};
    try app.endpoint("/error", &endpoint);
    try app.route("POST", "/form", form);
    try app.route("POST", "/upload", upload);
    try app.route("GET", "/state", state);
    try app.route("GET", "/stop", stop);
    try support.run(app, init);
}
