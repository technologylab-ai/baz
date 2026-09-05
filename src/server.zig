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
/// Inline mode is the default and reserves no application threads. Applications
/// with blocking callbacks explicitly select the fixed worker execution mode.
pub const Execution = enum { workers, inline_event_loop };

pub const Config = struct {
    execution: Execution = .inline_event_loop,
    gather_send: bool = true,
    /// Finished responses retained per connection before a drain; each is a
    /// range of the connection's output arena plus an optional borrowed span.
    response_batch_limit: u16 = 128,
    port: u16 = 8080,
    connections: u16 = 128,
    workers: u16 = 0,
    max_body: u32 = 65536,
    max_header: u32 = 16384,
    max_headers: u16 = 64,
    /// Contiguous output arena per connection: response heads, generated
    /// bodies, chunk framing and copied small borrows of one batch.
    output_bytes: u32 = 65536,
    /// Borrowed spans up to this size are copied into the arena; 0 disables.
    borrow_copy_threshold: u32 = 256,
    /// Inline callbacks per event-loop turn; 0 selects connections × batch
    /// limit, capped. Reported in Stats.
    callbacks_per_turn: u32 = 0,
    /// Exact per-callback queue/handler timing costs two clock reads each.
    callback_timing: bool = false,
    /// Interval of the full deadline sweep; touched slots are checked sooner.
    deadline_sweep_ms: u32 = 100,
    /// Submit queued sends after this many drains within a turn so responses
    /// leave before the turn ends; 0 submits only when the turn polls. Measured
    /// on omarx1 (2026-09-05): no throughput change at any depth, more CPU.
    submit_batch: u16 = 0,
    /// Arm the next receive while a batch is still being sent. Measured
    /// 2026-09-05: no change on io_uring, 6-16% slower on kqueue where the
    /// early receive costs two syscalls that find no data yet. Off by default.
    prearm_receive: bool = false,
    /// I/O owners. 0 selects one per allowed CPU on Linux and 1 elsewhere.
    shards: u8 = 0,
    /// Pin shard i to the i-th CPU the process may use (Linux only).
    shard_affinity: bool = false,
    max_response_bytes: usize = 16 * 1024 * 1024,
    timeout_ms: u32 = 5000,
    shutdown_ms: u32 = 5000,
    duration_ms: u32 = 0,
    send_chunk: u32 = 65536,
    socket_send_buffer_bytes: u32 = 65536,
    worker_stack_bytes: usize = 1024 * 1024,
    memory_budget_bytes: usize = 512 * 1024 * 1024,
    /// Set by the cluster for every shard beyond the first; never by users.
    reuse_port: bool = false,

    pub const max_callbacks_per_turn_auto: u32 = 8192;

    pub fn wireBytes(self: Config) !usize {
        const body = try std.math.mul(usize, self.max_body, 2);
        return std.math.add(usize, try std.math.add(usize, body, self.max_header), 4096);
    }
    pub fn effectiveBatchLimit(self: Config) usize {
        return if (self.execution == .inline_event_loop) self.response_batch_limit else 1;
    }
    pub fn effectiveCallbacksPerTurn(self: Config) usize {
        if (self.callbacks_per_turn != 0) return self.callbacks_per_turn;
        return @min(@as(usize, self.connections) * self.effectiveBatchLimit(), max_callbacks_per_turn_auto);
    }
    /// Gather vectors one batch can describe: arena runs around every borrow.
    pub fn maxSendParts(self: Config) usize {
        return 2 * self.effectiveBatchLimit() + 1;
    }

    /// Exact requested bytes for the framework allocator's startup allocations.
    /// Kernel mappings, allocator metadata, application allocations and pthread
    /// bookkeeping remain outside this metric; requested stacks are separate.
    pub fn heapBytes(self: Config) !usize {
        const count: usize = self.connections;
        const cells = try std.math.mul(usize, count, self.effectiveBatchLimit());
        const storage = try std.math.mul(usize, count, try std.math.add(usize, try self.wireBytes(), self.output_bytes));
        const vectors = try std.math.mul(usize, count, try std.math.mul(usize, 2 * self.maxSendParts(), @sizeOf(c.iovec_const)));
        var total: usize = @sizeOf(Server);
        for ([_]usize{
            storage,
            try std.math.mul(usize, count, @sizeOf(Slot)),
            try std.math.mul(usize, cells, @sizeOf(Cell)),
            vectors,
            try std.math.mul(usize, count, 2 * @sizeOf(u32)),
            try std.math.mul(usize, self.workers, @sizeOf(Worker)),
            try std.math.mul(usize, transport.cellCount(self.connections), transport.Backend.operation_bytes),
        }) |bytes| total = try std.math.add(usize, total, bytes);
        return total;
    }

    pub fn validate(self: Config) !void {
        const invalid_workers = switch (self.execution) {
            .workers => self.workers == 0,
            .inline_event_loop => self.workers != 0,
        };
        if (self.connections == 0 or self.connections > 4096 or invalid_workers or
            self.workers > 64 or self.workers > self.connections or self.max_header < 128 or
            self.max_header > 65536 or self.max_body > 16 * 1024 * 1024 or
            self.output_bytes < 1024 or self.output_bytes > 1024 * 1024 or self.timeout_ms == 0 or
            self.shutdown_ms == 0 or self.send_chunk == 0 or self.socket_send_buffer_bytes == 0 or
            self.socket_send_buffer_bytes > 16 * 1024 * 1024 or self.max_headers == 0 or
            self.max_headers > 1024 or self.worker_stack_bytes < 65536 or
            self.response_batch_limit == 0 or self.response_batch_limit > 511 or
            self.borrow_copy_threshold > 4096 or self.callbacks_per_turn > 1 << 20 or
            self.deadline_sweep_ms == 0 or self.deadline_sweep_ms > 1000 or self.shards > 64 or
            self.submit_batch > 4096)
            return error.InvalidConfiguration;
        assert(self.maxSendParts() <= transport.max_vectors);
        const stacks = try std.math.mul(usize, self.worker_stack_bytes, self.workers);
        if (try std.math.add(usize, try self.heapBytes(), stacks) > self.memory_budget_bytes)
            return error.MemoryBudgetExceeded;
    }
};

pub const Stats = struct {
    execution: Execution = .inline_event_loop,
    gather_send: bool = true,
    response_batch_limit: usize = 128,
    callbacks_per_turn: usize = 0,
    shards: u16 = 1,
    response_batches: u64 = 0,
    batched_finished_responses: u64 = 0,
    max_batch_responses: usize = 0,
    scalar_send_operations: u64 = 0,
    gather_send_operations: u64 = 0,
    /// Gather-mode operations whose batch formed one contiguous span.
    single_span_send_operations: u64 = 0,
    borrow_copies: u64 = 0,
    send_completions: u64 = 0,
    short_send_completions: u64 = 0,
    gather_cancel_requests: u64 = 0,
    gather_canceled_completions: u64 = 0,
    /// Frozen response cells retained when cancellation of a pending gather is
    /// successfully requested. The target may still complete normally in a race.
    max_canceled_batch_responses: usize = 0,
    max_send_parts: usize = 0,
    max_send_bytes: usize = 0,
    max_inline_callbacks_per_turn: usize = 0,
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
    /// Event-loop turns and polls that found nothing ready and had to wait.
    turns: u64 = 0,
    idle_polls: u64 = 0,
    /// Receives armed while the previous batch was still being sent.
    prearmed_receives: u64 = 0,
    max_handler_ns: u64 = 0,
    max_queue_ns: u64 = 0,
    max_request_ns: u64 = 0,
    workers: u16 = 0,
    allocation_calls_after_start: usize = 0,
    framework_heap_peak_bytes: usize = 0,
    framework_heap_limit_bytes: usize = 0,

    /// Sum counters and take maxima; used when several shards report together.
    pub fn merge(self: *Stats, other: Stats) void {
        inline for (@typeInfo(Stats).@"struct".fields) |field| {
            const name = field.name;
            if (comptime std.mem.startsWith(u8, name, "max_")) {
                @field(self, name) = @max(@field(self, name), @field(other, name));
            } else if (comptime std.mem.eql(u8, name, "execution") or std.mem.eql(u8, name, "gather_send") or
                std.mem.eql(u8, name, "response_batch_limit") or std.mem.eql(u8, name, "callbacks_per_turn") or
                std.mem.eql(u8, name, "shards") or std.mem.eql(u8, name, "framework_heap_peak_bytes") or
                std.mem.eql(u8, name, "framework_heap_limit_bytes") or std.mem.eql(u8, name, "allocation_calls_after_start"))
            {
                // Configuration and process-wide accounting are not summed.
            } else {
                @field(self, name) += @field(other, name);
            }
        }
    }
};

const Phase = enum(u8) { io, ready, running, result };
const SendMode = enum { response, interim, reject };
const Kind = enum(u8) { accept = 1, recv, send, cancel_recv, cancel_send, cancel_accept };
const accept_token: u64 = @intFromEnum(Kind.accept);
const cancel_accept_token: u64 = @intFromEnum(Kind.cancel_accept);

const BatchNext = enum { parse, resume_flush, close };

/// One finished or flushed response snapshot: a range of the connection's
/// arena, with an optional borrowed span logically inserted at `borrow_at`.
/// Arena bytes and the borrow stay frozen until the batch's terminal send
/// completion; the request input they borrow stays immutable as well.
const Cell = struct {
    begin: u32 = 0,
    end: u32 = 0,
    borrow_at: u32 = 0,
    borrowed: []const u8 = "",
    finished: bool = false,
    request_started: u64 = 0,
};

