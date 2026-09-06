//! Small immutable application data and JSON output. Path conversion is an
//! explicit application decision; malformed/overflowing IDs are ordinary 400s.
const std = @import("std");
const web = @import("baz");
const support = @import("example_support");

const User = struct { first_name: ?[]const u8 = null, last_name: ?[]const u8 = null };
const Shared = struct {
    users: [2]User = .{
        .{ .first_name = "renerocksai" },
        .{ .first_name = "Your", .last_name = "Mom" },
    },
};
const Application = web.App(Shared);

fn user(ctx: *Application.Context) !void {
    const raw = ctx.param("id").?;
    for (raw) |byte| if (byte < '0' or byte > '9') return ctx.response.text(400, "invalid user id");
    const id = std.fmt.parseInt(u32, raw, 10) catch return ctx.response.text(400, "invalid user id");
    if (id == 0 or id > ctx.shared.users.len) return ctx.response.jsonValue(404, @as(?User, null));
    return ctx.response.jsonValue(200, ctx.shared.users[id - 1]);
}

pub fn main(init: std.process.Init) !void {
    var shared: Shared = .{};
    const app = try Application.init(.{ .allocator = init.gpa, .io = init.io, .shared = &shared, .server = try support.config(init) });
    defer app.deinit();
    try app.route("GET", "/user/:id", user);
    try support.run(app, init);
}
