const std = @import("std");
pub const http = @import("http.zig");
const assert = std.debug.assert;

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

/// Largest response head this framework generates, plus the chunk-size field.
/// The scheduler guarantees at least this much free arena before a callback.
pub const header_reserve_bytes: usize = 384;
/// Fixed-width chunk-size field written before each chunked snapshot.
pub const chunk_size_field_bytes: usize = 10;
/// Space kept free for the chunk CRLF and the final zero chunk.
const chunk_slack_bytes: usize = 7;
pub const max_content_type_bytes: usize = 128;

/// Ordinary response construction errors, including untrusted header values.
pub fn validateHeader(name: []const u8, value: []const u8) !void {
    if (name.len == 0) return error.InvalidHeader;
    for (name) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
        else => return error.InvalidHeader,
    };
    for (value) |byte| {
        if ((byte < 32 and byte != '\t') or byte == 127) return error.InvalidHeader;
    }
    inline for (.{ "Content-Length", "Transfer-Encoding", "Connection", "Content-Type", "Trailer", "Upgrade", "Keep-Alive", "Proxy-Connection", "TE", "Server", "Date" }) |reserved| {
        if (std.ascii.eqlIgnoreCase(name, reserved)) return error.ReservedHeader;
    }
}

fn validateHeaderBlock(bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = std.mem.findPosLinear(u8, bytes, offset, "\r\n") orelse return error.InvalidHeader;
        const line = bytes[offset..end];
        const colon = std.mem.findScalar(u8, line, ':') orelse return error.InvalidHeader;
        try validateHeader(line[0..colon], line[colon + 1 ..]);
        offset = end + 2;
    }
}

/// Date/status prefix rebuilt by one I/O owner once per second. Inline begin()
/// reads that owner's cache; worker begin() reads an exclusive slot snapshot
/// published before dispatch. begin() copies the prefix instead of formatting.
pub const HeaderCache = struct {
    date: [29]u8 = undefined,
    ok_prefix: [80]u8 = undefined,
    ok_prefix_len: usize = 0,

    const ok_head = "HTTP/1.1 200 OK\r\nServer: zig-http\r\nDate: ";

    pub fn refresh(self: *HeaderCache, date: *const [29]u8) void {
        self.date = date.*;
        var n: usize = 0;
        @memcpy(self.ok_prefix[n..][0..ok_head.len], ok_head);
        n += ok_head.len;
        @memcpy(self.ok_prefix[n..][0..29], date);
        n += 29;
        @memcpy(self.ok_prefix[n..][0..2], "\r\n");
        n += 2;
        self.ok_prefix_len = n;
    }
};

pub fn reason(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        205 => "Reset Content",
        301 => "Moved Permanently",
        302 => "Found",
        303 => "See Other",
        304 => "Not Modified",
        307 => "Temporary Redirect",
        308 => "Permanent Redirect",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        413 => "Content Too Large",
        414 => "URI Too Long",
        415 => "Unsupported Media Type",
        417 => "Expectation Failed",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        505 => "HTTP Version Not Supported",
        else => "Response",
    };
}

/// Writes the shortest decimal representation; returns the byte count.
pub fn putDecimal(out: []u8, value: usize) usize {
    var count: usize = 1;
    var probe = value;
    while (probe >= 10) : (probe /= 10) count += 1;
    var remaining = value;
    var at = count;
    while (at > 0) {
        at -= 1;
        out[at] = @intCast('0' + remaining % 10);
        remaining /= 10;
    }
    return count;
}

/// Copy a short span with word stores instead of a libc call; the destination
/// must hold `src.len` bytes.
pub inline fn copyShort(dst: []u8, src: []const u8) void {
    if (src.len > 32) {
        @memcpy(dst[0..src.len], src);
        return;
    }
    var at: usize = 0;
    while (at + 8 <= src.len) : (at += 8) dst[at..][0..8].* = src[at..][0..8].*;
    while (at < src.len) : (at += 1) dst[at] = src[at];
}

