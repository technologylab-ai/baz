//! Single-owner transport interface. Only wake() may be called by another thread.
//! Payloads are borrowed through terminal completion; ordinary socket I/O still
//! copies between the kernel and userspace. This is not SEND_ZC / zero-copy RX.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

pub const Socket = i32;
pub const Completion = struct { token: u64, result: i32 };
pub const max_send_parts = 64 * 5;

/// Explicit single-owner operation identity shared by the server and adapters.
/// Bits 0..7 select kind, 8..23 select connection slot, 24..31 are zero,
/// and 32..63 hold a nonzero connection generation. Accept identities are fixed.
/// A data cell has one separate cancel cell; a cancel acknowledgement does not
/// retire the target. Reuse a connection slot only after both owners drain and
/// close releases its binding. Generation increments must be checked by caller.
pub const Token = struct {
    pub const Kind = enum(u8) { accept = 1, recv, send, cancel, cancel_accept };
    pub const accept: u64 = @intFromEnum(Kind.accept);
    pub const cancel_accept: u64 = @intFromEnum(Kind.cancel_accept);
    pub const max_connections = 16383;

    kind: Kind,
    index: u16 = 0,
    generation: u32 = 0,

    pub fn connection(index: usize, generation: u32, kind: Kind) u64 {
        std.debug.assert(index < max_connections and generation > 0);
        std.debug.assert(kind == .recv or kind == .send or kind == .cancel);
        return (@as(u64, generation) << 32) | (@as(u64, index) << 8) | @intFromEnum(kind);
    }

    pub fn decode(value: u64) !Token {
        const kind: Kind = switch (@as(u8, @truncate(value))) {
            1 => .accept,
            2 => .recv,
            3 => .send,
            4 => .cancel,
            5 => .cancel_accept,
            else => return error.InvalidOperationToken,
        };
        if (kind == .accept or kind == .cancel_accept) {
            if (value != @intFromEnum(kind)) return error.InvalidOperationToken;
            return .{ .kind = kind };
        }
        if (value & 0xff000000 != 0) return error.InvalidOperationToken;
        const index: u16 = @truncate(value >> 8);
        const generation: u32 = @intCast(value >> 32);
        if (index >= max_connections or generation == 0) return error.InvalidOperationToken;
        return .{ .kind = kind, .index = index, .generation = generation };
    }

    /// Fixed address: accept/cancel 0/1, connection data/cancel 2+2n/3+2n.
    pub fn cell(self: Token, capacity: usize) !usize {
        std.debug.assert(capacity >= 4 and capacity <= 2 * (max_connections + 1) and capacity % 2 == 0);
        const index: usize = switch (self.kind) {
            .accept => 0,
            .cancel_accept => 1,
            .recv, .send => 2 + 2 * @as(usize, self.index),
            .cancel => 3 + 2 * @as(usize, self.index),
        };
        if (index >= capacity) return error.OperationAddressOutOfBounds;
        return index;
    }

    pub fn cancellation(target: u64) !u64 {
        const decoded = try decode(target);
        return switch (decoded.kind) {
            .accept => cancel_accept,
            .recv, .send => connection(decoded.index, decoded.generation, .cancel),
            .cancel, .cancel_accept => error.InvalidCancellationTarget,
        };
    }
};

