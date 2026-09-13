//! Ordered borrowed query/form pairs and explicit byte decoding. Raw iteration
//! needs no allocator; decoded iteration uses an explicit caller allocator.
const std = @import("std");

pub const Limits = struct {
    max_bytes: usize = 64 * 1024,
    max_pairs: usize = 256,
    max_name_bytes: usize = 4096,
    max_value_bytes: usize = 64 * 1024,
};

pub const Error = error{ ParamsTooLarge, TooManyParams, NameTooLarge, ValueTooLarge };
pub const DecodeError = error{ InvalidEscape, NoSpaceLeft, OverlappingBuffers };
pub const AllocDecodeError = std.mem.Allocator.Error || error{InvalidEscape};

pub const Encoding = enum {
    /// Percent-decode bytes, preserving raw '+'.
    percent,
    /// Percent-decode bytes and replace raw '+' with SP.
    form,
};

pub const Param = struct {
    name_raw: []const u8,
    value_raw: []const u8,
    has_equals: bool,
};

/// Owned decoded bytes, independent of the input and other iterator results.
/// Release with deinit() using the iterator's allocator, or reset its arena
/// after every retained result is no longer needed. Do not free field subslices.
pub const DecodedParam = struct {
    name: []const u8,
    value: []const u8,
    has_equals: bool,
    storage: []u8,

    pub fn deinit(self: *DecodedParam, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
        self.* = undefined;
    }
};

/// Construct with parse(). Views borrow the supplied bytes without decoding.
/// Empty separator components are skipped; duplicate names retain wire order.
pub const Params = struct {
    raw: []const u8,
    count: usize,

    pub fn parse(bytes: []const u8, limits: Limits) Error!Params {
        if (bytes.len > limits.max_bytes) return error.ParamsTooLarge;
        var it: Iterator = .{ .raw = bytes };
        var count: usize = 0;
        while (it.next()) |param| {
            if (count == limits.max_pairs) return error.TooManyParams;
            if (param.name_raw.len > limits.max_name_bytes) return error.NameTooLarge;
            if (param.value_raw.len > limits.max_value_bytes) return error.ValueTooLarge;
            count += 1;
        }
        return .{ .raw = bytes, .count = count };
    }

    pub fn iterator(self: Params) Iterator {
        return .{ .raw = self.raw };
    }

    /// Decode each pair on demand with caller-owned allocation. The iterator
    /// borrows the original input; each returned pair independently owns its
    /// decoded bytes until deinit() or allocator arena reset. Wire order,
    /// duplicates, and bare keys are preserved. Bytes are not UTF-8 validated,
    /// normalized, or coerced. Encoding explicitly chooses the '+' policy.
    ///
    /// parse() limits still bound raw input and pairs; decoding never expands
    /// fields. Allocator bookkeeping and retained results belong to the caller's
    /// memory budget. Use application workers for arbitrary allocator work.
    pub fn decodedIterator(self: Params, allocator: std.mem.Allocator, encoding: Encoding) DecodedIterator {
        return .{ .pairs = self.iterator(), .allocator = allocator, .encoding = encoding };
    }

    /// Exact raw-name comparison. A present bare key is still a Param.
    pub fn firstRaw(self: Params, name: []const u8) ?Param {
        var it = self.allRaw(name);
        return it.next();
    }

    pub fn allRaw(self: Params, name: []const u8) MatchingIterator {
        return .{ .pairs = self.iterator(), .name = name };
    }
};

pub const Iterator = struct {
    raw: []const u8,
    offset: usize = 0,

    pub fn next(self: *Iterator) ?Param {
        while (self.offset < self.raw.len) {
            const start = self.offset;
            const end = std.mem.findScalarPos(u8, self.raw, start, '&') orelse self.raw.len;
            self.offset = if (end == self.raw.len) end else end + 1;
            const pair = self.raw[start..end];
            if (pair.len == 0) continue;
            if (std.mem.findScalar(u8, pair, '=')) |eq| {
                return .{ .name_raw = pair[0..eq], .value_raw = pair[eq + 1 ..], .has_equals = true };
            }
            return .{ .name_raw = pair, .value_raw = pair[pair.len..], .has_equals = false };
        }
        return null;
    }
};

