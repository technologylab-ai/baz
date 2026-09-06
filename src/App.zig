//! Typed, instance-owned application composition over the bounded HTTP engine.
const std = @import("std");
const engine = @import("bounded_http");
const Request = @import("request.zig").Request;
const responses = @import("response.zig");
const routing = @import("router.zig");

pub fn App(comptime Shared: type) type {
    return AppWithLocals(Shared, struct {});
}

/// Locals have field defaults and live at a stable address for one request.
/// Their fixed callback storage uses the startup-reserved execution stacks.
pub fn AppWithLocals(comptime Shared: type, comptime Locals: type) type {
    if (@typeInfo(Locals) != .@"struct" or @sizeOf(Locals) > 4096 or @alignOf(Locals) > 64)
        @compileError("request locals must be a struct of at most 4096 bytes with alignment at most 64");
    return struct {
        const Self = @This();
        pub const Handler = *const fn (*Context) anyerror!void;
        pub const ErrorHandler = *const fn (*Context, anyerror) anyerror!void;
        pub const Decision = enum { continue_request, respond };
        pub const Middleware = struct {
            before: ?*const fn (*Context) anyerror!Decision = null,
            after: ?Handler = null,
            /// Always runs for entered middleware, in reverse order. Cleanup
            /// releases application resources; it must not change the response.
            cleanup: ?*const fn (*Context) void = null,
        };
        pub const RouteOptions = struct { middleware: []const Middleware = &.{} };
        const BoundHandler = *const fn (?*anyopaque, *Context) anyerror!void;
        const Phase = enum { registration, starting, started, running, stopped, failed, unsafe };

        pub const Options = struct {
            allocator: std.mem.Allocator,
            io: std.Io,
            shared: *Shared,
            server: engine.Config = .{},
            response: responses.Limits = .{},
            max_routes: u16 = 128,
            /// Total copied global and route middleware descriptors.
            max_middleware: u16 = 128,
            middleware: []const Middleware = &.{},
            /// Locals already contain their field defaults, even on init error.
            init_locals: ?Handler = null,
            cleanup_locals: ?*const fn (*Context) void = null,
            /// Combined owned route/method strings and generated Allow values.
            route_bytes: u32 = 16384,
            not_found: ?Handler = null,
            on_error: ?ErrorHandler = null,
        };

        pub const Context = struct {
            shared: *Shared,
            locals: *Locals,
            request: Request,
            response: *responses.Response,
            captures: routing.Captures,
            app: *Self,
            cancelled: *const std.atomic.Value(bool),
            global_entered: usize = 0,
            route_entered: usize = 0,
            route_middleware: []const Middleware = &.{},

            pub fn param(self: *const Context, name: []const u8) ?[]const u8 {
                return self.captures.get(name);
            }

            /// The selected implementation may block. Inline callbacks cannot
            /// obtain it through this helper; shared services remain responsible
            /// for their own capabilities, deadlines and allocation behavior.
            pub fn serviceIo(self: *const Context) error{IoRequiresWorkers}!std.Io {
                if (self.app.config.execution != .workers) return error.IoRequiresWorkers;
                return self.app.io;
            }

            /// Sleep on this fixed worker, checking connection cancellation
            /// between bounded waits. The caller's Io controls each wait;
            /// custom providers must honor its clock and sleep contracts.
            pub fn sleep(self: *const Context, duration: std.Io.Duration) !void {
                const io = try self.serviceIo();
                if (duration.nanoseconds < 0) return error.InvalidDuration;
                const started_at = std.Io.Timestamp.now(io, .awake);
                const deadline = std.math.add(i96, started_at.nanoseconds, duration.nanoseconds) catch return error.InvalidDuration;
                while (true) {
                    if (self.cancelled.load(.acquire)) return error.Cancelled;
                    const now = std.Io.Timestamp.now(io, .awake).nanoseconds;
                    if (now >= deadline) return;
                    const remaining = std.math.sub(i96, deadline, now) catch return error.InvalidDuration;
                    try io.sleep(.fromNanoseconds(@min(remaining, 5 * std.time.ns_per_ms)), .awake);
                }
            }
        };

        const Route = struct {
            method: []const u8,
            pattern: []const u8,
            rank: u32,
            call: BoundHandler,
            instance: ?*anyopaque,
            allow: []const u8 = "",
            middleware: []const Middleware = &.{},
        };

        // init returns a stable allocation; all callbacks retain this address.
        budget: engine.Budget,
        io: std.Io,
        shared: *Shared,
        config: engine.Config,
        response_limits: responses.Limits,
        routes: []Route,
        routes_len: usize = 0,
        middleware: []Middleware,
        middleware_len: usize = 0,
        global_middleware_len: usize = 0,
        init_locals: ?Handler,
        cleanup_locals: ?*const fn (*Context) void,
        names: []u8,
        names_len: usize = 0,
        global_allow: []const u8 = "",
        not_found: ?Handler,
        on_error: ?ErrorHandler,
        cluster: ?*engine.Cluster = null,
        phase: Phase = .registration,

        pub fn init(options: Options) !*Self {
            if (options.max_routes == 0 or options.max_routes > 4096 or
                options.route_bytes < 64 or options.route_bytes > 1024 * 1024 or options.max_middleware > 4096)
                return error.InvalidConfiguration;
            if (options.middleware.len > options.max_middleware) return error.TooManyMiddleware;
            try validateMiddleware(options.middleware);
            var config = options.server;
            config.callback_output_reserve = @intCast(try options.response.reservationBytes());
            if (config.max_response_bytes < options.response.body_bytes) return error.InvalidConfiguration;
            try engine.Cluster.validate(config);
            const stacks = try engine.Cluster.stackBytes(config);
            var heap = try std.math.add(usize, @sizeOf(Self), try engine.Cluster.heapBytes(config));
            heap = try std.math.add(usize, heap, try std.math.mul(usize, options.max_routes, @sizeOf(Route)));
            heap = try std.math.add(usize, heap, options.route_bytes);
            heap = try std.math.add(usize, heap, try std.math.mul(usize, options.max_middleware, @sizeOf(Middleware)));
            if (try std.math.add(usize, heap, stacks) > config.memory_budget_bytes)
                return error.MemoryBudgetExceeded;

            // Bootstrap the stable owner, then explicitly include those bytes
            // in the same ledger used for all subsequent framework allocations.
            const self = try options.allocator.create(Self);
            self.* = .{
                .budget = .{ .upstream = options.allocator, .limit_bytes = config.memory_budget_bytes - stacks, .live_bytes = @sizeOf(Self), .peak_bytes = @sizeOf(Self) },
                .io = options.io,
                .shared = options.shared,
                .config = config,
                .response_limits = options.response,
                .routes = &.{},
                .middleware = &.{},
                .init_locals = options.init_locals,
                .cleanup_locals = options.cleanup_locals,
                .names = &.{},
                .not_found = options.not_found,
                .on_error = options.on_error,
            };
            const allocator = self.budget.allocator();
            errdefer allocator.destroy(self);
            self.routes = try allocator.alloc(Route, options.max_routes);
            errdefer allocator.free(self.routes);
            self.names = try allocator.alloc(u8, options.route_bytes);
            errdefer allocator.free(self.names);
            self.middleware = try allocator.alloc(Middleware, options.max_middleware);
            @memcpy(self.middleware[0..options.middleware.len], options.middleware);
            self.middleware_len = options.middleware.len;
            self.global_middleware_len = options.middleware.len;
            return self;
        }

        /// Register a function before start. Registration copies method/path.
        pub fn route(self: *Self, method: []const u8, path: []const u8, comptime handler: Handler) !void {
            return self.routeWith(method, path, handler, .{});
        }

        pub fn routeWith(self: *Self, method: []const u8, path: []const u8, comptime handler: Handler, options: RouteOptions) !void {
            const Adapter = struct {
                fn call(_: ?*anyopaque, context: *Context) anyerror!void {
                    return handler(context);
                }
            };
            try self.addRoute(method, path, null, Adapter.call, options);
        }

        /// Register a stateful method. The instance is borrowed through deinit.
        pub fn bind(self: *Self, method: []const u8, path: []const u8, instance: anytype, comptime handler: anytype) !void {
            return self.bindWith(method, path, instance, handler, .{});
        }

        pub fn bindWith(self: *Self, method: []const u8, path: []const u8, instance: anytype, comptime handler: anytype, options: RouteOptions) !void {
            const Pointer = @TypeOf(instance);
            const info = @typeInfo(Pointer);
            if (info != .pointer or info.pointer.size != .one or info.pointer.is_const)
                @compileError("a bound endpoint must be a mutable single-item pointer");
            const Adapter = struct {
                fn call(opaque_instance: ?*anyopaque, context: *Context) anyerror!void {
                    const value: Pointer = @ptrCast(@alignCast(opaque_instance.?));
                    return handler(value, context);
                }
            };
            try self.addRoute(method, path, @ptrCast(instance), Adapter.call, options);
        }

        /// Register conventional endpoint methods atomically. No base struct,
        /// path field or per-endpoint error-policy field is required.
        pub fn endpoint(self: *Self, path: []const u8, instance: anytype) !void {
            return self.endpointWith(path, instance, .{});
        }

        pub fn endpointWith(self: *Self, path: []const u8, instance: anytype, options: RouteOptions) !void {
            if (self.phase != .registration) return error.RegistrationClosed;
            const T = @typeInfo(@TypeOf(instance)).pointer.child;
            const old_count = self.routes_len;
            const old_bytes = self.names_len;
            const old_middleware = self.middleware_len;
            errdefer {
                self.routes_len = old_count;
                self.names_len = old_bytes;
                self.middleware_len = old_middleware;
            }
            inline for (.{ .{ "GET", "get" }, .{ "POST", "post" }, .{ "PUT", "put" }, .{ "DELETE", "delete" }, .{ "PATCH", "patch" }, .{ "HEAD", "head" }, .{ "OPTIONS", "options" } }) |method| {
                if (@hasDecl(T, method[1])) try self.bindWith(method[0], path, instance, @field(T, method[1]), options);
            }
            if (self.routes_len == old_count) return error.NoEndpointMethods;
        }

        fn validateMiddleware(chain: []const Middleware) !void {
            for (chain) |hook| {
                if (hook.before == null and hook.after == null and hook.cleanup == null) return error.InvalidMiddleware;
            }
        }

        fn addRoute(self: *Self, method: []const u8, path: []const u8, instance: ?*anyopaque, call: BoundHandler, options: RouteOptions) !void {
            if (self.phase != .registration) return error.RegistrationClosed;
            if (!routing.validMethod(method)) return error.InvalidMethod;
            try validateMiddleware(options.middleware);
            if (options.middleware.len > self.middleware.len - self.middleware_len) return error.TooManyMiddleware;
            const rank = try routing.validate(path);
            for (self.routes[0..self.routes_len]) |other| {
                if (std.mem.eql(u8, method, other.method) and routing.equivalent(path, other.pattern))
                    return error.DuplicateRoute;
            }
            if (self.routes_len == self.routes.len) return error.TooManyRoutes;
            const needed = try std.math.add(usize, method.len, path.len);
            if (needed > self.names.len - self.names_len) return error.RouteStorageFull;
            const method_copy = self.names[self.names_len..][0..method.len];
            @memcpy(method_copy, method);
            self.names_len += method.len;
            const path_copy = self.names[self.names_len..][0..path.len];
            @memcpy(path_copy, path);
            self.names_len += path.len;
            const chain = self.middleware[self.middleware_len..][0..options.middleware.len];
            @memcpy(chain, options.middleware);
            self.routes[self.routes_len] = .{ .method = method_copy, .pattern = path_copy, .rank = rank, .instance = instance, .call = call, .middleware = chain };
            self.middleware_len += chain.len;
            self.routes_len += 1;
        }

        fn methodSeen(self: *const Self, before: usize, pattern: ?[]const u8, method: []const u8) bool {
            for (self.routes[0..before]) |entry| {
                if (pattern) |p| if (!routing.equivalent(p, entry.pattern)) continue;
                if (std.mem.eql(u8, entry.method, method)) return true;
            }
            return false;
        }

        fn makeAllow(self: *Self, pattern: ?[]const u8) ![]const u8 {
            var writer: std.Io.Writer = .fixed(self.names[self.names_len..]);
            for (self.routes[0..self.routes_len], 0..) |entry, index| {
                if (pattern) |p| if (!routing.equivalent(p, entry.pattern)) continue;
                if (self.methodSeen(index, pattern, entry.method)) continue;
                if (writer.end != 0) try writer.writeAll(", ");
                try writer.writeAll(entry.method);
            }
            if (self.methodSeen(self.routes_len, pattern, "GET") and !self.methodSeen(self.routes_len, pattern, "HEAD")) {
                if (writer.end != 0) try writer.writeAll(", ");
                try writer.writeAll("HEAD");
            }
            if (!self.methodSeen(self.routes_len, pattern, "OPTIONS")) {
                if (writer.end != 0) try writer.writeAll(", ");
                try writer.writeAll("OPTIONS");
            }
            if (writer.end + "Allow: \r\n".len > self.response_limits.header_bytes) return error.HeaderLimitExceeded;
            const result = writer.buffer[0..writer.end];
            self.names_len += writer.end;
            return result;
        }

        pub fn start(self: *Self) !void {
            if (self.phase != .registration) return error.InvalidState;
            self.phase = .starting;
            errdefer self.phase = .failed;
            for (self.routes[0..self.routes_len], 0..) |*entry, index| {
                for (self.routes[0..index]) |other| {
                    if (routing.equivalent(entry.pattern, other.pattern)) {
                        entry.allow = other.allow;
                        break;
                    }
                } else entry.allow = try self.makeAllow(entry.pattern);
            }
            self.global_allow = try self.makeAllow(null);
            const cluster = try engine.Cluster.init(self.budget.allocator(), self.config, dispatch, self);
            errdefer cluster.deinit();
            try cluster.start();
            self.cluster = cluster;
            self.budget.sealed.store(true, .release);
            self.phase = .started;
        }

        pub fn port(self: *const Self) u16 {
            return self.cluster.?.port();
        }

        pub fn requestStop(self: *Self) void {
            if (self.cluster) |cluster| cluster.requestStop();
        }

        /// Only atomic stop flags, matching the maintained POSIX demo. Install
        /// signal handling in main, after start, and keep App alive through it.
        pub fn requestStopFromSignal(self: *Self) void {
            if (self.cluster) |cluster| cluster.requestStopFromSignal();
        }

        /// On an error, ownership may remain outstanding: terminate the process
        /// or retain the entire App. Do not unwind into deinit on that path.
        pub fn run(self: *Self) !void {
            if (self.phase != .started) return error.InvalidState;
            self.phase = .running;
            self.cluster.?.run() catch |err| {
                self.phase = .unsafe;
                return err;
            };
            self.phase = .stopped;
        }

        /// Stats are a snapshot only before run or after terminal shutdown.
        pub fn stats(self: *const Self) engine.Stats {
            std.debug.assert(self.phase == .started or self.phase == .stopped);
            var result = self.cluster.?.stats();
            result.allocation_calls_after_start = self.budget.late_calls.load(.acquire);
            result.framework_heap_peak_bytes = self.budget.peak_bytes;
            result.framework_heap_limit_bytes = self.budget.limit_bytes;
            return result;
        }

        pub fn deinit(self: *Self) void {
            if (self.phase == .started) {
                self.requestStop();
                self.run() catch engine.failFast(70);
            }
            std.debug.assert(self.phase == .registration or self.phase == .failed or self.phase == .stopped);
            if (self.cluster) |cluster| cluster.deinit();
            const allocator = self.budget.allocator();
            allocator.free(self.names);
            allocator.free(self.routes);
            allocator.free(self.middleware);
            std.debug.assert(self.budget.live_bytes == @sizeOf(Self));
            allocator.destroy(self);
        }

        fn dispatch(raw: *engine.api.Context) engine.api.Action {
            const self: *Self = @ptrCast(@alignCast(raw.application.?));
            // Worker streams retain this same callback stack across flushes.
            // The engine's separate continuation API is not used by App.
            std.debug.assert(raw.event == .request);
            var response = responses.Response.initWithLimit(raw.writer, self.response_limits, self.config.max_response_bytes) catch return .close;
            response.context = raw;
            var locals: Locals = .{};
            var context: Context = .{ .shared = self.shared, .locals = &locals, .request = .init(raw.request), .response = &response, .captures = .{}, .app = self, .cancelled = raw.cancelled };
            defer self.cleanup(&context);
            self.process(&context) catch |err| return self.handleError(&context, err);
            return response.finish() catch |err| self.handleError(&context, err);
        }

        fn runBefore(context: *Context, chain: []const Middleware, entered: *usize) !Decision {
            for (chain) |hook| {
                if (context.cancelled.load(.acquire)) return error.Cancelled;
                entered.* += 1;
                if (hook.before) |call| {
                    const decision = try call(context);
                    if (decision == .respond) {
                        if (!context.response.prepared) return error.InvalidMiddlewareResponse;
                        return .respond;
                    }
                    if (context.response.prepared) return error.InvalidMiddlewareResponse;
                }
            }
            return .continue_request;
        }

        fn runAfter(context: *Context, chain: []const Middleware) !void {
            var index = chain.len;
            while (index > 0) {
                index -= 1;
                if (context.cancelled.load(.acquire)) return error.Cancelled;
                if (chain[index].after) |call| try call(context);
            }
        }

        fn cleanupChain(context: *Context, chain: []const Middleware) void {
            var index = chain.len;
            while (index > 0) {
                index -= 1;
                if (chain[index].cleanup) |call| call(context);
            }
        }

        fn cleanup(self: *Self, context: *Context) void {
            cleanupChain(context, context.route_middleware[0..context.route_entered]);
            cleanupChain(context, self.middleware[0..context.global_entered]);
            if (self.cleanup_locals) |call| call(context);
        }

        fn process(self: *Self, context: *Context) !void {
            if (context.cancelled.load(.acquire)) return error.Cancelled;
            if (self.init_locals) |call| try call(context);
            if (context.response.prepared) return error.InvalidMiddlewareResponse;
            if (try runBefore(context, self.middleware[0..self.global_middleware_len], &context.global_entered) == .continue_request)
                try self.handle(context);
            try runAfter(context, context.route_middleware[0..context.route_entered]);
            try runAfter(context, self.middleware[0..context.global_entered]);
        }

        fn callRoute(context: *Context, entry: *const Route) !void {
            context.route_middleware = entry.middleware;
            if (try runBefore(context, entry.middleware, &context.route_entered) == .respond) return;
            if (context.cancelled.load(.acquire)) return error.Cancelled;
            try entry.call(entry.instance, context);
        }

        fn handleError(self: *Self, context: *Context, err: anyerror) engine.api.Action {
            if (self.on_error) |handler| {
                context.response.discard() catch return .close;
                handler(context, err) catch return context.response.errorResponse(500) catch .close;
                return context.response.finish() catch context.response.errorResponse(500) catch .close;
            }
            const status: u16 = switch (err) {
                error.InvalidEscape, error.InvalidMetadata, error.DuplicateMetadataParameter, error.InvalidBoundary, error.InvalidMultipart, error.MissingBoundary, error.InvalidQuotedPair, error.AmbiguousContentType, error.MalformedCookie, error.MalformedHeaders, error.DuplicateCookie => 400,
                error.CookiesTooLarge, error.TooManyCookies => 431,
                error.ParamsTooLarge, error.TooManyParams, error.NameTooLarge, error.ValueTooLarge, error.MultipartTooLarge, error.TooManyParts, error.PartTooLarge, error.PartHeadersTooLarge, error.MetadataTooLarge, error.TooManyMetadataParameters => 413,
                error.MissingContentType, error.UnsupportedMediaType, error.UnsupportedContentEncoding, error.UnsupportedMultipartEncoding => 415,
                else => 500,
            };
            return context.response.errorResponse(status) catch .close;
        }

        fn handle(self: *Self, context: *Context) !void {
            const method = context.request.method();
            if (std.mem.eql(u8, method, "CONNECT")) return context.response.text(501, "Not Implemented");
            const target = context.request.target();
            if (std.mem.eql(u8, target.raw, "*")) {
                if (!std.mem.eql(u8, method, "OPTIONS")) return context.response.text(400, "Bad Request");
                try context.response.header("Allow", self.global_allow);
                return context.response.bytes(204, "text/plain", "");
            }
            const raw_path = target.path orelse "/";
            const path = if (raw_path.len == 0) "/" else raw_path;
            var best: ?*const Route = null;
            for (self.routes[0..self.routes_len]) |*entry| {
                if (routing.matches(entry.pattern, path) and (best == null or entry.rank > best.?.rank)) best = entry;
            }
            const path_route = best orelse {
                if (self.not_found) |handler| return handler(context);
                return context.response.text(404, "Not Found");
            };
            var get: ?*const Route = null;
            for (self.routes[0..self.routes_len]) |*entry| {
                if (!routing.equivalent(entry.pattern, path_route.pattern)) continue;
                if (std.mem.eql(u8, entry.method, method)) {
                    context.captures = routing.capture(entry.pattern, path);
                    return callRoute(context, entry);
                }
                if (std.mem.eql(u8, entry.method, "GET")) get = entry;
            }
            if (std.mem.eql(u8, method, "HEAD")) if (get) |entry| {
                context.captures = routing.capture(entry.pattern, path);
                return callRoute(context, entry);
            };
            try context.response.header("Allow", path_route.allow);
            if (std.mem.eql(u8, method, "OPTIONS")) return context.response.bytes(204, "text/plain", "");
            return context.response.text(405, "Method Not Allowed");
        }
    };
}