const Slot = struct {
    phase: std.atomic.Value(Phase) = .init(.io),
    cancelled: std.atomic.Value(bool) = .init(false),
    in_use: bool = false,
    in_ready: bool = false,
    generation: u32 = 0,
    fd: transport.Socket = -1,
    input: []u8,
    received: usize = 0,
    input_cursor: usize = 0,
    request_active: bool = false,
    arena: []u8,
    arena_used: usize = 0,
    cells: []Cell,
    batch_count: usize = 0,
    batch_next: BatchNext = .parse,
    parser: http.Parser,
    request: http.Request = undefined,
    writer: api.Writer,
    /// Worker callbacks read this exclusive snapshot, never the owner's mutable
    /// once-per-second cache. Inline callbacks use the owner cache directly.
    worker_header_cache: api.HeaderCache = .{},
    state: [8]usize = @splat(0),
    action: api.Action = .close,
    event: api.Event = .request,
    /// A receive into the free input tail and a send of the frozen batch may
    /// be in flight together; each has its own cell and cancel cell.
    recv_pending: bool = false,
    /// Peer write-half closure ends input, not pending response output.
    recv_eof: bool = false,
    recv_token: u64 = 0,
    recv_cancel_pending: bool = false,
    send_pending: bool = false,
    send_token: u64 = 0,
    send_cancel_pending: bool = false,
    /// Some frozen cell borrows request input, so the input must not move.
    batch_borrows_input: bool = false,
    closing: bool = false,
    deadline: u64 = 0,
    request_started: u64 = 0,
    queued_at: u64 = 0,
    queue_ns: u64 = 0,
    handler_ns: u64 = 0,
    interim_sent: bool = false,
    logical_written: usize = 0,
    /// Wire parts of the batch being sent: arena runs and borrowed spans.
    parts: []c.iovec_const,
    part_count: usize = 0,
    /// The bounded selection submitted by the current send operation.
    selection: []c.iovec_const,
    part: usize = 0,
    part_offset: usize = 0,
    send_submitted_bytes: usize = 0,
    send_is_gather: bool = false,
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

/// One I/O owner: listener, transport, slots, arenas, operation cells, clock
/// and counters. Several shards run several independent Servers.
pub const Server = struct {
    allocator: std.mem.Allocator,
    config: Config,
    handler: api.Handler,
    application: ?*anyopaque,
    backend: transport.Backend,
    slots: []Slot,
    workers: []Worker,
    storage: []u8,
    response_cells: []Cell,
    vectors: []c.iovec_const,
    /// Free connection slots as a stack; accept pops, release pushes.
    free_slots: []u32,
    free_count: usize = 0,
    /// Slots with a published callback or result, in FIFO order.
    ready: []u32,
    ready_head: usize = 0,
    ready_count: usize = 0,
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
    inline_budget: usize = 0,
    /// Turn clock: sampled per turn, after polling and every 16 callbacks.
    now: u64 = 0,
    clock_budget: u32 = 0,
    last_sweep: u64 = 0,
    header_cache: api.HeaderCache = .{},
    date: [29]u8 = undefined,
    date_second: u64 = std.math.maxInt(u64),
    /// Shared process-wide ceiling when running as a shard; null standalone.
    admission: ?*Admission = null,
    /// Drains since the last explicit submission within the current turn.
    drains_since_flush: u16 = 0,

    const clock_refresh_callbacks: u32 = 16;

    pub fn init(allocator: std.mem.Allocator, config: Config, handler: api.Handler, application: ?*anyopaque) !*Server {
        try config.validate();
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);
        var backend = try transport.Backend.init(allocator, config.connections, config.port, config.reuse_port);
        errdefer backend.deinit();
        if (config.gather_send) try backend.enableGather();
        const slots = try allocator.alloc(Slot, config.connections);
        errdefer allocator.free(slots);
        const workers = try allocator.alloc(Worker, config.workers);
        errdefer allocator.free(workers);
        const wire = try config.wireBytes();
        const batch_limit = config.effectiveBatchLimit();
        const response_cells = try allocator.alloc(Cell, config.connections * batch_limit);
        errdefer allocator.free(response_cells);
        const parts_per_slot = config.maxSendParts();
        const vectors = try allocator.alloc(c.iovec_const, config.connections * 2 * parts_per_slot);
        errdefer allocator.free(vectors);
        const free_slots = try allocator.alloc(u32, config.connections);
        errdefer allocator.free(free_slots);
        const ready = try allocator.alloc(u32, config.connections);
        errdefer allocator.free(ready);
        const per_slot = wire + config.output_bytes;
        const storage = try allocator.alloc(u8, per_slot * config.connections);
        errdefer allocator.free(storage);
        @memset(storage, 0);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .handler = handler,
            .application = application,
            .backend = backend,
            .slots = slots,
            .workers = workers,
            .storage = storage,
            .response_cells = response_cells,
            .vectors = vectors,
            .free_slots = free_slots,
            .ready = ready,
            .stats = .{
                .workers = config.workers,
                .execution = config.execution,
                .gather_send = config.gather_send,
                .response_batch_limit = batch_limit,
                .callbacks_per_turn = config.effectiveCallbacksPerTurn(),
            },
        };
        for (slots, 0..) |*slot, index| {
            const base = storage[index * per_slot ..][0..per_slot];
            const arena = base[wire..][0..config.output_bytes];
            slot.* = .{
                .cells = response_cells[index * batch_limit ..][0..batch_limit],
                .input = base[0..wire],
                .arena = arena,
                .parts = vectors[index * 2 * parts_per_slot ..][0..parts_per_slot],
                .selection = vectors[index * 2 * parts_per_slot + parts_per_slot ..][0..parts_per_slot],
                .parser = http.Parser.init(.{
                    .max_header_bytes = config.max_header,
                    .max_header_count = config.max_headers,
                    .max_body_bytes = config.max_body,
                    .max_wire_bytes = @intCast(wire),
                    .max_target_bytes = 8192,
                }),
                .writer = api.Writer.init(arena, &self.header_cache, config.borrow_copy_threshold),
            };
            @memset(slot.cells, .{});
            // Higher slots go in first so accept pops the lowest free index.
            free_slots[index] = @intCast(config.connections - 1 - index);
        }
        self.free_count = config.connections;
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
        self.now = self.started_at;
        self.last_sweep = self.started_at;
        self.refreshDate();
    }

    pub fn requestStop(self: *Server) void {
        self.stop_requested.store(true, .release);
        self.backend.wake();
    }

    fn recvCell(self: *const Server, index: usize) u32 {
        assert(index < self.slots.len);
        return @intCast(index);
    }
    fn sendCell(self: *const Server, index: usize) u32 {
        assert(index < self.slots.len);
        return @intCast(self.slots.len + index);
    }
    fn recvCancelCell(self: *const Server, index: usize) u32 {
        assert(index < self.slots.len);
        return @intCast(2 * self.slots.len + index);
    }
    fn sendCancelCell(self: *const Server, index: usize) u32 {
        assert(index < self.slots.len);
        return @intCast(3 * self.slots.len + index);
    }
    fn acceptCell(self: *const Server) u32 {
        return @intCast(4 * self.slots.len);
    }
    fn cancelAcceptCell(self: *const Server) u32 {
        return @intCast(4 * self.slots.len + 1);
    }

    fn sampleClock(self: *Server) void {
        self.now = nowNs();
        self.clock_budget = clock_refresh_callbacks;
    }

    fn pushReady(self: *Server, index: usize) void {
        const slot = &self.slots[index];
        if (slot.in_ready) return;
        assert(self.ready_count < self.ready.len);
        self.ready[(self.ready_head + self.ready_count) % self.ready.len] = @intCast(index);
        self.ready_count += 1;
        slot.in_ready = true;
    }

    fn popReady(self: *Server) usize {
        assert(self.ready_count > 0);
        const index = self.ready[self.ready_head];
        self.ready_head = (self.ready_head + 1) % self.ready.len;
        self.ready_count -= 1;
        self.slots[index].in_ready = false;
        return index;
    }

    pub fn run(self: *Server) !void {
        assert(self.started);
        var completions: [512]transport.Completion = undefined;
        const sweep_ns = @as(u64, self.config.deadline_sweep_ms) * 1_000_000;
        while (true) {
            self.inline_budget = self.stats.callbacks_per_turn;
            self.drains_since_flush = 0;
            self.sampleClock();
            const turn_start = self.now;
            if (self.config.duration_ms != 0 and
                turn_start - self.started_at >= @as(u64, self.config.duration_ms) * 1_000_000)
                self.stop_requested.store(true, .release);
            if (self.stop_requested.load(.acquire) and !self.stopping) {
                self.stopping = true;
                self.stop_deadline = turn_start + @as(u64, self.config.shutdown_ms) * 1_000_000;
            }
            if (self.stopping and self.accept_pending and !self.accept_cancel_requested) {
                try self.backend.cancel(self.cancelAcceptCell(), cancel_accept_token, self.acceptCell());
                self.accept_cancel_pending = true;
                self.accept_cancel_requested = true;
                self.operationAdded();
            }
            if (!self.stopping and !self.accept_pending) {
                try self.backend.accept(self.acceptCell(), accept_token);
                self.accept_pending = true;
                self.operationAdded();
            }
            self.refreshDate();
            if (self.stopping or turn_start - self.last_sweep >= sweep_ns) {
                self.last_sweep = turn_start;
                for (self.slots) |*slot| {
                    if (!slot.in_use) continue;
                    if (slot.closing) {
                        self.maybeFree(slot);
                    } else if (self.stopping or turn_start >= slot.deadline) {
                        if (!self.stopping) self.stats.timeouts += 1;
                        try self.beginClose(slot);
                    }
                }
            }
            switch (self.config.execution) {
                .inline_event_loop => {
                    // One pass over the slots that were ready when the turn
                    // began; anything readied meanwhile waits for the next turn.
                    var remaining = self.ready_count;
                    while (remaining > 0 and self.inline_budget > 0) : (remaining -= 1) {
                        try self.serviceSlot(self.popReady());
                    }
                },
                .workers => for (self.slots, 0..) |*slot, index| {
                    if (slot.in_use) try self.serviceSlot(index);
                },
            }
            const control_ns = nowNs() - turn_start;
            self.stats.max_loop_ns = @max(self.stats.max_loop_ns, control_ns);
            if (self.stopping and self.stats.live_connections == 0 and
                self.stats.live_operations == 0) break;
            if (self.stopping and self.now >= self.stop_deadline) return error.ShutdownStalled;
            const local_ready = self.ready_count > 0 or (self.config.execution == .workers and self.anyResult());
            self.stats.turns += 1;
            const count = try self.backend.poll(&completions, if (local_ready) 0 else 10);
            if (count == 0 and !local_ready) self.stats.idle_polls += 1;
            self.sampleClock();
            const processing_start = self.now;
            for (completions[0..count]) |completion| try self.onCompletion(completion);
            assert(self.inline_budget <= self.stats.callbacks_per_turn);
            self.stats.max_inline_callbacks_per_turn = @max(self.stats.max_inline_callbacks_per_turn, self.stats.callbacks_per_turn - self.inline_budget);
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

    fn anyResult(self: *Server) bool {
        for (self.slots) |*slot| {
            if (slot.in_use and slot.phase.load(.acquire) == .result) return true;
        }
        return false;
    }

    /// Run the callbacks a slot has ready and process each published result.
    fn serviceSlot(self: *Server, index: usize) !void {
        const slot = &self.slots[index];
        if (!slot.in_use) return;
        if (!slot.closing and (self.stopping or self.now >= slot.deadline)) {
            if (!self.stopping) self.stats.timeouts += 1;
            try self.beginClose(slot);
        }
        // At most one configured batch worth of callbacks per slot and visit.
        // Empty flushes also consume this finite progress budget.
        const batch_limit = self.config.effectiveBatchLimit();
        for (0..batch_limit) |iteration| {
            if (self.config.execution == .inline_event_loop and
                slot.phase.load(.acquire) == .ready and self.inline_budget > 0)
            {
                // Preceding callbacks may have consumed time since the turn
                // clock was sampled; the clock refreshes every few callbacks.
                if (!slot.closing and (self.stop_requested.load(.acquire) or self.now >= slot.deadline)) {
                    if (!self.stop_requested.load(.acquire)) self.stats.timeouts += 1;
                    try self.beginClose(slot);
                }
                self.invokeInline(slot);
            }
            if (slot.phase.load(.acquire) != .result) break;
            if (self.config.callback_timing) {
                self.stats.max_handler_ns = @max(self.stats.max_handler_ns, slot.handler_ns);
                self.stats.max_queue_ns = @max(self.stats.max_queue_ns, slot.queue_ns);
            }
            slot.phase.store(.io, .release);
            if (slot.closing or slot.action == .close) {
                try self.beginClose(slot);
            } else if (self.stop_requested.load(.acquire) or self.now >= slot.deadline) {
                if (!self.stop_requested.load(.acquire)) self.stats.timeouts += 1;
                try self.beginClose(slot);
            } else {
                try self.prepareResponse(index, iteration + 1 < batch_limit);
            }
        }
        if (slot.closing) self.maybeFree(slot);
        // A budget-exhausted or re-dispatched slot is serviced next turn.
        if (self.config.execution == .inline_event_loop and slot.in_use) {
            const phase = slot.phase.load(.acquire);
            if (phase == .ready or phase == .result) self.pushReady(index);
        }
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
        self.allocator.free(self.ready);
        self.allocator.free(self.free_slots);
        self.allocator.free(self.vectors);
        self.allocator.free(self.response_cells);
        self.allocator.free(self.slots);
        self.allocator.free(self.workers);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    fn operationAdded(self: *Server) void {
        self.stats.live_operations += 1;
        self.stats.peak_operations = @max(self.stats.peak_operations, self.stats.live_operations);
        assert(self.stats.live_operations <= transport.cellCount(self.config.connections));
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
            if (self.stopping or self.free_count == 0) {
                if (!self.stopping) self.stats.rejected += 1;
                transport.closeFd(completion.result);
                return;
            }
            if (self.admission) |admission| {
                if (!admission.admit()) {
                    self.stats.rejected += 1;
                    transport.closeFd(completion.result);
                    return;
                }
            }
            const index = self.free_slots[self.free_count - 1];
            const slot = &self.slots[index];
            assert(!slot.in_use and slot.phase.load(.acquire) == .io);
            slot.generation = try std.math.add(u32, slot.generation, 1);
            slot.fd = completion.result;
            const send_buffer: c_int = @intCast(self.config.socket_send_buffer_bytes);
            if (c.setsockopt(slot.fd, c.SOL.SOCKET, c.SO.SNDBUF, &send_buffer, @sizeOf(c_int)) != 0) {
                transport.closeFd(slot.fd);
                slot.fd = -1;
                self.stats.rejected += 1;
                if (self.admission) |admission| admission.release();
                return;
            }
            self.free_count -= 1;
            slot.in_use = true;
            slot.closing = false;
            slot.cancelled.store(false, .release);
            slot.received = 0;
            slot.recv_eof = false;
            slot.input_cursor = 0;
            slot.request_active = false;
            slot.batch_count = 0;
            slot.arena_used = 0;
            slot.batch_borrows_input = false;
            slot.part_count = 0;
            slot.part = 0;
            slot.part_offset = 0;
            slot.parser.reset();
            slot.interim_sent = false;
            slot.logical_written = 0;
            slot.deadline = self.now + @as(u64, self.config.timeout_ms) * 1_000_000;
            slot.request_started = self.now;
            self.stats.accepted += 1;
            self.stats.live_connections += 1;
            self.stats.peak_connections = @max(self.stats.peak_connections, self.stats.live_connections);
            assert(self.stats.live_connections <= self.slots.len);
            try self.receive(index);
            return;
        }
        const index: usize = @intCast((completion.token >> 8) & 0xffff);
        assert(index < self.slots.len);
        const slot = &self.slots[index];
        assert(slot.in_use and slot.generation == completion.token >> 32);
        if (kind == .cancel_recv) {
            assert(slot.recv_cancel_pending);
            slot.recv_cancel_pending = false;
            self.maybeFree(slot);
            return;
        }
        if (kind == .cancel_send) {
            assert(slot.send_cancel_pending);
            slot.send_cancel_pending = false;
            self.maybeFree(slot);
            return;
        }
        if (kind == .recv) {
            assert(slot.recv_pending and slot.recv_token == completion.token);
            slot.recv_pending = false;
        } else {
            assert(kind == .send and slot.send_pending and slot.send_token == completion.token);
            slot.send_pending = false;
        }
        if (kind == .send) {
            self.stats.send_completions += 1;
            if (completion.result > 0) {
                assert(@as(usize, @intCast(completion.result)) <= slot.send_submitted_bytes);
                if (@as(usize, @intCast(completion.result)) < slot.send_submitted_bytes)
                    self.stats.short_send_completions += 1;
            } else if (slot.send_is_gather and completion.result == -@as(i32, @intFromEnum(c.E.CANCELED))) {
                self.stats.gather_canceled_completions += 1;
            }
        }
        if (!slot.closing and kind == .recv and completion.result == 0) {
            slot.recv_eof = true;
            // A prearmed receive can observe EOF while output or a callback
            // still owns the request. Those owners finish before input closure
            // is handled; complete buffered requests remain eligible to run.
            if (!slot.send_pending and slot.batch_count == 0 and !slot.request_active)
                try self.parseRequest(index);
            return;
        }
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
                // Bytes that arrive while a batch is still being sent, or while
                // a flushed request waits to resume, are parsed after that batch.
                if (!slot.send_pending and slot.batch_count == 0 and !slot.request_active)
                    try self.parseRequest(index);
            },
            .send => {
                assert(transferred <= slot.send_submitted_bytes);
                advanceSendParts(slot.parts[0..slot.part_count], &slot.part, &slot.part_offset, transferred);
                self.stats.bytes_sent += transferred;
                try self.sendNext(index);
            },
            else => unreachable,
        }
    }

    /// Idle receive: nothing is buffered, sent or active for this connection.
    fn receive(self: *Server, index: usize) anyerror!void {
        const slot = &self.slots[index];
        assert(!slot.recv_pending and !slot.send_pending and !slot.closing and slot.phase.load(.acquire) == .io);
        assert(slot.batch_count == 0 and !slot.request_active and slot.input_cursor == 0);
        if (slot.received == slot.input.len) return self.reject(index, 413);
        try self.armReceive(index);
    }

    fn armReceive(self: *Server, index: usize) anyerror!void {
        const slot = &self.slots[index];
        assert(!slot.recv_pending and !slot.recv_eof and !slot.closing and slot.received < slot.input.len);
        const token = tokenFor(slot, index, .recv);
        try self.backend.recv(self.recvCell(index), token, slot.fd, slot.input[slot.received..]);
        slot.recv_pending = true;
        slot.recv_token = token;
        self.operationAdded();
    }

    /// Arm the next receive while the batch is sent, so the client's next
    /// pipeline lands in the free input tail without waiting for the send.
    /// The consumed prefix is compacted first when no frozen cell borrows it.
    fn prearmReceive(self: *Server, index: usize) anyerror!void {
        const slot = &self.slots[index];
        if (slot.recv_pending or slot.recv_eof or slot.closing or slot.request_active or slot.batch_borrows_input) return;
        if (slot.input_cursor != 0) {
            const remaining = slot.received - slot.input_cursor;
            if (remaining != 0) {
                std.mem.copyForwards(u8, slot.input[0..remaining], slot.input[slot.input_cursor..slot.received]);
                self.stats.pipeline_copy_bytes += remaining;
            }
            slot.received = remaining;
            slot.input_cursor = 0;
            slot.parser.reset();
        }
        if (slot.received == slot.input.len) return;
        try self.armReceive(index);
        self.stats.prearmed_receives += 1;
    }

    fn parseRequest(self: *Server, index: usize) !void {
        const slot = &self.slots[index];
        assert(!slot.request_active and !slot.send_pending and slot.input_cursor <= slot.received);
        assert(slot.batch_count < slot.cells.len);
        const parsed = slot.parser.parseInto(slot.input[slot.input_cursor..slot.received], &slot.request) catch |err| {
            // Earlier successful responses retain wire order before this error.
            // Drain them, compact safely, then parse/reject the unchanged suffix.
            if (slot.batch_count != 0) return self.drainBatch(index, .parse);
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
        if (parsed) {
            slot.request_active = true;
            assert(slot.arena.len - slot.arena_used >= api.header_reserve_bytes);
            slot.writer.open(slot.arena_used, slot.request.keep_alive, slot.request.head_only);
            slot.state = @splat(0);
            slot.event = .request;
            slot.logical_written = 0;
            self.dispatch(index);
        } else if (slot.batch_count != 0) {
            // Do not wait for another byte, including an Expect body, to send
            // responses that are already complete.
            return self.drainBatch(index, .parse);
        } else if (slot.parser.head_complete and slot.parser.expect_continue and !slot.interim_sent) {
            slot.interim_sent = true;
            slot.send_mode = .interim;
            slot.part_count = 1;
            slot.parts[0] = transport.vector("HTTP/1.1 100 Continue\r\n\r\n");
            slot.part = 0;
            slot.part_offset = 0;
            try self.sendNext(index);
        } else try self.receiveMore(index);
    }

    /// An incomplete request needs more bytes. A pre-armed receive already
    /// covers that; otherwise reclaim the consumed prefix, which nothing
    /// borrows once no batch is in flight, then arm or refuse a full buffer.
    fn receiveMore(self: *Server, index: usize) anyerror!void {
        const slot = &self.slots[index];
        if (slot.recv_pending) return;
        assert(slot.batch_count == 0 and !slot.request_active and !slot.send_pending);
        if (slot.recv_eof) {
            // parseRequest already consumed every complete request. A remaining
            // incomplete prefix cannot become complete after EOF.
            if (slot.input_cursor < slot.received) return self.reject(index, 400);
            return self.beginClose(slot);
        }
        if (slot.input_cursor != 0) {
            const remaining = slot.received - slot.input_cursor;
            if (remaining != 0) {
                std.mem.copyForwards(u8, slot.input[0..remaining], slot.input[slot.input_cursor..slot.received]);
                self.stats.pipeline_copy_bytes += remaining;
            }
            slot.received = remaining;
            slot.input_cursor = 0;
            // The parser's incremental state indexes the old base; re-parse the
            // bounded suffix from the new one before the next completion.
            slot.parser.reset();
            if (remaining != 0) return self.parseRequest(index);
        }
        try self.receive(index);
    }

    fn dispatch(self: *Server, index: usize) void {
        const slot = &self.slots[index];
        assert(slot.phase.load(.acquire) == .io and !slot.closing and !slot.send_pending);
        if (self.config.callback_timing) slot.queued_at = nowNs();
        switch (self.config.execution) {
            .workers => {
                assert(self.workers.len > 0);
                self.snapshotWorkerHeader(slot);
                self.stats.worker_dispatches += 1;
                slot.phase.store(.ready, .release);
                self.workers[index % self.workers.len].wake();
            },
            .inline_event_loop => {
                assert(self.workers.len == 0);
                slot.phase.store(.ready, .release);
                self.pushReady(index);
            },
        }
    }

    fn snapshotWorkerHeader(self: *Server, slot: *Slot) void {
        assert(self.config.execution == .workers and slot.phase.load(.acquire) == .io);
        slot.worker_header_cache = self.header_cache;
        slot.writer.header_cache = &slot.worker_header_cache;
    }

    fn callbackClockDue(budget: *u32) bool {
        assert(budget.* > 0);
        budget.* -= 1;
        return budget.* == 0;
    }

    fn invokeInline(self: *Server, slot: *Slot) void {
        assert(self.config.execution == .inline_event_loop and self.inline_budget > 0);
        assert(slot.phase.load(.acquire) == .ready);
        self.inline_budget -= 1;
        self.stats.inline_dispatches += 1;
        slot.phase.store(.running, .release);
        self.invokeHandler(slot);
        if (callbackClockDue(&self.clock_budget)) self.sampleClock();
    }

    /// Caller exclusively owns the running phase. Publishing result ends every
    /// callback borrow, including inline execution; response processing belongs
    /// to the I/O loop and never recursively invokes a resumed callback here.
    fn invokeHandler(self: *Server, slot: *Slot) void {
        assert(slot.phase.load(.acquire) == .running);
        const timing = self.config.callback_timing;
        const started = if (timing) nowNs() else 0;
        if (timing) slot.queue_ns = started - slot.queued_at;
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
        if (timing) slot.handler_ns = nowNs() - started;
        slot.phase.store(.result, .release);
    }

    fn reject(self: *Server, index: usize, status: u16) !void {
        const slot = &self.slots[index];
        assert(slot.batch_count == 0 and slot.arena_used == 0);
        self.stats.rejected += 1;
        slot.send_mode = .reject;
        var n: usize = 0;
        const out = slot.arena;
        @memcpy(out[n..][0..9], "HTTP/1.1 ");
        n += 9;
        out[n] = @intCast('0' + status / 100);
        out[n + 1] = @intCast('0' + (status / 10) % 10);
        out[n + 2] = @intCast('0' + status % 10);
        out[n + 3] = ' ';
        n += 4;
        const text = api.reason(status);
        @memcpy(out[n..][0..text.len], text);
        n += text.len;
        const tail = "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        @memcpy(out[n..][0..tail.len], tail);
        n += tail.len;
        slot.parts[0] = transport.vector(out[0..n]);
        slot.part_count = 1;
        slot.part = 0;
        slot.part_offset = 0;
        try self.sendNext(index);
    }

    fn prepareResponse(self: *Server, index: usize, continue_turn: bool) !void {
        const slot = &self.slots[index];
        const writer = &slot.writer;
        assert(writer.frozen and slot.request_active and slot.batch_count < slot.cells.len);
        if (writer.copied_borrow) self.stats.borrow_copies += 1;
        const body_bytes = writer.bodyBytes();
        const total = std.math.add(usize, slot.logical_written, body_bytes) catch {
            return self.beginClose(slot);
        };
        if (total > self.config.max_response_bytes) return self.beginClose(slot);
        if (writer.content_length) |length| {
            if (total > length or (slot.action == .finish and total != length))
                return self.beginClose(slot);
        }
        if ((writer.status == 204 or writer.status == 304) and body_bytes != 0)
            return self.beginClose(slot);
        slot.logical_written = total;
        slot.send_mode = .response;
        const cell = &slot.cells[slot.batch_count];
        cell.* = .{ .begin = @intCast(writer.base), .finished = slot.action == .finish, .request_started = slot.request_started };
        const arena = slot.arena;
        var end = writer.buffered;
        if (writer.head_only or writer.status == 204 or writer.status == 304) {
            // The head is on the wire; body bytes are never sent.
            end = writer.body_start;
        } else if (writer.chunked()) {
            const size_at = writer.chunk_size_at.?;
            if (body_bytes == 0) {
                end = size_at; // Drop the unused size field.
            } else {
                api.putChunkSize(arena[size_at..][0..api.chunk_size_field_bytes], body_bytes);
                if (writer.borrowed) |span| {
                    assert(writer.generatedBytes() == 0);
                    cell.borrow_at = @intCast(writer.body_start);
                    cell.borrowed = span;
                }
                @memcpy(arena[end..][0..2], "\r\n");
                end += 2;
            }
            if (slot.action == .finish) {
                @memcpy(arena[end..][0..5], "0\r\n\r\n");
                end += 5;
            }
        } else if (writer.borrowed) |span| {
            assert(writer.generatedBytes() == 0);
            cell.borrow_at = @intCast(writer.body_start);
            cell.borrowed = span;
        }
        if (cell.borrowed.len != 0) {
            const address = @intFromPtr(cell.borrowed.ptr);
            const input_start = @intFromPtr(slot.input.ptr);
            if (address >= input_start and address < input_start + slot.input.len) slot.batch_borrows_input = true;
        }
        assert(end >= writer.base and end <= arena.len);
        cell.end = @intCast(end);
        slot.arena_used = end;
        writer.headers_committed = true;
        slot.batch_count += 1;
        assert(slot.batch_count <= slot.cells.len);
        if (slot.action == .flush) {
            self.stats.flushes += 1;
            return self.drainBatch(index, .resume_flush);
        }
        assert(slot.action == .finish);
        slot.request_active = false;
        assert(slot.request.consumed <= slot.received - slot.input_cursor);
        slot.input_cursor += slot.request.consumed;
        if (!slot.request.keep_alive) return self.drainBatch(index, .close);
        slot.parser.reset();
        slot.interim_sent = false;
        slot.request_started = self.now;
        // Keep the oldest unsent response's deadline. A later callback must not
        // extend ownership of bytes that are already waiting for the transport.
        if (self.config.execution == .inline_event_loop and continue_turn and
            self.inline_budget > 0 and slot.batch_count < slot.cells.len and
            slot.arena.len - slot.arena_used >= api.header_reserve_bytes and
            slot.input_cursor < slot.received)
            return self.parseRequest(index);
        return self.drainBatch(index, .parse);
    }

    /// Describe the batch as wire parts: adjacent arena bytes merge into one
    /// run, and each borrowed span is inserted where its cell recorded it.
    fn drainBatch(self: *Server, index: usize, next: BatchNext) anyerror!void {
        const slot = &self.slots[index];
        assert(slot.batch_count > 0 and !slot.send_pending);
        slot.batch_next = next;
        self.stats.response_batches += 1;
        self.stats.max_batch_responses = @max(self.stats.max_batch_responses, slot.batch_count);
        var count: usize = 0;
        var run_start: usize = slot.cells[0].begin;
        assert(run_start == 0);
        for (slot.cells[0..slot.batch_count]) |cell| {
            if (cell.borrowed.len == 0) continue;
            assert(cell.borrow_at >= run_start and cell.borrow_at <= cell.end);
            if (cell.borrow_at > run_start) {
                slot.parts[count] = transport.vector(slot.arena[run_start..cell.borrow_at]);
                count += 1;
            }
            slot.parts[count] = transport.vector(cell.borrowed);
            count += 1;
            run_start = cell.borrow_at;
        }
        if (slot.arena_used > run_start) {
            slot.parts[count] = transport.vector(slot.arena[run_start..slot.arena_used]);
            count += 1;
        }
        // An empty flush snapshot yields no parts and completes immediately.
        assert(count <= slot.parts.len);
        slot.part_count = count;
        slot.part = 0;
        slot.part_offset = 0;
        if (next == .parse and count > 0 and self.config.prearm_receive) try self.prearmReceive(index);
        try self.sendNext(index);
        if (count > 0 and self.config.submit_batch != 0) {
            self.drains_since_flush += 1;
            if (self.drains_since_flush >= self.config.submit_batch) {
                self.drains_since_flush = 0;
                try self.backend.flush();
            }
        }
    }

    fn sendNext(self: *Server, index: usize) anyerror!void {
        const slot = &self.slots[index];
        assert(!slot.send_pending and !slot.closing);
        while (slot.part < slot.part_count) {
            const current = slot.parts[slot.part];
            if (current.len - slot.part_offset == 0) {
                slot.part += 1;
                slot.part_offset = 0;
                continue;
            }
            const token = tokenFor(slot, index, .send);
            const cap = @min(self.config.send_chunk, std.math.maxInt(i32));
            const cell = self.sendCell(index);
            if (self.config.gather_send) {
                const selection = selectSendParts(slot.parts[0..slot.part_count], slot.part, slot.part_offset, cap, slot.selection);
                assert(selection.count > 0 and selection.bytes <= cap);
                // The selection storage and every payload stay borrowed until
                // the terminal completion of this operation.
                if (selection.count == 1) {
                    const only = slot.selection[0];
                    try self.backend.send(cell, token, slot.fd, only.base[0..only.len]);
                    self.stats.single_span_send_operations += 1;
                } else {
                    try self.backend.sendv(cell, token, slot.fd, slot.selection[0..selection.count]);
                }
                slot.send_submitted_bytes = selection.bytes;
                slot.send_is_gather = true;
                self.stats.gather_send_operations += 1;
                self.stats.max_send_parts = @max(self.stats.max_send_parts, selection.count);
            } else {
                const available = current.base[slot.part_offset..current.len];
                const submitted = available[0..@min(available.len, cap)];
                try self.backend.send(cell, token, slot.fd, submitted);
                slot.send_submitted_bytes = submitted.len;
                slot.send_is_gather = false;
                self.stats.scalar_send_operations += 1;
                self.stats.max_send_parts = @max(self.stats.max_send_parts, 1);
            }
            self.stats.max_send_bytes = @max(self.stats.max_send_bytes, slot.send_submitted_bytes);
            slot.send_pending = true;
            slot.send_token = token;
            self.operationAdded();
            return;
        }
        switch (slot.send_mode) {
            .interim => {
                slot.part_count = 0;
                slot.part = 0;
                slot.part_offset = 0;
                // A prearmed receive may have already completed while this
                // interim send was pending. Consume those buffered bytes before
                // asking the backend for another receive.
                try self.parseRequest(index);
            },
            .reject => try self.beginClose(slot),
            .response => try self.completeBatch(index),
        }
    }

    fn completeBatch(self: *Server, index: usize) anyerror!void {
        const slot = &self.slots[index];
        assert(!slot.send_pending and !slot.send_cancel_pending and slot.batch_count > 0);
        assert(slot.part == slot.part_count and slot.part_offset == 0);
        const completed_at = self.now;
        var finished: usize = 0;
        for (slot.cells[0..slot.batch_count]) |cell| {
            if (!cell.finished) continue;
            finished += 1;
            self.stats.max_request_ns = @max(self.stats.max_request_ns, completed_at -| cell.request_started);
        }
        self.stats.completed += finished;
        if (slot.batch_count > 1) self.stats.batched_finished_responses += finished;
        slot.batch_count = 0;
        slot.batch_borrows_input = false;
        slot.part_count = 0;
        slot.part = 0;
        slot.part_offset = 0;
        // Every cell and the whole arena are released together. The Writer is
        // the only metadata object left; its frozen snapshot ended with the batch.
        slot.writer.release();
        slot.arena_used = 0;
        // A fresh idle cycle starts after the preceding send finishes. Already
        // buffered partial/current requests retain their earlier deadline.
        if (slot.batch_next == .parse and !slot.request_active and slot.input_cursor == slot.received)
            slot.request_started = completed_at;
        slot.deadline = slot.request_started + @as(u64, self.config.timeout_ms) * 1_000_000;
        switch (slot.batch_next) {
            .resume_flush => {
                assert(slot.request_active);
                slot.writer.resumeSnapshot(0);
                slot.event = .flushed;
                self.stats.resumed += 1;
                self.dispatch(index);
            },
            .close => try self.beginClose(slot),
            .parse => {
                assert(!slot.request_active and slot.input_cursor <= slot.received);
                // No callback or transport retains the consumed prefix now.
                // Move the suffix once per batch, never once per response; a
                // pre-armed receive owns the tail, so compaction waits for it.
                if (slot.input_cursor != 0 and !slot.recv_pending) {
                    const remaining = slot.received - slot.input_cursor;
                    if (remaining != 0) {
                        std.mem.copyForwards(u8, slot.input[0..remaining], slot.input[slot.input_cursor..slot.received]);
                        self.stats.pipeline_copy_bytes += remaining;
                    }
                    slot.received = remaining;
                    slot.input_cursor = 0;
                    slot.parser.reset();
                }
                if (slot.input_cursor < slot.received) try self.parseRequest(index) else try self.receiveMore(index);
            },
        }
    }

    fn beginClose(self: *Server, slot: *Slot) !void {
        const index = (@intFromPtr(slot) - @intFromPtr(self.slots.ptr)) / @sizeOf(Slot);
        slot.closing = true;
        slot.cancelled.store(true, .release);
        if (slot.fd >= 0) self.backend.shutdown(slot.fd);
        if (slot.recv_pending and !slot.recv_cancel_pending) {
            const token = (slot.recv_token & ~@as(u64, 255)) | @intFromEnum(Kind.cancel_recv);
            try self.backend.cancel(self.recvCancelCell(index), token, self.recvCell(index));
            slot.recv_cancel_pending = true;
            self.operationAdded();
        }
        if (slot.send_pending and !slot.send_cancel_pending) {
            const token = (slot.send_token & ~@as(u64, 255)) | @intFromEnum(Kind.cancel_send);
            try self.backend.cancel(self.sendCancelCell(index), token, self.sendCell(index));
            if (slot.send_is_gather) {
                self.stats.gather_cancel_requests += 1;
                assert(slot.batch_count <= slot.cells.len);
                self.stats.max_canceled_batch_responses = @max(self.stats.max_canceled_batch_responses, slot.batch_count);
            }
            slot.send_cancel_pending = true;
            self.operationAdded();
        }
        if (!slot.recv_pending and !slot.send_pending and slot.fd >= 0) {
            self.backend.close(self.recvCell(index), slot.fd);
            slot.fd = -1;
        }
        // Release immediately when nothing is pending; otherwise the last
        // completion or the result publication releases the slot.
        self.maybeFree(slot);
    }

    fn maybeFree(self: *Server, slot: *Slot) void {
        if (!slot.closing or slot.recv_pending or slot.send_pending or
            slot.recv_cancel_pending or slot.send_cancel_pending or
            slot.phase.load(.acquire) != .io) return;
        const index = (@intFromPtr(slot) - @intFromPtr(self.slots.ptr)) / @sizeOf(Slot);
        if (slot.fd >= 0) {
            self.backend.close(self.recvCell(index), slot.fd);
            slot.fd = -1;
        }
        assert(slot.in_use and self.stats.live_connections > 0);
        self.stats.live_connections -= 1;
        if (self.admission) |admission| admission.release();
        slot.in_use = false;
        slot.closing = false;
        slot.received = 0;
        slot.input_cursor = 0;
        slot.request_active = false;
        slot.batch_count = 0;
        slot.batch_borrows_input = false;
        slot.arena_used = 0;
        assert(self.free_count < self.free_slots.len);
        self.free_slots[self.free_count] = @intCast(index);
        self.free_count += 1;
    }

    test "worker response headers retain their exclusive dispatch snapshot" {
        const server = try Server.init(std.testing.allocator, .{
            .execution = .workers,
            .workers = 1,
            .connections = 1,
            .port = 0,
        }, struct {
            fn handler(_: *api.Context) api.Action {
                return .close;
            }
        }.handler, null);
        defer server.deinit();
        const slot = &server.slots[0];
        const before = "Sat, 05 Sep 2026 12:34:56 GMT";
        const after = "Sat, 05 Sep 2026 12:34:57 GMT";
        server.header_cache.refresh(before);
        slot.writer.open(0, true, false);
        server.snapshotWorkerHeader(slot);
        // Deterministic ownership witness: refresh after publication, before
        // the callback reads the snapshot. No racing threads or sleeps needed.
        server.header_cache.refresh(after);
        try std.testing.expect(slot.writer.header_cache == &slot.worker_header_cache);
        try slot.writer.begin(200, "text/plain", 0);
        try std.testing.expect(std.mem.indexOf(u8, slot.arena[0..slot.writer.buffered], before) != null);
        try std.testing.expect(std.mem.indexOf(u8, slot.arena[0..slot.writer.buffered], after) == null);
        // The non-200 path reads the cached date separately from the 200 prefix.
        slot.writer.open(0, true, false);
        try slot.writer.begin(404, "text/plain", 0);
        try std.testing.expect(std.mem.indexOf(u8, slot.arena[0..slot.writer.buffered], before) != null);
    }

    test "callback clock becomes due on exactly every sixteenth callback" {
        var budget = clock_refresh_callbacks;
        var refreshes: usize = 0;
        for (1..2 * clock_refresh_callbacks + 1) |completed| {
            const due = callbackClockDue(&budget);
            try std.testing.expectEqual(completed % clock_refresh_callbacks == 0, due);
            if (due) {
                refreshes += 1;
                budget = clock_refresh_callbacks;
            }
        }
        try std.testing.expectEqual(@as(usize, 2), refreshes);
    }

    test "prearmed body completion waits for interim send then parses buffered body" {
        const server = try Server.init(std.testing.allocator, .{ .connections = 1, .port = 0 }, struct {
            fn handler(_: *api.Context) api.Action {
                return .close;
            }
        }.handler, null);
        const slot = &server.slots[0];
        defer {
            // The test injects completion state without submitting kernel work.
            slot.in_use = false;
            slot.in_ready = false;
            slot.phase.store(.io, .release);
            server.ready_count = 0;
            server.deinit();
        }
        const head = "POST /echo HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\nContent-Length: 4\r\n\r\n";
        const body = "body";
        @memcpy(slot.input[0 .. head.len + body.len], head ++ body);
        slot.received = head.len;
        try std.testing.expect(!try slot.parser.parseInto(slot.input[0..slot.received], &slot.request));
        try std.testing.expect(slot.parser.head_complete and slot.parser.expect_continue);
        slot.in_use = true;
        slot.generation = 1;
        slot.interim_sent = true;
        slot.send_mode = .interim;
        slot.send_pending = true;
        slot.recv_pending = true;
        slot.recv_token = tokenFor(slot, 0, .recv);
        server.stats.live_operations = 2;
        // Force the formerly failing completion order: body first, interim last.
        try server.onCompletion(.{ .token = slot.recv_token, .result = body.len });
        try std.testing.expect(slot.send_pending and !slot.request_active);
        try std.testing.expectEqual(Phase.io, slot.phase.load(.acquire));
        try std.testing.expectEqual(head.len + body.len, slot.received);
        slot.send_pending = false;
        server.stats.live_operations -= 1;
        slot.part_count = 1;
        slot.part = 1;
        try server.sendNext(0);
        try std.testing.expect(slot.request_active and !slot.recv_pending);
        try std.testing.expectEqual(Phase.ready, slot.phase.load(.acquire));
        try std.testing.expectEqualStrings(body, slot.request.body_wire);
        try std.testing.expectEqual(@as(usize, 0), server.stats.live_operations);
    }

    test "prearmed EOF retains pending output and closes only after its drain" {
        const server = try Server.init(std.testing.allocator, .{ .connections = 1, .port = 0 }, struct {
            fn handler(_: *api.Context) api.Action {
                return .close;
            }
        }.handler, null);
        defer server.deinit();
        const slot = &server.slots[0];
        // Synthetic terminal-order witness: no kernel operation is submitted.
        slot.in_use = true;
        slot.generation = 1;
        slot.recv_pending = true;
        slot.recv_token = tokenFor(slot, 0, .recv);
        slot.send_pending = true;
        slot.batch_count = 1;
        server.free_count = 0;
        server.stats.live_connections = 1;
        server.stats.live_operations = 2;
        try server.onCompletion(.{ .token = slot.recv_token, .result = 0 });
        try std.testing.expect(slot.recv_eof and !slot.recv_pending);
        try std.testing.expect(slot.send_pending and !slot.closing);
        try std.testing.expectEqual(@as(usize, 1), slot.batch_count);
        try std.testing.expectEqual(@as(usize, 1), server.stats.live_connections);
        // Once output is drained, an empty EOF input closes instead of rearming.
        slot.send_pending = false;
        server.stats.live_operations -= 1;
        slot.batch_count = 0;
        try server.receiveMore(0);
        try std.testing.expect(!slot.in_use and !slot.recv_pending);
        try std.testing.expectEqual(@as(usize, 0), server.stats.live_connections);
        try std.testing.expectEqual(@as(usize, 0), server.stats.live_operations);
        try std.testing.expectEqual(@as(usize, 1), server.free_count);
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
        self.header_cache.refresh(&self.date);
    }
};

