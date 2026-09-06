//! Fixed-capacity session storage for the local authentication example.
//! The caller supplies synchronization and monotonic nanoseconds, preferably from `std.Io.Clock.boot`.
//! The caller creates a fresh random key at startup. Never reset a counter with the same key.
//! Do not copy a live store. Authentication returns a copied identity, without borrowing session storage.
//! Browser cookie lifetime does not change the absolute server deadline.
const std = @import("std");

pub const Identity = u64;
pub const Token = [64]u8;
pub const Key = [32]u8;

pub fn Store(comptime capacity: usize) type {
    if (capacity == 0) @compileError("Session capacity must be positive");
    return struct {
        const Self = @This();
        const Entry = struct {
            token: [32]u8 = @splat(0),
            identity: Identity = 0,
            expires_ns: u64 = 0,
            occupied: bool = false,
        };

        key: Key,
        entries: [capacity]Entry = @splat(.{}),
        counter: u64 = 0,
        last_now_ns: u64 = 0,

        pub fn init(key: Key) Self {
            return .{ .key = key };
        }

        pub fn deinit(self: *Self) void {
            std.crypto.secureZero(u8, &self.key);
            for (&self.entries) |*entry| clear(entry);
            self.* = undefined;
        }

        /// Create a separate session. A full store never evicts a live session.
        /// Failed creation preserves entries, the token counter, and the time watermark.
        pub fn create(self: *Self, identity: Identity, now_ns: u64, ttl_ns: u64) !Token {
            try self.checkTime(now_ns);
            if (ttl_ns == 0) return error.InvalidTtl;
            const expires_ns = std.math.add(u64, now_ns, ttl_ns) catch return error.ExpiryOverflow;
            const counter = std.math.add(u64, self.counter, 1) catch return error.CounterExhausted;
            var available: ?*Entry = null;
            for (&self.entries) |*entry| {
                if (!entry.occupied or now_ns >= entry.expires_ns) {
                    available = entry;
                    break;
                }
            }
            const entry = available orelse return error.Full;

            // HMAC-SHA256 uses the standard implementation and a unique, domain-separated input.
            // The counter does not contain identity data. The full digest becomes the opaque token.
            var counter_bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &counter_bytes, counter, .big);
            var mac = std.crypto.auth.hmac.sha2.HmacSha256.init(&self.key);
            mac.update("baz/example/session/v1\x00");
            mac.update(&counter_bytes);
            var digest: [32]u8 = undefined;
            mac.final(&digest);
            defer std.crypto.secureZero(u8, &digest);

            entry.* = .{ .token = digest, .identity = identity, .expires_ns = expires_ns, .occupied = true };
            self.counter = counter;
            self.last_now_ns = now_ns;
            return encode(digest);
        }

        /// Return null for an unknown, expired, or revoked token. Reject malformed token text.
        /// Authentication never extends expiry. The caller must validate authorization separately.
        pub fn authenticate(self: *Self, token: []const u8, now_ns: u64) !?Identity {
            var digest = try decode(token);
            defer std.crypto.secureZero(u8, &digest);
            _ = try self.expire(now_ns);
            for (self.entries) |entry| {
                if (entry.occupied and std.crypto.timing_safe.eql([32]u8, digest, entry.token))
                    return entry.identity;
            }
            return null;
        }

        /// Remove this token without changing other sessions for the same identity.
        pub fn revoke(self: *Self, token: []const u8) !bool {
            var digest = try decode(token);
            defer std.crypto.secureZero(u8, &digest);
            for (&self.entries) |*entry| {
                if (entry.occupied and std.crypto.timing_safe.eql([32]u8, digest, entry.token)) {
                    clear(entry);
                    return true;
                }
            }
            return false;
        }

        /// Remove every stored session for this identity, including uncollected expired entries.
        pub fn revokeIdentity(self: *Self, identity: Identity) usize {
            var removed: usize = 0;
            for (&self.entries) |*entry| {
                if (entry.occupied and entry.identity == identity) {
                    clear(entry);
                    removed += 1;
                }
            }
            return removed;
        }

        /// Retain the counter so cleared slots receive fresh tokens on their next use.
        pub fn revokeAll(self: *Self) void {
            for (&self.entries) |*entry| clear(entry);
        }

        /// Expiry is inclusive: a session is invalid when now equals its deadline.
        pub fn expire(self: *Self, now_ns: u64) !usize {
            try self.checkTime(now_ns);
            var removed: usize = 0;
            for (&self.entries) |*entry| {
                if (entry.occupied and now_ns >= entry.expires_ns) {
                    clear(entry);
                    removed += 1;
                }
            }
            self.last_now_ns = now_ns;
            return removed;
        }

        fn checkTime(self: *const Self, now_ns: u64) !void {
            if (now_ns < self.last_now_ns) return error.ClockWentBackwards;
        }

        fn clear(entry: *Entry) void {
            std.crypto.secureZero(u8, &entry.token);
            entry.* = .{};
        }
    };
}

