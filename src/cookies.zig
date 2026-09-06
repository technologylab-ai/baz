//! Bounded cookie views and Set-Cookie formatting. No allocator or decoding.
const std = @import("std");
const overlap = @import("params.zig").overlap;

pub const Limits = struct {
    max_bytes: usize = 8192,
    max_pairs: usize = 32,
    max_name_bytes: usize = 256,
    max_value_bytes: usize = 4096,
};

pub const Error = error{
    MalformedCookie,
    MalformedHeaders,
    CookiesTooLarge,
    TooManyCookies,
    NameTooLarge,
    ValueTooLarge,
};

pub const Cookie = struct {
    name_raw: []const u8,
    /// Outer quotes are excluded. Percent escapes and plus bytes stay unchanged.
    value_raw: []const u8,
    quoted: bool,
};

/// Construct with parse() or parseHeaders(). Keep the source immutable while borrowing this view.
/// Duplicate names retain wire order. Cookie names use exact, case-sensitive comparisons.
pub const Cookies = struct {
    source: []const u8,
    count: usize,
    from_headers: bool,

    pub fn iterator(self: Cookies) Iterator {
        return .{ .fields = .{ .source = self.source, .from_headers = self.from_headers } };
    }

    pub fn firstRaw(self: Cookies, name: []const u8) ?Cookie {
        var it = self.allRaw(name);
        return it.next();
    }

    pub fn allRaw(self: Cookies, name: []const u8) MatchingIterator {
        return .{ .pairs = self.iterator(), .name = name };
    }

    /// Reject duplicate names, including duplicate empty values.
    pub fn uniqueRaw(self: Cookies, name: []const u8) error{DuplicateCookie}!?[]const u8 {
        var it = self.allRaw(name);
        const first = it.next() orelse return null;
        if (it.next() != null) return error.DuplicateCookie;
        return first.value_raw;
    }
};

pub const Iterator = struct {
    fields: Fields,
    field: []const u8 = "",
    offset: usize = 0,

    pub fn next(self: *Iterator) ?Cookie {
        if (self.offset == self.field.len) {
            self.field = (self.fields.next() catch return null) orelse return null;
            self.offset = 0;
        }
        const end = std.mem.findScalarPos(u8, self.field, self.offset, ';') orelse self.field.len;
        const raw = self.field[self.offset..end];
        self.offset = if (end == self.field.len) end else end + 1;
        return parsePair(raw, .{
            .max_name_bytes = std.math.maxInt(usize),
            .max_value_bytes = std.math.maxInt(usize),
        }) catch return null;
    }
};

pub const MatchingIterator = struct {
    pairs: Iterator,
    name: []const u8,

    pub fn next(self: *MatchingIterator) ?Cookie {
        while (self.pairs.next()) |cookie| {
            if (std.mem.eql(u8, self.name, cookie.name_raw)) return cookie;
        }
        return null;
    }
};

/// An empty source represents no cookies. An empty Cookie header is malformed.
pub fn parse(source: []const u8, limits: Limits) Error!Cookies {
    return validate(source, false, limits);
}

/// Read raw header lines ending in CRLF, without the request line or final empty line.
/// Bounds apply to all Cookie field values together. Other fields receive syntax checks.
pub fn parseHeaders(raw_headers: []const u8, limits: Limits) Error!Cookies {
    return validate(raw_headers, true, limits);
}

fn validate(source: []const u8, from_headers: bool, limits: Limits) Error!Cookies {
    var fields: Fields = .{ .source = source, .from_headers = from_headers };
    var count: usize = 0;
    var bytes: usize = 0;
    while (try fields.next()) |field| {
        if (field.len > limits.max_bytes - bytes) return error.CookiesTooLarge;
        bytes += field.len;
        var pairs = std.mem.splitScalar(u8, field, ';');
        while (pairs.next()) |raw| {
            if (count == limits.max_pairs) return error.TooManyCookies;
            _ = try parsePair(raw, limits);
            count += 1;
        }
    }
    return .{ .source = source, .count = count, .from_headers = from_headers };
}

