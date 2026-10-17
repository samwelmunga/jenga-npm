# `docs/` Site Drift Report

**Task:** `E70_S01_T02` · **Story:** `E70_S01` · **Epic:** `E70` (Retire Jenga's Own Use of `docs/`)
**Date:** 2026-10-06 (UTC)
**Measured at commit:** `8b82579a` (`task(E70_S01_T01): add defaulted output-dir override and read-only dry-run diff harness`)

**Harness command (exact, re-runnable):**

```bash
scripts/dryrun-pages-site-diff.sh                       # verdicts + full unified diffs
scripts/dryrun-pages-site-diff.sh --no-diffs            # verdicts and counts only
scripts/dryrun-pages-site-diff.sh --out <report-path>   # also write the whole report to a file
```

Exit codes: `0` clean · `1` usage error · `2` generator failed · `3` drift detected · `4` `docs/`
mutated by the run. At `8b82579a` the harness exits **3**.

This report lives under `project/documentation/`, never under `docs/` — per `CLAUDE.md`'s
"Documentation Placement" rule and `E70_S01`'s own implementation note. It is declared in the `docs:`
frontmatter of both `E70` and `E70_S01`.

---

## 1. Why this report exists

`E70` moves the GitHub Pages site source out of `docs/` into a root `site/` directory and repoints
`scripts/build-pages-site.sh` at the new layout. `E34_S06`/`E34_S07` hand-edited pages inside `docs/`
while the generator still claimed ownership of them, so a regenerate-and-move would silently discard
those hand-edits. The epic's own stated top risk is losing a hand-edit in the move.

This report is the record that proves what would and would not be lost. `E70_S02` must reproduce the
same comparison after the move; `E70_S05` verifies post-cutover state.

**Nothing under `docs/` was read-write during this measurement.** The generator was pointed at a fresh
`mktemp -d` via the `E70_S01_T01` output-directory override, and the harness fingerprints `docs/`
before and after each run and exits `4` if a byte changed. After every run in this report,
`git status --porcelain -- docs/` and `git diff --stat -- docs/` were both empty. *(Story AC 4.)*

---

## 2. Measured inventory — the "12 files" figure corrected

The story and the epic both say "the 12 files currently in `docs/`". That count is right about files
and wrong about pages. Measured at `8b82579a`:

| Measure | Count | Detail |
|---|---|---|
| Tracked files in `docs/` (depth 1) | **12** | `git ls-files docs/` |
| Markdown files | 11 | everything except `_config.yml` |
| Markdown files **with** Jekyll front matter (rendered as pages) | **9** | `agents`, `concepts`, `getting-started`, `hooks`, `index`, `mcp-tools`, `preflight-checklists`, `reference`, `skills` |
| Markdown files **without** front matter | 2 | `README.md`, `jenga-config.md` |
| Jekyll config (not a page) | 1 | `_config.yml` |
| **Generator-produced files** | **7** | `getting-started`, `concepts`, `skills`, `agents`, `hooks`, `mcp-tools`, `reference` |

So the honest breakdown is **12 files = 9 rendered pages + 1 Jekyll config + 1 excluded markdown doc
(`jenga-config.md`) + 1 maintainer decision record (`README.md`)**. Of the 9 rendered pages only 7 are
generated; the other 2 (`index.md`, `preflight-checklists.md`) are hand-authored.

`jenga-config.md` is a special case: it is site-destined content with no front matter, and
`docs/_config.yml`'s `exclude:` list keeps Jekyll from copying it into the built site at all. Epic
decision 3 gives it front matter and a nav entry during `E70_S02`; today it is published nowhere.

The harness derives every one of these numbers at runtime — the generated set from what actually lands
in the temp directory, the page count from testing each markdown file's first line for `---`. A comment
in the script forbids reintroducing a hardcoded page list or a hardcoded "12 files" figure.

---

## 3. Per-file verdicts

Verbatim from `scripts/dryrun-pages-site-diff.sh --no-diffs` at `8b82579a`:

| File | Verdict | Committed | Generated | Notes |
|---|---|---|---|---|
| `README.md` | **not-generated** | 14363 B | — | Maintainer decision record, not a site page (no front matter). |
| `_config.yml` | **not-generated** | 3486 B | — | Jekyll config. Generator header explicitly disclaims it. |
| `agents.md` | **identical** | 5990 B | 5990 B | From `documentation.md` `## Agents`. |
| `concepts.md` | **identical** | 25392 B | 25392 B | From `project/.wiki/concepts/*.md` (7 files, concatenated). |
| `getting-started.md` | **differs** | 13504 B | 13516 B | 1 hunk, 2 changed lines. **Not previously catalogued.** See §5. |
| `hooks.md` | **identical** | 1421 B | 1421 B | From `documentation.md` `## Hooks`. |
| `index.md` | **not-generated** | 1969 B | — | Hand-authored home page. Generator header explicitly disclaims it. |
| `jenga-config.md` | **not-generated** | 3742 B | — | Hand-maintained; Jekyll-`exclude`d, no front matter. |
| `mcp-tools.md` | **differs** | 1069 B | 817 B | 1 hunk, 1 added line. See §6. |
| `preflight-checklists.md` | **not-generated** | 13967 B | — | Hand-authored consumer reference (`E67_S06_T01`). See §7. |
| `reference.md` | **identical** | 7816 B | 7816 B | `## Directory Structure` + `## Agent Communication Contract` behind the section-4 heredoc blurb. |
| `skills.md` | **identical** | 46141 B | 46141 B | From `documentation.md` `## Skills`. **Contradicts the epic prose.** See §4. |

Tally: **5 identical · 2 differs · 5 not-generated · 0 missing-in-docs.**

`missing-in-docs: 0` means the generator produces no file that `docs/` lacks — the generated set is
exactly a subset of what is committed, so the `E70_S02` move has no orphan to account for.

---

## 4. `docs/skills.md` — **no drift** (the epic prose is stale here)

`E70`'s decision 8 and `E70_S01_T02`'s own description both state that `docs/skills.md` was hand-edited
in place by `E34_S06`/`E34_S07` and that the generator would overwrite it. **At `8b82579a` that is no
longer true.** `docs/skills.md` (46141 B, 1278 lines) is **byte-identical** to what
`scripts/build-pages-site.sh` produces from `project/.wiki/documentation.md`'s `## Skills` section.

Whatever hand-edit existed has since been reconciled into the wiki source, so the generator now
reproduces it. Evidence: the file is one of the 46 KB `cmp -s` matches in the verdict table, and the
harness emits no diff hunk for it.

**Drifted hunks: none. Dispositions required: none.** There is nothing to lose here, and `E70_S02` may
regenerate `skills.md` into `site/reference/` without special handling.

Two live caveats that are *not* drift and must not be mistaken for it:

- The generator's own header comment records a **wiki staleness** gap: `project/.wiki/documentation.md`
  documents roughly 30 skills under the retired bare `/<name>` invocation form and does not list every
  skill under `skills/`. The page faithfully reproduces a stale source. That is doc-sync's problem, not
  this epic's, and it is explicitly out of `E70`'s scope (the `wiki/docs/documentation.md`
  consolidation is deferred to a later epic by decision 7).
- `docs/skills.md`'s opening paragraph *does* already describe the `j-<name>` canonical form correctly —
  which is further evidence the wiki source was updated rather than the page hand-patched.

---

## 5. `docs/getting-started.md` — 1 drifted hunk (newly discovered)

Not mentioned in the epic, the story, or this task's description. The harness found it.

**Source:** `project/.wiki/intro-guide.md`, ported verbatim minus its leading H1, with section-5 `sed`
link rewrites applied.

```diff
--- generated/getting-started.md
+++ docs/getting-started.md
@@ -294,7 +294,7 @@

 **Adoption is partial by design.** Most skills don't declare an output type, and that's expected — it doesn't mean the skill is broken or unfinished. Only a skill that declares one can be named as a `forward_from` source in a playbook step; skills with no declared type simply aren't eligible for that role.

-This section explains the concept once. For which specific skills declare an output type today, see the **Skills** section of the [full reference](./documentation.md#skills) — each skill's entry there shows its Output type, or `any` if it doesn't declare one.
+This section explains the concept once. For which specific skills declare an output type today, see the **Skills** section of the [Skills Reference](./skills.md) — each skill's entry there shows its Output type, or `any` if it doesn't declare one.

 ---
```

Read `+` as the committed hand-edit and `-` as what the generator would write back.

**Root cause.** `project/.wiki/intro-guide.md:292` carries `[full reference](./documentation.md#skills)`.
The generator's section-5 rewrite rules match only the *exact* unanchored pattern
`[documentation.md](./documentation.md)` (handled at `intro-guide.md:7` and `:298`). The anchored,
differently-titled variant at line 292 matches no rule, so it passes through unrewritten and points at
`./documentation.md` — a file that **does not exist in the published site at all**. The hand-edit fixed
a genuinely broken link.

**Disposition: fold into generator source.** The hand-edit is correct and the generator must stop
reverting it. Two defensible mechanisms; the second is the one `E70` takes:

1. Fix `project/.wiki/intro-guide.md:292` to point at the restructured page. Rejected for now: the wiki
   is the canonical standalone wiki mirror, where `./documentation.md#skills` is a *valid* link. Fixing
   it there would break the wiki to fix the site.
2. **Add a section-5 `sed` rule** so the generator rewrites the anchored variant the same way it already
   rewrites the unanchored one. This is a link-rewrite rule, exactly the class of rule
   `E70_S01_T04` is already rewriting, so `E70_S01_T04` — the next task in this story — carries it.
   This report records the disposition; it does not claim it has been executed.

---

## 6. `docs/mcp-tools.md` — 1 drifted hunk (the `E34_S06`/`E34_S07` hand-edit)

**Source:** `project/.wiki/documentation.md`'s `## MCP Tools` section.

```diff
--- generated/mcp-tools.md
+++ docs/mcp-tools.md
@@ -7,6 +7,8 @@

 MCP (Model Context Protocol) tools extend Claude Code with additional capabilities. They are configured in `settings.json`.

+> Where a project registers an MCP *server* for Claude Code (`.mcp.json` vs `.claude/settings.json`) is recorded in [mcp-registration-decision.md](https://github.com/samwelmunga/jenga-npm/blob/main/project/documentation/mcp-registration-decision.md).
+
 ---

 ### `mcp/help`
```

One added blockquote (plus its trailing blank line) — the whole 252-byte difference between the
committed 1069 B and the generated 817 B. `project/.wiki/documentation.md` contains no occurrence of
`mcp-registration-decision` (verified by `grep`), so the text exists only in the committed page.

**Disposition: fold into generator source.** The pointer is correct and useful, and it is the only
link from the published site to the MCP-server-registration decision record. It must be added to
`project/.wiki/documentation.md`'s `## MCP Tools` section so the generator reproduces it. Note the link
is an absolute `https://github.com/samwelmunga/jenga-npm/blob/main/project/documentation/...` URL
rather than an intra-site link — deliberate, because `project/documentation/` is not published to the
Pages site, so a relative link would 404. It is therefore **out of scope** for `E70_S01_T04`'s
intra-site link normalisation and must stay absolute.

**Not executed in `E70_S01`.** Editing `project/.wiki/documentation.md` is a generator-source change
with no task in this story; it belongs to the `E70_S02` repoint, which already touches the generator
and its sources. Until it is folded, regenerating `mcp-tools.md` loses this blockquote — this is the
single concrete instance of the epic's stated top risk, and it is now on the record.

---

## 7. Generator-untouched pages — hand-maintained by definition, not drifted

These five files are **not produced by `scripts/build-pages-site.sh`**, so "drift" is not a meaningful
verdict for them. They are hand-maintained by definition and must be **moved, never regenerated**, in
`E70_S02`.

| File | Why it is not generated |
|---|---|
| `_config.yml` | Jekyll config (theme, `title`, `description`, `header_pages`, `exclude`). The generator's header comment names it explicitly as hand-authored site structure. |
| `index.md` | Hand-authored home page (`layout: home`). Also named explicitly in the generator's header comment. |
| `jenga-config.md` | Hand-maintained CLI config reference. No front matter, and `_config.yml`'s `exclude:` keeps Jekyll from copying it — it is published nowhere today. Epic decision 3 gives it front matter and a nav entry in `E70_S02`. |
| `preflight-checklists.md` | Hand-authored consumer authoring reference (`E67_S06_T01`), 13967 B, with front matter and `permalink: /preflight-checklists.html`. |
| `README.md` | Maintainer decision record — **not a site page at all.** See §8. |

**`project/.wiki/preflight-checklists.md` exists but the generator does not consume it**, as this task
requires calling out. It is not a stale copy of the published page either: 4991 B against the published
page's 13967 B, and 284 differing lines. They are two different documents with the same filename — the
wiki one is a short overview, the `docs/` one the full authoring reference. The generator reads only
`project/.wiki/documentation.md`, `project/.wiki/intro-guide.md` and `project/.wiki/concepts/*.md`;
nothing in it references `project/.wiki/preflight-checklists.md`. **No action in `E70`** — the two files
are independent and the published page is hand-maintained.

---

## 8. `docs/README.md` is not a site page

`docs/README.md` (14363 B, 187 lines) has no Jekyll front matter, so Jekyll does not render it as a
page, and the generator's header comment disclaims it. It is the maintainer-facing decision record for
the `E41_S13` Pages site, including the "Contents by audience" per-file classification table.

It is the reason the "12 files in `docs/`" figure overstates the site: 12 files, 11 of them site
content, and this one a maintainer artefact that happens to live in the same directory.

**Epic decision 6** moves its decision record to `project/documentation/site-decisions.md` and drops or
archives the "Contents by audience" table. That is owned by a later `E70` story, not by `E70_S01`.
No disposition is required here — it is not generated, so there is no hunk to lose.

---

## 9. Disposition register — every drifted hunk

Two drifted hunks exist in total across the whole site. Each carries exactly one disposition.

| # | File | Hunk | Disposition | Reason (one line) | Owner |
|---|---|---|---|---|---|
| 1 | `docs/getting-started.md` | line 297: `[full reference](./documentation.md#skills)` → `[Skills Reference](./skills.md)` | **fold into generator source** | The hand-edit fixes a link to a file that does not exist in the published site; the generator's section-5 `sed` rules miss the anchored variant, so add a rule rather than breaking the standalone wiki. | `E70_S01_T04` (next task in this story) |
| 2 | `docs/mcp-tools.md` | after the intro paragraph: added blockquote linking to `project/documentation/mcp-registration-decision.md` | **fold into generator source** | The pointer is correct and is the site's only link to that decision record; it must live in `project/.wiki/documentation.md`'s `## MCP Tools` section so the generator reproduces it. | `E70_S02` (not yet executed) |

No hunk is left without a disposition. No hunk was dispositioned **keep as a hand-maintained file** or
**discard as stale** — both hand-edits are correct and both pages should stay generated.

---

## 10. What this means for `E70_S02`

1. **Five of the seven generated pages are safe to regenerate** into `site/`: `agents.md`,
   `concepts.md`, `hooks.md`, `reference.md`, `skills.md`. All five are byte-identical to generator
   output today.
2. **`mcp-tools.md` must not be regenerated before hunk 2 is folded into
   `project/.wiki/documentation.md`.** Doing so silently drops the blockquote. This is the single real
   instance of the epic's top risk.
3. **`getting-started.md`**'s hunk is dispositioned to `E70_S01_T04`, which rewrites the generator's
   link rules anyway. Re-run the harness after that task and confirm the verdict before relying on it.
4. **Five files must be moved, never regenerated**: `_config.yml`, `index.md`, `jenga-config.md`,
   `preflight-checklists.md`, `README.md` (the last to `project/documentation/site-decisions.md` per
   decision 6).
5. **Re-run `scripts/dryrun-pages-site-diff.sh --source-dir site/...` after the move** and expect the
   same verdicts. `missing-in-docs: 0` today means any `missing-in-docs` line after the move is a
   repoint bug, not pre-existing state.
6. The harness classifies the source directory at **depth 1 only**. `site/guides/` and `site/reference/`
   are nested, so `E70_S02` must either run the harness once per subdirectory or extend its source-side
   `find -maxdepth 1`.

---

---

## 11. Amendment — `E70_S01_T04` (intra-site link normalisation)

*Added by `E70_S01_T04` after re-running the harness, per its acceptance criterion that this report be
amended if any verdict above changes. Re-measured at the `E70_S01_T04` working tree on top of
`5aed6c25`.*

`E70_S01_T04` normalised all 29 intra-site markdown links in the site pages to the bare relative
permalink `.html` form and updated `scripts/build-pages-site.sh`'s section-4 heredoc and section-5 /
section-6 `sed` rules to emit the same form. Two consequences for this report:

- **`docs/getting-started.md`: verdict changes from `differs` to `identical`.** Disposition 1 in §9 was
  executed by that task: a new section-5 rule,
  `s|\[full reference\](\./documentation\.md#skills)|[Skills Reference](skills.html)|g`, now rewrites
  the anchored variant that previously matched no rule, so the generator reproduces the committed page
  exactly. **Hunk 1 is closed.** §5's diff is retained above as the historical record of what the
  hand-edit was.
- **`docs/mcp-tools.md`: verdict unchanged — still `differs`.** Hunk 2 is a content blockquote, not a
  link, and its URL is a deliberate absolute GitHub URL into `project/documentation/` (which the site
  does not publish), so the intra-site normalisation correctly leaves it alone. **Hunk 2 remains open
  and owned by `E70_S02`.**

Post-`E70_S01_T04` tally: **6 identical · 1 differs (`mcp-tools.md` alone) · 5 not-generated ·
0 missing-in-docs.** The harness still exits `3`, now on `mcp-tools.md` alone. No other verdict in §3
changed and no new drift was introduced — which is exactly why `E70_S01_T04` was sequenced after this
report.

§10 item 2 is therefore the **only** remaining hand-edit risk for `E70_S02`, and §10 item 3 is
discharged.

---

## 12. Amendment — `E70_S02_T03` (hunk 2 closed; the site source is now `site/`)

*Added by `E70_S02_T03`, which owned the last open disposition in §9. Re-measured on top of
`580d6c8d` (`task(E70_S02_T02): git mv the 11 site pages into site/guides and site/reference`).*

**Hunk 2 is closed.** The `mcp-tools.md` blockquote was folded into
`project/.wiki/documentation.md`'s `## MCP Tools` section (now line 1502), immediately after that
section's intro paragraph, exactly as §6's disposition required. Its URL stays the absolute
`https://github.com/samwelmunga/jenga-npm/blob/main/project/documentation/mcp-registration-decision.md`
form — `project/documentation/` is not published to the Pages site, and the wiki is also read
standalone, so an absolute URL is the only form correct from both. It was **not** touched by
`E70_S01_T04`'s intra-site normalisation, as §6 predicted.

**§9's disposition register is now fully discharged.** Both drifted hunks were dispositioned "fold into
generator source" and both have been executed — hunk 1 by `E70_S01_T04`, hunk 2 here. No disposition
remains open, and no hand-edit was lost in the move.

**Post-move verdicts, measured at `580d6c8d` + the `E70_S02_T03` working tree:**

| Measure | Pre-move (§3, as amended by §11) | Post-move |
|---|---|---|
| `identical` | 6 | **7** |
| `differs` | 1 (`mcp-tools.md`) | **0** |
| `not-generated` | 5 | **4** |
| `missing-in-docs` | 0 | **0** |
| Harness exit code | 3 (drift detected) | **0 (clean)** |

The two deltas are both expected and both accounted for: `reference/mcp-tools.md` moved from `differs`
to `identical` because hunk 2 is now folded, and the `not-generated` count dropped from 5 to 4 because
`README.md` left the site source entirely (`E70_S02_T01` converted it to
`project/documentation/site-decisions.md`). The remaining four `not-generated` files are exactly the
hand-authored set §7 named, minus that README: `_config.yml`, `index.md`,
`guides/preflight-checklists.md`, `reference/jenga-config.md`.

**The strongest evidence is independent of the harness.** A bare `scripts/build-pages-site.sh` run
against the real `site/` tree leaves `git status --porcelain -- site` and `git diff --stat -- site`
both **empty**. Any lost hand-edit would necessarily appear in that diff as a deletion, so an empty
diff after a full regenerate is a direct proof that nothing was lost — not an inference from verdict
labels.

**Measured inventory, post-move:** 11 files under `site/` · 10 markdown with front matter (rendered
pages) · 0 markdown without · 7 generator-produced. The "markdown without front matter" count fell
from 2 to 0: `README.md` left the directory and `jenga-config.md` gained front matter in
`E70_S02_T02`, so it is now a rendered page at `/jenga-config.html` — the one page whose published URL
changed, from "published nowhere" to a live URL.

**§10 item 6 is discharged.** Both `E70_S01` scripts walked their source directory at depth 1 and so
would have gone silently blind against the nested layout. Both are repointed:

| Script | Change | Task |
|---|---|---|
| `scripts/check-site-links.sh` | default `--site-dir` → `site/`; recursive page walk; duplicate-basename guard | `E70_S02_T02` |
| `scripts/dryrun-pages-site-diff.sh` | default `--source-dir` → `site/`; recursive source walk; wider verdict columns | `E70_S02_T03` |

The `missing-in-docs` verdict label is deliberately **not** renamed, even though the source directory
is no longer `docs/`: §10 item 5 of this report quotes it verbatim and makes it the post-move
repoint-bug signal, so renaming it would invalidate a written expectation `E70_S05` still depends on. A
comment in the script records that the name is historical.

**Re-runnable commands, unchanged in form** — both now default to `site/`:

```bash
scripts/dryrun-pages-site-diff.sh --no-diffs     # expect: 7 identical, 0 differs, exit 0
scripts/check-site-links.sh --quiet              # expect: 10 pages, 64 links, 41 anchors, exit 0
```