/// Process-wide connection ceiling shared by every shard. Touched once per
/// accept and once per release; a shard that finds the ceiling reached closes
/// the accepted descriptor exactly as a full single owner does.
pub const Admission = struct {
    limit: u32,
    live: std.atomic.Value(u32) = .init(0),
    peak: std.atomic.Value(u32) = .init(0),

    /// Reserve one connection; false when the ceiling is already reached.
    pub fn admit(self: *Admission) bool {
        const before = self.live.fetchAdd(1, .acq_rel);
        if (before >= self.limit) {
            _ = self.live.fetchSub(1, .acq_rel);
            return false;
        }
        const now_live = before + 1;
        var peak = self.peak.load(.monotonic);
        while (peak < now_live) {
            peak = self.peak.cmpxchgWeak(peak, now_live, .monotonic, .monotonic) orelse break;
        }
        return true;
    }

    pub fn release(self: *Admission) void {
        const before = self.live.fetchSub(1, .acq_rel);
        assert(before > 0);
    }
};

/// Several independent I/O owners on one port. Each shard is a complete
/// Server with its own listener (SO_REUSEPORT), transport, slots, arenas and
/// counters; they share admission, stop coordination and the application
/// pointer. Shard 0 runs on the calling thread, the others on startup-spawned
/// threads with fixed stacks. Linux
/// distributes connections across the listeners; macOS keeps one shard.
pub const Cluster = struct {
    allocator: std.mem.Allocator,
    config: Config,
    shards: []*Server,
    threads: []?std.Thread,
    failures: []?anyerror,
    admission: Admission,
    port_number: u16,
    start_attempted: bool = false,
    started: bool = false,
    gate: std.atomic.Value(Gate) = .init(.waiting),
    prepared: std.atomic.Value(u32) = .init(0),
    exited: std.atomic.Value(u32) = .init(0),

    const Gate = enum(u8) { waiting, run, abort };
    const NativeLifecycle = struct {
        fn beforeSpawn(_: *Cluster, _: usize) !void {}
        fn runShard(cluster: *Cluster, index: usize) !void {
            try cluster.shards[index].run();
        }
    };

    pub const max_auto_shards: u8 = 16;

    /// 0 selects one shard per CPU the process may run on (Linux, at most
    /// max_auto_shards because every shard reserves full slot storage), else 1.
    pub fn resolveShards(config: Config) u8 {
        if (config.shards != 0) return config.shards;
        // Worker execution keeps one owner; only an explicit request is an error.
        if (config.execution != .inline_event_loop) return 1;
        if (@import("builtin").os.tag == .linux) {
            var set: std.os.linux.cpu_set_t = undefined;
            if (std.os.linux.sched_getaffinity(0, @sizeOf(std.os.linux.cpu_set_t), &set) == 0) {
                const count = std.os.linux.CPU_COUNT(set);
                return @intCast(@min(@max(count, 1), max_auto_shards));
            }
        }
        return 1;
    }

    /// Every shard keeps the full slot capacity: the kernel's hash may place
    /// more than an even share on one listener, and refusing those would make
    /// the process-wide limit depend on luck. The cluster enforces the limit
    /// with one shared counter instead.
    pub fn shardConfig(config: Config, shards: u8, index: u8, port_number: u16) Config {
        assert(shards > 0 and index < shards);
        var shard = config;
        shard.shards = shards;
        shard.port = port_number;
        shard.reuse_port = shards > 1;
        // Stacks for the other shards are reserved by the cluster, not per shard.
        shard.memory_budget_bytes = std.math.maxInt(usize);
        return shard;
    }

    pub fn validate(config: Config) !void {
        try config.validate();
        const shards = resolveShards(config);
        if (shards == 0 or shards > 64) return error.InvalidConfiguration;
        if (shards > 1 and config.execution != .inline_event_loop) return error.InvalidConfiguration;
        // XNU delivers every connection to the most recently bound reuse-port
        // listener (observed 2026-09-05), so extra macOS shards only shrink
        // admission. Distribution needs an acceptor mailbox there; not built.
        if (shards > 1 and @import("builtin").os.tag != .linux) return error.InvalidConfiguration;
        if (try std.math.add(usize, try heapBytes(config), try stackBytes(config)) > config.memory_budget_bytes)
            return error.MemoryBudgetExceeded;
    }

    /// Exact requested framework heap, including coordinator arrays. Pthread
    /// bookkeeping and kernel mappings are excluded; stacks are separate.
    pub fn heapBytes(config: Config) !usize {
        const shards = resolveShards(config);
        var heap: usize = @sizeOf(Cluster);
        const coordinator_per_shard = @sizeOf(*Server) + @sizeOf(?std.Thread) + @sizeOf(?anyerror);
        heap = try std.math.add(usize, heap, try std.math.mul(usize, shards, coordinator_per_shard));
        for (0..shards) |index| heap = try std.math.add(usize, heap, try shardConfig(config, shards, @intCast(index), config.port).heapBytes());
        return heap;
    }

    /// Requested startup stacks: application workers plus secondary owners.
    /// Shard 0 runs on the caller's existing stack.
    pub fn stackBytes(config: Config) !usize {
        const count = try std.math.add(usize, config.workers, resolveShards(config) - 1);
        return std.math.mul(usize, config.worker_stack_bytes, count);
    }

    pub fn init(allocator: std.mem.Allocator, config: Config, handler: api.Handler, application: ?*anyopaque) !*Cluster {
        try validate(config);
        const shards = resolveShards(config);
        const self = try allocator.create(Cluster);
        errdefer allocator.destroy(self);
        const servers = try allocator.alloc(*Server, shards);
        errdefer allocator.free(servers);
        const threads = try allocator.alloc(?std.Thread, shards);
        errdefer allocator.free(threads);
        const failures = try allocator.alloc(?anyerror, shards);
        errdefer allocator.free(failures);
        @memset(threads, null);
        @memset(failures, null);
        var created: usize = 0;
        errdefer for (servers[0..created]) |server| server.deinit();
        var port_number = config.port;
        for (servers, 0..) |*server, index| {
            server.* = try Server.init(allocator, shardConfig(config, shards, @intCast(index), port_number), handler, application);
            created += 1;
            // A port chosen by the OS for the first shard binds every other one.
            if (index == 0) port_number = server.*.backend.port();
        }
        self.* = .{ .allocator = allocator, .config = config, .shards = servers, .threads = threads, .failures = failures, .admission = .{ .limit = config.connections }, .port_number = port_number };
        // Standalone servers admit by their own slots; shards share one ceiling.
        if (shards > 1) for (servers) |server| {
            server.admission = &self.admission;
        };
        return self;
    }

    pub fn port(self: *const Cluster) u16 {
        return self.port_number;
    }

    fn shardMain(self: *Cluster, index: usize, comptime Lifecycle: type) void {
        // Entry and exit acknowledgements are published even when startup
        // aborts. No request operation or callback precedes the release gate.
        defer _ = self.exited.fetchAdd(1, .release);
        if (self.config.shard_affinity) pinToAllowedCpu(index);
        _ = self.prepared.fetchAdd(1, .release);
        while (true) switch (self.gate.load(.acquire)) {
            .waiting => std.Thread.yield() catch {},
            .abort => return,
            .run => break,
        };
        Lifecycle.runShard(self, index) catch |err| {
            self.failures[index] = err;
        };
        // A secondary owner's error or ordinary stop must reach shard 0 even
        // when duration_ms is zero. Error ownership remains retained.
        self.requestStop();
    }

    /// Pin the calling thread to the index-th CPU of the process's allowed set
    /// (Linux). Other platforms leave placement to the scheduler.
    fn pinToAllowedCpu(index: usize) void {
        if (@import("builtin").os.tag != .linux) return;
        const linux = std.os.linux;
        var allowed: linux.cpu_set_t = undefined;
        if (linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &allowed) != 0) return;
        var seen: usize = 0;
        for (allowed, 0..) |word, word_index| {
            var bits = word;
            while (bits != 0) : (bits &= bits - 1) {
                if (seen == index) {
                    const cpu = word_index * @bitSizeOf(usize) + @ctz(bits);
                    var only: linux.cpu_set_t = @splat(0);
                    only[cpu / @bitSizeOf(usize)] = @as(usize, 1) << @intCast(cpu % @bitSizeOf(usize));
                    linux.sched_setaffinity(0, &only) catch {};
                    return;
                }
                seen += 1;
            }
        }
    }

    pub fn start(self: *Cluster) !void {
        return self.startWith(NativeLifecycle);
    }

    /// The comptime lifecycle seam supports deterministic startup/run faults
    /// in tests without runtime hooks on the production request path.
    fn startWith(self: *Cluster, comptime Lifecycle: type) !void {
        assert(!self.start_attempted);
        self.start_attempted = true;
        var started: usize = 0;
        var spawned: usize = 0;
        errdefer self.abortStartup(started, spawned);
        for (self.shards) |server| {
            try server.start();
            started += 1;
        }
        const Entry = struct {
            fn main(cluster: *Cluster, index: usize) void {
                cluster.shardMain(index, Lifecycle);
            }
        };
        for (self.threads[1..], 1..) |*thread, index| {
            try Lifecycle.beforeSpawn(self, index);
            thread.* = try std.Thread.spawn(.{ .stack_size = self.config.worker_stack_bytes, .allocator = self.allocator }, Entry.main, .{ self, index });
            spawned += 1;
        }
        const deadline = self.shutdownDeadline();
        while (self.prepared.load(.acquire) != spawned) {
            if (nowNs() >= deadline) std.c._exit(70);
            std.Thread.yield() catch {};
        }
        self.started = true;
        // The calling application can now seal its allocator and announce
        // readiness. Only run() releases the prepared request-I/O owners.
    }

    fn shutdownDeadline(self: *const Cluster) u64 {
        return nowNs() + @as(u64, self.config.shutdown_ms) * 1_000_000;
    }

    fn joinExited(self: *Cluster, count: usize, deadline: u64) void {
        // Never join a shard still inside an application callback or waiting
        // for startup release. Its deadline cannot preempt arbitrary code.
        while (self.exited.load(.acquire) != count) {
            if (nowNs() >= deadline) std.c._exit(70);
            std.Thread.yield() catch {};
        }
        for (self.threads[1 .. 1 + count]) |*thread| {
            thread.*.?.join();
            thread.* = null;
        }
    }

    fn abortStartup(self: *Cluster, started: usize, spawned: usize) void {
        assert(!self.started and started <= self.shards.len);
        self.gate.store(.abort, .release);
        self.joinExited(spawned, self.shutdownDeadline());
        for (self.shards[0..started]) |server| {
            // The gate proves no request I/O ran. A stopped run starts no
            // accepts and safely joins any startup workers before destruction.
            assert(server.stats.live_connections == 0 and server.stats.live_operations == 0);
            server.requestStop();
            server.run() catch std.c._exit(70);
            assert(server.safe_to_destroy);
        }
    }

    pub fn requestStop(self: *Cluster) void {
        for (self.shards) |server| server.requestStop();
    }

    /// Runs shard 0 here until it stops, then stops and joins every other
    /// shard. Any shard's failure is the cluster's failure; the caller must
    /// then terminate the process because loans may remain outstanding.
    pub fn run(self: *Cluster) !void {
        return self.runWith(NativeLifecycle);
    }

    fn runWith(self: *Cluster, comptime Lifecycle: type) !void {
        assert(self.started and self.gate.load(.acquire) == .waiting);
        if (self.config.shard_affinity) pinToAllowedCpu(0);
        self.gate.store(.run, .release);
        const first = Lifecycle.runShard(self, 0);
        self.requestStop();
        self.joinExited(self.shards.len - 1, self.shutdownDeadline());
        try first;
        for (self.failures) |failure| if (failure) |err| return err;
    }

    pub fn stats(self: *const Cluster) Stats {
        var total = self.shards[0].stats;
        total.shards = @intCast(self.shards.len);
        for (self.shards[1..]) |server| total.merge(server.stats);
        if (self.shards.len > 1) {
            // The shared ceiling is the process-wide observation, not a sum.
            total.live_connections = self.admission.live.load(.acquire);
            total.peak_connections = self.admission.peak.load(.acquire);
        }
        return total;
    }

    pub fn deinit(self: *Cluster) void {
        for (self.threads) |thread| assert(thread == null);
        for (self.shards) |server| server.deinit();
        const allocator = self.allocator;
        allocator.free(self.failures);
        allocator.free(self.threads);
        allocator.free(self.shards);
        allocator.destroy(self);
    }
};

