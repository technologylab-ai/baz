//! Executable-only lifecycle support shared by the migration examples.
const std = @import("std");
const web = @import("baz");
const builtin = @import("builtin");
const win32 = struct {
    extern "kernel32" fn SetConsoleCtrlHandler(?*const fn (u32) callconv(.winapi) i32, i32) callconv(.winapi) i32;
};

pub fn config(init: std.process.Init) !web.Config {
    return parseConfig(init, false);
}

/// A stateful service example can explicitly require worker execution.
pub fn workerConfig(init: std.process.Init) !web.Config {
    return parseConfig(init, true);
}

fn parseConfig(init: std.process.Init, workers_required: bool) !web.Config {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    var result: web.Config = .{ .port = 8080, .shards = 1, .connections = 16 };
    if (workers_required) {
        result.execution = .workers;
        result.workers = 2;
    }
    while (args.next()) |flag| {
        const value = args.next() orelse return error.MissingArgument;
        if (std.mem.eql(u8, flag, "--port")) {
            result.port = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.eql(u8, flag, "--duration-ms")) {
            result.duration_ms = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--execution")) {
            if (std.mem.eql(u8, value, "inline")) {
                result.execution = .inline_event_loop;
                result.workers = 0;
            } else if (std.mem.eql(u8, value, "workers")) {
                result.execution = .workers;
                result.workers = 2;
            } else return error.InvalidArgument;
        } else if (std.mem.eql(u8, flag, "--workers")) {
            result.workers = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.eql(u8, flag, "--connections")) {
            result.connections = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.eql(u8, flag, "--shards")) {
            result.shards = try std.fmt.parseInt(u8, value, 10);
        } else return error.InvalidArgument;
    }
    if (workers_required and (result.execution != .workers or result.shards != 1)) return error.WorkerExecutionRequired;
    return result;
}

pub fn run(app: anytype, init: std.process.Init) !void {
    const Signals = struct {
        var active: std.atomic.Value(?@TypeOf(app)) = .init(null);
        var borrowers: std.atomic.Value(u32) = .init(0);

        fn stop(_: std.posix.SIG) callconv(.c) void {
            requestStop();
        }

        fn consoleStop(kind: u32) callconv(.winapi) i32 {
            if (kind != 0 and kind != 1) return 0; // CTRL_C_EVENT and CTRL_BREAK_EVENT
            requestStop();
            return 1;
        }

        fn requestStop() void {
            // Publish the borrow before reading the application pointer.
            _ = borrowers.fetchAdd(1, .seq_cst);
            defer _ = borrowers.fetchSub(1, .seq_cst);
            if (active.load(.seq_cst)) |application| application.requestStopFromSignal();
        }
    };
    try app.start();
    Signals.active.store(app, .seq_cst);
    defer {
        // Windows console handlers run on separate threads. Reconcile their
        // borrows before returning to the caller that owns App teardown.
        Signals.active.store(null, .seq_cst);
        const deadline = web.nowNs() + @as(u64, app.config.shutdown_ms) * std.time.ns_per_ms;
        while (Signals.borrowers.load(.seq_cst) != 0) {
            if (web.nowNs() >= deadline) web.engine.failFast(70);
            std.Thread.yield() catch {};
        }
    }
    if (builtin.os.tag == .windows) {
        if (win32.SetConsoleCtrlHandler(Signals.consoleStop, 1) == 0) return error.ConsoleHandlerFailed;
    } else {
        const action: std.posix.Sigaction = .{ .handler = .{ .handler = Signals.stop }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(.INT, &action, null);
        std.posix.sigaction(.TERM, &action, null);
    }
    defer if (builtin.os.tag == .windows) {
        std.debug.assert(win32.SetConsoleCtrlHandler(Signals.consoleStop, 0) != 0);
    };
    std.debug.print("READY port={d} backend={s} execution={s} optimize={s}\n", .{ app.port(), web.backend_name, @tagName(app.config.execution), @tagName(builtin.mode) });
    app.run() catch |err| {
        std.debug.print("FATAL {s}; application storage remains borrowed\n", .{@errorName(err)});
        web.engine.failFast(70);
    };
    const stats = try std.json.Stringify.valueAlloc(init.gpa, app.stats(), .{});
    defer init.gpa.free(stats);
    std.debug.print("STATS {s}\n", .{stats});
}