/// Writes exactly eight lowercase hex digits and CRLF: a valid chunk-size line
/// with leading zeros, so the field width is fixed before the length is known.
pub fn putChunkSize(out: *[chunk_size_field_bytes]u8, value: usize) void {
    assert(value <= std.math.maxInt(u32));
    const hex = "0123456789abcdef";
    var remaining: u32 = @intCast(value);
    var at: usize = 8;
    while (at > 0) {
        at -= 1;
        out[at] = hex[remaining & 15];
        remaining >>= 4;
    }
    out[8] = '\r';
    out[9] = '\n';
}

/// Only the current application callback can mutate a Writer. Returning flush
/// or finish transfers its committed bytes to the I/O owner until completion.
///
/// The Writer appends into one contiguous per-connection output arena that is
/// shared by every not yet sent response of that connection. Response head
/// bytes are written at begin(); body bytes follow them, so a whole batch of
/// generated responses forms one span. Borrowed spans at most
/// `copy_threshold` bytes long are copied into the arena as an explicit,
/// counted exception; longer spans stay borrowed and are described separately.
pub const Writer = struct {
    arena: []u8,
    header_cache: *const HeaderCache,
    /// First byte of this response snapshot within the arena.
    base: usize = 0,
    /// First body byte; the head and any chunk-size field end here.
    body_start: usize = 0,
    /// Absolute end of committed bytes.
    buffered: usize = 0,
    reserved: usize = 0,
    borrowed: ?[]const u8 = null,
    chunk_size_at: ?usize = null,
    status: u16 = 200,
    content_type: []const u8 = "text/plain",
    content_length: ?usize = null,
    copy_threshold: usize = 0,
    keep_alive: bool = true,
    head_only: bool = false,
    began: bool = false,
    frozen: bool = false,
    headers_committed: bool = false,
    copied_borrow: bool = false,
    /// Payload bytes compacted from an unpublished one-shot draft.
    draft_copy_bytes: usize = 0,

    pub fn init(arena: []u8, header_cache: *const HeaderCache, copy_threshold: usize) Writer {
        return .{ .arena = arena, .header_cache = header_cache, .copy_threshold = copy_threshold };
    }

    /// Start a new response whose bytes begin at `at`. The framework calls this
    /// once per request with the request's connection/HEAD facts.
    pub fn open(self: *Writer, at: usize, keep_alive: bool, head_only: bool) void {
        assert(at <= self.arena.len - header_reserve_bytes);
        self.base = at;
        self.body_start = at;
        self.buffered = at;
        self.reserved = 0;
        self.borrowed = null;
        self.chunk_size_at = null;
        self.status = 200;
        self.content_type = "text/plain";
        self.content_length = null;
        self.keep_alive = keep_alive;
        self.head_only = head_only;
        self.began = false;
        self.frozen = false;
        self.headers_committed = false;
        self.copied_borrow = false;
        self.draft_copy_bytes = 0;
    }

    /// Continue the same response after a flush drained the arena. The head is
    /// already on the wire; a chunked response gets a fresh size field.
    pub fn resumeSnapshot(self: *Writer, at: usize) void {
        assert(!self.frozen and self.began and self.headers_committed);
        assert(at <= self.arena.len - header_reserve_bytes);
        self.base = at;
        self.buffered = at;
        self.reserved = 0;
        self.borrowed = null;
        self.chunk_size_at = null;
        self.copied_borrow = false;
        self.draft_copy_bytes = 0;
        if (self.chunked()) {
            self.chunk_size_at = at;
            self.buffered += chunk_size_field_bytes;
        }
        self.body_start = self.buffered;
    }

    pub fn chunked(self: *const Writer) bool {
        return self.content_length == null and !self.head_only and self.status != 204 and self.status != 304;
    }

    fn slack(self: *const Writer) usize {
        return if (self.chunked()) chunk_slack_bytes else 0;
    }

    /// Body bytes the application can still reserve in one snapshot after a
    /// flush, independent of how full the arena currently is.
    pub fn capacity(self: *const Writer) usize {
        return self.arena.len - header_reserve_bytes - chunk_slack_bytes;
    }

    pub fn begin(self: *Writer, status: u16, content_type: []const u8, length: ?usize) !void {
        return self.beginWithHeaders(status, content_type, length, "");
    }

    /// Extra fields are complete name/value lines ending in CRLF. Their
    /// framing is validated before mutating the writer. Callers reserve the
    /// additional head space before execution; ordinary begin keeps its old
    /// fixed reserve. Extra fields may reside later in this writer's arena.
    pub fn beginWithHeaders(self: *Writer, status: u16, content_type: []const u8, length: ?usize, extra_headers: []const u8) !void {
        if (self.frozen or self.began or self.headers_committed) return error.InvalidState;
        if (status < 200 or status > 599 or content_type.len > max_content_type_bytes) return error.InvalidResponse;
        for (content_type) |byte| if (byte < 32 or byte > 126) return error.InvalidResponse;
        try validateHeaderBlock(extra_headers);
        const head_bound = std.math.add(usize, header_reserve_bytes, extra_headers.len) catch return error.InvalidResponse;
        if (head_bound > self.arena.len - self.buffered) return error.WouldBlock;
        self.status = status;
        self.content_type = content_type;
        self.content_length = length;
        self.began = true;
        // The scheduler only dispatches with header_reserve_bytes free.
        assert(self.arena.len - self.buffered >= header_reserve_bytes);
        var n = self.buffered;
        const out = self.arena;
        if (status == 200) {
            // Fixed-size copy of the cached prefix; the reserve guarantees room
            // and the logical end advances by the prefix's real length.
            const cache = self.header_cache;
            out[n..][0..cache.ok_prefix.len].* = cache.ok_prefix;
            n += cache.ok_prefix_len;
        } else {
            @memcpy(out[n..][0..9], "HTTP/1.1 ");
            n += 9;
            out[n] = @intCast('0' + status / 100);
            out[n + 1] = @intCast('0' + (status / 10) % 10);
            out[n + 2] = @intCast('0' + status % 10);
            out[n + 3] = ' ';
            n += 4;
            const text = reason(status);
            @memcpy(out[n..][0..text.len], text);
            n += text.len;
            const server = "\r\nServer: zig-http\r\nDate: ";
            @memcpy(out[n..][0..server.len], server);
            n += server.len;
            @memcpy(out[n..][0..29], &self.header_cache.date);
            n += 29;
            @memcpy(out[n..][0..2], "\r\n");
            n += 2;
        }
        @memcpy(out[n..][0..14], "Content-Type: ");
        n += 14;
        copyShort(out[n..], content_type);
        self.content_type = out[n..][0..content_type.len];
        n += content_type.len;
        @memcpy(out[n..][0..2], "\r\n");
        n += 2;
        if (status != 204 and status != 304) {
            if (length) |value| {
                @memcpy(out[n..][0..16], "Content-Length: ");
                n += 16;
                n += putDecimal(out[n..], value);
                @memcpy(out[n..][0..2], "\r\n");
                n += 2;
            } else {
                const coding = "Transfer-Encoding: chunked\r\n";
                @memcpy(out[n..][0..coding.len], coding);
                n += coding.len;
            }
        }
        if (!self.keep_alive) {
            const close = "Connection: close\r\n";
            @memcpy(out[n..][0..close.len], close);
            n += close.len;
        }
        std.mem.copyForwards(u8, out[n..][0..extra_headers.len], extra_headers);
        n += extra_headers.len;
        @memcpy(out[n..][0..2], "\r\n");
        n += 2;
        if (self.chunked()) {
            self.chunk_size_at = n;
            n += chunk_size_field_bytes;
        }
        assert(n - self.buffered <= head_bound);
        self.buffered = n;
        self.body_start = n;
    }

    pub fn reserve(self: *Writer, count: usize) ![]u8 {
        if (self.frozen or self.borrowed != null or self.reserved != 0) return error.InvalidState;
        if (count > self.arena.len - self.buffered - self.slack()) return error.WouldBlock;
        self.reserved = count;
        return self.arena[self.buffered..][0..count];
    }

    pub fn commit(self: *Writer, count: usize) void {
        assert(!self.frozen);
        assert(count <= self.reserved);
        assert(count <= self.arena.len - self.buffered - self.slack());
        self.buffered += count;
        self.reserved = 0;
    }

    /// Convenience copying path. reserve/commit writes directly into output storage.
    pub fn write(self: *Writer, bytes: []const u8) !void {
        const destination = try self.reserve(bytes.len);
        @memcpy(destination, bytes);
        self.commit(bytes.len);
    }

    /// Storage must be request-owned input or immutable server-lifetime assets;
    /// there is no dynamic lease-release notification yet. Spans up to the
    /// configured copy threshold are copied into the arena when they fit, which
    /// keeps small responses in one span; the copy is counted, never hidden.
    pub fn borrow(self: *Writer, bytes: []const u8) !void {
        if (self.frozen or self.generatedBytes() != 0 or self.reserved != 0 or self.borrowed != null)
            return error.InvalidState;
        if (bytes.len <= self.copy_threshold and bytes.len <= self.arena.len - self.buffered - self.slack()) {
            copyShort(self.arena[self.buffered..], bytes);
            self.buffered += bytes.len;
            self.copied_borrow = true;
            return;
        }
        self.borrowed = bytes;
    }

    pub fn flush(self: *Writer) Action {
        assert(!self.frozen and self.reserved == 0 and self.began);
        self.frozen = true;
        return .flush;
    }

    pub fn finish(self: *Writer) Action {
        assert(!self.frozen and self.reserved == 0 and self.began);
        self.frozen = true;
        return .finish;
    }

    /// Bytes generated into the arena for this snapshot, after the head.
    pub fn generatedBytes(self: *const Writer) usize {
        return self.buffered - self.body_start;
    }

    /// Logical body length of this snapshot: generated or borrowed bytes.
    pub fn bodyBytes(self: *const Writer) usize {
        return self.generatedBytes() + if (self.borrowed) |span| span.len else 0;
    }

    /// Committed body bytes as one slice: generated arena bytes or the borrow.
    pub fn committed(self: *const Writer) []const u8 {
        assert(self.frozen);
        return self.borrowed orelse self.arena[self.body_start..self.buffered];
    }

    pub fn release(self: *Writer) void {
        assert(self.frozen);
        self.reserved = 0;
        self.borrowed = null;
        self.frozen = false;
    }
};

