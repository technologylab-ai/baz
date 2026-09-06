//! Send each update while this handler remains active. Try curl -N localhost:8080.
const std = @import("std");
const baz = @import("baz");
const support = @import("example_support");

const Shared = struct {};
const Application = baz.App(Shared);

fn progress(ctx: *Application.Context) !void {
    try ctx.response.header("Cache-Control", "no-cache");
    var stream = try ctx.response.stream(200, "text/plain; charset=utf-8", .{});
    const out = stream.writer();
    try out.writeAll("Starting…\n");
    try out.flush();
    try ctx.sleep(.fromMilliseconds(500));
    try out.print("Completed step {d} of {d}\n", .{ 1, 2 });
    try out.flush();
    try ctx.sleep(.fromMilliseconds(500));
    try out.writeAll("Done.\n");
    try stream.finish();
}

pub fn main(init: std.process.Init) !void {
    var shared: Shared = .{};
    const app = try Application.init(.{
        .allocator = init.gpa,
        .io = init.io,
        .shared = &shared,
        .server = try support.workerConfig(init),
    });
    defer app.deinit();
    try app.route("GET", "/", progress);
    try support.run(app, init);
}
