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

test "consumer can borrow cookie tokens and publish cookies with an empty redirect" {
    var parser = engine.api.http.Parser.init(.{});
    const raw = (try parser.parse("GET / HTTP/1.1\r\nHost: localhost\r\nCookie: sid=opaque.jwt.bytes\r\n\r\n")).?;
    const request = web.Request.init(&raw);
    try std.testing.expectEqualStrings("opaque.jwt.bytes", (try request.cookie("sid")).?);
    const options: web.cookies.Options = .{ .max_age = 3600, .same_site = .strict };
    var arena: [1024]u8 = undefined;
    var cache: engine.api.HeaderCache = .{};
    cache.refresh("Sun, 06 Sep 2026 12:00:00 GMT");
    var writer = engine.api.Writer.init(&arena, &cache, 0);
    writer.open(0, true, false);
    var response = try web.Response.init(&writer, .{ .header_bytes = 256, .body_bytes = 0 });
    try response.setCookie("sid", "replacement", options);
    try response.deleteCookie("old", .{});
    try response.redirect(303, "/account");
    _ = try response.finish();
    try std.testing.expectEqual(@as(u16, 303), writer.status);
    try std.testing.expectEqualStrings("", writer.committed());
    try std.testing.expect(std.mem.indexOf(u8, arena[0..writer.body_start], "Max-Age=3600") != null);
}

test "consumer registers typed locals and copied route middleware" {
    const Shared = struct {};
    const Application = web.AppWithLocals(Shared, struct { user_id: ?u64 = null });
    const Hooks = struct {
        fn authorize(ctx: *Application.Context) !Application.Decision {
            ctx.locals.user_id = 42;
            return .continue_request;
        }
        fn page(ctx: *Application.Context) !void {
            try ctx.response.text(200, if (ctx.locals.user_id != null) "authorized" else "missing");
        }
    };
    var shared: Shared = .{};
    const app = try Application.init(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .shared = &shared,
        .server = .{ .connections = 1, .shards = 1 },
    });
    defer app.deinit();
    try app.routeWith("GET", "/account", Hooks.page, .{ .middleware = &.{.{ .before = Hooks.authorize }} });
}

test "consumer registers bounded typed continuations and rejects disabled or oversized state" {
    const Shared = struct {};
    const Application = web.App(Shared);
    const State = struct { count: u32 = 0 };
    const H = struct {
        fn start(ctx: *Application.Context, _: *State) !web.continuation.Step {
            var out = try ctx.response.snapshot(200, "text/plain", .{});
            try out.writeAll("first");
            return .flush;
        }
        fn advance(ctx: *Application.Context, state: *State, event: web.continuation.Event) !web.continuation.Step {
            if (event == .flushed) return .{ .wait = 1 };
            state.count += 1;
            var out = try ctx.response.resumeSnapshot();
            try out.print("{d}", .{state.count});
            return .finish;
        }
    };
    var shared: Shared = .{};
    const base: Application.Options = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .shared = &shared,
        .server = .{ .connections = 1, .shards = 1 },
    };
    const disabled = try Application.init(base);
    defer disabled.deinit();
    try std.testing.expectError(error.ContinuationsDisabled, disabled.routeContinuation("GET", "/", State, H.start, H.advance, .{}));
    var options = base;
    options.max_continuations = 1;
    options.max_continuation_state_bytes = 1;
    const small = try Application.init(options);
    defer small.deinit();
    try std.testing.expectError(error.ContinuationStateTooLarge, small.routeContinuation("GET", "/", State, H.start, H.advance, .{}));
    options.max_continuation_state_bytes = @sizeOf(State);
    const app = try Application.init(options);
    defer app.deinit();
    try app.routeContinuation("GET", "/", State, H.start, H.advance, .{});
}
