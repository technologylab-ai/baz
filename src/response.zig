//! Bounded response drafts and worker streams. All byte storage belongs to the current
//! connection's startup output arena; no allocator or request-local arena is
//! needed. The scheduler reserves Limits.reservationBytes before application
//! execution. Earlier frozen responses are never part of this draft.
const std = @import("std");
const api = @import("bounded_http").api;

pub const Limits = struct {
    /// Serialized extra fields, including names, separators and CRLFs.
    header_bytes: u32 = 2048,
    /// Maximum one-shot body and streaming staging capacity. Streaming totals
    /// use the server's separate max_response_bytes bound.
    body_bytes: u32 = 8192,
    max_headers: u16 = 32,

    pub fn validate(self: Limits) !void {
        _ = try self.reservationBytes();
    }

    /// The fixed prefix includes the canonical head and private Content-Type
    /// staging. The draft body is compacted once at publication, accounting for
    /// that copy in Writer.draft_copy_bytes / Stats.response_draft_copy_bytes.
    pub fn reservationBytes(self: Limits) !usize {
        if (self.header_bytes > 65536 or self.body_bytes > 1024 * 1024 or self.max_headers > 1024)
            return error.InvalidResponseLimits;
        const head = try std.math.add(usize, api.header_reserve_bytes + api.max_content_type_bytes, self.header_bytes);
        const total = try std.math.add(usize, head, self.body_bytes);
        if (total > 1024 * 1024) return error.InvalidResponseLimits;
        return total;
    }
};