fn testCache() HeaderCache {
    var cache: HeaderCache = .{};
    cache.refresh("Sat, 05 Sep 2026 12:34:56 GMT");
    return cache;
}

test "begin writes the head into the arena and flush keeps the snapshot" {
    var arena: [1024]u8 = undefined;
    const cache = testCache();
    var writer = Writer.init(&arena, &cache, 0);
    writer.open(0, true, false);
    try writer.begin(200, "text/plain", 7);
    const head = "HTTP/1.1 200 OK\r\nServer: zig-http\r\nDate: Sat, 05 Sep 2026 12:34:56 GMT\r\nContent-Type: text/plain\r\nContent-Length: 7\r\n\r\n";
    try std.testing.expectEqualStrings(head, arena[0..writer.body_start]);
    const reserved = try writer.reserve(8);
    @memcpy(reserved[0..3], "one");
    writer.commit(3);
    try writer.write(" two");
    try std.testing.expectEqual(Action.flush, writer.flush());
    try std.testing.expectEqualStrings("one two", writer.committed());
    try std.testing.expectEqualStrings(head ++ "one two", arena[0..writer.buffered]);
    try std.testing.expectError(error.InvalidState, writer.reserve(1));
    writer.release();
    try std.testing.expectEqual(@as(usize, 7), writer.generatedBytes());
}

