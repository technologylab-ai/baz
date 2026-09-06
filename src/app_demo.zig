//! Runnable first application slice. All request helpers use the public module.
const std = @import("std");
const web = @import("http_app");

const Shared = struct {
    greeting: []const u8 = "Hello from the App API",
    count: std.atomic.Value(usize) = .init(0),
    uploads: std.atomic.Value(usize) = .init(0),
    stall_ms: u32 = 100,
};
const Application = web.App(Shared);
const Context = Application.Context;
var active_app: ?*Application = null;

fn stopSignal(_: std.posix.SIG) callconv(.c) void {
    if (active_app) |app| app.requestStopFromSignal();
}

const Hello = struct {
    pub fn get(_: *Hello, ctx: *Context) !void {
        const query = try ctx.request.query();
        if (query.firstRaw("name")) |param| {
            var decoded: [1024]u8 = undefined;
            const name = try web.params.percentDecodeInto(param.value_raw, &decoded);
            return ctx.response.text(200, name); // copies before stack storage ends
        }
        return ctx.response.text(200, ctx.shared.greeting);
    }
};

const User = struct {
    label: []const u8 = "user",

    pub fn get(self: *User, ctx: *Context) !void {
        return ctx.response.jsonValue(200, .{ .kind = self.label, .id = ctx.param("id").? });
    }
};

fn count(ctx: *Context) !void {
    const value = ctx.shared.count.fetchAdd(1, .monotonic) + 1;
    return ctx.response.jsonValue(200, .{ .count = value });
}

fn countValue(ctx: *Context) !void {
    return ctx.response.jsonValue(200, .{ .count = ctx.shared.count.load(.monotonic) });
}

fn rawQuery(ctx: *Context) !void {
    return ctx.response.text(200, ctx.request.target().query_raw orelse "");
}

fn rawValue(ctx: *Context) !void {
    const query = try ctx.request.query();
    const value = query.firstRaw("value") orelse return ctx.response.text(400, "missing value");
    return ctx.response.text(200, value.value_raw);
}

fn postForm(ctx: *Context) !void {
    // A bounded, explicit copy handles bodies split across HTTP chunks.
    // The form views borrow this destination only until this callback returns.
    var body_buffer: [4096]u8 = undefined;
    const fields = ctx.request.formUrlEncoded(.{ .max_bytes = body_buffer.len }) catch |err| switch (err) {
        error.BodyNotContiguous => blk: {
            const body = try ctx.request.body().copyTo(&body_buffer);
            break :blk try web.form.parse(body, .{ .max_bytes = body_buffer.len });
        },
        else => return err,
    };
    const field = fields.firstRaw("value") orelse return ctx.response.text(400, "missing value");
    var decoded: [1024]u8 = undefined;
    const value = try web.params.formDecodeInto(field.value_raw, &decoded);
    return ctx.response.text(200, value);
}

fn upload(ctx: *Context) !void {
    var body_buffer: [8192]u8 = undefined;
    const limits: web.multipart.Limits = .{ .max_bytes = body_buffer.len, .max_parts = 8 };
    const parts = ctx.request.formMultipart(limits) catch |err| switch (err) {
        error.BodyNotContiguous => blk: {
            var boundary_buffer: [web.multipart.max_boundary_bytes]u8 = undefined;
            const boundary = try ctx.request.multipartBoundaryInto(&boundary_buffer);
            const body = try ctx.request.body().copyTo(&body_buffer);
            break :blk try web.multipart.parse(body, boundary, limits);
        },
        else => return err,
    };
    const Summary = struct {
        name_raw: []const u8,
        filename_raw: ?[]const u8,
        content_type_raw: ?[]const u8,
        size: usize,
        byte_sum: u64,
    };
    var summaries: [8]Summary = undefined;
    var it = parts.iterator();
    var count_parts: usize = 0;
    while (it.next()) |part| {
        var sum: u64 = 0;
        for (part.data) |byte| sum += byte;
        summaries[count_parts] = .{ .name_raw = part.name_raw, .filename_raw = part.filename_raw, .content_type_raw = part.content_type_raw, .size = part.data.len, .byte_sum = sum };
        count_parts += 1;
    }
    // Full multipart validation precedes this application side effect.
    const accepted = ctx.shared.uploads.fetchAdd(1, .monotonic) + 1;
    return ctx.response.jsonValue(200, .{ .accepted = accepted, .parts = summaries[0..count_parts] });
}

fn uploadCount(ctx: *Context) !void {
    return ctx.response.jsonValue(200, .{ .accepted = ctx.shared.uploads.load(.monotonic) });
}

fn echo(ctx: *Context) !void {
    var bytes: [8192]u8 = undefined;
    const body = try ctx.request.body().copyTo(&bytes);
    return ctx.response.bytes(200, "application/octet-stream", body);
}

fn borrowedEcho(ctx: *Context) !void {
    const body = ctx.request.body().contiguous() orelse return ctx.response.text(400, "body is segmented");
    return ctx.response.borrowBody(200, "application/octet-stream", body);
}