/// Stable metadata for an ordinary gather send. prepare() copies descriptors,
/// never payloads. The owner retains this object and all payload spans until the
/// one terminal completion (including a canceled target) has been consumed.
pub const Gather = struct {
    const Message = if (builtin.os.tag == .linux) std.os.linux.msghdr_const else c.msghdr_const;
    vectors: [max_send_parts]c.iovec_const = undefined,
    message: Message = undefined,
    bytes: usize = 0,

    pub fn prepare(self: *Gather, parts: []const []const u8) void {
        std.debug.assert(parts.len > 0 and parts.len <= max_send_parts);
        var total: usize = 0;
        for (parts, 0..) |part, index| {
            std.debug.assert(part.len > 0 and part.len <= std.math.maxInt(i32) - total);
            self.vectors[index] = .{ .base = part.ptr, .len = part.len };
            total += part.len;
        }
        self.bytes = total;
        self.message = .{
            .name = null,
            .namelen = 0,
            .iov = &self.vectors,
            .iovlen = @intCast(parts.len),
            .control = null,
            .controllen = 0,
            .flags = 0,
        };
    }
};
pub const Backend = switch (builtin.os.tag) {
    .linux => @import("transport_linux.zig").Backend,
    .macos => @import("transport_macos.zig").Backend,
    else => @compileError("The experimental MVP transport supports Linux and macOS; Windows is pending."),
};
pub const name = switch (builtin.os.tag) {
    .linux => "io_uring",
    .macos => "kqueue",
    else => "unsupported",
};

// Shared startup-only socket setup. The kernel listen backlog is separate from
// framework connection admission; it cannot establish application admission.
pub fn listen(port_number: u16, max_connections: u16, nonblocking: bool) !struct { socket: Socket, port: u16 } {
    if (max_connections == 0 or max_connections > 16383) return error.InvalidConnectionLimit;
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer closeFd(fd);
    try setFlags(fd, nonblocking);
    const one: c_int = 1;
    if (c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &one, @sizeOf(c_int)) != 0) return error.SocketOptionFailed;
    var address: c.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port_number),
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
    if (c.bind(fd, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0) return error.BindFailed;
    if (c.listen(fd, @intCast(max_connections)) != 0) return error.ListenFailed;
    var length: c.socklen_t = @sizeOf(@TypeOf(address));
    if (c.getsockname(fd, @ptrCast(&address), &length) != 0) return error.SocketNameFailed;
    return .{ .socket = fd, .port = std.mem.bigToNative(u16, address.port) };
}

pub fn setFlags(fd: Socket, nonblocking: bool) !void {
    if (c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) return error.SocketFlagsFailed;
    if (nonblocking) {
        const flags = c.fcntl(fd, c.F.GETFL);
        if (flags < 0) return error.SocketFlagsFailed;
        const nonblock: u32 = @bitCast(c.O{ .NONBLOCK = true });
        if (c.fcntl(fd, c.F.SETFL, flags | @as(c_int, @intCast(nonblock))) < 0) return error.SocketFlagsFailed;
    }
}

pub fn configureAccepted(fd: Socket, nonblocking: bool) !void {
    try setFlags(fd, nonblocking);
    const one: c_int = 1;
    if (c.setsockopt(fd, c.IPPROTO.TCP, c.TCP.NODELAY, &one, @sizeOf(c_int)) != 0) return error.SocketOptionFailed;
    if (builtin.os.tag == .macos) {
        if (c.setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, &one, @sizeOf(c_int)) != 0) return error.SocketOptionFailed;
    }
}

pub fn closeFd(fd: Socket) void {
    std.debug.assert(fd >= 0);
    const result = c.close(fd);
    // Do not retry close after EINTR: descriptor reuse makes that unsafe.
    std.debug.assert(result == 0 or c.errno(result) == .INTR);
}

fn waitCompletion(backend: *Backend) !Completion {
    var result: [1]Completion = undefined;
    for (0..100) |_| {
        if (try backend.poll(&result, 10) == 1) return result[0];
    }
    return error.CompletionDeadline;
}

test "transport rejects impossible capacity before creating a listener" {
    try std.testing.expectError(error.InvalidConnectionLimit, Backend.init(std.testing.allocator, 0, 0));
    try std.testing.expectError(error.InvalidConnectionLimit, Backend.init(std.testing.allocator, 16384, 0));
}

