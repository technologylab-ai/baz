//! Cookie values remain borrowed text. The response reports values without logging.
const std = @import("std");
const web = @import("http_app");
const support = @import("example_support");
const auth = @import("endpoint/auth_helpers.zig");

const Shared = struct {};
const Application = web.App(Shared);

fn handle(ctx: *Application.Context) !void {
    const parsed = auth.cookies(ctx.request) catch |err| switch (err) {
        error.TooManyCookies => return ctx.response.text(431, "Too many cookies"),
        error.MalformedCookie => return ctx.response.text(400, "Malformed Cookie header"),
    };
    const selected = parsed.unique("ZIG_ZAP") catch return ctx.response.text(400, "Duplicate ZIG_ZAP cookie");
    try ctx.response.header("Set-Cookie", "rene=rocksai; Path=/xxx; Max-Age=60; HttpOnly; SameSite=Lax");
    return ctx.response.jsonValue(200, .{ .message = "Hello", .count = parsed.len, .cookies = parsed.items[0..parsed.len], .zig_zap = selected });
}

pub fn main(init: std.process.Init) !void {
    var shared: Shared = .{};
    const app = try Application.init(.{ .allocator = init.gpa, .io = init.io, .shared = &shared, .server = try support.config(init) });
    defer app.deinit();
    try app.route("GET", "/", handle);
    try support.run(app, init);
}