pub const Response = struct {
    writer: *api.Writer,
    storage: []u8,
    limits: Limits,
    header_len: usize = 0,
    header_count: u16 = 0,
    content_type_len: usize = 0,
    body_len: usize = 0,
    borrowed: ?[]const u8 = null,
    status: u16 = 200,
    prepared: bool = false,
    published: bool = false,
    /// Installed by App for the duration of one callback. Never escapes it.
    context: ?*api.Context = null,
    stream_limit: usize = 0,
    streaming: bool = false,
    stream_finished: bool = false,
    stream_error: ?anyerror = null,
    stream_written: usize = 0,
    stream_length: ?usize = null,

    pub fn init(writer: *api.Writer, limits: Limits) !Response {
        const storage = writer.draftStorage(try limits.reservationBytes()) catch |err| {
            return if (err == error.WouldBlock) error.OutputReservationUnavailable else err;
        };
        return .{ .writer = writer, .storage = storage, .limits = limits };
    }

    fn typeStorage(self: *Response) []u8 {
        return self.storage[api.header_reserve_bytes..][0..api.max_content_type_bytes];
    }

    fn headerStorage(self: *Response) []u8 {
        return self.storage[api.header_reserve_bytes + api.max_content_type_bytes ..][0..self.limits.header_bytes];
    }

    fn bodyStorage(self: *Response) []u8 {
        return self.storage[api.header_reserve_bytes + api.max_content_type_bytes + self.limits.header_bytes ..][0..self.limits.body_bytes];
    }

    fn checkDraft(self: *const Response) !void {
        if (self.published) return error.InvalidState;
        _ = try self.writer.draftStorage(0);
    }

    fn checkBody(self: *const Response, status: u16, content_type: []const u8, length: usize) !void {
        try self.checkDraft();
        if (self.prepared) return error.InvalidState;
        if (status < 200 or status > 599 or content_type.len == 0 or content_type.len > api.max_content_type_bytes)
            return error.InvalidResponse;
        for (content_type) |byte| if (byte < 32 or byte > 126) return error.InvalidResponse;
        if ((status == 204 or status == 205 or status == 304) and length != 0) return error.InvalidResponse;
        if (length > self.limits.body_bytes) return error.ResponseLimit;
    }

    fn setBody(self: *Response, status: u16, content_type: []const u8, length: usize) void {
        @memcpy(self.typeStorage()[0..content_type.len], content_type);
        self.content_type_len = content_type.len;
        self.status = status;
        self.body_len = length;
        self.prepared = true;
    }

    /// Append one field. Name and value are copied before this method returns;
    /// stack buffers are valid inputs. Repetition, including Set-Cookie, stays
    /// explicit and ordered. Canonical/framing fields belong to the writer.
    pub fn header(self: *Response, name: []const u8, value: []const u8) !void {
        try self.checkDraft();
        try api.validateHeader(name, value);
        if (self.header_count == self.limits.max_headers) return error.ResponseLimit;
        const header_size = std.math.add(usize, std.math.add(usize, name.len, value.len) catch return error.ResponseLimit, 4) catch return error.ResponseLimit;
        if (header_size > self.limits.header_bytes - self.header_len) return error.ResponseLimit;
        const out = self.headerStorage()[self.header_len..][0..header_size];
        @memcpy(out[0..name.len], name);
        @memcpy(out[name.len..][0..2], ": ");
        @memcpy(out[name.len + 2 ..][0..value.len], value);
        @memcpy(out[header_size - 2 ..], "\r\n");
        self.header_len += header_size;
        self.header_count += 1;
    }

    /// Copy a complete body now. A successful call prepares the response but
    /// publishes nothing; middleware may still append headers before finish.
    pub fn bytes(self: *Response, status: u16, content_type: []const u8, body: []const u8) !void {
        try self.checkBody(status, content_type, body.len);
        @memcpy(self.bodyStorage()[0..body.len], body);
        self.setBody(status, content_type, body.len);
    }

    pub fn text(self: *Response, status: u16, body: []const u8) !void {
        return self.bytes(status, "text/plain; charset=utf-8", body);
    }

    /// Already encoded JSON bytes; the caller owns JSON syntax validation.
    pub fn jsonBytes(self: *Response, status: u16, body: []const u8) !void {
        return self.bytes(status, "application/json", body);
    }

    /// Serialize exactly once into the bounded unpublished body. A custom
    /// jsonStringify method remains application code and must obey the selected
    /// execution policy. A failed serializer can leave a private prefix but
    /// never prepares or publishes it.
    pub fn jsonValue(self: *Response, status: u16, value: anytype) !void {
        const content_type = "application/json";
        try self.checkBody(status, content_type, 0);
        var out: std.Io.Writer = .fixed(self.bodyStorage());
        try std.json.Stringify.value(value, .{}, &out);
        try self.checkBody(status, content_type, out.end);
        self.setBody(status, content_type, out.end);
    }

    /// Standard formatting without an allocating intermediate string. Standard
    /// Writer.flush is not the HTTP scheduler's flush/resume operation.
    pub fn print(self: *Response, status: u16, content_type: []const u8, comptime format: []const u8, args: anytype) !void {
        try self.checkBody(status, content_type, 0);
        var out: std.Io.Writer = .fixed(self.bodyStorage());
        try out.print(format, args);
        try self.checkBody(status, content_type, out.end);
        self.setBody(status, content_type, out.end);
    }

    /// Only original request input or immutable server-lifetime assets are
    /// eligible. Caller scratch, callback stack locals, mutable Shared storage,
    /// and external pools are not. No release callback exists after finish or
    /// cancellation. The core may copy small borrows as its counted exception.
    pub fn borrowBody(self: *Response, status: u16, content_type: []const u8, body: []const u8) !void {
        try self.checkBody(status, content_type, body.len);
        self.setBody(status, content_type, body.len);
        self.borrowed = body;
    }

    pub const StreamOptions = struct {
        /// Null selects HTTP/1.1 chunked framing. A known length is checked
        /// across every write and must match when the response ends.
        content_length: ?usize = null,
    };

    /// Start a stream on an existing application worker. Writes copy into the
    /// startup-reserved staging buffer. A full buffer applies backpressure by
    /// flushing before accepting more data. Explicit flush sends immediately.
    /// Headers remain editable until the first flush. Keep the returned handle
    /// on this callback's stack; never retain its writer past the callback.
    pub fn stream(self: *Response, status: u16, content_type: []const u8, options: StreamOptions) !Stream {
        const context = self.context orelse return error.BlockingFlushUnavailable;
        if (!context.supportsBlockingFlush()) return error.BlockingFlushUnavailable;
        if (context.cancelled.load(.acquire)) return error.Cancelled;
        try self.checkBody(status, content_type, 0);
        if (options.content_length) |length| {
            if (length > self.stream_limit) return error.ResponseLimit;
            if ((status == 204 or status == 205 or status == 304) and length != 0) return error.InvalidResponse;
        }
        self.setBody(status, content_type, 0);
        self.streaming = true;
        self.stream_length = if (status == 204 or status == 205 or status == 304) 0 else options.content_length;
        return .{ .response = self };
    }

    fn checkStream(self: *const Response) !void {
        if (self.stream_error) |err| return err;
        if (!self.streaming or self.stream_finished) return error.InvalidState;
        if (self.context.?.cancelled.load(.acquire)) return error.Cancelled;
    }

    fn appendStream(self: *Response, data: []const u8) !usize {
        try self.checkStream();
        if (data.len == 0) return 0;
        if (self.limits.body_bytes == 0) return error.ResponseLimit;
        if (self.body_len == self.limits.body_bytes) try self.flushStream();
        const count = @min(data.len, self.limits.body_bytes - self.body_len);
        const total = std.math.add(usize, self.stream_written, count) catch return error.ResponseLimit;
        if (total > self.stream_limit) return error.ResponseLimit;
        if (self.stream_length) |length| if (total > length) return error.ResponseLengthMismatch;
        @memcpy(self.bodyStorage()[self.body_len..][0..count], data[0..count]);
        self.body_len += count;
        self.stream_written = total;
        return count;
    }

    fn prepareStreamSnapshot(self: *Response) !void {
        if (!self.published) {
            try self.writer.beginWithHeaders(self.status, self.typeStorage()[0..self.content_type_len], self.stream_length, self.headerStorage()[0..self.header_len]);
            try self.writer.writeDraftBody(self.bodyStorage()[0..self.body_len]);
        } else {
            // The previous barrier returned every kernel borrow. Staging and
            // output may overlap, so ordinary memcpy is insufficient here.
            const source = self.bodyStorage()[0..self.body_len];
            const destination = try self.writer.reserve(self.body_len);
            if (@intFromPtr(destination.ptr) <= @intFromPtr(source.ptr)) {
                std.mem.copyForwards(u8, destination, source);
            } else {
                std.mem.copyBackwards(u8, destination, source);
            }
            self.writer.commit(self.body_len);
        }
        self.body_len = 0;
    }

    fn flushStream(self: *Response) !void {
        try self.checkStream();
        try self.prepareStreamSnapshot();
        // From this point an error cannot safely replace the HTTP response.
        self.published = true;
        try self.context.?.flushAndWait();
    }

    fn endStream(self: *Response) !void {
        try self.checkStream();
        if (self.stream_length) |length| if (self.stream_written != length) return error.ResponseLengthMismatch;
        self.stream_finished = true;
    }

    /// Publish one complete response to the low-level writer. Generated bytes
    /// move once within the reserved arena to eliminate unused head capacity;
    /// the retained batch is still one contiguous span. There are no fallible
    /// application callbacks between constructing the head and freezing output.
    pub fn finish(self: *Response) !api.Action {
        if (self.streaming) {
            if (self.stream_error) |err| return err;
            if (self.context.?.cancelled.load(.acquire)) return error.Cancelled;
            if (!self.stream_finished) try self.endStream();
            try self.prepareStreamSnapshot();
            self.published = true;
            return self.writer.finish();
        }
        try self.checkDraft();
        if (!self.prepared) return error.ResponseNotPrepared;
        const body = self.bodyStorage()[0..self.body_len];
        try self.writer.beginWithHeaders(
            self.status,
            self.typeStorage()[0..self.content_type_len],
            self.body_len,
            self.headerStorage()[0..self.header_len],
        );
        if (self.borrowed) |span| {
            try self.writer.borrow(span);
        } else {
            try self.writer.writeDraftBody(body);
        }
        self.published = true;
        return self.writer.finish();
    }

    /// Reset only the current unpublished draft. A mapper may now prepare a
    /// replacement response; older arena prefixes/cells remain untouched.
    pub fn discard(self: *Response) !void {
        if (self.published) return error.InvalidState;
        try self.writer.discardDraft();
        self.header_len = 0;
        self.header_count = 0;
        self.content_type_len = 0;
        self.body_len = 0;
        self.borrowed = null;
        self.status = 200;
        self.prepared = false;
        self.streaming = false;
        self.stream_finished = false;
        self.stream_error = null;
        self.stream_written = 0;
        self.stream_length = null;
    }

    /// Guaranteed storage for the generic fallback follows from valid Limits;
    /// zero/tiny body allowances use an empty response. No trace or stale draft
    /// prefix reaches the client. Published output cannot be replaced.
    pub fn errorResponse(self: *Response, status: u16) !api.Action {
        try self.discard();
        const reason = api.reason(status);
        try self.text(status, if (reason.len <= self.limits.body_bytes) reason else "");
        return self.finish();
    }
};

