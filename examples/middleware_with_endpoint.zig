//! Middleware passes typed locals directly to an ordinary endpoint method.
const std = @import("std");
const support = @import("example_support");
const parts = @import("endpoint/middleware_parts.zig");

const HtmlEndpoint = struct {
    pub fn get(_: *HtmlEndpoint, ctx: *parts.Application.Context, locals: *const parts.Locals) !void {
        try ctx.response.header("X-Middleware-Order", "user, session, endpoint");
        return parts.render(ctx, locals);
    }
};

const Pipeline = struct {
    endpoint: HtmlEndpoint = .{},

    pub fn get(self: *Pipeline, ctx: *parts.Application.Context) !void {
        var locals: parts.Locals = .{};
        if (try parts.UserMiddleware.before(ctx, &locals) == .respond) return;
        if (parts.SessionMiddleware.before(ctx, &locals) == .respond) return;
        return self.endpoint.get(ctx, &locals);
    }
};

pub fn main(init: std.process.Init) !void {
    var shared: parts.Shared = .{};
    const app = try parts.Application.init(.{ .allocator = init.gpa, .io = init.io, .shared = &shared, .server = try support.config(init) });
    defer app.deinit();
    var pipeline: Pipeline = .{};
    try app.endpoint("/", &pipeline);
    try app.endpoint("/test", &pipeline);
    try support.run(app, init);
}
