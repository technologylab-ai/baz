//! Middleware lifecycle wire fixture. Traces use atomic snapshots, without locks.
const std = @import("std");
const web = @import("baz");
const support = @import("example_support");
const Counter = std.atomic.Value(u64);

const Snapshot = struct {
    trace: u64,
    initialized: u64,
    handlers: u64,
    afters: u64,
    cleanups: u64,
    locals_cleaned: u64,
    cancelled: u64,
    errors: u64,
    sleeping: u64,
    bad_address: u64,
};
const Record = struct {
    trace: Counter = .init(0),
    initialized: Counter = .init(0),
    handlers: Counter = .init(0),
    afters: Counter = .init(0),
    cleanups: Counter = .init(0),
    locals_cleaned: Counter = .init(0),
    cancelled: Counter = .init(0),
    errors: Counter = .init(0),
    sleeping: Counter = .init(0),
    bad_address: Counter = .init(0),

    fn snapshot(self: *const Record) Snapshot {
        var result: Snapshot = undefined;
        inline for (std.meta.fields(Snapshot)) |field| @field(result, field.name) = @field(self, field.name).load(.acquire);
        return result;
    }
};
const Shared = struct { records: [64]Record = @splat(.{}) };
const Locals = struct {
    sentinel: u32 = 0xbeef,
    tracked: bool = false,
    index: u8 = 0,
    address: usize = 0,
    trace: u64 = 0,
    steps: u8 = 0,
    value: [64]u8 = @splat(0),
    value_len: usize = 0,
    instance: []const u8 = "plain",
};
const Application = web.AppWithLocals(Shared, Locals);
const Context = Application.Context;

fn record(ctx: *Context) *Record {
    return &ctx.shared.records[ctx.locals.index];
}

// Nibbles: I A B C D H d c b a 4 3 2 1 Z; zero is E (error mapper).
fn mark(ctx: *Context, code: u4) void {
    if (!ctx.locals.tracked) return;
    if (ctx.locals.address != @intFromPtr(ctx.locals) or ctx.locals.steps == 16) {
        _ = record(ctx).bad_address.fetchAdd(1, .monotonic);
        return;
    }
    ctx.locals.trace = (ctx.locals.trace << 4) | code;
    ctx.locals.steps += 1;
}

fn is(ctx: *Context, prefix: []const u8) bool {
    return std.mem.startsWith(u8, ctx.request.path() orelse "", prefix);
}

fn index(ctx: *Context) !u8 {
    const query = try ctx.request.query();
    const field = query.firstRaw("slot") orelse return 0;
    const value = try std.fmt.parseInt(u8, field.value_raw, 10);
    if (value >= 64) return error.InvalidSlot;
    return value;
}

fn initLocals(ctx: *Context) !void {
    if (is(ctx, "/state") or is(ctx, "/ping")) return;
    if (ctx.locals.sentinel != 0xbeef or ctx.locals.tracked or ctx.locals.trace != 0 or ctx.locals.value_len != 0 or
        !std.mem.allEqual(u8, &ctx.locals.value, 0)) return error.LocalsNotFresh;
    ctx.locals.tracked = true;
    ctx.locals.index = try index(ctx);
    ctx.locals.address = @intFromPtr(ctx.locals);
    ctx.locals.sentinel = 0x600d;
    _ = record(ctx).initialized.fetchAdd(1, .monotonic);
    record(ctx).trace.store(0, .release);
    mark(ctx, 1);
    const query = try ctx.request.query();
    if (query.firstRaw("value")) |field| {
        if (field.value_raw.len > ctx.locals.value.len) return error.InvalidValue;
        @memcpy(ctx.locals.value[0..field.value_raw.len], field.value_raw);
        ctx.locals.value_len = field.value_raw.len;
    }
    if (is(ctx, "/init-error")) return error.InitFailed;
    if (is(ctx, "/init-body")) try ctx.response.text(200, "invalid initializer body");
}

fn cleanupLocals(ctx: *Context) void {
    if (!ctx.locals.tracked) return;
    mark(ctx, 15);
    if (ctx.cancelled.load(.acquire)) _ = record(ctx).cancelled.fetchAdd(1, .monotonic);
    record(ctx).trace.store(ctx.locals.trace, .release);
    _ = record(ctx).locals_cleaned.fetchAdd(1, .release);
}

