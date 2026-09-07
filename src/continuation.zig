//! Bounded storage for application state retained between callback invocations.
const std = @import("std");

/// await_notification optionally includes a heartbeat timeout in nanoseconds.
pub const Step = union(enum) { flush, wait: u64, await_notification: ?u64, finish };
pub const Event = enum { flushed, timer, notified };
pub const Notification = @import("bounded_http").api.Notification;

/// The application must serialize each lease's callbacks and release exactly once.
/// Records and state cannot back output borrows or survive release.
/// The pool never calls application destructors. Cleanup precedes release.
pub fn Pool(comptime Record: type) type {
    if (@alignOf(Record) > 64) @compileError("Continuation records require alignment <= 64");
    return struct {
        const Self = @This();
        const maximum_generation = std.math.maxInt(usize) >> 1;
        const Slot = struct {
            /// Low bit means occupied. Other bits hold a generation that never wraps.
            ownership: std.atomic.Value(usize) = .init(0),
            record: Record = undefined,
        };
        pub const Lease = struct {
            index: usize,
            generation: usize,
            record: *Record,
            state: []align(64) u8,
        };

        allocator: std.mem.Allocator,
        slots: []Slot,
        bytes: []align(64) u8,
        state_bytes: usize,
        stride: usize,
        occupied: std.atomic.Value(usize) = .init(0),

        fn stateStride(state_bytes: u32) !usize {
            if (state_bytes > 2 * 1024 * 1024) return error.InvalidConfiguration;
            const rounded = try std.math.add(usize, state_bytes, 63);
            return rounded & ~@as(usize, 63);
        }

        pub fn heapBytes(capacity: u16, state_bytes: u32) !usize {
            const stride = try stateStride(state_bytes);
            const records = try std.math.mul(usize, capacity, @sizeOf(Slot));
            const payload = try std.math.mul(usize, capacity, stride);
            return std.math.add(usize, records, payload);
        }

        pub fn init(allocator: std.mem.Allocator, capacity: u16, state_bytes: u32) !Self {
            _ = try heapBytes(capacity, state_bytes);
            const stride = try stateStride(state_bytes);
            const slots = try allocator.alloc(Slot, capacity);
            errdefer allocator.free(slots);
            const bytes = try allocator.alignedAlloc(u8, .@"64", try std.math.mul(usize, capacity, stride));
            for (slots) |*slot| slot.* = .{};
            return .{ .allocator = allocator, .slots = slots, .bytes = bytes, .state_bytes = state_bytes, .stride = stride };
        }

        fn lease(self: *Self, index: usize, generation: usize) Lease {
            const begin = index * self.stride;
            return .{ .index = index, .generation = generation, .record = &self.slots[index].record, .state = @alignCast(self.bytes[begin..][0..self.state_bytes]) };
        }

        /// One finite scan. Contention or full capacity returns null immediately.
        /// New records and payload bytes are uninitialized application storage.
        pub fn acquire(self: *Self) ?Lease {
            for (self.slots, 0..) |*slot, index| {
                const current = slot.ownership.load(.acquire);
                if (current & 1 != 0) continue;
                const generation = current >> 1;
                if (generation == maximum_generation) continue;
                const next = generation + 1;
                if (slot.ownership.cmpxchgStrong(current, (next << 1) | 1, .acquire, .monotonic) != null) continue;
                _ = self.occupied.fetchAdd(1, .monotonic);
                return self.lease(index, next);
            }
            return null;
        }

        /// Validate a handle during its exclusive application callback.
        /// This check cannot extend ownership against a concurrent release.
        pub fn get(self: *Self, index: usize, generation: usize) ?Lease {
            if (index >= self.slots.len or generation == 0 or generation > maximum_generation) return null;
            if (self.slots[index].ownership.load(.acquire) != (generation << 1) | 1) return null;
            return self.lease(index, generation);
        }

        pub fn release(self: *Self, owned: Lease) void {
            std.debug.assert(owned.index < self.slots.len and owned.generation > 0 and owned.generation <= maximum_generation);
            const slot = &self.slots[owned.index];
            std.debug.assert(slot.ownership.load(.acquire) == (owned.generation << 1) | 1);
            std.debug.assert(owned.record == &slot.record);
            const previous = self.occupied.fetchSub(1, .monotonic);
            std.debug.assert(previous > 0);
            slot.ownership.store(owned.generation << 1, .release);
        }

        pub fn live(self: *const Self) usize {
            return self.occupied.load(.acquire);
        }

        pub fn deinit(self: *Self) void {
            std.debug.assert(self.live() == 0);
            for (self.slots) |*slot| std.debug.assert(slot.ownership.load(.acquire) & 1 == 0);
            self.allocator.free(self.bytes);
            self.allocator.free(self.slots);
            self.* = undefined;
        }
    };
}

test "continuation slots retain typed records and aligned payloads through generation changes" {
    const Record = struct { number: u64, initialized: bool };
    var pool = try Pool(Record).init(std.testing.allocator, 2, 129);
    defer pool.deinit();
    const first = pool.acquire().?;
    const second = pool.acquire().?;
    try std.testing.expect(pool.acquire() == null);
    try std.testing.expectEqual(@as(usize, 2), pool.live());
    try std.testing.expectEqual(@as(usize, 129), first.state.len);
    try std.testing.expectEqual(@as(usize, 192), @intFromPtr(second.state.ptr) - @intFromPtr(first.state.ptr));
    first.record.* = .{ .number = 42, .initialized = true };
    first.state[128] = 123;
    const resumed = pool.get(first.index, first.generation).?;
    try std.testing.expectEqual(@as(u64, 42), resumed.record.number);
    try std.testing.expectEqual(@as(u8, 123), resumed.state[128]);
    pool.release(first);
    try std.testing.expect(pool.get(first.index, first.generation) == null);
    const reused = pool.acquire().?;
    try std.testing.expectEqual(first.index, reused.index);
    try std.testing.expect(reused.generation != first.generation);
    try std.testing.expect(pool.get(first.index, first.generation) == null);
    try std.testing.expect(pool.get(999, 1) == null);
    try std.testing.expect(pool.get(0, 0) == null);
    pool.release(second);
    pool.release(reused);
    try std.testing.expectEqual(@as(usize, 0), pool.live());
}

test "continuation pool handles disabled capacity, payload bounds, and permanent generation retirement" {
    var disabled = try Pool(void).init(std.testing.allocator, 0, 0);
    defer disabled.deinit();
    try std.testing.expect(disabled.acquire() == null);
    try std.testing.expectEqual(@as(usize, 0), try Pool(void).heapBytes(0, 0));
    try std.testing.expectError(error.InvalidConfiguration, Pool(void).heapBytes(1, 2 * 1024 * 1024 + 1));
    var pool = try Pool(void).init(std.testing.allocator, 1, 0);
    defer pool.deinit();
    const final_generation = std.math.maxInt(usize) >> 1;
    pool.slots[0].ownership.store((final_generation - 1) << 1, .release);
    const last = pool.acquire().?;
    try std.testing.expectEqual(final_generation, last.generation);
    pool.release(last);
    try std.testing.expect(pool.acquire() == null);
    try std.testing.expect(pool.get(last.index, last.generation) == null);
}
