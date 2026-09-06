//! Zap's smallest greeting example, using one explicit route and no callback
//! logging or hidden per-request allocations.
const std = @import("std");
const web = @import("http_app");
const support = @import("example_support");

const Shared = struct {};
const Application = web.App(Shared);

fn hello(ctx: *Application.Context) !void {
    return ctx.response.bytes(200, "text/html; charset=utf-8", "<html><body><h1>Hello from zig-http!!!</h1></body></html>");
}

pub fn main(init: std.process.Init) !void {
    var shared: Shared = .{};
    const app = try Application.init(.{ .allocator = init.gpa, .io = init.io, .shared = &shared, .server = try support.config(init) });
    defer app.deinit();
    try app.route("GET", "/", hello);
    try support.run(app, init);
}
