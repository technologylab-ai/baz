//! Pure, bounded raw-path matching. No decoding or allocation.
const std = @import("std");

pub const max_segments = 32;
pub const max_captures = 16;
pub const Error = error{ InvalidMethod, InvalidRoute, TooManySegments, TooManyCaptures };

pub const Capture = struct { name: []const u8, value: []const u8 };
pub const Captures = struct {
    items: [max_captures]Capture = undefined,
    len: usize = 0,

    pub fn get(self: *const Captures, name: []const u8) ?[]const u8 {
        for (self.items[0..self.len]) |item| {
            if (std.mem.eql(u8, item.name, name)) return item.value;
        }
        return null;
    }
};

pub fn validMethod(method: []const u8) bool {
    if (method.len == 0 or method.len > 32) return false;
    for (method) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.findScalar(u8, "!#$%&'*+-.^_`|~", byte) == null)
            return false;
    }
    return true;
}

/// Earlier static segments outrank captures; registration order is irrelevant.
pub fn validate(pattern: []const u8) Error!u32 {
    if (pattern.len == 0 or pattern.len > 8192 or pattern[0] != '/') return error.InvalidRoute;
    var parts = std.mem.splitScalar(u8, pattern[1..], '/');
    var count: usize = 0;
    var captures: usize = 0;
    var rank: u32 = 0;
    while (parts.next()) |part| {
        if (count == max_segments) return error.TooManySegments;
        if (isCapture(part)) {
            if (part.len == 1 or !identifier(part[1..])) return error.InvalidRoute;
            if (captures == max_captures) return error.TooManyCaptures;
            var previous = std.mem.splitScalar(u8, pattern[1..], '/');
            for (0..count) |_| {
                const other = previous.next().?;
                if (isCapture(other) and std.mem.eql(u8, other, part)) return error.InvalidRoute;
            }
            captures += 1;
        } else {
            var at: usize = 0;
            while (at < part.len) : (at += 1) {
                const byte = part[at];
                if (byte <= 32 or byte >= 127 or std.mem.findScalar(u8, "?#[]\\", byte) != null)
                    return error.InvalidRoute;
                if (byte == '%') {
                    if (part.len - at < 3 or !std.ascii.isHex(part[at + 1]) or !std.ascii.isHex(part[at + 2]))
                        return error.InvalidRoute;
                    at += 2;
                }
            }
            rank |= @as(u32, 1) << @intCast(max_segments - 1 - count);
        }
        count += 1;
    }
    return rank;
}

fn identifier(bytes: []const u8) bool {
    if (bytes.len == 0 or (!std.ascii.isAlphabetic(bytes[0]) and bytes[0] != '_')) return false;
    for (bytes[1..]) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

fn isCapture(part: []const u8) bool {
    return part.len != 0 and part[0] == ':';
}

/// Pattern must first pass validate(). Empty segments are meaningful; a capture
/// cannot match an empty segment. Values remain slices of the supplied path.
pub fn matches(pattern: []const u8, path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    var patterns = std.mem.splitScalar(u8, pattern[1..], '/');
    var values = std.mem.splitScalar(u8, path[1..], '/');
    while (patterns.next()) |part| {
        const value = values.next() orelse return false;
        if (isCapture(part)) {
            if (value.len == 0) return false;
        } else if (!std.mem.eql(u8, part, value)) return false;
    }
    return values.next() == null;
}

/// True when two validated patterns differ only in capture names.
pub fn equivalent(a: []const u8, b: []const u8) bool {
    var left = std.mem.splitScalar(u8, a[1..], '/');
    var right = std.mem.splitScalar(u8, b[1..], '/');
    while (left.next()) |part| {
        const other = right.next() orelse return false;
        if (isCapture(part) and isCapture(other)) continue;
        if (!std.mem.eql(u8, part, other)) return false;
    }
    return right.next() == null;
}

pub fn capture(pattern: []const u8, path: []const u8) Captures {
    std.debug.assert(matches(pattern, path));
    var out: Captures = .{};
    var patterns = std.mem.splitScalar(u8, pattern[1..], '/');
    var values = std.mem.splitScalar(u8, path[1..], '/');
    while (patterns.next()) |part| {
        const value = values.next().?;
        if (isCapture(part)) {
            std.debug.assert(out.len < out.items.len);
            out.items[out.len] = .{ .name = part[1..], .value = value };
            out.len += 1;
        }
    }
    return out;
}

test "raw route captures preserve spelling and static precedence" {
    const path = "/users/a%2Fb";
    const pattern = "/users/:id";
    const rank = try validate(pattern);
    try std.testing.expect(rank < try validate("/users/new"));
    try std.testing.expect(matches(pattern, path));
    const found = capture(pattern, path);
    try std.testing.expectEqualStrings("a%2Fb", found.get("id").?);
    try std.testing.expectEqual(path[7..].ptr, found.get("id").?.ptr);
    try std.testing.expect(!matches(pattern, "/users/"));
    try std.testing.expect(!matches("/users", "/users-old"));
    try std.testing.expect(!matches("/users", "/users/"));
    try std.testing.expect(!matches("/users", "/Users"));
    try std.testing.expect(matches("/", "/"));
    try std.testing.expect(!matches("/a/b", "/a//b"));
}

test "registration validates patterns and detects capture aliases" {
    try std.testing.expect(equivalent("/users/:id", "/users/:name"));
    try std.testing.expect(!equivalent("/users/new", "/users/:id"));
    try std.testing.expectError(error.InvalidRoute, validate("/:id/:id"));
    try std.testing.expectError(error.InvalidRoute, validate("/x?y"));
    try std.testing.expectError(error.InvalidRoute, validate("/:"));
    try std.testing.expectError(error.InvalidRoute, validate("/%xz"));
    try std.testing.expectError(error.InvalidRoute, validate("/a\\b"));
    try std.testing.expect(validMethod("CUSTOM"));
    try std.testing.expect(!validMethod("GET\r\n"));
}
