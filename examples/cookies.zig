//! Cookie values remain borrowed text. The response reports values without logging.
const std = @import("std");
const web = @import("baz");
const support = @import("example_support");

const Shared = struct {};
const Application = web.App(Shared);

fn handle(ctx: *Application.Context) !void {
    const parsed = ctx.request.cookiesWithLimits(.{ .max_pairs = 16 }) catch |err| switch (err) {
        error.MalformedCookie => return ctx.response.text(400, "Malformed Cookie header"),
        else => return ctx.response.text(431, "Cookie limits exceeded"),
    };
    const selected = parsed.uniqueRaw("ZIG_ZAP") catch return ctx.response.text(400, "Duplicate ZIG_ZAP cookie");
    // Only JSON descriptors use this stack array. Names and values still borrow the request.
    var items: [16]web.cookies.Cookie = undefined;
    var pairs = parsed.iterator();
    var count: usize = 0;
    while (pairs.next()) |cookie| : (count += 1) items[count] = cookie;
    try ctx.response.setCookie("rene", "rocksai", .{ .path = "/xxx", .max_age = 60 });
    return ctx.response.jsonValue(200, .{ .message = "Hello", .count = count, .cookies = items[0..count], .zig_zap = selected });
}

pub fn main(init: std.process.Init) !void {
    var shared: Shared = .{};
    const app = try Application.init(.{ .allocator = init.gpa, .io = init.io, .shared = &shared, .server = try support.config(init) });
    defer app.deinit();
    try app.route("GET", "/", handle);
    try support.run(app, init);
}
