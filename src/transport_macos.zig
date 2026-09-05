//! macOS readiness adapter. Nonblocking socket calls make each returned result
//! a terminal completion; kqueue readiness itself never releases a buffer.
//! Operations live in caller-addressed cells; finished cells queue on a ring so
//! collection never scans the table.
const std = @import("std");
const c = std.c;
const common = @import("transport.zig");
const Socket = common.Socket;
const Completion = common.Completion;
const assert = std.debug.assert;

pub const Backend = struct {
    const Kind = enum { free, accept, recv, send, sendv, cancel };
    const Operation = struct {
        kind: Kind = .free,
        token: u64 = 0,
        socket: Socket = -1,
        read_buffer: []u8 = &.{},
        write_buffer: []const u8 = &.{},
        /// Caller-owned vectors, stable until the terminal completion.
        vectors: []const c.iovec_const = &.{},
        message: c.msghdr_const = undefined,
        result: ?i32 = null,
        registered: bool = false,
        queued: bool = false,
    };

    pub const operation_bytes = @sizeOf(Operation) + @sizeOf(u32);

    allocator: std.mem.Allocator,
    operations: []Operation,
    /// Cells with a result, in completion order. Capacity equals the cell count.
    ready: []u32,
    ready_head: usize = 0,
    ready_count: usize = 0,
    gather_enabled: bool = false,
    outstanding: usize = 0,
    listener: Socket,
    queue_fd: Socket,
    bound_port: u16,

    pub fn init(allocator: std.mem.Allocator, max_connections: u16, port_number: u16, reuse_port: bool) !Backend {
        if (max_connections == 0 or max_connections > 16383) return error.InvalidConnectionLimit;
        const capacity = common.cellCount(max_connections);
        const operations = try allocator.alloc(Operation, capacity);
        errdefer allocator.free(operations);
        @memset(operations, .{});
        const ready = try allocator.alloc(u32, capacity);
        errdefer allocator.free(ready);
        const listener = try common.listen(port_number, max_connections, true, reuse_port);
        errdefer common.closeFd(listener.socket);
        const queue = c.kqueue();
        if (queue < 0) return error.KqueueFailed;
        errdefer common.closeFd(queue);
        try common.setFlags(queue, false);
        const wake_event: c.Kevent = .{ .ident = 1, .filter = c.EVFILT.USER, .flags = c.EV.ADD | c.EV.CLEAR, .fflags = 0, .data = 0, .udata = 0 };
        try change(queue, wake_event);
        return .{ .allocator = allocator, .operations = operations, .ready = ready, .listener = listener.socket, .queue_fd = queue, .bound_port = listener.port };
    }

    /// Startup-only capability flag; nonblocking sendmsg uses the socket ABI.
    pub fn enableGather(self: *Backend) !void {
        assert(self.outstanding == 0 and !self.gather_enabled);
        self.gather_enabled = true;
    }

    pub fn deinit(self: *Backend) void {
        assert(self.outstanding == 0 and self.ready_count == 0);
        for (self.operations) |op| assert(op.kind == .free);
        common.closeFd(self.listener);
        common.closeFd(self.queue_fd);
        self.allocator.free(self.ready);
        self.allocator.free(self.operations);
        self.* = undefined;
    }

    fn change(fd: Socket, event: c.Kevent) !void {
        const changes = [_]c.Kevent{event};
        const no_events: [0]c.Kevent = .{};
        const zero: c.timespec = .{ .sec = 0, .nsec = 0 };
        for (0..3) |_| {
            const result = c.kevent(fd, &changes, 1, @constCast(&no_events), 0, &zero);
            if (result == 0) return;
            if (c.errno(result) == .INTR) continue;
            // Retrying an interrupted delete can find its already removed watch.
            if (event.flags & c.EV.DELETE != 0 and c.errno(result) == .NOENT) return;
            return error.KqueueChangeFailed;
        }
        return error.KqueueInterrupted;
    }

    fn claim(self: *Backend, cell: u32) !*Operation {
        if (cell >= self.operations.len) return error.OperationCellInvalid;
        const op = &self.operations[cell];
        if (op.kind != .free) return error.OperationCellBusy;
        return op;
    }

    fn cellOf(self: *const Backend, op: *const Operation) u32 {
        const index = (@intFromPtr(op) - @intFromPtr(self.operations.ptr)) / @sizeOf(Operation);
        assert(index < self.operations.len);
        return @intCast(index);
    }

    fn isSend(kind: Kind) bool {
        return kind == .send or kind == .sendv;
    }

    fn finish(self: *Backend, op: *Operation, result: i32) void {
        assert(op.kind != .free and op.result == null and !op.queued);
        op.result = result;
        op.queued = true;
        assert(self.ready_count < self.ready.len);
        self.ready[(self.ready_head + self.ready_count) % self.ready.len] = self.cellOf(op);
        self.ready_count += 1;
    }

    fn arm(self: *Backend, op: *Operation) !void {
        assert(!op.registered and op.result == null);
        const event: c.Kevent = .{
            .ident = @intCast(op.socket),
            .filter = if (isSend(op.kind)) c.EVFILT.WRITE else c.EVFILT.READ,
            .flags = c.EV.ADD | c.EV.ONESHOT,
            .fflags = 0,
            .data = 0,
            .udata = self.cellOf(op) + 1,
        };
        change(self.queue_fd, event) catch |err| {
            // A signal may interrupt change after installation. Confirm removal
            // before this stable slot can be recycled; never leave stale udata.
            var removal = event;
            removal.flags = c.EV.DELETE;
            change(self.queue_fd, removal) catch @panic("unable to retire an ambiguous kqueue registration");
            return err;
        };
        op.registered = true;
    }

    fn attempt(self: *Backend, op: *Operation) !void {
        assert(op.kind != .free and op.kind != .cancel and !op.registered and op.result == null);
        const result: isize = switch (op.kind) {
            .accept => c.accept(self.listener, null, null),
            .recv => c.recv(op.socket, op.read_buffer.ptr, op.read_buffer.len, 0),
            .send => c.send(op.socket, op.write_buffer.ptr, op.write_buffer.len, 0),
            .sendv => c.sendmsg(op.socket, &op.message, 0),
            else => unreachable,
        };
        if (result >= 0) {
            var value: i32 = @intCast(result);
            if (op.kind == .accept) {
                common.configureAccepted(value, true) catch {
                    common.closeFd(value);
                    value = -@as(i32, @intFromEnum(c.E.IO));
                };
            }
            self.finish(op, value);
        } else switch (c.errno(result)) {
            .AGAIN, .INTR => try self.arm(op),
            else => |err| self.finish(op, -@as(i32, @intFromEnum(err))),
        }
    }

    fn begin(self: *Backend, op: *Operation, value: Operation) !void {
        op.* = value;
        self.attempt(op) catch |err| {
            op.* = .{};
            return err;
        };
        self.outstanding += 1;
    }

    pub fn accept(self: *Backend, cell: u32, token: u64) !void {
        const op = try self.claim(cell);
        try self.begin(op, .{ .kind = .accept, .token = token, .socket = self.listener });
    }

    pub fn recv(self: *Backend, cell: u32, token: u64, socket: Socket, buffer: []u8) !void {
        assert(buffer.len > 0 and buffer.len <= std.math.maxInt(i32));
        const op = try self.claim(cell);
        try self.begin(op, .{ .kind = .recv, .token = token, .socket = socket, .read_buffer = buffer });
    }

    pub fn send(self: *Backend, cell: u32, token: u64, socket: Socket, bytes: []const u8) !void {
        assert(bytes.len > 0 and bytes.len <= std.math.maxInt(i32));
        const op = try self.claim(cell);
        try self.begin(op, .{ .kind = .send, .token = token, .socket = socket, .write_buffer = bytes });
    }

    pub fn sendv(self: *Backend, cell: u32, token: u64, socket: Socket, vectors: []const c.iovec_const) !void {
        if (!self.gather_enabled) return error.GatherSendNotEnabled;
        assert(vectors.len > 0 and vectors.len <= common.max_vectors);
        const op = try self.claim(cell);
        try self.begin(op, .{ .kind = .sendv, .token = token, .socket = socket, .vectors = vectors, .message = .{
            .name = null,
            .namelen = 0,
            .iov = vectors.ptr,
            .iovlen = @intCast(vectors.len),
            .control = null,
            .controllen = 0,
            .flags = 0,
        } });
    }

    pub fn cancel(self: *Backend, cell: u32, token: u64, target_cell: u32) !void {
        assert(cell != target_cell and target_cell < self.operations.len);
        const cancellation = try self.claim(cell);
        var result: i32 = -@as(i32, @intFromEnum(c.E.NOENT));
        const target = &self.operations[target_cell];
        if (target.kind != .free and target.result == null) {
            assert(target.kind != .cancel and target.registered);
            try change(self.queue_fd, .{
                .ident = @intCast(target.socket),
                .filter = if (isSend(target.kind)) c.EVFILT.WRITE else c.EVFILT.READ,
                .flags = c.EV.DELETE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            });
            target.registered = false;
            self.finish(target, -@as(i32, @intFromEnum(c.E.CANCELED)));
            result = 0;
        }
        cancellation.* = .{ .kind = .cancel, .token = token };
        self.finish(cancellation, result);
        self.outstanding += 1;
    }

    fn collect(self: *Backend, out: []Completion) usize {
        var count: usize = 0;
        while (count < out.len and self.ready_count > 0) {
            const cell = self.ready[self.ready_head];
            self.ready_head = (self.ready_head + 1) % self.ready.len;
            self.ready_count -= 1;
            const op = &self.operations[cell];
            assert(op.kind != .free and op.queued and !op.registered and self.outstanding > 0);
            out[count] = .{ .token = op.token, .result = op.result.? };
            count += 1;
            op.* = .{};
            self.outstanding -= 1;
        }
        return count;
    }

    pub fn poll(self: *Backend, out: []Completion, timeout_ms: u32) !usize {
        assert(out.len > 0 and timeout_ms <= std.math.maxInt(c_int));
        const collected = self.collect(out);
        var events: [256]c.Kevent = undefined;
        const no_changes: [0]c.Kevent = .{};
        // Always service readiness, including when immediate I/O keeps producing
        // completions. Otherwise busy low-latency sockets can starve waiters.
        const wait_ms: u32 = if (collected > 0) 0 else timeout_ms;
        const timeout: c.timespec = .{ .sec = @intCast(wait_ms / 1000), .nsec = @intCast((wait_ms % 1000) * 1_000_000) };
        const result = c.kevent(self.queue_fd, &no_changes, 0, &events, events.len, &timeout);
        if (result < 0) {
            if (c.errno(result) == .INTR) return collected;
            // Already collected results have transferred ownership. Do not drop
            // them on an unrelated poll error; surface failure next poll.
            if (collected > 0) return collected;
            return error.KqueuePollFailed;
        }
        for (events[0..@intCast(result)]) |event| {
            if (event.filter == c.EVFILT.USER) continue;
            assert(event.udata > 0 and event.udata <= self.operations.len);
            const op = &self.operations[event.udata - 1];
            assert(op.kind != .free and op.result == null and op.registered);
            assert(event.ident == @as(usize, @intCast(op.socket)));
            op.registered = false; // EV_ONESHOT deleted this registration.
            if (event.flags & c.EV.ERROR != 0) {
                assert(event.data > 0 and event.data <= std.math.maxInt(i32));
                self.finish(op, -@as(i32, @intCast(event.data)));
            } else self.attempt(op) catch {
                // Once admitted, every operation must produce a terminal result.
                self.finish(op, -@as(i32, @intFromEnum(c.E.IO)));
            };
        }
        return collected + if (collected < out.len) self.collect(out[collected..]) else @as(usize, 0);
    }

    /// EVFILT_USER coalesces notifications. It owns no caller payload or token.
    /// Worker lifetime must end before the kqueue descriptor is closed.
    pub fn wake(self: *Backend) void {
        change(self.queue_fd, .{ .ident = 1, .filter = c.EVFILT.USER, .flags = 0, .fflags = c.NOTE.TRIGGER, .data = 0, .udata = 0 }) catch |err| switch (err) {
            error.KqueueInterrupted => {}, // Finite engine deadline poll is a fallback.
            else => unreachable,
        };
    }

    pub fn close(self: *Backend, cell: u32, socket: Socket) void {
        assert(cell < self.operations.len and self.operations[cell].kind == .free);
        common.closeFd(socket);
    }

    pub fn shutdown(_: *Backend, socket: Socket) void {
        _ = c.shutdown(socket, c.SHUT.RDWR);
    }

    pub fn port(self: *const Backend) u16 {
        return self.bound_port;
    }
};
