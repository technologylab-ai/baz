//! Worker callbacks parse bounded JSON and serialize a fixed, synchronized user table.
const std = @import("std");
const web = @import("http_app");
const support = @import("example_support");
const users = @import("endpoint/users.zig");

const Shared = struct { store: users.Store = .{} };
const Application = web.App(Shared);
const Context = Application.Context;
const Input = struct { first_name: ?[]const u8 = null, last_name: ?[]const u8 = null };

fn input(ctx: *Context, body_buffer: []u8, allocator: std.mem.Allocator) !std.json.Parsed(Input) {
    var content_type: ?[]const u8 = null;
    var fields = ctx.request.headers();
    while (fields.next()) |field| {
        if (std.ascii.eqlIgnoreCase(field.name_raw, "Content-Type")) {
            if (content_type != null) return error.InvalidJson;
            content_type = field.value_raw;
        }
        if (std.ascii.eqlIgnoreCase(field.name_raw, "Content-Encoding") and
            !std.ascii.eqlIgnoreCase(field.value_raw, "identity")) return error.UnsupportedMediaType;
    }
    const media = web.form.mediaType(content_type orelse return error.UnsupportedMediaType, .{}) catch return error.InvalidJson;
    if (!media.is("application/json")) return error.UnsupportedMediaType;
    if (ctx.request.body().len() > body_buffer.len) return error.InputTooLarge;
    const body = try ctx.request.body().copyTo(body_buffer);
    return std.json.parseFromSlice(Input, allocator, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.InputTooLarge,
        else => error.InvalidJson,
    };
}

fn idFromContext(ctx: *Context) !u64 {
    const raw = ctx.param("id") orelse return error.InvalidUserId;
    if (raw.len == 0) return error.InvalidUserId;
    for (raw) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidUserId;
    return std.fmt.parseInt(u64, raw, 10) catch error.InvalidUserId;
}

const Collection = struct {
    pub fn get(_: *Collection, ctx: *Context) !void {
        const io = try ctx.serviceIo();
        const store = &ctx.shared.store;
        store.lock.lockUncancelable(io);
        defer store.lock.unlock(io);
        var views: [users.max_users]users.View = undefined;
        var count: usize = 0;
        for (&store.users) |*user| {
            if (!user.occupied) continue;
            views[count] = user.view();
            count += 1;
        }
        // Serialization copies all borrowed names before the mutex unlocks.
        return ctx.response.jsonValue(200, views[0..count]);
    }

    pub fn post(_: *Collection, ctx: *Context) !void {
        const io = try ctx.serviceIo();
        var body: [4096]u8 = undefined;
        var scratch: [16384]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&scratch);
        const parsed = try input(ctx, &body, fixed.allocator());
        defer parsed.deinit();
        const first = parsed.value.first_name orelse return error.MissingUserFields;
        const store = &ctx.shared.store;
        store.lock.lockUncancelable(io);
        defer store.lock.unlock(io);
        const id = try store.add(first, parsed.value.last_name orelse "");
        return ctx.response.jsonValue(201, .{ .status = "OK", .id = id });
    }

    pub fn options(_: *Collection, ctx: *Context) !void {
        try ctx.response.header("Allow", "GET, HEAD, POST, OPTIONS");
        try ctx.response.header("Access-Control-Allow-Origin", "*");
        try ctx.response.header("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS, HEAD");
        try ctx.response.header("Access-Control-Allow-Headers", "Content-Type");
        return ctx.response.text(204, "");
    }
};

const Item = struct {
    pub fn get(_: *Item, ctx: *Context) !void {
        const id = try idFromContext(ctx);
        const io = try ctx.serviceIo();
        const store = &ctx.shared.store;
        store.lock.lockUncancelable(io);
        defer store.lock.unlock(io);
        const user = store.get(id) orelse return error.UserNotFound;
        return ctx.response.jsonValue(200, user.view());
    }

    pub fn patch(_: *Item, ctx: *Context) !void {
        const id = try idFromContext(ctx);
        const io = try ctx.serviceIo();
        var body: [4096]u8 = undefined;
        var scratch: [16384]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&scratch);
        const parsed = try input(ctx, &body, fixed.allocator());
        defer parsed.deinit();
        if (parsed.value.first_name == null and parsed.value.last_name == null) return error.MissingUserFields;
        const store = &ctx.shared.store;
        store.lock.lockUncancelable(io);
        defer store.lock.unlock(io);
        const user = store.get(id) orelse return error.UserNotFound;
        try user.update(parsed.value.first_name, parsed.value.last_name);
        return ctx.response.jsonValue(200, .{ .status = "OK", .id = id });
    }

    pub fn delete(_: *Item, ctx: *Context) !void {
        const id = try idFromContext(ctx);
        const io = try ctx.serviceIo();
        const store = &ctx.shared.store;
        store.lock.lockUncancelable(io);
        defer store.lock.unlock(io);
        if (!store.remove(id)) return error.UserNotFound;
        return ctx.response.jsonValue(200, .{ .status = "OK", .id = id });
    }
};

fn page(ctx: *Context) !void {
    return ctx.response.borrowBody(200, "text/html; charset=utf-8", @embedFile("assets/endpoint.html"));
}

fn fallback(ctx: *Context) !void {
    return ctx.response.bytes(404, "text/html; charset=utf-8", "<html><body><h1>Unknown endpoint</h1><a href=\"/\">User example</a></body></html>");
}

fn fail(_: *Context) !void {
    return error.DemoFailure;
}

fn mapError(ctx: *Context, err: anyerror) !void {
    const status: u16 = switch (err) {
        error.InvalidJson, error.InvalidUserId, error.MissingUserFields => 400,
        error.UserNotFound => 404,
        error.UserNameTooLong, error.InputTooLarge => 413,
        error.UnsupportedMediaType => 415,
        error.UserCapacityReached => 503,
        else => 500,
    };
    return ctx.response.jsonValue(status, .{ .status = "ERROR", .message = web.api.reason(status) });
}

fn stop(ctx: *Context) !void {
    try ctx.response.text(200, "Stop requested");
    ctx.app.requestStop();
}

pub fn main(init: std.process.Init) !void {
    var shared: Shared = .{};
    _ = try shared.store.add("renerocksai", "");
    _ = try shared.store.add("renerocksai", "your mom");
    // Blocking table locks and the bounded JSON allocator run only on workers.
    const app = try Application.init(.{ .allocator = init.gpa, .io = init.io, .shared = &shared, .server = try support.workerConfig(init), .response = .{ .body_bytes = 16384 }, .not_found = fallback, .on_error = mapError });
    defer app.deinit();
    var collection: Collection = .{};
    var item: Item = .{};
    try app.endpoint("/users", &collection);
    try app.endpoint("/users/:id", &item);
    try app.route("GET", "/", page);
    try app.route("GET", "/index.html", page);
    try app.route("GET", "/error", fail);
    try app.route("GET", "/unhandled", fail);
    try app.route("GET", "/stop", stop);
    try support.run(app, init);
}
