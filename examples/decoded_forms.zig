//! Ordered decoded fields using an explicit, per-request application allocator.
const std = @import("std");
const web = @import("baz");
const support = @import("example_support");

const Shared = struct { allocator: std.mem.Allocator };
const Application = web.App(Shared);
const limits: web.params.Limits = .{ .max_bytes = 4096, .max_pairs = 16, .max_name_bytes = 128, .max_value_bytes = 1024 };

fn form(ctx: *Application.Context) !void {
    // General allocator work is explicit application work on a fixed worker.
    _ = try ctx.serviceIo();
    var arena = std.heap.ArenaAllocator.init(ctx.shared.allocator);
    defer arena.deinit();
    var body: [limits.max_bytes]u8 = undefined;
    const fields = ctx.request.formUrlEncoded(limits) catch |err| switch (err) {
        error.BodyNotContiguous => try web.form.parse(try ctx.request.body().copyTo(&body), limits),
        else => return err,
    };
    const Field = struct { name: []const u8, value: []const u8, has_equals: bool };
    var output: [limits.max_pairs]Field = undefined;
    var count: usize = 0;
    var it = fields.decodedIterator(arena.allocator(), .form);
    while (try it.next()) |field| {
        // The decoder accepts bytes. This JSON display deliberately requires UTF-8.
        if (!std.unicode.utf8ValidateSlice(field.name) or !std.unicode.utf8ValidateSlice(field.value))
            return ctx.response.text(400, "This example displays UTF-8 fields only");
        output[count] = .{ .name = field.name, .value = field.value, .has_equals = field.has_equals };
        count += 1;
    }
    // Earlier fields stay valid after next(). jsonValue copies before arena teardown.
    try ctx.response.jsonValue(200, .{ .fields = output[0..count] });
}

pub fn main(init: std.process.Init) !void {
    var config = try support.workerConfig(init);
    config.max_body = limits.max_bytes;
    var shared: Shared = .{ .allocator = init.gpa };
    const app = try Application.init(.{
        .allocator = init.gpa,
        .io = init.io,
        .shared = &shared,
        .server = config,
        .response = .{ .body_bytes = 32768 },
    });
    defer app.deinit();
    try app.route("POST", "/", form);
    try support.run(app, init);
}