pub const MatchingIterator = struct {
    pairs: Iterator,
    name: []const u8,

    pub fn next(self: *MatchingIterator) ?Param {
        while (self.pairs.next()) |param| {
            if (std.mem.eql(u8, self.name, param.name_raw)) return param;
        }
        return null;
    }
};

pub const DecodedIterator = struct {
    pairs: Iterator,
    allocator: std.mem.Allocator,
    encoding: Encoding,

    /// Allocates one owned byte buffer per pair. Neither errors nor allocation
    /// failure advance the iterator. The iterator owns no returned storage and
    /// requires no deinit(); callers release each successful result themselves.
    pub fn next(self: *DecodedIterator) AllocDecodeError!?DecodedParam {
        var next_pairs = self.pairs;
        const pair = next_pairs.next() orelse {
            self.pairs = next_pairs;
            return null;
        };
        const name_len = try decodedLength(pair.name_raw);
        const value_len = try decodedLength(pair.value_raw);
        // Both lengths are bounded by disjoint slices of the same input pair.
        const storage_len = std.math.add(usize, name_len, value_len) catch return error.OutOfMemory;
        const storage = try self.allocator.alloc(u8, storage_len);
        const plus_as_space = self.encoding == .form;
        decodeValidated(pair.name_raw, storage[0..name_len], plus_as_space);
        decodeValidated(pair.value_raw, storage[name_len..], plus_as_space);
        self.pairs = next_pairs;
        return .{
            .name = storage[0..name_len],
            .value = storage[name_len..],
            .has_equals = pair.has_equals,
            .storage = storage,
        };
    }
};

pub const parse = Params.parse;

/// Decode once into caller storage; '+' remains a plus. On any error destination
/// is unchanged. Source and destination must not overlap. Bytes are not UTF-8
/// validated, normalized, or coerced. The result borrows destination, not source.
pub fn percentDecodeInto(source: []const u8, destination: []u8) DecodeError![]u8 {
    return decodeInto(source, destination, false);
}

/// As percentDecodeInto(), additionally replacing raw '+' with SP for form data.
pub fn formDecodeInto(source: []const u8, destination: []u8) DecodeError![]u8 {
    return decodeInto(source, destination, true);
}

fn decodeInto(source: []const u8, destination: []u8, plus_as_space: bool) DecodeError![]u8 {
    if (overlap(source, destination)) return error.OverlappingBuffers;
    const count = try decodedLength(source);
    if (count > destination.len) return error.NoSpaceLeft;
    decodeValidated(source, destination[0..count], plus_as_space);
    return destination[0..count];
}

fn decodedLength(source: []const u8) error{InvalidEscape}!usize {
    var input: usize = 0;
    var count: usize = 0;
    while (input < source.len) {
        if (source[input] == '%') {
            if (source.len - input < 3 or hex(source[input + 1]) == null or hex(source[input + 2]) == null)
                return error.InvalidEscape;
            input += 3;
        } else input += 1;
        count += 1;
    }
    return count;
}

/// Source has passed decodedLength(); destination has exactly that length.
fn decodeValidated(source: []const u8, destination: []u8, plus_as_space: bool) void {
    var input: usize = 0;
    var output: usize = 0;
    while (input < source.len) : (output += 1) {
        const byte = source[input];
        if (byte == '%') {
            destination[output] = hex(source[input + 1]).? * 16 + hex(source[input + 2]).?;
            input += 3;
        } else {
            destination[output] = if (byte == '+' and plus_as_space) ' ' else byte;
            input += 1;
        }
    }
}

fn hex(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

pub fn overlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const start_a = @intFromPtr(a.ptr);
    const start_b = @intFromPtr(b.ptr);
    return if (start_a <= start_b) start_b - start_a < a.len else start_a - start_b < b.len;
}

