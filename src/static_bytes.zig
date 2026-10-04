//! Compile-time construction of immutable byte fixtures without heap allocation.
const std = @import("std");

/// Repeat a byte pattern and retain the string sentinel outside its payload.
/// Prefix doubling bounds evaluator iterations even for multi-megabyte assets.
pub fn repeat(comptime pattern: []const u8, comptime count: usize) [pattern.len * count:0]u8 {
    const length = pattern.len * count;
    // A fully defined byte buffer avoids quadratic partially defined aggregate
    // updates in the 0.17 comptime evaluator for the multi-megabyte fixtures.
    var bytes: [length:0]u8 = @splat(0);
    if (length == 0) return bytes;
    @memcpy(bytes[0..pattern.len], pattern);
    var initialized = pattern.len;
    while (initialized < length) {
        const next = @min(initialized, length - initialized);
        @memcpy(bytes[initialized..][0..next], bytes[0..next]);
        initialized += next;
    }
    return bytes;
}

test "static repetition retains binary octets payload bounds and sentinel" {
    const bytes = comptime repeat("\x00\xffA", 3);
    try std.testing.expectEqualStrings("\x00\xffA\x00\xffA\x00\xffA", &bytes);
    try std.testing.expectEqual(@as(u8, 0), bytes[bytes.len]);
    const empty_pattern = comptime repeat("", 5);
    const empty_count = comptime repeat("unused", 0);
    try std.testing.expectEqualStrings("", &empty_pattern);
    try std.testing.expectEqualStrings("", &empty_count);
    try std.testing.expectEqual(@as(u8, 0), empty_pattern[0]);
    try std.testing.expectEqual(@as(u8, 0), empty_count[0]);
}
