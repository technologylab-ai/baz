const std = @import("std");
const c = std.c;
const assert = std.debug.assert;
const transport = @import("transport.zig");
const http = @import("http.zig");
pub const api = @import("api.zig");
pub const Budget = @import("budget.zig").Budget;
pub const backend_name = transport.name;

/// Inline handlers execute on the sole I/O owner and must be bounded and
/// nonblocking. The framework cannot preempt or isolate a violating callback.
/// Workers remain the default; inline mode reserves no application threads.
pub const Execution = enum { workers, inline_event_loop };

pub const Config = struct {
    execution: Execution = .workers,
    port: u16 = 8080,
    connections: u16 = 128,
    workers: u16 = 2,
    max_body: u32 = 65536,
    max_header: u32 = 16384,
    max_headers: u16 = 64,
    output_bytes: u32 = 4096,
    max_response_bytes: usize = 16 * 1024 * 1024,
    timeout_ms: u32 = 5000,
    shutdown_ms: u32 = 5000,
    duration_ms: u32 = 0,
    send_chunk: u32 = 65536,
    socket_send_buffer_bytes: u32 = 65536,
    worker_stack_bytes: usize = 1024 * 1024,
    memory_budget_bytes: usize = 512 * 1024 * 1024,

    pub fn wireBytes(self: Config) !usize {
        const body = try std.math.mul(usize, self.max_body, 2);
        return std.math.add(usize, try std.math.add(usize, body, self.max_header), 4096);
    }
    pub fn validate(self: Config) !void {
        const invalid_workers = switch (self.execution) {
            .workers => self.workers == 0,
            .inline_event_loop => self.workers != 0,
        };
        if (self.connections == 0 or self.connections > 4096 or invalid_workers or
            self.workers > 64 or self.workers > self.connections or self.max_header < 128 or
            self.max_header > 65536 or self.max_body > 16 * 1024 * 1024 or
            self.output_bytes == 0 or self.output_bytes > 65536 or self.timeout_ms == 0 or
            self.shutdown_ms == 0 or self.send_chunk == 0 or self.socket_send_buffer_bytes == 0 or
            self.socket_send_buffer_bytes > 16 * 1024 * 1024 or self.max_headers == 0 or
            self.max_headers > 1024 or self.worker_stack_bytes < 65536)
            return error.InvalidConfiguration;
        const per_connection = try std.math.add(usize, try self.wireBytes(), try std.math.add(usize, self.output_bytes, @sizeOf(Slot) + 4096));
        const pools = try std.math.mul(usize, per_connection, self.connections);
        const stacks = try std.math.mul(usize, self.worker_stack_bytes, self.workers);
        if (try std.math.add(usize, pools, stacks) > self.memory_budget_bytes)
            return error.MemoryBudgetExceeded;
    }
};

pub const Stats = struct {
    execution: Execution = .workers,
    inline_dispatches: u64 = 0,
    worker_dispatches: u64 = 0,
    accepted: u64 = 0,
    completed: u64 = 0,
    rejected: u64 = 0,
    timeouts: u64 = 0,
    flushes: u64 = 0,
    resumed: u64 = 0,
    bytes_received: u64 = 0,
    bytes_sent: u64 = 0,
    pipeline_copy_bytes: u64 = 0,
    live_connections: usize = 0,
    peak_connections: usize = 0,
    live_operations: usize = 0,
    peak_operations: usize = 0,
    max_loop_ns: u64 = 0,
    max_handler_ns: u64 = 0,
    max_queue_ns: u64 = 0,
    max_request_ns: u64 = 0,
    workers: u16 = 0,
    allocation_calls_after_start: usize = 0,
    framework_heap_peak_bytes: usize = 0,
    framework_heap_limit_bytes: usize = 0,
};

const Phase = enum(u8) { io, ready, running, result };
const SendMode = enum { response, interim, reject };
const Kind = enum(u8) { accept = 1, recv, send, cancel, cancel_accept };
const accept_token: u64 = @intFromEnum(Kind.accept);
const cancel_accept_token: u64 = @intFromEnum(Kind.cancel_accept);

