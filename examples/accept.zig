//! Bounded content negotiation for the original five representations. Supported
//! profile: media ranges, wildcards and one optional q parameter (0..1, at most
//! three decimals). Other media parameters/extensions return 400 explicitly.
//! Repeated Accept fields are processed in wire order, with at most 32 ranges
//! and 4096 aggregate value bytes. This is example policy, not a general parser.
const std = @import("std");
const web = @import("http_app");
const support = @import("example_support");

const Shared = struct {};
const Application = web.App(Shared);
const content_types = [_][]const u8{
    "text/html",
    "text/plain",
    "application/json",
    "application/xml",
    "application/xhtml+xml",
};
const Preference = struct { specificity: i8 = -1, quality: u16 = 0 };
const NegotiationError = error{ InvalidAccept, AcceptTooLarge };

fn trim(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, " \t");
}

fn token(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
        else => return false,
    };
    return true;
}

fn quality(bytes: []const u8) NegotiationError!u16 {
    if (bytes.len == 0 or (bytes[0] != '0' and bytes[0] != '1')) return error.InvalidAccept;
    if (bytes.len == 1) return if (bytes[0] == '1') 1000 else 0;
    if (bytes[1] != '.' or bytes.len > 5) return error.InvalidAccept;
    var value: u16 = 0;
    var scale: u16 = 100;
    for (bytes[2..]) |digit| {
        if (digit < '0' or digit > '9' or (bytes[0] == '1' and digit != '0')) return error.InvalidAccept;
        value += @as(u16, digit - '0') * scale;
        scale /= 10;
    }
    return if (bytes[0] == '1') 1000 else value;
}

fn addRange(raw: []const u8, preferences: *[content_types.len]Preference) NegotiationError!void {
    var pieces = std.mem.splitScalar(u8, raw, ';');
    const media = trim(pieces.next().?);
    const slash = std.mem.findScalar(u8, media, '/') orelse return error.InvalidAccept;
    const kind = media[0..slash];
    const subtype = media[slash + 1 ..];
    if (!token(kind) or !token(subtype)) return error.InvalidAccept;
    if ((std.mem.findScalar(u8, kind, '*') != null and !std.mem.eql(u8, kind, "*")) or
        (std.mem.findScalar(u8, subtype, '*') != null and !std.mem.eql(u8, subtype, "*")) or
        (std.mem.eql(u8, kind, "*") and !std.mem.eql(u8, subtype, "*"))) return error.InvalidAccept;
    var q: u16 = 1000;
    var q_seen = false;
    while (pieces.next()) |parameter| {
        const pair = trim(parameter);
        const equals = std.mem.findScalar(u8, pair, '=') orelse return error.InvalidAccept;
        if (q_seen or !std.ascii.eqlIgnoreCase(trim(pair[0..equals]), "q")) return error.InvalidAccept;
        q = try quality(trim(pair[equals + 1 ..]));
        q_seen = true;
    }
    for (content_types, preferences) |content_type, *preference| {
        const separator = std.mem.findScalar(u8, content_type, '/').?;
        const specificity: i8 = if (std.mem.eql(u8, kind, "*"))
            0
        else if (!std.ascii.eqlIgnoreCase(kind, content_type[0..separator]))
            continue
        else if (std.mem.eql(u8, subtype, "*"))
            1
        else if (std.ascii.eqlIgnoreCase(subtype, content_type[separator + 1 ..]))
            2
        else
            continue;
        // A specific exclusion overrides a broader wildcard, even when its q
        // is zero. Equal-specificity duplicates use the first entry by policy.
        if (specificity > preference.specificity) preference.* = .{ .specificity = specificity, .quality = q };
    }
}

fn negotiate(request: web.Request) NegotiationError!?usize {
    var preferences: [content_types.len]Preference = @splat(.{});
    var headers = request.headers();
    var seen = false;
    var bytes: usize = 0;
    var ranges: usize = 0;
    while (headers.next()) |field| {
        if (!std.ascii.eqlIgnoreCase(field.name_raw, "Accept")) continue;
        seen = true;
        if (field.value_raw.len > 4096 - bytes) return error.AcceptTooLarge;
        bytes += field.value_raw.len;
        var list = std.mem.splitScalar(u8, field.value_raw, ',');
        while (list.next()) |item| {
            const raw = trim(item);
            if (raw.len == 0) continue;
            if (ranges == 32) return error.AcceptTooLarge;
            ranges += 1;
            try addRange(raw, &preferences);
        }
    }
    if (!seen) return 0; // Server preference is HTML when Accept is absent.
    var best: ?usize = null;
    var best_quality: u16 = 0;
    for (preferences, 0..) |preference, index| {
        if (preference.quality > best_quality) {
            best = index;
            best_quality = preference.quality;
        }
    }
    return best;
}

fn hello(ctx: *Application.Context) !void {
    try ctx.response.header("Vary", "Accept");
    const index = (negotiate(ctx.request) catch |err| return ctx.response.text(switch (err) {
        error.InvalidAccept => 400,
        error.AcceptTooLarge => 431,
    }, @errorName(err))) orelse return ctx.response.text(406, "no acceptable representation");
    switch (index) {
        0 => return ctx.response.bytes(200, content_types[index], "<html><body><h1>Hello from zig-http!!!</h1></body></html>"),
        1 => return ctx.response.bytes(200, content_types[index], "Hello from zig-http!!!"),
        2 => return ctx.response.jsonValue(200, .{ .message = "Hello from zig-http!!!" }),
        3 => return ctx.response.bytes(200, content_types[index], "<?xml version=\"1.0\" encoding=\"UTF-8\"?><message><warning>Hello from zig-http!!!</warning></message>"),
        4 => return ctx.response.bytes(200, content_types[index], "<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" xml:lang=\"en-US\"><body><h1>Hello from zig-http!!!</h1></body></html>"),
        else => unreachable,
    }
}

pub fn main(init: std.process.Init) !void {
    var shared: Shared = .{};
    const app = try Application.init(.{ .allocator = init.gpa, .io = init.io, .shared = &shared, .server = try support.config(init) });
    defer app.deinit();
    try app.route("GET", "/", hello);
    try support.run(app, init);
}
