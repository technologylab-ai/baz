//! The original two-page static-site demonstration with an explicit asset
//! allowlist. This is not a public-directory server: no filesystem access,
//! directory traversal, automatic index discovery or runtime file loading.
const std = @import("std");
const web = @import("baz");
const support = @import("example_support");

const Shared = struct {};
const Application = web.App(Shared);

fn index(ctx: *Application.Context) !void {
    return ctx.response.borrowBody(200, "text/html; charset=utf-8", @embedFile("assets/serve_index.html"));
}

fn two(ctx: *Application.Context) !void {
    return ctx.response.borrowBody(200, "text/html; charset=utf-8", @embedFile("assets/serve_two.html"));
}

fn notFound(ctx: *Application.Context) !void {
    return ctx.response.bytes(404, "text/html; charset=utf-8", "<html><body><h1>404 - File not found</h1></body></html>");
}

pub fn main(init: std.process.Init) !void {
    var shared: Shared = .{};
    const app = try Application.init(.{ .allocator = init.gpa, .io = init.io, .shared = &shared, .server = try support.config(init), .not_found = notFound });
    defer app.deinit();
    try app.route("GET", "/", index);
    try app.route("GET", "/index.html", index);
    try app.route("GET", "/two.html", two);
    try support.run(app, init);
}
