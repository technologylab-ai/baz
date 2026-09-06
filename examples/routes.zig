//! Static and dynamic route functions with a fallback menu. The fixed route
//! table replaces the example's global map; the bounded counter is shared safely.
const std = @import("std");
const web = @import("http_app");
const support = @import("example_support");

const Shared = struct { counter: std.atomic.Value(u32) = .init(0) };
const Application = web.App(Shared);

fn menu(ctx: *Application.Context) !void {
    return ctx.response.bytes(200, "text/html; charset=utf-8",
        \\<html><body>
        \\<p><a href="/static">static</a></p>
        \\<p><a href="/dynamic">dynamic</a></p>
        \\</body></html>
    );
}

fn staticSite(ctx: *Application.Context) !void {
    return ctx.response.bytes(200, "text/html; charset=utf-8", "<html><body><h1>Hello from STATIC zig-http!</h1></body></html>");
}

fn dynamicSite(ctx: *Application.Context) !void {
    var previous = ctx.shared.counter.load(.monotonic);
    for (0..16) |_| {
        if (previous >= 1_000_000_000) return ctx.response.text(409, "counter limit reached");
        if (ctx.shared.counter.cmpxchgWeak(previous, previous + 1, .monotonic, .monotonic)) |changed| {
            previous = changed;
        } else return ctx.response.print(200, "text/html; charset=utf-8", "<html><body><h1>Hello # {d} from DYNAMIC zig-http!!!</h1></body></html>", .{previous + 1});
    }
    return ctx.response.text(503, "counter busy");
}

pub fn main(init: std.process.Init) !void {
    var shared: Shared = .{};
    const app = try Application.init(.{ .allocator = init.gpa, .io = init.io, .shared = &shared, .server = try support.config(init), .not_found = menu });
    defer app.deinit();
    try app.route("GET", "/", menu);
    try app.route("GET", "/static", staticSite);
    try app.route("GET", "/dynamic", dynamicSite);
    try support.run(app, init);
}
