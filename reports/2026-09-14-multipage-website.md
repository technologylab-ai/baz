# Multipage website — 14 September 2026

The former landing document is now a compact overview and six topic pages:
Get started, Design, Examples, Performance, Roadmap, and Guides. Shared navigation
identifies the current page and connects the reader to the same directory.
Longer topic pages provide local section links. Streaming remains a prominent
landing-page feature and opens its maintained example directly.

## Content preservation

The [website maintenance guide](../docs/WEBSITE.md#page-organization) maps every
former chapter to its new page. All technical paragraphs, code samples, tables,
diagrams, benchmark profiles, evidence links, and guide entries are retained.
The repetitive facts and principle cards are consolidated into feature summaries
and the App, raw-data, and ownership explanations; lifecycle ownership and the
literal `files[]` name are explicitly retained in those detailed sections.
Repeated decorative page headings are consolidated into each page's title.
The original benchmark receipts, all 26 example sources, and all guide content
other than the website-maintenance instructions remain unchanged.

Original section bookmarks redirect to their destination without adding an extra
history entry. Without JavaScript, a fallback directory preserves access to those
sections, mobile navigation stays visible, all examples remain available, and
Get started displays all three maintained code excerpts. New links point directly
to the new pages. Unknown fragments leave the overview in place.

## Verification

Development tree based on `a35216011ba935fb81f88049befa33b202475f9a`, branch
`docs/multipage-site`. The [source manifest](2026-09-14-multipage-website/source.sha256.json)
records the reviewed website inputs. No Zig, engine, or runtime-test inputs changed;
these results qualify the website only.

- `python3 tools/build_pages.py`: passed. Eight HTML entry points, 108 unchanged
  copied documents, complete guide coverage, all links and anchors, SVG names,
  all 26 examples, four original benchmark profiles, and publication inventory.
- JavaScript syntax checks passed for the site, reader, Zig highlighter, generated
  legacy-link script, and browser harness. `git diff --check` passed.
- Headless Chrome `152.0.7977.83`, native macOS `26.6.2` (`25G83`), arm64:
  **22 browser groups passed**, with the screen locked. The local URL used the
  `/baz/` project prefix. [Browser receipt](2026-09-14-multipage-website/receipt.json).
- All seven pages passed overflow and current-navigation checks at widths 320,
  390, 760, 820, and 1440. All 108 reader documents rendered. Keyboard tabs,
  repeated deep links, mobile menu/Escape, skip links, filters, print output,
  12 former section bookmarks, unknown fragments, rejected reader paths, and
  Markdown sanitization passed. No unexpected external requests or JS exceptions.
- At 390 × 844, the overview is about three viewport heights. Full catalogs,
  technical chapters, and benchmark details are reached through their own pages.

The initial run found a browser-test selector that matched the new off-screen
section-navigation link; the check now scrolls to and clicks the intended link
inside the App example. The final run includes the heading hierarchy and unknown
fragment fixes. Desktop and mobile screenshots were visually reviewed; screenshots
and print output remain in the worktree's ignored `.zig-cache/multipage-qa-reviewed/`.

The shared host reservation was acquired atomically after checking for competing
measurement processes. A 240-second external watchdog bounded the suite; the
browser and preview-server children stopped before the owner released its lock.
[Environment](2026-09-14-multipage-website/context.json) ·
[Cleanup](2026-09-14-multipage-website/cleanup.json).
No deployment or new framework performance measurement was performed.
