//! Streaming example and bounded wire-test fixture. Each stream occupies one worker.
const std = @import("std");
const web = @import("baz");
const builtin = @import("builtin");
const win32 = struct {
    extern "kernel32" fn SetConsoleCtrlHandler(?*const fn (u32) callconv(.winapi) i32, i32) callconv(.winapi) i32;
};

const Shared = struct {
    released: std.atomic.Value(bool) = .init(false),
    started: std.atomic.Value(u32) = .init(0),
    finished: std.atomic.Value(u32) = .init(0),
    sleep_started: std.atomic.Value(u32) = .init(0),
    sleep_canceled: std.atomic.Value(u32) = .init(0),
    flush_started: std.atomic.Value(u32) = .init(0),
    flush_returned: std.atomic.Value(u32) = .init(0),
    flush_canceled: std.atomic.Value(u32) = .init(0),
    stall_ms: u32 = 40,
    chunk_bytes: usize = 8192,

    fn snapshot(self: *const Shared) Snapshot {
        return .{
            .released = self.released.load(.acquire),
            .started = self.started.load(.acquire),
            .finished = self.finished.load(.acquire),
            .sleep_started = self.sleep_started.load(.acquire),
            .sleep_canceled = self.sleep_canceled.load(.acquire),
            .flush_started = self.flush_started.load(.acquire),
            .flush_returned = self.flush_returned.load(.acquire),
            .flush_canceled = self.flush_canceled.load(.acquire),
        };
    }
};
const Snapshot = struct {
    released: bool,
    started: u32,
    finished: u32,
    sleep_started: u32,
    sleep_canceled: u32,
    flush_started: u32,
    flush_returned: u32,
    flush_canceled: u32,
};
const Application = web.App(Shared);
const Context = Application.Context;
var active_app: std.atomic.Value(?*Application) = .init(null);
var active_controls: std.atomic.Value(u32) = .init(0);

fn stopSignal(_: std.posix.SIG) callconv(.c) void {
    requestControlStop();
}

fn stopConsole(kind: u32) callconv(.winapi) i32 {
    if (kind != 0 and kind != 1) return 0;
    requestControlStop();
    return 1;
}

fn requestControlStop() void {
    _ = active_controls.fetchAdd(1, .seq_cst);
    defer _ = active_controls.fetchSub(1, .seq_cst);
    if (active_app.load(.seq_cst)) |app| app.requestStopFromSignal();
}

fn ping(ctx: *Context) !void {
    return ctx.response.text(200, "ok\n");
}

fn state(ctx: *Context) !void {
    return ctx.response.jsonValue(200, ctx.shared.snapshot());
}

fn release(ctx: *Context) !void {
    ctx.shared.released.store(true, .release);
    return ctx.response.text(200, "released\n");
}

fn chunks(ctx: *Context) !void {
    var stream = try ctx.response.stream(200, "text/plain", .{});
    var first = "first\n".*;
    try stream.writer().writeAll(&first);
    @memset(&first, 'x'); // Writes copy caller bytes before they return.
    try stream.flush();
    try ctx.sleep(.fromMilliseconds(ctx.shared.stall_ms));
    try stream.writeAll("second\n");
    try stream.writer().flush();
    try ctx.sleep(.fromMilliseconds(ctx.shared.stall_ms));
    try stream.print("{s}\n", .{"final"});
    try stream.finish();
}

fn echo(ctx: *Context) !void {
    const body = ctx.request.body().contiguous() orelse return error.BodyNotContiguous;
    const middle = body.len / 2;
    var stream = try ctx.response.stream(200, "application/octet-stream", .{});
    try stream.writeAll(body[0..middle]);
    try stream.flush();
    try ctx.sleep(.fromMilliseconds(5));
    // Original request input remains borrowed across the flush and sleep.
    try stream.writeAll(body[middle..]);
    try stream.finish();
}

fn gated(ctx: *Context) !void {
    _ = ctx.shared.started.fetchAdd(1, .release);
    defer _ = ctx.shared.finished.fetchAdd(1, .release);
    try ctx.response.header("X-Stream", "gated");
    var stream = try ctx.response.stream(200, "text/plain", .{});
    try stream.writer().writeAll("first\n");
    try stream.writer().flush();
    // A second worker releases this handler only after the client reads a chunk.
    // The request deadline also cancels this bounded sequence of short sleeps.
    var waits: u16 = 0;
    while (!ctx.shared.released.load(.acquire)) : (waits += 1) {
        if (waits == 1000) return error.GateNotReleased;
        try ctx.sleep(.fromMilliseconds(5));
    }
    try stream.flush(); // An empty flush must not terminate chunked framing.
    try stream.writeAll("second\n");
    try stream.flush();
    try stream.print("{s}\n", .{"final"});
    try stream.finish();
}

