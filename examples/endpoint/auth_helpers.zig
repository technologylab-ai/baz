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
