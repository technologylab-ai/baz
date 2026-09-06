//! Large immutable asset fixture. The application owns these bytes before startup.
const std = @import("std");
const zli = @import("zli");
const baz = @import("baz");
const support = @import("example_support");

const asset = "\x00\x01\x7f\x80\xffBAZ\r\nasset!" ** (5 * 1024 * 1024 / 16);
const Shared = struct {
    asset_bytes: []const u8 = asset,
    asset_requests: std.atomic.Value(u32) = .init(0),
    markers: std.atomic.Value(u32) = .init(0),
};
const Application = baz.App(Shared);
const Context = Application.Context;

fn borrowed(ctx: *Context) !void {
    _ = ctx.shared.asset_requests.fetchAdd(1, .release);
    try ctx.response.header("X-Asset", "immutable startup storage");
    try ctx.response.borrowBody(200, "application/octet-stream", ctx.shared.asset_bytes);
}

fn copied(ctx: *Context) !void {
    try ctx.response.bytes(200, "application/octet-stream", ctx.shared.asset_bytes);
}

fn ping(ctx: *Context) !void {
    try ctx.response.bytes(204, "text/plain", "");
}

fn marker(ctx: *Context) !void {
    _ = ctx.shared.markers.fetchAdd(1, .release);
    try ping(ctx);
}

fn state(ctx: *Context) !void {
    var count: [16]u8 = undefined;
    try ctx.response.header("X-Asset-Requests", try std.fmt.bufPrint(&count, "{d}", .{ctx.shared.asset_requests.load(.acquire)}));
    try ctx.response.header("X-Markers", try std.fmt.bufPrint(&count, "{d}", .{ctx.shared.markers.load(.acquire)}));
    // Control responses have no body. Their headers still require ordinary copies.
    try ping(ctx);
}

const Options = struct {
    port: u16 = 8080,
    execution: enum { @"inline", workers } = .workers,
    workers: ?u16 = null,
    shards: u8 = 1,
    connections: u16 = 2,
    max_body: u32 = 64 * 1024,
    max_header: u32 = 16 * 1024,
    output_bytes: u32 = 4096,
    response_body: u32 = 1024,
    max_response: usize = 6 * 1024 * 1024,
    timeout_ms: u32 = 5000,
    shutdown_ms: u32 = 5000,
    duration_ms: u32 = 0,
    send_chunk: u32 = 64 * 1024,
    socket_send_buffer: u32 = 64 * 1024,

    pub const help =
        \\ Large borrowed body: GET /asset; HEAD /asset
        \\
        \\ --port N --execution inline|workers --workers N --connections N --shards N
        \\ --max-body N --max-header N --output-bytes N --response-body N --max-response N
        \\ --timeout-ms N --shutdown-ms N --duration-ms N --send-chunk N --socket-send-buffer N
        \\
        \\ Values accept --name value and --name=value.
        \\ Workers default to 2 in workers mode and 0 in inline mode.
        \\ -h, --help shows this help and exits.
    ;
};

pub fn main(init: std.process.Init) !void {
    const options = try zli.parseInit(init, Options);
    var shared: Shared = .{};
    const server: baz.Config = .{
        .port = options.port,
        .execution = switch (options.execution) {
            .@"inline" => .inline_event_loop,
            .workers => .workers,
        },
        .workers = options.workers orelse if (options.execution == .workers) 2 else 0,
        .shards = options.shards,
        .connections = options.connections,
        .max_body = options.max_body,
        .max_header = options.max_header,
        .output_bytes = options.output_bytes,
        .max_response_bytes = options.max_response,
        .timeout_ms = options.timeout_ms,
        .shutdown_ms = options.shutdown_ms,
        .duration_ms = options.duration_ms,
        .send_chunk = options.send_chunk,
        .socket_send_buffer_bytes = options.socket_send_buffer,
        .response_batch_limit = 1,
        .borrow_copy_threshold = 256,
    };
    const limits: baz.ResponseLimits = .{ .body_bytes = options.response_body };
    const app = try Application.init(.{
        .allocator = init.gpa,
        .io = init.io,
        .shared = &shared,
        .server = server,
        .response = limits,
    });
    defer app.deinit();
    try app.route("GET", "/asset", borrowed);
    try app.route("GET", "/copied", copied);
    try app.route("GET", "/ping", ping);
    try app.route("GET", "/marker", marker);
    try app.route("GET", "/state", state);
    try support.run(app, init);
}