const Slot = struct {
    phase: std.atomic.Value(Phase) = .init(.io),
    cancelled: std.atomic.Value(bool) = .init(false),
    in_use: bool = false,
    generation: u32 = 0,
    fd: transport.Socket = -1,
    input: []u8,
    received: usize = 0,
    parser: http.Parser,
    request: http.Request = undefined,
    writer: api.Writer,
    state: [8]usize = @splat(0),
    action: api.Action = .close,
    event: api.Event = .request,
    op_pending: bool = false,
    cancel_pending: bool = false,
    op_token: u64 = 0,
    closing: bool = false,
    deadline: u64 = 0,
    request_started: u64 = 0,
    queued_at: u64 = 0,
    queue_ns: u64 = 0,
    handler_ns: u64 = 0,
    interim_sent: bool = false,
    response_started: bool = false,
    logical_written: usize = 0,
    header_buffer: [512]u8 = undefined,
    chunk_buffer: [32]u8 = undefined,
    parts: [5][]const u8 = @splat(""),
    part_count: usize = 0,
    part: usize = 0,
    part_offset: usize = 0,
    send_mode: SendMode = .response,
};

const Worker = struct {
    server: *Server,
    index: usize,
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    thread: ?std.Thread = null,

    fn init(server: *Server, index: usize) !Worker {
        var fds: [2]c.fd_t = undefined;
        if (c.pipe(&fds) != 0) return error.WorkerPipeFailed;
        errdefer transport.closeFd(fds[0]);
        errdefer transport.closeFd(fds[1]);
        try transport.setFlags(fds[0], false);
        try transport.setFlags(fds[1], true);
        return .{ .server = server, .index = index, .read_fd = fds[0], .write_fd = fds[1] };
    }
    fn wake(self: *Worker) void {
        const byte = [_]u8{1};
        const result = c.write(self.write_fd, &byte, 1);
        if (result < 0) assert(c.errno(result) == .AGAIN or c.errno(result) == .INTR);
    }
    fn run(self: *Worker) void {
        _ = self.server.ready_workers.fetchAdd(1, .release);
        defer _ = self.server.exited_workers.fetchAdd(1, .release);
        var bytes: [64]u8 = undefined;
        while (!self.server.stop_workers.load(.acquire)) {
            // A finite wait makes EINTR/coalesced notification loss harmless.
            // The published phase is authoritative; pipe bytes are only hints.
            var ready = [_]c.pollfd{.{ .fd = self.read_fd, .events = c.POLL.IN, .revents = 0 }};
            const polled = c.poll(&ready, 1, 10);
            if (polled < 0) {
                assert(c.errno(polled) == .INTR);
                continue;
            }
            if (polled > 0) {
                const read = c.read(self.read_fd, &bytes, bytes.len);
                assert(read > 0 or (read < 0 and c.errno(read) == .INTR));
            }
            if (self.server.stop_workers.load(.acquire)) break;
            var index = self.index;
            while (index < self.server.slots.len) : (index += self.server.workers.len) {
                const slot = &self.server.slots[index];
                if (slot.phase.cmpxchgStrong(.ready, .running, .acquire, .monotonic) != null)
                    continue;
                self.server.invokeHandler(slot);
                self.server.backend.wake();
            }
        }
    }
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    config: Config,
    handler: api.Handler,
    application: ?*anyopaque,
    backend: transport.Backend,
    slots: []Slot,
    workers: []Worker,
    storage: []u8,
    stop_requested: std.atomic.Value(bool) = .init(false),
    stop_workers: std.atomic.Value(bool) = .init(false),
    ready_workers: std.atomic.Value(u32) = .init(0),
    exited_workers: std.atomic.Value(u32) = .init(0),
    accept_pending: bool = false,
    accept_cancel_pending: bool = false,
    accept_cancel_requested: bool = false,
    stopping: bool = false,
    stop_deadline: u64 = 0,
    started_at: u64 = 0,
    started: bool = false,
    safe_to_destroy: bool = true,
    stats: Stats = .{},
    date: [29]u8 = undefined,
    date_second: u64 = std.math.maxInt(u64),

    pub fn init(allocator: std.mem.Allocator, config: Config, handler: api.Handler, application: ?*anyopaque) !*Server {
        try config.validate();
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);
        var backend = try transport.Backend.init(allocator, config.connections, config.port);
        errdefer backend.deinit();
        const slots = try allocator.alloc(Slot, config.connections);
        errdefer allocator.free(slots);
        const workers = try allocator.alloc(Worker, config.workers);
        errdefer allocator.free(workers);
        const wire = try config.wireBytes();
        const per_slot = wire + config.output_bytes;
        const storage = try allocator.alloc(u8, per_slot * config.connections);
        errdefer allocator.free(storage);
        @memset(storage, 0);
        self.* = .{ .allocator = allocator, .config = config, .handler = handler, .application = application, .backend = backend, .slots = slots, .workers = workers, .storage = storage, .stats = .{ .workers = config.workers, .execution = config.execution } };
        for (slots, 0..) |*slot, index| {
            const base = storage[index * per_slot ..][0..per_slot];
            slot.* = .{
                .input = base[0..wire],
                .parser = http.Parser.init(.{
                    .max_header_bytes = config.max_header,
                    .max_header_count = config.max_headers,
                    .max_body_bytes = config.max_body,
                    .max_wire_bytes = @intCast(wire),
                    .max_target_bytes = 8192,
                }),
                .writer = api.Writer.init(base[wire..]),
            };
        }
        var initialized: usize = 0;
        errdefer for (workers[0..initialized]) |worker| {
            transport.closeFd(worker.read_fd);
            transport.closeFd(worker.write_fd);
        };
        for (workers, 0..) |*worker, index| {
            worker.* = try Worker.init(self, index);
            initialized += 1;
        }
        return self;
    }

    pub fn start(self: *Server) !void {
        assert(!self.started);
        errdefer {
            self.stop_workers.store(true, .release);
            for (self.workers) |*worker| if (worker.thread) |thread| {
                worker.wake();
                thread.join();
                worker.thread = null;
            };
        }
        for (self.workers) |*worker| worker.thread = try std.Thread.spawn(.{
            .stack_size = self.config.worker_stack_bytes,
            .allocator = self.allocator,
        }, Worker.run, .{worker});
        const startup_deadline = nowNs() + @as(u64, self.config.shutdown_ms) * 1_000_000;
        while (self.ready_workers.load(.acquire) != self.workers.len) {
            // A thread that never reaches its entry point cannot safely be
            // reclaimed in-process. The demo's outer watchdog also covers spawn.
            if (nowNs() >= startup_deadline) std.c._exit(70);
            std.Thread.yield() catch {};
        }
        self.started = true;
        self.safe_to_destroy = false;
        self.started_at = nowNs();
        self.refreshDate();
    }

    pub fn requestStop(self: *Server) void {
        self.stop_requested.store(true, .release);
        self.backend.wake();
    }

    pub fn run(self: *Server) !void {
        assert(self.started);
        var completions: [128]transport.Completion = undefined;
        while (true) {
            const turn_start = nowNs();
            if (self.config.duration_ms != 0 and
                turn_start - self.started_at >= @as(u64, self.config.duration_ms) * 1_000_000)
                self.stop_requested.store(true, .release);
            if (self.stop_requested.load(.acquire) and !self.stopping) {
                self.stopping = true;
                self.stop_deadline = turn_start + @as(u64, self.config.shutdown_ms) * 1_000_000;
            }
            if (self.stopping and self.accept_pending and !self.accept_cancel_requested) {
                try self.backend.cancel(cancel_accept_token, accept_token);
                self.accept_cancel_pending = true;
                self.accept_cancel_requested = true;
                self.operationAdded();
            }
            if (!self.stopping and !self.accept_pending) {
                try self.backend.accept(accept_token);
                self.accept_pending = true;
                self.operationAdded();
            }
            self.refreshDate();
            var local_result_ready = false;
            for (self.slots, 0..) |*slot, index| {
                if (!slot.in_use) continue;
                if (!slot.closing and (self.stopping or turn_start >= slot.deadline)) {
                    if (!self.stopping) self.stats.timeouts += 1;
                    try self.beginClose(slot);
                }
                if (slot.phase.load(.acquire) == .result) {
                    self.stats.max_handler_ns = @max(self.stats.max_handler_ns, slot.handler_ns);
                    self.stats.max_queue_ns = @max(self.stats.max_queue_ns, slot.queue_ns);
                    slot.phase.store(.io, .release);
                    if (slot.closing or slot.action == .close) {
                        try self.beginClose(slot);
                    } else {
                        try self.prepareResponse(index);
                    }
                }
                if (slot.closing) self.maybeFree(slot);
                // An empty inline flush or already-buffered next request may
                // publish another result while consuming this one. Process it
                // on the next turn: no recursive callbacks or idle poll delay.
                if (self.config.execution == .inline_event_loop and
                    slot.phase.load(.acquire) == .result) local_result_ready = true;
            }
            const control_ns = nowNs() - turn_start;
            self.stats.max_loop_ns = @max(self.stats.max_loop_ns, control_ns);
            if (self.stopping and self.stats.live_connections == 0 and
                self.stats.live_operations == 0) break;
            if (self.stopping and nowNs() >= self.stop_deadline) return error.ShutdownStalled;
            const count = try self.backend.poll(&completions, if (local_result_ready) 0 else 10);
            const processing_start = nowNs();
            for (completions[0..count]) |completion| try self.onCompletion(completion);
            self.stats.max_loop_ns = @max(self.stats.max_loop_ns, control_ns + nowNs() - processing_start);
        }
        self.stop_workers.store(true, .release);
        for (self.workers) |*worker| worker.wake();
        while (self.exited_workers.load(.acquire) != self.workers.len) {
            if (nowNs() >= self.stop_deadline) return error.ShutdownStalled;
            const count = try self.backend.poll(&completions, 10);
            assert(count == 0);
        }
        for (self.workers) |*worker| if (worker.thread) |thread| {
            thread.join();
            worker.thread = null;
        };
        self.safe_to_destroy = true;
    }

    pub fn deinit(self: *Server) void {
        assert(self.safe_to_destroy);
        assert(self.stats.live_operations == 0 and self.stats.live_connections == 0);
        for (self.workers) |worker| {
            assert(worker.thread == null);
            transport.closeFd(worker.read_fd);
            transport.closeFd(worker.write_fd);
        }
        self.backend.deinit();
        self.allocator.free(self.storage);
        self.allocator.free(self.slots);
        self.allocator.free(self.workers);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    fn operationAdded(self: *Server) void {
        self.stats.live_operations += 1;
        self.stats.peak_operations = @max(self.stats.peak_operations, self.stats.live_operations);
        assert(self.stats.live_operations <= 2 * (self.slots.len + 1));
    }

    fn tokenFor(slot: *const Slot, index: usize, kind: Kind) u64 {
        return (@as(u64, slot.generation) << 32) | (@as(u64, index) << 8) | @intFromEnum(kind);
    }

    fn onCompletion(self: *Server, completion: transport.Completion) !void {
        assert(self.stats.live_operations > 0);
        self.stats.live_operations -= 1;
        const kind: Kind = @enumFromInt(@as(u8, @truncate(completion.token)));
        if (kind == .cancel_accept) {
            assert(self.accept_cancel_pending);
            self.accept_cancel_pending = false;
            return;
        }
        if (kind == .accept) {
            assert(self.accept_pending);
            self.accept_pending = false;
            if (completion.result < 0) return;
            if (self.stopping) {
                self.backend.close(completion.result);
                return;
            }
            for (self.slots, 0..) |*slot, index| {
                if (slot.in_use) continue;
                assert(slot.phase.load(.acquire) == .io);
                slot.generation = try std.math.add(u32, slot.generation, 1);
                slot.in_use = true;
                slot.fd = completion.result;
                const send_buffer: c_int = @intCast(self.config.socket_send_buffer_bytes);
                if (c.setsockopt(slot.fd, c.SOL.SOCKET, c.SO.SNDBUF, &send_buffer, @sizeOf(c_int)) != 0) {
                    self.backend.close(slot.fd);
                    slot.fd = -1;
                    slot.in_use = false;
                    self.stats.rejected += 1;
                    return;
                }
                slot.closing = false;
                slot.cancelled.store(false, .release);
                slot.received = 0;
                slot.parser.reset();
                slot.interim_sent = false;
                slot.response_started = false;
                slot.logical_written = 0;
                slot.deadline = nowNs() + @as(u64, self.config.timeout_ms) * 1_000_000;
                slot.request_started = nowNs();
                self.stats.accepted += 1;
                self.stats.live_connections += 1;
                self.stats.peak_connections = @max(self.stats.peak_connections, self.stats.live_connections);
                assert(self.stats.live_connections <= self.slots.len);
                try self.receive(index);
                return;
            }
            self.stats.rejected += 1;
            self.backend.close(completion.result);
            return;
        }
        const index: usize = @intCast((completion.token >> 8) & 0xffff);
        assert(index < self.slots.len);
        const slot = &self.slots[index];
        assert(slot.in_use and slot.generation == completion.token >> 32);
        if (kind == .cancel) {
            assert(slot.cancel_pending);
            slot.cancel_pending = false;
            self.maybeFree(slot);
            return;
        }
        assert(slot.op_pending and slot.op_token == completion.token);
        slot.op_pending = false;
        if (slot.closing or completion.result <= 0) {
            try self.beginClose(slot);
            self.maybeFree(slot);
            return;
        }
        const transferred: usize = @intCast(completion.result);
        switch (kind) {
            .recv => {
                assert(transferred <= slot.input.len - slot.received);
                slot.received += transferred;
                self.stats.bytes_received += transferred;
                try self.parseRequest(index);
            },
            .send => {
                assert(transferred <= slot.parts[slot.part].len - slot.part_offset);
                slot.part_offset += transferred;
                self.stats.bytes_sent += transferred;
                try self.sendNext(index);
            },
            else => unreachable,
        }
    }

    fn receive(self: *Server, index: usize) anyerror!void {
        const slot = &self.slots[index];
        assert(!slot.op_pending and !slot.closing and slot.phase.load(.acquire) == .io);
        if (slot.received == slot.input.len) return self.reject(index, 413);
        const token = tokenFor(slot, index, .recv);
        try self.backend.recv(token, slot.fd, slot.input[slot.received..]);
        slot.op_pending = true;
        slot.op_token = token;
        self.operationAdded();
    }

    fn parseRequest(self: *Server, index: usize) !void {
        const slot = &self.slots[index];
        const parsed = slot.parser.parse(slot.input[0..slot.received]) catch |err| {
            return self.reject(index, switch (err) {
                error.HeadersTooLarge => 431,
                error.BodyTooLarge => 413,
                error.TargetTooLong => 414,
                error.ExpectationFailed => 417,
                error.UnsupportedVersion => 505,
                error.UnsupportedTransferEncoding => 501,
                else => 400,
            });
        };
        if (parsed) |request| {
            slot.request = request;
            slot.writer = api.Writer.init(slot.writer.buffer);
            slot.state = @splat(0);
            slot.event = .request;
            slot.response_started = false;
            slot.logical_written = 0;
            self.dispatch(index);
        } else if (slot.parser.head_complete and slot.parser.expect_continue and !slot.interim_sent) {
            slot.interim_sent = true;
            slot.send_mode = .interim;
            slot.part_count = 1;
            slot.parts[0] = "HTTP/1.1 100 Continue\r\n\r\n";
            slot.part = 0;
            slot.part_offset = 0;
            try self.sendNext(index);
        } else try self.receive(index);
    }

    fn dispatch(self: *Server, index: usize) void {
        const slot = &self.slots[index];
        assert(slot.phase.load(.acquire) == .io and !slot.closing and !slot.op_pending);
        slot.queued_at = nowNs();
        switch (self.config.execution) {
            .workers => {
                assert(self.workers.len > 0);
                self.stats.worker_dispatches += 1;
                slot.phase.store(.ready, .release);
                self.workers[index % self.workers.len].wake();
            },
            .inline_event_loop => {
                assert(self.workers.len == 0);
                self.stats.inline_dispatches += 1;
                slot.phase.store(.running, .release);
                self.invokeHandler(slot);
            },
        }
    }

    /// Caller exclusively owns the running phase. Publishing result ends every
    /// callback borrow, including inline execution; response processing belongs
    /// to the I/O loop and never recursively invokes a resumed callback here.
    fn invokeHandler(self: *Server, slot: *Slot) void {
        assert(slot.phase.load(.acquire) == .running);
        const started = nowNs();
        slot.queue_ns = started - slot.queued_at;
        if (slot.cancelled.load(.acquire)) {
            slot.action = .close;
        } else {
            var context: api.Context = .{
                .request = &slot.request,
                .writer = &slot.writer,
                .event = slot.event,
                .state = &slot.state,
                .application = self.application,
                .cancelled = &slot.cancelled,
            };
            slot.action = self.handler(&context);
            if (slot.action != .close) assert(slot.writer.frozen);
        }
        slot.handler_ns = nowNs() - started;
        slot.phase.store(.result, .release);
    }

    fn reject(self: *Server, index: usize, status: u16) !void {
        const slot = &self.slots[index];
        self.stats.rejected += 1;
        slot.send_mode = .reject;
        slot.parts[0] = try std.fmt.bufPrint(&slot.header_buffer, "HTTP/1.1 {d} {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{ status, reason(status) });
        slot.part_count = 1;
        slot.part = 0;
        slot.part_offset = 0;
        try self.sendNext(index);
    }

    fn prepareResponse(self: *Server, index: usize) !void {
        const slot = &self.slots[index];
        const writer = &slot.writer;
        assert(writer.frozen);
        const bytes = writer.committed();
        const total = std.math.add(usize, slot.logical_written, bytes.len) catch {
            return self.beginClose(slot);
        };
        if (total > self.config.max_response_bytes) return self.beginClose(slot);
        if (writer.content_length) |length| {
            if (total > length or (slot.action == .finish and total != length))
                return self.beginClose(slot);
        }
        if ((writer.status == 204 or writer.status == 304) and bytes.len != 0)
            return self.beginClose(slot);
        slot.logical_written = total;
        slot.send_mode = .response;
        slot.part_count = 0;
        slot.part = 0;
        slot.part_offset = 0;
        if (!slot.response_started) {
            var length_buffer: [64]u8 = undefined;
            const framing = if (writer.status == 204 or writer.status == 304) "" else if (writer.content_length) |length|
                try std.fmt.bufPrint(&length_buffer, "Content-Length: {d}\r\n", .{length})
            else
                "Transfer-Encoding: chunked\r\n";
            const header = try std.fmt.bufPrint(&slot.header_buffer, "HTTP/1.1 {d} {s}\r\nServer: zig-http\r\nDate: {s}\r\n" ++
                "Content-Type: {s}\r\n{s}Connection: {s}\r\n\r\n", .{ writer.status, reason(writer.status), self.date, writer.content_type, framing, if (slot.request.keep_alive) "keep-alive" else "close" });
            self.addPart(slot, header);
            slot.response_started = true;
            writer.headers_committed = true;
        }
        if (!slot.request.head_only and writer.status != 204 and writer.status != 304) {
            if (writer.content_length == null and bytes.len != 0) {
                self.addPart(slot, try std.fmt.bufPrint(&slot.chunk_buffer, "{x}\r\n", .{bytes.len}));
            }
            if (bytes.len != 0) self.addPart(slot, bytes);
            if (writer.content_length == null) {
                if (bytes.len != 0) self.addPart(slot, "\r\n");
                if (slot.action == .finish) self.addPart(slot, "0\r\n\r\n");
            }
        }
        if (slot.action == .flush) self.stats.flushes += 1;
        try self.sendNext(index);
    }

    fn addPart(_: *Server, slot: *Slot, bytes: []const u8) void {
        assert(slot.part_count < slot.parts.len);
        slot.parts[slot.part_count] = bytes;
        slot.part_count += 1;
    }

    fn sendNext(self: *Server, index: usize) anyerror!void {
        const slot = &self.slots[index];
        assert(!slot.op_pending and !slot.closing);
        while (slot.part < slot.part_count) {
            const bytes = slot.parts[slot.part][slot.part_offset..];
            if (bytes.len == 0) {
                slot.part += 1;
                slot.part_offset = 0;
                continue;
            }
            const token = tokenFor(slot, index, .send);
            try self.backend.send(token, slot.fd, bytes[0..@min(bytes.len, self.config.send_chunk)]);
            slot.op_pending = true;
            slot.op_token = token;
            self.operationAdded();
            return;
        }
        switch (slot.send_mode) {
            .interim => try self.receive(index),
            .reject => try self.beginClose(slot),
            .response => {
                slot.writer.release();
                if (slot.action == .flush) {
                    slot.event = .flushed;
                    self.stats.resumed += 1;
                    self.dispatch(index);
                } else {
                    assert(slot.action == .finish);
                    self.stats.completed += 1;
                    self.stats.max_request_ns = @max(self.stats.max_request_ns, nowNs() - slot.request_started);
                    if (!slot.request.keep_alive) return self.beginClose(slot);
                    assert(slot.request.consumed <= slot.received);
                    const remaining = slot.received - slot.request.consumed;
                    if (remaining != 0) {
                        std.mem.copyForwards(u8, slot.input[0..remaining], slot.input[slot.request.consumed..slot.received]);
                        self.stats.pipeline_copy_bytes += remaining;
                    }
                    slot.received = remaining;
                    slot.parser.reset();
                    slot.interim_sent = false;
                    slot.request_started = nowNs();
                    slot.deadline = slot.request_started + @as(u64, self.config.timeout_ms) * 1_000_000;
                    if (remaining == 0) try self.receive(index) else try self.parseRequest(index);
                }
            },
        }
    }

    fn beginClose(self: *Server, slot: *Slot) !void {
        slot.closing = true;
        slot.cancelled.store(true, .release);
        if (slot.fd >= 0) self.backend.shutdown(slot.fd);
        if (slot.op_pending and !slot.cancel_pending) {
            const token = (slot.op_token & ~@as(u64, 255)) | @intFromEnum(Kind.cancel);
            try self.backend.cancel(token, slot.op_token);
            slot.cancel_pending = true;
            self.operationAdded();
        }
        if (!slot.op_pending and slot.fd >= 0) {
            self.backend.close(slot.fd);
            slot.fd = -1;
        }
    }

    fn maybeFree(self: *Server, slot: *Slot) void {
        if (!slot.closing or slot.op_pending or slot.cancel_pending or
            slot.phase.load(.acquire) != .io) return;
        if (slot.fd >= 0) {
            self.backend.close(slot.fd);
            slot.fd = -1;
        }
        assert(slot.in_use and self.stats.live_connections > 0);
        self.stats.live_connections -= 1;
        slot.in_use = false;
        slot.closing = false;
        slot.received = 0;
    }

    fn refreshDate(self: *Server) void {
        var ts: c.timespec = undefined;
        assert(c.clock_gettime(.REALTIME, &ts) == 0);
        const seconds: u64 = @intCast(@max(ts.sec, 0));
        if (seconds == self.date_second) return;
        self.date_second = seconds;
        const epoch = std.time.epoch.EpochSeconds{ .secs = @min(seconds, 253402300799) };
        const day = epoch.getEpochDay();
        const year_day = day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const time = epoch.getDaySeconds();
        const weekdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
        const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
        _ = std.fmt.bufPrint(&self.date, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{ weekdays[(day.day + 4) % 7], @as(u8, month_day.day_index) + 1, months[@intFromEnum(month_day.month) - 1], year_day.year, time.getHoursIntoDay(), time.getMinutesIntoHour(), time.getSecondsIntoMinute() }) catch unreachable;
    }
};

pub fn nowNs() u64 {
    var time: c.timespec = undefined;
    assert(c.clock_gettime(.MONOTONIC, &time) == 0);
    return @as(u64, @intCast(time.sec)) * 1_000_000_000 + @as(u64, @intCast(time.nsec));
}

fn reason(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        204 => "No Content",
        304 => "Not Modified",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Content Too Large",
        414 => "URI Too Long",
        417 => "Expectation Failed",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        505 => "HTTP Version Not Supported",
        else => "Response",
    };
}

