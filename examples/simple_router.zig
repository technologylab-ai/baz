//! Plain routes and methods bound to one caller-owned endpoint. The original
//! growable formatting strings become bounded output generation. Mutable state
//! uses finite atomic retries so explicit multi-shard execution is safe too.
const std = @import("std");
const web = @import("baz");
const support = @import("example_support");

const Shared = struct {};
const Application = web.App(Shared);

const SomePackage = struct {
    a: std.atomic.Value(u32) = .init(1),
    b: u32 = 2,

    fn getA(self: *SomePackage, ctx: *Application.Context) !void {
        return ctx.response.print(200, "text/plain", "A value is {d}\n", .{self.a.load(.monotonic)});
    }

    fn getB(self: *SomePackage, ctx: *Application.Context) !void {
        return ctx.response.print(200, "text/plain", "B value is {d}\n", .{self.b});
    }

    fn incrementA(self: *SomePackage, ctx: *Application.Context) !void {
        var previous = self.a.load(.monotonic);
        for (0..16) |_| {
            if (previous >= 1_000_000_000) return ctx.response.text(409, "counter limit reached");
            if (self.a.cmpxchgWeak(previous, previous + 1, .monotonic, .monotonic)) |changed| {
                previous = changed;
            } else return ctx.response.text(200, "incremented A");
        }
        return ctx.response.text(503, "counter busy");
    }
};

fn hello(ctx: *Application.Context) !void {
    return ctx.response.bytes(200, "text/html; charset=utf-8", "<html><body><h1>Hello from zig-http!!!</h1></body></html>");
}

fn notFound(ctx: *Application.Context) !void {
    return ctx.response.text(404, "Not found");
}

pub fn main(init: std.process.Init) !void {
    var shared: Shared = .{};
    var package: SomePackage = .{};
    const app = try Application.init(.{ .allocator = init.gpa, .io = init.io, .shared = &shared, .server = try support.config(init), .not_found = notFound });
    defer app.deinit();
    try app.route("GET", "/", hello);
    try app.bind("GET", "/geta", &package, SomePackage.getA);
    try app.bind("GET", "/getb", &package, SomePackage.getB);
    // GET is retained solely for parity with the original educational example.
    // Applications should use POST for state-changing operations.
    try app.bind("GET", "/inca", &package, SomePackage.incrementA);
    try app.bind("POST", "/inca", &package, SomePackage.incrementA);
    try support.run(app, init);
}
