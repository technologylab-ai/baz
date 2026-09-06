//! Parse once at startup. Render typed data into the reserved HTML response.
const std = @import("std");
const web = @import("baz");
const support = @import("example_support");

const User = struct { id: u8, name: []const u8, profile: struct { role: []const u8 } };
const Shared = struct {
    template: web.mustache.Template,
    users: [2]User = .{
        .{ .id = 1, .name = "Rene", .profile = .{ .role = "Making things work." } },
        .{ .id = 6, .name = "Caro", .profile = .{ .role = "Making things wonderful." } },
    },
};
const Application = web.App(Shared);

fn hello(ctx: *Application.Context) !void {
    const query = ctx.request.queryWithLimits(.{ .max_pairs = 8, .max_bytes = 8192 }) catch
        return ctx.response.text(400, "invalid greeting query");
    var names = query.allRaw("name");
    var decoded: [2048]u8 = undefined;
    const name = if (names.next()) |field|
        web.params.formDecodeInto(field.value_raw, &decoded) catch
            return ctx.response.text(400, "name must fit 2048 bytes with valid URL escapes")
    else
        "friend";
    if (names.next() != null or !std.unicode.utf8ValidateSlice(name))
        return ctx.response.text(400, "name must be one UTF-8 value");

    return ctx.response.mustache(200, &ctx.shared.template, .{
        .name = name,
        .page = .{ .title = "A little company.", .community = "The Baz community" },
        .users = &ctx.shared.users,
    });
}

pub fn main(init: std.process.Init) !void {
    const config = try support.config(init);
    var shared: Shared = .{ .template = try web.mustache.Template.init(init.gpa, @embedFile("assets/mustache.html"), .{
        .partials = &.{.{ .name = "user", .source = @embedFile("assets/mustache-user.html") }},
    }) };
    defer shared.template.deinit();
    const app = try Application.init(.{
        .allocator = init.gpa,
        .io = init.io,
        .shared = &shared,
        .server = config,
        .response = .{ .body_bytes = 8192 },
    });
    defer app.deinit();
    try app.route("GET", "/", hello);
    try support.run(app, init);
}
