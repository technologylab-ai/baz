//! Bounded one-shot response drafts. All byte storage belongs to the current
//! connection's startup output arena; no allocator or request-local arena is
//! needed. The scheduler reserves Limits.reservationBytes before application
//! execution. Earlier frozen responses are never part of this draft.
const std = @import("std");
const api = @import("api.zig");

pub const Limits = struct {
    /// Serialized extra fields, including names, separators and CRLFs.
    header_bytes: u32 = 2048,
    /// Maximum logical body, whether generated, copied or explicitly borrowed.
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
    limits: Limits,
    header_len: usize = 0,
    header_count: u16 = 0,
    content_type_len: usize = 0,
    body_len: usize = 0,
    borrowed: ?[]const u8 = null,
    status: u16 = 200,
    prepared: bool = false,
    published: bool = false,

    pub fn init(writer: *api.Writer, limits: Limits) !Response {
        if (writer.frozen or writer.began or writer.headers_committed or writer.reserved != 0 or writer.buffered != writer.base)
            return error.InvalidState;
        if (try limits.reservationBytes() > writer.arena.len - writer.base)
            return error.OutputReservationUnavailable;
        return .{ .writer = writer, .limits = limits };
    }

    fn typeStorage(self: *Response) []u8 {
        return self.writer.arena[self.writer.base + api.header_reserve_bytes ..][0..api.max_content_type_bytes];
    }

    fn headerStorage(self: *Response) []u8 {
        return self.writer.arena[self.writer.base + api.header_reserve_bytes + api.max_content_type_bytes ..][0..self.limits.header_bytes];
    }

    fn bodyStorage(self: *Response) []u8 {
        return self.writer.arena[self.writer.base + api.header_reserve_bytes + api.max_content_type_bytes + self.limits.header_bytes ..][0..self.limits.body_bytes];
    }

    fn checkDraft(self: *const Response) !void {
        if (self.published or self.writer.began or self.writer.frozen or self.writer.headers_committed)
            return error.InvalidState;
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

    /// Publish one complete response to the low-level writer. Generated bytes
    /// move once within the reserved arena to eliminate unused head capacity;
    /// the retained batch is still one contiguous span. There are no fallible
    /// application callbacks between constructing the head and freezing output.
    pub fn finish(self: *Response) !api.Action {
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
            const destination = try self.writer.reserve(body.len);
            std.mem.copyForwards(u8, destination, body);
            self.writer.commit(body.len);
            self.writer.draft_copy_bytes = body.len;
        }
        self.published = true;
        return self.writer.finish();
    }

    /// Reset only the current unpublished draft. A mapper may now prepare a
    /// replacement response; older arena prefixes/cells remain untouched.
    pub fn discard(self: *Response) !void {
        if (self.published or self.writer.frozen or self.writer.headers_committed) return error.InvalidState;
        self.writer.open(self.writer.base, self.writer.keep_alive, self.writer.head_only);
        self.header_len = 0;
        self.header_count = 0;
        self.content_type_len = 0;
        self.body_len = 0;
        self.borrowed = null;
        self.status = 200;
        self.prepared = false;
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

const testing = std.testing;

fn testCache() api.HeaderCache {
    var cache: api.HeaderCache = .{};
    cache.refresh("Sun, 06 Sep 2026 12:34:56 GMT");
    return cache;
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
