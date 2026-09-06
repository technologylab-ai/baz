# Baz website handoff — 2026-09-06

The user requested a beautiful, helpful Baz page with bounded/http's visual style.
The user then stopped this work because the request reached the wrong session.
Resume website work in the user's intended Baz session.
This document records preparation only; no Baz website was implemented.

## Repository and worktree

- Canonical checkout: `/Users/rs/code/github.com/technologylab.ai/baz`.
- Canonical branch: `main`, commit `d62fee76a2f2f3f8fe9bd4b831a7905241b381b1`.
- Website worktree: `/Users/rs/code/github.com/technologylab.ai/baz-website`.
- Website branch: `docs/website`, created from that exact main commit.
- No Git remote was configured during inspection.
- No GitHub repository, Pages deployment, or website preview server was created.
- No `.openai/hosting.json` was present.

The canonical checkout contained another session's preparation changes at first inspection.
The final inspection found clean `main` at the commit above.
This session did not change, stage, discard, or commit those preparation changes.
This session created the isolated website worktree and this handoff.

The local `work/windows-update` branch belongs to the paused Baz Windows effort.
Its provisional engine revision is `bb14d98756152936fadb6e8353852a686e8d315d`.
That draft is separate from the website branch.
Read the canonical [handoff](../baz/HANDOFF.md) before resuming dependency or Windows work.

## Design reference already inspected

Reference: <https://technologylab-ai.github.io/bounded-http/>.
Canonical source: `../bounded-http/docs/whitepaper.template.html`.
Generated source: `../bounded-http/docs/whitepaper.html`.
Canonical diagrams: `../bounded-http/docs/diagrams/`.

The page uses an ivory background, navy text, orange accents, and fine grey rules.
Large serif headings contrast with compact monospace labels.
A fixed navigation rail provides section links and platform scope.
Embedded SVG diagrams explain ownership and architecture.
Its Markdown reader supplies navigation, syntax highlighting, and source links.
The generated whitepaper works offline and supports printing.

Local reference artifacts remain under `.zig-cache/reference/` in this worktree:

- `whitepaper-desktop.png`: captured desktop view at 1440 × 1040.
- `receipt.json`: browser identity and the completed reference check.
- `inspect.mjs`: the local reference inspection script.

These ignored artifacts are local preparation, not published evidence.
Chrome `152.0.7977.76` rendered the published reference successfully.
The reference check confirmed branding, byline, heading, and six SVGs.
The browser recorded no JavaScript exceptions.
The connected browser plugin was unavailable; a separate headless browser captured the reference.
That browser exited, and this session released its Mac reservation.
No Baz runtime or benchmark was executed.

## Source-backed website content

Suggested positioning: **Baz — Bounded Async Zap. Typed Zig applications on bounded/http.**
Baz owns application ergonomics; bounded/http owns the HTTP engine.
Keep both packages independently understandable.

Use these existing sources when writing the page:

| Topic | Source and scope |
| --- | --- |
| Public package | `src/web.zig` exports App, request views, responses, and parsers. |
| Working example | `src/app_demo.zig` includes `Hello.get`, borrowed query access, explicit decoding, and copied response output. |
| Quickstart | `docs/APP-API.md` and `README.md` document exact Zig 0.16.0 commands. |
| Ownership | `docs/APP-API.md` explains retained input and callback-scoped application access. |
| Decoding | `src/params.zig` preserves query `+`; form decoding converts `+` into a space. |
| Forms and uploads | Preserve ordered duplicates and literal bracket names; multipart returns flat borrowed parts. |
| Responses | Secure bounded output capacity before dispatch; one-shot handlers construct private drafts. |
| Examples | `examples/README.md` catalogs 20 examples and their source files. |
| Engine boundary | `docs/DEPENDENCY.md` records the pinned external `bounded_http` dependency. |
| Remaining work | `docs/APP-API-ROADMAP.md` distinguishes implemented and proposed APIs. |

The existing quickstart is:

```sh
zig build run-app -Doptimize=ReleaseSafe -- --port 8080
curl 'http://127.0.0.1:8080/hello?name=Hello%20Zig'
curl --data 'value=x+y%2Bz' http://127.0.0.1:8080/form
curl -F 'files[]=@.zig-version' http://127.0.0.1:8080/upload
```

Link code demonstrations to maintained, compiled examples.
Organize examples by greeting/routing, responses/assets, App/endpoints, composition/authentication, and parameters/uploads.
Explain middleware, authentication, and cookie helpers as example-local implementations.
Do not present those helpers as completed public composition APIs.

Multipart parsing validates the complete body and never implicitly saves uploads.
Segmented bodies require explicit copying when a contiguous representation is needed.
Do not describe all request or response handling as zero-copy.

## Performance scope

Use `reports/2026-09-06-basic-zap.md` as the performance source.
The recorded Baz prototype is `c152e59`, before package extraction.

| Host / connections | Baz median requests/s | Zap median requests/s | Ratio |
| --- | ---: | ---: | ---: |
| Mac / 32 | 254,261 | 245,054 | 1.038× |
| Linux / 32 | 363,594 | 205,310 | 1.771× |
| Mac / 1 | 33,199 | 52,809 | 0.629× |
| Linux / 1 | 74,386 | 72,575 | 1.025× |

Each profile used three paired trials and three-second measurements.
Both implementations used ReleaseSafe, same-host loopback, and no pipelining.
Preserve the report's exact environments, protocol, ranges, and limitations.
These results establish neither framework overhead nor production capacity.
Do not substitute bounded/http's engine benchmark figures for Baz measurements.

## Boundaries and next steps

Baz's current verified baseline covers macOS and Linux.
The current main engine pin is `e52f09f723388685263d14a9bfa265f2456a3744`.
Baz has no native Windows runtime qualification in the inspected receipts.
An engine Windows gate does not qualify Baz automatically.

Public middleware composition and typed resumable endpoints remain future API work.
TLS, WebSockets, Mustache integration, and an owned `std.Io` provider are not completed features.
The reference `hello` example retains historical greeting text; avoid copying that text into the page heading.

The receiving session should confirm repository state before implementation.
Build the page, useful diagrams, and a browser Markdown reader with syntax highlighting.
Reuse the reference's visual language while writing Baz-specific content.
Test desktop, mobile, navigation, keyboard access, printing, and rendered documentation links.
Prepare publication files for Baz's own repository.
Do not create a remote or publish based solely on this handoff.
Reconfirm publication authorization from the user's intended session.

The Windows engine PR remains owned by the separate bounded/http session.
Its candidate branch is `feat/windows-shards` in `../bounded-http-windows-shards`.
No Baz agent, build, browser, or remote runner remains active from this preparation.