fn knownLength(ctx: *Context) !void {
    var stream = try ctx.response.stream(200, "text/plain", .{ .content_length = 19 });
    try stream.writeAll("first\n");
    try stream.flush();
    try stream.flush();
    try stream.writeAll("second\n");
    try stream.flush();
    try stream.writeAll("final\n");
    try stream.finish();
}

fn empty(ctx: *Context) !void {
    var stream = try ctx.response.stream(200, "text/plain", .{});
    try stream.flush();
    try stream.flush();
    try stream.writeAll("body\n");
    try stream.flush();
    try stream.flush();
    try stream.finish();
}

fn autoFinish(ctx: *Context) !void {
    var stream = try ctx.response.stream(200, "text/plain", .{});
    try stream.writeAll("auto\n");
    try stream.flush();
    try stream.writeAll("done\n");
}

fn lateHeader(ctx: *Context) !void {
    var stream = try ctx.response.stream(200, "text/plain", .{});
    try stream.writeAll("before\n");
    try stream.flush();
    ctx.response.header("X-Late", "forbidden") catch {
        try stream.writeAll("locked\n");
        return stream.finish();
    };
    return error.HeaderWasMutable;
}

fn failBefore(ctx: *Context) !void {
    var stream = try ctx.response.stream(200, "text/plain", .{});
    try stream.writeAll("private bytes\n");
    return error.StreamFixtureFailure;
}

fn failAfter(ctx: *Context) !void {
    var stream = try ctx.response.stream(200, "text/plain", .{});
    try stream.writeAll("first\n");
    try stream.flush();
    return error.StreamFixtureFailure;
}

fn shortLength(ctx: *Context) !void {
    var stream = try ctx.response.stream(200, "text/plain", .{ .content_length = 20 });
    try stream.writeAll("first\n");
    try stream.flush();
    try stream.finish();
}

fn longLength(ctx: *Context) !void {
    var stream = try ctx.response.stream(200, "text/plain", .{ .content_length = 8 });
    try stream.writeAll("first\n");
    try stream.flush();
    try stream.writeAll("excess\n");
    try stream.finish();
}

fn largeWrite(ctx: *Context) !void {
    const bytes = "s" ** 8193;
    var stream = try ctx.response.stream(200, "text/plain", .{});
    try stream.writeAll(bytes[0 .. ctx.shared.chunk_bytes + 1]);
    try stream.finish();
}

fn cumulativeLimit(ctx: *Context) !void {
    const bytes = "b" ** 512;
    var stream = try ctx.response.stream(200, "text/plain", .{});
    for (0..3) |_| {
        try stream.writeAll(bytes);
        try stream.flush();
    }
    try stream.finish();
}

fn sleeping(ctx: *Context) !void {
    _ = ctx.shared.started.fetchAdd(1, .release);
    defer _ = ctx.shared.finished.fetchAdd(1, .release);
    var stream = try ctx.response.stream(200, "text/plain", .{});
    try stream.writeAll("sleeping\n");
    try stream.flush();
    _ = ctx.shared.sleep_started.fetchAdd(1, .release);
    ctx.sleep(.fromMilliseconds(30_000)) catch |err| {
        if (err == error.Cancelled or err == error.Canceled) _ = ctx.shared.sleep_canceled.fetchAdd(1, .release);
        return err;
    };
    return error.SleepWasNotCanceled;
}

