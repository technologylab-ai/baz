const std = @import("std");
const framework = @import("bounded_http");
const api = framework.api;

var active_server: ?*framework.Server = null;

fn signalStop(_: std.posix.SIG) callconv(.c) void {
    // The event loop checks this lock-free flag at least once per poll timeout.
    // No allocation, logging, or framework callback from a signal handler.
    if (active_server) |server| server.stop_requested.store(true, .release);
}

const Demo = struct { html: []const u8, stall_ms: u32, execution: framework.Execution };

pub fn main(init: std.process.Init) !void {
    var config: framework.Config = .{};
    var stall_ms: u32 = 1000;
    var workers_explicit = false;
    var index_path: []const u8 = "assets/index.html";
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |flag| {
        if (std.mem.eql(u8, flag, "--help")) {
            std.debug.print("zig-http: bounded experimental Linux io_uring / macOS kqueue HTTP/1.1\n" ++
                "--port N --connections N --execution workers|inline --workers N --max-body N --max-header N\n" ++
                "--timeout-ms N --duration-ms N --send-chunk N --stall-ms N\n" ++
                "--socket-send-buffer N --output-bytes N --max-response N --memory-budget N --index FILE\n", .{});
            return;
        }
        const value = args.next() orelse return error.MissingArgument;
        if (std.mem.eql(u8, flag, "--port")) {
            config.port = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.eql(u8, flag, "--connections")) {
            config.connections = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.eql(u8, flag, "--execution")) {
            config.execution = if (std.mem.eql(u8, value, "workers")) .workers else if (std.mem.eql(u8, value, "inline")) .inline_event_loop else return error.InvalidExecution;
        } else if (std.mem.eql(u8, flag, "--workers")) {
            workers_explicit = true;
            config.workers = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.eql(u8, flag, "--max-body")) {
            config.max_body = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--max-header")) {
            config.max_header = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--timeout-ms")) {
            config.timeout_ms = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--duration-ms")) {
            config.duration_ms = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--send-chunk")) {
            config.send_chunk = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--socket-send-buffer")) {
            config.socket_send_buffer_bytes = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--stall-ms")) {
            stall_ms = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--output-bytes")) {
            config.output_bytes = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--max-response")) {
            config.max_response_bytes = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, flag, "--memory-budget")) {
            config.memory_budget_bytes = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, flag, "--index")) {
            index_path = value;
        } else return error.UnknownArgument;
    }
    if (config.execution == .inline_event_loop and !workers_explicit) config.workers = 0;
    try config.validate();
    const html = try std.Io.Dir.cwd().readFileAlloc(init.io, index_path, init.gpa, .limited(65536));
    defer init.gpa.free(html);
    var demo: Demo = .{ .html = html, .stall_ms = stall_ms, .execution = config.execution };
    var budget: framework.Budget = .{ .upstream = init.gpa, .limit_bytes = config.memory_budget_bytes - config.workers * config.worker_stack_bytes };
    defer std.debug.assert(budget.live_bytes == 0);
    const server = try framework.Server.init(budget.allocator(), config, handler, &demo);
    defer server.deinit();
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = signalStop },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    active_server = server;
    defer active_server = null;
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
    try server.start();
    budget.sealed.store(true, .release);
    std.debug.print("READY port={d} backend={s} connections={d} workers={d} execution={s} optimize={s}\n", .{
        server.backend.port(), framework.backend_name, config.connections, config.workers, @tagName(config.execution), @tagName(@import("builtin").mode),
    });
    server.run() catch |err| {
        // A stuck callback or uncertain kernel submission still owns memory.
        // Terminate the process; never unwind live loans or kill a worker alone.
        std.debug.print("FATAL {s}; retained loans require process termination\n", .{@errorName(err)});
        std.c._exit(70);
    };
    server.stats.allocation_calls_after_start = budget.late_calls.load(.acquire);
    server.stats.framework_heap_peak_bytes = budget.peak_bytes;
    server.stats.framework_heap_limit_bytes = budget.limit_bytes;
    const stats = try std.json.Stringify.valueAlloc(init.gpa, server.stats, .{});
    defer init.gpa.free(stats);
    std.debug.print("STATS {s}\n", .{stats});
}

fn handler(context: *api.Context) api.Action {
    return handle(context) catch .close;
}

fn handle(context: *api.Context) !api.Action {
    const demo: *const Demo = @ptrCast(@alignCast(context.application.?));
    const writer = context.writer;
    const path = routePath(context.request.target);
    if (std.mem.eql(u8, context.request.method, "CONNECT")) {
        try writer.begin(501, "text/plain", 0);
        return writer.finish();
    }
    if (std.mem.eql(u8, path, "/echo")) {
        if (context.event == .request) try writer.begin(200, "application/octet-stream", context.request.body_bytes);
        var body = context.request.body();
        // Persist an iterator byte offset rather than rescanning prior chunks.
        body.offset = context.state[0];
        body.finished = context.state[1] != 0;
        if (body.next()) |span| {
            context.state[0] = body.offset;
            context.state[1] = @intFromBool(body.finished);
            try writer.borrow(span);
            return writer.flush();
        }
        return writer.finish();
    }
    if (std.mem.eql(u8, path, "/chunks")) {
        if (context.event == .request) try writer.begin(200, "text/plain", null);
        const parts = [_][]const u8{ "first ", "second ", "third" };
        if (context.state[0] < parts.len) {
            const bytes = parts[context.state[0]];
            // Demonstrates filling the framework output buffer in place.
            const destination = try writer.reserve(bytes.len);
            @memcpy(destination, bytes);
            writer.commit(bytes.len);
            context.state[0] += 1;
            return writer.flush();
        }
        return writer.finish();
    }
    if (std.mem.eql(u8, path, "/stall")) {
        // A deliberately blocking demo route violates the inline opt-in
        // contract. Keep this fixture available only in worker execution.
        if (demo.execution == .inline_event_loop) {
            try writer.begin(501, "text/plain", 0);
            return writer.finish();
        }
        var remaining: std.c.timespec = .{ .sec = demo.stall_ms / 1000, .nsec = @as(isize, demo.stall_ms % 1000) * 1_000_000 };
        while (std.c.nanosleep(&remaining, &remaining) != 0) {
            if (context.cancelled.load(.acquire)) return .close;
        }
        if (context.cancelled.load(.acquire)) return .close;
        try writer.begin(200, "text/plain", 4);
        try writer.borrow("done");
        return writer.finish();
    }
    if (std.mem.eql(u8, path, "/plaintext")) {
        try writer.begin(200, "text/plain", 13);
        try writer.borrow("Hello, World!");
    } else if (std.mem.eql(u8, path, "/index.html") or std.mem.eql(u8, path, "/")) {
        try writer.begin(200, "text/html; charset=utf-8", demo.html.len);
        try writer.borrow(demo.html);
    } else {
        try writer.begin(404, "text/plain", 9);
        try writer.borrow("not found");
    }
    return writer.finish();
}

fn routePath(target: []const u8) []const u8 {
    var path = target;
    if (std.ascii.startsWithIgnoreCase(path, "http://") or std.ascii.startsWithIgnoreCase(path, "https://")) {
        const scheme_end = std.mem.find(u8, path, "://").? + 3;
        const authority_end = std.mem.findAny(u8, path[scheme_end..], "/?") orelse return "/";
        path = path[scheme_end + authority_end ..];
        if (path[0] == '?') return "/";
    }
    return path[0 .. std.mem.findScalar(u8, path, '?') orelse path.len];
}
