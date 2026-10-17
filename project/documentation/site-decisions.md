# Jenga's GitHub Pages site — decisions and structure

**Provenance:** converted from `docs/README.md` by `E70_S02_T01` (epic `E70`, decision 6). That file was
a maintainer-facing note that lived inside the site source directory without being part of the rendered
site — it carried no Jekyll front matter, so Jekyll never processed it as a page. The site source itself
moved from `docs/` to `site/` in `E70_S02_T02`; this document is its decision record and is
maintainer-internal, so it lives under `project/documentation/` per the placement rule below.

The site source is `site/` — `site/index.md`, `site/_config.yml`, `site/guides/` and `site/reference/`.
`docs/` is no longer Jenga's site directory and this repo keeps no `docs/` directory at all.

**Count:** `site/` holds **11 site pages** — 10 rendered markdown pages plus Jekyll's own
`_config.yml`. (Pre-move the rendered count was 9: `jenga-config.md` had no front matter and was
Jekyll-`exclude`d, so it published nowhere until `E70_S02_T02` gave it front matter and a nav entry.)
Earlier epic and story prose quoted a figure of twelve, counting `docs/README.md` — this file — as a
site page. It never was one: it carried no front matter, so Jekyll never rendered it. The honest
figure is 11 site pages, and that is the figure to carry forward.

---

## What was dropped in the conversion, and why

`docs/README.md`'s **"Contents by audience"** table (24 rows, audited 2026-10-02 under `E34_S06_T01`)
is **dropped, not archived.**

Reason: it was a point-in-time classification of every file that sat under `docs/` on that date, and its
whole purpose was to decide which of those files were published-site content and which were
maintainer-internal. Every row has since been actioned — `E34_S06` and `E34_S07` moved the 11
maintainer-internal files it named into `project/documentation/`, and `E70_S02` moved the remaining
site content into `site/`. Not one of its 24 rows still describes a file at the path it names, so
preserving the table would preserve a map of a directory layout that no longer exists, in the one
document a reader consults to learn the *current* layout. The audit itself remains recoverable from git
history (`docs/README.md` at any commit before `E70_S02_T01`) and from the `E34_S06` board items, which
is the right home for a dated audit.

What the table was *for* survives as the one-line test in "Where documentation goes" below, which is
the durable rule rather than the dated application of it.

Consequence for callers: `CLAUDE.md` and `AGENTS.md` previously ended their placement rule with "The
per-file classification is in `docs/README.md`'s 'Contents by audience'." Since the table is gone, that
claim is dropped rather than retargeted — see `E70_S02_T04`.

---

## Source-of-truth decision (`E41_S13_T01`)

This site is **restructured from** the existing wiki mirror:

- `project/.wiki/documentation.md`
- `project/.wiki/intro-guide.md`
- `project/.wiki/concepts/*.md`

It does **not** supersede the wiki. The wiki remains the canonical, `j.doc-sync`-maintained mirror and
stays in sync going forward; this site is a navigable, styled presentation layer over the same
underlying content, reorganized into multiple linked pages instead of one long scrollable file.

Rationale: lower risk for a first iteration — the wiki keeps working as a fallback while the new site
proves itself. This can be revisited later if the site fully replaces the wiki as the documentation
entry point.

## Tooling decision (`E41_S13_T01`)

GitHub's built-in Jekyll support, theme `minima` (Jekyll's own default theme, natively supported by
GitHub Pages). Chosen over a `pages-themes/*` theme (e.g. Cayman, the originally-considered default)
because `minima`'s default layout actually renders a header navigation bar sourced from `header_pages`
in `_config.yml` — most `pages-themes/*` themes, including Cayman, ship with no navigation bar at all,
which would not satisfy "genuinely navigable, multiple linked pages" without hand-writing a custom
layout/include.

No `Gemfile` and no hand-written build pipeline for the Jekyll build itself.

**Build source (changed by `E70`).** The site was originally built natively by GitHub from `docs/` on
`main`. `site/` is not a directory GitHub Pages can serve in branch mode — branch-based Pages serves
only the repository root or `docs/` — so `E70_S03` moves the build to a GitHub Actions workflow that
runs Jekyll against `site/` and deploys the artifact, and the user flips the repository's Pages source
setting from "branch" to "GitHub Actions". Until that cutover lands, the published site is served from
whatever the branch-mode build last produced.

