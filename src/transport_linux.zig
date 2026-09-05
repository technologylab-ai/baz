//! Linux single-shot io_uring adapter. No std.Io.Threaded or application workers.
const std = @import("std");
const c = std.c;
const linux = std.os.linux;
const common = @import("transport.zig");
const Socket = common.Socket;
const Completion = common.Completion;
const assert = std.debug.assert;

pub const Backend = struct {
    const Kind = enum { free, accept, data, cancel };
    const Operation = struct { kind: Kind = .free, token: u64 = 0, socket: Socket = -1 };

    allocator: std.mem.Allocator,
    ring: linux.IoUring,
    operations: []Operation,
    gather_metadata: ?[]common.Gather = null,
    gather_supported: bool,
    outstanding: usize = 0,
    listener: Socket,
    wake_fd: Socket,
    bound_port: u16,
    /// Saturating diagnostic; a transient never releases an operation or buffer.
    transient_retries: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, max_connections: u16, port_number: u16) !Backend {
        if (max_connections == 0 or max_connections > 16383) return error.InvalidConnectionLimit;
        const capacity = (@as(usize, max_connections) + 1) * 2;
        const entries = try std.math.ceilPowerOfTwo(u16, @intCast(capacity));
        var ring = try linux.IoUring.init(entries, 0);
        errdefer ring.deinit();
        const probe = try ring.get_probe();
        inline for (.{ linux.IORING_OP.ACCEPT, linux.IORING_OP.RECV, linux.IORING_OP.SEND, linux.IORING_OP.ASYNC_CANCEL }) |opcode| {
            if (!probe.is_supported(opcode)) return error.RequiredOpcodeUnsupported;
        }
        const operations = try allocator.alloc(Operation, capacity);
        errdefer allocator.free(operations);
        @memset(operations, .{});
        const listener = try common.listen(port_number, max_connections, false);
        errdefer common.closeFd(listener.socket);
        const result = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(result) != .SUCCESS) return error.WakeDescriptorFailed;
        return .{
            .allocator = allocator,
            .ring = ring,
            .operations = operations,
            .gather_supported = probe.is_supported(.SENDMSG),
            .listener = listener.socket,
            .wake_fd = @intCast(result),
            .bound_port = listener.port,
        };
    }

    /// Startup-only optional capability: scalar SEND does not require SENDMSG.
    pub fn enableGather(self: *Backend) !void {
        assert(self.outstanding == 0 and self.gather_metadata == null);
        if (!self.gather_supported) return error.GatherSendUnsupported;
        self.gather_metadata = try self.allocator.alloc(common.Gather, self.operations.len);
    }

    /// Caller must stop admission, cancel, and drain every target AND cancel CQE.
    /// Closing the ring is not used as an ownership acknowledgement.
    pub fn deinit(self: *Backend) void {
        assert(self.outstanding == 0);
        for (self.operations) |op| assert(op.kind == .free);
        common.closeFd(self.listener);
        common.closeFd(self.wake_fd);
        self.ring.deinit();
        if (self.gather_metadata) |metadata| self.allocator.free(metadata);
        self.allocator.free(self.operations);
        self.* = undefined;
    }

    fn vacant(self: *Backend, token: u64, socket: Socket, kind: Kind) !*Operation {
        var free: ?*Operation = null;
        var data_count: usize = 0;
        var cancel_count: usize = 0;
        for (self.operations) |*op| {
            if (op.kind == .free) {
                if (free == null) free = op;
            } else {
                assert(op.token != token);
                if (kind == .accept) assert(op.kind != .accept);
                if (kind == .data and op.kind == .data) assert(op.socket != socket);
                if (op.kind == .data) data_count += 1;
                if (op.kind == .cancel) cancel_count += 1;
            }
        }
        if (kind == .data and data_count >= self.operations.len / 2 - 1) return error.OperationCapacityExceeded;
        if (kind == .cancel and cancel_count >= self.operations.len / 2) return error.OperationCapacityExceeded;
        return free orelse error.OperationCapacityExceeded;
    }

    pub fn accept(self: *Backend, token: u64) !void {
        const op = try self.vacant(token, self.listener, .accept);
        _ = try self.ring.accept(token, self.listener, null, null, linux.SOCK.CLOEXEC);
        op.* = .{ .kind = .accept, .token = token, .socket = self.listener };
        self.outstanding += 1;
    }

    pub fn recv(self: *Backend, token: u64, socket: Socket, buffer: []u8) !void {
        assert(buffer.len > 0 and buffer.len <= std.math.maxInt(i32));
        const op = try self.vacant(token, socket, .data);
        _ = try self.ring.recv(token, socket, .{ .buffer = buffer }, 0);
        op.* = .{ .kind = .data, .token = token, .socket = socket };
        self.outstanding += 1;
    }

    pub fn send(self: *Backend, token: u64, socket: Socket, bytes: []const u8) !void {
        assert(bytes.len > 0 and bytes.len <= std.math.maxInt(i32));
        const op = try self.vacant(token, socket, .data);
        _ = try self.ring.send(token, socket, bytes, linux.MSG.NOSIGNAL);
        op.* = .{ .kind = .data, .token = token, .socket = socket };
        self.outstanding += 1;
    }

    pub fn sendv(self: *Backend, token: u64, socket: Socket, parts: []const []const u8) !void {
        const metadata = self.gather_metadata orelse return error.GatherSendNotEnabled;
        const op = try self.vacant(token, socket, .data);
        const index = (@intFromPtr(op) - @intFromPtr(self.operations.ptr)) / @sizeOf(Operation);
        assert(index < metadata.len);
        const gather = &metadata[index];
        gather.prepare(parts);
        _ = try self.ring.sendmsg(token, socket, &gather.message, linux.MSG.NOSIGNAL);
        op.* = .{ .kind = .data, .token = token, .socket = socket };
        self.outstanding += 1;
    }

    pub fn cancel(self: *Backend, token: u64, target: u64) !void {
        assert(token != target);
        const op = try self.vacant(token, -1, .cancel);
        _ = try self.ring.cancel(token, target, 0);
        op.* = .{ .kind = .cancel, .token = token };
        self.outstanding += 1;
    }

    pub fn poll(self: *Backend, out: []Completion, timeout_ms: u32) !usize {
        assert(out.len > 0 and timeout_ms <= std.math.maxInt(c_int));
        // submit() may already have published SQEs before enter is interrupted
        // or resource-constrained. Leave every ownership record intact. The next
        // outer poll turn reuses the ring's pending SQ state, rather than creating
        // duplicate operations or retrying in an unbounded loop here.
        _ = self.ring.submit() catch |err| switch (err) {
            error.SignalInterrupt, error.SystemResources => blk: {
                self.transient_retries +|= 1;
                break :blk @as(u32, 0);
            },
            else => return err,
        };
        var cqes: [64]linux.io_uring_cqe = undefined;
        var count = try self.copyReady(cqes[0..@min(out.len, cqes.len)]);
        if (count == 0) {
            var fds = [_]c.pollfd{
                .{ .fd = self.ring.fd, .events = c.POLL.IN, .revents = 0 },
                .{ .fd = self.wake_fd, .events = c.POLL.IN, .revents = 0 },
            };
            const result = c.poll(&fds, fds.len, @intCast(timeout_ms));
            if (result < 0 and c.errno(result) != .INTR) return error.PollFailed;
            if (fds[1].revents & c.POLL.IN != 0) {
                var value: u64 = undefined;
                const read_result = linux.read(self.wake_fd, @ptrCast(&value), @sizeOf(u64));
                assert(read_result == @sizeOf(u64) or linux.errno(read_result) == .AGAIN or linux.errno(read_result) == .INTR);
            }
            count = try self.copyReady(cqes[0..@min(out.len, cqes.len)]);
        }
        for (cqes[0..count], out[0..count]) |cqe, *completion| {
            // Socket readiness hints do not extend ownership. Only single-shot,
            // caller-buffer operations are admitted: no provided buffer or ZC.
            assert(cqe.flags & (linux.IORING_CQE_F_MORE | linux.IORING_CQE_F_NOTIF | linux.IORING_CQE_F_BUFFER) == 0);
            var matched = false;
            for (self.operations) |*op| {
                if (op.kind == .free or op.token != cqe.user_data) continue;
                assert(!matched and self.outstanding > 0);
                matched = true;
                var result = cqe.res;
                if (op.kind == .accept and result >= 0) {
                    common.configureAccepted(result, false) catch {
                        common.closeFd(result);
                        result = -@as(i32, @intFromEnum(c.E.IO));
                    };
                }
                completion.* = .{ .token = op.token, .result = result };
                op.* = .{};
                self.outstanding -= 1;
                break;
            }
            assert(matched);
        }
        assert(self.ring.cq.overflow.* == 0 and self.ring.sq.dropped.* == 0);
        return count;
    }

    fn copyReady(self: *Backend, cqes: []linux.io_uring_cqe) !u32 {
        // Zig's non-waiting copy can still enter the kernel to flush a pending
        // CQ condition. An interrupted/resource-limited flush is not terminal
        // evidence for any target. poll performs at most two such calls per turn.
        return self.ring.copy_cqes(cqes, 0) catch |err| switch (err) {
            error.SignalInterrupt, error.SystemResources => blk: {
                self.transient_retries +|= 1;
                break :blk @as(u32, 0);
            },
            else => return err,
        };
    }

    /// Coalescing eventfd wake. Worker lifetime must end before deinit.
    pub fn wake(self: *Backend) void {
        const one: u64 = 1;
        for (0..3) |_| {
            const result = linux.write(self.wake_fd, @ptrCast(&one), @sizeOf(u64));
            switch (linux.errno(result)) {
                .SUCCESS => return,
                .AGAIN => return, // Counter already readable; publication remains visible.
                .INTR => continue,
                else => unreachable,
            }
        }
        // Interrupted wake is backed by the engine's finite deadline poll.
    }

    pub fn close(self: *Backend, socket: Socket) void {
        for (self.operations) |op| assert(op.kind != .data or op.socket != socket);
        common.closeFd(socket);
    }

    pub fn shutdown(_: *Backend, socket: Socket) void {
        _ = c.shutdown(socket, c.SHUT.RDWR);
    }

    pub fn port(self: *const Backend) u16 {
        return self.bound_port;
    }
};
