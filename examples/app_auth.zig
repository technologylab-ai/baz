//! Route middleware authenticates a bearer token before the endpoint runs.
//! The fixed token is public example data, not a production credential.
const std = @import("std");
const web = @import("baz");
const support = @import("example_support");
const auth = @import("endpoint/auth_helpers.zig");

const Shared = struct { bearer_token: [7]u8 = "ABCDEFG".* };
const Locals = struct { user_id: ?u64 = null };
const Application = web.AppWithLocals(Shared, Locals);
const Endpoint = struct {
    greeting: []const u8 = "Hello from the authenticated App",

    pub fn get(self: *Endpoint, ctx: *Application.Context) !void {
        std.debug.assert(ctx.locals.user_id != null);
        return ctx.response.text(200, self.greeting);
    }
};

fn authenticate(ctx: *Application.Context) !Application.Decision {
    if (!auth.bearer(7, ctx.request, &ctx.shared.bearer_token)) {
        try ctx.response.header("WWW-Authenticate", "Bearer realm=\"app-example\"");
        try ctx.response.text(401, "UNAUTHORIZED ACCESS");
        return .respond;
    }
    ctx.locals.user_id = 1;
    return .continue_request;
}

pub fn main(init: std.process.Init) !void {
    var shared: Shared = .{};
    const app = try Application.init(.{ .allocator = init.gpa, .io = init.io, .shared = &shared, .server = try support.config(init) });
    defer app.deinit();
    var endpoint: Endpoint = .{};
    try app.endpointWith("/test", &endpoint, .{ .middleware = &.{.{ .before = authenticate }} });
    try support.run(app, init);
}
