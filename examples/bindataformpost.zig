//! Zap's binary form example with one flat Part iterator for one/many uploads.
//! POST / using curl -F img=@some-file -F img=@another-file http://localhost:8080/
//! Up to 32 KiB body / 8 parts; binary content is shown as a bounded hex preview.
const std = @import("std");
const web = @import("baz");
const support = @import("example_support");

const Shared = struct {};
const Application = web.App(Shared);
const Context = Application.Context;
const limits: web.multipart.Limits = .{
    .max_bytes = 32 * 1024,
    .max_parts = 8,
    .max_part_bytes = 32 * 1024,
    .max_part_header_bytes = 512,
    .max_part_headers = 4,
};
const preview_bytes = 64;

const Endpoint = struct {
    pub fn get(_: *Endpoint, ctx: *Context) !void {
        return ctx.response.text(200, "POST multipart/form-data here: curl -F img=@file1 -F img=@file2 http://127.0.0.1:8080/\nLimits: 32768 body bytes, 8 parts, 512 header bytes per part. Files are never saved implicitly.\n");
    }

    pub fn post(_: *Endpoint, ctx: *Context) !void {
        var body: [limits.max_bytes]u8 = undefined;
        const parts = ctx.request.formMultipart(limits) catch |err| switch (err) {
            error.BodyNotContiguous => blk: {
                var boundary: [web.multipart.max_boundary_bytes]u8 = undefined;
                const decoded = try ctx.request.multipartBoundaryInto(&boundary);
                const copied = try ctx.request.body().copyTo(&body);
                break :blk try web.multipart.parse(copied, decoded, limits);
            },
            else => return err,
        };

        const Summary = struct {
            name_raw: []const u8,
            filename_raw: ?[]const u8,
            content_type_raw: ?[]const u8,
            size: usize,
            byte_sum: u64,
            data_preview_hex: []const u8,
            preview_complete: bool,
        };
        var summaries: [limits.max_parts]Summary = undefined;
        var previews: [limits.max_parts][preview_bytes * 2]u8 = undefined;
        var it = parts.iterator();
        var count: usize = 0;
        // parse() already validated all parts and the terminal boundary. No
        // special branch depends on whether a field contains one or many files.
        while (it.next()) |part| {
            // The binary payload is never interpreted as text. This JSON display
            // explicitly requires UTF-8 only for the metadata it prints.
            if (!std.unicode.utf8ValidateSlice(part.name_raw) or
                (part.filename_raw != null and !std.unicode.utf8ValidateSlice(part.filename_raw.?)) or
                (part.content_type_raw != null and !std.unicode.utf8ValidateSlice(part.content_type_raw.?)))
                return ctx.response.text(400, "this JSON example displays UTF-8 metadata only");
            var sum: u64 = 0;
            for (part.data) |byte| sum += byte;
            const shown = part.data[0..@min(part.data.len, preview_bytes)];
            const hex = "0123456789abcdef";
            for (shown, 0..) |byte, index| {
                previews[count][index * 2] = hex[byte >> 4];
                previews[count][index * 2 + 1] = hex[byte & 15];
            }
            summaries[count] = .{
                .name_raw = part.name_raw,
                .filename_raw = part.filename_raw,
                .content_type_raw = part.content_type_raw,
                .size = part.data.len,
                .byte_sum = sum,
                .data_preview_hex = previews[count][0 .. shown.len * 2],
                .preview_complete = shown.len == part.data.len,
            };
            count += 1;
        }
        // jsonValue serializes/copies these stack-backed summaries immediately.
        return ctx.response.jsonValue(200, .{ .ok = true, .parts = summaries[0..count] });
    }
};

pub fn main(init: std.process.Init) !void {
    var shared: Shared = .{};
    var endpoint: Endpoint = .{};
    var config = try support.config(init);
    config.max_body = limits.max_bytes;
    const app = try Application.init(.{
        .allocator = init.gpa,
        .io = init.io,
        .shared = &shared,
        .server = config,
        .response = .{ .body_bytes = 32768 },
    });
    defer app.deinit();
    try app.endpoint("/", &endpoint);
    try support.run(app, init);
}
