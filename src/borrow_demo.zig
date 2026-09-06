//! Large immutable asset fixture. The application owns these bytes before startup.
const std = @import("std");
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

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    var server: baz.Config = .{
        .port = 8080,
        .shards = 1,
        .connections = 2,
        .execution = .workers,
        .workers = 2,
        .output_bytes = 4096,
        .max_response_bytes = 6 * 1024 * 1024,
        .response_batch_limit = 1,
        .borrow_copy_threshold = 256,
    };
    var limits: baz.ResponseLimits = .{ .body_bytes = 1024 };
    while (args.next()) |flag| {
        if (std.mem.eql(u8, flag, "--help")) {
            std.debug.print("Large borrowed body: GET /asset; HEAD /asset\n" ++
                "--port N --execution inline|workers --workers N --connections N --shards N\n" ++
                "--max-body N --max-header N --output-bytes N --response-body N --max-response N\n" ++
                "--timeout-ms N --shutdown-ms N --duration-ms N --send-chunk N --socket-send-buffer N\n", .{});
            return;
        }
        const value = args.next() orelse return error.MissingArgument;
        if (std.mem.eql(u8, flag, "--port")) {
            server.port = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.eql(u8, flag, "--execution")) {
            if (std.mem.eql(u8, value, "inline")) {
                server.execution = .inline_event_loop;
                server.workers = 0;
            } else if (std.mem.eql(u8, value, "workers")) {
                server.execution = .workers;
                server.workers = 2;
            } else return error.InvalidArgument;
        } else if (std.mem.eql(u8, flag, "--workers")) {
            server.workers = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.eql(u8, flag, "--connections")) {
            server.connections = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.eql(u8, flag, "--shards")) {
            server.shards = try std.fmt.parseInt(u8, value, 10);
        } else if (std.mem.eql(u8, flag, "--max-body")) {
            server.max_body = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--max-header")) {
            server.max_header = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--output-bytes")) {
            server.output_bytes = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--response-body")) {
            limits.body_bytes = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--max-response")) {
            server.max_response_bytes = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, flag, "--timeout-ms")) {
            server.timeout_ms = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--shutdown-ms")) {
            server.shutdown_ms = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--duration-ms")) {
            server.duration_ms = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--send-chunk")) {
            server.send_chunk = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--socket-send-buffer")) {
            server.socket_send_buffer_bytes = try std.fmt.parseInt(u32, value, 10);
        } else return error.InvalidArgument;
    }
    var shared: Shared = .{};
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
