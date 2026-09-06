//! Shared example helpers keep authentication inputs as bounded borrowed bytes.
const std = @import("std");
const web = @import("baz");

pub fn bearer(comptime length: usize, request: web.Request, expected: *const [length]u8) bool {
    var authorization: ?[]const u8 = null;
    var fields = request.headers();
    while (fields.next()) |field| {
        if (!std.ascii.eqlIgnoreCase(field.name_raw, "Authorization")) continue;
        if (authorization != null) return false;
        authorization = field.value_raw;
    }
    const value = authorization orelse return false;
    if (value.len != "Bearer ".len + length or !std.ascii.eqlIgnoreCase(value[0..6], "Bearer")) return false;
    if (value[6] != ' ') return false;
    return std.crypto.timing_safe.eql([length]u8, value[7..][0..length].*, expected.*);
}

pub const Cookie = struct { name_raw: []const u8, value_raw: []const u8, quoted: bool };
pub const Cookies = struct {
    items: [16]Cookie = undefined,
    len: usize = 0,

    pub fn unique(self: *const Cookies, name: []const u8) error{DuplicateCookie}!?[]const u8 {
        var result: ?[]const u8 = null;
        for (self.items[0..self.len]) |item| {
            if (!std.mem.eql(u8, item.name_raw, name)) continue;
            if (result != null) return error.DuplicateCookie;
            result = item.value_raw;
        }
        return result;
    }
};

/// Cookie values retain percent escapes and plus bytes. Duplicate order survives.
pub fn cookies(request: web.Request) error{ MalformedCookie, TooManyCookies }!Cookies {
    var result: Cookies = .{};
    var fields = request.headers();
    while (fields.next()) |field| {
        if (!std.ascii.eqlIgnoreCase(field.name_raw, "Cookie")) continue;
        var pairs = std.mem.splitScalar(u8, field.value_raw, ';');
        while (pairs.next()) |raw_pair| {
            const pair = std.mem.trim(u8, raw_pair, " \t");
            if (pair.len == 0) return error.MalformedCookie;
            const equal = std.mem.findScalar(u8, pair, '=') orelse return error.MalformedCookie;
            const name = pair[0..equal];
            if (name.len == 0) return error.MalformedCookie;
            for (name) |byte| if (!web.form.token(byte)) return error.MalformedCookie;
            var value = pair[equal + 1 ..];
            const quoted = value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"';
            if (quoted) value = value[1 .. value.len - 1];
            for (value) |byte| {
                if (!(byte == 0x21 or (byte >= 0x23 and byte <= 0x2b) or
                    (byte >= 0x2d and byte <= 0x3a) or (byte >= 0x3c and byte <= 0x5b) or
                    (byte >= 0x5d and byte <= 0x7e))) return error.MalformedCookie;
            }
            if (result.len == result.items.len) return error.TooManyCookies;
            result.items[result.len] = .{ .name_raw = name, .value_raw = value, .quoted = quoted };
            result.len += 1;
        }
    }
    return result;
}