const Fields = struct {
    source: []const u8,
    from_headers: bool,
    offset: usize = 0,

    fn next(self: *Fields) Error!?[]const u8 {
        if (self.offset == self.source.len) return null;
        if (!self.from_headers) {
            self.offset = self.source.len;
            return self.source;
        }
        while (self.offset < self.source.len) {
            const end = std.mem.findPosLinear(u8, self.source, self.offset, "\r\n") orelse return error.MalformedHeaders;
            const line = self.source[self.offset..end];
            self.offset = end + 2;
            const colon = std.mem.findScalar(u8, line, ':') orelse return error.MalformedHeaders;
            if (colon == 0) return error.MalformedHeaders;
            for (line[0..colon]) |byte| if (!token(byte)) return error.MalformedHeaders;
            const value = line[colon + 1 ..];
            for (value) |byte| {
                if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return error.MalformedHeaders;
            }
            if (std.ascii.eqlIgnoreCase(line[0..colon], "Cookie")) return value;
        }
        return null;
    }
};

fn parsePair(raw: []const u8, limits: Limits) Error!Cookie {
    const pair = std.mem.trim(u8, raw, " \t");
    const equal = std.mem.findScalar(u8, pair, '=') orelse return error.MalformedCookie;
    const name = pair[0..equal];
    if (name.len == 0) return error.MalformedCookie;
    if (name.len > limits.max_name_bytes) return error.NameTooLarge;
    for (name) |byte| if (!token(byte)) return error.MalformedCookie;
    var value = pair[equal + 1 ..];
    const quoted = value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"';
    if (quoted) value = value[1 .. value.len - 1];
    if (value.len > limits.max_value_bytes) return error.ValueTooLarge;
    for (value) |byte| if (!cookieOctet(byte)) return error.MalformedCookie;
    return .{ .name_raw = name, .value_raw = value, .quoted = quoted };
}

pub const SameSite = enum { strict, lax, none };

pub const Options = struct {
    /// An absolute path without trailing SP, which browsers would trim.
    /// Null omits Path, which leaves browser default-path rules in effect.
    path: ?[]const u8 = "/",
    /// ASCII DNS name without leading or trailing dots. Null creates a host-only cookie.
    domain: ?[]const u8 = null,
    /// Seconds from receipt. Null omits Max-Age; zero or negative values request deletion.
    max_age: ?i64 = null,
    /// Unix seconds in UTC, from 1970 through 9999. Null omits Expires.
    expires: ?u64 = null,
    secure: bool = false,
    http_only: bool = true,
    same_site: ?SameSite = .lax,
};

pub const EncodeError = error{
    InvalidCookieName,
    InvalidCookieValue,
    InvalidCookiePath,
    InvalidCookieDomain,
    InvalidCookieExpiry,
    InsecureCookie,
    InvalidCookiePrefix,
    CookieTooLarge,
    NoSpaceLeft,
    OverlappingBuffers,
};

