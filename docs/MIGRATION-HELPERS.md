# From migration friction to everyday APIs

Serve LAN clients, download runtime files, decode ordered form fields, and keep
Baz's error classifications in a custom hook. These conveniences keep resource
ownership explicit. Use exact Zig 0.16.0.

## Reach your application from the LAN

The listener defaults to `127.0.0.1`. Select another IPv4 address at startup:

```zig
.server = .{
    .bind_address = .{ 0, 0, 0, 0 },
    .port = 8080,
    .connections = 16,
}
```

`0.0.0.0` listens on all IPv4 interfaces. A specific local address selects that
address. Clients use the machine's actual LAN address, not `0.0.0.0`.
The address comes from the [bounded/http](https://technologylab-ai.github.io/bounded-http/)
configuration that Baz exposes directly. No name lookup or request allocation
is involved. Connection limits and [backpressure](LIMITS.md) still apply.

Try the hello example:

```sh
zig build hello -Doptimize=ReleaseSafe
./zig-out/bin/hello --bind-address 0.0.0.0 --port 8080 --connections 16
```

Open `http://YOUR-LAN-IP:8080/` on another device. Stop the server with Ctrl-C.
The shared example CLI accepts four decimal octets; embedded applications can
use `web.Config.parseBindAddress(text)`. The server still speaks plain HTTP/1.1.

## Copy a runtime file into a response

An embedded asset is useful when the file is known at compilation. For a file
created later, run the [runtime download example](../examples/runtime_file.zig):

```sh
zig build runtime_file -Doptimize=ReleaseSafe
./zig-out/bin/runtime_file --file ./export.zip --port 8080
curl --output downloaded.zip http://127.0.0.1:8080/download
curl --head http://127.0.0.1:8080/download
```

Supply an existing file. On Windows, use `.exe` executables and `curl.exe`.
The operator selects the path at startup; the request URL does not select a
filesystem path. The example opens the file for each request on a fixed worker.
It uses 16 KiB of copy scratch, 4 KiB of reader storage, 8 KiB of response staging,
and a 64 MiB total response limit. The scratch buffers live on the worker stack.

The central operation is:

```zig
var reader = file.reader(io, &read_buffer);
var stream = try ctx.response.stream(200, "application/zip", .{});
_ = try stream.copyFrom(&reader.interface, &scratch);
try stream.finish();
```

`copyFrom` reads until EOF and returns the copied byte count. It leaves the stream
open for additional writes. Scratch must be nonempty and separate from reader and
response storage. Every write copies into Baz's bounded response staging; a full
staging buffer waits for transport progress. This is not an OS zero-copy operation.

The raw stream writer has no writable destination buffer. Consequently,
`file_reader.interface.streamRemaining(stream.writer())` can fail with
`WriterBufferUnavailable` in Zig 0.16.0's file-reader fallback. Use `copyFrom` for
that transfer. Standard writer `writeAll`, `print`, and `flush` remain available.

Source and sink failures are sticky: `stream.failure()` retains the error, and
`copyFrom` returns it. A generic reader reports `ReadFailed`; its concrete file
reader retains the underlying diagnostic in `reader.err`. The complete example
shows how to propagate that diagnostic. An error before publication can become
an error response. After publication, failure closes the incomplete response.

Keep the file, reader, and scratch alive during the copy. The file can close after
the copied bytes have been accepted, even when final transport work remains.
For a generated temporary ZIP, close its generation writer before opening it for
reading. Close the reader's file before unlinking it; retain the path and arrange
cleanup on error too. Do not unlink a shared download while another request needs
to open it. That lifetime belongs to the application.

The file size from `stat` is a snapshot. Baz still enforces cumulative response
bounds and any declared content length if the file changes. HEAD executes the
handler and suppresses its payload; this example still reads the file for HEAD.
Cancellation is checked before each source read and while waiting for flushes.
It cannot interrupt arbitrary source I/O already in progress.

## Decode fields without losing the iterator

The raw iterator continues to return borrowed `name_raw`, `value_raw`, and
`has_equals`. Use a caller allocator when owned, decoded fields are more convenient:

```zig
var it = fields.decodedIterator(allocator, .form);
while (try it.next()) |decoded| {
    var field = decoded;
    defer field.deinit(allocator);
    // Consume field.name, field.value, and field.has_equals here.
}
```

Each pair owns one allocation for its decoded name and value. Free the pair with
the same allocator, or reset its arena after all results are no longer needed.
Do not free the name and value subslices individually. Earlier results stay valid
after `next()`; the iterator itself still borrows the original encoded input.
An invalid escape or allocation failure leaves its position unchanged.

`.form` converts `+` to a space; `.percent` preserves `+`. Both decode percent
escapes once. Neither validates UTF-8, normalizes text, converts numbers, merges
query and body parameters, or chooses a duplicate policy.

| Encoded input | Decoded name | Decoded value | `has_equals` |
| --- | --- | --- | --- |
| `name=Alice+Smith` | `name` | `Alice Smith` | `true` |
| `%6eame=Bob%2BJones` | `name` | `Bob+Jones` | `true` |
| `flag` | `flag` | empty | `false` |
| `empty=` | `empty` | empty | `true` |

Both `name` entries remain in order. The application decides whether to accept
both, use one, or reject duplicates. Existing `firstRaw` and `allRaw` continue
matching the original encoded names.

Try the [decoded form example](../examples/decoded_forms.zig):

```sh
zig build decoded_forms -Doptimize=ReleaseSafe
./zig-out/bin/decoded_forms --port 8080
curl --data 'name=Alice+Smith&%6eame=Bob%2BJones&flag&empty=' http://127.0.0.1:8080/
```

The example uses a per-request application arena on a worker, preserves ordered
duplicates, and joins segmented bodies into bounded caller storage when needed.
Its JSON display explicitly requires UTF-8. Input byte and pair limits still apply;
allocator overhead and retained results are part of the application's memory use.

## Customize errors and preserve their status

An `on_error` hook replaces Baz's default handler. Reuse the default classification
when adding custom presentation or application error cases:

```zig
fn onError(ctx: *Application.Context, err: anyerror) !void {
    const status = switch (err) {
        error.ServiceUnavailable => 503,
        else => web.defaultErrorStatus(err),
    };
    try ctx.response.jsonValue(status, .{ .message = "Request failed" });
}
```

Malformed forms retain their 400 classification, oversized forms their 413, and
unsupported form media types their 415. Cookie limits map to 431; unknown errors
map to 500. The [error example](../examples/app_errors.zig) counts failures and
customizes its demo error without exposing internal diagnostics.
Engine framing failures occur before App dispatch. A hook cannot replace bytes
already published. Logging or other work in the hook follows the same execution
rules as its handler.

## Bring a service to a clean stop

The [jobs application](JOBS.md) already demonstrates cached templates, sessions,
background work, and producer cleanup. For a persistent service, complete HTTP
draining, quiesce background mutations, perform the final persistence flush, and
then release shared storage. Keep dependencies needed by draining handlers alive.
Give service operations explicit deadlines where the provider supports them, and
join producers before freeing their storage.

A periodic save is not a final shutdown flush. A successful graceful-shutdown
test also does not prove crash durability. Whether an HTTP success acknowledges
durable storage is an application policy. A useful regression test updates state,
stops immediately, restarts, and verifies the update without waiting for the
periodic-save interval.
