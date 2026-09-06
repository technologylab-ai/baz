//! Explicit URL-encoded pairs and bounded MIME metadata parsing. Values stay raw.
const std = @import("std");
pub const params = @import("params.zig");
pub const Limits = params.Limits;
pub const parse = params.parse;

pub const MetadataLimits = struct {
    max_bytes: usize = 8192,
    max_parameters: usize = 16,
};
pub const MetadataError = error{ InvalidMetadata, MetadataTooLarge, TooManyMetadataParameters, DuplicateMetadataParameter };
pub const UnquoteError = error{ InvalidQuotedPair, NoSpaceLeft, OverlappingBuffers };

pub const Parameter = struct {
    name_raw: []const u8,
    /// Surrounding quotes are excluded; quoted-pair escapes remain untouched.
    value_raw: []const u8,
    quoted: bool,
};

/// Returned only after the entire value and parameter list have been validated.
pub const Metadata = struct {
    value_raw: []const u8,
    parameters_raw: []const u8,
    parameter_count: usize,

    pub fn is(self: Metadata, expected: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.value_raw, expected);
    }

    pub fn parameters(self: Metadata) ParameterIterator {
        return .{ .raw = self.parameters_raw };
    }

    pub fn parameter(self: Metadata, name: []const u8) ?Parameter {
        var it = self.parameters();
        while (it.next()) |item| {
            if (std.ascii.eqlIgnoreCase(name, item.name_raw)) return item;
        }
        return null;
    }
};

pub const ParameterIterator = struct {
    raw: []const u8,
    offset: usize = 0,

    /// The constructor validated this immutable metadata. Mutation of its input
    /// while the view is alive violates the borrowing contract.
    pub fn next(self: *ParameterIterator) ?Parameter {
        return nextParameter(self.raw, &self.offset) catch unreachable;
    }
};

pub fn mediaType(bytes: []const u8, limits: MetadataLimits) MetadataError!Metadata {
    return metadata(bytes, limits, true);
}

pub fn disposition(bytes: []const u8, limits: MetadataLimits) MetadataError!Metadata {
    return metadata(bytes, limits, false);
}

fn metadata(bytes: []const u8, limits: MetadataLimits, media: bool) MetadataError!Metadata {
    if (bytes.len > limits.max_bytes) return error.MetadataTooLarge;
    const raw = trim(bytes);
    var at: usize = 0;
    while (at < raw.len and token(raw[at])) : (at += 1) {}
    if (at == 0) return error.InvalidMetadata;
    if (media) {
        if (at == raw.len or raw[at] != '/') return error.InvalidMetadata;
        at += 1;
        const subtype_start = at;
        while (at < raw.len and token(raw[at])) : (at += 1) {}
        if (at == subtype_start) return error.InvalidMetadata;
    }
    const value = raw[0..at];
    const parameter_bytes = raw[at..];
    var offset: usize = 0;
    var count: usize = 0;
    while (try nextParameter(parameter_bytes, &offset)) |item| {
        if (count == limits.max_parameters) return error.TooManyMetadataParameters;
        // The parameter count is explicit and finite. Reject duplicate names
        // case-insensitively instead of inventing first/last-wins MIME semantics.
        var earlier: usize = 0;
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const previous = (try nextParameter(parameter_bytes, &earlier)).?;
            if (std.ascii.eqlIgnoreCase(previous.name_raw, item.name_raw)) return error.DuplicateMetadataParameter;
        }
        count += 1;
    }
    return .{ .value_raw = value, .parameters_raw = parameter_bytes, .parameter_count = count };
}

fn nextParameter(raw: []const u8, offset: *usize) MetadataError!?Parameter {
    var at = offset.*;
    while (at < raw.len and ows(raw[at])) : (at += 1) {}
    if (at == raw.len) {
        offset.* = at;
        return null;
    }
    if (raw[at] != ';') return error.InvalidMetadata;
    at += 1;
    while (at < raw.len and ows(raw[at])) : (at += 1) {}
    const name_start = at;
    while (at < raw.len and token(raw[at])) : (at += 1) {}
    if (at == name_start) return error.InvalidMetadata;
    const name = raw[name_start..at];
    while (at < raw.len and ows(raw[at])) : (at += 1) {}
    if (at == raw.len or raw[at] != '=') return error.InvalidMetadata;
    at += 1;
    while (at < raw.len and ows(raw[at])) : (at += 1) {}
    if (at == raw.len) return error.InvalidMetadata;
    const quoted = raw[at] == '"';
    if (quoted) at += 1;
    const value_start = at;
    if (quoted) {
        while (at < raw.len and raw[at] != '"') {
            if (raw[at] == '\\') {
                at += 1;
                if (at == raw.len or !quotedByte(raw[at])) return error.InvalidMetadata;
            } else if (!quotedByte(raw[at])) return error.InvalidMetadata;
            at += 1;
        }
        if (at == raw.len) return error.InvalidMetadata;
    } else {
        while (at < raw.len and token(raw[at])) : (at += 1) {}
        if (at == value_start) return error.InvalidMetadata;
    }
    const value = raw[value_start..at];
    if (quoted) at += 1;
    while (at < raw.len and ows(raw[at])) : (at += 1) {}
    if (at < raw.len and raw[at] != ';') return error.InvalidMetadata;
    offset.* = at;
    return .{ .name_raw = name, .value_raw = value, .quoted = quoted };
}

