//! A local login example has one active session and 32 startup-generated tokens.
//! Credentials are public demo data. This example is not a production identity service.
//! The cookie has no Max-Age or Expires. Browser cookie lifetime differs from server session lifetime.
//! The server retains its active session until logout, replacement, or shutdown.
//! Tokens are opaque random bytes encoded as hex. This example does not implement JWT.
const std = @import("std");
const web = @import("baz");
const support = @import("example_support");

const Shared = struct {
    tokens: [32][64]u8 = undefined,
    used: usize = 0,
    active: ?usize = null,
    busy: std.atomic.Value(bool) = .init(false),
};
const Application = web.App(Shared);
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

fn login(ctx: *Context) !void {
    if (!acceptsPost(ctx.request)) return ctx.response.text(403, "Cross-origin POST rejected");
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

    const shared = ctx.shared;
    if (shared.busy.swap(true, .acquire)) return ctx.response.text(503, "Session state is busy");
    defer shared.busy.store(false, .release);
    if (shared.used == shared.tokens.len) return ctx.response.text(503, "Demo login capacity reached; restart the example");
    try ctx.response.setCookie(cookie_name, &shared.tokens[shared.used], .{ .same_site = .strict });
    try redirect(ctx, "/normal_page");
    // A new login replaces the prior session. A retired token never returns.
    shared.active = shared.used;
    shared.used += 1;
}

fn authenticated(shared: *const Shared, request: web.Request) bool {
    const active = shared.active orelse return false;
    const token = (request.cookie(cookie_name) catch return false) orelse return false;
    if (token.len != 64) return false;
    return std.crypto.timing_safe.eql([64]u8, token[0..64].*, shared.tokens[active]);
}

fn home(ctx: *Context) !void {
    if (ctx.shared.busy.swap(true, .acquire)) return ctx.response.text(503, "Session state is busy");
    defer ctx.shared.busy.store(false, .release);
    if (!authenticated(ctx.shared, ctx.request)) return redirect(ctx, "/login");
    try ctx.response.header("Cache-Control", "no-store");
    return ctx.response.borrowBody(200, "text/html; charset=utf-8", @embedFile("assets/session_home.html"));
}

fn logout(ctx: *Context) !void {
    if (!acceptsPost(ctx.request)) return ctx.response.text(403, "Cross-origin POST rejected");
    if (ctx.shared.busy.swap(true, .acquire)) return ctx.response.text(503, "Session state is busy");
    defer ctx.shared.busy.store(false, .release);
    if (!authenticated(ctx.shared, ctx.request)) return redirect(ctx, "/login");
    try ctx.response.deleteCookie(cookie_name, .{ .same_site = .strict });
    try redirect(ctx, "/login");
    ctx.shared.active = null;
}

fn stop(ctx: *Context) !void {
    if (!acceptsPost(ctx.request)) return ctx.response.text(403, "Cross-origin POST rejected");
    if (ctx.shared.busy.swap(true, .acquire)) return ctx.response.text(503, "Session state is busy");
    defer ctx.shared.busy.store(false, .release);
    if (!authenticated(ctx.shared, ctx.request)) return redirect(ctx, "/login");
    try ctx.response.text(200, "Stop requested");
    ctx.shared.active = null;
    ctx.app.requestStop();
}

pub fn main(init: std.process.Init) !void {
    var shared: Shared = .{};
    var entropy: [32][32]u8 = undefined;
    try init.io.randomSecure(std.mem.asBytes(&entropy));
    const hex = "0123456789abcdef";
    for (&shared.tokens, entropy) |*token, bytes| {
        for (bytes, 0..) |byte, index| {
            token[2 * index] = hex[byte >> 4];
            token[2 * index + 1] = hex[byte & 15];
        }
    }
    const app = try Application.init(.{ .allocator = init.gpa, .io = init.io, .shared = &shared, .server = try support.config(init) });
    defer app.deinit();
    try app.route("GET", "/login", loginPage);
    try app.route("POST", "/login", login);
    try app.route("POST", "/normal_page", login);
    try app.route("GET", "/normal_page", home);
    try app.route("GET", "/", home);
    try app.route("GET", "/logout", home);
    try app.route("POST", "/logout", logout);
    try app.route("POST", "/stop", stop);
    try support.run(app, init);
}
