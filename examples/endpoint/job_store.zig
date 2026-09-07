//! Fixed job slots and replay rings for the local progress example.
//! The caller supplies synchronization and monotonic nanoseconds.
//! Authenticate the current session before each read, under the same lock.
//! A copied identity does not prove that its session remains valid.
//! Notify subscribers after publishing and releasing the application lock.
const std = @import("std");

pub const Identity = u64;
pub const Handle = struct { slot: u16, generation: u64 };
pub const Event = struct { sequence: u64, progress: u8, done: bool };
pub const Replay = union(enum) {
    event: Event,
    waiting,
    complete,
    /// The ring no longer contains the requested next event.
    /// The caller can send this snapshot as a reset, or close the stream.
    gap: Event,
};

pub fn Store(comptime job_capacity: usize, comptime replay_capacity: usize) type {
    if (job_capacity == 0 or job_capacity > 65536) @compileError("Job capacity must be 1 through 65536");
    if (replay_capacity == 0) @compileError("Replay capacity must be positive");
    return struct {
        const Self = @This();
        const Entry = struct {
            generation: u64 = 0,
            occupied: bool = false,
            owner: Identity = 0,
            expires_ns: u64 = 0,
            latest: Event = .{ .sequence = 0, .progress = 0, .done = false },
            history: [replay_capacity]Event = undefined,
            history_len: usize = 0,
        };

        entries: [job_capacity]Entry = @splat(.{}),
        last_now_ns: u64 = 0,

        /// A full store never evicts a live job, including a completed job.
        /// Failed creation preserves entries, generations, and the time watermark.
        pub fn create(self: *Self, owner: Identity, now_ns: u64, ttl_ns: u64) !Handle {
            try self.checkTime(now_ns);
            if (ttl_ns == 0) return error.InvalidTtl;
            const deadline = std.math.add(u64, now_ns, ttl_ns) catch return error.ExpiryOverflow;
            for (&self.entries, 0..) |*entry, slot| {
                if (entry.occupied and now_ns < entry.expires_ns) continue;
                // Retire exhausted slots permanently. Old handles must never become valid again.
                const generation = std.math.add(u64, entry.generation, 1) catch continue;
                entry.* = .{ .generation = generation, .occupied = true, .owner = owner, .expires_ns = deadline };
                append(entry, .{ .sequence = 1, .progress = 0, .done = false });
                self.last_now_ns = now_ns;
                return .{ .slot = @intCast(slot), .generation = generation };
            }
            return error.Full;
        }

        /// Producer access uses a generation-checked handle, without a user session.
        /// Progress must increase. Progress 100 completes the job.
        pub fn publish(self: *Self, handle: Handle, progress: u8, now_ns: u64) !Event {
            _ = try self.expire(now_ns);
            const entry = try self.lookup(handle);
            if (entry.latest.done) return error.AlreadyComplete;
            if (progress > 100 or progress <= entry.latest.progress) return error.InvalidProgress;
            const sequence = std.math.add(u64, entry.latest.sequence, 1) catch return error.SequenceExhausted;
            const event: Event = .{ .sequence = sequence, .progress = progress, .done = progress == 100 };
            append(entry, event);
            return event;
        }

        /// Advance one producer tick. The final tick stops at progress 100.
        pub fn advance(self: *Self, handle: Handle, increment: u8, now_ns: u64) !Event {
            if (increment == 0) return error.InvalidProgress;
            _ = try self.expire(now_ns);
            const entry = try self.lookup(handle);
            return self.publish(handle, @intCast(@min(@as(u16, entry.latest.progress) + increment, 100)), now_ns);
        }

        /// Return one copied event after the cursor. Zero requests the initial event.
        /// Unknown, expired, stale, and other users' handles all return NotFound.
        pub fn read(self: *Self, owner: Identity, handle: Handle, after_sequence: u64, now_ns: u64) !Replay {
            _ = try self.expire(now_ns);
            const entry = try self.lookup(handle);
            if (entry.owner != owner) return error.NotFound;
            if (after_sequence > entry.latest.sequence) return error.InvalidCursor;
            if (after_sequence == entry.latest.sequence)
                return if (entry.latest.done) .complete else .waiting;
            const oldest = entry.latest.sequence - entry.history_len + 1;
            const next = after_sequence + 1; // The latest sequence is strictly greater than the cursor.
            if (next < oldest) return .{ .gap = entry.latest };
            const index: usize = @intCast((next - 1) % replay_capacity);
            const event = entry.history[index];
            std.debug.assert(event.sequence == next);
            return .{ .event = event };
        }

        /// Copy every unfinished handle into caller-owned fixed storage.
        pub fn active(self: *Self, out: *[job_capacity]Handle, now_ns: u64) !usize {
            _ = try self.expire(now_ns);
            var count: usize = 0;
            for (self.entries, 0..) |entry, slot| {
                if (!entry.occupied or entry.latest.done) continue;
                out[count] = .{ .slot = @intCast(slot), .generation = entry.generation };
                count += 1;
            }
            return count;
        }

        /// Remove jobs for this identity. Session revocation remains the caller's responsibility.
        pub fn revokeIdentity(self: *Self, owner: Identity) usize {
            var removed: usize = 0;
            for (&self.entries) |*entry| {
                if (entry.occupied and entry.owner == owner) {
                    clear(entry);
                    removed += 1;
                }
            }
            return removed;
        }

        /// Expiry is inclusive and absolute. Reads and progress never extend the deadline.
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

        fn lookup(self: *Self, handle: Handle) !*Entry {
            if (@as(usize, handle.slot) >= job_capacity) return error.NotFound;
            const entry = &self.entries[handle.slot];
            if (!entry.occupied or entry.generation != handle.generation) return error.NotFound;
            return entry;
        }

        fn append(entry: *Entry, event: Event) void {
            const index: usize = @intCast((event.sequence - 1) % replay_capacity);
            entry.history[index] = event;
            entry.history_len = @min(entry.history_len + 1, replay_capacity);
            entry.latest = event;
        }

        fn clear(entry: *Entry) void {
            entry.* = .{ .generation = entry.generation };
        }
    };
}

