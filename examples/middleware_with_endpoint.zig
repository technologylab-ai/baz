//! An ordinary endpoint method reads locals filled by public middleware.
const std = @import("std");
const support = @import("example_support");
const parts = @import("endpoint/middleware_parts.zig");

const HtmlEndpoint = struct {
    pub fn get(_: *HtmlEndpoint, ctx: *parts.Application.Context) !void {
        try ctx.response.header("X-Middleware-Order", "user, session, endpoint");
        return parts.render(ctx);
    }
};

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
    var endpoint: HtmlEndpoint = .{};
    const options: parts.Application.RouteOptions = .{ .middleware = &.{parts.session_middleware} };
    try app.endpointWith("/", &endpoint, options);
    try app.endpointWith("/test", &endpoint, options);
    try support.run(app, init);
}