const SendSelection = struct { count: usize = 0, bytes: usize = 0 };

/// Select one bounded write across framing and payload without coalescing
/// bytes, writing the chosen vectors into caller-provided stable storage.
fn selectSendParts(parts: []const c.iovec_const, part: usize, offset: usize, cap: usize, out: []c.iovec_const) SendSelection {
    assert(parts.len > 0 and parts.len <= out.len and part < parts.len);
    assert(offset <= parts[part].len and cap > 0 and cap <= std.math.maxInt(i32));
    var selected: SendSelection = .{};
    for (parts[part..], 0..) |span, index| {
        const skip = if (index == 0) offset else 0;
        const available = span.len - skip;
        if (available == 0) continue;
        const count = @min(available, cap - selected.bytes);
        if (count == 0) break;
        out[selected.count] = .{ .base = span.base + skip, .len = count };
        selected.count += 1;
        selected.bytes += count;
        if (selected.bytes == cap) break;
    }
    assert(selected.bytes > 0 and selected.bytes <= cap);
    return selected;
}

/// One positive completion acknowledges a prefix of the submitted aggregate,
/// which may stop before, exactly at, or after a framing/payload boundary.
fn advanceSendParts(parts: []const c.iovec_const, part: *usize, offset: *usize, amount: usize) void {
    assert(parts.len > 0 and part.* < parts.len);
    assert(offset.* <= parts[part.*].len and amount > 0);
    var remaining = amount;
    for (0..parts.len) |_| {
        assert(part.* < parts.len and offset.* <= parts[part.*].len);
        const available = parts[part.*].len - offset.*;
        if (remaining < available) {
            offset.* += remaining;
            return;
        }
        remaining -= available;
        part.* += 1;
        offset.* = 0;
        if (remaining == 0) return;
    }
    unreachable; // Caller proved completion bytes <= the submitted selection.
}