fn pressure(ctx: *Context) !void {
    _ = ctx.shared.started.fetchAdd(1, .release);
    defer _ = ctx.shared.finished.fetchAdd(1, .release);
    const bytes = "p" ** 8192;
    var stream = try ctx.response.stream(200, "application/octet-stream", .{});
    // This upper bound exceeds socket buffers. The wire gate stops reading.
    for (0..8192) |_| {
        try stream.writeAll(bytes[0..ctx.shared.chunk_bytes]);
        _ = ctx.shared.flush_started.fetchAdd(1, .release);
        stream.flush() catch |err| {
            if (err == error.Cancelled or err == error.Canceled) _ = ctx.shared.flush_canceled.fetchAdd(1, .release);
            return err;
        };
        _ = ctx.shared.flush_returned.fetchAdd(1, .release);
    }
    try stream.finish();
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    var shared: Shared = .{};
    var server: web.Config = .{ .port = 8080, .shards = 1, .execution = .workers, .workers = 2 };
    var limits: web.ResponseLimits = .{};
    while (args.next()) |flag| {
        if (std.mem.eql(u8, flag, "--help")) {
            std.debug.print("Streaming: GET /stream; curl --no-buffer http://localhost:8080/stream\n" ++
                "--port N --execution inline|workers --workers N --shards N --connections N\n" ++
                "--max-body N --max-header N --output-bytes N --response-body N --max-response N\n" ++
                "--timeout-ms N --shutdown-ms N --duration-ms N --send-chunk N --stall-ms N --socket-send-buffer N\n", .{});
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
        } else if (std.mem.eql(u8, flag, "--shards")) {
            server.shards = try std.fmt.parseInt(u8, value, 10);
        } else if (std.mem.eql(u8, flag, "--connections")) {
            server.connections = try std.fmt.parseInt(u16, value, 10);
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
        } else if (std.mem.eql(u8, flag, "--stall-ms")) {
            shared.stall_ms = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--socket-send-buffer")) {
            server.socket_send_buffer_bytes = try std.fmt.parseInt(u32, value, 10);
        } else return error.InvalidArgument;
    }
    if (shared.stall_ms > 5000 or limits.body_bytes > 8192) return error.InvalidArgument;
    shared.chunk_bytes = limits.body_bytes;
    const app = try Application.init(.{ .allocator = init.gpa, .io = init.io, .shared = &shared, .server = server, .response = limits });
    defer app.deinit();
    try app.route("GET", "/", chunks);
    try app.route("GET", "/stream", chunks);
    try app.route("POST", "/echo", echo);
    try app.route("GET", "/ping", ping);
    try app.route("GET", "/state", state);
    try app.route("POST", "/release", release);
    try app.route("GET", "/gated", gated);
    try app.route("GET", "/known", knownLength);
    try app.route("GET", "/empty", empty);
    try app.route("GET", "/auto", autoFinish);
    try app.route("GET", "/late-header", lateHeader);
    try app.route("GET", "/fail-before", failBefore);
    try app.route("GET", "/fail-after", failAfter);
    try app.route("GET", "/short", shortLength);
    try app.route("GET", "/long", longLength);
    try app.route("GET", "/large-write", largeWrite);
    try app.route("GET", "/cumulative-limit", cumulativeLimit);
    try app.route("GET", "/sleep", sleeping);
    try app.route("GET", "/pressure", pressure);
    try app.start();
    active_app.store(app, .seq_cst);
    defer {
        active_app.store(null, .seq_cst);
        const deadline = web.nowNs() + @as(u64, server.shutdown_ms) * std.time.ns_per_ms;
        while (active_controls.load(.seq_cst) != 0) {
            if (web.nowNs() >= deadline) web.engine.failFast(70);
            std.Thread.yield() catch {};
        }
    }
    if (builtin.os.tag == .windows) {
        if (win32.SetConsoleCtrlHandler(stopConsole, 1) == 0) return error.ConsoleHandlerFailed;
    } else {
        const action: std.posix.Sigaction = .{ .handler = .{ .handler = stopSignal }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(.INT, &action, null);
        std.posix.sigaction(.TERM, &action, null);
    }
    defer if (builtin.os.tag == .windows) {
        std.debug.assert(win32.SetConsoleCtrlHandler(stopConsole, 0) != 0);
    };
    std.debug.print("READY port={d} backend={s} execution={s} optimize={s}\n", .{ app.port(), web.backend_name, @tagName(server.execution), @tagName(builtin.mode) });
    app.run() catch |err| {
        std.debug.print("FATAL {s}; App storage remains borrowed\n", .{@errorName(err)});
        web.engine.failFast(70);
    };
    const stats = try std.json.Stringify.valueAlloc(init.gpa, app.stats(), .{});
    defer init.gpa.free(stats);
    const fixture = try std.json.Stringify.valueAlloc(init.gpa, shared.snapshot(), .{});
    defer init.gpa.free(fixture);
    std.debug.print("FIXTURE {s}\nSTATS {s}\n", .{ fixture, stats });
}
