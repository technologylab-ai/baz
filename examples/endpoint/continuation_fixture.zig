//! Fixed test counters and fault routes keep the public continuation example short.
const std = @import("std");
const web = @import("baz");
const Counter = std.atomic.Value(u64);
const Step = web.continuation.Step;
const Event = web.continuation.Event;

const Snapshot = struct {
    initialized: u64,
    before: u64,
    after: u64,
    cleaned: u64,
    locals_cleaned: u64,
    state_cleaned: u64,
    starts: u64,
    resumes: u64,
    flushed: u64,
    timers: u64,
    errors: u64,
    cancelled: u64,
    bad_address: u64,
};

const Record = struct {
    initialized: Counter = .init(0),
    before: Counter = .init(0),
    after: Counter = .init(0),
    cleaned: Counter = .init(0),
    locals_cleaned: Counter = .init(0),
    state_cleaned: Counter = .init(0),
    starts: Counter = .init(0),
    resumes: Counter = .init(0),
    flushed: Counter = .init(0),
    timers: Counter = .init(0),
    errors: Counter = .init(0),
    cancelled: Counter = .init(0),
    bad_address: Counter = .init(0),

    fn snapshot(self: *const Record) Snapshot {
        var result: Snapshot = undefined;
        inline for (std.meta.fields(Snapshot)) |field| @field(result, field.name) = @field(self, field.name).load(.acquire);
        return result;
    }
};

pub const Shared = struct { records: [64]Record = @splat(.{}) };
pub const Locals = struct {
    record: ?*Record = null,
    address: usize = 0,
    sentinel: u32 = 0xbeef,
    cleanup_started: bool = false,
    state_cleaned: bool = false,
    payload: [16]u8 = "locals borrowed!".*,
    large_payload: [512]u8 = @splat('L'),
};
pub const Application = web.AppWithLocals(Shared, Locals);
const Context = Application.Context;
pub const middleware: Application.Middleware = .{ .before = before, .after = after, .cleanup = cleanup };

fn slot(ctx: *Context) !u8 {
    const query = try ctx.request.query();
    const field = query.firstRaw("slot") orelse return 0;
    const index = try std.fmt.parseInt(u8, field.value_raw, 10);
    if (index >= 64) return error.InvalidSlot;
    return index;
}

pub fn initLocals(ctx: *Context) !void {
    const path = ctx.request.path() orelse return;
    if (!std.mem.eql(u8, path, "/events")) return;
    if (ctx.locals.record != null or ctx.locals.address != 0 or ctx.locals.sentinel != 0xbeef) return error.LocalsNotFresh;
    ctx.locals.record = &ctx.shared.records[try slot(ctx)];
    ctx.locals.address = @intFromPtr(ctx.locals);
    _ = ctx.locals.record.?.initialized.fetchAdd(1, .monotonic);
    if (try selectedMode(ctx) == .init_error) return error.InitializerFailed;
}

fn checkAddress(ctx: *Context) void {
    const record = ctx.locals.record orelse return;
    if (ctx.locals.address != @intFromPtr(ctx.locals) or ctx.locals.sentinel != 0xbeef)
        _ = record.bad_address.fetchAdd(1, .monotonic);
}

pub fn cleanupLocals(ctx: *Context) void {
    const record = ctx.locals.record orelse return;
    checkAddress(ctx);
    if (ctx.cancelled.load(.acquire)) _ = record.cancelled.fetchAdd(1, .monotonic);
    _ = record.locals_cleaned.fetchAdd(1, .release);
}

fn before(ctx: *Context) !Application.Decision {
    checkAddress(ctx);
    if (ctx.locals.record) |record| _ = record.before.fetchAdd(1, .monotonic);
    if (ctx.locals.record != null and try selectedMode(ctx) == .before_error) return error.BeforeHookFailed;
    return .continue_request;
}

fn after(ctx: *Context) !void {
    checkAddress(ctx);
    if (ctx.locals.record) |record| _ = record.after.fetchAdd(1, .monotonic);
}

fn cleanup(ctx: *Context) void {
    checkAddress(ctx);
    ctx.locals.cleanup_started = true;
    if (ctx.locals.record) |record| _ = record.cleaned.fetchAdd(1, .monotonic);
}

pub fn onError(ctx: *Context, _: anyerror) !void {
    if (ctx.locals.record) |record| _ = record.errors.fetchAdd(1, .monotonic);
    if ((selectedMode(ctx) catch .normal) == .mapper_borrow)
        return ctx.response.borrowBody(500, "text/plain", &ctx.locals.large_payload);
    return ctx.response.text(500, "Continuation failed");
}

