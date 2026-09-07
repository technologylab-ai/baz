//! A complete local application: Mustache, expiring sessions, and live job progress.
//! One startup producer serves fixed job and subscriber slots. Waiting streams release callbacks.
//! Credentials are public demo data: zap/awesome and baz/awesome. This is not an identity service.
const std = @import("std");
const web = @import("baz");
const support = @import("example_support");
const sessions = @import("endpoint/session_store.zig");
const jobs = @import("endpoint/job_store.zig");

const Options = struct {
    port: u16 = 8080,
    duration_ms: u32 = 0,
    execution: enum { @"inline", workers } = .@"inline",
    workers: ?u16 = null,
    connections: u16 = 64,
    shards: u8 = 1,
    session_ttl_ms: u32 = 1800000,
    job_ttl_ms: u32 = 60000,
    tick_ms: u32 = 250,
    pub const aliases = .{ .port = "p" };
    pub const help =
        \\Baz jobs — Mustache, sessions, and live progress
        \\Usage: jobs [options]
        \\  -h, --help                       Show this help and exit
        \\  -p, --port N                     Listen port (default: 8080; 0 selects a port)
        \\      --duration-ms N              Stop after N milliseconds; 0 waits for shutdown
        \\      --execution inline|workers   Callback execution (default: inline)
        \\      --workers N                  Worker count (default: 2 for workers)
        \\      --connections N              Connection slots (default: 64)
        \\      --shards N                   I/O shards (default: 1)
        \\      --session-ttl-ms N           Positive session lifetime (default: 1800000)
        \\      --job-ttl-ms N               Positive job lifetime (default: 60000)
        \\      --tick-ms N                  Positive producer interval (default: 250)
    ;
};
const Subscription = struct {
    active: std.atomic.Value(bool) = .init(false),
    notification: web.continuation.Notification = undefined,
};
const Shared = struct {
    template: web.mustache.Template,
    sessions: sessions.Store(32),
    jobs: jobs.Store(8, 8) = .{},
    subscriptions: [32]Subscription = @splat(.{}),
    session_ttl_ns: u64,
    job_ttl_ns: u64,
    tick_ns: u64,
    busy: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    started: std.atomic.Value(u64) = .init(0),
    cleaned: std.atomic.Value(u64) = .init(0),
};
const Locals = struct { identity: ?u64 = null };
const Application = web.AppWithLocals(Shared, Locals);
const Context = Application.Context;
const Step = web.continuation.Step;
const cookie_name = "baz-jobs-session";
const State = struct {
    job: jobs.Handle = .{ .slot = 0, .generation = 0 },
    cursor: u64 = 0,
    subscription: ?u8 = null,

    pub fn deinit(self: *State, ctx: *Context) void {
        if (self.subscription) |slot| {
            // Registration and producer reads share the guard. Cleanup only releases ownership.
            ctx.shared.subscriptions[slot].active.store(false, .release);
            _ = ctx.shared.cleaned.fetchAdd(1, .monotonic);
            self.subscription = null;
        }
    }
};

fn now(io: std.Io) !u64 {
    return std.math.cast(u64, std.Io.Clock.boot.now(io).nanoseconds) orelse error.InvalidClock;
}

fn redirect(ctx: *Context, path: []const u8) !void {
    try ctx.response.header("Cache-Control", "no-store");
    try ctx.response.redirect(303, path);
}

// Reject explicit cross-origin browser POSTs. Nonbrowser clients can omit Fetch Metadata.
fn guardPost(ctx: *Context) !Application.Decision {
    if (!std.mem.eql(u8, ctx.request.method(), "POST")) return .continue_request;
    var headers = ctx.request.headers();
    var seen = false;
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name_raw, "Sec-Fetch-Site")) continue;
        if (seen or (!std.mem.eql(u8, header.value_raw, "same-origin") and !std.mem.eql(u8, header.value_raw, "none"))) {
            try ctx.response.text(403, "Cross-origin POST rejected");
            return .respond;
        }
        seen = true;
    }
    return .continue_request;
}