test "App registration is instance-owned, copies paths and rolls back endpoints" {
    const Shared = struct { count: usize = 0 };
    const Application = App(Shared);
    const Endpoint = struct {
        fn get(_: *@This(), _: *Application.Context) !void {}
        fn post(_: *@This(), _: *Application.Context) !void {}
    };
    var shared: Shared = .{};
    const app = try Application.init(.{ .allocator = std.testing.allocator, .io = std.testing.io, .shared = &shared, .server = .{ .connections = 1, .shards = 1 }, .max_routes = 2 });
    defer app.deinit();
    var path = "/first".*;
    const H = struct {
        fn get(_: *Application.Context) !void {}
    };
    try app.route("GET", &path, H.get);
    path[1] = 'z';
    try std.testing.expectEqualStrings("/first", app.routes[0].pattern);
    var endpoint: Endpoint = .{};
    try std.testing.expectError(error.TooManyRoutes, app.endpoint("/second", &endpoint));
    try std.testing.expectEqual(@as(usize, 1), app.routes_len);
    try app.route("GET", "/:id", H.get);
    try std.testing.expectError(error.DuplicateRoute, app.route("GET", "/:name", H.get));
    const other = try Application.init(.{ .allocator = std.testing.allocator, .io = std.testing.io, .shared = &shared, .server = .{ .connections = 1, .shards = 1 } });
    defer other.deinit();
    try std.testing.expectEqual(@as(usize, 0), other.routes_len);
}