fn headers(ctx: *Context) !void {
    var name = "X-App-Value".*;
    var value = "temporary".*;
    try ctx.response.header(&name, &value);
    @memset(&name, 'x');
    @memset(&value, 'y');
    try ctx.response.header("Set-Cookie", "a=1; Path=/; HttpOnly; SameSite=Lax");
    try ctx.response.header("Set-Cookie", "b=2; Path=/; HttpOnly; SameSite=Lax");
    return ctx.response.text(200, "headers copied");
}

fn redirect(ctx: *Context) !void {
    try ctx.response.header("Location", "/hello");
    return ctx.response.bytes(303, "text/plain", "");
}

fn fail(_: *Context) !void {
    return error.DemoFailure;
}

fn invalidHeader(ctx: *Context) !void {
    try ctx.response.header("X-Test", "bad\r\nInjected: yes");
}

fn tooLarge(ctx: *Context) !void {
    const bytes = "x" ** 9000;
    return ctx.response.text(200, bytes);
}

fn noResponse(_: *Context) !void {}

fn twice(ctx: *Context) !void {
    try ctx.response.text(200, "first");
    try ctx.response.text(201, "second");
}

fn workerService(ctx: *Context) !void {
    const io = ctx.serviceIo() catch return ctx.response.text(501, "select worker execution");
    try io.sleep(std.Io.Duration.fromMilliseconds(ctx.shared.stall_ms), .awake);
    return ctx.response.text(200, "worker service complete");
}

fn earlierStatic(ctx: *Context) !void {
    return ctx.response.text(200, "earlier static");
}

fn laterStatic(ctx: *Context) !void {
    return ctx.response.text(200, "later static");
}

fn explicitHead(ctx: *Context) !void {
    try ctx.response.header("X-Handler", "explicit HEAD");
    return ctx.response.text(200, "head");
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    var shared: Shared = .{};
    var server: web.Config = .{ .port = 8080, .shards = 1 };
    var limits: web.ResponseLimits = .{};
    while (args.next()) |flag| {
        if (std.mem.eql(u8, flag, "--help")) {
            std.debug.print("HTTP App example: --port N --execution inline|workers --workers N --shards N\n" ++
                "--connections N --max-body N --max-header N --output-bytes N --response-body N\n" ++
                "--timeout-ms N --duration-ms N --send-chunk N --stall-ms N\n", .{});
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
        } else if (std.mem.eql(u8, flag, "--timeout-ms")) {
            server.timeout_ms = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--duration-ms")) {
            server.duration_ms = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--send-chunk")) {
            server.send_chunk = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--stall-ms")) {
            shared.stall_ms = try std.fmt.parseInt(u32, value, 10);
        } else return error.InvalidArgument;
    }
    if (shared.stall_ms > 5000) return error.InvalidArgument;

    const app = try Application.init(.{ .allocator = init.gpa, .io = init.io, .shared = &shared, .server = server, .response = limits });
    defer app.deinit();
    var hello: Hello = .{};
    var users: User = .{};
    try app.endpoint("/", &hello);
    try app.endpoint("/hello", &hello);
    try app.endpoint("/users/:id", &users);
    try app.route("POST", "/count", count);
    try app.route("GET", "/count", countValue);
    try app.route("GET", "/raw-query", rawQuery);
    try app.route("GET", "/raw-value", rawValue);
    try app.route("POST", "/form", postForm);
    try app.route("POST", "/upload", upload);
    try app.route("GET", "/upload-count", uploadCount);
    try app.route("POST", "/echo", echo);
    try app.route("POST", "/borrow", borrowedEcho);
    try app.route("GET", "/headers", headers);
    try app.route("GET", "/redirect", redirect);
    try app.route("GET", "/fail", fail);
    try app.route("GET", "/invalid-header", invalidHeader);
    try app.route("GET", "/too-large", tooLarge);
    try app.route("GET", "/no-response", noResponse);
    try app.route("GET", "/twice", twice);
    try app.route("GET", "/service", workerService);
    try app.route("GET", "/left/:x/fixed", laterStatic);
    try app.route("GET", "/left/fixed/:y", earlierStatic);
    try app.route("GET", "/right/fixed/:y", earlierStatic);
    try app.route("GET", "/right/:x/fixed", laterStatic);
    try app.route("POST", "/right/:x/fixed", laterStatic);
    try app.route("GET", "/head", earlierStatic);
    try app.route("HEAD", "/head", explicitHead);
    try app.route("M-SEARCH", "/extension", earlierStatic);
    try app.start();
    active_app = app;
    defer active_app = null;
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = stopSignal }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
    std.debug.print("READY port={d} backend={s} execution={s} optimize={s}\n", .{ app.port(), web.backend_name, @tagName(server.execution), @tagName(@import("builtin").mode) });
    app.run() catch |err| {
        std.debug.print("FATAL {s}; App storage remains borrowed\n", .{@errorName(err)});
        std.c._exit(70);
    };
    const stats = try std.json.Stringify.valueAlloc(init.gpa, app.stats(), .{});
    defer init.gpa.free(stats);
    std.debug.print("STATS {s}\n", .{stats});
}
