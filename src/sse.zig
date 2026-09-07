//! Server-sent event encoding for bounded response writers. No allocation or flush.
//! The caller sets input bounds, response capacity, publication, and replay policy.
//! Format: https://html.spec.whatwg.org/multipage/server-sent-events.html
const std = @import("std");

pub const content_type = "text/event-stream; charset=utf-8";

pub const ValidationError = error{ InvalidUtf8, InvalidEventName, InvalidEventId };
pub const Error = ValidationError || std.Io.Writer.Error;

pub const Event = struct {
    /// Empty data dispatches an empty event. CRLF and CR become LF in received data.
    data: []const u8,
    /// Null or empty selects the browser's default "message" event type.
    event: ?[]const u8 = null,
    /// Null preserves the previous ID. Empty resets the browser's last event ID.
    id: ?[]const u8 = null,
    /// A browser reconnect hint in milliseconds. Zero is valid. No replay is implied.
    retry_ms: ?u32 = null,
};

/// Validate every field before writing. Invalid input leaves the writer unchanged.
/// Writer errors can leave partial output. The caller must end a failed stream.
/// This function does not flush. A continuation publishes with `.flush` after this call.
pub fn write(writer: *std.Io.Writer, event: Event) Error!void {
    try validateUtf8(event.data);
    if (event.event) |name| {
        try validateUtf8(name);
        if (hasLineEnding(name)) return error.InvalidEventName;
    }
    if (event.id) |id| try validateId(id);

    if (event.event) |name| try field(writer, "event: ", name);
    if (event.id) |id| try field(writer, "id: ", id);
    if (event.retry_ms) |retry| try writer.print("retry: {d}\n", .{retry});
    try lines(writer, "data: ", event.data);
    try writer.writeByte('\n');
}

/// Write a comment block. Browsers do not dispatch comments as application events.
/// Each input line gets a colon prefix. Comments cannot inject event fields.
pub fn comment(writer: *std.Io.Writer, text: []const u8) Error!void {
    try validateUtf8(text);
    try lines(writer, ": ", text);
    try writer.writeByte('\n');
}

/// Write an empty comment block. The caller schedules and publishes each heartbeat.
pub fn heartbeat(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(":\n\n");
}

/// Validate an event ID or a borrowed Last-Event-ID value. No decoding occurs.
/// The caller rejects duplicate headers and applies application-specific ID bounds.
pub fn validateId(id: []const u8) ValidationError!void {
    try validateUtf8(id);
    if (hasLineEnding(id) or std.mem.findScalar(u8, id, 0) != null) return error.InvalidEventId;
}

fn validateUtf8(text: []const u8) error{InvalidUtf8}!void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
}

fn hasLineEnding(text: []const u8) bool {
    return std.mem.findAny(u8, text, "\r\n") != null;
}

fn field(writer: *std.Io.Writer, prefix: []const u8, text: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll(prefix);
    try writer.writeAll(text);
    try writer.writeByte('\n');
}

fn lines(writer: *std.Io.Writer, prefix: []const u8, text: []const u8) std.Io.Writer.Error!void {
    var start: usize = 0;
    while (true) {
        const end = std.mem.findAnyPos(u8, text, start, "\r\n") orelse text.len;
        try field(writer, prefix, text[start..end]);
        if (end == text.len) return;
        start = end + 1;
        if (text[end] == '\r' and start < text.len and text[start] == '\n') start += 1;
    }
}

test "event metadata, UTF-8, leading spaces and reserved punctuation stay literal" {
    var storage: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try write(&writer, .{
        .data = "  Grüße: \u{1f405}\x00",
        .event = " progress:更新",
        .id = " 42:α",
        .retry_ms = 1500,
    });
    try std.testing.expectEqualStrings(
        "event:  progress:更新\nid:  42:α\nretry: 1500\ndata:   Grüße: \u{1f405}\x00\n\n",
        writer.buffered(),
    );
}

