# bounded/http engine reference

Baz uses [bounded/http](https://github.com/technologylab-ai/bounded-http) as its HTTP engine.
The engine has its own repository and [GitHub Pages documentation](https://technologylab-ai.github.io/bounded-http/).

Use the engine's [embedding guide](https://github.com/technologylab-ai/bounded-http/blob/main/docs/USING.md)
for low-level callbacks, continuation state, startup, shutdown, and configuration.
Its [architecture guide](https://github.com/technologylab-ai/bounded-http/blob/main/docs/ARCHITECTURE.md)
explains shards, output arenas, operation ownership, and resource accounting.
Its [ownership contract](https://github.com/technologylab-ai/bounded-http/blob/main/docs/OWNERSHIP.md)
defines borrowed storage and terminal completion.

[build.zig.zon](../build.zig.zon) pins the engine package.
[DEPENDENCY.md](DEPENDENCY.md) records Baz's use of that dependency.
The website follows the engine's published branch; the package pin identifies the code that Baz actually uses.

The engine remains independently usable.
Its executable, parser, scheduler, transports, and core verification suites live upstream.
Baz owns App composition, routing, request conveniences, response drafts, and application examples.

Start with [Baz's README](../README.md) and [API guide](APP-API.md) for the framework.
