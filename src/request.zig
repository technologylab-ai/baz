//! Public immutable request conveniences over the core's validated request.
//! Every raw view retains the core borrow; caller-buffer results retain only
//! their destination. No operation here allocates or initiates service/socket I/O.
const std = @import("std");
pub const http = @import("bounded_http").api.http;
pub const params = @import("params.zig");
pub const form = @import("form.zig");
pub const multipart = @import("multipart.zig");
const cookie_codec = @import("cookies.zig");

pub const ContentError = form.MetadataError || error{
    MissingContentType,
    AmbiguousContentType,
    UnsupportedMediaType,
    UnsupportedContentEncoding,
};
pub const FormError = ContentError || params.Error || error{BodyNotContiguous};
pub const MultipartError = ContentError || multipart.Error || form.UnquoteError || error{ BodyNotContiguous, MissingBoundary };
pub const CopyError = error{ NoSpaceLeft, OverlappingBuffers };

pub const Target = struct {
    pub const Kind = enum { origin, absolute, authority, asterisk };
    kind: Kind,
    raw: []const u8,
    /// Null for authority/asterisk forms. An empty absolute path remains empty;
    /// a router can explicitly apply '/', without claiming it occurred on wire.
    path: ?[]const u8,
    query_raw: ?[]const u8,
    authority: ?[]const u8,
};

pub const Request = struct {
    raw: *const http.Request,

    /// Only a successfully parsed core Request may be wrapped. Keep input
    /// immutable and retain this pointer only through the active request.
    pub fn init(request: *const http.Request) Request {
        return .{ .raw = request };
    }

    pub fn method(self: Request) []const u8 {
        return self.raw.method;
    }

    pub fn target(self: Request) Target {
        const raw = self.raw.target;
        if (std.mem.eql(u8, self.raw.method, "CONNECT"))
            return .{ .kind = .authority, .raw = raw, .path = null, .query_raw = null, .authority = raw };
        if (std.mem.eql(u8, raw, "*"))
            return .{ .kind = .asterisk, .raw = raw, .path = null, .query_raw = null, .authority = null };
        var path_start: usize = 0;
        var authority: ?[]const u8 = null;
        const kind: Target.Kind = if (raw[0] == '/') .origin else .absolute;
        if (kind == .absolute) {
            const authority_start = (std.mem.find(u8, raw, "://") orelse unreachable) + 3;
            path_start = authority_start;
            while (path_start < raw.len and raw[path_start] != '/' and raw[path_start] != '?') : (path_start += 1) {}
            authority = raw[authority_start..path_start];
        }
        const query_at = std.mem.findScalarPos(u8, raw, path_start, '?');
        return .{
            .kind = kind,
            .raw = raw,
            .path = raw[path_start .. query_at orelse raw.len],
            .query_raw = if (query_at) |at| raw[at + 1 ..] else null,
            .authority = authority,
        };
    }

    pub fn path(self: Request) ?[]const u8 {
        return self.target().path;
    }

    pub fn query(self: Request) params.Error!params.Params {
        return self.queryWithLimits(.{});
    }

    pub fn queryWithLimits(self: Request, limits: params.Limits) params.Error!params.Params {
        return params.parse(self.target().query_raw orelse "", limits);
    }

    /// First matching value, case-insensitive header name, no value conversion.
    pub fn header(self: Request, name: []const u8) ?[]const u8 {
        return self.raw.header(name);
    }

    pub fn headers(self: Request) HeaderIterator {
        return .{ .raw = self.raw.headers };
    }

    /// Borrow validated pairs across every Cookie field, without decoding.
    pub fn cookies(self: Request) cookie_codec.Error!cookie_codec.Cookies {
        return self.cookiesWithLimits(.{});
    }

    pub fn cookiesWithLimits(self: Request, limits: cookie_codec.Limits) cookie_codec.Error!cookie_codec.Cookies {
        return cookie_codec.parseHeaders(self.raw.headers, limits);
    }

    /// Exact name match. Reject ambiguity instead of choosing a session token.
    pub fn cookie(self: Request, name: []const u8) (cookie_codec.Error || error{DuplicateCookie})!?[]const u8 {
        return (try self.cookies()).uniqueRaw(name);
    }

    pub fn body(self: Request) Body {
        return .{ .raw = self.raw };
    }

    /// Checks media type/encoding before reporting BodyNotContiguous. A caller
    /// handling that error may then copy body bytes and call form.parse directly.
    pub fn formUrlEncoded(self: Request, limits: params.Limits) FormError!params.Params {
        _ = try self.expectMediaType("application/x-www-form-urlencoded");
        if (self.raw.body_bytes > limits.max_bytes) return error.ParamsTooLarge;
        const bytes = self.body().contiguous() orelse return error.BodyNotContiguous;
        return form.parse(bytes, limits);
    }

    /// Validates Content-Type and returns the decoded, validated boundary in
    /// caller storage. Input errors and capacity errors leave destination intact.
    pub fn multipartBoundaryInto(self: Request, destination: []u8) MultipartError![]u8 {
        const media = try self.expectMediaType("multipart/form-data");
        const boundary = media.parameter("boundary") orelse return error.MissingBoundary;
        var scratch: [multipart.max_boundary_bytes]u8 = undefined;
        const decoded = form.unquoteInto(boundary.value_raw, &scratch) catch |err| switch (err) {
            error.NoSpaceLeft => return error.InvalidBoundary,
            else => return err,
        };
        try multipart.validateBoundary(decoded);
        if (destination.len < decoded.len) return error.NoSpaceLeft;
        const request_bytes = self.raw.method.ptr[0..self.raw.consumed];
        if (params.overlap(request_bytes, destination)) return error.OverlappingBuffers;
        @memcpy(destination[0..decoded.len], decoded);
        return destination[0..decoded.len];
    }

    pub fn formMultipart(self: Request, limits: multipart.Limits) MultipartError!multipart.Multipart {
        var boundary: [multipart.max_boundary_bytes]u8 = undefined;
        const decoded = try self.multipartBoundaryInto(&boundary);
        if (self.raw.body_bytes > limits.max_bytes) return error.MultipartTooLarge;
        const bytes = self.body().contiguous() orelse return error.BodyNotContiguous;
        return multipart.parse(bytes, decoded, limits);
    }

    fn expectMediaType(self: Request, expected: []const u8) ContentError!form.Metadata {
        var content_type: ?[]const u8 = null;
        var encoding_seen = false;
        var it = self.headers();
        while (it.next()) |field| {
            if (std.ascii.eqlIgnoreCase(field.name_raw, "content-type")) {
                if (content_type != null) return error.AmbiguousContentType;
                content_type = field.value_raw;
            } else if (std.ascii.eqlIgnoreCase(field.name_raw, "content-encoding")) {
                if (encoding_seen or !std.ascii.eqlIgnoreCase(field.value_raw, "identity")) return error.UnsupportedContentEncoding;
                encoding_seen = true;
            }
        }
        const media = try form.mediaType(content_type orelse return error.MissingContentType, .{});
        if (!media.is(expected)) return error.UnsupportedMediaType;
        return media;
    }
};

