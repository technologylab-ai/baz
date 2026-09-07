//! Startup-sized, non-blocking application message storage.
const std = @import("std");

/// Store values, not borrowed callback pointers. Pointer/slice payload lifetimes
/// remain the application's responsibility. Stop and join all producers before
/// destroying or reinitializing the mailbox. Never copy a live mailbox. Busy is an ordinary admission result.
pub fn Mailbox(comptime T: type, comptime capacity: u16) type {
    if (capacity == 0) @compileError("Mailbox capacity must be positive");
    return struct {
        const Self = @This();
        busy: std.atomic.Value(bool) = .init(false),
        items: [capacity]T = undefined,
        head: usize = 0,
        count: usize = 0,
        closed: bool = false,

        /// Enqueue before signalling the consumer's notification handle.
        /// No lock retry, allocation, overwrite, or implicit dropping.
        pub fn tryPush(self: *Self, item: T) error{ Busy, Full, Closed }!void {
            if (self.busy.swap(true, .acquire)) return error.Busy;
            defer self.busy.store(false, .release);
            if (self.closed) return error.Closed;
            if (self.count == capacity) return error.Full;
            self.items[(self.head + self.count) % capacity] = item;
            self.count += 1;
        }

        /// null means currently empty. A closed mailbox drains queued values
        /// before returning Closed. Callbacks must bound their drain loops too.
        pub fn tryPop(self: *Self) error{ Busy, Closed }!?T {
            if (self.busy.swap(true, .acquire)) return error.Busy;
            defer self.busy.store(false, .release);
            if (self.count == 0) {
                if (self.closed) return error.Closed;
                return null;
            }
            const item = self.items[self.head];
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
            return item;
        }

        /// Reject future pushes; already queued values remain available.
        /// Signal consumers after closing so they can observe terminal state.
        pub fn tryClose(self: *Self) error{Busy}!void {
            if (self.busy.swap(true, .acquire)) return error.Busy;
            defer self.busy.store(false, .release);
            self.closed = true;
        }
    };
}

test "mailbox bounds, FIFO wraparound, and drain before close" {
    var queue: Mailbox(u32, 2) = .{};
    try std.testing.expectEqual(null, try queue.tryPop());
    try queue.tryPush(10);
    try queue.tryPush(20);
    try std.testing.expectError(error.Full, queue.tryPush(30));
    try std.testing.expectEqual(@as(?u32, 10), try queue.tryPop());
    try queue.tryPush(30);
    try queue.tryClose();
    try queue.tryClose();
    try std.testing.expectError(error.Closed, queue.tryPush(40));
    try std.testing.expectEqual(@as(?u32, 20), try queue.tryPop());
    try std.testing.expectEqual(@as(?u32, 30), try queue.tryPop());
    try std.testing.expectError(error.Closed, queue.tryPop());
}

test "mailbox contention never waits or mutates admission state" {
    var queue: Mailbox(u8, 1) = .{};
    queue.busy.store(true, .release);
    try std.testing.expectError(error.Busy, queue.tryPush(1));
    try std.testing.expectError(error.Busy, queue.tryPop());
    try std.testing.expectError(error.Busy, queue.tryClose());
    queue.busy.store(false, .release);
    try queue.tryPush(2);
    try std.testing.expectEqual(@as(?u8, 2), try queue.tryPop());
}