// Call only under shared.busy. Recheck the actual token for every resumed stream callback.
fn identityLocked(ctx: *Context, timestamp: u64) !?u64 {
    const token = (ctx.request.cookie(cookie_name) catch null) orelse return null;
    return ctx.shared.sessions.authenticate(token, timestamp) catch |err| switch (err) {
        error.InvalidToken => null,
        else => return err,
    };
}

fn authenticate(ctx: *Context) !Application.Decision {
    if (ctx.shared.busy.swap(true, .acquire)) {
        try ctx.response.text(503, "Application state is busy");
        return .respond;
    }
    defer ctx.shared.busy.store(false, .release);
    ctx.locals.identity = try identityLocked(ctx, try now(ctx.app.io));
    if (ctx.locals.identity != null) return .continue_request;
    if (std.mem.eql(u8, ctx.request.path() orelse "", "/")) try redirect(ctx, "/login") else try ctx.response.text(401, "Sign in first");
    return .respond;
}

fn loginPage(ctx: *Context) !void {
    try ctx.response.header("Cache-Control", "no-store");
    try ctx.response.borrowBody(200, "text/html; charset=utf-8", @embedFile("assets/jobs-login.html"));
}

fn login(ctx: *Context) !void {
    var body: [1024]u8 = undefined;
    const limits: web.params.Limits = .{ .max_bytes = body.len, .max_pairs = 2, .max_name_bytes = 16, .max_value_bytes = 128 };
    const fields = ctx.request.formUrlEncoded(limits) catch |err| switch (err) {
        error.BodyNotContiguous => try web.form.parse(try ctx.request.body().copyTo(&body), limits),
        else => return ctx.response.text(400, @errorName(err)),
    };
    var users = fields.allRaw("username");
    var passwords = fields.allRaw("password");
    const raw_user = users.next() orelse return ctx.response.text(400, "username is required");
    const raw_pass = passwords.next() orelse return ctx.response.text(400, "password is required");
    if (users.next() != null or passwords.next() != null) return ctx.response.text(400, "Duplicate credentials");
    var user_buffer: [128]u8 = undefined;
    var pass_buffer: [128]u8 = undefined;
    const user = web.params.formDecodeInto(raw_user.value_raw, &user_buffer) catch return ctx.response.text(400, "Invalid username");
    const pass = web.params.formDecodeInto(raw_pass.value_raw, &pass_buffer) catch return ctx.response.text(400, "Invalid password");
    const identity: u64 = if (std.mem.eql(u8, user, "zap")) 1 else if (std.mem.eql(u8, user, "baz")) 2 else 0;
    if (identity == 0 or pass.len != 7 or !std.crypto.timing_safe.eql([7]u8, pass[0..7].*, "awesome".*))
        return ctx.response.text(401, "Invalid demo credentials");
    const old = ctx.request.cookie(cookie_name) catch return ctx.response.text(400, "Invalid cookie");
    if (ctx.shared.busy.swap(true, .acquire)) return ctx.response.text(503, "Application state is busy");
    defer ctx.shared.busy.store(false, .release);
    const token = ctx.shared.sessions.create(identity, try now(ctx.app.io), ctx.shared.session_ttl_ns) catch |err| switch (err) {
        error.Full => return ctx.response.text(503, "Session capacity reached"),
        else => return err,
    };
    errdefer _ = ctx.shared.sessions.revoke(&token) catch false;
    try ctx.response.setCookie(cookie_name, &token, .{ .same_site = .strict });
    try redirect(ctx, "/");
    if (old) |previous| _ = ctx.shared.sessions.revoke(previous) catch false;
}

