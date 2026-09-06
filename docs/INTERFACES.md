# Baz module contracts

Use exact Zig 0.16.0.
The public `baz` module exports App, Request, Response, response limits, and parsing helpers.
The [API guide](APP-API.md) describes those contracts.
The [ownership guide](OWNERSHIP.md) describes their lifetimes.

Baz imports the external `bounded_http` module.
`baz.engine` exposes that same module.
The build also exports `bounded_http` for consumers that need both interfaces.
The independent [consumer fixture](../examples/embedding/src/main.zig) verifies shared engine type identity.

The engine's [module contracts](https://github.com/technologylab-ai/bounded-http/blob/main/docs/INTERFACES.md)
describe its parser, scheduler, and transport interfaces.
See its [documentation website](https://technologylab-ai.github.io/bounded-http/) for the architecture and embedding guide.

Keep engine changes in the [engine repository](https://github.com/technologylab-ai/bounded-http).
Baz uses checked draft methods instead of accessing writer lifecycle fields.
The [dependency guide](DEPENDENCY.md) describes that boundary.
