# docs/ — GitHub Pages site (E41_S13)

This directory is the source for Jenga AI's GitHub Pages documentation site,
built natively by GitHub from `docs/` on the `main` branch (no separate
`gh-pages` branch, no custom CI build step, no `Gemfile`).

This README is a maintainer-facing note. It is not part of the rendered
Jekyll site (it has no front matter, so Jekyll does not process it as a
page).

## Source-of-truth decision (E41_S13_T01)

This site is **restructured from** the existing wiki mirror:
- `project/.wiki/documentation.md`
- `project/.wiki/intro-guide.md`
- `project/.wiki/concepts/*.md`

It does **not** supersede the wiki. The wiki remains the canonical,
`doc-sync`-maintained mirror and stays in sync going forward; this site is a
navigable, styled presentation layer over the same underlying content,
reorganized into multiple linked pages instead of one long scrollable file.

Rationale: lower risk for a first iteration — the wiki keeps working as a
fallback while the new site proves itself. This can be revisited later if
the site fully replaces the wiki as the documentation entry point.

## Tooling decision (E41_S13_T01)

GitHub's built-in Jekyll support, theme `minima` (Jekyll's own default
theme, natively supported by GitHub Pages). Chosen over a `pages-themes/*`
theme (e.g. Cayman, the originally-considered default) because `minima`'s
default layout actually renders a header navigation bar sourced from
`header_pages` in `_config.yml` — most `pages-themes/*` themes, including
Cayman, ship with no navigation bar at all, which would not satisfy "genuinely
navigable, multiple linked pages" without hand-writing a custom
layout/include.

No `Gemfile`, no custom build pipeline — GitHub Pages builds this
automatically on every push to `main`.

## `docs/` predates this site — pre-existing files are excluded, not moved

`docs/` was already this repo's home for internal/engineering reference
docs (`JENGA_PROTOCOL.md`, `STRATEGY.md`, `api-contract.md`,
`distribution.md`, `hook-parity.md`, `jenga-config.md`,
`skill-authoring.md`) before E41_S13_T01 scaffolded the Pages site into the
same directory. None of those files carry Jekyll front matter, and their
`docs/<name>.md` paths are referenced throughout the repo (`CLAUDE.md`,
`AGENTS.md`, `README.md`, many `skills/*/SKILL.md` files) — moving them
would be a much larger, cross-cutting change out of scope for this story.
Instead, `_config.yml`'s `exclude:` list keeps Jekyll from building them
into the published site at all, while leaving every existing reference to
them intact. If a future doc gets added to `docs/` that isn't meant to be
part of the Pages site, add it to that `exclude:` list too.

## Structure

- `_config.yml` — Jekyll config: theme, title, description, `header_pages` nav
- `index.md` — landing page (hand-authored, not script-generated)
- `getting-started.md` — ported from `intro-guide.md`
- `concepts.md` — ported from `concepts/*.md` (all 7 files, one section each)
- `skills.md` — ported from `documentation.md`'s "Skills" section
- `agents.md` — ported from `documentation.md`'s "Agents" section
- `hooks.md` — ported from `documentation.md`'s "Hooks" section
- `mcp-tools.md` — ported from `documentation.md`'s "MCP Tools" section
- `reference.md` — index page linking to skills/agents/hooks/mcp-tools.md,
  plus `documentation.md`'s "Directory Structure" and "Agent Communication
  Contract" sections

## Content conversion & sync (E41_S13_T02)

`scripts/build-pages-site.sh` (repo root) generates `getting-started.md`,
`concepts.md`, `skills.md`, `agents.md`, `hooks.md`, `mcp-tools.md`, and
`reference.md` from `project/.wiki/*` — deterministically, safe to re-run at
any time, and it always fully overwrites those seven files. **Do not
hand-edit them directly** — edit the wiki source and re-run the script
instead. `_config.yml` and `index.md` are hand-authored and untouched by the
script.

**Re-run this script whenever `project/.wiki/documentation.md`,
`project/.wiki/intro-guide.md`, or `project/.wiki/concepts/*.md` change** —
most commonly right after `j.doc-sync` updates the wiki, per
`skills/doc-sync/SKILL.md`'s pointer to this script. This is the concrete
mechanism behind the "keep both in sync" half of the source-of-truth
decision above.

```bash
scripts/build-pages-site.sh
```

**Known limitation:** the script is a structural transform, not a
fact-checker — it faithfully ports whatever `project/.wiki/documentation.md`
currently says, including that file's own pre-existing staleness (e.g. it
documents roughly 30 skills under the old bare `/<name>` invocation form,
not the full current `skills/` set including `j-<name>` twins). Bringing the
wiki itself up to date is `doc-sync`'s job, not this script's.

`README.md`'s documentation links get updated to the published Pages URL in
`E41_S13_T03`. Live verification and `package.json`'s `homepage` field
consideration happen in `E41_S13_T04`.