test "non-200 heads, close and chunked size fields are laid out exactly" {
    var arena: [2048]u8 = undefined;
    const cache = testCache();
    var writer = Writer.init(&arena, &cache, 0);
    writer.open(100, false, false);
    try writer.begin(404, "text/html; charset=utf-8", null);
    const head = "HTTP/1.1 404 Not Found\r\nServer: zig-http\r\nDate: Sat, 05 Sep 2026 12:34:56 GMT\r\n" ++
        "Content-Type: text/html; charset=utf-8\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n";
    try std.testing.expectEqualStrings(head, arena[100 .. 100 + head.len]);
    try std.testing.expectEqual(@as(usize, 100 + head.len), writer.chunk_size_at.?);
    try std.testing.expectEqual(@as(usize, 100 + head.len + chunk_size_field_bytes), writer.body_start);
    var field: [chunk_size_field_bytes]u8 = undefined;
    putChunkSize(&field, 0xabc);
    try std.testing.expectEqualStrings("00000abc\r\n", &field);
    var decimal: [20]u8 = undefined;
    try std.testing.expectEqualStrings("0", decimal[0..putDecimal(&decimal, 0)]);
    try std.testing.expectEqualStrings("18446744073709551615", decimal[0..putDecimal(&decimal, std.math.maxInt(usize))]);
}

