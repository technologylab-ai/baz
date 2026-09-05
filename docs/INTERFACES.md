# Initial module contracts

Exact Zig 0.16.0. Root integrates server, worker and writer. Separate contributors
own `src/http.zig` and `src/transport*.zig`. Interface changes are coordinated.

## HTTP parser

`Limits`: max_header_bytes u32, max_header_count u16, max_body_bytes u32,
max_wire_bytes u32, max_target_bytes u16. Defaults may be declared by parser.
`Parser.init(limits)`, `reset()` and `parse(bytes: []const u8) ParseError!?Request`.
Input is one stable contiguous receive buffer; each call extends the prefix.
The parser retains scan state to avoid rescanning all earlier bytes.
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
Backend methods: `init(allocator, max_connections: u16, port: u16) !Backend`,
`deinit()`, `accept(token: u64) !void`,
`recv(token, socket, buffer: []u8) !void`,
`send(token, socket, bytes: []const u8) !void`,
`cancel(token: u64, target: u64) !void`,
`poll(out: []Completion, timeout_ms: u32) !usize`,
`close(socket) void`, `shutdown(socket) void`, `port() u16`.
Accepted sockets are returned as nonnegative completion results; zero recv is EOF;
negative results are terminal OS failures. Cancellation reports target and
cancel-request completions separately. One data operation per connection and
one pending accept suffice for the first engine. Buffers remain borrowed until
the target completion, and close is only after outstanding operations return.
`wake()` is thread-safe for worker completions if available; agree a documented
short bounded poll interval if implementing that hook would block progress.

Linux uses actual low-level io_uring accept/recv/send, runtime opcode probes,
finite queues and explicit cancel drain. macOS uses nonblocking sockets/kqueue
and the same completion interface. IPv4 loopback binding initially; CLI can
expose other bind addresses later. No per-operation allocation.