## Manual cutover (`E70_S03`)

The Pages source of the public `samwelmunga/jenga-npm` repository moves from branch mode (`/docs` on
`main`) to GitHub Actions (`.github/workflows/pages.yml`, which builds `site/`). Nothing in this
repository performs that switch. The user performs it, in this order.

### The order

1. **Flip the Pages source to `workflow`.** Run `scripts/pages-cutover.sh --dry-run` to see the command, then
   `scripts/pages-cutover.sh --execute` to run it. This needs an authenticated `gh` with admin rights on
   `jenga-npm`. The script refuses to run without one of the two flags.
2. **Run the public mirror**, `/j-mirror-public`. Its rsync `--delete` removes `docs/` from the public repo and adds `site/`.
3. **Trigger the workflow** with `workflow_dispatch`, either from the public repo's Actions tab or with
   `gh workflow run pages.yml --repo samwelmunga/jenga-npm`. Confirm the deploy succeeded.

### Failure mode: the mirror runs before the flip

If the mirror runs while Pages is still in branch mode, `rsync --delete` removes `docs/` and the branch-mode
build stops producing the site. The live site goes dark. The workflow cannot recover it on its own: it deploys
only once the source is set to `workflow`, and it needs `site/`, which only the mirror delivers. So the mirror
must never run before the flip.

### Residual dark window

Even in the required order there is a window. After the flip and before a successful `workflow_dispatch`
deploy, the source is `workflow` and nothing new is deployed. It is not verified whether the last branch-mode
build keeps serving during this window, so plan as though the site is dark. Run steps 1 to 3 back to back.

### Every site change needs a manual dispatch

`mirror-staging-gate.yml`'s `promote-main` job pushes to `main` with the default `GITHUB_TOKEN`. GitHub does not
start workflows from pushes made with `GITHUB_TOKEN`, so the `push` trigger in `pages.yml` does not fire after a
gated promotion. Until a follow-up changes the promotion path (for example a PAT, or a `workflow_run` trigger),
run step 3 after each mirror that changes `site/`.

### Rollback

1. **Flip back to branch mode.** Use `gh api -X PUT repos/samwelmunga/jenga-npm/pages -f build_type=legacy`, with
   the source set to branch `main` and path `/docs`. **Unverified:** these legacy-source parameter names have
   not been run against the live API. Check them against the GitHub Pages REST documentation before relying on this.
2. **Restore `docs/` if the mirror already ran.** The mirror's `--delete` removed `docs/` from the public repo,
   so the branch-mode build has nothing to serve until it is back. Restore it with a manual commit to `main`
   that brings back `docs/` from the last pre-mirror commit. The gated promotion is fast-forward only, so this
   cannot be a force push.

### Verification

After step 3, run the permalink check (`E70_S03_T05`) against the live base URL. Every `permalink:` declared in the
`site/` front matter, plus the site root, must return HTTP 200.

## Link form — bare relative `<name>.html`, never root-absolute

Every page declares a **flat, root-level** `permalink: /<name>.html`, so every page is served as a
sibling of every other page regardless of which source subdirectory its file lives in. That is what
made the `docs/` → `site/` move a pure path move: the published URL is a property of the front matter,
not of the file's location.

Two rules follow, and both are enforced by `scripts/check-site-links.sh`:

- **Intra-site links use the bare relative form** `](skills.html)`. Not `](./skills.md)`, not
  `](skills.md)`.
- **A root-absolute `/<name>.html` is wrong and is rejected.** `site/_config.yml` declares no
  `baseurl`, and the site is a GitHub Pages *project* site served under the `/jenga-npm` path prefix,
  so a leading slash drops the prefix and 404s. Do not "tidy" the links into that form.

A page that lives in `site/reference/` still publishes at `/skills.html`, never
`/reference/skills.html`. `tests/site-dir-migration.bats` asserts that no permalink ever gains a
`guides/` or `reference/` segment.

## Maintainer-internal documents live in `project/documentation/`

