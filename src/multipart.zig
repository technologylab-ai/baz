//! Flat multipart/form-data over a complete contiguous, immutable body.
//! parse() validates the entire body before publishing an iterable view. This
//! modern profile has no preamble/epilogue, nested multipart, or transfer coding.
const std = @import("std");
const form = @import("form.zig");

pub const max_boundary_bytes = 70;
pub const Limits = struct {
    max_bytes: usize = 64 * 1024,
    max_parts: usize = 64,
    max_part_bytes: usize = 64 * 1024,
    /// Includes each header CRLF and the final blank CRLF.
    max_part_header_bytes: usize = 8192,
    max_part_headers: usize = 16,
    max_metadata_parameters: usize = 16,
};
pub const Error = form.MetadataError || error{
    InvalidBoundary,
    InvalidMultipart,
    MultipartTooLarge,
    TooManyParts,
    PartTooLarge,
    PartHeadersTooLarge,
    UnsupportedMultipartEncoding,
};

pub const Part = struct {
    name_raw: []const u8,
    filename_raw: ?[]const u8,
    content_type_raw: ?[]const u8,
    headers_raw: []const u8,
    data: []const u8,
};

pub const Multipart = struct {
    raw: []const u8,
    /// Small fixed parsing metadata, copied so a decoded header boundary does
    /// not need to borrow a caller's temporary buffer. Part data is never copied.
    boundary_bytes: [max_boundary_bytes]u8,
    boundary_len: usize,
    limits: Limits,
    count: usize,

    pub fn iterator(self: Multipart) Iterator {
        return .{ .view = self };
    }
};

pub fn parse(bytes: []const u8, boundary: []const u8, limits: Limits) Error!Multipart {
    if (bytes.len > limits.max_bytes) return error.MultipartTooLarge;
    try validateBoundary(boundary);
    var result: Multipart = .{
        .raw = bytes,
        .boundary_bytes = undefined,
        .boundary_len = boundary.len,
        .limits = limits,
        .count = 0,
    };
    @memcpy(result.boundary_bytes[0..boundary.len], boundary);
    var it = result.iterator();
    while (try it.nextChecked()) |_| {}
    result.count = it.count;
    return result;
}