pub fn nowNs() u64 {
    var time: c.timespec = undefined;
    assert(c.clock_gettime(.MONOTONIC, &time) == 0);
    return @as(u64, @intCast(time.sec)) * 1_000_000_000 + @as(u64, @intCast(time.nsec));
}

fn vectorsOf(comptime strings: anytype) [strings.len]c.iovec_const {
    var out: [strings.len]c.iovec_const = undefined;
    inline for (strings, 0..) |text, index| out[index] = transport.vector(text);
    return out;
}

fn vectorString(vec: c.iovec_const) []const u8 {
    return vec.base[0..vec.len];
}

test "configuration rejects combined resource overcommit and impossible worker limits" {
    try (Config{}).validate();
    try std.testing.expectError(error.InvalidConfiguration, (Config{ .execution = .workers, .workers = 0 }).validate());
    try std.testing.expectError(error.InvalidConfiguration, (Config{ .connections = 1, .workers = 2 }).validate());
    try std.testing.expectError(error.MemoryBudgetExceeded, (Config{ .connections = 4096, .max_body = 1024 * 1024 }).validate());
    try std.testing.expectError(error.InvalidConfiguration, (Config{ .output_bytes = 512 }).validate());
    try std.testing.expectError(error.InvalidConfiguration, (Config{ .response_batch_limit = 512 }).validate());
    try std.testing.expectEqual(@as(usize, 16 * 16), (Config{ .connections = 16, .response_batch_limit = 16 }).effectiveCallbacksPerTurn());
    try std.testing.expectEqual(Config.max_callbacks_per_turn_auto, (Config{ .connections = 4096 }).effectiveCallbacksPerTurn());
}

