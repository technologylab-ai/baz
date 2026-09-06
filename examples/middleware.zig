//! A fixed middleware chain uses typed callback locals and explicit decisions.
const std = @import("std");
const support = @import("example_support");
const parts = @import("endpoint/middleware_parts.zig");

fn handle(ctx: *parts.Application.Context) !void {
    var locals: parts.Locals = .{};
    if (try parts.UserMiddleware.before(ctx, &locals) == .respond) return;
    if (parts.SessionMiddleware.before(ctx, &locals) == .respond) return;
    try ctx.response.header("X-Middleware-Order", "user, session, response");
    return parts.render(ctx, &locals);
}

pub fn main(init: std.process.Init) !void {
    var shared: parts.Shared = .{};
    const app = try parts.Application.init(.{ .allocator = init.gpa, .io = init.io, .shared = &shared, .server = try support.config(init) });
    defer app.deinit();
    try app.route("GET", "/", handle);
    try support.run(app, init);
}