/// Standard Zig writer backed by a Response's bounded streaming storage.
/// Do not move this handle while a pointer returned by writer() is in use.
/// Errors from this response sink are sticky; failure() exposes the cause.
/// Propagate errors from custom formatters or source readers used with writer().
pub const Stream = struct {
    response: *Response,
    interface: std.Io.Writer = .{
        .vtable = &.{ .drain = drain, .flush = flushWriter, .rebase = rebase },
        .buffer = &.{},
    },

    pub fn writer(self: *Stream) *std.Io.Writer {
        return &self.interface;
    }

    pub fn failure(self: *const Stream) ?anyerror {
        return self.response.stream_error;
    }

    pub fn writeAll(self: *Stream, bytes: []const u8) !void {
        self.interface.writeAll(bytes) catch |err| return self.failure() orelse err;
    }

    pub fn print(self: *Stream, comptime format: []const u8, args: anytype) !void {
        self.interface.print(format, args) catch |err| {
            if (self.response.stream_error == null) self.response.stream_error = err;
            return self.failure().?;
        };
    }

    /// Wait for the I/O owner to finish transmitting this snapshot. This is
    /// local send completion, not acknowledgement by the peer application.
    pub fn flush(self: *Stream) !void {
        self.response.flushStream() catch |err| {
            self.response.stream_error = err;
            return err;
        };
    }

    /// End application writes. App publishes the final framing when the
    /// handler returns. Returning normally also ends a healthy open stream.
    pub fn finish(self: *Stream) !void {
        self.response.endStream() catch |err| {
            self.response.stream_error = err;
            return err;
        };
    }

    fn drain(out: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Stream = @fieldParentPtr("interface", out);
        std.debug.assert(out.end == 0 and data.len > 0);
        for (data, 0..) |bytes, index| {
            if (index == data.len - 1 and splat == 0) break;
            if (bytes.len == 0) continue;
            return self.response.appendStream(bytes) catch |err| {
                self.response.stream_error = err;
                return error.WriteFailed;
            };
        }
        return 0;
    }

    fn flushWriter(out: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *Stream = @fieldParentPtr("interface", out);
        self.flush() catch return error.WriteFailed;
    }

    fn rebase(out: *std.Io.Writer, _: usize, _: usize) std.Io.Writer.Error!void {
        const self: *Stream = @fieldParentPtr("interface", out);
        if (self.response.stream_error == null) self.response.stream_error = error.WriterBufferUnavailable;
        return error.WriteFailed;
    }
};