pub const Iterator = struct {
    view: Multipart,
    offset: usize = 0,
    started: bool = false,
    finished: bool = false,
    count: usize = 0,

    /// Only use views returned by parse(), retaining their immutable input.
    pub fn next(self: *Iterator) ?Part {
        return self.nextChecked() catch unreachable;
    }

    fn nextChecked(self: *Iterator) Error!?Part {
        if (self.finished) return null;
        const bytes = self.view.raw;
        const boundary = self.view.boundary_bytes[0..self.view.boundary_len];
        if (!self.started) {
            self.started = true;
            if (!std.mem.startsWith(u8, bytes, "--") or bytes.len - 2 < boundary.len or
                !std.mem.eql(u8, bytes[2..][0..boundary.len], boundary)) return error.InvalidMultipart;
            const end = 2 + boundary.len;
            if (terminalPrefix(bytes[end..])) {
                if (!terminal(bytes[end..])) return error.InvalidMultipart;
                self.finished = true;
                return null;
            }
            if (!std.mem.startsWith(u8, bytes[end..], "\r\n")) return error.InvalidMultipart;
            self.offset = end + 2;
        }
        if (self.count == self.view.limits.max_parts) return error.TooManyParts;
        const header_start = self.offset;
        var at = header_start;
        var header_count: usize = 0;
        var name: ?[]const u8 = null;
        var filename: ?[]const u8 = null;
        var content_type: ?[]const u8 = null;
        var disposition_seen = false;
        var headers_end = header_start;
        while (true) {
            if (at - header_start > self.view.limits.max_part_header_bytes) return error.PartHeadersTooLarge;
            const budget = self.view.limits.max_part_header_bytes - (at - header_start);
            const window = bytes[at..][0..@min(bytes.len - at, budget)];
            const line_length = std.mem.find(u8, window, "\r\n") orelse {
                if (bytes.len - at >= budget) return error.PartHeadersTooLarge;
                return error.InvalidMultipart;
            };
            const line = bytes[at..][0..line_length];
            at += line_length + 2;
            if (line.len == 0) {
                headers_end = at - 2;
                break;
            }
            if (header_count == self.view.limits.max_part_headers) return error.PartHeadersTooLarge;
            header_count += 1;
            const colon = std.mem.findScalar(u8, line, ':') orelse return error.InvalidMultipart;
            if (colon == 0) return error.InvalidMultipart;
            for (line[0..colon]) |byte| if (!form.token(byte)) return error.InvalidMultipart;
            for (line[colon + 1 ..]) |byte| {
                if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return error.InvalidMultipart;
            }
            const header_name = line[0..colon];
            const value = form.trim(line[colon + 1 ..]);
            const metadata_limits: form.MetadataLimits = .{
                .max_bytes = self.view.limits.max_part_header_bytes,
                .max_parameters = self.view.limits.max_metadata_parameters,
            };
            if (std.ascii.eqlIgnoreCase(header_name, "content-disposition")) {
                if (disposition_seen) return error.InvalidMultipart;
                disposition_seen = true;
                const disposition = try form.disposition(value, metadata_limits);
                if (!disposition.is("form-data")) return error.InvalidMultipart;
                name = (disposition.parameter("name") orelse return error.InvalidMultipart).value_raw;
                if (disposition.parameter("filename")) |parameter| filename = parameter.value_raw;
                if (disposition.parameter("filename*") != null) return error.UnsupportedMultipartEncoding;
            } else if (std.ascii.eqlIgnoreCase(header_name, "content-type")) {
                if (content_type != null) return error.InvalidMultipart;
                const media = try form.mediaType(value, metadata_limits);
                if (media.value_raw.len >= 10 and std.ascii.eqlIgnoreCase(media.value_raw[0..10], "multipart/"))
                    return error.UnsupportedMultipartEncoding;
                content_type = value;
            } else if (std.ascii.eqlIgnoreCase(header_name, "content-transfer-encoding")) {
                return error.UnsupportedMultipartEncoding;
            }
        }
        if (!disposition_seen) return error.InvalidMultipart;
        const payload_start = at;
        // At most one candidate comparison per body byte, each at most 70 bytes.
        // The complete-body and boundary limits bound adversarial near-matches.
        while (std.mem.findPosLinear(u8, bytes, at, "\r\n--")) |marker| {
            const boundary_start = marker + 4;
            at = boundary_start;
            if (bytes.len - boundary_start < boundary.len or
                !std.mem.eql(u8, bytes[boundary_start..][0..boundary.len], boundary)) continue;
            const boundary_end = boundary_start + boundary.len;
            const suffix = bytes[boundary_end..];
            const final = terminalPrefix(suffix);
            if (final and !terminal(suffix)) return error.InvalidMultipart;
            if (!final and !std.mem.startsWith(u8, suffix, "\r\n")) continue;
            const data = bytes[payload_start..marker];
            if (data.len > self.view.limits.max_part_bytes) return error.PartTooLarge;
            self.finished = final;
            self.offset = if (final) bytes.len else boundary_end + 2;
            self.count += 1;
            return .{
                .name_raw = name.?,
                .filename_raw = filename,
                .content_type_raw = content_type,
                .headers_raw = bytes[header_start..headers_end],
                .data = data,
            };
        }
        return error.InvalidMultipart;
    }
};

fn terminal(suffix: []const u8) bool {
    return std.mem.eql(u8, suffix, "--") or std.mem.eql(u8, suffix, "--\r\n");
}

fn terminalPrefix(suffix: []const u8) bool {
    return std.mem.startsWith(u8, suffix, "--") and
        (suffix.len == 2 or std.mem.startsWith(u8, suffix[2..], "\r\n"));
}

pub fn validateBoundary(boundary: []const u8) error{InvalidBoundary}!void {
    if (!validBoundary(boundary)) return error.InvalidBoundary;
}

fn validBoundary(boundary: []const u8) bool {
    if (boundary.len == 0 or boundary.len > max_boundary_bytes or boundary[boundary.len - 1] == ' ') return false;
    for (boundary) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '\'', '(', ')', '+', '_', ',', '-', '.', '/', ':', '=', '?', ' ' => {},
            else => return false,
        }
    }
    return true;
}

