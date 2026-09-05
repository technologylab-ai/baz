const std = @import("std");
const framework = @import("bounded_http");
const api = framework.api;

var active_cluster: ?*framework.Cluster = null;

fn signalStop(_: std.posix.SIG) callconv(.c) void {
    // Every shard's event loop checks its lock-free flag at least once per
    // poll timeout. No allocation, logging, or framework callback here.
    if (active_cluster) |cluster| for (cluster.shards) |server| server.stop_requested.store(true, .release);
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
                "--timeout-ms N --duration-ms N --send-chunk N --gather-send 0|1 --stall-ms N\n" ++
                "--response-batch-limit N --socket-send-buffer N --output-bytes N --max-response N --memory-budget N --index FILE\n" ++
                "--borrow-copy-threshold N --callbacks-per-turn N --callback-timing 0|1 --deadline-sweep-ms N --shards N\n", .{});
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
        } else if (std.mem.eql(u8, flag, "--gather-send")) {
            config.gather_send = if (std.mem.eql(u8, value, "1")) true else if (std.mem.eql(u8, value, "0")) false else return error.InvalidGatherSend;
        } else if (std.mem.eql(u8, flag, "--response-batch-limit")) {
            config.response_batch_limit = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.eql(u8, flag, "--borrow-copy-threshold")) {
            config.borrow_copy_threshold = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--callbacks-per-turn") or std.mem.eql(u8, flag, "--inline-callback-budget")) {
            config.callbacks_per_turn = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--callback-timing")) {
            config.callback_timing = if (std.mem.eql(u8, value, "1")) true else if (std.mem.eql(u8, value, "0")) false else return error.InvalidCallbackTiming;
        } else if (std.mem.eql(u8, flag, "--prearm-receive")) {
            config.prearm_receive = if (std.mem.eql(u8, value, "1")) true else if (std.mem.eql(u8, value, "0")) false else return error.InvalidPrearmReceive;
        } else if (std.mem.eql(u8, flag, "--submit-batch")) {
            config.submit_batch = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.eql(u8, flag, "--deadline-sweep-ms")) {
            config.deadline_sweep_ms = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--shards")) {
            config.shards = try std.fmt.parseInt(u8, value, 10);
        } else if (std.mem.eql(u8, flag, "--shard-affinity")) {
            config.shard_affinity = if (std.mem.eql(u8, value, "1")) true else if (std.mem.eql(u8, value, "0")) false else return error.InvalidShardAffinity;
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
    if (!workers_explicit) config.workers = if (config.execution == .workers) 2 else 0;
    try framework.Cluster.validate(config);
    const shards = framework.Cluster.resolveShards(config);
    const html = try std.Io.Dir.cwd().readFileAlloc(init.io, index_path, init.gpa, .limited(65536));
    defer init.gpa.free(html);
    var demo: Demo = .{ .html = html, .stall_ms = stall_ms, .execution = config.execution };
    var budget: framework.Budget = .{ .upstream = init.gpa, .limit_bytes = config.memory_budget_bytes - try framework.Cluster.stackBytes(config) };
    defer std.debug.assert(budget.live_bytes == 0);
    const cluster = try framework.Cluster.init(budget.allocator(), config, handler, &demo);
    defer cluster.deinit();
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = signalStop },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    active_cluster = cluster;
    defer active_cluster = null;
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
    try cluster.start();
    budget.sealed.store(true, .release);
    std.debug.print("READY port={d} backend={s} connections={d} workers={d} execution={s} gather_send={d} response_batch_limit={d} shards={d} callbacks_per_turn={d} optimize={s}\n", .{
        cluster.port(), framework.backend_name, config.connections, config.workers, @tagName(config.execution), @intFromBool(config.gather_send), config.effectiveBatchLimit(), shards, cluster.shards[0].stats.callbacks_per_turn, @tagName(@import("builtin").mode),
    });
    cluster.run() catch |err| {
        // A stuck callback or uncertain kernel submission still owns memory.
        // Terminate the process; never unwind live loans or kill a worker alone.
        // The counters name the retained owners for the shutdown diagnosis.
        const partial = cluster.stats();
        std.debug.print("FATAL {s}; retained loans require process termination; live_connections={d} live_operations={d}\n", .{ @errorName(err), partial.live_connections, partial.live_operations });
        std.c._exit(70);
    };
    if (cluster.shards.len > 1) {
        // Per-shard admission shows how the kernel distributed connections.
        std.debug.print("SHARDS", .{});
        for (cluster.shards) |shard| std.debug.print(" accepted={d}/completed={d}", .{ shard.stats.accepted, shard.stats.completed });
        std.debug.print("\n", .{});
    }
    var merged = cluster.stats();
    merged.allocation_calls_after_start = budget.late_calls.load(.acquire);
    merged.framework_heap_peak_bytes = budget.peak_bytes;
    merged.framework_heap_limit_bytes = budget.limit_bytes;
    const stats = try std.json.Stringify.valueAlloc(init.gpa, merged, .{});
    defer init.gpa.free(stats);
    std.debug.print("STATS {s}\n", .{stats});
}

