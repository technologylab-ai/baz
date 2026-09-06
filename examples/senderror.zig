//! Application error propagation and a custom bounded mapper. Internal errors
//! are not HTTP-version errors; the response is a generic 500 with no trace.
const std = @import("std");
const web = @import("http_app");
const support = @import("example_support");

const Shared = struct {};
const Application = web.App(Shared);

fn fail(_: *Application.Context) !void {
    return error.MEGA_ERROR;
}

fn mapped(ctx: *Application.Context, _: anyerror) !void {
    return ctx.response.jsonValue(500, .{ .@"error" = "request failed" });
}

pub fn main(init: std.process.Init) !void {
    var shared: Shared = .{};
    const app = try Application.init(.{ .allocator = init.gpa, .io = init.io, .shared = &shared, .server = try support.config(init), .on_error = mapped });
    defer app.deinit();
    try app.route("GET", "/", fail);
    try support.run(app, init);
}
