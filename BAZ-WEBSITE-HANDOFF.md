# Baz website handoff — integrated into Baz

The transferred preparation is preserved in commit `99729c3` on `docs/website`.
That preparation contained no website. The intended Baz session implemented the
site and integrated it into Baz’s `main`, as requested by the user.

- Repository: <https://github.com/technologylab-ai/baz>.
- GitHub Pages: <https://technologylab-ai.github.io/baz/>.
- Canonical local checkout: `/Users/rs/code/github.com/technologylab.ai/baz`.
- Website working directory: a linked Baz worktree at `../baz-website`, not a separate repository.
- [Website maintenance](docs/WEBSITE.md) records templates, diagrams, reader,
  local preview, browser libraries/licenses, checks, and publishing.
- [Verification receipt](reports/2026-09-06-website.md) records local browser checks.

The page uses bounded/http’s visual language with Baz-specific narrative,
maintained example source, four SVG diagrams/charts, 20 example links, and the
original Zap comparison. All original benchmark receipts remain unchanged.
README and guides link both Baz’s site and bounded/http’s repository/Pages site.

The user explicitly authorized publication in the intended session. Website
source and the Pages workflow belong to Baz’s `main`; Pages deploys from there.
The generated artifact records its exact publication revision.

The Windows dependency update subsequently passed Baz’s own native x64 Windows,
Linux, and macOS gates. Read [HANDOFF.md](HANDOFF.md) and the
[native receipt](reports/2026-09-06-windows-baz.md) for source identity and scope.
The site prominently identifies pure Zig implementation, Windows support,
and the bounded/http website link.