fn encode(digest: [32]u8) Token {
    const hex = "0123456789abcdef";
    var token: Token = undefined;
    for (digest, 0..) |byte, index| {
        token[2 * index] = hex[byte >> 4];
        token[2 * index + 1] = hex[byte & 15];
    }
    return token;
}

fn decode(token: []const u8) ![32]u8 {
    if (token.len != 64) return error.InvalidToken;
    var digest: [32]u8 = undefined;
    for (&digest, 0..) |*byte, index| {
        byte.* = (try nibble(token[2 * index])) << 4 | try nibble(token[2 * index + 1]);
    }
    return digest;
}

fn nibble(byte: u8) !u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        else => error.InvalidToken,
    };
}

test "absolute expiry rejects its boundary and never slides on authentication" {
    var store = Store(2).init(@splat(1));
    defer store.deinit();
    const token = try store.create(42, 100, 50);
    try std.testing.expectEqual(@as(?Identity, 42), try store.authenticate(&token, 100));
    try std.testing.expectEqual(@as(?Identity, 42), try store.authenticate(&token, 149));
    try std.testing.expectEqual(@as(?Identity, null), try store.authenticate(&token, 150));
    try std.testing.expectEqual(@as(?Identity, null), try store.authenticate(&token, 151));
}

test "capacity preserves live sessions and reuses expired slots with fresh tokens" {
    var store = Store(2).init(@splat(2));
    defer store.deinit();
    const first = try store.create(1, 10, 10);
    const second = try store.create(2, 10, 100);
    try std.testing.expectError(error.Full, store.create(3, 19, 100));
    try std.testing.expectEqual(@as(u64, 2), store.counter);
    try std.testing.expectEqual(@as(?Identity, 1), try store.authenticate(&first, 19));
    const replacement = try store.create(3, 20, 100);
    try std.testing.expect(!std.mem.eql(u8, &first, &replacement));
    try std.testing.expectEqual(@as(?Identity, null), try store.authenticate(&first, 20));
    try std.testing.expectEqual(@as(?Identity, 2), try store.authenticate(&second, 20));
    try std.testing.expectEqual(@as(?Identity, 3), try store.authenticate(&replacement, 20));
}

test "revocation rejects replay without changing other identities or reusing counters" {
    var store = Store(3).init(@splat(3));
    defer store.deinit();
    const first = try store.create(7, 0, 100);
    const second = try store.create(7, 0, 100);
    const third = try store.create(8, 0, 100);
    try std.testing.expect(try store.revoke(&first));
    try std.testing.expect(!try store.revoke(&first));
    try std.testing.expectEqual(@as(?Identity, null), try store.authenticate(&first, 0));
    try std.testing.expectEqual(@as(?Identity, 7), try store.authenticate(&second, 0));
    try std.testing.expectEqual(@as(usize, 1), store.revokeIdentity(7));
    try std.testing.expectEqual(@as(?Identity, null), try store.authenticate(&second, 0));
    try std.testing.expectEqual(@as(?Identity, 8), try store.authenticate(&third, 0));
    store.revokeAll();
    try std.testing.expectEqual(@as(?Identity, null), try store.authenticate(&third, 0));
    const fresh = try store.create(7, 0, 100);
    try std.testing.expect(!std.mem.eql(u8, &first, &fresh));
    try std.testing.expectEqual(@as(u64, 4), store.counter);
}

