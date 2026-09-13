//! Download a runtime-opened file with fixed copy scratch on application workers.
//! The operator chooses the path at startup; request paths never select files.
const std = @import("std");
const web = @import("baz");
const support = @import("example_support");

const maximum = 64 * 1024 * 1024;
const Options = struct {
    port: u16 = 8080,
    bind_address: []const u8 = "127.0.0.1",
    duration_ms: u32 = 0,
    execution: enum { @"inline", workers } = .workers,
    workers: ?u16 = null,
    connections: u16 = 16,
    shards: u8 = 1,
    file: []const u8 = "examples/assets/sendfile.txt",

    pub const aliases = .{ .port = "p" };
    pub const help = support.Options(true).help ++
        \\
        \\      --file PATH               File to download at /download (opened per request)
        \\Default: examples/assets/sendfile.txt; maximum response: 64 MiB.
    ;
};
const Shared = struct { path: []const u8 };
const Application = web.App(Shared);

fn download(ctx: *Application.Context) !void {
    const io = try ctx.serviceIo();
    const file = try std.Io.Dir.cwd().openFile(io, ctx.shared.path, .{});
    defer file.close(io);
    const size = (try file.stat(io)).size;
    if (size > maximum) return error.FileTooLarge;
    try ctx.response.header("Content-Disposition", "attachment; filename=download.bin");
    try ctx.response.header("Accept-Ranges", "none");
    var stream = try ctx.response.stream(200, "application/octet-stream", .{
        .content_length = @intCast(size),
    });
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    var scratch: [16384]u8 = undefined;
    _ = stream.copyFrom(&reader.interface, &scratch) catch |err| {
        // Generic readers report ReadFailed; the concrete file reader retains
        // the underlying I/O diagnostic. Stream failures remain sticky too.
        if (err == error.ReadFailed) return reader.err orelse err;
        return err;
    };
    try stream.finish();
    // Copied bytes belong to the response. The file can close before the final
    // transport send. HEAD follows this handler, but transmits no file payload.
}

pub fn main(init: std.process.Init) !void {
    const options = try support.parseOptions(init, Options);
    var config = try support.configFromOptions(options, true);
    config.max_response_bytes = maximum;
    var shared: Shared = .{ .path = options.file };
    const app = try Application.init(.{
        .allocator = init.gpa,
        .io = init.io,
        .shared = &shared,
        .server = config,
        .response = .{ .body_bytes = 8192 },
    });
    defer app.deinit();
    try app.route("GET", "/download", download);
    try support.run(app, init);
}