fn handler(context: *api.Context) api.Action {
    return handle(context) catch .close;
}

fn handle(context: *api.Context) !api.Action {
    const demo: *const Demo = @ptrCast(@alignCast(context.application.?));
    const writer = context.writer;
    // Exact-target fast path for the measured route; every other form takes
    // the general route resolution below.
    if (api.http.fixedEqual(context.request.target, "/plaintext")) {
        try writer.begin(200, "text/plain", 13);
        try writer.borrow("Hello, World!");
        return writer.finish();
    }
    const path = routePath(context.request.target);
    if (std.mem.eql(u8, context.request.method, "CONNECT")) {
        try writer.begin(501, "text/plain", 0);
        return writer.finish();
    }
    if (std.mem.eql(u8, path, "/borrowed-body") or std.mem.eql(u8, path, "/borrowed-body-chunked")) {
        // Fixed-length bodies form one request-owned span. This route finishes
        // without a flush, allowing multiple distinct borrowed bodies in a
        // batch; /echo demonstrates chunked iteration and flush/resume instead.
        // The chunked variant frames the same borrow with chunk framing, so a
        // cell carries arena bytes around one borrowed span.
        if (context.request.chunked) {
            try writer.begin(501, "text/plain", 0);
            return writer.finish();
        }
        const chunked_output = std.mem.eql(u8, path, "/borrowed-body-chunked");
        try writer.begin(200, "application/octet-stream", if (chunked_output) null else context.request.body_bytes);
        try writer.borrow(context.request.body_wire);
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
    } else if (std.mem.eql(u8, path, "/buffered") or std.mem.eql(u8, path, "/buffered-chunked")) {
        // A generated response exercises the ordinary output arena ownership.
        // Distinct targets make accidental reuse across a pipeline observable.
        // The arena is shared with earlier unsent responses: a reservation that
        // does not fit now flushes the head and retries in an empty arena.
        const target = context.request.target;
        if (context.event == .request) {
            if (target.len > writer.capacity()) {
                try writer.begin(413, "text/plain", 0);
                return writer.finish();
            }
            try writer.begin(200, "text/plain", if (std.mem.eql(u8, path, "/buffered-chunked")) null else target.len);
        }
        const destination = writer.reserve(target.len) catch |err| switch (err) {
            error.WouldBlock => return writer.flush(),
            else => return err,
        };
        @memcpy(destination, target);
        writer.commit(target.len);
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
    // Origin-form targets start with '/'; only other forms can carry a scheme.
    if (target.len != 0 and target[0] != '/' and
        (std.ascii.startsWithIgnoreCase(path, "http://") or std.ascii.startsWithIgnoreCase(path, "https://")))
    {
        const scheme_end = std.mem.find(u8, path, "://").? + 3;
        const authority_end = std.mem.findAny(u8, path[scheme_end..], "/?") orelse return "/";
        path = path[scheme_end + authority_end ..];
        if (path[0] == '?') return "/";
    }
    return path[0 .. std.mem.findScalar(u8, path, '?') orelse path.len];
}