/// Validate all fields and calculate the Set-Cookie field value length.
/// The result excludes the header name and CRLF. Values receive no implicit encoding.
pub fn encodedLength(name: []const u8, value: []const u8, options: Options) EncodeError!usize {
    if (name.len == 0) return error.InvalidCookieName;
    for (name) |byte| if (!token(byte)) return error.InvalidCookieName;
    for (value) |byte| if (!cookieOctet(byte)) return error.InvalidCookieValue;
    if (options.path) |path| {
        if (path.len == 0 or path[0] != '/' or path[path.len - 1] == ' ') return error.InvalidCookiePath;
        for (path) |byte| if (byte < 0x20 or byte > 0x7e or byte == ';') return error.InvalidCookiePath;
    }
    if (options.domain) |domain| try validateDomain(domain);
    if (options.expires) |seconds| if (seconds > max_expiry) return error.InvalidCookieExpiry;
    if (options.same_site == .none and !options.secure) return error.InsecureCookie;
    // Browsers match these prefixes without case sensitivity under RFC6265bis section 5.4.
    if (hasPrefix(name, "__Secure-") and !options.secure) return error.InvalidCookiePrefix;
    if (hasPrefix(name, "__Host-")) {
        if (!options.secure or options.domain != null or options.path == null or
            !std.mem.eql(u8, options.path.?, "/")) return error.InvalidCookiePrefix;
    }
    var length = try add(name.len, 1);
    length = try add(length, value.len);
    if (options.path) |path| length = try add(try add(length, "; Path=".len), path.len);
    if (options.domain) |domain| length = try add(try add(length, "; Domain=".len), domain.len);
    if (options.max_age) |age| length = try add(length, "; Max-Age=".len + signedDigits(age));
    if (options.expires != null) length = try add(length, "; Expires=".len + 29);
    if (options.secure) length = try add(length, "; Secure".len);
    if (options.http_only) length = try add(length, "; HttpOnly".len);
    if (options.same_site) |site| length = try add(length, "; SameSite=".len + siteName(site).len);
    return length;
}

/// Write into caller storage. Validation, capacity, and overlap errors leave destination unchanged.
/// Name, value, path, and domain must not overlap any part of destination.
pub fn encodeInto(name: []const u8, value: []const u8, options: Options, destination: []u8) EncodeError![]u8 {
    const length = try encodedLength(name, value, options);
    if (length > destination.len) return error.NoSpaceLeft;
    if (overlap(name, destination) or overlap(value, destination)) return error.OverlappingBuffers;
    if (options.path) |path| if (overlap(path, destination)) return error.OverlappingBuffers;
    if (options.domain) |domain| if (overlap(domain, destination)) return error.OverlappingBuffers;
    var out: Output = .{ .bytes = destination[0..length] };
    out.append(name);
    out.append("=");
    out.append(value);
    if (options.path) |path| {
        out.append("; Path=");
        out.append(path);
    }
    if (options.domain) |domain| {
        out.append("; Domain=");
        out.append(domain);
    }
    if (options.max_age) |age| {
        out.append("; Max-Age=");
        if (age < 0) out.append("-");
        out.decimal(@abs(age), digits(@abs(age)));
    }
    if (options.expires) |seconds| {
        out.append("; Expires=");
        out.date(seconds);
    }
    if (options.secure) out.append("; Secure");
    if (options.http_only) out.append("; HttpOnly");
    if (options.same_site) |site| {
        out.append("; SameSite=");
        out.append(siteName(site));
    }
    std.debug.assert(out.offset == length);
    return destination[0..length];
}

const max_expiry: u64 = 253402300799;

const Output = struct {
    bytes: []u8,
    offset: usize = 0,

    fn append(self: *Output, bytes: []const u8) void {
        @memcpy(self.bytes[self.offset..][0..bytes.len], bytes);
        self.offset += bytes.len;
    }

    fn decimal(self: *Output, value: u64, width: usize) void {
        var remaining = value;
        var i = width;
        while (i > 0) {
            i -= 1;
            self.bytes[self.offset + i] = '0' + @as(u8, @intCast(remaining % 10));
            remaining /= 10;
        }
        std.debug.assert(remaining == 0);
        self.offset += width;
    }

    fn date(self: *Output, seconds: u64) void {
        std.debug.assert(seconds <= max_expiry);
        const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
        const day = epoch.getEpochDay();
        // Gregorian leap-year rules repeat every 400 years. Limit the standard helper to one cycle.
        const within_cycle: std.time.epoch.EpochDay = .{ .day = day.day % 146097 };
        var year = within_cycle.calculateYearDay();
        year.year += @as(u16, @intCast((day.day / 146097) * 400));
        const month = year.calculateMonthDay();
        const time = epoch.getDaySeconds();
        const weekdays = "SunMonTueWedThuFriSat";
        const months = "JanFebMarAprMayJunJulAugSepOctNovDec";
        const weekday: usize = @intCast((day.day + 4) % 7);
        const month_index: usize = month.month.numeric() - 1;
        self.append(weekdays[weekday * 3 ..][0..3]);
        self.append(", ");
        self.decimal(@as(u32, month.day_index) + 1, 2);
        self.append(" ");
        self.append(months[month_index * 3 ..][0..3]);
        self.append(" ");
        self.decimal(year.year, 4);
        self.append(" ");
        self.decimal(time.getHoursIntoDay(), 2);
        self.append(":");
        self.decimal(time.getMinutesIntoHour(), 2);
        self.append(":");
        self.decimal(time.getSecondsIntoMinute(), 2);
        self.append(" GMT");
    }
};

