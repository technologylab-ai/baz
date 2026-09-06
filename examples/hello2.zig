//! Request inspection and a browser form. Diagnostics are returned as bounded
//! JSON at /inspect instead of performing blocking logging on an inline owner.
//! Form bytes stay raw; no automatic parameter or type conversion occurs.
const std = @import("std");
const web = @import("baz");
const support = @import("example_support");

const Shared = struct {};
const Application = web.App(Shared);

fn hello(ctx: *Application.Context) !void {
    return ctx.response.bytes(200, "text/html; charset=utf-8",
        \\<!doctype html><html><body>
        \\<h1>Hello from zig-http!!!</h1>
        \\<form action="/" method="post">
        \\<label>First name: <input name="fname"></label>
        \\<label>Last name: <input name="lname"></label>
        \\<button>Inspect request</button></form>
        \\<p><a href="/inspect?raw=x+y%20z">Inspect raw query bytes</a></p>
        \\</body></html>
    );
}

fn inspect(ctx: *Application.Context) !void {
    var storage: [2048]u8 = undefined;
    if (ctx.request.body().len() > storage.len) return ctx.response.text(413, "inspection body limit is 2048 bytes");
    const body = try ctx.request.body().copyTo(&storage);
    const special = ctx.request.header("special-header");
    if (special != null and special.?.len > 256) return ctx.response.text(431, "inspection special-header limit is 256 bytes");
    if (!std.unicode.utf8ValidateSlice(body) or (special != null and !std.unicode.utf8ValidateSlice(special.?)))
        return ctx.response.text(400, "inspection strings must be UTF-8");
    var headers = ctx.request.headers();
    var count: usize = 0;
    while (headers.next() != null) count += 1;
    const target = ctx.request.target();
    return ctx.response.jsonValue(200, .{
        .method = ctx.request.method(),
        .path = target.path,
        .query_raw = target.query_raw,
        .special_header = special,
        .header_count = count,
        .body_raw = body,
    });
}

pub fn main(init: std.process.Init) !void {
    var shared: Shared = .{};
    const app = try Application.init(.{ .allocator = init.gpa, .io = init.io, .shared = &shared, .server = try support.config(init), .response = .{ .body_bytes = 32768 } });
    defer app.deinit();
    try app.route("GET", "/", hello);
    try app.route("POST", "/", inspect);
    try app.route("GET", "/inspect", inspect);
    try app.route("POST", "/inspect", inspect);
    try support.run(app, init);
}