test "accept cancellation drains target and cancellation acknowledgement separately" {
    var backend = try Backend.init(std.testing.allocator, 2, 0);
    defer backend.deinit();
    try backend.accept(Token.accept);
    try backend.cancel(Token.cancel_accept, Token.accept);
    var target = false;
    var cancellation = false;
    for (0..2) |step| {
        const completion = try waitCompletion(&backend);
        switch (completion.token) {
            Token.accept => {
                try std.testing.expect(!target);
                target = true;
                try std.testing.expectEqual(-@as(i32, @intFromEnum(c.E.CANCELED)), completion.result);
            },
            Token.cancel_accept => {
                try std.testing.expect(!cancellation);
                cancellation = true;
                try std.testing.expectEqual(@as(i32, 0), completion.result);
            },
            else => return error.UnexpectedCompletion,
        }
        if (step == 0) try std.testing.expectError(error.OperationCapacityExceeded, backend.accept(Token.accept));
    }
    try std.testing.expect(target and cancellation);
}

test "transport borrows receive and send buffers and accounts for EOF" {
    const recv_token = comptime Token.connection(0, 1, .recv);
    const send_token = Token.connection(0, 1, .send);
    const cancel_token = comptime Token.cancellation(recv_token) catch unreachable;
    var backend = try Backend.init(std.testing.allocator, 2, 0);
    defer backend.deinit();
    try backend.enableGather();
    const client = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (client < 0) return error.SocketFailed;
    defer closeFd(client);
    var address: c.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, backend.port()),
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
    if (c.connect(client, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0) return error.ConnectFailed;
    try backend.accept(Token.accept);
    const accepted = try waitCompletion(&backend);
    try std.testing.expectEqual(@as(u64, Token.accept), accepted.token);
    try std.testing.expect(accepted.result >= 0);
    const peer = accepted.result;
    defer backend.close(peer);
    var buffer: [32]u8 = undefined;
    try backend.recv(recv_token, peer, &buffer);
    const input = "borrowed input";
    try std.testing.expectEqual(@as(isize, input.len), c.send(client, input.ptr, input.len, 0));
    const received = try waitCompletion(&backend);
    try std.testing.expectEqual(@as(u64, recv_token), received.token);
    try std.testing.expectEqual(@as(i32, input.len), received.result);
    try std.testing.expectEqualStrings(input, buffer[0..input.len]);
    try backend.send(send_token, peer, buffer[0..input.len]);
    const sent = try waitCompletion(&backend);
    try std.testing.expectEqual(@as(u64, send_token), sent.token);
    try std.testing.expectEqual(@as(i32, input.len), sent.result);
    var response: [32]u8 = undefined;
    // Poll first so a fixture failure cannot block forever in recv.
    var readable = [_]c.pollfd{.{ .fd = client, .events = c.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(c_int, 1), c.poll(&readable, 1, 1000));
    try std.testing.expectEqual(@as(isize, input.len), c.recv(client, &response, response.len, 0));
    try std.testing.expectEqualStrings(input, response[0..input.len]);
    const gather_parts = [_][]const u8{ "header:", "body", ":end" };
    try backend.sendv(send_token, peer, &gather_parts);
    const gathered = try waitCompletion(&backend);
    try std.testing.expectEqual(@as(u64, send_token), gathered.token);
    const gather_expected = "header:body:end";
    try std.testing.expectEqual(@as(i32, gather_expected.len), gathered.result);
    try std.testing.expectEqual(@as(c_int, 1), c.poll(&readable, 1, 1000));
    try std.testing.expectEqual(@as(isize, gather_expected.len), c.recv(client, &response, response.len, 0));
    try std.testing.expectEqualStrings(gather_expected, response[0..gather_expected.len]);
    try backend.recv(recv_token, peer, &buffer);
    try backend.cancel(cancel_token, recv_token);
    var canceled_receive = false;
    var cancel_acknowledged = false;
    for (0..2) |_| {
        const completion = try waitCompletion(&backend);
        switch (completion.token) {
            recv_token => {
                try std.testing.expect(!canceled_receive);
                canceled_receive = true;
                try std.testing.expectEqual(-@as(i32, @intFromEnum(c.E.CANCELED)), completion.result);
            },
            cancel_token => {
                try std.testing.expect(!cancel_acknowledged);
                cancel_acknowledged = true;
                try std.testing.expectEqual(@as(i32, 0), completion.result);
            },
            else => return error.UnexpectedCompletion,
        }
    }
    try std.testing.expect(canceled_receive and cancel_acknowledged);
    _ = c.shutdown(client, c.SHUT.WR);
    try backend.recv(recv_token, peer, &buffer);
    const eof = try waitCompletion(&backend);
    try std.testing.expectEqual(@as(u64, recv_token), eof.token);
    try std.testing.expectEqual(@as(i32, 0), eof.result);
}

test "gather metadata borrows payloads and initializes only the visible vector prefix" {
    var metadata: Gather = .{};
    const parts = [_][]const u8{ "header", "payload", "trailer" };
    metadata.prepare(&parts);
    try std.testing.expectEqual(@as(usize, 20), metadata.bytes);
    try std.testing.expectEqual(@as(usize, 3), metadata.message.iovlen);
    try std.testing.expectEqual(@as([*]const c.iovec_const, &metadata.vectors), metadata.message.iov);
    for (parts, 0..) |part, index| {
        try std.testing.expectEqual(part.ptr, metadata.vectors[index].base);
        try std.testing.expectEqual(part.len, metadata.vectors[index].len);
    }
    metadata.prepare(&.{"short"});
    try std.testing.expectEqual(@as(usize, 1), metadata.message.iovlen);
    try std.testing.expectEqual(@as(usize, 5), metadata.bytes);
}

test "wake is coalesced and does not consume a caller completion token" {
    var backend = try Backend.init(std.testing.allocator, 1, 0);
    defer backend.deinit();
    backend.wake();
    backend.wake();
    var completions: [2]Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 100));
    const missing_target = Token.connection(0, 9, .recv);
    const cancel_token = try Token.cancellation(missing_target);
    try backend.cancel(cancel_token, missing_target);
    const missing = try waitCompletion(&backend);
    try std.testing.expectEqual(cancel_token, missing.token);
    try std.testing.expectEqual(-@as(i32, @intFromEnum(c.E.NOENT)), missing.result);
}

