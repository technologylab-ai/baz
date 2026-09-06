//! A typed App wraps an endpoint with bearer authentication.
//! The fixed token is public example data, not a production credential.
const std = @import("std");
const web = @import("baz");
const support = @import("example_support");
const auth = @import("endpoint/auth_helpers.zig");

const Shared = struct { bearer_token: [7]u8 = "ABCDEFG".* };
const Application = web.App(Shared);
const Endpoint = struct {
    greeting: []const u8 = "Hello from the authenticated App",

    pub fn get(self: *Endpoint, ctx: *Application.Context) !void {
        return ctx.response.text(200, self.greeting);
    }

    pub fn unauthorized(_: *Endpoint, ctx: *Application.Context) !void {
        try ctx.response.header("WWW-Authenticate", "Bearer realm=\"app-example\"");
        return ctx.response.text(401, "UNAUTHORIZED ACCESS");
    }
};

const Authenticated = struct {
    endpoint: *Endpoint,

    pub fn get(self: *Authenticated, ctx: *Application.Context) !void {
        if (!auth.bearer(7, ctx.request, &ctx.shared.bearer_token)) return self.endpoint.unauthorized(ctx);
        return self.endpoint.get(ctx);
    }
};

pub fn main(init: std.process.Init) !void {
    var shared: Shared = .{};
    const app = try Application.init(.{ .allocator = init.gpa, .io = init.io, .shared = &shared, .server = try support.config(init) });
    defer app.deinit();
    var endpoint: Endpoint = .{};
    var authenticated: Authenticated = .{ .endpoint = &endpoint };
    try app.endpoint("/test", &authenticated);
    try support.run(app, init);
}