test "fixed slots preserve completed jobs until expiry and reject stale handles" {
    var store: Store(1, 4) = .{};
    const first = try store.create(7, 10, 10);
    _ = try store.publish(first, 100, 11);
    try std.testing.expectError(error.Full, store.create(7, 19, 20));
    try std.testing.expectEqual(@as(u64, 11), store.last_now_ns);
    const next = try store.create(7, 20, 20);
    try std.testing.expectEqual(first.slot, next.slot);
    try std.testing.expectEqual(first.generation + 1, next.generation);
    try std.testing.expectError(error.NotFound, store.read(7, first, 0, 20));
    try std.testing.expectError(error.NotFound, store.publish(first, 50, 20));
    try std.testing.expectEqual(@as(u8, 0), (try store.read(7, next, 0, 20)).event.progress);
}

test "bounded replay copies events and reports exact cursor outcomes" {
    var store: Store(1, 3) = .{};
    const handle = try store.create(1, 0, 100);
    const initial = (try store.read(1, handle, 0, 0)).event;
    try std.testing.expectEqual(@as(u64, 1), initial.sequence);
    try std.testing.expectEqual(Replay.waiting, try store.read(1, handle, 1, 0));
    _ = try store.publish(handle, 25, 1);
    _ = try store.publish(handle, 50, 2);
    _ = try store.publish(handle, 75, 3);
    const gap = (try store.read(1, handle, 0, 3)).gap;
    try std.testing.expectEqual(@as(u8, 75), gap.progress);
    try std.testing.expectEqual(@as(u64, 4), gap.sequence);
    try std.testing.expectEqual(@as(u8, 25), (try store.read(1, handle, 1, 3)).event.progress);
    try std.testing.expectEqual(@as(u8, 50), (try store.read(1, handle, 2, 3)).event.progress);
    try std.testing.expectEqual(@as(u8, 75), (try store.read(1, handle, 3, 3)).event.progress);
    try std.testing.expectEqual(Replay.waiting, try store.read(1, handle, 4, 3));
    try std.testing.expectError(error.InvalidCursor, store.read(1, handle, 5, 3));
    try std.testing.expectEqual(@as(u8, 0), initial.progress);
    const done = try store.publish(handle, 100, 4);
    try std.testing.expect(done.done);
    try std.testing.expectEqual(Replay.complete, try store.read(1, handle, done.sequence, 4));
    try std.testing.expectError(error.AlreadyComplete, store.publish(handle, 100, 4));
}

test "single-event rings reset slow readers to a completed snapshot" {
    var store: Store(1, 1) = .{};
    const handle = try store.create(1, 0, 100);
    _ = try store.publish(handle, 100, 1);
    const reset = (try store.read(1, handle, 0, 1)).gap;
    try std.testing.expect(reset.done);
    try std.testing.expectEqual(@as(u64, 2), reset.sequence);
    try std.testing.expectEqual(Replay.complete, try store.read(1, handle, reset.sequence, 1));
}