test "raw pairs preserve order, spelling, bare/empty values and source pointers" {
    const bytes = "&&n=001&ok=false&tag=a&tag=b&flag&flag=&=x&a=b=c&a[]=1&%61=%26%3D&b=x+y&";
    const pairs = try parse(bytes, .{});
    try std.testing.expectEqual(@as(usize, 11), pairs.count);
    try std.testing.expectEqualStrings("001", pairs.firstRaw("n").?.value_raw);
    try std.testing.expectEqualStrings("false", pairs.firstRaw("ok").?.value_raw);
    try std.testing.expectEqualStrings("b=c", pairs.firstRaw("a").?.value_raw);
    try std.testing.expectEqualStrings("1", pairs.firstRaw("a[]").?.value_raw);
    try std.testing.expectEqualStrings("%26%3D", pairs.firstRaw("%61").?.value_raw);
    try std.testing.expectEqualStrings("x+y", pairs.firstRaw("b").?.value_raw);
    var tags = pairs.allRaw("tag");
    try std.testing.expectEqualStrings("a", tags.next().?.value_raw);
    try std.testing.expectEqualStrings("b", tags.next().?.value_raw);
    try std.testing.expectEqual(null, tags.next());
    var flags = pairs.allRaw("flag");
    try std.testing.expect(!flags.next().?.has_equals);
    try std.testing.expect(flags.next().?.has_equals);
    try std.testing.expectEqual(null, pairs.firstRaw("absent"));
    try std.testing.expectEqualStrings("x", pairs.firstRaw("").?.value_raw);
    var it = pairs.iterator();
    while (it.next()) |pair| {
        try std.testing.expect(@intFromPtr(pair.name_raw.ptr) >= @intFromPtr(bytes.ptr));
        try std.testing.expect(@intFromPtr(pair.value_raw.ptr) + pair.value_raw.len <= @intFromPtr(bytes.ptr) + bytes.len);
    }
    try std.testing.expectEqual(@as(usize, 0), (try parse("&&", .{})).count);
}

test "pair bounds are checked before publishing any iterable result" {
    _ = try parse("a=12", .{ .max_bytes = 4, .max_pairs = 1, .max_name_bytes = 1, .max_value_bytes = 2 });
    try std.testing.expectError(error.ParamsTooLarge, parse("a=12", .{ .max_bytes = 3 }));
    try std.testing.expectError(error.TooManyParams, parse("a=1&b=2", .{ .max_pairs = 1 }));
    try std.testing.expectError(error.NameTooLarge, parse("ab=1", .{ .max_name_bytes = 1 }));
    try std.testing.expectError(error.ValueTooLarge, parse("a=12", .{ .max_value_bytes = 1 }));
    _ = try parse("&&", .{ .max_pairs = 0 });
    try std.testing.expectError(error.TooManyParams, parse("flag", .{ .max_pairs = 0 }));
}

test "explicit decoders preserve source, decode once and publish only on success" {
    var out: [32]u8 = @splat(0xaa);
    const source = "%26%3D%2520%2B+x%00%ff";
    try std.testing.expectEqualStrings("&=%20++x\x00\xff", try percentDecodeInto(source, &out));
    try std.testing.expectEqualStrings("&=%20+ x\x00\xff", try formDecodeInto(source, &out));
    var exact: [1]u8 = undefined;
    try std.testing.expectEqualStrings(" ", try percentDecodeInto("%20", &exact));
    for ([_][]const u8{ "%", "%2", "%GG", "a%4Z" }) |bad| {
        out = @splat(0xaa);
        try std.testing.expectError(error.InvalidEscape, percentDecodeInto(bad, &out));
        try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(0xaa)), &out);
    }
    out = @splat(0xaa);
    try std.testing.expectError(error.NoSpaceLeft, formDecodeInto("ab", out[0..1]));
    try std.testing.expectEqual(@as(u8, 0xaa), out[0]);
    var same = "%20".*;
    try std.testing.expectError(error.OverlappingBuffers, percentDecodeInto(&same, same[1..]));
    try std.testing.expectEqualStrings("%20", &same);
    try std.testing.expectEqualStrings(source, "%26%3D%2520%2B+x%00%ff");
}

test "decoded pairs preserve wire order, decoded duplicates, bare and empty fields" {
    const pairs = try parse("&&name=Alice&%6eame=Bob&flag&flag=&=x&=&", .{});
    var it = pairs.decodedIterator(std.testing.allocator, .form);
    const expected = [_]struct { name: []const u8, value: []const u8, has_equals: bool }{
        .{ .name = "name", .value = "Alice", .has_equals = true },
        .{ .name = "name", .value = "Bob", .has_equals = true },
        .{ .name = "flag", .value = "", .has_equals = false },
        .{ .name = "flag", .value = "", .has_equals = true },
        .{ .name = "", .value = "x", .has_equals = true },
        .{ .name = "", .value = "", .has_equals = true },
    };
    for (expected) |item| {
        var pair = (try it.next()).?;
        defer pair.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(item.name, pair.name);
        try std.testing.expectEqualStrings(item.value, pair.value);
        try std.testing.expectEqual(item.has_equals, pair.has_equals);
    }
    try std.testing.expectEqual(null, try it.next());
    try std.testing.expectEqual(null, try it.next());
    try std.testing.expectEqualStrings("Bob", pairs.firstRaw("%6eame").?.value_raw);
}

