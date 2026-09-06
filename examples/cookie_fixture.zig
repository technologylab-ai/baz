//! Public cookie and redirect wire fixture. Uses the shared portable lifecycle.
const std = @import("std");
const web = @import("baz");
const support = @import("example_support");

const Shared = struct {};
const Application = web.App(Shared);
const Context = Application.Context;
const future_expiry = 1893456000; // 2030-01-01 00:00:00 UTC.
const minimal: web.cookies.Options = .{ .path = null, .http_only = false, .same_site = null };

fn set(ctx: *Context) !void {
    try ctx.response.setCookie("session", "opaque%2B+001", .{});
    try ctx.response.setCookie("remember", "yes", .{
        .path = "/prefs",
        .domain = "example.test",
        .max_age = 3600,
        .expires = future_expiry,
        .secure = true,
        .http_only = false,
        .same_site = .strict,
    });
    try ctx.response.setCookie("zero", "gone", .{ .max_age = 0 });
    try ctx.response.setCookie("negative", "gone", .{ .max_age = -7 });
    try ctx.response.deleteCookie("retired", .{
        .path = "/account",
        .domain = "example.test",
        .max_age = 7200,
        .expires = future_expiry,
        .secure = true,
        .same_site = .none,
    });
    try ctx.response.setCookie("minimal", "raw", minimal);
    try ctx.response.setCookie("repeat", "first", .{ .path = "/one" });
    try ctx.response.setCookie("repeat", "second", .{ .path = "/two" });
    return ctx.response.text(200, "cookies");
}

fn expiresOnly(ctx: *Context) !void {
    try ctx.response.setCookie("expires-only", "present", .{ .expires = future_expiry });
    return ctx.response.text(200, "ok");
}

fn inspect(ctx: *Context) !void {
    const parsed = (if (std.mem.eql(u8, ctx.request.path().?, "/bounded"))
        ctx.request.cookiesWithLimits(.{ .max_bytes = 96, .max_pairs = 4, .max_name_bytes = 16, .max_value_bytes = 32 })
    else
        ctx.request.cookies()) catch |err| return ctx.response.text(switch (err) {
        error.MalformedCookie, error.MalformedHeaders => 400,
        else => 431,
    }, @errorName(err));
    const selected = parsed.uniqueRaw("sid") catch |err| return ctx.response.text(400, @errorName(err));
    var items: [32]web.cookies.Cookie = undefined;
    var iterator = parsed.iterator();
    var count: usize = 0;
    while (iterator.next()) |item| : (count += 1) items[count] = item;
    return ctx.response.jsonValue(200, .{ .count = parsed.count, .items = items[0..count], .sid = selected });
}

fn cookie(ctx: *Context) !void {
    const selected = ctx.request.cookie("sid") catch |err| return ctx.response.text(400, @errorName(err));
    return ctx.response.jsonValue(200, .{ .sid = selected });
}

fn defaultCookie(ctx: *Context) !void {
    return ctx.response.jsonValue(200, .{ .sid = try ctx.request.cookie("sid") });
}

fn defaultBounded(ctx: *Context) !void {
    const parsed = try ctx.request.cookiesWithLimits(.{ .max_bytes = 96, .max_pairs = 4, .max_name_bytes = 16, .max_value_bytes = 32 });
    _ = try parsed.uniqueRaw("sid");
    return ctx.response.text(200, "ok");
}

fn rejectedCookie(ctx: *Context) !void {
    const Probe = enum { name, value, path, domain, expiry, insecure, secure_prefix, host_prefix, header_limit };
    const probe = std.meta.stringToEnum(Probe, ctx.param("probe").?) orelse return ctx.response.text(404, "unknown probe");
    try ctx.response.setCookie("before", "kept", .{});
    const attempted = switch (probe) {
        .name => ctx.response.setCookie("bad name", "x", .{}),
        .value => ctx.response.setCookie("bad", "x; injected=y", .{}),
        .path => ctx.response.setCookie("bad", "x", .{ .path = "/ok\r\nInjected: yes" }),
        .domain => ctx.response.setCookie("bad", "x", .{ .domain = "bad; injected=y" }),
        .expiry => ctx.response.setCookie("bad", "x", .{ .expires = 253402300800 }),
        .insecure => ctx.response.setCookie("bad", "x", .{ .same_site = .none }),
        .secure_prefix => ctx.response.setCookie("__Secure-token", "x", .{}),
        .host_prefix => ctx.response.setCookie("__Host-token", "x", .{ .secure = true, .path = "/elsewhere" }),
        .header_limit => ctx.response.setCookie("huge", "x" ** 1024, .{}),
    };
    if (attempted) |_| {
        return error.ExpectedCookieFailure;
    } else |err| {
        try ctx.response.setCookie("after", "kept", .{});
        return ctx.response.text(200, @errorName(err));
    }
}

