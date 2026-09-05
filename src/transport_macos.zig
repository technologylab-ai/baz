//! macOS readiness adapter. Nonblocking socket calls make each returned result
//! a terminal completion; kqueue readiness itself never releases a buffer.
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
        result: ?i32 = null,
        registered: bool = false,
    };

    pub const operation_bytes = @sizeOf(Operation);

    allocator: std.mem.Allocator,
    operations: []Operation,
    gather_metadata: ?[]common.Gather = null,
    outstanding: usize = 0,
    listener: Socket,
    queue_fd: Socket,
    bound_port: u16,
    scan_start: usize = 0,

    pub fn init(allocator: std.mem.Allocator, max_connections: u16, port_number: u16) !Backend {
        if (max_connections == 0 or max_connections > 16383) return error.InvalidConnectionLimit;
        const operations = try allocator.alloc(Operation, (@as(usize, max_connections) + 1) * 2);
        errdefer allocator.free(operations);
        @memset(operations, .{});
        const listener = try common.listen(port_number, max_connections, true);
        errdefer common.closeFd(listener.socket);
        const queue = c.kqueue();
        if (queue < 0) return error.KqueueFailed;
        errdefer common.closeFd(queue);
        try common.setFlags(queue, false);
        const wake_event: c.Kevent = .{ .ident = 1, .filter = c.EVFILT.USER, .flags = c.EV.ADD | c.EV.CLEAR, .fflags = 0, .data = 0, .udata = 0 };
        try change(queue, wake_event);
        return .{ .allocator = allocator, .operations = operations, .listener = listener.socket, .queue_fd = queue, .bound_port = listener.port };
    }

    /// Startup-only storage; nonblocking sendmsg uses the established socket ABI.
    pub fn enableGather(self: *Backend) !void {
        assert(self.outstanding == 0 and self.gather_metadata == null);
        self.gather_metadata = try self.allocator.alloc(common.Gather, self.operations.len);
    }

    pub fn deinit(self: *Backend) void {
        assert(self.outstanding == 0);
        for (self.operations) |op| assert(op.kind == .free);
        common.closeFd(self.listener);
        common.closeFd(self.queue_fd);
        if (self.gather_metadata) |metadata| self.allocator.free(metadata);
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

    fn vacant(self: *Backend, token: u64, socket: Socket, kind: Kind) !*Operation {
        const identity = try common.Token.decode(token);
        const expected: common.Token.Kind = switch (kind) {
            .accept => .accept,
            .recv => .recv,
            .send, .sendv => .send,
            .cancel => identity.kind,
            .free => unreachable,
        };
        if (identity.kind != expected) return error.OperationKindMismatch;
        const cell = try identity.cell(self.operations.len);
        var free: ?*Operation = null;
        var data_count: usize = 0;
        var cancel_count: usize = 0;
        for (self.operations) |*op| {
            if (op.kind == .free) {
                if (free == null) free = op;
            } else {
                // Keep the shared logical reservation contract; this readiness
                // adapter still uses its original bounded pooled-cell scan.
                const occupied = (common.Token.decode(op.token) catch unreachable).cell(self.operations.len) catch unreachable;
                if (occupied == cell or ((kind == .accept or isData(kind)) and occupied == cell + 1)) return error.OperationCapacityExceeded;
                assert(op.token != token);
                if (kind == .accept) assert(op.kind != .accept);
                if (isData(kind)) {
                    if (isData(op.kind)) assert(op.socket != socket);
                }
                if (isData(op.kind)) data_count += 1;
                if (op.kind == .cancel) cancel_count += 1;
            }
        }
        if (isData(kind) and data_count >= self.operations.len / 2 - 1) return error.OperationCapacityExceeded;
        if (kind == .cancel and cancel_count >= self.operations.len / 2) return error.OperationCapacityExceeded;
        return free orelse error.OperationCapacityExceeded;
    }

    fn isData(kind: Kind) bool {
        return kind == .recv or kind == .send or kind == .sendv;
    }

    fn isSend(kind: Kind) bool {
        return kind == .send or kind == .sendv;
    }

    fn gatherFor(self: *Backend, op: *Operation) *common.Gather {
        const index = (@intFromPtr(op) - @intFromPtr(self.operations.ptr)) / @sizeOf(Operation);
        const metadata = self.gather_metadata.?;
        assert(index < metadata.len);
        return &metadata[index];
    }

    fn arm(self: *Backend, op: *Operation) !void {
        assert(!op.registered and op.result == null);
        const index = (@intFromPtr(op) - @intFromPtr(self.operations.ptr)) / @sizeOf(Operation);
        assert(index < self.operations.len);
        const event: c.Kevent = .{
            .ident = @intCast(op.socket),
            .filter = if (isSend(op.kind)) c.EVFILT.WRITE else c.EVFILT.READ,
            .flags = c.EV.ADD | c.EV.ONESHOT,
            .fflags = 0,
            .data = 0,
            .udata = index + 1,
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
            .sendv => c.sendmsg(op.socket, &self.gatherFor(op).message, 0),
            else => unreachable,
        };
        if (result >= 0) {
            op.result = @intCast(result);
            if (op.kind == .accept) {
                common.configureAccepted(@intCast(result), true) catch {
                    common.closeFd(@intCast(result));
                    op.result = -@as(i32, @intFromEnum(c.E.IO));
                };
            }
        } else switch (c.errno(result)) {
            .AGAIN, .INTR => try self.arm(op),
            else => |err| op.result = -@as(i32, @intFromEnum(err)),
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

    pub fn accept(self: *Backend, token: u64) !void {
        const op = try self.vacant(token, self.listener, .accept);
        try self.begin(op, .{ .kind = .accept, .token = token, .socket = self.listener });
    }

    pub fn recv(self: *Backend, token: u64, socket: Socket, buffer: []u8) !void {
        assert(buffer.len > 0 and buffer.len <= std.math.maxInt(i32));
        const op = try self.vacant(token, socket, .recv);
        try self.begin(op, .{ .kind = .recv, .token = token, .socket = socket, .read_buffer = buffer });
    }

    pub fn send(self: *Backend, token: u64, socket: Socket, bytes: []const u8) !void {
        assert(bytes.len > 0 and bytes.len <= std.math.maxInt(i32));
        const op = try self.vacant(token, socket, .send);
        try self.begin(op, .{ .kind = .send, .token = token, .socket = socket, .write_buffer = bytes });
    }

    pub fn sendv(self: *Backend, token: u64, socket: Socket, parts: []const []const u8) !void {
        if (self.gather_metadata == null) return error.GatherSendNotEnabled;
        const op = try self.vacant(token, socket, .sendv);
        self.gatherFor(op).prepare(parts);
        try self.begin(op, .{ .kind = .sendv, .token = token, .socket = socket });
    }

    pub fn cancel(self: *Backend, token: u64, target: u64) !void {
        if (token != try common.Token.cancellation(target)) return error.CancellationIdentityMismatch;
        const cancellation = try self.vacant(token, -1, .cancel);
        var result: i32 = -@as(i32, @intFromEnum(c.E.NOENT));
        for (self.operations) |*op| {
            if (op.kind == .free or op.token != target or op.result != null) continue;
            assert(op.kind != .cancel and op.registered);
            try change(self.queue_fd, .{
                .ident = @intCast(op.socket),
                .filter = if (isSend(op.kind)) c.EVFILT.WRITE else c.EVFILT.READ,
                .flags = c.EV.DELETE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            });
            op.registered = false;
            op.result = -@as(i32, @intFromEnum(c.E.CANCELED));
            result = 0;
            break;
        }
        cancellation.* = .{ .kind = .cancel, .token = token, .result = result };
        self.outstanding += 1;
    }

    fn collect(self: *Backend, out: []Completion) usize {
        var count: usize = 0;
        // Rotate the bounded scan so a perpetually ready low slot cannot starve
        // higher slots when the caller supplies a small completion buffer.
        const start = self.scan_start;
        for (0..self.operations.len) |offset| {
            const index = (start + offset) % self.operations.len;
            const op = &self.operations[index];
            if (op.kind == .free) continue;
            if (op.result) |result| {
                assert(!op.registered and self.outstanding > 0);
                out[count] = .{ .token = op.token, .result = result };
                count += 1;
                op.* = .{};
                self.outstanding -= 1;
                self.scan_start = (index + 1) % self.operations.len;
                if (count == out.len) break;
            }
        }
        return count;
    }

    pub fn poll(self: *Backend, out: []Completion, timeout_ms: u32) !usize {
        assert(out.len > 0 and timeout_ms <= std.math.maxInt(c_int));
        const collected = self.collect(out);
        var events: [64]c.Kevent = undefined;
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
                op.result = -@as(i32, @intCast(event.data));
            } else self.attempt(op) catch {
                // Once admitted, every operation must produce a terminal result.
                op.result = -@as(i32, @intFromEnum(c.E.IO));
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

    pub fn close(self: *Backend, socket: Socket) void {
        for (self.operations) |op| assert(op.kind == .free or op.socket != socket);
        common.closeFd(socket);
    }

    pub fn shutdown(_: *Backend, socket: Socket) void {
        _ = c.shutdown(socket, c.SHUT.RDWR);
    }

    pub fn port(self: *const Backend) u16 {
        return self.bound_port;
    }
};