fn home(ctx: *Context) !void {
    try ctx.response.header("Cache-Control", "no-store");
    try ctx.response.mustache(200, &ctx.shared.template, .{ .username = if (ctx.locals.identity.? == 1) "zap" else "baz" });
}

fn createJob(ctx: *Context) !void {
    if (ctx.shared.busy.swap(true, .acquire)) return ctx.response.text(503, "Application state is busy");
    defer ctx.shared.busy.store(false, .release);
    const timestamp = try now(ctx.app.io);
    const identity = (try identityLocked(ctx, timestamp)) orelse return ctx.response.text(401, "Sign in first");
    const handle = ctx.shared.jobs.create(identity, timestamp, ctx.shared.job_ttl_ns) catch |err| switch (err) {
        error.Full => return ctx.response.text(503, "All eight job slots remain reserved until expiry"),
        else => return err,
    };
    var buffer: [32]u8 = undefined;
    const id = try std.fmt.bufPrint(&buffer, "{d}-{d}", .{ handle.slot, handle.generation });
    try ctx.response.header("Cache-Control", "no-store");
    try ctx.response.jsonValue(201, .{ .id = id });
}

fn decimal(comptime T: type, raw: []const u8) !T {
    if (raw.len == 0 or raw.len > 20 or (raw.len > 1 and raw[0] == '0')) return error.InvalidId;
    for (raw) |byte| if (byte < '0' or byte > '9') return error.InvalidId;
    return std.fmt.parseInt(T, raw, 10) catch error.InvalidId;
}

fn jobHandle(raw: []const u8) !jobs.Handle {
    const separator = std.mem.indexOfScalar(u8, raw, '-') orelse return error.InvalidId;
    const generation = try decimal(u64, raw[separator + 1 ..]);
    if (generation == 0) return error.InvalidId;
    return .{ .slot = try decimal(u16, raw[0..separator]), .generation = generation };
}

fn cursor(request: web.Request) !u64 {
    var headers = request.headers();
    var result: ?u64 = null;
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name_raw, "Last-Event-ID")) continue;
        if (result != null) return error.DuplicateId;
        result = try decimal(u64, header.value_raw);
    }
    return result orelse 0;
}

fn streamError(ctx: *Context, status: u16, message: []const u8) !Step {
    try ctx.response.text(status, message);
    return .finish;
}

fn startEvents(ctx: *Context, state: *State) !Step {
    state.job = jobHandle(ctx.param("id").?) catch return streamError(ctx, 400, "Invalid job ID");
    state.cursor = cursor(ctx.request) catch return streamError(ctx, 400, "Invalid Last-Event-ID");
    const shared = ctx.shared;
    if (shared.busy.swap(true, .acquire)) return streamError(ctx, 503, "Application state is busy");
    const replay = blk: {
        defer shared.busy.store(false, .release);
        const timestamp = try now(ctx.app.io);
        const identity = (try identityLocked(ctx, timestamp)) orelse return streamError(ctx, 401, "Sign in first");
        const result = shared.jobs.read(identity, state.job, state.cursor, timestamp) catch |err| switch (err) {
            error.NotFound => return streamError(ctx, 404, "Job not found"),
            error.InvalidCursor => return streamError(ctx, 400, "Cursor is ahead of this job"),
            else => return err,
        };
        if (result == .gap) return streamError(ctx, 409, "Replay expired; start a new job");
        if (result == .complete or std.mem.eql(u8, ctx.request.method(), "HEAD")) return streamError(ctx, 204, "");
        for (&shared.subscriptions, 0..) |*subscription, index| {
            if (subscription.active.load(.acquire)) continue;
            subscription.notification = try ctx.notification();
            subscription.active.store(true, .release);
            state.subscription = @intCast(index);
            _ = shared.started.fetchAdd(1, .monotonic);
            break;
        }
        if (state.subscription == null) return streamError(ctx, 503, "All 32 subscriber slots are active");
        break :blk result;
    };
    try ctx.response.header("Cache-Control", "no-store");
    _ = try ctx.response.snapshot(200, web.sse.content_type, .{});
    return emit(ctx, state, replay, false);
}

