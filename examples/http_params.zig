//! Zap's parameter example using explicit borrowed bytes. Query and form fields
//! have independent ordered lists; no numeric/bool coercion or bracket arrays.
//! GET /?one=001&string=hello+world&bool=false&flag&tag=a&tag=b
//! POST /?one=query with application/x-www-form-urlencoded body one=form.
const std = @import("std");
const web = @import("http_app");
const support = @import("example_support");

const Shared = struct {};
const Application = web.App(Shared);
const Context = Application.Context;
const limits: web.params.Limits = .{
    .max_bytes = 512,
    .max_pairs = 8,
    .max_name_bytes = 64,
    .max_value_bytes = 128,
};

const Endpoint = struct {
    pub fn get(_: *Endpoint, ctx: *Context) !void {
        return report(ctx, null);
    }

    pub fn post(_: *Endpoint, ctx: *Context) !void {
        // This buffer is only used when HTTP chunk boundaries fragment fields.
        // Both direct views and copied views are consumed before callback return.
        var body: [limits.max_bytes]u8 = undefined;
        const fields = ctx.request.formUrlEncoded(limits) catch |err| switch (err) {
            error.BodyNotContiguous => try web.form.parse(try ctx.request.body().copyTo(&body), limits),
            else => return err,
        };
        return report(ctx, fields);
    }
};

fn report(ctx: *Context, form: ?web.params.Params) !void {
    const query = try ctx.request.queryWithLimits(limits);
    var query_items: [limits.max_pairs]web.params.Param = undefined;
    var form_items: [limits.max_pairs]web.params.Param = undefined;
    const query_list = collect(query, &query_items) orelse return ctx.response.text(400, "this JSON example displays UTF-8 fields only");
    const form_list = if (form) |fields|
        collect(fields, &form_items) orelse return ctx.response.text(400, "this JSON example displays UTF-8 fields only")
    else
        null;

    const Decoded = struct { raw: []const u8, percent_decoded: []const u8, form_decoded: []const u8 };
    var percent: [limits.max_value_bytes]u8 = undefined;
    var form_text: [limits.max_value_bytes]u8 = undefined;
    var string_example: ?Decoded = null;
    if (query.firstRaw("string")) |field| {
        const percent_value = try web.params.percentDecodeInto(field.value_raw, &percent);
        const form_value = try web.params.formDecodeInto(field.value_raw, &form_text);
        // Text validation is this display example's deliberate policy. The
        // underlying query/form/decoder APIs accept and preserve arbitrary bytes.
        if (!std.unicode.utf8ValidateSlice(percent_value) or !std.unicode.utf8ValidateSlice(form_value))
            return ctx.response.text(400, "decoded string is not UTF-8");
        string_example = .{ .raw = field.value_raw, .percent_decoded = percent_value, .form_decoded = form_value };
    }
    return ctx.response.jsonValue(200, .{
        .query = query_list,
        .form = form_list,
        .one_raw = if (query.firstRaw("one")) |field| field.value_raw else null,
        .string = string_example,
    });
}

fn collect(fields: web.params.Params, storage: []web.params.Param) ?[]const web.params.Param {
    var it = fields.iterator();
    var count: usize = 0;
    while (it.next()) |field| {
        if (!std.unicode.utf8ValidateSlice(field.name_raw) or !std.unicode.utf8ValidateSlice(field.value_raw)) return null;
        storage[count] = field;
        count += 1;
    }
    return storage[0..count];
}

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
        .response = .{ .body_bytes = 16384 },
    });
    defer app.deinit();
    try app.endpoint("/", &endpoint);
    try support.run(app, init);
}
