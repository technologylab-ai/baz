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

The separate Windows dependency update remains paused. Read [HANDOFF.md](HANDOFF.md)
before resuming runtime or dependency work. The website changes do not qualify
Baz on Windows or change its tested engine pin.
