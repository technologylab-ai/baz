//! A stateful endpoint owns its authentication wrapper and endpoint configuration.
const std = @import("std");
const web = @import("baz");
const support = @import("example_support");
const auth = @import("endpoint/auth_helpers.zig");

const Shared = struct {};
const Application = web.App(Shared);
const Endpoint = struct {
    pub fn get(_: *Endpoint, ctx: *Application.Context) !void {
        return ctx.response.bytes(200, "text/html; charset=utf-8", "<html><body>Hello from the authenticated endpoint!</body></html>");
    }

    pub fn unauthorized(_: *Endpoint, ctx: *Application.Context) !void {
        try ctx.response.header("WWW-Authenticate", "Bearer realm=\"endpoint-example\"");
        return ctx.response.text(401, "UNAUTHORIZED ACCESS");
    }
};

const AuthenticatingEndpoint = struct {
    endpoint: Endpoint = .{},
    /// This public example token is deliberately easy to exercise with curl.
    token: [7]u8 = "ABCDEFG".*,

    pub fn get(self: *AuthenticatingEndpoint, ctx: *Application.Context) !void {
        if (!auth.bearer(7, ctx.request, &self.token)) return self.endpoint.unauthorized(ctx);
        return self.endpoint.get(ctx);
    }
};

pub fn main(init: std.process.Init) !void {
    var shared: Shared = .{};
    const app = try Application.init(.{ .allocator = init.gpa, .io = init.io, .shared = &shared, .server = try support.config(init) });
    defer app.deinit();
    var endpoint: AuthenticatingEndpoint = .{};
    try app.endpoint("/test", &endpoint);
    try support.run(app, init);
}