fn token(byte: u8) bool {
    return switch (byte) {
        '0'...'9', 'A'...'Z', 'a'...'z', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn cookieOctet(byte: u8) bool {
    return byte == 0x21 or (byte >= 0x23 and byte <= 0x2b) or
        (byte >= 0x2d and byte <= 0x3a) or (byte >= 0x3c and byte <= 0x5b) or
        (byte >= 0x5d and byte <= 0x7e);
}

fn validateDomain(domain: []const u8) EncodeError!void {
    if (domain.len == 0 or domain.len > 253) return error.InvalidCookieDomain;
    var labels = std.mem.splitScalar(u8, domain, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') return error.InvalidCookieDomain;
        for (label) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '-') return error.InvalidCookieDomain;
        }
    }
}

fn hasPrefix(name: []const u8, prefix: []const u8) bool {
    return name.len >= prefix.len and std.ascii.eqlIgnoreCase(name[0..prefix.len], prefix);
}

fn add(a: usize, b: usize) EncodeError!usize {
    return std.math.add(usize, a, b) catch error.CookieTooLarge;
}

fn digits(value: u64) usize {
    var remaining = value;
    var length: usize = 1;
    while (remaining >= 10) : (length += 1) remaining /= 10;
    return length;
}

fn signedDigits(value: i64) usize {
    return digits(@abs(value)) + @intFromBool(value < 0);
}

fn siteName(site: SameSite) []const u8 {
    return switch (site) {
        .strict => "Strict",
        .lax => "Lax",
        .none => "None",
    };
}

test "cookie views preserve borrowed bytes, quotes, case, and duplicate order" {
    const source = "id=001; flag=false; quoted=\"%26+[]==\"; id=; Id=case; empty=\"\"; id=last";
    const view = try parse(source, .{});
    try std.testing.expectEqual(@as(usize, 7), view.count);
    try std.testing.expectEqualStrings("001", view.firstRaw("id").?.value_raw);
    try std.testing.expectEqualStrings("false", (try view.uniqueRaw("flag")).?);
    try std.testing.expectEqualStrings("case", (try view.uniqueRaw("Id")).?);
    try std.testing.expectEqualStrings("", (try view.uniqueRaw("empty")).?);
    try std.testing.expectEqual(null, try view.uniqueRaw("missing"));
    const quoted = view.firstRaw("quoted").?;
    try std.testing.expect(quoted.quoted);
    try std.testing.expectEqualStrings("%26+[]==", quoted.value_raw);
    try std.testing.expectError(error.DuplicateCookie, view.uniqueRaw("id"));
    var matches = view.allRaw("id");
    try std.testing.expectEqualStrings("001", matches.next().?.value_raw);
    try std.testing.expectEqualStrings("", matches.next().?.value_raw);
    try std.testing.expectEqualStrings("last", matches.next().?.value_raw);
    try std.testing.expectEqual(null, matches.next());
    var it = view.iterator();
    while (it.next()) |cookie| {
        try std.testing.expect(@intFromPtr(cookie.name_raw.ptr) >= @intFromPtr(source.ptr));
        try std.testing.expect(@intFromPtr(cookie.value_raw.ptr) + cookie.value_raw.len <= @intFromPtr(source.ptr) + source.len);
    }
    try std.testing.expectEqual(@as(usize, 0), (try parse("", .{})).count);
    try std.testing.expectError(error.DuplicateCookie, (try parse("empty=; empty=", .{})).uniqueRaw("empty"));
}