fn countLimit(ctx: *Context) !void {
    for (0..8) |index| {
        var buffer: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&buffer, "c{d}", .{index});
        try ctx.response.setCookie(name, "1", minimal);
    }
    if (ctx.response.setCookie("extra", "discarded", minimal)) |_| {
        return error.ExpectedCookieFailure;
    } else |err| {
        return ctx.response.text(200, @errorName(err));
    }
}

fn streamCookie(ctx: *Context) !void {
    if (ctx.app.config.execution != .workers) return ctx.response.text(409, "workers required");
    try ctx.response.setCookie("stream", "initial", .{});
    var stream = try ctx.response.stream(200, "text/plain", .{});
    try stream.writeAll("first|");
    try stream.flush();
    if (ctx.response.setCookie("late", "discarded", .{})) |_| {
        return error.ExpectedCookieFailure;
    } else |err| {
        try stream.print("{s}|", .{@errorName(err)});
    }
    try stream.writeAll("last");
    try stream.finish();
}

fn redirect(ctx: *Context) !void {
    const status = std.fmt.parseInt(u16, ctx.param("status").?, 10) catch return ctx.response.text(400, "invalid status");
    return ctx.response.redirect(status, "https://example.test/next?raw=a%2Bb#part");
}

fn rejectedRedirect(ctx: *Context) !void {
    const Probe = enum { status, empty, space, backslash, escape, non_ascii, crlf, quote, brackets, duplicate };
    const probe = std.meta.stringToEnum(Probe, ctx.param("probe").?) orelse return ctx.response.text(404, "unknown probe");
    try ctx.response.setCookie("before", "kept", .{});
    if (probe == .duplicate) try ctx.response.header("Location", "/kept");
    const attempted = switch (probe) {
        .status => ctx.response.redirect(200, "/safe"),
        .empty => ctx.response.redirect(303, ""),
        .space => ctx.response.redirect(303, "/two words"),
        .backslash => ctx.response.redirect(303, "/bad\\path"),
        .escape => ctx.response.redirect(303, "/bad%GG"),
        .non_ascii => ctx.response.redirect(303, "/caf\xc3\xa9"),
        .crlf => ctx.response.redirect(303, "/safe\r\nInjected: yes"),
        .quote => ctx.response.redirect(303, "/bad\"uri"),
        .brackets => ctx.response.redirect(303, "/<bad>{uri}|^`"),
        .duplicate => ctx.response.redirect(303, "/discarded"),
    };
    if (attempted) |_| {
        return error.ExpectedRedirectFailure;
    } else |err| {
        try ctx.response.setCookie("after", "kept", .{});
        return ctx.response.text(200, @errorName(err));
    }
}

fn ping(ctx: *Context) !void {
    return ctx.response.text(200, "ok");
}

pub fn main(init: std.process.Init) !void {
    var shared: Shared = .{};
    const app = try Application.init(.{
        .allocator = init.gpa,
        .io = init.io,
        .shared = &shared,
        .server = try support.config(init),
        .response = .{ .header_bytes = 1024, .max_headers = 8, .body_bytes = 8192 },
    });
    defer app.deinit();
    try app.route("GET", "/set", set);
    try app.route("GET", "/expires-only", expiresOnly);
    try app.route("GET", "/inspect", inspect);
    try app.route("GET", "/bounded", inspect);
    try app.route("GET", "/cookie", cookie);
    try app.route("GET", "/default-cookie", defaultCookie);
    try app.route("GET", "/default-bounded", defaultBounded);
    try app.route("GET", "/invalid-cookie/:probe", rejectedCookie);
    try app.route("GET", "/limit-count", countLimit);
    try app.route("GET", "/stream-cookie", streamCookie);
    try app.route("GET", "/redirect/:status", redirect);
    try app.route("POST", "/redirect/:status", redirect);
    try app.route("GET", "/invalid-redirect/:probe", rejectedRedirect);
    try app.route("GET", "/ping", ping);
    try support.run(app, init);
}