test "inline execution explicitly requires no application worker resources" {
    try (Config{ .execution = .inline_event_loop, .workers = 0 }).validate();
    try std.testing.expectError(error.InvalidConfiguration, (Config{ .execution = .inline_event_loop, .workers = 2 }).validate());
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

test "gather selection bounds aggregate bytes and borrows original spans" {
    const parts = vectorsOf(.{ "abc", "", "defg", "hi" });
    var out: [4]c.iovec_const = undefined;
    const selected = selectSendParts(&parts, 0, 1, 5, &out);
    try std.testing.expectEqual(@as(usize, 2), selected.count);
    try std.testing.expectEqual(@as(usize, 5), selected.bytes);
    try std.testing.expectEqualStrings("bc", vectorString(out[0]));
    try std.testing.expectEqualStrings("def", vectorString(out[1]));
    try std.testing.expectEqual(parts[0].base + 1, out[0].base);
    try std.testing.expectEqual(parts[2].base, out[1].base);
    const complete = selectSendParts(&parts, 0, 0, 64, &out);
    try std.testing.expectEqual(@as(usize, 3), complete.count);
    try std.testing.expectEqual(@as(usize, 9), complete.bytes);
    const at_end = selectSendParts(&parts, 2, 4, 1, &out);
    try std.testing.expectEqualStrings("h", vectorString(out[0]));
    _ = at_end;
}

test "positive gather completions advance before at and after part boundaries" {
    const parts = vectorsOf(.{ "abc", "defg", "hi" });
    const Case = struct { bytes: usize, part: usize, offset: usize };
    const cases = [_]Case{
        .{ .bytes = 1, .part = 0, .offset = 1 },
        .{ .bytes = 3, .part = 1, .offset = 0 },
        .{ .bytes = 4, .part = 1, .offset = 1 },
        .{ .bytes = 7, .part = 2, .offset = 0 },
        .{ .bytes = 8, .part = 2, .offset = 1 },
        .{ .bytes = 9, .part = 3, .offset = 0 },
    };
    for (cases) |case| {
        var part: usize = 0;
        var offset: usize = 0;
        advanceSendParts(&parts, &part, &offset, case.bytes);
        try std.testing.expectEqual(case.part, part);
        try std.testing.expectEqual(case.offset, offset);
    }
    var part: usize = 0;
    var offset: usize = 0;
    var out: [3]c.iovec_const = undefined;
    advanceSendParts(&parts, &part, &offset, 4);
    _ = selectSendParts(&parts, part, offset, 5, &out);
    try std.testing.expectEqualStrings("efg", vectorString(out[0]));
    try std.testing.expectEqualStrings("hi", vectorString(out[1]));
    advanceSendParts(&parts, &part, &offset, 2);
    advanceSendParts(&parts, &part, &offset, 3);
    try std.testing.expectEqual(parts.len, part);
    try std.testing.expectEqual(@as(usize, 0), offset);
}

test "arena, cell and vector storage is budgeted exactly and laid out per slot" {
    try std.testing.expectError(error.InvalidConfiguration, (Config{ .response_batch_limit = 0 }).validate());
    for ([_]bool{ false, true }) |gather| {
        for ([_]u16{ 1, 16, 128 }) |limit| {
            var config: Config = .{ .connections = 2, .port = 0, .gather_send = gather, .response_batch_limit = limit };
            const heap = try config.heapBytes();
            config.memory_budget_bytes = heap;
            try config.validate();
            var budget: Budget = .{ .upstream = std.testing.allocator, .limit_bytes = heap };
            const server = try Server.init(budget.allocator(), config, struct {
                fn handle(_: *api.Context) api.Action {
                    unreachable;
                }
            }.handle, null);
            try std.testing.expectEqual(heap, budget.live_bytes);
            try std.testing.expectEqual(@as(usize, 2) * limit, server.response_cells.len);
            for (server.slots, 0..) |slot, index| {
                try std.testing.expectEqual(@as(usize, limit), slot.cells.len);
                try std.testing.expectEqual(config.output_bytes, slot.arena.len);
                try std.testing.expectEqual(2 * @as(usize, limit) + 1, slot.parts.len);
                try std.testing.expectEqual(slot.parts.len, slot.selection.len);
                if (index > 0) try std.testing.expect(@intFromPtr(server.slots[index - 1].arena.ptr) + config.output_bytes <= @intFromPtr(slot.arena.ptr));
            }
            try std.testing.expectEqual(@as(usize, 2), server.free_count);
            server.deinit();
            try std.testing.expectEqual(@as(usize, 0), budget.live_bytes);
            config.memory_budget_bytes = heap - 1;
            try std.testing.expectError(error.MemoryBudgetExceeded, config.validate());
        }
    }
    const workers: Config = .{ .execution = .workers, .workers = 2, .response_batch_limit = 16 };
    try std.testing.expectEqual(@as(usize, 1), workers.effectiveBatchLimit());
    var single = workers;
    single.response_batch_limit = 1;
    try std.testing.expectEqual(try single.heapBytes(), try workers.heapBytes());
}

test "batch gather progress crosses part boundaries without copying" {
    var parts: [257]c.iovec_const = undefined;
    for (&parts, 0..) |*part, index| part.* = transport.vector(if (index % 2 == 0) "header" else "payload");
    var out: [257]c.iovec_const = undefined;
    const selected = selectSendParts(&parts, 0, 0, 65536, &out);
    try std.testing.expectEqual(parts.len, selected.count);
    try std.testing.expectEqual(@as(usize, 129 * 6 + 128 * 7), selected.bytes);
    var part: usize = 0;
    var offset: usize = 0;
    advanceSendParts(&parts, &part, &offset, 13 * 17 + 2);
    try std.testing.expectEqual(@as(usize, 34), part);
    try std.testing.expectEqual(@as(usize, 2), offset);
    _ = selectSendParts(&parts, part, offset, 9, &out);
    try std.testing.expectEqualStrings("ader", vectorString(out[0]));
    try std.testing.expectEqualStrings("paylo", vectorString(out[1]));
    try std.testing.expectEqual(parts[34].base + 2, out[0].base);
}

test "cluster reserves full shard capacity and rejects unsupported topologies" {
    const config: Config = .{ .connections = 128, .shards = 3 };
    const first = Cluster.shardConfig(config, 3, 0, 9000);
    const last = Cluster.shardConfig(config, 3, 2, 9000);
    // Every shard keeps full capacity; the shared Admission enforces the total.
    try std.testing.expectEqual(@as(u16, 128), first.connections);
    try std.testing.expectEqual(@as(u16, 128), last.connections);
    try std.testing.expect(first.reuse_port and last.reuse_port);
    try std.testing.expectEqual(@as(u16, 9000), last.port);
    try std.testing.expect(!Cluster.shardConfig(config, 1, 0, 1).reuse_port);
    var admission: Admission = .{ .limit = 2 };
    try std.testing.expect(admission.admit() and admission.admit() and !admission.admit());
    admission.release();
    try std.testing.expect(admission.admit());
    try std.testing.expectEqual(@as(u32, 2), admission.peak.load(.acquire));
    try std.testing.expectError(error.InvalidConfiguration, Cluster.validate(.{ .shards = 65 }));
    try std.testing.expectError(error.InvalidConfiguration, Cluster.validate(.{ .execution = .workers, .workers = 2, .shards = 2 }));
    if (@import("builtin").os.tag != .linux) {
        try std.testing.expectEqual(@as(u8, 1), Cluster.resolveShards(.{}));
        try std.testing.expectError(error.InvalidConfiguration, Cluster.validate(.{ .shards = 2 }));
    } else {
        try std.testing.expect(Cluster.resolveShards(.{}) >= 1);
        try Cluster.validate(.{ .shards = 2 });
    }
    const single = try Cluster.init(std.testing.allocator, .{ .connections = 2, .port = 0, .shards = 1 }, struct {
        fn handle(_: *api.Context) api.Action {
            unreachable;
        }
    }.handle, null);
    defer single.deinit();
    try std.testing.expectEqual(@as(usize, 1), single.shards.len);
    try single.start();
    single.requestStop();
    try single.run();
    try std.testing.expectEqual(@as(u16, 1), single.stats().shards);
}

/// A regression in stop propagation must fail finitely even when the fixture
/// deliberately leaves duration_ms at zero. This is outside server resources.
const ClusterTestWatchdog = struct {
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *ClusterTestWatchdog) void {
        const deadline = nowNs() + 5_000_000_000;
        while (!self.done.load(.acquire)) {
            if (nowNs() >= deadline) std.c._exit(71);
            const delay: c.timespec = .{ .sec = 0, .nsec = 1_000_000 };
            _ = c.nanosleep(&delay, null);
        }
    }
};

