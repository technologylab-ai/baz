const std = @import("std");
pub const http = @import("http.zig");

pub const Action = enum { flush, finish, close };
pub const Event = enum { request, flushed };
pub const Handler = *const fn (*Context) Action;

pub const Context = struct {
    request: *const http.Request,
    writer: *Writer,
    event: Event,
    /// Eight startup-reserved words, zeroed for each new request.
    state: *[8]usize,
    application: ?*anyopaque,
    cancelled: *const std.atomic.Value(bool),
};

/// Only the current application callback can mutate a Writer. Returning flush
/// or finish transfers its committed bytes to the I/O owner until completion.
pub const Writer = struct {
    buffer: []u8,
    buffered: usize = 0,
    reserved: usize = 0,
    borrowed: ?[]const u8 = null,
    status: u16 = 200,
    content_type: []const u8 = "text/plain",
    content_length: ?usize = null,
    began: bool = false,
    frozen: bool = false,
    headers_committed: bool = false,

    pub fn init(buffer: []u8) Writer {
        return .{ .buffer = buffer };
    }

    pub fn begin(self: *Writer, status: u16, content_type: []const u8, length: ?usize) !void {
        if (self.frozen or self.began or self.headers_committed) return error.InvalidState;
        if (status < 200 or status > 599 or content_type.len > 128) return error.InvalidResponse;
        for (content_type) |byte| if (byte < 32 or byte > 126) return error.InvalidResponse;
        self.status = status;
        self.content_type = content_type;
        self.content_length = length;
        self.began = true;
    }

    pub fn reserve(self: *Writer, count: usize) ![]u8 {
        if (self.frozen or self.borrowed != null or self.reserved != 0) return error.InvalidState;
        if (count > self.buffer.len - self.buffered) return error.WouldBlock;
        self.reserved = count;
        return self.buffer[self.buffered..][0..count];
    }

    pub fn commit(self: *Writer, count: usize) void {
        std.debug.assert(!self.frozen);
        std.debug.assert(count <= self.reserved);
        std.debug.assert(count <= self.buffer.len - self.buffered);
        self.buffered += count;
        self.reserved = 0;
    }

    /// Convenience copying path. reserve/commit writes directly into output storage.
    pub fn write(self: *Writer, bytes: []const u8) !void {
        const destination = try self.reserve(bytes.len);
        @memcpy(destination, bytes);
        self.commit(bytes.len);
    }

    /// MVP storage must be request-owned input or immutable server-lifetime
    /// assets. A successful flush resumes the callback, but finish/cancellation
    /// has no application release notification yet. Do not borrow stack locals
    /// or externally recycled buffers. Dynamic lease release is a pending API
    /// experiment. begin() content_type has the same lifetime requirement.
    pub fn borrow(self: *Writer, bytes: []const u8) !void {
        if (self.frozen or self.buffered != 0 or self.reserved != 0 or self.borrowed != null)
            return error.InvalidState;
        self.borrowed = bytes;
    }

    pub fn flush(self: *Writer) Action {
        std.debug.assert(!self.frozen and self.reserved == 0 and self.began);
        self.frozen = true;
        return .flush;
    }

    pub fn finish(self: *Writer) Action {
        std.debug.assert(!self.frozen and self.reserved == 0 and self.began);
        self.frozen = true;
        return .finish;
    }

    pub fn committed(self: *const Writer) []const u8 {
        std.debug.assert(self.frozen);
        return self.borrowed orelse self.buffer[0..self.buffered];
    }

    pub fn release(self: *Writer) void {
        std.debug.assert(self.frozen);
        self.buffered = 0;
        self.reserved = 0;
        self.borrowed = null;
        self.frozen = false;
    }
};

test "flush holds all committed bytes and resumed writer starts empty" {
    var buffer: [16]u8 = undefined;
    var writer = Writer.init(&buffer);
    try writer.begin(200, "text/plain", 7);
    const reserved = try writer.reserve(8);
    @memcpy(reserved[0..3], "one");
    writer.commit(3);
    try writer.write(" two");
    try std.testing.expectEqual(Action.flush, writer.flush());
    try std.testing.expectEqualStrings("one two", writer.committed());
    try std.testing.expectError(error.InvalidState, writer.reserve(1));
    writer.release();
    try std.testing.expectEqual(@as(usize, 0), writer.buffered);
}

test "borrowed output retains its source pointer and capacity errors are recoverable" {
    var buffer: [2]u8 = undefined;
    var writer = Writer.init(&buffer);
    try writer.begin(200, "text/plain", null);
    try std.testing.expectError(error.WouldBlock, writer.write("too large"));
    const body = "borrowed body";
    try writer.borrow(body);
    _ = writer.finish();
    try std.testing.expectEqual(body.ptr, writer.committed().ptr);
    try std.testing.expectEqualStrings(body, writer.committed());
}