test "App startup budget covers application storage before sockets exist" {
    const Shared = struct {};
    var shared: Shared = .{};
    try std.testing.expectError(error.MemoryBudgetExceeded, App(Shared).init(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .shared = &shared,
        .server = .{ .connections = 1, .shards = 1, .memory_budget_bytes = 1024 },
    }));
}

test "two Apps of the same type dispatch their own shared state" {
    const Shared = struct { text: []const u8 };
    const Application = App(Shared);
    const H = struct {
        fn get(ctx: *Application.Context) !void {
            try ctx.response.text(200, ctx.shared.text);
        }
    };
    var first_shared: Shared = .{ .text = "first application" };
    var second_shared: Shared = .{ .text = "second application" };
    const first = try Application.init(.{ .allocator = std.testing.allocator, .io = std.testing.io, .shared = &first_shared, .server = .{ .connections = 1, .shards = 1 }, .response = .{ .header_bytes = 128, .body_bytes = 64 } });
    defer first.deinit();
    const second = try Application.init(.{ .allocator = std.testing.allocator, .io = std.testing.io, .shared = &second_shared, .server = .{ .connections = 1, .shards = 1 }, .response = .{ .header_bytes = 128, .body_bytes = 64 } });
    defer second.deinit();
    try first.route("GET", "/", H.get);
    try second.route("GET", "/", H.get);
    var parser = engine.api.http.Parser.init(.{});
    var request = (try parser.parse("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")).?;
    var arena: [2048]u8 = undefined;
    var cache: engine.api.HeaderCache = .{};
    cache.refresh("Sun, 06 Sep 2026 12:00:00 GMT");
    var writer = engine.api.Writer.init(&arena, &cache, 0);
    var state: [8]usize = @splat(0);
    const cancelled: std.atomic.Value(bool) = .init(false);
    for ([_]*Application{ first, second, first }) |app| {
        writer.open(0, true, false);
        var ctx: engine.api.Context = .{ .request = &request, .writer = &writer, .event = .request, .state = &state, .application = app, .cancelled = &cancelled };
        try std.testing.expectEqual(engine.api.Action.finish, Application.dispatch(&ctx));
        try std.testing.expectEqualStrings(app.shared.text, writer.committed());
        writer.release();
    }
}

