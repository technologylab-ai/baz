//! The session example adds an explicit server lifetime to the common CLI options.
const std = @import("std");

pub const Options = struct {
    port: u16 = 8080,
    duration_ms: u32 = 0,
    execution: enum { @"inline", workers } = .@"inline",
    workers: ?u16 = null,
    connections: u16 = 16,
    shards: u8 = 1,
    session_ttl_ms: u32 = 30 * 60 * 1000,

    pub const aliases = .{ .port = "p" };
    pub const help =
        \\Baz session example — Zig 0.16.0
        \\Usage: userpass_session [options]
        \\
        \\  -h, --help                    Show this help and exit
        \\  -p, --port N                  Listen port; 0 selects an available port (default: 8080)
        \\      --duration-ms N           Stop after N milliseconds; 0 waits for shutdown
        \\      --execution inline|workers
        \\      --workers N               Worker count (default: 2 for workers, 0 for inline)
        \\      --connections N           Connection slots (default: 16)
        \\      --shards N                I/O shards (default: 1)
        \\      --session-ttl-ms N        Server session lifetime; positive (default: 1800000)
        \\
        \\Options accept both --port 8080 and --port=8080. Repeated options are errors.
        \\This example defaults to inline execution. The browser cookie remains a session cookie.
    ;

    pub fn ttlNanoseconds(self: Options) !u64 {
        if (self.session_ttl_ms == 0) return error.InvalidSessionTtl;
        return @as(u64, self.session_ttl_ms) * std.time.ns_per_ms;
    }
};

test "session lifetime rejects zero and preserves the full CLI range" {
    try std.testing.expectError(error.InvalidSessionTtl, (Options{ .session_ttl_ms = 0 }).ttlNanoseconds());
    try std.testing.expectEqual(@as(u64, 1800 * std.time.ns_per_s), try (Options{}).ttlNanoseconds());
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u32)) * std.time.ns_per_ms, try (Options{ .session_ttl_ms = std.math.maxInt(u32) }).ttlNanoseconds());
}