fn resumeEvents(ctx: *Context, state: *State, event: web.continuation.Event) !Step {
    const shared = ctx.shared;
    if (shared.busy.swap(true, .acquire)) return .{ .wait = 10 * std.time.ns_per_ms };
    const replay = blk: {
        defer shared.busy.store(false, .release);
        const timestamp = try now(ctx.app.io);
        const identity = (try identityLocked(ctx, timestamp)) orelse return endEvent(ctx, "session-expired");
        break :blk shared.jobs.read(identity, state.job, state.cursor, timestamp) catch |err| switch (err) {
            error.NotFound => return endEvent(ctx, "expired"),
            else => return err,
        };
    };
    return emit(ctx, state, replay, event == .timer);
}

fn endEvent(ctx: *Context, name: []const u8) !Step {
    var output = try ctx.response.resumeSnapshot();
    try web.sse.write(output.writer(), .{ .event = name, .data = "{}" });
    return .finish;
}

fn emit(ctx: *Context, state: *State, replay: jobs.Replay, timed_out: bool) !Step {
    switch (replay) {
        .event, .gap => |value| {
            var id_buffer: [20]u8 = undefined;
            var data_buffer: [64]u8 = undefined;
            var output = try ctx.response.resumeSnapshot();
            const id = try std.fmt.bufPrint(&id_buffer, "{d}", .{value.sequence});
            const data = try std.fmt.bufPrint(&data_buffer, "{{\"progress\":{d},\"done\":{s}}}", .{ value.progress, if (value.done) "true" else "false" });
            const event = if (replay == .gap) "reset" else if (value.done) "done" else "progress";
            try web.sse.write(output.writer(), .{ .event = event, .id = id, .data = data, .retry_ms = 1000 });
            state.cursor = value.sequence;
            return if (value.done or replay == .gap) .finish else .flush;
        },
        .complete => return .finish,
        .waiting => {
            if (timed_out) {
                var output = try ctx.response.resumeSnapshot();
                try web.sse.heartbeat(output.writer());
                return .flush;
            }
            return .{ .await_notification = std.time.ns_per_s };
        },
    }
}

fn logout(ctx: *Context) !void {
    if (ctx.shared.busy.swap(true, .acquire)) return ctx.response.text(503, "Application state is busy");
    defer ctx.shared.busy.store(false, .release);
    const token = (try ctx.request.cookie(cookie_name)).?;
    try ctx.response.deleteCookie(cookie_name, .{ .same_site = .strict });
    try redirect(ctx, "/login");
    _ = try ctx.shared.sessions.revoke(token);
}

fn health(ctx: *Context) !void {
    try ctx.response.text(200, "ok");
}

fn stop(ctx: *Context) !void {
    try ctx.response.text(200, "Stop requested");
    ctx.app.requestStop();
}

fn stylesheet(ctx: *Context) !void {
    try ctx.response.borrowBody(200, "text/css; charset=utf-8", @embedFile("assets/jobs.css"));
}

fn script(ctx: *Context) !void {
    try ctx.response.borrowBody(200, "text/javascript; charset=utf-8", @embedFile("assets/jobs.js"));
}

