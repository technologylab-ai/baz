//! Public middleware protects a local login example with 32 reusable session slots.
//! Credentials are public demo data. This example is not a production identity service.
//! Server sessions expire after 30 minutes by default. Authentication never extends that deadline.
//! The browser cookie has no Max-Age or Expires. The server enforces its own lifetime.
//! Tokens use a startup secret and a checked counter. This example does not implement JWT.
const std = @import("std");
const web = @import("baz");
const support = @import("example_support");
const sessions = @import("endpoint/session_store.zig");
const Options = @import("endpoint/session_options.zig").Options;

const Shared = struct {
    sessions: sessions.Store(32),
    ttl_ns: u64,
    busy: std.atomic.Value(bool) = .init(false),
};
const Locals = struct { user_id: ?sessions.Identity = null, token: ?[]const u8 = null };
const Application = web.AppWithLocals(Shared, Locals);
const Context = Application.Context;
const cookie_name = "demo-session";

fn redirect(ctx: *Context, path: []const u8) !void {
    try ctx.response.header("Cache-Control", "no-store");
    return ctx.response.redirect(303, path);
}

fn loginPage(ctx: *Context) !void {
    try ctx.response.header("Cache-Control", "no-store");
    return ctx.response.borrowBody(200, "text/html; charset=utf-8", @embedFile("assets/session_login.html"));
}

// Reject explicit cross-origin browser POSTs. Clients without Fetch Metadata remain allowed.
fn acceptsPost(request: web.Request) bool {
    var seen = false;
    var headers = request.headers();
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name_raw, "Sec-Fetch-Site")) continue;
        if (seen) return false;
        seen = true;
        if (!std.mem.eql(u8, header.value_raw, "same-origin") and
            !std.mem.eql(u8, header.value_raw, "none")) return false;
    }
    return true;
}

fn guardPost(ctx: *Context) !Application.Decision {
    if (std.mem.eql(u8, ctx.request.method(), "POST") and !acceptsPost(ctx.request)) {
        try ctx.response.text(403, "Cross-origin POST rejected");
        return .respond;
    }
    return .continue_request;
}

// Read the clock under the session guard, so concurrent callbacks cannot reorder timestamps.
// The boot clock requests suspend-inclusive time. Platform implementations can differ.
fn now(ctx: *Context) !u64 {
    return std.math.cast(u64, std.Io.Clock.boot.now(ctx.app.io).nanoseconds) orelse error.InvalidSessionClock;
}

fn login(ctx: *Context) !void {
    var body_buffer: [1024]u8 = undefined;
    const limits: web.params.Limits = .{ .max_bytes = body_buffer.len, .max_pairs = 2, .max_name_bytes = 16, .max_value_bytes = 128 };
    const fields = ctx.request.formUrlEncoded(limits) catch |err| switch (err) {
        error.BodyNotContiguous => blk: {
            const bytes = try ctx.request.body().copyTo(&body_buffer);
            break :blk try web.form.parse(bytes, limits);
        },
        else => return err,
    };
    var usernames = fields.allRaw("username");
    var passwords = fields.allRaw("password");
    const username = usernames.next() orelse return ctx.response.text(400, "username is required");
    const password = passwords.next() orelse return ctx.response.text(400, "password is required");
    if (usernames.next() != null or passwords.next() != null) return ctx.response.text(400, "Duplicate credentials");
    var user_buffer: [128]u8 = undefined;
    var password_buffer: [128]u8 = undefined;
    const user = try web.params.formDecodeInto(username.value_raw, &user_buffer);
    const pass = try web.params.formDecodeInto(password.value_raw, &password_buffer);
    if (!std.mem.eql(u8, user, "zap") or pass.len != 7 or
        !std.crypto.timing_safe.eql([7]u8, pass[0..7].*, "awesome".*))
        return ctx.response.text(401, "Invalid demo credentials");

    const previous = ctx.request.cookie(cookie_name) catch return ctx.response.text(400, "Invalid session cookie");
    const shared = ctx.shared;
    if (shared.busy.swap(true, .acquire)) return ctx.response.text(503, "Session state is busy");
    defer shared.busy.store(false, .release);
    const token = shared.sessions.create(1, try now(ctx), shared.ttl_ns) catch |err| switch (err) {
        error.Full => return ctx.response.text(503, "All 32 session slots are active; log out or wait for expiry"),
        else => return err,
    };
    errdefer _ = shared.sessions.revoke(&token) catch false;
    try ctx.response.setCookie(cookie_name, &token, .{ .same_site = .strict });
    try redirect(ctx, "/normal_page");
    // Rotate only the presented token after response preparation. Other devices remain signed in.
    if (previous) |old| _ = shared.sessions.revoke(old) catch false;
}