test "two prepared Apps have independent ports and stop ownership" {
    const Shared = struct {};
    const Application = App(Shared);
    const H = struct {
        fn get(ctx: *Application.Context) !void {
            try ctx.response.text(200, "ok");
        }
    };
    var shared: Shared = .{};
    const options: Application.Options = .{ .allocator = std.testing.allocator, .io = std.testing.io, .shared = &shared, .server = .{ .port = 0, .connections = 1, .shards = 1, .duration_ms = 1 } };
    const first = try Application.init(options);
    defer first.deinit();
    const second = try Application.init(options);
    defer second.deinit();
    try first.route("GET", "/", H.get);
    try second.route("GET", "/", H.get);
    try first.start();
    try second.start();
    try std.testing.expect(first.port() != second.port());
    try std.testing.expectError(error.RegistrationClosed, first.route("GET", "/late", H.get));
    try std.testing.expectEqual(@as(u64, 0), first.stats().accepted);
    try std.testing.expectEqual(@as(u64, 0), second.stats().accepted);
    first.requestStop();
    try std.testing.expect(!second.cluster.?.shards[0].stop_requested.load(.acquire));
    first.run() catch engine.failFast(70);
    second.run() catch engine.failFast(70);
    try std.testing.expectEqual(@as(usize, 0), first.budget.late_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), second.budget.late_calls.load(.acquire));
}