test "cookie fields combine bounds and preserve order without trusting raw header syntax" {
    const source = "Host: example.test\r\nCookie: a=1; q=\"x\"\r\nX-Other: ok\r\ncOoKiE:\tb=2; a=3\r\n";
    const view = try parseHeaders(source, .{});
    try std.testing.expectEqual(@as(usize, 4), view.count);
    try std.testing.expectEqualStrings("2", (try view.uniqueRaw("b")).?);
    var matches = view.allRaw("a");
    try std.testing.expectEqualStrings("1", matches.next().?.value_raw);
    try std.testing.expectEqualStrings("3", matches.next().?.value_raw);
    try std.testing.expectEqual(null, matches.next());
    try std.testing.expectError(error.DuplicateCookie, view.uniqueRaw("a"));
    const two = "Cookie:a=1\r\nCookie:b=2\r\n";
    _ = try parseHeaders(two, .{ .max_bytes = 6, .max_pairs = 2 });
    try std.testing.expectError(error.CookiesTooLarge, parseHeaders(two, .{ .max_bytes = 5 }));
    try std.testing.expectError(error.TooManyCookies, parseHeaders(two, .{ .max_pairs = 1 }));
    try std.testing.expectEqual(@as(usize, 0), (try parseHeaders("Host: example.test\r\n", .{ .max_bytes = 0, .max_pairs = 0 })).count);
    for ([_][]const u8{ "Cookie: \r\n", "Cookie:\t\r\n", "Cookie:a=1\r\nCookie:b\r\n" }) |bad|
        try std.testing.expectError(error.MalformedCookie, parseHeaders(bad, .{}));
    for ([_][]const u8{ "Cookie:a=1", "Cookie:a=1\n", "Cookie:a=1\r\nBad\r\n", ": value\r\n", "Cookie :a=1\r\n", "Host: x\x00\r\n", "Host: x\nCookie:a=1\r\n", "\r\n", " Cookie:a=1\r\n" }) |bad|
        try std.testing.expectError(error.MalformedHeaders, parseHeaders(bad, .{}));
}

test "cookie parser rejects malformed pairs and checks exact bounds before publishing" {
    _ = try parse("a=\"12\"", .{ .max_bytes = 6, .max_pairs = 1, .max_name_bytes = 1, .max_value_bytes = 2 });
    try std.testing.expectError(error.CookiesTooLarge, parse("a=12", .{ .max_bytes = 3 }));
    try std.testing.expectError(error.TooManyCookies, parse("a=1;b=2", .{ .max_pairs = 1 }));
    try std.testing.expectError(error.NameTooLarge, parse("ab=1", .{ .max_name_bytes = 1 }));
    try std.testing.expectError(error.ValueTooLarge, parse("a=\"12\"", .{ .max_value_bytes = 1 }));
    _ = try parse("", .{ .max_bytes = 0, .max_pairs = 0 });
    for ([_][]const u8{ " ", "a", "=b", "a =b", "a= b", "a=one two", "a[]=1", "a=1, b=2", "a=\"bad", "a=bad\"", "a=\"a\\b\"", "a=1;", ";a=1", "a=1;;b=2", "a=\xff", "a=\r\n", "a=\x00" }) |bad|
        try std.testing.expectError(error.MalformedCookie, parse(bad, .{}));
    var byte: usize = 0;
    while (byte < 256) : (byte += 1) {
        const raw = [_]u8{ 'a', '=', 'x', @intCast(byte), 'y' };
        if (cookieOctet(@intCast(byte))) {
            _ = try parse(&raw, .{});
        } else {
            try std.testing.expectError(error.MalformedCookie, parse(&raw, .{}));
        }
    }
}

