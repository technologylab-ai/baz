//! Bounded HTTP/1.1 framing, following RFC 9112 sections 2, 3, 5, 6, 7 and 9.
//! RFC 9110 supplies Host, Connection and Expect semantics; URI syntax is from
//! RFC 3986. This is a strict origin-server parser, not a forwarding proxy.
//!
//! The caller owns one stable receive buffer and extends its initialized prefix.
//! Request slices and body spans borrow that buffer until the caller releases
//! the request. No allocator, header table, payload coalescing or text decoding
//! is involved. Syntax scanning is incremental; optional header lookup is lazy.
//! Only HTTP/1.1 and the chunked transfer coding are supported. Duplicate
//! Content-Length fields/list forms are rejected, even if their values agree.
//! All parse errors require closing the connection: no ambiguous suffix reuse.
const std = @import("std");
const assert = std.debug.assert;
const equal = std.mem.eql;
const equalCase = std.ascii.eqlIgnoreCase;

pub const Limits = struct {
    /// Request line, header lines and final CRLF; trailers share this budget.
    max_header_bytes: u32 = 8 * 1024,
    /// Initial fields and trailer fields share this budget.
    max_header_count: u16 = 64,
    max_body_bytes: u32 = 256 * 1024,
    /// Complete request including all chunk framing/extensions/trailers.
    max_wire_bytes: u32 = 280 * 1024,
    max_target_bytes: u16 = 2048,
};

pub const ParseError = error{
    BadRequest,
    HeadersTooLarge,
    BodyTooLarge,
    TargetTooLong,
    UnsupportedTransferEncoding,
    ExpectationFailed,
    UnsupportedVersion,
};

pub const Request = struct {
    /// Methods are case-sensitive tokens, including application-defined methods.
    /// Parsing CONNECT/Upgrade syntax does not implement tunnelling or upgrades.
    method: []const u8,
    target: []const u8,
    /// Initial field lines including their CRLFs, without request line/blank line.
    headers: []const u8,
    /// Includes chunk framing and discarded trailers when `chunked` is true.
    body_wire: []const u8,
    chunked: bool,
    body_bytes: usize,
    /// Offset of the first pipelined byte, relative to Parser.parse input.
    consumed: usize,
    keep_alive: bool,
    expect_continue: bool,
    head_only: bool,

    /// First field value, trimmed of optional surrounding SP/HTAB. Repeated
    /// application fields remain in `headers`; this does not join their values.
    /// Names are case-insensitive; values remain unmodified borrowed bytes.
    pub fn header(self: Request, name: []const u8) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, self.headers, "\r\n");
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const colon = std.mem.findScalar(u8, line, ':') orelse unreachable;
            assert(colon > 0);
            if (equalCase(line[0..colon], name)) return trim(line[colon + 1 ..]);
        }
        return null;
    }

    pub fn body(self: Request) BodyIterator {
        return .{ .wire = self.body_wire, .chunked = self.chunked };
    }
};

/// Only construct from a successfully parsed Request. `next` borrows payload
/// spans directly from its receive buffer; a zero chunk terminates iteration.
pub const BodyIterator = struct {
    wire: []const u8,
    chunked: bool,
    offset: usize = 0,
    finished: bool = false,

    pub fn next(self: *BodyIterator) ?[]const u8 {
        if (self.finished) return null;
        assert(self.offset <= self.wire.len);
        if (!self.chunked) {
            self.finished = true;
            return if (self.wire.len == 0) null else self.wire;
        }
        const end = std.mem.findPosLinear(u8, self.wire, self.offset, "\r\n") orelse unreachable;
        const count = chunkSize(self.wire[self.offset..end], std.math.maxInt(u32)) catch unreachable;
        self.offset = end + 2;
        if (count == 0) {
            self.finished = true;
            return null;
        }
        assert(count <= self.wire.len - self.offset);
        const span = self.wire[self.offset..][0..count];
        self.offset += count;
        assert(self.wire.len - self.offset >= 2);
        assert(equal(u8, self.wire[self.offset..][0..2], "\r\n"));
        self.offset += 2;
        return span;
    }
};