test "middleware descriptors are startup-owned and endpoint rollback restores their bound" {
    const Shared = struct {};
    const Application = App(Shared);
    const Hooks = struct {
        fn before(_: *Application.Context) !Application.Decision {
            return .continue_request;
        }
    };
    const Endpoint = struct {
        pub fn get(_: *@This(), _: *Application.Context) !void {}
        pub fn post(_: *@This(), _: *Application.Context) !void {}
    };
    var shared: Shared = .{};
    var chain = [_]Application.Middleware{.{ .before = Hooks.before }};
    const app = try Application.init(.{ .allocator = std.testing.allocator, .io = std.testing.io, .shared = &shared, .server = .{ .connections = 1, .shards = 1 }, .max_middleware = 2, .middleware = &chain });
    defer app.deinit();
    chain[0] = .{};
    try std.testing.expect(app.middleware[0].before != null);
    var endpoint: Endpoint = .{};
    try std.testing.expectError(error.TooManyMiddleware, app.endpointWith("/", &endpoint, .{ .middleware = &.{.{ .before = Hooks.before }} }));
    try std.testing.expectEqual(@as(usize, 0), app.routes_len);
    try std.testing.expectEqual(@as(usize, 0), app.names_len);
    try std.testing.expectEqual(@as(usize, 1), app.middleware_len);
    try std.testing.expectError(error.InvalidMiddleware, app.endpointWith("/", &endpoint, .{ .middleware = &.{.{}} }));
    try app.bindWith("GET", "/", &endpoint, Endpoint.get, .{ .middleware = &.{.{ .before = Hooks.before }} });
    try std.testing.expectEqual(@as(usize, 2), app.middleware_len);
    try std.testing.expectError(error.TooManyMiddleware, app.bindWith("GET", "/other", &endpoint, Endpoint.get, .{ .middleware = &.{.{ .before = Hooks.before }} }));
    try std.testing.expectEqual(@as(usize, 1), app.routes_len);
}

