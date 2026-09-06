//! Global and route middleware share typed request locals.
const std = @import("std");
const support = @import("example_support");
const parts = @import("endpoint/middleware_parts.zig");

fn handle(ctx: *parts.Application.Context) !void {
    try ctx.response.header("X-Middleware-Order", "user, session, response");
    return parts.render(ctx);
}

pub fn main(init: std.process.Init) !void {
    var shared: parts.Shared = .{};
    const app = try parts.Application.init(.{
        .allocator = init.gpa,
        .io = init.io,
        .shared = &shared,
        .server = try support.config(init),
        .middleware = &.{parts.user_middleware},
    });
    defer app.deinit();
    try app.routeWith("GET", "/", handle, .{ .middleware = &.{parts.session_middleware} });
    try support.run(app, init);
}