pub const Parser = struct {
    limits: Limits,
    head_complete: bool = false,
    expect_continue: bool = false,
    headers_end: usize = 0,

    state: State = .request_line,
    failure: ?ParseError = null,
    scan: usize = 0,
    line_start: usize = 0,
    input_address: ?[*]const u8 = null,
    previous_length: usize = 0,
    method_end: usize = 0,
    target_start: usize = 0,
    target_end: usize = 0,
    fields_start: usize = 0,
    field_count: u32 = 0,
    content_length: ?u32 = null,
    host_seen: bool = false,
    chunked: bool = false,
    keep_alive: bool = true,
    head_only: bool = false,
    body_bytes: usize = 0,
    chunk_remaining: usize = 0,
    chunk_suffix_read: u2 = 0,
    trailer_start: usize = 0,
    consumed: usize = 0,

    const State = enum { request_line, headers, fixed_body, chunk_size, chunk_data, chunk_suffix, trailers, complete };

    pub fn init(limits: Limits) Parser {
        return .{ .limits = limits };
    }

    /// Reset parser metadata for a new independent input view. Existing Request
    /// slices may remain borrowed if their underlying bytes stay unchanged.
    /// Moving an input suffix requires every affected callback/transport borrow
    /// to have returned; resetting parser metadata does not release those borrows.
    pub fn reset(self: *Parser) void {
        self.* = init(self.limits);
    }

    /// Null means more bytes are needed. Each call must use the same buffer
    /// base and preserve previously supplied bytes; violating this is a caller
    /// ownership bug, not malformed HTTP. Errors remain sticky until reset.
    /// A supplied suffix beyond the first complete request is left uninspected.
    pub fn parse(self: *Parser, bytes: []const u8) ParseError!?Request {
        assert(bytes.len >= self.previous_length);
        if (self.input_address) |address| assert(address == bytes.ptr);
        if (bytes.len != 0) self.input_address = bytes.ptr;
        self.previous_length = bytes.len;
        if (self.failure) |failure| return failure;
        return self.parseInner(bytes) catch |failure| {
            self.failure = failure;
            return failure;
        };
    }

    fn parseInner(self: *Parser, bytes: []const u8) ParseError!?Request {
        assert(self.scan <= bytes.len);
        while (true) switch (self.state) {
            .request_line => {
                const line = try self.nextLine(bytes, @min(self.limits.max_header_bytes, self.limits.max_wire_bytes), error.HeadersTooLarge) orelse return null;
                try self.requestLine(line);
                self.fields_start = self.scan;
                self.state = .headers;
            },
            .headers => {
                const line = try self.nextLine(bytes, @min(self.limits.max_header_bytes, self.limits.max_wire_bytes), error.HeadersTooLarge) orelse return null;
                if (line.len != 0) {
                    try self.field(line, false);
                    continue;
                }
                try self.finishHead();
            },
            .fixed_body => {
                assert(self.headers_end <= self.consumed);
                assert(self.consumed <= self.limits.max_wire_bytes);
                if (bytes.len < self.consumed) return null;
                self.scan = self.consumed;
                self.state = .complete;
            },
            .chunk_size => {
                // An extension line is individually bounded as well as counted
                // against the total wire budget; it cannot consume body capacity
                // without also consuming a finite framing budget.
                const line_limit = @min(@as(u64, self.line_start) + self.limits.max_header_bytes, self.limits.max_wire_bytes);
                const line = try self.nextLine(bytes, @intCast(line_limit), error.BodyTooLarge) orelse return null;
                const remaining = self.limits.max_body_bytes - self.body_bytes;
                const count = try chunkSize(line, @intCast(remaining));
                self.body_bytes += count;
                assert(self.body_bytes <= self.limits.max_body_bytes);
                if (count == 0) {
                    self.trailer_start = self.scan;
                    self.state = .trailers;
                } else {
                    if (count > self.limits.max_wire_bytes - self.scan) return error.BodyTooLarge;
                    self.chunk_remaining = count;
                    self.state = .chunk_data;
                }
            },
            .chunk_data => {
                const end = @min(bytes.len, self.limits.max_wire_bytes);
                assert(self.scan <= end);
                const take = @min(end - self.scan, self.chunk_remaining);
                self.scan += take;
                self.chunk_remaining -= take;
                if (self.chunk_remaining != 0) {
                    if (self.scan == self.limits.max_wire_bytes) return error.BodyTooLarge;
                    return null;
                }
                self.chunk_suffix_read = 0;
                self.state = .chunk_suffix;
            },
            .chunk_suffix => {
                while (self.chunk_suffix_read < 2) {
                    if (self.scan == self.limits.max_wire_bytes) return error.BodyTooLarge;
                    if (self.scan == bytes.len) return null;
                    if (bytes[self.scan] != "\r\n"[self.chunk_suffix_read]) return error.BadRequest;
                    self.scan += 1;
                    self.chunk_suffix_read += 1;
                }
                self.line_start = self.scan;
                self.state = .chunk_size;
            },
            .trailers => {
                assert(self.headers_end <= self.limits.max_header_bytes);
                const trailer_limit = @as(u64, self.trailer_start) + (self.limits.max_header_bytes - self.headers_end);
                const limit = @min(trailer_limit, self.limits.max_wire_bytes);
                const limit_error: ParseError = if (trailer_limit <= self.limits.max_wire_bytes) error.HeadersTooLarge else error.BodyTooLarge;
                const line = try self.nextLine(bytes, @intCast(limit), limit_error) orelse return null;
                if (line.len != 0) {
                    try self.field(line, true);
                    continue;
                }
                self.consumed = self.scan;
                self.state = .complete;
            },
            .complete => return self.request(bytes),
        };
    }

    /// Each newly received line byte is scanned once. Completed lines get one
    /// syntax pass; extending a fragmented line never rescans the old prefix.
    fn nextLine(self: *Parser, bytes: []const u8, limit: usize, limit_error: ParseError) ParseError!?[]const u8 {
        assert(self.line_start <= self.scan);
        assert(self.scan <= bytes.len);
        const end = @min(bytes.len, limit);
        if (self.scan >= end) {
            if (self.scan >= limit) return limit_error;
            return null;
        }
        // A CR that ended the previous fragment is decided by this byte.
        if (self.scan > self.line_start and bytes[self.scan - 1] == '\r') {
            if (bytes[self.scan] != '\n') return error.BadRequest;
            const line = bytes[self.line_start .. self.scan - 1];
            self.scan += 1;
            self.line_start = self.scan;
            return line;
        }
        // One vector pass finds the first CR or LF. A CR is legal only when
        // immediately followed by LF; a bare LF or bare CR is malformed.
        const hit = findLineControl(bytes[0..end], self.scan) orelse {
            self.scan = end;
            if (self.scan >= limit) return limit_error;
            return null;
        };
        if (bytes[hit] == '\n') return error.BadRequest;
        if (hit + 1 >= end) {
            self.scan = hit + 1;
            if (self.scan >= limit) return limit_error;
            return null;
        }
        if (bytes[hit + 1] != '\n') return error.BadRequest;
        const line = bytes[self.line_start..hit];
        self.scan = hit + 2;
        self.line_start = self.scan;
        return line;
    }

    fn requestLine(self: *Parser, line: []const u8) ParseError!void {
        const method_end = findByte(line, ' ') orelse return error.BadRequest;
        if (!isToken(line[0..method_end])) return error.BadRequest;
        const target_start = method_end + 1;
        const target_end = (findByte(line[target_start..], ' ') orelse return error.BadRequest) + target_start;
        const method = line[0..method_end];
        const target = line[target_start..target_end];
        if (target.len > self.limits.max_target_bytes) return error.TargetTooLong;
        try validateTarget(method, target);
        const version = line[target_end + 1 ..];
        if (!equal(u8, version, "HTTP/1.1")) {
            if (version.len == 8 and equal(u8, version[0..5], "HTTP/") and std.ascii.isDigit(version[5]) and version[6] == '.' and std.ascii.isDigit(version[7])) return error.UnsupportedVersion;
            return error.BadRequest;
        }
        self.method_end = method_end;
        self.target_start = target_start;
        self.target_end = target_end;
        self.head_only = equal(u8, method, "HEAD");
    }

    fn field(self: *Parser, line: []const u8, trailer: bool) ParseError!void {
        if (self.field_count == self.limits.max_header_count) return error.HeadersTooLarge;
        self.field_count += 1;
        const colon = findByte(line, ':') orelse return error.BadRequest;
        const name = line[0..colon];
        if (!isToken(name)) return error.BadRequest;
        const value = trim(line[colon + 1 ..]);
        for (value) |c| if (!byte_class.value[c]) return error.BadRequest;
        if (trailer) {
            // Trailers are never merged into header lookup or acted upon. Reject
            // common forbidden fields explicitly; unknown valid fields are ignored.
            for ([_][]const u8{ "content-length", "transfer-encoding", "host", "connection", "trailer", "expect", "upgrade", "authorization", "proxy-authorization", "content-encoding", "content-type", "content-range" }) |forbidden| {
                if (equalCase(name, forbidden)) return error.BadRequest;
            }
            return;
        }
        if (equalCase(name, "host")) {
            if (self.host_seen) return error.BadRequest;
            try validateAuthority(value, false);
            self.host_seen = true;
        } else if (equalCase(name, "content-length")) {
            if (self.content_length != null or self.chunked) return error.BadRequest;
            const length = try decimalLength(value, self.limits.max_body_bytes);
            self.content_length = length;
        } else if (equalCase(name, "transfer-encoding")) {
            if (self.chunked or self.content_length != null) return error.BadRequest;
            try transferEncoding(value);
            self.chunked = true;
        } else if (equalCase(name, "connection")) {
            var values = std.mem.splitScalar(u8, value, ',');
            while (values.next()) |raw| {
                const option = trim(raw);
                // RFC 9110 list recipients ignore a reasonable number of empty
                // elements; total elements/work are bounded by the header budget.
                if (option.len == 0) continue;
                if (!isToken(option)) return error.BadRequest;
                if (equalCase(option, "close")) self.keep_alive = false;
            }
        } else if (equalCase(name, "expect")) {
            var values = std.mem.splitScalar(u8, value, ',');
            var found = false;
            while (values.next()) |raw| {
                const expectation = trim(raw);
                if (expectation.len == 0) continue;
                if (!equalCase(expectation, "100-continue")) return error.ExpectationFailed;
                found = true;
            }
            if (!found) return error.ExpectationFailed;
            self.expect_continue = true;
        }
    }

    fn finishHead(self: *Parser) ParseError!void {
        if (!self.host_seen) return error.BadRequest;
        self.headers_end = self.scan;
        assert(self.headers_end <= self.limits.max_wire_bytes);
        if (self.chunked) {
            self.state = .chunk_size;
        } else {
            self.body_bytes = self.content_length orelse 0;
            if (self.body_bytes > self.limits.max_wire_bytes - self.headers_end) return error.BodyTooLarge;
            self.consumed = self.headers_end + self.body_bytes;
            if (self.body_bytes == 0) self.expect_continue = false;
            self.state = .fixed_body;
        }
        // Do not expose an interim-100 decision before all initial framing,
        // authority, expectation and known body-size checks have succeeded.
        self.head_complete = true;
    }

    fn request(self: *const Parser, bytes: []const u8) Request {
        assert(self.head_complete);
        assert(self.fields_start <= self.headers_end - 2);
        assert(self.headers_end <= self.consumed);
        assert(self.consumed <= bytes.len);
        assert(self.body_bytes <= self.limits.max_body_bytes);
        return .{
            .method = bytes[0..self.method_end],
            .target = bytes[self.target_start..self.target_end],
            .headers = bytes[self.fields_start .. self.headers_end - 2],
            .body_wire = bytes[self.headers_end..self.consumed],
            .chunked = self.chunked,
            .body_bytes = self.body_bytes,
            .consumed = self.consumed,
            .keep_alive = self.keep_alive,
            .expect_continue = self.expect_continue,
            .head_only = self.head_only,
        };
    }
};