test "typed locals, middleware unwinding, early responses and error cleanup run exactly once" {
    const Shared = struct { mode: u8 = 0, trace: [64]u8 = undefined, used: usize = 0 };
    const Locals = struct { value: u32 = 7 };
    const Application = AppWithLocals(Shared, Locals);
    const H = struct {
        fn mark(ctx: *Application.Context, byte: u8) void {
            ctx.shared.trace[ctx.shared.used] = byte;
            ctx.shared.used += 1;
        }
        fn init(ctx: *Application.Context) !void {
            try std.testing.expectEqual(@as(u32, 7), ctx.locals.value);
            mark(ctx, 'I');
            ctx.locals.value = 8;
            if (ctx.shared.mode == 1) return error.InitFailed;
        }
        fn global(ctx: *Application.Context) !Application.Decision {
            mark(ctx, 'G');
            if (ctx.shared.mode == 2) {
                try ctx.response.text(401, "denied");
                return .respond;
            }
            return .continue_request;
        }
        fn route(ctx: *Application.Context) !Application.Decision {
            mark(ctx, 'R');
            try std.testing.expectEqualStrings("item", ctx.param("id").?);
            try std.testing.expectEqual(@as(u32, 8), ctx.locals.value);
            ctx.locals.value = 9;
            if (ctx.shared.mode == 3) return error.BeforeFailed;
            if (ctx.shared.mode == 4) return .respond;
            if (ctx.shared.mode == 5) try ctx.response.text(200, "bad continue");
            return .continue_request;
        }
        fn get(ctx: *Application.Context) !void {
            mark(ctx, 'H');
            try std.testing.expectEqual(@as(u32, 9), ctx.locals.value);
            if (ctx.shared.mode == 6) return error.HandlerFailed;
            try ctx.response.text(200, "ok");
        }
        fn routeAfter(ctx: *Application.Context) !void {
            mark(ctx, 'r');
            if (ctx.shared.mode == 7) return error.AfterFailed;
            try ctx.response.header("X-Route", "done");
        }
        fn globalAfter(ctx: *Application.Context) !void {
            mark(ctx, 'g');
            try ctx.response.header("X-Global", "done");
        }
        fn routeCleanup(ctx: *Application.Context) void {
            mark(ctx, 'C');
        }
        fn globalCleanup(ctx: *Application.Context) void {
            mark(ctx, 'D');
        }
        fn localsCleanup(ctx: *Application.Context) void {
            mark(ctx, 'L');
            ctx.locals.value = 999;
        }
        fn onError(ctx: *Application.Context, _: anyerror) !void {
            mark(ctx, 'E');
            try std.testing.expect(ctx.locals.value != 999);
            return ctx.response.text(500, "mapped");
        }
    };
    var shared: Shared = .{};
    const app = try Application.init(.{ .allocator = std.testing.allocator, .io = std.testing.io, .shared = &shared, .server = .{ .connections = 1, .shards = 1 }, .response = .{ .header_bytes = 128, .body_bytes = 64 }, .middleware = &.{.{ .before = H.global, .after = H.globalAfter, .cleanup = H.globalCleanup }}, .init_locals = H.init, .cleanup_locals = H.localsCleanup, .on_error = H.onError });
    defer app.deinit();
    try app.routeWith("GET", "/:id", H.get, .{ .middleware = &.{.{ .before = H.route, .after = H.routeAfter, .cleanup = H.routeCleanup }} });
    var parser = engine.api.http.Parser.init(.{});
    var request = (try parser.parse("GET /item HTTP/1.1\r\nHost: localhost\r\n\r\n")).?;
    var arena: [2048]u8 = undefined;
    var cache: engine.api.HeaderCache = .{};
    cache.refresh("Sun, 06 Sep 2026 12:00:00 GMT");
    var writer = engine.api.Writer.init(&arena, &cache, 0);
    var state: [8]usize = @splat(0);
    const cancelled: std.atomic.Value(bool) = .init(false);
    const traces = [_][]const u8{ "IGRHrgCDL", "IEL", "IGgDL", "IGRECDL", "IGRECDL", "IGRECDL", "IGRHECDL", "IGRHrECDL", "IGRHrgCDL" };
    for (traces, 0..) |trace, mode| {
        shared.mode = @intCast(mode);
        shared.used = 0;
        writer.open(0, true, false);
        var ctx: engine.api.Context = .{ .request = &request, .writer = &writer, .event = .request, .state = &state, .application = app, .cancelled = &cancelled };
        try std.testing.expectEqual(engine.api.Action.finish, Application.dispatch(&ctx));
        try std.testing.expectEqualStrings(trace, shared.trace[0..shared.used]);
        try std.testing.expectEqual(@as(u16, if (mode == 0 or mode == 8) 200 else if (mode == 2) 401 else 500), writer.status);
        writer.release();
    }
}