test "cluster exact heap and stack budget includes coordinator and shard arrays" {
    const configs = [_]Config{
        .{ .connections = 2, .port = 0, .shards = 1, .response_batch_limit = 2 },
        .{ .connections = 2, .port = 0, .shards = 1, .execution = .workers, .workers = 1 },
        .{ .connections = 2, .port = 0, .shards = 3, .response_batch_limit = 2 },
    };
    for (configs) |initial| {
        if (initial.shards > 1 and @import("builtin").os.tag != .linux) continue;
        var config = initial;
        const heap = try Cluster.heapBytes(config);
        const stacks = try Cluster.stackBytes(config);
        try std.testing.expectEqual(config.worker_stack_bytes * (config.workers + config.shards - 1), stacks);
        config.memory_budget_bytes = try std.math.add(usize, heap, stacks);
        try Cluster.validate(config);
        var budget: Budget = .{ .upstream = std.testing.allocator, .limit_bytes = heap };
        const cluster = try Cluster.init(budget.allocator(), config, struct {
            fn handle(_: *api.Context) api.Action {
                unreachable;
            }
        }.handle, null);
        try std.testing.expectEqual(heap, budget.live_bytes);
        try std.testing.expectEqual(config.shards, cluster.shards.len);
        // No request I/O is released by start(), including on secondary owners.
        try cluster.start();
        try std.testing.expectEqual(heap, budget.live_bytes);
        for (cluster.shards) |server| {
            try std.testing.expectEqual(@as(usize, 0), server.stats.live_operations);
            try std.testing.expectEqual(@as(u64, 0), server.stats.turns);
        }
        budget.sealed.store(true, .release);
        cluster.requestStop();
        try cluster.run();
        cluster.deinit();
        try std.testing.expectEqual(@as(usize, 0), budget.live_bytes);
        try std.testing.expectEqual(@as(usize, 0), budget.late_calls.load(.acquire));
        config.memory_budget_bytes -= 1;
        try std.testing.expectError(error.MemoryBudgetExceeded, Cluster.validate(config));
    }
}

