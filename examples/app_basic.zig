//! Typed Shared state, ordinary stateful endpoints, and instance-specific stop.
//! The old callback-local arena and demonstration sleep are removed: formatting
//! writes into reserved output and inline callbacks remain nonblocking.
const std = @import("std");
const web = @import("http_app");
const support = @import("example_support");

const Shared = struct { db_connection: []const u8 = "db connection established!" };
const Application = web.App(Shared);

const SimpleEndpoint = struct {
    some_data: []const u8 = "some endpoint specific data",

    pub fn get(self: *SimpleEndpoint, ctx: *Application.Context) !void {
        return ctx.response.print(200, "text/plain; charset=utf-8", "Hello!\ncontext.db_connection: {s}\nendpoint.data: {s}\n", .{ ctx.shared.db_connection, self.some_data });
    }
};

const StopEndpoint = struct {
    pub fn get(_: *StopEndpoint, ctx: *Application.Context) !void {
        try ctx.response.text(200, "stopping");
        // Stop cancels admitted connections, including this one. A reply is
        // deliberately not promised; observe clean process shutdown instead.
        ctx.app.requestStop();
    }
};

pub fn main(init: std.process.Init) !void {
    var shared: Shared = .{};
    var simple: SimpleEndpoint = .{};
    var stop: StopEndpoint = .{};
    const app = try Application.init(.{ .allocator = init.gpa, .io = init.io, .shared = &shared, .server = try support.config(init) });
    defer app.deinit();
    try app.endpoint("/test", &simple);
    try app.endpoint("/stop", &stop);
    try support.run(app, init);
}