fn authenticate(ctx: *Context) !Application.Decision {
    const token = (ctx.request.cookie(cookie_name) catch null) orelse {
        try redirect(ctx, "/login");
        return .respond;
    };
    if (ctx.shared.busy.swap(true, .acquire)) {
        try ctx.response.text(503, "Session state is busy");
        return .respond;
    }
    defer ctx.shared.busy.store(false, .release);
    ctx.locals.user_id = ctx.shared.sessions.authenticate(token, try now(ctx)) catch |err| switch (err) {
        error.InvalidToken => null,
        else => return err,
    };
    if (ctx.locals.user_id == null) {
        try redirect(ctx, "/login");
        return .respond;
    }
    ctx.locals.token = token;
    // The copied identity authorizes this request. Later revocation does not cancel an admitted request.
    return .continue_request;
}

fn home(ctx: *Context) !void {
    try ctx.response.header("Cache-Control", "no-store");
    return ctx.response.borrowBody(200, "text/html; charset=utf-8", @embedFile("assets/session_home.html"));
}

fn logout(ctx: *Context) !void {
    return endSession(ctx, false);
}

fn logoutAll(ctx: *Context) !void {
    return endSession(ctx, true);
}

fn endSession(ctx: *Context, all_devices: bool) !void {
    if (ctx.shared.busy.swap(true, .acquire)) return ctx.response.text(503, "Session state is busy");
    defer ctx.shared.busy.store(false, .release);
    try ctx.response.deleteCookie(cookie_name, .{ .same_site = .strict });
    try redirect(ctx, "/login");
    if (all_devices) {
        _ = ctx.shared.sessions.revokeIdentity(ctx.locals.user_id.?);
    } else {
        _ = try ctx.shared.sessions.revoke(ctx.locals.token.?);
    }
}

fn stop(ctx: *Context) !void {
    try ctx.response.text(200, "Stop requested");
    ctx.app.requestStop();
}

pub fn main(init: std.process.Init) !void {
    const options = try support.parseOptions(init, Options);
    const ttl_ns = try options.ttlNanoseconds();
    var key: sessions.Key = undefined;
    try init.io.randomSecure(&key);
    var shared: Shared = .{ .sessions = .init(key), .ttl_ns = ttl_ns };
    std.crypto.secureZero(u8, &key);
    defer shared.sessions.deinit();
    const app = try Application.init(.{
        .allocator = init.gpa,
        .io = init.io,
        .shared = &shared,
        .server = try support.configFromOptions(options, false),
        .middleware = &.{.{ .before = guardPost }},
    });
    defer app.deinit();
    try app.route("GET", "/login", loginPage);
    try app.route("POST", "/login", login);
    try app.route("POST", "/normal_page", login);
    const protected: Application.RouteOptions = .{ .middleware = &.{.{ .before = authenticate }} };
    try app.routeWith("GET", "/normal_page", home, protected);
    try app.routeWith("GET", "/", home, protected);
    try app.routeWith("GET", "/logout", home, protected);
    try app.routeWith("POST", "/logout", logout, protected);
    try app.routeWith("POST", "/logout-all", logoutAll, protected);
    try app.routeWith("POST", "/stop", stop, protected);
    try support.run(app, init);
}