fn beforeA(ctx: *Context) !Application.Decision {
    if (ctx.param("id") != null) return error.GlobalCapturesTooEarly;
    mark(ctx, 2);
    if (is(ctx, "/before-error")) return error.BeforeFailed;
    if (is(ctx, "/respond-empty")) return .respond;
    if (is(ctx, "/continue-body")) try ctx.response.text(200, "invalid continued body");
    if (is(ctx, "/early-global")) {
        try ctx.response.text(200, "global response");
        return .respond;
    }
    return .continue_request;
}
fn beforeB(ctx: *Context) !Application.Decision {
    mark(ctx, 3);
    return .continue_request;
}
fn beforeC(ctx: *Context) !Application.Decision {
    if (ctx.param("id") == null) return error.MissingRouteCapture;
    mark(ctx, 4);
    if (is(ctx, "/route-before-error")) return error.RouteBeforeFailed;
    if (is(ctx, "/early-route")) {
        try ctx.response.text(200, ctx.param("id").?);
        return .respond;
    }
    return .continue_request;
}
fn beforeD(ctx: *Context) !Application.Decision {
    mark(ctx, 5);
    return .continue_request;
}
fn afterA(ctx: *Context) !void {
    mark(ctx, 10);
    if (!ctx.locals.tracked) return;
    _ = record(ctx).afters.fetchAdd(1, .monotonic);
    if (!is(ctx, "/stream")) {
        var buffer: [16]u8 = undefined;
        try ctx.response.header("X-Trace", try std.fmt.bufPrint(&buffer, "{x}", .{ctx.locals.trace}));
    }
}
fn afterB(ctx: *Context) !void {
    mark(ctx, 9);
    if (ctx.locals.tracked) _ = record(ctx).afters.fetchAdd(1, .monotonic);
    if (is(ctx, "/global-after-error")) return error.GlobalAfterFailed;
}
fn afterC(ctx: *Context) !void {
    mark(ctx, 8);
    if (ctx.locals.tracked) _ = record(ctx).afters.fetchAdd(1, .monotonic);
    if (is(ctx, "/early-route-after-error")) return error.EarlyAfterFailed;
}
fn afterD(ctx: *Context) !void {
    mark(ctx, 7);
    if (ctx.locals.tracked) _ = record(ctx).afters.fetchAdd(1, .monotonic);
    if (is(ctx, "/after-error")) return error.AfterFailed;
    if (is(ctx, "/stream-after-error")) try ctx.response.header("X-Too-Late", "must not publish");
}
fn clean(ctx: *Context, code: u4) void {
    mark(ctx, code);
    if (ctx.locals.tracked) _ = record(ctx).cleanups.fetchAdd(1, .monotonic);
}
fn cleanupA(ctx: *Context) void {
    clean(ctx, 14);
}
fn cleanupB(ctx: *Context) void {
    clean(ctx, 13);
}
fn cleanupC(ctx: *Context) void {
    clean(ctx, 12);
}
fn cleanupD(ctx: *Context) void {
    clean(ctx, 11);
}

fn handle(ctx: *Context) !void {
    mark(ctx, 6);
    _ = record(ctx).handlers.fetchAdd(1, .monotonic);
    if (is(ctx, "/handler-error")) return error.HandlerFailed;
    return ctx.response.jsonValue(200, .{
        .id = ctx.param("id"),
        .value = ctx.locals.value[0..ctx.locals.value_len],
        .sentinel = ctx.locals.sentinel,
        .instance = ctx.locals.instance,
    });
}

const Endpoint = struct {
    name: []const u8,
    pub fn get(self: *Endpoint, ctx: *Context) !void {
        ctx.locals.instance = self.name;
        return handle(ctx);
    }
};