`docs/` used to double as this repo's home for internal engineering documents. `E34_S06` moved them to
`project/documentation/` (the `documentation` path in
[`project/configs/workflow.json`](../configs/workflow.json)), leaving behind only what the Pages site
publishes; `E70_S02` then moved that remainder to `site/`. `site/_config.yml` carries no `exclude:`
entries — every file under `site/` is now a rendered page or Jekyll's own config.

## Where documentation goes

- **`docs/` belongs to the project.** Jenga scaffolds it but never puts Jenga content in it.
- **Jenga's internal documents live in `project/documentation/`**, the `documentation` path in
  [`project/configs/workflow.json`](../configs/workflow.json) — design notes, mirror and distribution
  rules, protocol and parity docs, decision records, execution plans and summaries.
- **The published site source lives in `site/`.**
- One-line test: *would someone who only installed the package want to read this?* If not, it is
  internal.
- There is no exception: the strategy brief is an ordinary `project/documentation/` file (see
  "STRATEGY.md placement" below).

The same rule is stated in `CLAUDE.md` and `AGENTS.md` under "Documentation Placement", and is guarded
at commit time by the `no-new-files-under-docs` item in `project/configs/checklists.json`.

## STRATEGY.md placement (`E34_S07`, reverses `E34_S06_T03`)

`STRATEGY.md` lives at `project/documentation/STRATEGY.md`, the default of `paths.strategy`, for
consumer projects and for this repo. It is an ordinary `project/documentation/` file.

**Decision reversed.** `E34_S06_T03` had kept the brief under `docs/` as a stakeholder deliverable, so
that it stayed committed when a consumer sets `project_files_visibility: ignored` (which gitignores
everything under `project/`). On 2026-10-03 the user reversed that: choosing to ignore Jenga's files
should ignore the strategy brief with the rest, and the cost `E34_S06_T03` was avoiding is accepted. A
consumer who wants the brief committed keeps `visible` (the default) or points `paths.strategy` at a
tracked path. `tests/strategy-visibility.bats` asserts the behaviour against the real
`skills/j-init/scripts/apply-project-visibility.sh`. The file is not blocklisted by `.publicignore`
(which lists only `project/documentation/plans/` and `summaries/`), so this repo's brief is still
mirrored publicly, and the dashboard's documentation parser
(`project/app/api/parsers/documentation.js`) reads it from the new location.

`j.init` and `j.strategy` resolve the path through `scripts/strategy_path_resolver.sh`, which reads
`paths.strategy` from `project/configs/workflow.json` (default `project/documentation/STRATEGY.md`).

**Existing consumers — the legacy `docs/STRATEGY.md` fallback is live behaviour, not history.** The
resolver keeps a legacy fallback: with no file at the configured path and an existing
`docs/STRATEGY.md`, it returns `docs/STRATEGY.md`, so `j.strategy` updates that file in place and
nothing is orphaned or duplicated. Nothing is migrated automatically; Jenga never moves a user's file
unasked. A consumer who wants the new location moves the file themselves:

```
git mv docs/STRATEGY.md project/documentation/STRATEGY.md
```

after which the resolver returns the configured path. A consumer's own `workflow.json` that still says
`paths.strategy: docs/STRATEGY.md` keeps working unchanged. Under `ignored`, a brief left at
`docs/STRATEGY.md` is not ignored, since only `project/` is a working path.

This fallback is **deliberate and stays**. `tests/strategy-path-resolver.bats` and
`tests/strategy-visibility.bats` assert it against temp fixtures, not against this repo's own tree, so
they keep passing even though this repo has no `docs/` directory. `E70` explicitly leaves all four of
those assertions unchanged.

---

## Structure

```
site/
├── _config.yml                        Jekyll config: theme, title, description, header_pages
├── index.md                           landing page (hand-authored, layout: home, no permalink)
├── guides/
│   ├── getting-started.md             /getting-started.html   (generated)
│   ├── concepts.md                    /concepts.html          (generated)
│   └── preflight-checklists.md        /preflight-checklists.html  (hand-authored)
└── reference/
    ├── reference.md                   /reference.html         (generated)
    ├── skills.md                      /skills.html            (generated)
    ├── agents.md                      /agents.html            (generated)
    ├── hooks.md                       /hooks.html             (generated)
    ├── mcp-tools.md                   /mcp-tools.html         (generated)
    └── jenga-config.md                /jenga-config.html      (hand-authored)
```

