# Baz’s GitHub Pages site

The site belongs to the [Baz repository](https://github.com/technologylab-ai/baz),
and publishes at <https://technologylab-ai.github.io/baz/>.
It shares the visual language of the [bounded/http engineering paper](https://technologylab-ai.github.io/bounded-http/):
ivory, navy, orange, serif headings, a navigation rail, and ownership diagrams.
The landing-page narrative, diagrams, examples, and measurements are specific to Baz.

## Build and preview

Use Python 3; no Node package installation or network fetch is needed to build:

```sh
python3 tools/build_pages.py
python3 -m http.server 8081 --bind 127.0.0.1 --directory .zig-cache/github-pages
```

Open `http://127.0.0.1:8081/`. Stop the preview with Ctrl-C.
The generated artifact is ignored and can be recreated from the repository.
The landing page also opens from disk, with its local styles, diagrams, and code.
The Markdown reader uses `fetch`, so preview it over HTTP.

The [Pages workflow](../.github/workflows/pages.yml) builds and checks pull requests.
Pushes to Baz’s `main` deploy the artifact through GitHub Actions.
The `github-pages` environment carries the deployment URL.
The website worktree is only a branch of Baz, not another project or repository.

## Source of truth

| Content | Maintained source |
| --- | --- |
| Landing-page prose | [index.template.html](index.template.html) |
| App excerpt | `Hello` in [app_demo.zig](../src/app_demo.zig), extracted at build time |
| Streaming excerpt | `progress` in [streaming.zig](../examples/streaming.zig), extracted at build time |
| File-from-memory handler | App types and complete `index` handler in [serve.zig](../examples/serve.zig), extracted from the compiled example; the separate 5 MiB fixture backs the large-body evidence |
| Example cards | The catalog in [build_pages.py](../tools/build_pages.py), linked to all 21 compiled examples |
| Benchmark chart and table | Original [Mac](../reports/2026-09-06-basic-zap/macos-summary.json) and [Linux](../reports/2026-09-06-basic-zap/linux-summary.json) summaries; medians checked against recorded trial rates |
| Diagrams | [Raw parameters](diagrams/parameters.svg), [package boundary](diagrams/layers.svg), [response lifetime](diagrams/lifetime.svg) |
| Reader content | Repository Markdown and source files, copied unchanged from an explicit allowlist |

The benchmark narrative identifies prototype `c152e59`, before package extraction,
and links the complete report. Do not replace it with engine measurements or
rerun performance tests for a website edit. All timing, including warmups,
requires ReleaseSafe with assertions.

The artifact’s `publication.json` records its Git revision and every other
file’s SHA-256. Reader source links use that exact revision. Documents excluded
from the Pages allowlist, such as large raw evidence files, link to GitHub.
The `.zig-version` document is served through `docs/zig-version.txt` because
Pages hides dot-prefixed paths; its reader identity and GitHub source stay canonical.
The artifact’s `.nojekyll` control file is not a public document.
The artifact includes no Git object store, caches, temporary browser profiles,
or benchmark archives.

## Reader and accessibility

The reader validates an allowlisted path before URL normalization, sanitizes
Markdown in a detached fragment, and resolves links before attaching content.
Source code is rendered as text. Scripts, event handlers, forms, embedded
frames, arbitrary images, and active URL schemes are not document capabilities.
A restrictive Content Security Policy supplies a second boundary.

The reader includes a heading table of contents, raw and GitHub links, syntax
highlighting, code copy buttons, and print styles. Mobile menus support Escape;
skip links and scrollable code, table, and diagram regions support keyboards.
The landing page shows App, streaming, and file-response excerpts without JavaScript.
With JavaScript, keyboard-accessible tabs select the excerpt; `#streaming` and
`#borrowed` open their options directly. Print output includes all three. Example filtering is optional.
System fonts and local browser libraries avoid third-party asset requests.

Browser dependencies are vendored with their original notices and checksums:

- marked 18.0.11: [MIT notice](vendor/marked-LICENSE).
- highlight.js 11.12.0: [BSD 3-Clause notice](vendor/highlight-LICENSE).
- DOMPurify 3.4.15: [Apache-2.0](vendor/purify-LICENSE) or [MPL-2.0](vendor/purify-LICENSE-MPL).

[The vendor manifest](vendor/manifest.json) preserves archive URLs, package
integrity strings, source revisions, and file hashes. The build verifies them.
These assets came from the existing [bounded/http](https://technologylab-ai.github.io/bounded-http/) documentation bundle.
Their licenses remain separate from Baz’s MIT license.

## Verification

`build_pages.py` runs [static checks](../tools/check_site.py) for artifact links,
anchors, accessible SVG names, example count, all four performance profiles,
allowlist contents, and unchanged copied documents. The workflow also checks
the authored JavaScript syntax.

The optional [Chromium browser checks](../tools/check_site_browser.mjs) exercise
desktop/mobile layouts, keyboard navigation, filters, reader fragments,
all published documents, rejected paths, sanitized Markdown, printing, and
the landing page without JavaScript. It uses a fresh temporary browser profile.

```sh
node tools/check_site_browser.mjs http://127.0.0.1:8081/ .zig-cache/website-qa
```

Set `BROWSER` to a Chromium executable if needed. On the shared Mac or Linux
host, acquire the cooperative measurement reservation described in [AGENTS.md](../AGENTS.md)
before browser suites. Apply a finite external watchdog, retain the reservation
through browser and server cleanup, and remove only your own lock.
Cross-width browser checks qualify the website layout; they are not Baz HTTP
runtime or performance evidence. Windows platform claims are backed by [Baz’s native receipt](../reports/2026-09-06-windows-baz.md).
