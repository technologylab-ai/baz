//! Single-owner transport interface. Only wake() may be called by another thread.
//! Payloads are borrowed through terminal completion; ordinary socket I/O still
//! copies between the kernel and userspace. This is not SEND_ZC / zero-copy RX.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

pub const Socket = i32;
pub const Completion = struct { token: u64, result: i32 };
pub const max_send_parts = 16 * 5;

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
    try backend.accept(11);
    try backend.cancel(12, 11);
    var target = false;
    var cancellation = false;
    for (0..2) |_| {
        const completion = try waitCompletion(&backend);
        switch (completion.token) {
            11 => {
                try std.testing.expect(!target);
                target = true;
                try std.testing.expectEqual(-@as(i32, @intFromEnum(c.E.CANCELED)), completion.result);
            },
            12 => {
                try std.testing.expect(!cancellation);
                cancellation = true;
                try std.testing.expectEqual(@as(i32, 0), completion.result);
            },
            else => return error.UnexpectedCompletion,
        }
    }
    try std.testing.expect(target and cancellation);
}

test "transport borrows receive and send buffers and accounts for EOF" {
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
    try backend.accept(21);
    const accepted = try waitCompletion(&backend);
    try std.testing.expectEqual(@as(u64, 21), accepted.token);
    try std.testing.expect(accepted.result >= 0);
    const peer = accepted.result;
    defer backend.close(peer);
    var buffer: [32]u8 = undefined;
    try backend.recv(22, peer, &buffer);
    const input = "borrowed input";
    try std.testing.expectEqual(@as(isize, input.len), c.send(client, input.ptr, input.len, 0));
    const received = try waitCompletion(&backend);
    try std.testing.expectEqual(@as(u64, 22), received.token);
    try std.testing.expectEqual(@as(i32, input.len), received.result);
    try std.testing.expectEqualStrings(input, buffer[0..input.len]);
    try backend.send(23, peer, buffer[0..input.len]);
    const sent = try waitCompletion(&backend);
    try std.testing.expectEqual(@as(u64, 23), sent.token);
    try std.testing.expectEqual(@as(i32, input.len), sent.result);
    var response: [32]u8 = undefined;
    // Poll first so a fixture failure cannot block forever in recv.
    var readable = [_]c.pollfd{.{ .fd = client, .events = c.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(c_int, 1), c.poll(&readable, 1, 1000));
    try std.testing.expectEqual(@as(isize, input.len), c.recv(client, &response, response.len, 0));
    try std.testing.expectEqualStrings(input, response[0..input.len]);
    const gather_parts = [_][]const u8{ "header:", "body", ":end" };
    try backend.sendv(27, peer, &gather_parts);
    const gathered = try waitCompletion(&backend);
    try std.testing.expectEqual(@as(u64, 27), gathered.token);
    const gather_expected = "header:body:end";
    try std.testing.expectEqual(@as(i32, gather_expected.len), gathered.result);
    try std.testing.expectEqual(@as(c_int, 1), c.poll(&readable, 1, 1000));
    try std.testing.expectEqual(@as(isize, gather_expected.len), c.recv(client, &response, response.len, 0));
    try std.testing.expectEqualStrings(gather_expected, response[0..gather_expected.len]);
    try backend.recv(25, peer, &buffer);
    try backend.cancel(26, 25);
    var canceled_receive = false;
    var cancel_acknowledged = false;
    for (0..2) |_| {
        const completion = try waitCompletion(&backend);
        switch (completion.token) {
            25 => {
                try std.testing.expect(!canceled_receive);
                canceled_receive = true;
                try std.testing.expectEqual(-@as(i32, @intFromEnum(c.E.CANCELED)), completion.result);
            },
            26 => {
                try std.testing.expect(!cancel_acknowledged);
                cancel_acknowledged = true;
                try std.testing.expectEqual(@as(i32, 0), completion.result);
            },
            else => return error.UnexpectedCompletion,
        }
    }
    try std.testing.expect(canceled_receive and cancel_acknowledged);
    _ = c.shutdown(client, c.SHUT.WR);
    try backend.recv(24, peer, &buffer);
    const eof = try waitCompletion(&backend);
    try std.testing.expectEqual(@as(u64, 24), eof.token);
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
    try backend.cancel(31, 999);
    const missing = try waitCompletion(&backend);
    try std.testing.expectEqual(@as(u64, 31), missing.token);
    try std.testing.expectEqual(-@as(i32, @intFromEnum(c.E.NOENT)), missing.result);
}

test "cancellation admission is finite and returned completions replenish it" {
    var backend = try Backend.init(std.testing.allocator, 1, 0);
    defer backend.deinit();
    try backend.cancel(41, 999);
    try backend.cancel(42, 999);
    try std.testing.expectError(error.OperationCapacityExceeded, backend.cancel(43, 999));
    for (0..2) |_| _ = try waitCompletion(&backend);
    try backend.cancel(43, 999);
    const replenished = try waitCompletion(&backend);
    try std.testing.expectEqual(@as(u64, 43), replenished.token);
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