const Mode = enum { normal, known, wait_first, wait_hold, hold, error_before, error_after, staged_wait, forbidden_state, forbidden_locals, mapper_borrow, init_error, before_error };
const State = struct {
    address: usize = 0,
    phase: u8 = 0,
    mode: Mode = .normal,
    payload: [16]u8 = "state borrowed!!".*,

    pub fn deinit(self: *State, ctx: *Context) void {
        const record = ctx.locals.record orelse return;
        checkAddress(ctx);
        if ((self.address != 0 and self.address != @intFromPtr(self)) or
            ctx.locals.cleanup_started or ctx.locals.state_cleaned)
            _ = record.bad_address.fetchAdd(1, .monotonic);
        ctx.locals.state_cleaned = true;
        _ = record.state_cleaned.fetchAdd(1, .release);
    }
};

fn selectedMode(ctx: *Context) !Mode {
    const query = try ctx.request.query();
    const field = query.firstRaw("mode") orelse return .normal;
    return std.meta.stringToEnum(Mode, field.value_raw) orelse error.InvalidMode;
}

fn start(ctx: *Context, state: *State) !Step {
    const record = ctx.locals.record.?;
    checkAddress(ctx);
    if (state.address != 0 or state.phase != 0 or state.mode != .normal) return error.StateNotFresh;
    state.address = @intFromPtr(state);
    _ = record.starts.fetchAdd(1, .monotonic);
    state.mode = try selectedMode(ctx);
    if (state.mode == .mapper_borrow) return error.MapperBorrow;
    if (state.mode == .forbidden_state or state.mode == .forbidden_locals) {
        const bytes = if (state.mode == .forbidden_state) &state.payload else &ctx.locals.payload;
        try ctx.response.borrowBody(200, "text/plain", bytes);
        return .finish;
    }
    if (state.mode == .wait_hold) return .{ .wait = 10 * std.time.ns_per_s };
    if (state.mode == .wait_first) {
        try ctx.response.header("X-Wait", "retained");
        return .{ .wait = 100 * std.time.ns_per_ms };
    }
    var output = try ctx.response.snapshot(200, "text/plain; charset=utf-8", .{
        .content_length = if (state.mode == .known) 19 else null,
    });
    try output.writer().writeAll("first\n");
    if (state.mode == .error_before) return error.BeforePublication;
    if (state.mode == .staged_wait) {
        try output.writer().flush(); // A writer flush does not publish a snapshot.
        return .{ .wait = std.time.ns_per_s };
    }
    state.phase = 1;
    return .flush;
}

fn advance(ctx: *Context, state: *State, event: Event) !Step {
    const record = ctx.locals.record.?;
    checkAddress(ctx);
    if (state.address != @intFromPtr(state)) _ = record.bad_address.fetchAdd(1, .monotonic);
    _ = record.resumes.fetchAdd(1, .monotonic);
    switch (event) {
        .notified => return error.UnexpectedNotification, // This fixture only arms timer waits.
        .flushed => {
            _ = record.flushed.fetchAdd(1, .monotonic);
            if (state.mode == .error_after) return error.AfterPublication;
            return .{ .wait = if (state.mode == .hold) 10 * std.time.ns_per_s else 50 * std.time.ns_per_ms };
        },
        .timer => {
            _ = record.timers.fetchAdd(1, .monotonic);
            if (state.mode == .wait_first or state.mode == .wait_hold) {
                var output = try ctx.response.snapshot(200, "text/plain; charset=utf-8", .{});
                try output.writer().writeAll("after timer\n");
                return .finish;
            }
            var output = try ctx.response.resumeSnapshot();
            state.phase += 1;
            try output.writer().writeAll(if (state.phase == 2) "second\n" else "third\n");
            return if (state.phase == 3) .finish else .flush;
        },
    }
}

fn ping(ctx: *Context) !void {
    return ctx.response.text(200, "ok");
}

fn inspect(ctx: *Context) !void {
    return ctx.response.jsonValue(200, ctx.shared.records[try slot(ctx)].snapshot());
}

pub fn register(app: *Application) !void {
    try app.routeContinuation("GET", "/events", State, start, advance, .{});
    try app.route("GET", "/ping", ping);
    try app.route("GET", "/state", inspect);
}

pub fn report(shared: *const Shared) void {
    var totals: Snapshot = std.mem.zeroes(Snapshot);
    for (&shared.records) |*record| {
        const current = record.snapshot();
        inline for (std.meta.fields(Snapshot)) |field| @field(totals, field.name) += @field(current, field.name);
    }
    std.debug.print("CONTINUATIONS {f}\n", .{std.json.fmt(totals, .{})});
}