test "borrow copies small spans when allowed and keeps large spans borrowed" {
    var arena: [1024]u8 = undefined;
    const cache = testCache();
    var writer = Writer.init(&arena, &cache, 16);
    writer.open(0, true, false);
    try writer.begin(200, "text/plain", 13);
    try writer.borrow("Hello, World!");
    try std.testing.expect(writer.copied_borrow and writer.borrowed == null);
    try std.testing.expectEqual(@as(usize, 13), writer.bodyBytes());
    _ = writer.finish();
    try std.testing.expectEqualStrings("Hello, World!", writer.committed());
    writer.release();
    var large = Writer.init(&arena, &cache, 16);
    large.open(0, true, false);
    try large.begin(200, "application/octet-stream", 32);
    const body = "0123456789abcdef0123456789abcdef";
    try large.borrow(body);
    try std.testing.expect(!large.copied_borrow);
    try std.testing.expectEqual(body.ptr, large.borrowed.?.ptr);
    _ = large.finish();
    try std.testing.expectEqual(body.ptr, large.committed().ptr);
    var strict = Writer.init(&arena, &cache, 0);
    strict.open(0, true, false);
    try strict.begin(200, "text/plain", 13);
    try strict.borrow("Hello, World!");
    try std.testing.expect(!strict.copied_borrow and strict.borrowed != null);
}

test "reservation capacity errors are recoverable and leave slack for chunk framing" {
    var arena: [header_reserve_bytes + 32]u8 = undefined;
    const cache = testCache();
    var writer = Writer.init(&arena, &cache, 0);
    writer.open(0, true, false);
    try writer.begin(200, "text/plain", null);
    const free = arena.len - writer.buffered - chunk_slack_bytes;
    try std.testing.expectError(error.WouldBlock, writer.reserve(free + 1));
    _ = try writer.reserve(free);
    writer.commit(free);
    try std.testing.expectEqual(chunk_slack_bytes, arena.len - writer.buffered);
    _ = writer.flush();
    writer.headers_committed = true; // The I/O owner records the sent head.
    writer.release();
    writer.resumeSnapshot(0);
    try std.testing.expectEqual(@as(usize, 0), writer.chunk_size_at.?);
    try std.testing.expectEqual(chunk_size_field_bytes, writer.body_start);
    try std.testing.expectError(error.InvalidState, writer.begin(200, "text/plain", null));
}

test "extra header validation is transactional and bounded before begin" {
    var arena: [1024]u8 = undefined;
    const cache = testCache();
    var writer = Writer.init(&arena, &cache, 0);
    writer.open(0, true, false);
    try std.testing.expectError(error.InvalidHeader, writer.beginWithHeaders(200, "text/plain", 0, "Bad Name: x\r\n"));
    try std.testing.expectError(error.InvalidHeader, writer.beginWithHeaders(200, "text/plain", 0, "X: missing terminator"));
    try std.testing.expectError(error.ReservedHeader, writer.beginWithHeaders(200, "text/plain", 0, "Connection: close\r\n"));
    try std.testing.expect(!writer.began and writer.buffered == 0);
    try writer.beginWithHeaders(303, "text/plain", 0, "Location: /next\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n");
    _ = writer.finish();
    try std.testing.expect(std.mem.indexOf(u8, arena[0..writer.buffered], "HTTP/1.1 303 See Other\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, arena[0..writer.buffered], "Location: /next\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\n"));
    writer.release();
    writer.open(arena.len - header_reserve_bytes, true, false);
    try std.testing.expectError(error.WouldBlock, writer.beginWithHeaders(200, "text/plain", 0, "X: y\r\n"));
    try std.testing.expect(!writer.began and writer.buffered == writer.base);
    try writer.begin(200, "text/plain", 0);
}