test "cancellation admission is finite and returned completions replenish it" {
    var backend = try Backend.init(std.testing.allocator, 1, 0);
    defer backend.deinit();
    const missing_target = Token.connection(0, 9, .recv);
    const cancel_token = try Token.cancellation(missing_target);
    try backend.cancel(Token.cancel_accept, Token.accept);
    try backend.cancel(cancel_token, missing_target);
    try std.testing.expectError(error.OperationCapacityExceeded, backend.cancel(cancel_token, missing_target));
    for (0..2) |_| _ = try waitCompletion(&backend);
    try backend.cancel(cancel_token, missing_target);
    const replenished = try waitCompletion(&backend);
    try std.testing.expectEqual(cancel_token, replenished.token);
    try std.testing.expectEqual(-@as(i32, @intFromEnum(c.E.NOENT)), replenished.result);
}

test "a startup worker can wake a waiting I/O owner" {
    var backend = try Backend.init(std.testing.allocator, 1, 0);
    defer backend.deinit();
    const Worker = struct {
        fn run(target: *Backend) void {
            const delay: c.timespec = .{ .sec = 0, .nsec = 20_000_000 };
            _ = c.nanosleep(&delay, null);
            target.wake();
        }
    };
    const worker = try std.Thread.spawn(.{}, Worker.run, .{&backend});
    defer worker.join();
    var completions: [1]Completion = undefined;
    var before: c.timespec = undefined;
    var after: c.timespec = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.clock_gettime(c.CLOCK.MONOTONIC, &before));
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 1000));
    try std.testing.expectEqual(@as(c_int, 0), c.clock_gettime(c.CLOCK.MONOTONIC, &after));
    const elapsed_ns = (@as(i128, after.sec) - before.sec) * std.time.ns_per_s + after.nsec - before.nsec;
    // Generous fixture watchdog; this is not a scheduler latency guarantee.
    try std.testing.expect(elapsed_ns < 900 * std.time.ns_per_ms);
}