fn stream(ctx: *Context) !void {
    if (ctx.app.config.execution != .workers) return error.WorkersRequired;
    mark(ctx, 6);
    _ = record(ctx).handlers.fetchAdd(1, .monotonic);
    var out = try ctx.response.stream(200, "text/plain", .{});
    try out.writeAll("first\n");
    try out.flush();
    if (is(ctx, "/stream-sleep")) {
        _ = record(ctx).sleeping.fetchAdd(1, .release);
        try ctx.sleep(.fromSeconds(30));
    }
    try out.print("last:{s}\n", .{ctx.locals.value[0..ctx.locals.value_len]});
    try out.finish();
}

fn mapError(ctx: *Context, err: anyerror) !void {
    mark(ctx, 0);
    if (ctx.locals.tracked) {
        _ = record(ctx).errors.fetchAdd(1, .monotonic);
        if (ctx.locals.sentinel != 0x600d) return error.ErrorMapperLostLocals;
    }
    try ctx.response.header("X-Error-Locals", "retained");
    try ctx.response.text(500, @errorName(err));
}
fn state(ctx: *Context) !void {
    return ctx.response.jsonValue(200, ctx.shared.records[try index(ctx)].snapshot());
}
fn ping(ctx: *Context) !void {
    return ctx.response.text(200, "ok");
}
fn poison(_: *Context) !Application.Decision {
    return error.MiddlewareDescriptorsNotCopied;
}

pub fn main(init: std.process.Init) !void {
    var shared: Shared = .{};
    var config = try support.config(init);
    config.timeout_ms = 1200;
    config.shutdown_ms = 3000;
    var globals = [_]Application.Middleware{
        .{ .before = beforeA, .after = afterA, .cleanup = cleanupA },
        .{ .before = beforeB, .after = afterB, .cleanup = cleanupB },
    };
    var chain = [_]Application.Middleware{
        .{ .before = beforeC, .after = afterC, .cleanup = cleanupC },
        .{ .before = beforeD, .after = afterD, .cleanup = cleanupD },
    };
    const app = try Application.init(.{
        .allocator = init.gpa,
        .io = init.io,
        .shared = &shared,
        .server = config,
        .middleware = &globals,
        .init_locals = initLocals,
        .cleanup_locals = cleanupLocals,
        .on_error = mapError,
    });
    defer app.deinit();
    inline for (.{ "/normal/:id", "/init-error/:id", "/init-body/:id", "/before-error/:id", "/respond-empty/:id", "/continue-body/:id", "/early-global/:id", "/route-before-error/:id", "/early-route/:id", "/early-route-after-error/:id", "/handler-error/:id", "/after-error/:id", "/global-after-error/:id" }) |path|
        try app.routeWith("GET", path, handle, .{ .middleware = &chain });
    try app.route("GET", "/plain/:id", handle);
    try app.routeWith("GET", "/after-only/:id", handle, .{ .middleware = &.{.{ .after = afterC, .cleanup = cleanupC }} });
    var bound: Endpoint = .{ .name = "bound" };
    var endpoint: Endpoint = .{ .name = "endpoint" };
    try app.bindWith("GET", "/bound/:id", &bound, Endpoint.get, .{ .middleware = &chain });
    try app.endpointWith("/endpoint/:id", &endpoint, .{ .middleware = &chain });
    inline for (.{ "/stream/:id", "/stream-sleep/:id", "/stream-after-error/:id" }) |path|
        try app.routeWith("GET", path, stream, .{ .middleware = &chain });
    try app.route("GET", "/state", state);
    try app.route("GET", "/ping", ping);
    @memset(&globals, .{ .before = poison });
    @memset(&chain, .{ .before = poison });
    try support.run(app, init);
    var total: Snapshot = .{ .trace = 0, .initialized = 0, .handlers = 0, .afters = 0, .cleanups = 0, .locals_cleaned = 0, .cancelled = 0, .errors = 0, .sleeping = 0, .bad_address = 0 };
    for (&shared.records) |*item| {
        const snapshot = item.snapshot();
        inline for (std.meta.fields(Snapshot)) |field| {
            if (comptime !std.mem.eql(u8, field.name, "trace")) @field(total, field.name) += @field(snapshot, field.name);
        }
    }
    const receipt = try std.json.Stringify.valueAlloc(init.gpa, total, .{});
    defer init.gpa.free(receipt);
    std.debug.print("HOOKS {s}\n", .{receipt});
}
