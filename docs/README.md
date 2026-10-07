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

## Maintainer-internal documents live in `project/documentation/`

`docs/` used to double as this repo's home for internal engineering documents. `E34_S06` moved
them to `project/documentation/` (the `documentation` path in `project/configs/workflow.json`),
leaving here only what the Pages site publishes. The classification and the move targets are in
"Contents by audience" below. `_config.yml`'s `exclude:` list now names only the one file that
sits here without being rendered as a page (`jenga-config.md`); `STRATEGY.md` was moved out by
`E34_S07` (see "STRATEGY.md placement" below).

## Where documentation goes

- **`docs/` holds only content meant for the published GitHub Pages site.**
- **Maintainer-internal documentation** (design notes, mirror and distribution rules, protocol and parity
  docs, decision records, execution plans and summaries) lives under **`project/documentation/`**, the
  `documentation` path in [`project/configs/workflow.json`](../project/configs/workflow.json).
- One-line test: *would someone who only installed the package want to read this?* If not, it is internal.
- There is no exception: the strategy brief is an ordinary `project/documentation/` file (see "STRATEGY.md placement" below).

The same rule is stated in `CLAUDE.md` under "Documentation Placement".

## Contents by audience

Classification of every file under `docs/` (E34_S06_T01, audited 2026-10-02). Test applied: would
someone who only installed the package, or reads the published Pages site, want this? Evidence is
what the repo shows, not the file name.

- **Pages evidence:** `_config.yml` `header_pages` lists getting-started, concepts and reference;
  `index.md` links those three, and `reference.md` links skills, agents, hooks and mcp-tools.
  `scripts/build-pages-site.sh` generates those seven pages. Jekyll's `exclude:` list (as of this
  audit) names only `JENGA_PROTOCOL.md`, `STRATEGY.md`, `api-contract.md`, `distribution.md`,
  `hook-parity.md`, `jenga-config.md`, `skill-authoring.md`. Every `.md` file here that carries no
  front matter and is not excluded is copied into the built site as a raw static file.
- **Reference counts** are files, not hits. *Live* = skills, agents, scripts, hooks, lib, templates,
  tests, `.publicignore`, `package.json`, root docs and other docs, excluding the generated
  `.claude/`/`.agents/` mirrors and `project/knowledge-graph/graph.json`. *Historical* = board items,
  rapports, logs, queue, execution plans and summaries, `todo.md`, instructions and data records,
  which describe what was true at the time and are never rewritten.
- `package.json` `files` ships none of `docs/`; the public mirror ships all of it, because
  `.publicignore` blocks none of it.