test "iterator respects accepted custom limits above the defaults" {
    const raw = "a" ** 257 ++ "=" ++ "x" ** 4097;
    const view = try parse(raw, .{ .max_name_bytes = 257, .max_value_bytes = 4097 });
    var it = view.iterator();
    const item = it.next().?;
    try std.testing.expectEqual(@as(usize, 257), item.name_raw.len);
    try std.testing.expectEqual(@as(usize, 4097), item.value_raw.len);
    try std.testing.expectEqual(null, it.next());
}

test "Set-Cookie defaults, explicit flags, dates, and exact output capacity" {
    var buffer: [256]u8 = undefined;
    const default = "sid=a%20+b==[]; Path=/; HttpOnly; SameSite=Lax";
    const value = try encodeInto("sid", "a%20+b==[]", .{}, buffer[0..default.len]);
    try std.testing.expectEqualStrings(default, value);
    try std.testing.expectEqual(default.len, try encodedLength("sid", "a%20+b==[]", .{}));
    try std.testing.expectEqualStrings("sid=", try encodeInto("sid", "", .{ .path = null, .http_only = false, .same_site = null }, &buffer));
    try std.testing.expectEqualStrings("sid=abc; Path=/app; Domain=Example.test; Max-Age=9223372036854775807; Expires=Fri, 31 Dec 9999 23:59:59 GMT; Secure; HttpOnly; SameSite=None", try encodeInto("sid", "abc", .{ .path = "/app", .domain = "Example.test", .max_age = std.math.maxInt(i64), .expires = max_expiry, .secure = true, .same_site = .none }, &buffer));
    try std.testing.expectEqualStrings("sid=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; HttpOnly; SameSite=Strict", try encodeInto("sid", "", .{ .max_age = 0, .expires = 0, .same_site = .strict }, &buffer));
    try std.testing.expectEqualStrings("sid=x; Path=/; Max-Age=-9223372036854775808; HttpOnly; SameSite=Lax", try encodeInto("sid", "x", .{ .max_age = std.math.minInt(i64) }, &buffer));
    try std.testing.expectEqualStrings("sid=x; Path=/; Expires=Tue, 29 Feb 2000 12:34:56 GMT; HttpOnly; SameSite=Lax", try encodeInto("sid", "x", .{ .expires = 951827696 }, &buffer));
    try std.testing.expectEqualStrings("sid=x; Path=/; Expires=Mon, 01 Mar 2100 00:00:00 GMT; HttpOnly; SameSite=Lax", try encodeInto("sid", "x", .{ .expires = 4107542400 }, &buffer));
}

test "Set-Cookie validates browser prefix rules without changing name spelling" {
    for ([_][]const u8{ "__Secure-id", "__SECURE-id", "__SeCuRe-id" }) |name| {
        try std.testing.expectError(error.InvalidCookiePrefix, encodedLength(name, "x", .{}));
        _ = try encodedLength(name, "x", .{ .secure = true });
    }
    for ([_][]const u8{ "__Host-id", "__HOST-id", "__hOsT-id" }) |name| {
        try std.testing.expectError(error.InvalidCookiePrefix, encodedLength(name, "x", .{}));
        try std.testing.expectError(error.InvalidCookiePrefix, encodedLength(name, "x", .{ .secure = true, .path = null }));
        try std.testing.expectError(error.InvalidCookiePrefix, encodedLength(name, "x", .{ .secure = true, .path = "/app" }));
        try std.testing.expectError(error.InvalidCookiePrefix, encodedLength(name, "x", .{ .secure = true, .domain = "example.test" }));
        _ = try encodedLength(name, "x", .{ .secure = true });
    }
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("__hOsT-id=x; Path=/; Secure; HttpOnly; SameSite=Lax", try encodeInto("__hOsT-id", "x", .{ .secure = true }, &buffer));
    try std.testing.expectError(error.InsecureCookie, encodedLength("sid", "x", .{ .same_site = .none }));
    _ = try encodedLength("__Hostish", "x", .{});
}