const testing = std.testing;

fn testCache() api.HeaderCache {
    var cache: api.HeaderCache = .{};
    cache.refresh("Sun, 06 Sep 2026 12:34:56 GMT");
    return cache;
}

test "stream writer preserves vector order and makes a length error sticky" {
    var arena: [2048]u8 = undefined;
    const cache = testCache();
    var writer = api.Writer.init(&arena, &cache, 0);
    writer.open(0, true, false);
    var cancelled: std.atomic.Value(bool) = .init(false);
    var request: api.http.Request = undefined;
    var state: [8]usize = @splat(0);
    var context: api.Context = .{
        .request = &request,
        .writer = &writer,
        .event = .request,
        .state = &state,
        .application = null,
        .cancelled = &cancelled,
        .blocking_flush = .{
            .context = &writer,
            .flush = struct {
                fn flush(_: *anyopaque) api.FlushError!void {
                    return error.InvalidState; // This fixture must stay unpublished.
                }
            }.flush,
        },
    };
    var response = try Response.init(&writer, .{ .header_bytes = 64, .body_bytes = 32 });
    response.context = &context;
    response.stream_limit = 64;
    var stream = try response.stream(200, "text/plain", .{ .content_length = 5 });
    var pieces = [_][]const u8{ "a", "bc" };
    try stream.writer().writeSplatAll(&pieces, 2);
    try testing.expectEqualStrings("abcbc", response.bodyStorage()[0..response.body_len]);
    try testing.expectError(error.WriteFailed, stream.writer().writeAll("x"));
    try testing.expectEqual(error.ResponseLengthMismatch, stream.failure().?);
    try testing.expectError(error.ResponseLengthMismatch, stream.finish());
    try testing.expectError(error.ResponseLengthMismatch, response.finish());
    try testing.expect(!writer.began and !writer.frozen);
    // A caught error cannot turn a truncated draft into success. App can still
    // replace this wholly private response with its normal error policy.
    try testing.expectEqual(api.Action.finish, try response.errorResponse(500));
    try testing.expectEqualStrings("Internal Server Error", writer.committed());
}