test "flat repeated parts retain borrowed raw names and binary data" {
    const bytes = "--bound\r\nContent-Disposition: form-data; name=\"a[]\"\r\n\r\n001\r\n" ++
        "--bound\r\nContent-Disposition: form-data; name=\"a[]\"; filename=\"\"\r\nContent-Type: application/octet-stream\r\n\r\n\x00\xff+%20\r\n" ++
        "--bound\r\nContent-Disposition: form-data; name=\"a[]\"; filename=\"a\\\"b\"\r\n\r\n\r\n--bound--\r\n";
    const multipart = try parse(bytes, "bound", .{});
    try std.testing.expectEqual(@as(usize, 3), multipart.count);
    var it = multipart.iterator();
    const first = it.next().?;
    try std.testing.expectEqualStrings("a[]", first.name_raw);
    try std.testing.expectEqualStrings("001", first.data);
    try std.testing.expectEqual(null, first.filename_raw);
    try std.testing.expectEqual(null, first.content_type_raw);
    const second = it.next().?;
    try std.testing.expectEqualStrings("", second.filename_raw.?);
    try std.testing.expectEqualStrings("\x00\xff+%20", second.data);
    try std.testing.expectEqualStrings("application/octet-stream", second.content_type_raw.?);
    const third = it.next().?;
    try std.testing.expectEqualStrings("a\\\"b", third.filename_raw.?);
    try std.testing.expectEqualStrings("", third.data);
    try std.testing.expectEqual(null, it.next());
    try std.testing.expect(@intFromPtr(second.data.ptr) >= @intFromPtr(bytes.ptr));
    try std.testing.expect(@intFromPtr(second.data.ptr) + second.data.len <= @intFromPtr(bytes.ptr) + bytes.len);
}

test "whole-body validation rejects truncation before returning an iterable view" {
    const bytes = "--B\r\nContent-Disposition: form-data; name=x\r\n\r\nabc\r\n--B--\r\n";
    _ = try parse(bytes, "B", .{});
    for (0..bytes.len - 2) |cut| {
        try std.testing.expectError(error.InvalidMultipart, parse(bytes[0..cut], "B", .{}));
    }
    // A final delimiter without the last CRLF is accepted by this profile.
    _ = try parse(bytes[0 .. bytes.len - 2], "B", .{});
    try std.testing.expectError(error.InvalidMultipart, parse(bytes[0 .. bytes.len - 1], "B", .{}));
    const bad = "--B\r\nContent-Disposition: form-data; name=x\r\n\r\nok\r\n--B\r\nBad\r\n\r\nbad\r\n--B--\r\n";
    try std.testing.expectError(error.InvalidMultipart, parse(bad, "B", .{}));
    const epilogue = "--B\r\nContent-Disposition: form-data; name=x\r\n\r\nok\r\n--B--\r\nepilogue\r\n--B--\r\n";
    try std.testing.expectError(error.InvalidMultipart, parse(epilogue, "B", .{}));
}

test "multipart limits, metadata errors and boundary-like payload" {
    const bytes = "--B\r\nContent-Disposition: form-data; name=x\r\n\r\nabc\r\n--B--\r\n";
    const header_bytes = "Content-Disposition: form-data; name=x\r\n\r\n".len;
    _ = try parse(bytes, "B", .{ .max_bytes = bytes.len, .max_parts = 1, .max_part_bytes = 3, .max_part_header_bytes = header_bytes, .max_part_headers = 1 });
    try std.testing.expectError(error.MultipartTooLarge, parse(bytes, "B", .{ .max_bytes = bytes.len - 1 }));
    try std.testing.expectError(error.TooManyParts, parse(bytes, "B", .{ .max_parts = 0 }));
    try std.testing.expectError(error.PartTooLarge, parse(bytes, "B", .{ .max_part_bytes = 2 }));
    try std.testing.expectError(error.PartHeadersTooLarge, parse(bytes, "B", .{ .max_part_header_bytes = header_bytes - 1 }));
    try std.testing.expectError(error.PartHeadersTooLarge, parse(bytes, "B", .{ .max_part_headers = 0 }));
    try std.testing.expectError(error.InvalidBoundary, parse(bytes, "", .{}));
    try std.testing.expectError(error.InvalidBoundary, parse(bytes, "B ", .{}));
    try std.testing.expectError(error.InvalidBoundary, parse(bytes, &@as([71]u8, @splat('B')), .{}));
    const near = "--B\r\nContent-Disposition: form-data; name=x\r\n\r\na\r\n--BX\r\n--B--x\r\n--B--\r\n";
    var it = (try parse(near, "B", .{})).iterator();
    try std.testing.expectEqualStrings("a\r\n--BX\r\n--B--x", it.next().?.data);
    try std.testing.expectError(error.DuplicateMetadataParameter, parse("--B\r\nContent-Disposition: form-data; name=x; Name=y\r\n\r\na\r\n--B--", "B", .{}));
    try std.testing.expectError(error.UnsupportedMultipartEncoding, parse("--B\r\nContent-Disposition: form-data; name=x\r\nContent-Type: multipart/mixed\r\n\r\na\r\n--B--", "B", .{}));
    try std.testing.expectError(error.UnsupportedMultipartEncoding, parse("--B\r\nContent-Disposition: form-data; name=x\r\nContent-Transfer-Encoding: binary\r\n\r\na\r\n--B--", "B", .{}));
}