| File | Audience | Evidence | Refs live / historical | Disposition |
|---|---|---|---|---|
| `_config.yml` | published-site | Jekyll config for the Pages build | 1 / 9 | keep |
| `README.md` | maintainer note about `docs/` itself | No front matter, so not rendered; linked from `_config.yml` and `index.md` comments | 4 / 11 | keep |
| `index.md` | published-site | Landing page; hand-authored | 1 / 7 | keep |
| `getting-started.md` | published-site | `header_pages`; linked from `index.md`; generated by `build-pages-site.sh` | 2 / 21 | keep |
| `concepts.md` | published-site | `header_pages`; linked from `index.md`; generated | 2 / 6 | keep |
| `reference.md` | published-site | `header_pages`; linked from `index.md`; generated | 2 / 10 | keep |
| `skills.md` | published-site | Linked from `reference.md`; generated | 3 / 23 | keep |
| `agents.md` | published-site | Linked from `reference.md`; generated | 2 / 4 | keep |
| `hooks.md` | published-site | Linked from `reference.md`; generated | 2 / 2 | keep |
| `mcp-tools.md` | published-site | Linked from `reference.md`; generated | 3 / 5 | keep |
| `preflight-checklists.md` | published-site | Consumer authoring reference for the pre-flight checklist feature (`E67_S06_T01`); has Jekyll front matter (`layout: page`, `permalink: /preflight-checklists.html`) so it renders as a page; hand-authored, not produced by `scripts/build-pages-site.sh`; linked from `index.md` and the root `README.md`. Its maintainer-internal counterpart is `project/documentation/preflight-checklists.md`, which it links to rather than copies | n/a | keep |
| `jenga-config.md` | published-site (consumer reference, not yet wired into the nav) | Documents `jenga.cli.json`, which `lib/config-schema.js` reads and `jenga init` scaffolds into consumer projects; in `exclude:` and linked from nowhere | 0 / 11 | keep; navigation wiring is out of scope here |
| `STRATEGY.md` | stakeholder deliverable; consumer-scaffolded | `/init` scaffolded `docs/STRATEGY.md` into every consumer project (`skills/j-init/scripts/init.sh` step 9, `tests/init.bats`); `/strategy` reads and writes the same path; in `exclude:`; this repo's own copy is an investor brief | 13 / 34 | audited as keep in E34_S06_T03, reversed by E34_S07: moved to `project/documentation/STRATEGY.md`; see "STRATEGY.md placement" below |
| `skill-authoring.md` | maintainer-internal | Contributor guide to the skill contract; in `exclude:`; not linked from `index.md` or the README; cited by `CLAUDE.md`, `AGENTS.md` and framework-authoring preambles, not by anything a consumer runs | 73 / 195 | move to `project/documentation/skill-authoring.md` |
| `public-mirror-content-parity.md` | maintainer-internal | Rules for the private-to-public mirror; cited by `.publicignore` comments, `mirror.sh` and mirror tests; not in `exclude:`, so currently built into the site as a raw file | 6 / 43 | move to `project/documentation/public-mirror-content-parity.md` |
| `distribution.md` | maintainer-internal | Install and mirror mechanics (590 lines, includes packaging decisions); cited by `postinstall.js`, `doctor.js`, `.npmignore` comments; the README links one prerequisite anchor; in `exclude:` | 8 / 31 | move to `project/documentation/distribution.md`; README anchor link retargeted |
| `hook-parity.md` | maintainer-internal | Claude Code to Copilot hook mapping with correction history; cited by `hooks/copilot_session_end.sh` and the Copilot instructions template; in `exclude:` | 2 / 22 | move to `project/documentation/hook-parity.md` |
| `JENGA_PROTOCOL.md` | maintainer-internal | Router completion-signal protocol for skill and router authors; in `exclude:`; no live reference | 0 / 1 | move to `project/documentation/JENGA_PROTOCOL.md` |
| `api-contract.md` | maintainer-internal | Dashboard API conventions for developers of `project/app/api`; in `exclude:`; no live reference | 0 / 11 | move to `project/documentation/api-contract.md` |
| `service-descriptor.md` | maintainer-internal | Authoring format for `j.connect` descriptors; cited by `skills/j-connect/` scripts and tests; not in `exclude:` | 6 / 25 | move to `project/documentation/service-descriptor.md` |
| `mcp-registration-decision.md` | maintainer-internal | Decision record (`E65_S01_T01`); cited by `attach.js`, `register-mcp.sh` and tests; not in `exclude:` | 9 / 13 | move to `project/documentation/mcp-registration-decision.md` |
| `digitalocean-connect-research.md` | maintainer-internal | Dated research note feeding one descriptor (`E65_S05_T01`); cited by a descriptor, an adapter and tests; not in `exclude:` | 4 / 5 | move to `project/documentation/digitalocean-connect-research.md` |
| `supabase-connect-research.md` | maintainer-internal | Dated research note feeding one descriptor (`E65_S04_T01`); cited by a descriptor and tests; not in `exclude:` | 3 / 6 | move to `project/documentation/supabase-connect-research.md` |
| `figma-expo-connect-research.md` | maintainer-internal | Dated research note feeding the Figma and Expo descriptors (`E65_S06_T01`); cited by two descriptors and four tests; not in `exclude:`; missed by the original T01 audit and moved afterwards | n/a | move to `project/documentation/figma-expo-connect-research.md` |

## STRATEGY.md placement (E34_S07, reverses E34_S06_T03)

`STRATEGY.md` lives at `project/documentation/STRATEGY.md`, the default of `paths.strategy`, for consumer
projects and for this repo. It is an ordinary `project/documentation/` file; `docs/` holds only
published-site content, and `/init` creates no `docs/` directory.

**Decision reversed.** `E34_S06_T03` had kept the brief under `docs/` as a stakeholder deliverable, so that
it stayed committed when a consumer sets `project_files_visibility: ignored` (which gitignores everything
under `project/`). On 2026-10-03 the user reversed that: choosing to ignore Jenga's files should ignore the
strategy brief with the rest, and the cost E34_S06_T03 was avoiding is accepted. A consumer who wants the
brief committed keeps `visible` (the default) or points `paths.strategy` at a tracked path.
`tests/strategy-visibility.bats` asserts the behaviour against the real
`skills/j-init/scripts/apply-project-visibility.sh`. The file is not blocklisted by `.publicignore`
(which lists only `project/documentation/plans/` and `summaries/`), so this repo's brief is still mirrored
publicly, and the dashboard's documentation parser (`project/app/api/parsers/documentation.js`) reads it
from the new location.

`/init` and `/strategy` resolve the path through `scripts/strategy_path_resolver.sh`, which reads
`paths.strategy` from `project/configs/workflow.json` (default `project/documentation/STRATEGY.md`).

**Existing consumers.** The resolver keeps a legacy fallback: with no file at the configured path and an
existing `docs/STRATEGY.md`, it returns `docs/STRATEGY.md`, so `/strategy` updates that file in place and
nothing is orphaned or duplicated. Nothing is migrated automatically; Jenga never moves a user's file
unasked. A consumer who wants the new location moves the file themselves:

```
git mv docs/STRATEGY.md project/documentation/STRATEGY.md
```

after which the resolver returns the configured path. A consumer's own `workflow.json` that still says
`paths.strategy: docs/STRATEGY.md` keeps working unchanged. Under `ignored`, a brief left at
`docs/STRATEGY.md` is not ignored, since only `project/` is a working path.

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
- `preflight-checklists.md` — hand-authored authoring reference for the pre-flight checklist feature
  (not generated; `build-pages-site.sh` does not touch it)

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
