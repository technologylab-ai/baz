# All guides

Look up types, functions, and their source in the [generated API reference](https://technologylab-ai.github.io/baz/api/).
Choose a guide by what you want to do. Start with the API guide for your first
App, or explore a complete example to see the pieces working together.

## Build an application

- [Application API](APP-API.md) — Compose an App and handle requests and responses, with notes for Zap users.
- [Application recipes](APPLICATION-RECIPES.md) — Bind to the LAN, download runtime files, decode fields, and customize errors.
- [Runnable examples](../examples/README.md) — Choose a small example and run it locally.
- [Mustache templates](MUSTACHE.md) — Render HTML from startup-owned templates and typed data.
- [Cookies, redirects, and sessions](COOKIES.md) — Read cookies, choose expiry and scope, and manage session lifetimes.
- [Middleware and request locals](MIDDLEWARE.md) — Share authentication and other request work through ordered hooks.

## Send live updates

- [Streaming responses](STREAMING.md) — Write and flush a response incrementally through a standard Zig writer.
- [Typed continuations](CONTINUATIONS.md) — Keep many streams waiting while releasing the executor between steps.
- [Server-sent events and notifications](SSE.md) — Encode events and wake waiting requests with bounded messages.
- [A complete live-job application](JOBS.md) — Put templates, authentication, background jobs, and live progress together.

## Understand capacity

- [Limits and backpressure](LIMITS.md) — Understand connection admission, worker capacity, slow readers, and rejection.
- [Connection-limit walkthrough: two slots, three clients](CONNECTION-LIMIT-WALKTHROUGH.md) — Fill the slots yourself, observe rejection, and release a slot to recover.
- [Pipelining and browser downloads](PIPELINING.md) — Understand ordered HTTP/1.1 requests and parallel asset downloads.
- [Ownership contract](OWNERSHIP.md) — Know how long borrowed input, response storage, and application state remain valid.

## Go deeper

- [Packages and embedding](DEPENDENCY.md) — Understand the framework and engine boundary and consume Baz as a package.
- [Module contracts](INTERFACES.md) — Find the responsibilities and interfaces of Baz's modules.
- [Engine reference](ENGINE-REFERENCE.md) — Find the engine's source, architecture, and ownership contracts.
- [The std.Io decision](STD-IO-DECISION.md) — Read the reasoning behind caller-supplied I/O and fixed workers.
- [API design and predecessor analysis](APP-API-DESIGN.md) — Explore the design rationale and the original implementation plan.
- [Roadmap and implementation ledger](APP-API-ROADMAP.md) — Follow milestones, verification gates, and recorded implementation work.
- [Evidence and verification](EVIDENCE.md) — Find source inputs and native integration receipts.
- [Repository history and publication](REPOSITORY.md) — Understand the standalone repository, branches, and CI.
- [Website maintenance](WEBSITE.md) — Build, preview, check, and publish this documentation site.
- [Mustache selection](MUSTACHE-CANDIDATES.md) — Read the comparison behind the template dependency choice.
- [Streaming across three platforms](../reports/2026-09-06-streaming.md) — Inspect the recorded Windows, Linux, and macOS verification.
- [bounded/http](https://technologylab-ai.github.io/bounded-http/) — Read the engine's engineering paper and documentation.
