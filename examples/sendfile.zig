//! Sends the original small file's embedded bytes as an immutable asset.
//! The current framework has no sendfile/range/gzip implementation. This
//! adaptation sends a complete ordinary body; it advertises no range support.
const std = @import("std");
const web = @import("http_app");
const support = @import("example_support");

const Shared = struct {};
const Application = web.App(Shared);

fn file(ctx: *Application.Context) !void {
    try ctx.response.header("Cache-Control", "no-cache");
    try ctx.response.header("Accept-Ranges", "none");
    return ctx.response.borrowBody(200, "text/plain; charset=utf-8", @embedFile("assets/sendfile.txt"));
}

pub fn main(init: std.process.Init) !void {
    var shared: Shared = .{};
    var config = try support.config(init);
    config.max_body = 1024;
    const app = try Application.init(.{ .allocator = init.gpa, .io = init.io, .shared = &shared, .server = config });
    defer app.deinit();
    try app.route("GET", "/", file);
    try app.route("GET", "/testfile.txt", file);
    try support.run(app, init);
}
