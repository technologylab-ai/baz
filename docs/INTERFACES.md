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
Backend methods: `init(allocator, max_connections: u16, port: u16) !Backend`,
`deinit()`, `accept(token: u64) !void`,
`recv(token, socket, buffer: []u8) !void`,
`send(token, socket, bytes: []const u8) !void`,
`enableGather() !void` during startup,
`sendv(token, socket, parts: []const []const u8) !void`,
`cancel(token: u64, target: u64) !void`,
`poll(out: []Completion, timeout_ms: u32) !usize`,
`close(socket) void`, `shutdown(socket) void`, `port() u16`.
Tokens now use the explicit shared `transport.Token` contract rather than opaque
caller-chosen integers. Use fixed Token.accept/Token.cancel_accept for the
listener and Token.connection(index, generation, kind) for recv/send/cancel.
Generation is nonzero u32, slot index is below the configured connection count,
and kind is checked at submission. The checked server generation increment must
never wrap. Token.cancellation(target) creates the matching cancellation identity;
a cancellation of a valid but missing/stale target reports its own terminal
NOENT result. Old fixture integers such as11 or999 are not valid identities.
Bits0–7 encode kind,8–23 slot,24–31 must be zero,32–63 generation. Token.decode
rejects malformed identities; Token.cell validates the configured cell bound.

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

Gather metadata is separately reserved during startup when enabled. At most 80
parts borrow payload storage through the terminal target completion. The server
caps aggregate bytes and advances partial sends across part boundaries. Adapter
`operation_bytes` allows Config.heapBytes to include exact requested operation
storage; these counts exclude kernel ring/socket allocations.

Linux addresses reserved accept/cancel cells0/1 and connection data/cancel cells
2+2n/3+2n. Admission for an already-bound connection and CQE lookup are constant
work; full token/kind/generation assertions remain. Each free data cell retains
its fd/generation binding until close. The first binding checks all other data
bindings for duplicate fd ownership, and close scans to release its binding;
those bounded cold scans remain. Target reuse (including the fixed accept token)
waits for both its target and paired cancel cell to drain. Socket shutdown is
immediate; descriptor close/reuse waits for both completions. Mac validates the
same logical token/reservation contract but retains pooled operation scans.
No new allocation or change to Linux Operation size/capacity is introduced.