pub const Header = struct { name_raw: []const u8, value_raw: []const u8 };
pub const HeaderIterator = struct {
    raw: []const u8,
    offset: usize = 0,

    pub fn next(self: *HeaderIterator) ?Header {
        if (self.offset == self.raw.len) return null;
        const end = std.mem.findPosLinear(u8, self.raw, self.offset, "\r\n") orelse unreachable;
        const line = self.raw[self.offset..end];
        self.offset = end + 2;
        const colon = std.mem.findScalar(u8, line, ':') orelse unreachable;
        return .{ .name_raw = line[0..colon], .value_raw = form.trim(line[colon + 1 ..]) };
    }
};

pub const Body = struct {
    raw: *const http.Request,

    pub fn len(self: Body) usize {
        return self.raw.body_bytes;
    }

    pub fn iterator(self: Body) http.BodyIterator {
        return self.raw.body();
    }

    /// Empty bodies return a borrowed empty slice. One payload chunk is
    /// contiguous even when HTTP chunk framing surrounds it.
    pub fn contiguous(self: Body) ?[]const u8 {
        var it = self.iterator();
        const first = it.next() orelse return self.raw.body_wire[0..0];
        if (it.next() != null) return null;
        return first;
    }

    /// Copy logical payload, never chunk framing/trailers. Full capacity and
    /// immutable-input overlap are checked before writing any destination byte.
    pub fn copyTo(self: Body, destination: []u8) CopyError![]u8 {
        if (destination.len < self.raw.body_bytes) return error.NoSpaceLeft;
        const request_bytes = self.raw.method.ptr[0..self.raw.consumed];
        if (params.overlap(request_bytes, destination)) return error.OverlappingBuffers;
        var offset: usize = 0;
        var it = self.iterator();
        while (it.next()) |span| {
            @memcpy(destination[offset..][0..span.len], span);
            offset += span.len;
        }
        return destination[0..offset];
    }

    /// This fixed memory reader never initiates I/O. Its returned views still
    /// borrow immutable request input; callers must not mutate Reader buffers.
    /// Copy a segmented body explicitly before using Reader.fixed on that copy.
    pub fn reader(self: Body) error{BodyNotContiguous}!std.Io.Reader {
        return .fixed(self.contiguous() orelse return error.BodyNotContiguous);
    }
};