test "all Set-Cookie errors preserve destination including overlapping option storage" {
    const Case = struct { name: []const u8 = "sid", value: []const u8 = "x", options: Options = .{}, expected: EncodeError };
    const cases = [_]Case{
        .{ .name = "", .expected = error.InvalidCookieName },
        .{ .name = "bad[]", .expected = error.InvalidCookieName },
        .{ .name = "bad\r\nX", .expected = error.InvalidCookieName },
        .{ .value = "bad;value", .expected = error.InvalidCookieValue },
        .{ .value = "\"quoted\"", .expected = error.InvalidCookieValue },
        .{ .value = "bad\r\nX", .expected = error.InvalidCookieValue },
        .{ .options = .{ .path = "relative" }, .expected = error.InvalidCookiePath },
        .{ .options = .{ .path = "/app " }, .expected = error.InvalidCookiePath },
        .{ .options = .{ .path = "/; Secure" }, .expected = error.InvalidCookiePath },
        .{ .options = .{ .path = "/\x7f" }, .expected = error.InvalidCookiePath },
        .{ .options = .{ .domain = ".example.test" }, .expected = error.InvalidCookieDomain },
        .{ .options = .{ .domain = "example.test." }, .expected = error.InvalidCookieDomain },
        .{ .options = .{ .domain = "-example.test" }, .expected = error.InvalidCookieDomain },
        .{ .options = .{ .domain = "example-.test" }, .expected = error.InvalidCookieDomain },
        .{ .options = .{ .domain = "example..test" }, .expected = error.InvalidCookieDomain },
        .{ .options = .{ .domain = "example.test:80" }, .expected = error.InvalidCookieDomain },
        .{ .options = .{ .domain = "ex\xffmple.test" }, .expected = error.InvalidCookieDomain },
        .{ .options = .{ .domain = "a" ** 64 ++ ".test" }, .expected = error.InvalidCookieDomain },
        .{ .options = .{ .expires = max_expiry + 1 }, .expected = error.InvalidCookieExpiry },
        .{ .options = .{ .same_site = .none }, .expected = error.InsecureCookie },
        .{ .name = "__Host-id", .expected = error.InvalidCookiePrefix },
    };
    for (cases) |case| {
        var buffer: [256]u8 = @splat(0xaa);
        try std.testing.expectError(case.expected, encodeInto(case.name, case.value, case.options, &buffer));
        try std.testing.expectEqualSlices(u8, &@as([256]u8, @splat(0xaa)), &buffer);
    }
    var short: [4]u8 = @splat(0xaa);
    try std.testing.expectError(error.NoSpaceLeft, encodeInto("sid", "x", .{}, &short));
    try std.testing.expectEqualSlices(u8, &@as([4]u8, @splat(0xaa)), &short);
    var buffer: [256]u8 = @splat('a');
    buffer[0] = '/';
    const snapshot = buffer;
    try std.testing.expectError(error.OverlappingBuffers, encodeInto(buffer[1..4], "x", .{}, &buffer));
    try std.testing.expectError(error.OverlappingBuffers, encodeInto("sid", buffer[1..4], .{}, &buffer));
    try std.testing.expectError(error.OverlappingBuffers, encodeInto("sid", "x", .{ .path = buffer[0..4] }, &buffer));
    try std.testing.expectError(error.OverlappingBuffers, encodeInto("sid", "x", .{ .domain = buffer[1..4] }, &buffer));
    try std.testing.expectEqualSlices(u8, &snapshot, &buffer);
}
