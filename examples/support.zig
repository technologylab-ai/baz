//! Executable-only lifecycle support shared by the migration examples.
const std = @import("std");
const web = @import("baz");

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
        var active: ?@TypeOf(app) = null;
        fn stop(_: std.posix.SIG) callconv(.c) void {
            if (active) |application| application.requestStopFromSignal();
        }
    };
    try app.start();
    Signals.active = app;
    defer Signals.active = null;
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = Signals.stop }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
    std.debug.print("READY port={d} backend={s} execution={s} optimize={s}\n", .{ app.port(), web.backend_name, @tagName(app.config.execution), @tagName(@import("builtin").mode) });
    app.run() catch |err| {
        std.debug.print("FATAL {s}; application storage remains borrowed\n", .{@errorName(err)});
        std.c._exit(70);
    };
    const stats = try std.json.Stringify.valueAlloc(init.gpa, app.stats(), .{});
    defer init.gpa.free(stats);
    std.debug.print("STATS {s}\n", .{stats});
}