/// Unescape raw quoted metadata after outer quotes have been removed. This does
/// no percent/charset decoding. On failure source and destination are unchanged.
pub fn unquoteInto(source: []const u8, destination: []u8) UnquoteError![]u8 {
    if (params.overlap(source, destination)) return error.OverlappingBuffers;
    var at: usize = 0;
    var length: usize = 0;
    while (at < source.len) : (at += 1) {
        if (source[at] == '\\') {
            at += 1;
            if (at == source.len or !quotedByte(source[at])) return error.InvalidQuotedPair;
        } else if (!quotedByte(source[at]) or source[at] == '"') return error.InvalidQuotedPair;
        length += 1;
    }
    if (length > destination.len) return error.NoSpaceLeft;
    at = 0;
    var output: usize = 0;
    while (at < source.len) : (at += 1) {
        if (source[at] == '\\') at += 1;
        destination[output] = source[at];
        output += 1;
    }
    return destination[0..length];
}

pub fn token(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

pub fn trim(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, " \t");
}

fn ows(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn quotedByte(byte: u8) bool {
    return byte == '\t' or (byte >= 0x20 and byte != 0x7f);
}

test "media types preserve raw values and validate quoted parameters and duplicates" {
    const raw = " Application/X-Www-Form-Urlencoded ; Charset=\"UTF-8\"; x=\"a\\\"b\" \t";
    const value = try mediaType(raw, .{});
    try std.testing.expect(value.is("application/x-www-form-urlencoded"));
    try std.testing.expectEqualStrings("UTF-8", value.parameter("charset").?.value_raw);
    try std.testing.expect(value.parameter("charset").?.quoted);
    try std.testing.expectEqualStrings("a\\\"b", value.parameter("x").?.value_raw);
    var decoded: [8]u8 = undefined;
    try std.testing.expectEqualStrings("a\"b", try unquoteInto(value.parameter("x").?.value_raw, &decoded));
    for ([_][]const u8{ "", "text", "text/", "text/plain, text/html", "text/plain;", "text/plain; a=", "text/plain; a=\"unterminated", "text/plain; a=\"x\r\n\"", "text/plain; a=\"x\"oops" }) |bad|
        try std.testing.expectError(error.InvalidMetadata, mediaType(bad, .{}));
    try std.testing.expectError(error.DuplicateMetadataParameter, mediaType("text/plain; a=1; A=2", .{}));
    try std.testing.expectError(error.MetadataTooLarge, mediaType("text/plain", .{ .max_bytes = 9 }));
    try std.testing.expectError(error.TooManyMetadataParameters, mediaType("text/plain; a=1", .{ .max_parameters = 0 }));
    const disp = try disposition("form-data; name=\"\"; filename=\"a\\\\b\"", .{});
    try std.testing.expectEqualStrings("", disp.parameter("name").?.value_raw);
    try std.testing.expectEqualStrings("a\\b", try unquoteInto(disp.parameter("filename").?.value_raw, &decoded));
}

test "unquoting is explicit, preserves plus/percent bytes, and is atomic on error" {
    var out: [8]u8 = @splat(0xaa);
    try std.testing.expectEqualStrings("%20+x", try unquoteInto("%20+x", &out));
    out = @splat(0xaa);
    try std.testing.expectError(error.InvalidQuotedPair, unquoteInto("a\\", &out));
    try std.testing.expectEqual(@as(u8, 0xaa), out[0]);
    try std.testing.expectError(error.NoSpaceLeft, unquoteInto("a\\\"b", out[0..2]));
    try std.testing.expectEqual(@as(u8, 0xaa), out[0]);
    var same = "ab".*;
    try std.testing.expectError(error.OverlappingBuffers, unquoteInto(&same, &same));
}