test "structured operation identities reject malformed bounds kinds and cancellation targets" {
    try std.testing.expectEqual(@as(usize, 0), try (try Token.decode(Token.accept)).cell(4));
    try std.testing.expectEqual(@as(usize, 1), try (try Token.decode(Token.cancel_accept)).cell(4));
    const recv_token = Token.connection(0, std.math.maxInt(u32), .recv);
    const send_token = Token.connection(0, std.math.maxInt(u32), .send);
    const cancel_token = try Token.cancellation(recv_token);
    try std.testing.expectEqual(@as(usize, 2), try (try Token.decode(recv_token)).cell(4));
    try std.testing.expectEqual(@as(usize, 2), try (try Token.decode(send_token)).cell(4));
    try std.testing.expectEqual(@as(usize, 3), try (try Token.decode(cancel_token)).cell(4));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), (try Token.decode(recv_token)).generation);
    try std.testing.expectError(error.InvalidOperationToken, Token.decode(11));
    try std.testing.expectError(error.InvalidOperationToken, Token.decode(2)); // Missing generation.
    try std.testing.expectError(error.InvalidOperationToken, Token.decode(recv_token | 0x01000000));
    try std.testing.expectError(error.InvalidOperationToken, Token.decode(Token.accept | (@as(u64, 1) << 32)));
    try std.testing.expectError(error.InvalidOperationToken, Token.decode((@as(u64, 1) << 32) | (16383 << 8) | 2));
    try std.testing.expectError(error.InvalidCancellationTarget, Token.cancellation(cancel_token));
    try std.testing.expectError(error.InvalidCancellationTarget, Token.cancellation(Token.cancel_accept));

    var backend = try Backend.init(std.testing.allocator, 1, 0);
    defer backend.deinit();
    var buffer: [1]u8 = undefined;
    try std.testing.expectError(error.OperationKindMismatch, backend.recv(Token.accept, -1, &buffer));
    try std.testing.expectError(error.OperationKindMismatch, backend.accept(recv_token));
    try std.testing.expectError(error.OperationAddressOutOfBounds, backend.recv(Token.connection(1, 1, .recv), -1, &buffer));
    try std.testing.expectError(error.CancellationIdentityMismatch, backend.cancel(Token.cancel_accept, recv_token));
    try backend.accept(Token.accept);
    try std.testing.expectError(error.OperationCapacityExceeded, backend.accept(Token.accept));
    try backend.cancel(Token.cancel_accept, Token.accept);
    for (0..2) |_| _ = try waitCompletion(&backend);
}

test "stale cancellation generation cannot retire the occupied data cell" {
    var backend = try Backend.init(std.testing.allocator, 1, 0);
    defer backend.deinit();
    const client = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (client < 0) return error.SocketFailed;
    defer closeFd(client);
    var address: c.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, backend.port()),
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
    if (c.connect(client, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0) return error.ConnectFailed;
    try backend.accept(Token.accept);
    const accepted = try waitCompletion(&backend);
    try std.testing.expect(accepted.result >= 0);
    const peer = accepted.result;
    defer backend.close(peer);
    var buffer: [32]u8 = undefined;
    const current = Token.connection(0, 2, .recv);
    const stale = Token.connection(0, 1, .recv);
    const stale_cancel = try Token.cancellation(stale);
    const current_cancel = try Token.cancellation(current);
    try backend.recv(current, peer, &buffer);
    try std.testing.expectError(error.OperationCapacityExceeded, backend.send(Token.connection(0, 2, .send), peer, "occupied"));
    try backend.cancel(stale_cancel, stale);
    try std.testing.expectError(error.OperationCapacityExceeded, backend.cancel(current_cancel, current));
    const missing = try waitCompletion(&backend);
    try std.testing.expectEqual(stale_cancel, missing.token);
    try std.testing.expectEqual(-@as(i32, @intFromEnum(c.E.NOENT)), missing.result);
    try std.testing.expectEqual(@as(usize, 1), backend.outstanding);
    try backend.cancel(current_cancel, current);
    var saw_target = false;
    var saw_cancel = false;
    for (0..2) |_| {
        const completion = try waitCompletion(&backend);
        if (completion.token == current) {
            try std.testing.expect(!saw_target);
            saw_target = true;
            try std.testing.expectEqual(-@as(i32, @intFromEnum(c.E.CANCELED)), completion.result);
        } else if (completion.token == current_cancel) {
            try std.testing.expect(!saw_cancel);
            saw_cancel = true;
            try std.testing.expectEqual(@as(i32, 0), completion.result);
        } else return error.UnexpectedCompletion;
    }
    try std.testing.expect(saw_target and saw_cancel and backend.outstanding == 0);
    // Same connection generation can use its data cell again once both drain.
    try backend.send(Token.connection(0, 2, .send), peer, "reused");
    const reused = try waitCompletion(&backend);
    try std.testing.expectEqual(@as(i32, 6), reused.result);
}

