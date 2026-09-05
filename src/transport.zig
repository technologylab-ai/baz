//! Single-owner transport interface. Only wake() may be called by another thread.
//! Payloads are borrowed through terminal completion; ordinary socket I/O still
//! copies between the kernel and userspace. This is not SEND_ZC / zero-copy RX.
//!
//! Operations are addressed by caller-chosen cells: `4 * max_connections + 2`
//! fixed records, so admission and completion matching never search. The caller
//! owns the numbering (receive, send and their cancel cells per connection,
//! plus accept and cancel-accept) and never has two live operations in one
//! cell. Gather vectors stay in the caller's stable storage until the terminal
//! completion, canceled or not.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

pub const Socket = i32;
pub const Completion = struct { token: u64, result: i32 };
/// Kernel iovec limit for one sendmsg on Linux and macOS.
pub const max_vectors: usize = 1024;

pub fn cellCount(max_connections: u16) usize {
    return @as(usize, max_connections) * 4 + 2;
}

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
// With `reuse_port`, several owners may bind the same address; on Linux the
// kernel distributes connections across them.
pub fn listen(port_number: u16, max_connections: u16, nonblocking: bool, reuse_port: bool) !struct { socket: Socket, port: u16 } {
    if (max_connections == 0 or max_connections > 16383) return error.InvalidConnectionLimit;
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer closeFd(fd);
    try setFlags(fd, nonblocking);
    const one: c_int = 1;
    if (c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &one, @sizeOf(c_int)) != 0) return error.SocketOptionFailed;
    if (reuse_port) {
        if (c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEPORT, &one, @sizeOf(c_int)) != 0) return error.SocketOptionFailed;
    }
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

pub fn vector(bytes: []const u8) c.iovec_const {
    return .{ .base = bytes.ptr, .len = bytes.len };
}

fn waitCompletion(backend: *Backend) !Completion {
    var result: [1]Completion = undefined;
    for (0..100) |_| {
        if (try backend.poll(&result, 10) == 1) return result[0];
    }
    return error.CompletionDeadline;
}

// Test cell layout for two connections: recv 0-1, send 2-3, cancels 4-7,
// accept 8, cancel-accept 9. The adapter does not interpret roles.
const test_accept_cell = 8;
const test_cancel_accept_cell = 9;

test "transport rejects impossible capacity before creating a listener" {
    try std.testing.expectError(error.InvalidConnectionLimit, Backend.init(std.testing.allocator, 0, 0, false));
    try std.testing.expectError(error.InvalidConnectionLimit, Backend.init(std.testing.allocator, 16384, 0, false));
}

test "accept cancellation drains target and cancellation acknowledgement separately" {
    var backend = try Backend.init(std.testing.allocator, 2, 0, false);
    defer backend.deinit();
    try backend.accept(test_accept_cell, 11);
    try backend.cancel(test_cancel_accept_cell, 12, test_accept_cell);
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
    var backend = try Backend.init(std.testing.allocator, 2, 0, false);
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
    try backend.accept(test_accept_cell, 21);
    const accepted = try waitCompletion(&backend);
    try std.testing.expectEqual(@as(u64, 21), accepted.token);
    try std.testing.expect(accepted.result >= 0);
    const peer = accepted.result;
    defer backend.close(0, peer);
    var buffer: [32]u8 = undefined;
    try backend.recv(0, 22, peer, &buffer);
    const input = "borrowed input";
    try std.testing.expectEqual(@as(isize, input.len), c.send(client, input.ptr, input.len, 0));
    const received = try waitCompletion(&backend);
    try std.testing.expectEqual(@as(u64, 22), received.token);
    try std.testing.expectEqual(@as(i32, input.len), received.result);
    try std.testing.expectEqualStrings(input, buffer[0..input.len]);
    try backend.send(0, 23, peer, buffer[0..input.len]);
    const sent = try waitCompletion(&backend);
    try std.testing.expectEqual(@as(u64, 23), sent.token);
    try std.testing.expectEqual(@as(i32, input.len), sent.result);
    var response: [32]u8 = undefined;
    // Poll first so a fixture failure cannot block forever in recv.
    var readable = [_]c.pollfd{.{ .fd = client, .events = c.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(c_int, 1), c.poll(&readable, 1, 1000));
    try std.testing.expectEqual(@as(isize, input.len), c.recv(client, &response, response.len, 0));
    try std.testing.expectEqualStrings(input, response[0..input.len]);
    const vectors = [_]c.iovec_const{ vector("header:"), vector("body"), vector(":end") };
    try backend.sendv(0, 27, peer, &vectors);
    const gathered = try waitCompletion(&backend);
    try std.testing.expectEqual(@as(u64, 27), gathered.token);
    const gather_expected = "header:body:end";
    try std.testing.expectEqual(@as(i32, gather_expected.len), gathered.result);
    try std.testing.expectEqual(@as(c_int, 1), c.poll(&readable, 1, 1000));
    try std.testing.expectEqual(@as(isize, gather_expected.len), c.recv(client, &response, response.len, 0));
    try std.testing.expectEqualStrings(gather_expected, response[0..gather_expected.len]);
    try backend.recv(0, 25, peer, &buffer);
    try backend.cancel(4, 26, 0);
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
    try backend.recv(0, 24, peer, &buffer);
    const eof = try waitCompletion(&backend);
    try std.testing.expectEqual(@as(u64, 24), eof.token);
    try std.testing.expectEqual(@as(i32, 0), eof.result);
}

test "wake is coalesced and does not consume a caller completion token" {
    var backend = try Backend.init(std.testing.allocator, 1, 0, false);
    defer backend.deinit();
    backend.wake();
    backend.wake();
    var completions: [2]Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 100));
    // Cancelling an idle cell yields ENOENT: the record exists, no target does.
    try backend.cancel(2, 31, 0);
    const missing = try waitCompletion(&backend);
    try std.testing.expectEqual(@as(u64, 31), missing.token);
    try std.testing.expectEqual(-@as(i32, @intFromEnum(c.E.NOENT)), missing.result);
}

test "cancellation cells are finite and returned completions replenish them" {
    var backend = try Backend.init(std.testing.allocator, 1, 0, false);
    defer backend.deinit();
    try backend.cancel(2, 41, 0);
    try backend.cancel(3, 42, 1);
    try std.testing.expectError(error.OperationCellBusy, backend.cancel(2, 43, 0));
    for (0..2) |_| _ = try waitCompletion(&backend);
    try backend.cancel(2, 43, 0);
    const replenished = try waitCompletion(&backend);
    try std.testing.expectEqual(@as(u64, 43), replenished.token);
}

test "a startup worker can wake a waiting I/O owner" {
    var backend = try Backend.init(std.testing.allocator, 1, 0, false);
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

test "two reuse-port listeners share one loopback port" {
    var first = try Backend.init(std.testing.allocator, 1, 0, true);
    defer first.deinit();
    var second = try Backend.init(std.testing.allocator, 1, first.port(), true);
    defer second.deinit();
    try std.testing.expectEqual(first.port(), second.port());
}