test "all line endings produce data fields and preserve trailing logical newlines" {
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "", .expected = "data: \n\n" },
        .{ .input = "a\nb", .expected = "data: a\ndata: b\n\n" },
        .{ .input = "a\rb", .expected = "data: a\ndata: b\n\n" },
        .{ .input = "a\r\nb", .expected = "data: a\ndata: b\n\n" },
        .{ .input = "a\r\n", .expected = "data: a\ndata: \n\n" },
        .{ .input = "\r\n\r\n", .expected = "data: \ndata: \ndata: \n\n" },
        .{ .input = "\n\r", .expected = "data: \ndata: \ndata: \n\n" },
        .{ .input = "x\n\nid: forged\nretry: 0", .expected = "data: x\ndata: \ndata: id: forged\ndata: retry: 0\n\n" },
    };
    for (cases) |case| {
        var storage: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&storage);
        try write(&writer, .{ .data = case.input });
        try std.testing.expectEqualStrings(case.expected, writer.buffered());
    }
}

test "omitted ID preserves cursor and empty ID resets it without losing empty events" {
    var storage: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try write(&writer, .{ .data = "one", .id = "9" });
    try write(&writer, .{ .data = "" });
    try write(&writer, .{ .data = "", .id = "", .event = "", .retry_ms = 0 });
    try std.testing.expectEqualStrings(
        "id: 9\ndata: one\n\ndata: \n\nevent: \nid: \nretry: 0\ndata: \n\n",
        writer.buffered(),
    );
}

test "invalid fields fail before any output including fields validated last" {
    const cases = [_]struct { event: Event, failure: ValidationError }{
        .{ .event = .{ .data = "\xc0\x80" }, .failure = error.InvalidUtf8 },
        .{ .event = .{ .data = "ok", .event = "\xed\xa0\x80" }, .failure = error.InvalidUtf8 },
        .{ .event = .{ .data = "ok", .event = "a\nb" }, .failure = error.InvalidEventName },
        .{ .event = .{ .data = "ok", .event = "a\rb" }, .failure = error.InvalidEventName },
        .{ .event = .{ .data = "ok", .event = "valid", .id = "\xff" }, .failure = error.InvalidUtf8 },
        .{ .event = .{ .data = "ok", .event = "valid", .id = "a\x00b" }, .failure = error.InvalidEventId },
        .{ .event = .{ .data = "ok", .event = "valid", .id = "a\nb" }, .failure = error.InvalidEventId },
        .{ .event = .{ .data = "ok", .event = "valid", .id = "a\rb" }, .failure = error.InvalidEventId },
    };
    for (cases) |case| {
        var storage: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&storage);
        try writer.writeAll("previous\n\n");
        try std.testing.expectError(case.failure, write(&writer, case.event));
        try std.testing.expectEqualStrings("previous\n\n", writer.buffered());
    }
}

test "comments and heartbeats never inject application events" {
    var storage: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try heartbeat(&writer);
    try comment(&writer, "healthy\r\ndata: forged\r\n\n");
    try std.testing.expectEqualStrings(":\n\n: healthy\n: data: forged\n: \n: \n\n", writer.buffered());
    const before = writer.end;
    try std.testing.expectError(error.InvalidUtf8, comment(&writer, "bad\xff"));
    try std.testing.expectEqual(before, writer.end);
}

test "writer capacity stays authoritative and write errors propagate" {
    var exact: [9]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&exact);
    try write(&writer, .{ .data = "x" });
    try std.testing.expectEqualStrings("data: x\n\n", writer.buffered());
    try std.testing.expectError(error.WriteFailed, heartbeat(&writer));

    var short: [8]u8 = undefined;
    var limited: std.Io.Writer = .fixed(&short);
    try std.testing.expectError(error.WriteFailed, write(&limited, .{ .data = "x" }));
    try std.testing.expect(limited.end <= short.len);
}

test "maximum retry uses decimal digits and ID validation borrows without conversion" {
    var storage: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try write(&writer, .{ .data = "", .retry_ms = std.math.maxInt(u32) });
    try std.testing.expectEqualStrings("retry: 4294967295\ndata: \n\n", writer.buffered());
    try validateId("%0A+42:東京");
    try validateId("");
    try std.testing.expectError(error.InvalidEventId, validateId("bad\x00"));
    try std.testing.expectError(error.InvalidUtf8, validateId("\xf4\x90\x80\x80"));
}