That is the full inventory: **11 files.** Of the 10 markdown pages, 7 are generated by
`scripts/build-pages-site.sh` and 3 are hand-authored (`index.md`, `preflight-checklists.md`,
`jenga-config.md`).

What each generated page is derived from:

- `guides/getting-started.md` — ported from `project/.wiki/intro-guide.md`
- `guides/concepts.md` — ported from `project/.wiki/concepts/*.md` (all 7 files, one section each)
- `reference/skills.md` — ported from `documentation.md`'s "Skills" section
- `reference/agents.md` — ported from `documentation.md`'s "Agents" section
- `reference/hooks.md` — ported from `documentation.md`'s "Hooks" section
- `reference/mcp-tools.md` — ported from `documentation.md`'s "MCP Tools" section
- `reference/reference.md` — index page linking to skills/agents/hooks/mcp-tools, plus
  `documentation.md`'s "Directory Structure" and "Agent Communication Contract" sections

And the three hand-authored ones:

- `index.md` — landing page; not script-generated
- `guides/preflight-checklists.md` — authoring reference for the pre-flight checklist feature
  (`E67_S06_T01`); not generated. Its maintainer-internal counterpart is
  `project/documentation/preflight-checklists.md`, which it links to rather than copies.
  `project/.wiki/preflight-checklists.md` also exists and is a *different, shorter* document — the
  generator does not read it and the two are independent.
- `reference/jenga-config.md` — reference for `jenga.cli.json`, which `lib/config-schema.js` reads and
  `jenga init` scaffolds into consumer projects. Until `E70_S02_T02` it had no front matter and sat in
  `_config.yml`'s `exclude:` list, so it was published nowhere; it now renders at
  `/jenga-config.html` and appears in the nav.

## Content conversion & sync (`E41_S13_T02`)

`scripts/build-pages-site.sh` (repo root) generates `guides/getting-started.md`, `guides/concepts.md`,
`reference/skills.md`, `reference/agents.md`, `reference/hooks.md`, `reference/mcp-tools.md` and
`reference/reference.md` under `site/` from `project/.wiki/*` — deterministically, safe to re-run at
any time, and it always fully overwrites those seven files. **Do not hand-edit them directly** — edit
the wiki source and re-run the script instead. `_config.yml`, `index.md`,
`guides/preflight-checklists.md` and `reference/jenga-config.md` are hand-authored and untouched by the
script.

**Re-run this script whenever `project/.wiki/documentation.md`, `project/.wiki/intro-guide.md`, or
`project/.wiki/concepts/*.md` change** — most commonly right after `j.doc-sync` updates the wiki, per
`skills/j-doc-sync/SKILL.md` section 8's pointer to this script. This is the concrete mechanism behind
the "keep both in sync" half of the source-of-truth decision above.

```bash
scripts/build-pages-site.sh
```

The output directory is an opt-in, defaulted override (`E70_S01_T01`): `$1`, else
`$BUILD_PAGES_OUTPUT_DIR`, else `<repo root>/site`. `--print-output-dir` resolves and prints it without
writing anything.

**Hand-edit drift is a real failure mode, and it is measured, not assumed.**
`scripts/dryrun-pages-site-diff.sh` generates into a fresh temp directory and classifies every file in
the site source as `identical` / `differs` / `not-generated` / `missing-in-docs`, without writing a
byte into `site/`. `project/documentation/docs-site-drift-report.md` is the `E70_S01_T02` measurement
and its disposition register. Both of its drifted hunks were folded back into generator source rather
than left as hand-edits — `getting-started.md`'s by `E70_S01_T04` (a new link-rewrite rule) and
`mcp-tools.md`'s by `E70_S02_T03` (the MCP-registration-decision blockquote, added to
`project/.wiki/documentation.md`'s `## MCP Tools` section). Run the harness before and after any change
to the generator or the wiki.

**Known limitation:** the script is a structural transform, not a fact-checker — it faithfully ports
whatever `project/.wiki/documentation.md` currently says, including that file's own pre-existing
staleness (e.g. it documents roughly 30 skills under the retired bare `/<name>` invocation form, not
the full current `skills/` set). Bringing the wiki itself up to date is `j.doc-sync`'s job, not this
script's.
