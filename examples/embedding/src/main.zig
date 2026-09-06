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
