const std = @import("std");

/// Counts and refuses allocations through the framework allocator after startup.
/// This does not intercept libc or arbitrary application allocations.
pub const Budget = struct {
    upstream: std.mem.Allocator,
    /// Requested live bytes, excluding allocator metadata and OS allocations.
    limit_bytes: usize = std.math.maxInt(usize),
    live_bytes: usize = 0,
    peak_bytes: usize = 0,
    sealed: std.atomic.Value(bool) = .init(false),
    late_calls: std.atomic.Value(usize) = .init(0),
    pub fn allocator(self: *Budget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }
    fn reject(self: *Budget) bool {
        if (!self.sealed.load(.acquire)) return false;
        _ = self.late_calls.fetchAdd(1, .monotonic);
        return true;
    }
    fn alloc(ctx: *anyopaque, n: usize, a: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (self.reject()) return null;
        if (n > self.limit_bytes - self.live_bytes) return null;
        const memory = self.upstream.rawAlloc(n, a, ret) orelse return null;
        self.live_bytes += n;
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
        return memory;
    }
    fn resize(ctx: *anyopaque, memory: []u8, a: std.mem.Alignment, n: usize, ret: usize) bool {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (self.reject()) return false;
        if (n > memory.len and n - memory.len > self.limit_bytes - self.live_bytes) return false;
        if (!self.upstream.rawResize(memory, a, n, ret)) return false;
        self.live_bytes = self.live_bytes - memory.len + n;
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
        return true;
    }
    fn remap(ctx: *anyopaque, memory: []u8, a: std.mem.Alignment, n: usize, ret: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (self.reject()) return null;
        if (n > memory.len and n - memory.len > self.limit_bytes - self.live_bytes) return null;
        const result = self.upstream.rawRemap(memory, a, n, ret) orelse return null;
        self.live_bytes = self.live_bytes - memory.len + n;
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
        return result;
    }
    fn free(ctx: *anyopaque, memory: []u8, a: std.mem.Alignment, ret: usize) void {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        // Thread join and server teardown release startup storage. Sealing
        // prohibits new allocations, not cleanup after all borrows have ended.
        std.debug.assert(memory.len <= self.live_bytes);
        self.live_bytes -= memory.len;
        self.upstream.rawFree(memory, a, ret);
    }
};

test "startup cap and sealed allocator refuse before growing storage" {
    var budget: Budget = .{ .upstream = std.testing.allocator, .limit_bytes = 8 };
    const allocator = budget.allocator();
    const bytes = try allocator.alloc(u8, 8);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));
    try std.testing.expectEqual(@as(usize, 8), budget.peak_bytes);
    budget.sealed.store(true, .release);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));
    try std.testing.expectEqual(@as(usize, 1), budget.late_calls.load(.acquire));
    allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), budget.live_bytes);
}