test "cluster partial spawn failure aborts prepared owners before request I/O" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const Lifecycle = struct {
        fn beforeSpawn(cluster: *Cluster, index: usize) !void {
            if (index != 2) return;
            // Ensure the first spawned thread has entered the barrier before
            // failing the next spawn. No timing-dependent sleeps or requests.
            const deadline = cluster.shutdownDeadline();
            while (cluster.prepared.load(.acquire) != 1) {
                if (nowNs() >= deadline) std.c._exit(71);
                std.Thread.yield() catch {};
            }
            return error.InjectedSpawnFailure;
        }
        fn runShard(_: *Cluster, _: usize) !void {
            @panic("aborted startup must not release a request owner");
        }
    };
    var watchdog: ClusterTestWatchdog = .{};
    const watcher = try std.Thread.spawn(.{}, ClusterTestWatchdog.run, .{&watchdog});
    defer {
        watchdog.done.store(true, .release);
        watcher.join();
    }
    const cluster = try Cluster.init(std.testing.allocator, .{
        .connections = 2,
        .port = 0,
        .shards = 3,
        .response_batch_limit = 2,
        .shutdown_ms = 1000,
    }, struct {
        fn handle(_: *api.Context) api.Action {
            @panic("aborted startup must not dispatch a callback");
        }
    }.handle, null);
    defer cluster.deinit();
    try std.testing.expectError(error.InjectedSpawnFailure, cluster.startWith(Lifecycle));
    try std.testing.expectEqual(@as(u32, 1), cluster.prepared.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), cluster.exited.load(.acquire));
    for (cluster.threads) |thread| try std.testing.expect(thread == null);
    for (cluster.shards) |server| {
        try std.testing.expect(server.safe_to_destroy);
        try std.testing.expectEqual(@as(u64, 0), server.stats.turns);
        try std.testing.expectEqual(@as(usize, 0), server.stats.live_connections);
        try std.testing.expectEqual(@as(usize, 0), server.stats.live_operations);
    }
}

test "secondary shard error stops the primary without a duration escape" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const Lifecycle = struct {
        var primary_entered: std.atomic.Value(bool) = .init(false);
        fn beforeSpawn(_: *Cluster, _: usize) !void {}
        fn runShard(cluster: *Cluster, index: usize) !void {
            if (index == 0) {
                primary_entered.store(true, .release);
                return cluster.shards[0].run();
            }
            const deadline = cluster.shutdownDeadline();
            while (!primary_entered.load(.acquire)) {
                if (nowNs() >= deadline) std.c._exit(71);
                std.Thread.yield() catch {};
            }
            // Reconcile this fixture's owners before injecting the error, so
            // the test can destroy its cluster. Real failed runs retain loans.
            cluster.shards[index].requestStop();
            try cluster.shards[index].run();
            return error.InjectedShardFailure;
        }
    };
    Lifecycle.primary_entered.store(false, .release);
    var watchdog: ClusterTestWatchdog = .{};
    const watcher = try std.Thread.spawn(.{}, ClusterTestWatchdog.run, .{&watchdog});
    defer {
        watchdog.done.store(true, .release);
        watcher.join();
    }
    const cluster = try Cluster.init(std.testing.allocator, .{
        .connections = 2,
        .port = 0,
        .shards = 2,
        .response_batch_limit = 2,
        .shutdown_ms = 1000,
    }, struct {
        fn handle(_: *api.Context) api.Action {
            unreachable;
        }
    }.handle, null);
    defer cluster.deinit();
    try std.testing.expectEqual(@as(u32, 0), cluster.config.duration_ms);
    try cluster.startWith(Lifecycle);
    try std.testing.expectError(error.InjectedShardFailure, cluster.runWith(Lifecycle));
    try std.testing.expect(cluster.shards[0].stop_requested.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), cluster.exited.load(.acquire));
    for (cluster.threads) |thread| try std.testing.expect(thread == null);
    for (cluster.shards) |server| {
        try std.testing.expect(server.safe_to_destroy);
        try std.testing.expectEqual(@as(usize, 0), server.stats.live_connections);
        try std.testing.expectEqual(@as(usize, 0), server.stats.live_operations);
    }
}

test "stats merge sums counters, keeps maxima and leaves configuration alone" {
    var total: Stats = .{ .completed = 1, .max_batch_responses = 3, .response_batch_limit = 16, .shards = 2 };
    total.merge(.{ .completed = 2, .max_batch_responses = 5, .response_batch_limit = 99, .shards = 7 });
    try std.testing.expectEqual(@as(u64, 3), total.completed);
    try std.testing.expectEqual(@as(usize, 5), total.max_batch_responses);
    try std.testing.expectEqual(@as(usize, 16), total.response_batch_limit);
    try std.testing.expectEqual(@as(u16, 2), total.shards);
}