test "authorization hides other users' jobs and identity revocation preserves other jobs" {
    var store: Store(2, 2) = .{};
    const first = try store.create(7, 0, 100);
    const second = try store.create(8, 0, 100);
    try std.testing.expectError(error.NotFound, store.read(8, first, 0, 0));
    try std.testing.expectError(error.NotFound, store.read(7, second, std.math.maxInt(u64), 0));
    try std.testing.expectEqual(@as(usize, 1), store.revokeIdentity(7));
    try std.testing.expectEqual(@as(usize, 0), store.revokeIdentity(7));
    try std.testing.expectError(error.NotFound, store.read(7, first, 0, 0));
    try std.testing.expectEqual(@as(u8, 0), (try store.read(8, second, 0, 0)).event.progress);
    const reused = try store.create(8, 0, 100);
    try std.testing.expectEqual(first.slot, reused.slot);
    try std.testing.expect(first.generation != reused.generation);
}

test "absolute expiry includes the deadline and releases all matching slots" {
    var store: Store(2, 2) = .{};
    const first = try store.create(1, 1, 2);
    const second = try store.create(2, 1, 3);
    _ = try store.publish(first, 50, 2);
    try std.testing.expectEqual(@as(usize, 1), try store.expire(3));
    try std.testing.expectError(error.NotFound, store.read(1, first, 0, 3));
    _ = try store.read(2, second, 0, 3);
    try std.testing.expectError(error.NotFound, store.read(2, second, 0, 4));
    try std.testing.expectEqual(@as(usize, 0), try store.expire(4));
}

test "producer handles stay bounded and completed jobs leave the active set" {
    var store: Store(3, 2) = .{};
    const first = try store.create(1, 0, 100);
    const second = try store.create(2, 0, 100);
    var handles: [3]Handle = undefined;
    try std.testing.expectEqual(@as(usize, 2), try store.active(&handles, 0));
    try std.testing.expectEqual(first, handles[0]);
    try std.testing.expectEqual(second, handles[1]);
    try std.testing.expectEqual(@as(u8, 60), (try store.advance(first, 60, 1)).progress);
    try std.testing.expectEqual(@as(u8, 100), (try store.advance(first, 60, 2)).progress);
    try std.testing.expectError(error.AlreadyComplete, store.advance(first, 1, 2));
    try std.testing.expectEqual(@as(usize, 1), try store.active(&handles, 2));
    try std.testing.expectEqual(second, handles[0]);
    try std.testing.expectEqual(@as(usize, 0), try store.active(&handles, 100));
}

test "invalid progress and arithmetic preserve job state" {
    var store: Store(1, 2) = .{};
    try std.testing.expectError(error.InvalidTtl, store.create(1, 0, 0));
    try std.testing.expectError(error.ExpiryOverflow, store.create(1, std.math.maxInt(u64), 1));
    const handle = try store.create(1, 10, 100);
    try std.testing.expectError(error.ClockWentBackwards, store.create(1, 9, 1));
    try std.testing.expectError(error.ClockWentBackwards, store.expire(9));
    try std.testing.expectError(error.ClockWentBackwards, store.read(1, handle, 0, 9));
    try std.testing.expectError(error.ClockWentBackwards, store.publish(handle, 50, 9));
    try std.testing.expectError(error.InvalidProgress, store.publish(handle, 0, 10));
    try std.testing.expectError(error.InvalidProgress, store.publish(handle, 101, 10));
    try std.testing.expectError(error.InvalidProgress, store.advance(handle, 0, 10));
    try std.testing.expectEqual(@as(u64, 1), (try store.read(1, handle, 0, 10)).event.sequence);
    _ = try store.publish(handle, 50, 10);
    try std.testing.expectError(error.InvalidProgress, store.publish(handle, 49, 10));
    try std.testing.expectError(error.InvalidProgress, store.publish(handle, 50, 10));
}

test "invalid handles fail closed and generation exhaustion retires a slot" {
    var store: Store(2, 1) = .{};
    store.entries[0].generation = std.math.maxInt(u64);
    const handle = try store.create(1, 0, 1);
    try std.testing.expectEqual(@as(u16, 1), handle.slot);
    try std.testing.expectError(error.NotFound, store.read(1, .{ .slot = 2, .generation = 1 }, 0, 0));
    try std.testing.expectError(error.NotFound, store.read(1, .{ .slot = 1, .generation = 0 }, 0, 0));
    _ = try store.expire(1);
    store.entries[1].generation = std.math.maxInt(u64);
    try std.testing.expectError(error.Full, store.create(1, 1, 1));
}

test "many reuse cycles never replay events through an old handle" {
    var store: Store(1, 2) = .{};
    var previous: ?Handle = null;
    for (0..100) |tick| {
        const handle = try store.create(1, tick, 1);
        if (previous) |old| {
            try std.testing.expectError(error.NotFound, store.publish(old, 100, tick));
            try std.testing.expectError(error.NotFound, store.read(1, old, 0, tick));
            try std.testing.expectEqual(old.generation + 1, handle.generation);
        }
        try std.testing.expectEqual(@as(u64, 1), (try store.read(1, handle, 0, tick)).event.sequence);
        previous = handle;
    }
}