// The producer has one startup thread and fixed stack. HTTP callbacks never wait for this guard.
fn produce(shared: *Shared, io: std.Io) void {
    var next_tick: u64 = 0;
    while (!shared.stopping.load(.acquire)) {
        io.sleep(.fromMilliseconds(5), .awake) catch return;
        if (shared.busy.swap(true, .acquire)) continue;
        var notifications: [32]web.continuation.Notification = undefined;
        var count: usize = 0;
        collect: {
            defer shared.busy.store(false, .release);
            const timestamp = now(io) catch break :collect;
            if (timestamp < next_tick) break :collect;
            next_tick = std.math.add(u64, timestamp, shared.tick_ns) catch break :collect;
            var handles: [8]jobs.Handle = undefined;
            const active = shared.jobs.active(&handles, timestamp) catch break :collect;
            for (handles[0..active]) |handle| _ = shared.jobs.advance(handle, 10, timestamp) catch continue;
            for (&shared.subscriptions) |*subscription| {
                if (!subscription.active.load(.acquire)) continue;
                notifications[count] = subscription.notification;
                count += 1;
            }
        }
        // Copied handles contain no request pointers. Cleanup and reuse can make a copy stale.
        for (notifications[0..count]) |notification| _ = notification.signal();
    }
}

pub fn main(init: std.process.Init) !void {
    const options = try support.parseOptions(init, Options);
    if (options.session_ttl_ms == 0 or options.job_ttl_ms == 0 or options.tick_ms == 0) return error.InvalidLifetime;
    var key: sessions.Key = undefined;
    try init.io.randomSecure(&key);
    var shared: Shared = .{
        .template = try web.mustache.Template.init(init.gpa, @embedFile("assets/jobs.html"), .{}),
        .sessions = .init(key),
        .session_ttl_ns = @as(u64, options.session_ttl_ms) * std.time.ns_per_ms,
        .job_ttl_ns = @as(u64, options.job_ttl_ms) * std.time.ns_per_ms,
        .tick_ns = @as(u64, options.tick_ms) * std.time.ns_per_ms,
    };
    std.crypto.secureZero(u8, &key);
    defer shared.template.deinit();
    defer shared.sessions.deinit();
    var config = try support.configFromOptions(options, false);
    config.timeout_ms = 10000;
    config.max_response_bytes = 64 * 1024;
    config.shutdown_ms = 1000;
    const app = try Application.init(.{
        .allocator = init.gpa,
        .io = init.io,
        .shared = &shared,
        .server = config,
        .response = .{ .body_bytes = 8192 },
        .max_continuations = 32,
        .max_continuation_state_bytes = 256,
        .middleware = &.{.{ .before = guardPost }},
    });
    defer app.deinit();
    try app.route("GET", "/login", loginPage);
    try app.route("POST", "/login", login);
    try app.route("GET", "/health", health);
    try app.route("GET", "/jobs.css", stylesheet);
    try app.route("GET", "/jobs.js", script);
    const protected: Application.RouteOptions = .{ .middleware = &.{.{ .before = authenticate }} };
    try app.routeWith("GET", "/", home, protected);
    try app.routeWith("POST", "/jobs", createJob, protected);
    try app.routeContinuation("GET", "/jobs/:id/events", State, startEvents, resumeEvents, protected);
    try app.routeContinuation("HEAD", "/jobs/:id/events", State, startEvents, resumeEvents, protected);
    try app.routeWith("POST", "/logout", logout, protected);
    try app.routeWith("POST", "/stop", stop, protected);
    const producer = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, produce, .{ &shared, init.io });
    defer {
        shared.stopping.store(true, .release);
        producer.join();
    }
    try support.run(app, init);
    std.debug.print("JOBS started={d} cleaned={d}\n", .{ shared.started.load(.monotonic), shared.cleaned.load(.monotonic) });
}

test "job URLs and reconnect cursors use canonical bounded decimal IDs" {
    try std.testing.expectEqual(jobs.Handle{ .slot = 7, .generation = 42 }, try jobHandle("7-42"));
    for ([_][]const u8{ "", "0", "00-1", "0-0", "1-01", "1-+1", "1-1-1", "65536-1", "1-18446744073709551616" }) |invalid|
        try std.testing.expectError(error.InvalidId, jobHandle(invalid));
    try std.testing.expectEqual(@as(u64, 0), try decimal(u64, "0"));
    try std.testing.expectError(error.InvalidId, decimal(u64, "01"));
}
