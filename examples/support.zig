//! Executable-only CLI and lifecycle support shared by every public example.
const std = @import("std");
const web = @import("baz");
const zli = @import("zli");
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

/// Typed startup arguments. Underscores become CLI hyphens in zli.
/// Worker-only examples choose their own execution default below.
pub fn Options(comptime workers_required: bool) type {
    return struct {
        port: u16 = 8080,
        duration_ms: u32 = 0,
        execution: enum { @"inline", workers } = if (workers_required) .workers else .@"inline",
        workers: ?u16 = null,
        connections: u16 = 16,
        shards: u8 = 1,

        pub const help =
            \\Baz example — Zig 0.16.0
            \\Usage: EXAMPLE [options]
            \\
            \\  -h, --help                    Show this help and exit
            \\  -p, --port N                  Listen port; 0 selects an available port (default: 8080)
            \\      --duration-ms N           Stop after N milliseconds; 0 waits for shutdown
            \\      --execution inline|workers
            \\      --workers N               Worker count (default: 2 for workers, 0 for inline)
            \\      --connections N           Connection slots (default: 16)
            \\      --shards N                I/O shards (default: 1)
            \\
            \\Options accept both --port 8080 and --port=8080. Repeated options are errors.
        ++ if (workers_required)
            \\
            \\This example defaults to workers and requires worker execution with one shard.
        else
            \\
            \\This example defaults to inline execution.
        ;
        pub const aliases = .{ .port = "p" };
    };
}

fn parseConfig(init: std.process.Init, comptime workers_required: bool) !web.Config {
    const options = try parseOptions(init, Options(workers_required));
    return configFromOptions(options, workers_required);
}

/// Executable-local option structs can add service configuration explicitly.
pub fn parseOptions(init: std.process.Init, comptime T: type) !T {
    return zli.parseInit(init, T);
}

pub fn configFromOptions(options: anytype, comptime workers_required: bool) !web.Config {
    const result: web.Config = .{
        .port = options.port,
        .duration_ms = options.duration_ms,
        .execution = if (options.execution == .workers) .workers else .inline_event_loop,
        .workers = options.workers orelse if (options.execution == .workers) @as(u16, 2) else 0,
        .connections = options.connections,
        .shards = options.shards,
    };
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