test "invalid TTL, overflow, and backward time preserve the live session" {
    var store = Store(2).init(@splat(4));
    defer store.deinit();
    const token = try store.create(9, 100, 100);
    try std.testing.expectError(error.InvalidTtl, store.create(1, 100, 0));
    try std.testing.expectError(error.ExpiryOverflow, store.create(1, std.math.maxInt(u64), 1));
    try std.testing.expectError(error.ClockWentBackwards, store.create(1, 99, 1));
    try std.testing.expectError(error.ClockWentBackwards, store.authenticate(&token, 99));
    try std.testing.expectError(error.ClockWentBackwards, store.expire(99));
    try std.testing.expectEqual(@as(u64, 1), store.counter);
    try std.testing.expectEqual(@as(u64, 100), store.last_now_ns);
    try std.testing.expectEqual(@as(?Identity, 9), try store.authenticate(&token, 100));
    store.counter = std.math.maxInt(u64);
    try std.testing.expectError(error.CounterExhausted, store.create(1, 100, 100));
    try std.testing.expectEqual(@as(?Identity, 9), try store.authenticate(&token, 100));
    store.revokeAll();
    try std.testing.expectError(error.CounterExhausted, store.create(1, 100, 100));
}

test "tokens reject malformed and noncanonical text without clearing a session" {
    var store = Store(1).init(@splat(5));
    defer store.deinit();
    const token = try store.create(std.math.maxInt(Identity), 0, 100);
    for ([_][]const u8{ "", token[0..63], &([_]u8{'g'} ** 64), &([_]u8{'A'} ** 64) }) |invalid| {
        try std.testing.expectError(error.InvalidToken, store.authenticate(invalid, 0));
        try std.testing.expectError(error.InvalidToken, store.revoke(invalid));
    }
    var altered = token;
    altered[0] = if (altered[0] == '0') '1' else '0';
    try std.testing.expectEqual(@as(?Identity, null), try store.authenticate(&altered, 0));
    try std.testing.expectEqual(@as(?Identity, std.math.maxInt(Identity)), try store.authenticate(&token, 0));
}

test "expiry collects all slots and authentication returns independent identity values" {
    var store = Store(2).init(@splat(6));
    defer store.deinit();
    const first = try store.create(0, 1, 2);
    _ = try store.create(2, 1, 3);
    const identity = (try store.authenticate(&first, 2)).?;
    try std.testing.expectEqual(@as(usize, 1), try store.expire(3));
    try std.testing.expectEqual(@as(usize, 1), try store.expire(4));
    try std.testing.expectEqual(@as(usize, 0), try store.expire(4));
    _ = try store.create(3, 4, 1);
    try std.testing.expectEqual(@as(Identity, 0), identity);
}

test "reusable slots support more logins than the startup capacity" {
    var store = Store(1).init(@splat(7));
    defer store.deinit();
    var previous: ?Token = null;
    for (0..100) |index| {
        const token = try store.create(index, index, 1);
        if (previous) |old| {
            try std.testing.expect(!std.mem.eql(u8, &old, &token));
            try std.testing.expectEqual(@as(?Identity, null), try store.authenticate(&old, index));
        }
        try std.testing.expectEqual(@as(?Identity, index), try store.authenticate(&token, index));
        previous = token;
    }
}

test "different startup keys separate otherwise equal counters" {
    var first = Store(1).init(@splat(8));
    defer first.deinit();
    var second = Store(1).init(@splat(9));
    defer second.deinit();
    const token = try first.create(1, 0, 100);
    const other = try second.create(1, 0, 100);
    try std.testing.expect(!std.mem.eql(u8, &token, &other));
    try std.testing.expectEqual(@as(?Identity, null), try second.authenticate(&token, 0));
}