fn trim(bytes: []const u8) []const u8 {
    var start: usize = 0;
    var end = bytes.len;
    while (start < end and (bytes[start] == ' ' or bytes[start] == '\t')) start += 1;
    while (end > start and (bytes[end - 1] == ' ' or bytes[end - 1] == '\t')) end -= 1;
    return bytes[start..end];
}

fn tokenByteSlow(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or switch (c) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

/// One table load per byte replaces the branch chains on the request path. The
/// slow classifiers remain the definition; a test checks every byte agrees.
const ByteClass = struct {
    token: [256]bool,
    /// RFC 3986 pchar/query octets except '%', which needs two hex digits.
    path: [256]bool,
    /// reg-name octets except '%': unreserved and sub-delims.
    host: [256]bool,
    /// Field value octets: visible ASCII, HTAB, SP and obs-text.
    value: [256]bool,
    fn init() ByteClass {
        @setEvalBranchQuota(20_000);
        var class: ByteClass = .{ .token = undefined, .path = undefined, .host = undefined, .value = undefined };
        for (0..256) |index| {
            const c: u8 = @intCast(index);
            class.token[index] = tokenByteSlow(c);
            class.path[index] = unreserved(c) or subDelimiter(c) or c == ':' or c == '@' or c == '/' or c == '?';
            class.host[index] = unreserved(c) or subDelimiter(c);
            class.value[index] = !((c < 0x20 and c != '\t') or c == 0x7f);
        }
        return class;
    }
};
const byte_class = ByteClass.init();

const Lane = @Vector(16, u8);

/// Index of the first CR or LF at or after `start`; one 16-byte lane per step.
fn findLineControl(bytes: []const u8, start: usize) ?usize {
    assert(start <= bytes.len);
    var at = start;
    const cr: Lane = @splat('\r');
    const lf: Lane = @splat('\n');
    while (at + 16 <= bytes.len) : (at += 16) {
        const lane: Lane = bytes[at..][0..16].*;
        const hits: u16 = @bitCast((lane == cr) | (lane == lf));
        if (hits != 0) return at + @ctz(hits);
    }
    while (at < bytes.len) : (at += 1) {
        if (bytes[at] == '\r' or bytes[at] == '\n') return at;
    }
    return null;
}

/// Index of the first `needle` in `bytes`; short header lines fit a few lanes.
fn findByte(bytes: []const u8, needle: u8) ?usize {
    var at: usize = 0;
    const wanted: Lane = @splat(needle);
    while (at + 16 <= bytes.len) : (at += 16) {
        const lane: Lane = bytes[at..][0..16].*;
        const hits: u16 = @bitCast(lane == wanted);
        if (hits != 0) return at + @ctz(hits);
    }
    while (at < bytes.len) : (at += 1) {
        if (bytes[at] == needle) return at;
    }
    return null;
}

fn tokenByte(c: u8) bool {
    return byte_class.token[c];
}

fn isToken(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |c| if (!tokenByte(c)) return false;
    return true;
}

fn decimalLength(bytes: []const u8, maximum: u32) ParseError!u32 {
    if (bytes.len == 0) return error.BadRequest;
    var value: u32 = 0;
    for (bytes) |c| {
        if (!std.ascii.isDigit(c)) return error.BadRequest;
        const digit: u32 = c - '0';
        if (digit > maximum or value > (maximum - digit) / 10) return error.BodyTooLarge;
        value = value * 10 + digit;
    }
    return value;
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn chunkSize(line: []const u8, maximum: u32) ParseError!usize {
    var at: usize = 0;
    var value: u32 = 0;
    while (at < line.len) : (at += 1) {
        const digit: u32 = hexDigit(line[at]) orelse break;
        if (digit > maximum or value > (maximum - digit) / 16) return error.BodyTooLarge;
        value = value * 16 + digit;
    }
    if (at == 0) return error.BadRequest;
    try validateChunkExtensions(line[at..]);
    return value;
}

fn validateChunkExtensions(bytes: []const u8) ParseError!void {
    var at: usize = 0;
    while (at < bytes.len) {
        // RFC 9112 chunk-ext = *( BWS ";" BWS name [ BWS "=" BWS value ] ).
        while (at < bytes.len and (bytes[at] == ' ' or bytes[at] == '\t')) : (at += 1) {}
        if (at == bytes.len or bytes[at] != ';') return error.BadRequest;
        at += 1;
        while (at < bytes.len and (bytes[at] == ' ' or bytes[at] == '\t')) : (at += 1) {}
        const name_start = at;
        while (at < bytes.len and tokenByte(bytes[at])) : (at += 1) {}
        if (at == name_start) return error.BadRequest;
        const after_name = at;
        while (at < bytes.len and (bytes[at] == ' ' or bytes[at] == '\t')) : (at += 1) {}
        if (at == bytes.len or bytes[at] != '=') {
            // Whitespace belongs to the next extension's BWS, if present.
            at = after_name;
            continue;
        }
        at += 1;
        while (at < bytes.len and (bytes[at] == ' ' or bytes[at] == '\t')) : (at += 1) {}
        if (at == bytes.len) return error.BadRequest;
        if (bytes[at] == '"') {
            at += 1;
            var closed = false;
            while (at < bytes.len) {
                const c = bytes[at];
                at += 1;
                if (c == '"') {
                    closed = true;
                    break;
                }
                if (c == '\\') {
                    if (at == bytes.len) return error.BadRequest;
                    const escaped = bytes[at];
                    if ((escaped < 0x20 and escaped != '\t') or escaped == 0x7f) return error.BadRequest;
                    at += 1;
                } else if ((c < 0x20 and c != '\t') or c == 0x7f) return error.BadRequest;
            }
            if (!closed) return error.BadRequest;
        } else {
            const value_start = at;
            while (at < bytes.len and tokenByte(bytes[at])) : (at += 1) {}
            if (at == value_start) return error.BadRequest;
        }
    }
}

/// Only a final, unparameterized chunked coding delimits requests. Unsupported
/// earlier codings get 501; a non-chunked final coding is malformed framing and
/// gets 400 (RFC 9112 section 6.3), even if the coding itself is recognized.
fn transferEncoding(bytes: []const u8) ParseError!void {
    var at: usize = 0;
    var chunked_seen = false;
    var unsupported = false;
    while (at < bytes.len) {
        while (at < bytes.len and (bytes[at] == ' ' or bytes[at] == '\t' or bytes[at] == ',')) : (at += 1) {}
        if (at == bytes.len) break;
        if (chunked_seen) return error.BadRequest;
        const name_start = at;
        while (at < bytes.len and tokenByte(bytes[at])) : (at += 1) {}
        if (at == name_start) return error.BadRequest;
        const is_chunked = equalCase(bytes[name_start..at], "chunked");
        while (true) {
            while (at < bytes.len and (bytes[at] == ' ' or bytes[at] == '\t')) : (at += 1) {}
            if (at == bytes.len or bytes[at] == ',') break;
            if (bytes[at] != ';' or is_chunked) return error.BadRequest;
            at += 1;
            while (at < bytes.len and (bytes[at] == ' ' or bytes[at] == '\t')) : (at += 1) {}
            const parameter_start = at;
            while (at < bytes.len and tokenByte(bytes[at])) : (at += 1) {}
            if (at == parameter_start) return error.BadRequest;
            while (at < bytes.len and (bytes[at] == ' ' or bytes[at] == '\t')) : (at += 1) {}
            if (at == bytes.len or bytes[at] != '=') return error.BadRequest;
            at += 1;
            while (at < bytes.len and (bytes[at] == ' ' or bytes[at] == '\t')) : (at += 1) {}
            if (at == bytes.len) return error.BadRequest;
            if (bytes[at] == '"') {
                at += 1;
                var closed = false;
                while (at < bytes.len) {
                    const c = bytes[at];
                    at += 1;
                    if (c == '"') {
                        closed = true;
                        break;
                    }
                    if (c == '\\') {
                        if (at == bytes.len) return error.BadRequest;
                        const escaped = bytes[at];
                        if ((escaped < 0x20 and escaped != '\t') or escaped == 0x7f) return error.BadRequest;
                        at += 1;
                    } else if ((c < 0x20 and c != '\t') or c == 0x7f) return error.BadRequest;
                }
                if (!closed) return error.BadRequest;
            } else {
                const value_start = at;
                while (at < bytes.len and tokenByte(bytes[at])) : (at += 1) {}
                if (at == value_start) return error.BadRequest;
            }
        }
        if (is_chunked) chunked_seen = true else unsupported = true;
    }
    if (!chunked_seen) return error.BadRequest;
    if (unsupported) return error.UnsupportedTransferEncoding;
}

fn unreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or switch (c) {
        '-', '.', '_', '~' => true,
        else => false,
    };
}

fn subDelimiter(c: u8) bool {
    return switch (c) {
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=' => true,
        else => false,
    };
}

/// Validate path/query octets without decoding percent escapes or normalizing.
fn validatePath(bytes: []const u8) ParseError!void {
    var at: usize = 0;
    while (at < bytes.len) : (at += 1) {
        const c = bytes[at];
        if (byte_class.path[c]) continue;
        if (c == '%' and bytes.len - at >= 3 and hexDigit(bytes[at + 1]) != null and hexDigit(bytes[at + 2]) != null) {
            at += 2;
            continue;
        }
        return error.BadRequest;
    }
}

fn validateTarget(method: []const u8, target: []const u8) ParseError!void {
    if (target.len == 0) return error.BadRequest;
    if (equal(u8, method, "CONNECT")) return validateAuthority(target, true);
    if (equal(u8, target, "*")) {
        if (!equal(u8, method, "OPTIONS")) return error.BadRequest;
        return;
    }
    if (target[0] == '/') return validatePath(target);
    const authority_start: usize = if (target.len >= 7 and equalCase(target[0..7], "http://")) 7 else if (target.len >= 8 and equalCase(target[0..8], "https://")) 8 else return error.BadRequest;
    var authority_end = authority_start;
    while (authority_end < target.len and target[authority_end] != '/' and target[authority_end] != '?') : (authority_end += 1) {}
    try validateAuthority(target[authority_start..authority_end], false);
    try validatePath(target[authority_end..]);
}

/// Strict HTTP authority: nonempty reg-name or IPv6/IPvFuture literal, optional
/// decimal port. No userinfo or scoped IPv6. This never resolves a hostname.
fn validateAuthority(bytes: []const u8, require_port: bool) ParseError!void {
    if (bytes.len == 0) return error.BadRequest;
    var host_end: usize = 0;
    if (bytes[0] == '[') {
        const close = std.mem.findScalar(u8, bytes, ']') orelse return error.BadRequest;
        if (close <= 1) return error.BadRequest;
        const literal = bytes[1..close];
        if (literal[0] == 'v' or literal[0] == 'V') {
            const dot = std.mem.findScalar(u8, literal, '.') orelse return error.BadRequest;
            if (dot <= 1 or dot + 1 == literal.len) return error.BadRequest;
            for (literal[1..dot]) |c| if (hexDigit(c) == null) return error.BadRequest;
            for (literal[dot + 1 ..]) |c| if (!unreserved(c) and !subDelimiter(c) and c != ':') return error.BadRequest;
        } else {
            _ = std.Io.net.Ip6Address.parse(literal, 0) catch return error.BadRequest;
        }
        host_end = close + 1;
    } else {
        while (host_end < bytes.len and bytes[host_end] != ':') : (host_end += 1) {
            const c = bytes[host_end];
            if (byte_class.host[c]) continue;
            if (c == '%' and bytes.len - host_end >= 3 and hexDigit(bytes[host_end + 1]) != null and hexDigit(bytes[host_end + 2]) != null) {
                host_end += 2;
                continue;
            }
            return error.BadRequest;
        }
        if (host_end == 0) return error.BadRequest;
    }
    if (host_end == bytes.len) {
        if (require_port) return error.BadRequest;
        return;
    }
    if (bytes[host_end] != ':') return error.BadRequest;
    const port = bytes[host_end + 1 ..];
    // Empty ports are syntactically valid in an HTTP URI/Host; CONNECT requires
    // an explicit nonempty destination port. Numeric ports are policy-bounded.
    if (require_port and port.len == 0) return error.BadRequest;
    var value: u32 = 0;
    for (port) |c| {
        if (!std.ascii.isDigit(c)) return error.BadRequest;
        const digit: u32 = c - '0';
        if (value > (std.math.maxInt(u16) - digit) / 10) return error.BadRequest;
        value = value * 10 + digit;
    }
}

const testing = std.testing;

fn parseComplete(bytes: []const u8) !Request {
    var parser = Parser.init(.{});
    return (try parser.parse(bytes)) orelse error.TestUnexpectedResult;
}

test "incremental fixed body at every prefix, lazy headers and borrowed payload" {
    const wire = "POST /echo?q=%2f HTTP/1.1\r\nHost: example.test\r\nContent-Length: 5\r\nX-Custom:\t first \t\r\nX-Custom: second\r\n\r\nhello";
    var parser = Parser.init(.{});
    for (0..wire.len) |length| {
        try testing.expectEqual(null, try parser.parse(wire[0..length]));
        try testing.expect(parser.scan <= length);
    }
    const request = (try parser.parse(wire)).?;
    try testing.expectEqualStrings("POST", request.method);
    try testing.expectEqualStrings("/echo?q=%2f", request.target);
    try testing.expectEqualStrings("first", request.header("x-CUSTOM").?);
    try testing.expectEqual(null, request.header("absent"));
    try testing.expectEqual(@as(usize, 5), request.body_bytes);
    try testing.expectEqual(wire.len, request.consumed);
    try testing.expect(request.keep_alive);
    try testing.expect(!request.chunked);
    var body = request.body();
    const span = body.next().?;
    try testing.expectEqualStrings("hello", span);
    try testing.expectEqual(wire.ptr + wire.len - 5, span.ptr);
    try testing.expectEqual(null, body.next());
    try testing.expectEqual(request.consumed, (try parser.parse(wire)).?.consumed);
}

test "every split of chunked request, extensions, trailers and borrowed spans" {
    const wire = "POST /echo HTTP/1.1\r\nHost: [::1]:8080\r\nTransfer-Encoding: Chunked\r\n\r\n" ++
        "3; name = \"x\\\"y\";flag\r\nabc\r\n2 ;q=ok\r\nde\r\n0;done\r\nDigest: ignored\r\n\r\n";
    for (0..wire.len + 1) |split| {
        var parser = Parser.init(.{});
        const partial = try parser.parse(wire[0..split]);
        if (split != wire.len) try testing.expectEqual(null, partial);
        const request = (try parser.parse(wire)).?;
        try testing.expectEqual(wire.len, request.consumed);
        try testing.expectEqual(@as(usize, 5), request.body_bytes);
        try testing.expect(request.chunked);
        try testing.expectEqual(null, request.header("Digest"));
        var body = request.body();
        const one = body.next().?;
        const two = body.next().?;
        try testing.expectEqualStrings("abc", one);
        try testing.expectEqualStrings("de", two);
        try testing.expect(@intFromPtr(one.ptr) >= @intFromPtr(wire.ptr) and @intFromPtr(two.ptr) < @intFromPtr(wire.ptr) + wire.len);
        try testing.expectEqual(null, body.next());
    }
    var parser = Parser.init(.{});
    for (0..wire.len) |length| try testing.expectEqual(null, try parser.parse(wire[0..length]));
    try testing.expectEqual(@as(usize, 5), (try parser.parse(wire)).?.body_bytes);
}

test "Expect is exposed after validated headers, no-body expectation ignored" {
    const wire = "POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 2\r\n\r\nab";
    var parser = Parser.init(.{});
    try testing.expectEqual(null, try parser.parse(wire[0 .. wire.len - 3]));
    try testing.expect(!parser.head_complete);
    try testing.expectEqual(null, try parser.parse(wire[0 .. wire.len - 2]));
    try testing.expect(parser.head_complete and parser.expect_continue);
    try testing.expectEqual(wire.len - 2, parser.headers_end);
    try testing.expect((try parser.parse(wire)).?.expect_continue);
    const empty = try parseComplete("GET / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\n\r\n");
    try testing.expect(!empty.expect_continue);
}

test "pipelined suffix does not count against preceding request limits" {
    const first = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";
    const second = "HEAD /next HTTP/1.1\r\nHost: x\r\nConnection: keep-alive, CLOSE\r\n\r\n";
    const bytes = first ++ second;
    var parser = Parser.init(.{ .max_wire_bytes = first.len });
    try testing.expectEqual(first.len, (try parser.parse(bytes)).?.consumed);
    parser = Parser.init(.{});
    const next = (try parser.parse(bytes[first.len..])).?;
    try testing.expect(next.head_only and !next.keep_alive);
    try testing.expectEqualStrings("/next", next.target);
    parser.reset();
    try testing.expect(!parser.head_complete and parser.scan == 0);
    try testing.expectEqual(first.len, (try parser.parse(first)).?.consumed);
}

test "strict malformed header and framing rejection never exposes a request" {
    const bad = [_][]const u8{
        "GET / HTTP/1.1\r\n\r\n",
        "GET / HTTP/1.1\r\nHost:\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x\r\nHost: x\r\n\r\n",
        "GET / HTTP/1.1\r\nHost : x\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x\r\n folded: no\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x\r\nX: a\x00b\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x\r\nX: a\x7fb\r\n\r\n",
        "GET / HTTP/1.1\nHost: x\n\n",
        "GET / HTTP/1.1\rHost: x\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: +1\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0, 0\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x\r\nConnection: cl ose\r\n\r\n",
        "G@T / HTTP/1.1\r\nHost: x\r\n\r\n",
        "GET  / HTTP/1.1\r\nHost: x\r\n\r\n",
        "GET / HTTP/1.1 extra\r\nHost: x\r\n\r\n",
    };
    for (bad) |wire| {
        var parser = Parser.init(.{});
        try testing.expectError(error.BadRequest, parser.parse(wire));
        try testing.expectError(error.BadRequest, parser.parse(wire));
    }
}

test "byte class tables agree with the slow classifiers for every octet" {
    for (0..256) |index| {
        const c: u8 = @intCast(index);
        try testing.expectEqual(tokenByteSlow(c), tokenByte(c));
        try testing.expectEqual(unreserved(c) or subDelimiter(c) or c == ':' or c == '@' or c == '/' or c == '?', byte_class.path[c]);
    }
}

test "vectorised line scanning rejects bare CR/LF at every fragment boundary" {
    // Every CR position and every split must produce the same verdict as the
    // whole-buffer parse, and a CR must never be rescanned into acceptance.
    const good = "GET /a HTTP/1.1\r\nHost: x\r\nX-Long: abcdefghijklmnopqrstuvwxyz\r\n\r\n";
    var wire: [good.len]u8 = undefined;
    for (0..good.len) |position| {
        for ([_]u8{ '\r', '\n' }) |octet| {
            @memcpy(&wire, good);
            wire[position] = octet;
            var whole = Parser.init(.{});
            const expected = whole.parse(&wire);
            for (0..wire.len + 1) |split| {
                var parser = Parser.init(.{});
                const first = parser.parse(wire[0..split]) catch |err| {
                    try testing.expectError(err, expected);
                    continue;
                };
                if (first != null) {
                    try testing.expect((try expected) != null);
                    continue;
                }
                const second = parser.parse(&wire) catch |err| {
                    try testing.expectError(err, expected);
                    continue;
                };
                try testing.expectEqual((try expected) != null, second != null);
                if (second) |request| try testing.expectEqual(good.len, request.consumed);
            }
        }
    }
}

test "supported target forms and raw extension methods" {
    const requests = [_][]const u8{
        "GET http://example.test:80/a?b=%20 HTTP/1.1\r\nHost: ignored.example\r\n\r\n",
        "GET HTTPS://[2001:db8::1]/ HTTP/1.1\r\nHost: example.test\r\n\r\n",
        "GET http://example.test?query HTTP/1.1\r\nHost: example.test\r\n\r\n",
        "GET http://example.test HTTP/1.1\r\nHost: example.test:\r\n\r\n",
        "OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n",
        "CONNECT example.test:443 HTTP/1.1\r\nHost: example.test:443\r\n\r\n",
        "CONNECT [::1]:443 HTTP/1.1\r\nHost: [::1]:443\r\n\r\n",
        "CUSTOM /x HTTP/1.1\r\nHost: [v1.a:b]\r\n\r\n",
    };
    for (requests) |wire| {
        const request = try parseComplete(wire);
        try testing.expectEqual(wire.len, request.consumed);
    }
    const malformed = [_][]const u8{
        "GET * HTTP/1.1\r\nHost: x\r\n\r\n",
        "CONNECT / HTTP/1.1\r\nHost: x\r\n\r\n",
        "CONNECT x HTTP/1.1\r\nHost: x\r\n\r\n",
        "GET /bad%Q0 HTTP/1.1\r\nHost: x\r\n\r\n",
        "GET /bad% HTTP/1.1\r\nHost: x\r\n\r\n",
        "GET /fragment#bad HTTP/1.1\r\nHost: x\r\n\r\n",
        "GET /\xff HTTP/1.1\r\nHost: x\r\n\r\n",
        "GET http://user@x/ HTTP/1.1\r\nHost: x\r\n\r\n",
        "GET http:///x HTTP/1.1\r\nHost: x\r\n\r\n",
        "GET http://x/#frag HTTP/1.1\r\nHost: x\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a b\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: [bad]\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: [::1]x\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x:65536\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x:1:2\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x@y\r\n\r\n",
    };
    for (malformed) |wire| {
        var parser = Parser.init(.{});
        try testing.expectError(error.BadRequest, parser.parse(wire));
    }
}

test "chunk syntax, discarded trailer safety and unsupported semantics" {
    const head = "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n";
    const bad_bodies = [_][]const u8{
        "\r\n", "g\r\n", "1x\r\na\r\n0\r\n\r\n", "-1\r\n", "1;\r\na\r\n0\r\n\r\n", "1;foo=\r\na\r\n0\r\n\r\n", "1;foo=\"unterminated\r\n", "1\r\naX\n0\r\n\r\n", "0\r\nHost: x\r\n\r\n", "0\r\nContent-Length: 3\r\n\r\n", "0\r\n folded: x\r\n\r\n", "0\r\nBad\r\n\r\n", "0 \r\n\r\n",
    };
    inline for (bad_bodies) |body| {
        var parser = Parser.init(.{});
        try testing.expectError(error.BadRequest, parser.parse(head ++ body));
    }
    const unknown = "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, chunked\r\n\r\n";
    var parser = Parser.init(.{});
    try testing.expectError(error.UnsupportedTransferEncoding, parser.parse(unknown));
    parser.reset();
    try testing.expectError(error.ExpectationFailed, parser.parse("GET / HTTP/1.1\r\nHost: x\r\nExpect: something-else\r\n\r\n"));
    parser.reset();
    try testing.expectError(error.UnsupportedVersion, parser.parse("GET / HTTP/1.0\r\nHost: x\r\n\r\n"));
}

test "exact header, field-count, target, body and wire limits" {
    const head = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\n";
    var parser = Parser.init(.{ .max_header_bytes = head.len, .max_header_count = 2, .max_body_bytes = 3, .max_wire_bytes = head.len + 3, .max_target_bytes = 1 });
    try testing.expectEqual(@as(usize, 3), (try parser.parse(head ++ "abc")).?.body_bytes);
    parser = Parser.init(.{ .max_header_bytes = head.len - 1 });
    try testing.expectError(error.HeadersTooLarge, parser.parse(head));
    parser = Parser.init(.{ .max_header_count = 1 });
    try testing.expectError(error.HeadersTooLarge, parser.parse(head));
    parser = Parser.init(.{ .max_body_bytes = 2 });
    try testing.expectError(error.BodyTooLarge, parser.parse(head));
    try testing.expect(!parser.head_complete);
    parser = Parser.init(.{ .max_wire_bytes = head.len + 2 });
    try testing.expectError(error.BodyTooLarge, parser.parse(head));
    parser = Parser.init(.{ .max_target_bytes = 0 });
    try testing.expectError(error.TargetTooLong, parser.parse(head));
    parser = Parser.init(.{});
    try testing.expectError(error.BodyTooLarge, parser.parse("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 18446744073709551616\r\n\r\n"));
}

test "chunk limits count logical body, total framing and trailers independently" {
    const head = "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n";
    const body = "1\r\na\r\n1\r\nb\r\n0\r\nX: y\r\n\r\n";
    var parser = Parser.init(.{ .max_body_bytes = 2, .max_header_bytes = head.len + 8, .max_header_count = 3, .max_wire_bytes = head.len + body.len });
    try testing.expectEqual(@as(usize, 2), (try parser.parse(head ++ body)).?.body_bytes);
    parser = Parser.init(.{ .max_body_bytes = 1 });
    try testing.expectError(error.BodyTooLarge, parser.parse(head ++ body));
    parser = Parser.init(.{ .max_wire_bytes = head.len + body.len - 1 });
    try testing.expectError(error.BodyTooLarge, parser.parse(head ++ body));
    parser = Parser.init(.{ .max_header_bytes = head.len + 7 });
    try testing.expectError(error.HeadersTooLarge, parser.parse(head ++ body));
    parser = Parser.init(.{ .max_header_count = 2 });
    try testing.expectError(error.HeadersTooLarge, parser.parse(head ++ body));
    parser = Parser.init(.{});
    try testing.expectError(error.BodyTooLarge, parser.parse(head ++ "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF\r\n"));
    parser = Parser.init(.{ .max_body_bytes = 0 });
    try testing.expectEqual(@as(usize, 0), (try parser.parse(head ++ "0\r\n\r\n")).?.body_bytes);
}

test "all octets in header values are either safely borrowed or rejected" {
    const prefix = "GET / HTTP/1.1\r\nHost: x\r\nX: a";
    const suffix = "b\r\n\r\n";
    var wire: [prefix.len + 1 + suffix.len]u8 = undefined;
    @memcpy(wire[0..prefix.len], prefix);
    @memcpy(wire[prefix.len + 1 ..], suffix);
    for (0..256) |number| {
        const byte: u8 = @intCast(number);
        wire[prefix.len] = byte;
        var parser = Parser.init(.{});
        if ((byte < 0x20 and byte != '\t') or byte == 0x7f) {
            try testing.expectError(error.BadRequest, parser.parse(&wire));
        } else {
            const request = (try parser.parse(&wire)).?;
            try testing.expectEqual(byte, request.header("x").?[1]);
        }
    }
}

test "transfer coding order and parameters distinguish invalid from unsupported" {
    const prefix = "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: ";
    const bad = [_][]const u8{ "", "gzip", "chunked, gzip", "chunked, chunked", "chunked;foo=bar", "gzip;foo, chunked", "gzip;foo=\"unterminated, chunked", "@, chunked" };
    inline for (bad) |coding| {
        var parser = Parser.init(.{});
        try testing.expectError(error.BadRequest, parser.parse(prefix ++ coding ++ "\r\n\r\n"));
    }
    const unknown = [_][]const u8{ "gzip, chunked", "custom; level=2, chunked", "custom; value=\"a,b\", chunked" };
    inline for (unknown) |coding| {
        var parser = Parser.init(.{});
        try testing.expectError(error.UnsupportedTransferEncoding, parser.parse(prefix ++ coding ++ "\r\n\r\n"));
    }
    var parser = Parser.init(.{});
    try testing.expectEqual(@as(usize, 0), (try parser.parse(prefix ++ ", Chunked,,\r\n\r\n0\r\n\r\n")).?.body_bytes);
}

test "chunk extension line budget bounds incremental scanning" {
    const head = "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n";
    const wire = head ++ "1;" ++ "a" ** 64 ++ "=x\r\na\r\n0\r\n\r\n";
    var parser = Parser.init(.{ .max_header_bytes = 64 });
    for (0..head.len + 64) |length| try testing.expectEqual(null, try parser.parse(wire[0..length]));
    try testing.expectError(error.BodyTooLarge, parser.parse(wire[0 .. head.len + 64]));
    try testing.expectEqual(head.len + 64, parser.scan);
}

test "deterministic hostile octet mutations preserve parser safety under fragmentation" {
    const good = "POST http://[::1]:80/x?q=%20 HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n1;a=\"b\"\r\nz\r\n0\r\nX: y\r\n\r\n";
    var wire: [good.len]u8 = undefined;
    for (0..good.len) |position| {
        @memcpy(&wire, good);
        for (0..256) |number| {
            wire[position] = @intCast(number);
            var parser = Parser.init(.{});
            // The first split lands directly before the mutated octet. Accepted
            // mutations still have to preserve in-buffer slices and body bounds.
            _ = parser.parse(wire[0..position]) catch continue;
            const request = (parser.parse(&wire) catch continue) orelse continue;
            try testing.expect(request.consumed <= wire.len);
            try testing.expect(request.body_bytes <= parser.limits.max_body_bytes);
            var body = request.body();
            var observed: usize = 0;
            while (body.next()) |span| {
                try testing.expect(@intFromPtr(span.ptr) >= @intFromPtr(&wire));
                try testing.expect(@intFromPtr(span.ptr) + span.len <= @intFromPtr(&wire) + wire.len);
                observed += span.len;
            }
            try testing.expectEqual(request.body_bytes, observed);
        }
    }
}