test "draft copies stack metadata and body and preserves earlier frozen bytes" {
    var arena: [2048]u8 = @splat(0xa5);
    const prefix = "older response stays frozen";
    @memcpy(arena[0..prefix.len], prefix);
    const cache = testCache();
    var writer = api.Writer.init(&arena, &cache, 0);
    writer.open(prefix.len, true, false);
    var response = try Response.init(&writer, .{ .header_bytes = 512, .body_bytes = 256 });
    var header_value = "original".*;
    var body = "Hello".*;
    var content_type = "text/plain".*;
    try response.header("X-Note", &header_value);
    try response.bytes(201, &content_type, &body);
    @memset(&header_value, 'x');
    @memset(&body, 'x');
    @memset(&content_type, 'x');
    try response.header("Set-Cookie", "a=1");
    try response.header("Set-Cookie", "b=2");
    try testing.expect(!writer.began and !writer.frozen);
    try testing.expectEqual(api.Action.finish, try response.finish());
    try testing.expectEqualStrings(prefix, arena[0..prefix.len]);
    try testing.expectEqualStrings("Hello", writer.committed());
    const head = arena[writer.base..writer.body_start];
    try testing.expect(std.mem.indexOf(u8, head, "Content-Type: text/plain\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, head, "X-Note: original\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\n") != null);
    try testing.expectEqual(@as(usize, 5), writer.draft_copy_bytes);
    try testing.expectError(error.InvalidState, response.finish());
    try testing.expectError(error.InvalidState, response.errorResponse(500));
}

test "header bounds and injection failures leave the unpublished draft usable" {
    var arena: [1024]u8 = undefined;
    const cache = testCache();
    var writer = api.Writer.init(&arena, &cache, 0);
    writer.open(0, true, false);
    var response = try Response.init(&writer, .{ .header_bytes = 6, .body_bytes = 10, .max_headers = 1 });
    try testing.expectError(error.InvalidHeader, response.header("Bad Name", "ok"));
    try testing.expectError(error.InvalidHeader, response.header("X", "ok\r\nInjected: yes"));
    try testing.expectError(error.ReservedHeader, response.header("cOnTeNt-LeNgTh", "0"));
    try testing.expectError(error.ReservedHeader, response.header("Transfer-Encoding", "chunked"));
    try testing.expectError(error.ResponseLimit, response.header("X", "ab"));
    try response.header("X", "a");
    try testing.expectError(error.ResponseLimit, response.header("Y", "b"));
    try response.text(200, "ok");
    _ = try response.finish();
    try testing.expect(std.mem.indexOf(u8, arena[0..writer.body_start], "X: a\r\n\r\n") != null);
    try testing.expectEqualStrings("ok", writer.committed());
}

test "JSON exact fit and overflow never publish an incomplete success" {
    var arena: [1024]u8 = undefined;
    const cache = testCache();
    var writer = api.Writer.init(&arena, &cache, 0);
    writer.open(0, true, false);
    var response = try Response.init(&writer, .{ .header_bytes = 0, .body_bytes = 4 });
    try response.jsonValue(200, "ab");
    _ = try response.finish();
    try testing.expectEqualStrings("\"ab\"", writer.committed());
    writer.release();
    writer.open(0, true, false);
    response = try Response.init(&writer, .{ .header_bytes = 0, .body_bytes = 3 });
    try testing.expectError(error.WriteFailed, response.jsonValue(200, "ab"));
    try testing.expect(!response.prepared and !writer.began and writer.buffered == 0);
    _ = try response.errorResponse(500);
    try testing.expectEqual(@as(u16, 500), writer.status);
    try testing.expectEqualStrings("", writer.committed());
    try testing.expect(std.mem.indexOf(u8, arena[0..writer.buffered], "\"ab") == null);
}

test "failed custom serializer executes once and custom mapper discards all draft fields" {
    const Value = struct {
        calls: *usize,
        pub fn jsonStringify(self: @This(), out: *std.json.Stringify) !void {
            self.calls.* += 1;
            try out.writer.writeAll("partial-private-data");
            return error.WriteFailed;
        }
    };
    var arena: [1024]u8 = undefined;
    const cache = testCache();
    var writer = api.Writer.init(&arena, &cache, 0);
    writer.open(0, true, false);
    var response = try Response.init(&writer, .{ .header_bytes = 64, .body_bytes = 64 });
    var calls: usize = 0;
    try response.header("X-Unpublished", "private");
    try testing.expectError(error.WriteFailed, response.jsonValue(200, Value{ .calls = &calls }));
    try testing.expectEqual(@as(usize, 1), calls);
    try response.discard();
    try response.header("X-Error", "mapped");
    try response.text(409, "conflict");
    _ = try response.finish();
    const wire = arena[0..writer.buffered];
    try testing.expect(std.mem.indexOf(u8, wire, "private") == null);
    try testing.expect(std.mem.indexOf(u8, wire, "X-Error: mapped\r\n") != null);
    try testing.expectEqualStrings("conflict", writer.committed());
}

test "response states bodyless statuses HEAD and explicit borrowing retain contracts" {
    var arena: [1024]u8 = undefined;
    const cache = testCache();
    var writer = api.Writer.init(&arena, &cache, 0);
    writer.open(0, true, true);
    var response = try Response.init(&writer, .{ .header_bytes = 0, .body_bytes = 16 });
    try testing.expectError(error.ResponseNotPrepared, response.finish());
    try testing.expectError(error.InvalidResponse, response.text(204, "body"));
    try testing.expectError(error.InvalidResponse, response.text(205, "body"));
    try testing.expectError(error.InvalidResponse, response.bytes(200, "text/plain\n", "body"));
    try testing.expectError(error.ResponseLimit, response.text(200, "body beyond limit"));
    const asset = "immutable asset";
    try response.borrowBody(200, "text/plain", asset);
    try testing.expectError(error.InvalidState, response.text(200, "again"));
    _ = try response.finish();
    try testing.expect(writer.head_only);
    try testing.expectEqual(@as(?usize, asset.len), writer.content_length);
    try testing.expectEqual(asset.ptr, writer.borrowed.?.ptr);
    try testing.expectEqual(@as(usize, 0), writer.draft_copy_bytes);
    writer.release();
    writer.open(0, true, false);
    response = try Response.init(&writer, .{ .header_bytes = 0, .body_bytes = 0 });
    try response.text(304, "");
    _ = try response.finish();
    try testing.expectEqual(@as(usize, 0), writer.bodyBytes());
    try testing.expect(std.mem.indexOf(u8, arena[0..writer.buffered], "Content-Length") == null);
}

test "configured reservation includes all draft storage and exact output fit" {
    const limits: Limits = .{ .header_bytes = 32, .body_bytes = 8 };
    var arena: [api.header_reserve_bytes + api.max_content_type_bytes + 32 + 8]u8 = undefined;
    try testing.expectEqual(arena.len, try limits.reservationBytes());
    const cache = testCache();
    var writer = api.Writer.init(&arena, &cache, 0);
    writer.open(0, true, false);
    var response = try Response.init(&writer, limits);
    try response.print(200, "text/plain", "{s}:{d}", .{ "value", 12 });
    _ = try response.finish();
    try testing.expectEqualStrings("value:12", writer.committed());
    writer.release();
    writer.open(1, true, false);
    try testing.expectError(error.OutputReservationUnavailable, Response.init(&writer, limits));
    try testing.expectError(error.InvalidResponseLimits, (Limits{ .body_bytes = 1024 * 1024 }).reservationBytes());
    try testing.expectError(error.InvalidResponseLimits, (Limits{ .max_headers = 1025 }).validate());
}