test "target forms, query distinction and repeated raw header views" {
    const cases = .{
        .{ "GET /a%2Fb?tag=a&tag=b&flag HTTP/1.1\r\nHost: x\r\nX-A: one\r\nx-a:\ttwo \t\r\n\r\n", Target.Kind.origin, "/a%2Fb", "tag=a&tag=b&flag" },
        .{ "GET http://x? HTTP/1.1\r\nHost: x\r\n\r\n", Target.Kind.absolute, "", "" },
        .{ "GET https://x/a?x=1 HTTP/1.1\r\nHost: x\r\n\r\n", Target.Kind.absolute, "/a", "x=1" },
        .{ "GET / HTTP/1.1\r\nHost: x\r\n\r\n", Target.Kind.origin, "/", @as(?[]const u8, null) },
        .{ "OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n", Target.Kind.asterisk, @as(?[]const u8, null), @as(?[]const u8, null) },
        .{ "CONNECT x:443 HTTP/1.1\r\nHost: x:443\r\n\r\n", Target.Kind.authority, @as(?[]const u8, null), @as(?[]const u8, null) },
    };
    inline for (cases) |case| {
        var parser = http.Parser.init(.{});
        const raw = (try parser.parse(case[0])).?;
        const request = Request.init(&raw);
        const target = request.target();
        try std.testing.expectEqual(case[1], target.kind);
        if (@as(?[]const u8, case[2])) |expected| try std.testing.expectEqualStrings(expected, target.path.?) else try std.testing.expectEqual(null, target.path);
        if (@as(?[]const u8, case[3])) |expected| try std.testing.expectEqualStrings(expected, target.query_raw.?) else try std.testing.expectEqual(null, target.query_raw);
        try std.testing.expectEqual(raw.target.ptr, target.raw.ptr);
        try std.testing.expectEqual(raw.method.ptr, request.method().ptr);
    }
    var parser = http.Parser.init(.{});
    const raw = (try parser.parse(cases[0][0])).?;
    const request = Request.init(&raw);
    const query = try request.query();
    var tags = query.allRaw("tag");
    try std.testing.expectEqualStrings("a", tags.next().?.value_raw);
    try std.testing.expectEqualStrings("b", tags.next().?.value_raw);
    try std.testing.expectEqualStrings("one", request.header("X-a").?);
    var headers = request.headers();
    _ = headers.next();
    try std.testing.expectEqualStrings("one", headers.next().?.value_raw);
    try std.testing.expectEqualStrings("two", headers.next().?.value_raw);
    try std.testing.expectEqual(null, headers.next());
    try std.testing.expectError(error.TooManyParams, request.queryWithLimits(.{ .max_pairs = 2 }));
}

test "body adapters use logical payload and perform atomic explicit copies" {
    const cases = .{
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc",
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n2\r\nbc\r\n0\r\nX-T: ignored\r\n\r\n",
    };
    inline for (cases, 0..) |wire, index| {
        var parser = http.Parser.init(.{});
        const raw = (try parser.parse(wire)).?;
        const body = Request.init(&raw).body();
        try std.testing.expectEqual(@as(usize, 3), body.len());
        var copy: [3]u8 = undefined;
        try std.testing.expectEqualStrings("abc", try body.copyTo(&copy));
        var short: [2]u8 = @splat(0xaa);
        try std.testing.expectError(error.NoSpaceLeft, body.copyTo(&short));
        try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xaa }, &short);
        if (index == 2) {
            try std.testing.expectEqual(null, body.contiguous());
            try std.testing.expectError(error.BodyNotContiguous, body.reader());
        } else {
            try std.testing.expectEqualStrings("abc", body.contiguous().?);
            var reader = try body.reader();
            try std.testing.expectEqualStrings("abc", try reader.take(3));
            try std.testing.expectError(error.EndOfStream, reader.takeByte());
        }
    }
    var wire = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc".*;
    var parser = http.Parser.init(.{});
    const raw = (try parser.parse(&wire)).?;
    try std.testing.expectError(error.OverlappingBuffers, Request.init(&raw).body().copyTo(wire[0..3]));
    try std.testing.expectEqualStrings("POS", wire[0..3]);
    parser.reset();
    const empty = (try parser.parse("GET / HTTP/1.1\r\nHost: x\r\n\r\n")).?;
    try std.testing.expectEqualStrings("", Request.init(&empty).body().contiguous().?);
}