test "gather target and cancellation cells retain metadata until both terminal owners drain" {
    var backend = try Backend.init(std.testing.allocator, 1, 0);
    defer backend.deinit();
    try backend.enableGather();
    const client = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (client < 0) return error.SocketFailed;
    defer closeFd(client);
    var address: c.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, backend.port()),
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
    if (c.connect(client, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0) return error.ConnectFailed;
    try backend.accept(Token.accept);
    const accepted = try waitCompletion(&backend);
    try std.testing.expect(accepted.result >= 0);
    const peer = accepted.result;
    defer backend.close(peer);
    const target = Token.connection(0, 1, .send);
    const cancellation = try Token.cancellation(target);
    const parts = [_][]const u8{ "header:", "borrowed body", ":end" };
    try backend.sendv(target, peer, &parts);
    var metadata: ?*const Gather = null;
    for (backend.operations, 0..) |op, index| {
        if (op.token == target) metadata = &backend.gather_metadata.?[index];
    }
    try std.testing.expect(metadata != null);
    const frozen = metadata.?;
    try backend.cancel(cancellation, target);
    try std.testing.expectEqual(@as(usize, 2), backend.outstanding);
    var saw_target = false;
    var saw_cancel = false;
    for (0..2) |step| {
        const completion = try waitCompletion(&backend);
        if (completion.token == target) {
            try std.testing.expect(!saw_target);
            saw_target = true;
            try std.testing.expect(completion.result > 0 or completion.result == -@as(i32, @intFromEnum(c.E.CANCELED)));
        } else if (completion.token == cancellation) {
            try std.testing.expect(!saw_cancel);
            saw_cancel = true;
            // Completing normally can race the cancellation request.
            try std.testing.expect(completion.result == 0 or completion.result == -@as(i32, @intFromEnum(c.E.NOENT)) or completion.result == -@as(i32, @intFromEnum(c.E.ALREADY)));
        } else return error.UnexpectedCompletion;
        for (parts, 0..) |part, index| {
            try std.testing.expectEqual(part.ptr, frozen.vectors[index].base);
            try std.testing.expectEqual(part.len, frozen.vectors[index].len);
        }
        if (step == 0) {
            try std.testing.expectEqual(@as(usize, 1), backend.outstanding);
            // Whichever CQE arrives first, its other owner prevents data reuse.
            try std.testing.expectError(error.OperationCapacityExceeded, backend.sendv(target, peer, &.{"must not replace frozen descriptors"}));
        }
    }
    try std.testing.expect(saw_target and saw_cancel and backend.outstanding == 0);
    try backend.sendv(target, peer, &.{"reused"});
    const reused = try waitCompletion(&backend);
    try std.testing.expectEqual(@as(i32, 6), reused.result);
}