test "decoded iterator chooses plus policy explicitly and preserves arbitrary bytes" {
    const pairs = try parse("a+b=%26%3D%2520%2B+x%00%ff", .{});
    var percent = pairs.decodedIterator(std.testing.allocator, .percent);
    var form = pairs.decodedIterator(std.testing.allocator, .form);
    var percent_pair = (try percent.next()).?;
    defer percent_pair.deinit(std.testing.allocator);
    var form_pair = (try form.next()).?;
    defer form_pair.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a+b", percent_pair.name);
    try std.testing.expectEqualStrings("&=%20++x\x00\xff", percent_pair.value);
    try std.testing.expectEqualStrings("a b", form_pair.name);
    try std.testing.expectEqualStrings("&=%20+ x\x00\xff", form_pair.value);
}

test "decoded results outlive advancing the iterator and its source bytes" {
    var source = "a=first&b=second".*;
    const pairs = try parse(&source, .{});
    var it = pairs.decodedIterator(std.testing.allocator, .form);
    var first = (try it.next()).?;
    defer first.deinit(std.testing.allocator);
    var second = (try it.next()).?;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(null, try it.next());
    @memset(&source, 'x');
    try std.testing.expectEqualStrings("a", first.name);
    try std.testing.expectEqualStrings("first", first.value);
    try std.testing.expectEqualStrings("b", second.name);
    try std.testing.expectEqualStrings("second", second.value);
}

test "decoded iterator validates both fields before allocation and retains failed position" {
    for ([_][]const u8{ "%=valid", "valid=%", "%GG=x", "a=%2", "a=x%4Z" }) |bad| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        const pairs = try parse(bad, .{});
        var it = pairs.decodedIterator(failing.allocator(), .form);
        try std.testing.expectError(error.InvalidEscape, it.next());
        try std.testing.expectError(error.InvalidEscape, it.next());
        try std.testing.expectEqual(@as(usize, 0), it.pairs.offset);
        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
        try std.testing.expect(!failing.has_induced_failure);
    }
}

test "decoded iterator allocation failure preserves position and previous owned results" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const allocator = failing.allocator();
    const pairs = try parse("a=first&%62=second", .{});
    var it = pairs.decodedIterator(allocator, .form);
    var first = (try it.next()).?;
    defer first.deinit(allocator);
    const offset = it.pairs.offset;
    try std.testing.expectError(error.OutOfMemory, it.next());
    try std.testing.expectEqual(offset, it.pairs.offset);
    try std.testing.expectEqualStrings("first", first.value);
    failing.fail_index = std.math.maxInt(usize);
    var second = (try it.next()).?;
    defer second.deinit(allocator);
    try std.testing.expectEqualStrings("b", second.name);
    try std.testing.expectEqualStrings("second", second.value);
    try std.testing.expectEqual(null, try it.next());
}

test "decoded fields fit raw parse bounds and exact caller allocation budget" {
    const pairs = try parse("%61=%62", .{ .max_bytes = 7, .max_pairs = 1, .max_name_bytes = 3, .max_value_bytes = 3 });
    var scratch: [2]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    var it = pairs.decodedIterator(fixed.allocator(), .form);
    var pair = (try it.next()).?;
    defer pair.deinit(fixed.allocator());
    try std.testing.expectEqualStrings("a", pair.name);
    try std.testing.expectEqualStrings("b", pair.value);
    try std.testing.expectEqual(@as(usize, 2), fixed.end_index);
    try std.testing.expectError(error.NameTooLarge, parse("%61=%62", .{ .max_name_bytes = 2 }));
    try std.testing.expectError(error.ValueTooLarge, parse("%61=%62", .{ .max_value_bytes = 2 }));
}
