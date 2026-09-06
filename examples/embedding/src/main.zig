const std = @import("std");
const web = @import("baz");
const engine = @import("bounded_http");

test "consumer mixes framework and dependency types without duplicate engine identity" {
    try std.testing.expect(web.engine == engine);
    try std.testing.expect(web.Config == engine.Config);
    try std.testing.expect(web.api.Writer == engine.api.Writer);
    var parser = engine.api.http.Parser.init(.{});
    var raw = (try parser.parse("GET /?q=001 HTTP/1.1\r\nHost: localhost\r\n\r\n")).?;
    const request = web.Request.init(&raw);
    try std.testing.expect(request.raw == &raw);
    try std.testing.expectEqualStrings("001", (try request.query()).firstRaw("q").?.value_raw);

    var shared: struct {} = .{};
    const Application = web.App(@TypeOf(shared));
    const app = try Application.init(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .shared = &shared,
        .server = engine.Config{ .connections = 1, .shards = 1 },
    });
    defer app.deinit();
}

test "consumer parses Mustache partials and publishes an escaped HTML response" {
    var template = try web.mustache.Template.init(std.testing.allocator, "<h1>{{title}}</h1>{{#users}}{{>user}}{{/users}}", .{
        .partials = &.{.{ .name = "user", .source = "<p>{{name}} / {{site.name}}</p>" }},
    });
    defer template.deinit();
    var arena: [1024]u8 = undefined;
    var cache: engine.api.HeaderCache = .{};
    cache.refresh("Sun, 06 Sep 2026 12:00:00 GMT");
    var writer = engine.api.Writer.init(&arena, &cache, 0);
    writer.open(0, true, false);
    var response = try web.Response.init(&writer, .{ .header_bytes = 64, .body_bytes = 256 });
    const User = struct { name: []const u8 };
    try response.mustache(200, &template, .{
        .title = "<Hello>",
        .site = .{ .name = "Baz" },
        .users = &[_]User{ .{ .name = "Rene" }, .{ .name = "Caro" } },
    });
    try std.testing.expect(!writer.began);
    try std.testing.expectEqual(engine.api.Action.finish, try response.finish());
    try std.testing.expectEqualStrings("<h1>&lt;Hello&gt;</h1><p>Rene / Baz</p><p>Caro / Baz</p>", writer.committed());
    try std.testing.expect(std.mem.indexOf(u8, arena[0..writer.body_start], "Content-Type: text/html; charset=utf-8\r\n") != null);
}