test "form convenience checks metadata before contiguity and never merges query" {
    const prefix = "POST /?a=query HTTP/1.1\r\nHost: x\r\n";
    var parser = http.Parser.init(.{});
    const raw = (try parser.parse(prefix ++ "Content-Type: application/x-www-form-urlencoded; charset=\"UTF-8\"\r\nContent-Length: 10\r\n\r\na=001&flag")).?;
    const request = Request.init(&raw);
    const pairs = try request.formUrlEncoded(.{});
    try std.testing.expectEqualStrings("001", pairs.firstRaw("a").?.value_raw);
    try std.testing.expectEqualStrings("query", (try request.query()).firstRaw("a").?.value_raw);
    try std.testing.expect(!pairs.firstRaw("flag").?.has_equals);
    const cases = .{
        .{ "", error.MissingContentType },
        .{ "Content-Type: application/json\r\n", error.UnsupportedMediaType },
        .{ "Content-Type: application/x-www-form-urlencoded\r\nContent-Type: application/x-www-form-urlencoded\r\n", error.AmbiguousContentType },
        .{ "Content-Type: application/x-www-form-urlencoded\r\nContent-Encoding: gzip\r\n", error.UnsupportedContentEncoding },
        .{ "Content-Type: application/x-www-form-urlencoded; x=1; X=2\r\n", error.DuplicateMetadataParameter },
        .{ "Content-Type: application/x-www-form-urlencoded\r\n", error.BodyNotContiguous },
    };
    inline for (cases) |case| {
        parser.reset();
        const item = (try parser.parse(prefix ++ case[0] ++ "Transfer-Encoding: chunked\r\n\r\n2\r\na=\r\n1\r\n1\r\n0\r\n\r\n")).?;
        try std.testing.expectError(case[1], Request.init(&item).formUrlEncoded(.{}));
    }
    parser.reset();
    const segmented = (try parser.parse(prefix ++ "Content-Type: application/x-www-form-urlencoded\r\nTransfer-Encoding: chunked\r\n\r\n2\r\na=\r\n1\r\n1\r\n0\r\n\r\n")).?;
    try std.testing.expectError(error.ParamsTooLarge, Request.init(&segmented).formUrlEncoded(.{ .max_bytes = 2 }));
    parser.reset();
    const segmented_multipart = (try parser.parse(prefix ++ "Content-Type: multipart/form-data; boundary=B\r\nTransfer-Encoding: chunked\r\n\r\n2\r\na=\r\n1\r\n1\r\n0\r\n\r\n")).?;
    try std.testing.expectError(error.MultipartTooLarge, Request.init(&segmented_multipart).formMultipart(.{ .max_bytes = 2 }));
}

test "multipart request helper validates and owns small boundary metadata" {
    const payload = "--A:B\r\nContent-Disposition: form-data; name=x\r\n\r\na\r\n--A:B--\r\n";
    var wire: [512]u8 = undefined;
    const bytes = try std.fmt.bufPrint(&wire, "POST / HTTP/1.1\r\nHost: x\r\nContent-Type: multipart/form-data; boundary=\"A:B\"\r\nContent-Length: {d}\r\n\r\n{s}", .{ payload.len, payload });
    var parser = http.Parser.init(.{});
    const raw = (try parser.parse(bytes)).?;
    const request = Request.init(&raw);
    var it = (try request.formMultipart(.{})).iterator();
    try std.testing.expectEqualStrings("a", it.next().?.data);
    try std.testing.expectEqual(null, it.next());
    var boundary: [3]u8 = undefined;
    try std.testing.expectEqualStrings("A:B", try request.multipartBoundaryInto(&boundary));
    try std.testing.expectError(error.NoSpaceLeft, request.multipartBoundaryInto(boundary[0..2]));
}

test "request cookie helpers validate every field and borrow exact raw token bytes" {
    const wire = "GET / HTTP/1.1\r\nHost: x\r\nCookie: sid=001%20+==; q=\"raw\"\r\ncookie: sid=two; flag=false\r\n\r\n";
    var parser = http.Parser.init(.{});
    const raw = (try parser.parse(wire)).?;
    const request = Request.init(&raw);
    const view = try request.cookies();
    try std.testing.expectEqual(@as(usize, 4), view.count);
    try std.testing.expectError(error.DuplicateCookie, request.cookie("sid"));
    try std.testing.expectEqualStrings("false", (try request.cookie("flag")).?);
    try std.testing.expectEqual(null, try request.cookie("missing"));
    const offset = std.mem.indexOf(u8, wire, "001%20+==").?;
    try std.testing.expectEqual(wire[offset..].ptr, view.firstRaw("sid").?.value_raw.ptr);
    try std.testing.expectEqualStrings("raw", view.firstRaw("q").?.value_raw);
    try std.testing.expectError(error.TooManyCookies, request.cookiesWithLimits(.{ .max_pairs = 3 }));
    var invalid_parser = http.Parser.init(.{});
    const invalid = (try invalid_parser.parse("GET / HTTP/1.1\r\nHost: x\r\nCookie: sid=ok\r\nCookie: broken\r\n\r\n")).?;
    try std.testing.expectError(error.MalformedCookie, Request.init(&invalid).cookie("sid"));
}
