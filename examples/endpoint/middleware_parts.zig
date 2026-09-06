//! Plain typed functions compose middleware without a second framework context.
const std = @import("std");
const web = @import("baz");

pub const Shared = struct { requests: std.atomic.Value(u64) = .init(0) };
pub const Application = web.App(Shared);
pub const User = struct { name: []const u8, email: []const u8 };
pub const Session = struct { info: []const u8, token: []const u8 };
pub const Locals = struct { user: ?User = null, session: ?Session = null };
pub const Decision = enum { continue_request, respond };

pub const UserMiddleware = struct {
    pub fn before(ctx: *Application.Context, locals: *Locals) !Decision {
        _ = ctx.shared.requests.fetchAdd(1, .monotonic);
        if (ctx.request.header("X-Deny")) |value| {
            if (std.mem.eql(u8, value, "1")) {
                try ctx.response.text(403, "Middleware stopped this request");
                return .respond;
            }
        }
        locals.user = .{ .name = "renerocksai", .email = "supa@secret.org" };
        return .continue_request;
    }
};

pub const SessionMiddleware = struct {
    pub fn before(_: *Application.Context, locals: *Locals) Decision {
        // This data demonstrates composition. It does not authenticate a session.
        locals.session = .{ .info = "secret session", .token = "rot47-asdlkfjsaklfdj" };
        return .continue_request;
    }
};

pub fn render(ctx: *Application.Context, locals: *const Locals) !void {
    if (locals.user) |user| {
        if (locals.session) |session| {
            return ctx.response.print(200, "text/plain; charset=utf-8", "User: {s} / {s}, Session: {s} / {s}", .{ user.name, user.email, session.info, session.token });
        }
    }
    return ctx.response.print(200, "text/plain; charset=utf-8", "User info found: {}, session info found: {}", .{ locals.user != null, locals.session != null });
}
