# Module contracts

Exact Zig 0.16.0. The maintained parser, server, writer and platform adapters
share the ownership contract in [OWNERSHIP.md](OWNERSHIP.md).

## HTTP parser

`Limits`: max_header_bytes u32, max_header_count u16, max_body_bytes u32,
max_wire_bytes u32, max_target_bytes u16. Defaults may be declared by parser.
`Parser.init(limits)`, `reset()` and `parse(bytes: []const u8) ParseError!?Request`.
Input is one stable contiguous receive buffer; each call extends the prefix.
The parser retains scan state to avoid rescanning all earlier bytes. Reset
clears parser metadata; older response cells may still borrow immutable input.
Only the server knows when every such borrow has ended and compaction is safe.
Public `head_complete`, `expect_continue`, `headers_end` allow an interim 100
after validated headers and before waiting for a body. No allocation.

`Request`: method and target byte slices; raw headers slice; body_wire slice;
chunked bool; body_bytes usize; consumed usize; keep_alive bool;
expect_continue bool; head_only bool. `header(name)` returns first borrowed
match or null, `body()` returns iterator with `next() ?[]const u8` returning
logical body spans (skip chunk framing without coalescing copies).

`ParseError`: BadRequest, HeadersTooLarge, BodyTooLarge, TargetTooLong,
UnsupportedTransferEncoding, ExpectationFailed, UnsupportedVersion.

## Transport

`src/transport.zig` exports selected `Backend`, `Socket` (i32 for POSIX MVP),
`Completion { token: u64, result: i32 }` and `name`.
Operations are addressed by caller-chosen cells: `cellCount(max_connections)`
= `2 × (max_connections + 1)` fixed records. The server numbers them data
cell = slot index, cancel cell = slots + index, then accept and cancel-accept.
One cell never holds two live operations, so admission and completion matching
are constant-time and the token is returned from the record.
Backend methods: `init(allocator, max_connections: u16, port: u16, reuse_port: bool) !Backend`,
`deinit()`, `accept(cell: u32, token: u64) !void`,
`recv(cell, token, socket, buffer: []u8) !void`,
`send(cell, token, socket, bytes: []const u8) !void`,
`enableGather() !void` during startup,
`sendv(cell, token, socket, vectors: []const iovec_const) !void`,
`cancel(cell, token, target_cell: u32) !void`,
`poll(out: []Completion, timeout_ms: u32) !usize`,
`close(cell, socket) void`, `shutdown(socket) void`, `port() u16`.
Accepted sockets are returned as nonnegative completion results; zero recv is EOF;
negative results are terminal OS failures. Cancellation reports target and
cancel-request completions separately; cancelling an idle cell reports ENOENT.
Buffers and gather vectors remain borrowed until the target completion, and
close is only after outstanding operations return. A busy cell yields
`error.OperationCellBusy`. `wake()` is thread-safe for worker completions.

Linux uses actual low-level io_uring accept/recv/send, runtime opcode probes,
finite queues and explicit cancel drain. macOS uses nonblocking sockets/kqueue
and the same completion interface. IPv4 loopback binding initially; CLI can
expose other bind addresses later. No per-operation allocation.

Gather vectors live in the caller's per-connection startup storage; the adapter
points its msghdr at them and copies nothing. Up to `max_vectors` (1024) may be
submitted; the server bounds a batch at `2 × response_batch_limit + 1`. The
server caps aggregate bytes and advances partial sends across vector
boundaries. Adapter `operation_bytes` allows Config.heapBytes to include exact
requested operation storage; these counts exclude kernel ring/socket allocations.
With `reuse_port`, several backends bind one port and Linux distributes
connections across them; XNU does not.