test "configuration rejects combined resource overcommit and impossible worker limits" {
    try (Config{}).validate();
    try std.testing.expectError(error.InvalidConfiguration, (Config{ .workers = 0 }).validate());
    try std.testing.expectError(error.InvalidConfiguration, (Config{ .connections = 1, .workers = 2 }).validate());
    try std.testing.expectError(error.MemoryBudgetExceeded, (Config{ .connections = 4096, .max_body = 1024 * 1024 }).validate());
}

test "inline execution explicitly requires no application worker resources" {
    try (Config{ .execution = .inline_event_loop, .workers = 0 }).validate();
    try std.testing.expectError(error.InvalidConfiguration, (Config{ .execution = .inline_event_loop }).validate());
    const config: Config = .{ .execution = .inline_event_loop, .workers = 0, .connections = 1, .port = 0 };
    const server = try Server.init(std.testing.allocator, config, struct {
        fn handle(_: *api.Context) api.Action {
            @panic("stopped server must not dispatch a callback");
        }
    }.handle, null);
    defer server.deinit();
    try std.testing.expectEqual(@as(usize, 0), server.workers.len);
    try server.start();
    try std.testing.expectEqual(@as(u32, 0), server.ready_workers.load(.acquire));
    server.requestStop();
    try server.run();
    try std.testing.expectEqual(@as(u32, 0), server.exited_workers.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), server.stats.worker_dispatches);
    try std.testing.expect(server.safe_to_destroy);
}
