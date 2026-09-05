---
name: j:j-uncharted
description: Polyfill alias of the uncharted skill under a collision-safe directory name. Identical behavior to /uncharted — Investigate code that has no Jenga board provenance — a foreign file, an external source being pulled in, or an entire pre-existing codebase — and give it a consistent understanding document plus proper board representation. Use when the bare /uncharted form is shadowed by another tool's own built-in command of the same name.
metadata:
  prefered_agent: scrum-master
keywords:
  - "uncharted"
  - "foreign code"
  - "unfamiliar code"
  - "existing codebase"
  - "onboard codebase"
  - "import source"
  - "unlinked code"
  - "no board history"
  - j-uncharted
  - polyfill
examples:
  - "what does this file actually do?"
  - "help me understand this directory I inherited"
  - "we're adopting Jenga into an existing project, backfill the board"
  - "pull in this repo and figure out how it fits"
  - "this code has no board history, get it onto the board"
  - "analyse the legacy module nobody understands"
  - "onboard this existing codebase"
  - "j-uncharted"
---

# Uncharted — Investigative Workflow for Foreign & Pre-Existing Code

This skill is a literal-directory-name duplicate of `skills/uncharted/`. It exists so that `/j-uncharted` (and `j:j-uncharted`) give a guaranteed-unshadowed way to reach the same flow as `/uncharted`, even if a host tool's own built-in command of the same name would otherwise shadow or override the bare `/uncharted` alias (Claude Code's native skill resolution is a literal-string, directory-name-based match — see `docs/skill-authoring.md`'s "Invocation Convention").

This file is generated/synced by `scripts/generate-j-alias.sh uncharted` from `skills/uncharted/SKILL.md` — do not hand-edit it; re-run the generator instead to pick up source changes.

`/uncharted` is the entry point for code with **no board provenance** — code that was never planned, decomposed, or executed through the Jenga workflow.

It fills a gap the existing investigative skills leave open:

| Skill | Investigates | Requires |
|---|---|---|
| `/deep-dive` | ideas and proposals | no code target |
| `/improve` | the current codebase | an explicit goal |
| `/redo` | prior implementations | existing board history |
| **`/uncharted`** | **code with no board history** | **nothing but a target** |

Every mode runs the same shared investigative engine and emits the same understanding document. The modes differ only in **scale** and in **what happens after** the analysis.

---

## Invocation Contract

```
/uncharted <mode> [target]
```

| Mode | Scale | What it does | Implemented by |
|---|---|---|---|
| `segment` | one file, directory, or feature | Two explicit modes since E20_S08_T03: `--mode delivery` (default, unchanged) analyses a target already in the repo and proposes a standard epic/story/task; `--mode investigate` opens a conversational architecture-investigation flow instead. See **`segment`** below for the mode choice. | E40_S02 / E20_S08_T03 |
| `import` | an external source | Acquires a git URL, an out-of-repo path, or a pasted snippet into the repo at a user-confirmed location, then hands off to `segment`. | E40_S03 |
| `onboard` | the whole codebase | Conversational by default since E20_S08_T03: discovery scripts seed a human-in-the-loop elicitation that writes `[ARCH]`-tagged board items and coarse graph nodes. `--legacy` reproduces the original fully-automated, zero-prompt, capped-**backfilled**-epic pass unchanged. Board/graph-only — never touches application code, in either mode. | E40_S04 / E20_S08_T03 |

**Dispatch rules:**

1. If the mode is one of `segment`, `import`, or `onboard`, dispatch to that section below.
2. If the mode is missing or unrecognised, do **not** guess. Present the three modes as a numbered choice list with a free-text option last, per the Interaction Pattern in `CLAUDE.md`.
3. If a mode is given but its target is missing, ask for the target the same way — a numbered list of plausible candidates where they can be inferred, free-text last.
4. Never widen scope across modes in one invocation. `import` may hand off to `segment` because that handoff is part of its contract (E40_S03_T03); nothing else chains implicitly.

---

## Shared Investigative Engine

All three modes call the same engine rather than reimplementing analysis. Per the Skill Implementation Principle in `CLAUDE.md`, the deterministic work lives in scripts under `skills/j-uncharted/scripts/`, not in this file:

| Script | Responsibility | Implemented by |
|---|---|---|
| `enumerate-target.sh` | Resolves a target to file / directory / repo-root and emits its structure as JSON. Respects `.gitignore`; supports a `--max-depth` bound. | E40_S01_T02 |
| `detect-dependencies.sh` | Separates internal from external dependencies; lists manifests found in or above the target. | E40_S01_T03 |
| `detect-tests.sh` | Reports whether tests actually cover the target, distinguished from "the repo has tests but none reference it". | E40_S01_T03 |
| `run-engine.sh` | Mode-agnostic entry point. Invokes the three detectors above, merges their JSON, renders the understanding document, and prints the written path on stdout. | E40_S01_T04 |

**Invoke `run-engine.sh`, never the individual detectors.** It is the only supported entry point; calling a detector directly gets you raw JSON and no document.

```bash
DOC=$(bash skills/j-uncharted/scripts/run-engine.sh --mode segment <target>)
```

| Option | Effect |
|---|---|
| `--mode segment\|import\|onboard` | Mode hint. Default `segment`. Reflected in the filename and the document's Target section. `onboard` also defaults the tree depth to 2, because it is coarse-first by design. |
| `--max-depth N` | Tree depth bound (default 3, or 2 for `onboard`; `0` = unlimited). Bounds the **tree only** — file and line counts always cover the whole target. |
| `--top N` | How many largest-files rows to report. Default 10. |
| `--no-gitignore` | Enumerate `.gitignore`'d content too. Needed when `import` has staged a source into an ignored path. |
| `--origin "<text>"` | Value for the Target section's Origin row. `import` mode passes its acquired source here, e.g. `--origin "imported from https://…"`. Defaults to `in-repo`, or an explicit "outside this repository" when the target is. |
| `--out-dir <dir>` | Override the output directory. Default `project/rapports/analysis/`. |
| `--json-out <file>` | Also write the merged detector JSON, for when you want to reason over the raw evidence rather than the rendered prose. |
| `--template <file>` | Override the document template. Present for testing; production runs use the default. |

**Streams.** stdout is exactly one line — the absolute path of the written document — so `DOC=$(…)` is safe. Detector notices, skipped paths, and render warnings go to stderr. **Read the stderr.** It is where "4 hidden directories were skipped", "reference names truncated to the first 300", and "this target is not inside a git repository" show up, and each of those changes how much weight the document's findings deserve.

| Exit | Meaning | What to do |
|---|---|---|
| 0 | Document written | Proceed; the path is on stdout. |
| 1 | Usage error | Fix the invocation. Do not retry blindly. |
| 2 | Target does not exist or is unreadable | Re-resolve the target with the user; in `segment` mode this usually means the free-text description resolved to nothing. |
| 3 | A detector was missing or failed | Surface the forwarded stderr to the user. Do **not** hand-write a document to work around it. |
| 4 | Render or write failure | Template missing, `--out-dir` or `--json-out` directory unwritable, or the rendered document failed its seven-heading self-check. Report it; nothing is left behind — both destinations are checked before any detector runs, and the document is the last thing written. |

Do not restate in prose what these scripts do step by step, and do not reimplement their logic inline. Read the document (and `--json-out` when you need the raw evidence) and reason about it — that is the part that needs an agent.

> **Note:** the engine is live as of E40_S01. `segment` (E40_S02), `import` (E40_S03), and `onboard` (E40_S04) are all complete end to end — resolution or acquisition through to board write and handoff, in each mode's own terms.

---

## Output: the Understanding Document

Every mode produces exactly one document per target, rendered from `skills/j-uncharted/assets/UNDERSTANDING_DOC_TEMPLATE.md`.

**Where it goes:** `project/rapports/analysis/`, named `uncharted-<mode>-<slug>-<YYYYMMDDTHHMMSSZ>.md`. Nothing is ever overwritten — a name collision gets a `-2`, `-3`… suffix, so repeated runs against one target leave a diffable history.

This reuses the **existing `analysis` rapport type** already defined in `templates/SCRUM_BOARD_SCHEMA.md`. `/uncharted` introduces **no new rapport type** — if a change to the rapport taxonomy ever seems necessary, that is a schema change to be raised with the scrum-master, not something this skill invents.

**Fixed structure** — seven headings, never added to, removed, reordered, or renamed, because downstream steps read the document by heading:

`## Target` · `## Purpose` · `## Structure` · `## Key Dependencies` · `## Existing Tests` · `## Risk Areas` · `## Open Questions`

The engine enforces this itself: a render that would drop a heading exits 4 instead of writing. Diagnostics have nowhere to live in that structure, which is exactly why they go to stderr rather than being appended as an eighth section.

**Two classes of section, treated differently:**

| Section | Class | Filled by |
|---|---|---|
| `Target` | Mechanical | Engine — resolved path, target type, mode, board linkage, origin |
| `Structure` | Mechanical | Engine — file count, per-extension table, bounded tree, largest files |
| `Key Dependencies` | Mechanical | Engine — internal vs external, plus manifests found in or above the target |
| `Existing Tests` | Mechanical | Engine — coverage signal, referencing test files, runner configuration |
| `Purpose` | **Judgement** | **You**, from the mechanical evidence |
| `Risk Areas` | **Judgement** | **You**, from the mechanical evidence |
| `Open Questions` | **Judgement** | **You**, from the mechanical evidence |

The engine emits the three judgement sections as explicit `_TODO(agent):_` placeholders and must never fabricate them. After the engine runs:

1. Read the document and the stderr notices.
2. Replace each `_TODO(agent):_` line, citing what the mechanical sections actually found — a specific untested file, a named dependency, an oversized module.
3. Where the evidence does not support a conclusion, say so under **Open Questions** and name who could answer it. That is a valid result, not a failure.
4. Leave the headings alone.

Two signals deserve particular attention because they are easy to misread:

- **Coverage** is reported as `covered`, `repo_tests_only`, or `no_tests_in_repo`. "The repo has tests but none touch this target" is a finding about *this target*, not about the repo's testing culture — do not soften it into "the project has tests".
- **Board linkage** says `unlinked` when no board item mentions the target's path. That is the whole reason `/uncharted` exists; it is the starting condition, not a problem to report.

A document whose judgement sections are generic enough to apply to any codebase has failed its purpose. Ground every claim in something the scripts actually found.

---

## Conversational Elicitation

Since **E20_S08_T03**, `onboard`'s default behavior and `segment --mode investigate` both run a human-in-the-loop **conversational elicitation** instead of (or, for `onboard`, in addition to keeping available) a one-shot deterministic pass. This section defines the mechanics shared by both; each mode's own subsection below only describes what is specific to it.

**What conversational elicitation produces, and how that differs from the Understanding Document above:** the **primary** output is coarse-tier graph nodes/edges — written directly to `project/knowledge-graph/graph.json`, conforming to the stub schema at `project/knowledge-graph/STUB_SCHEMA.md` (E20_S08_T01; this is a throwaway pilot schema, swapped wholesale once E20_S01's real schema lands — do not extend it expecting stability). Every node this flow writes carries `source: "human"`, since it comes from a person confirming or correcting a proposed understanding, not from mechanical extraction. Board representation is a `[ARCH]`-tagged epic, story, or task at whichever level fits the investigated scope (see `templates/SCRUM_BOARD_SCHEMA.md`'s `[ARCH]` — Durable Architectural Inventory convention) — **not** the delivery-shaped epic/story/task proposal `segment --mode delivery` and legacy `onboard` produce, and not the fixed 7-heading Understanding Document either. A written summary is produced only when warranted, filed as the resulting board item's ordinary `-summary.md` — there is no new artifact type or separate "Understanding Document" for conversational output.

### Human-Oracle-Availability Limitation

**Read this before running a conversational elicitation on code nobody currently understands.** This is `/uncharted`'s own documented, standing, accepted limitation — not only `agents/developer.md`'s and `agents/tester.md`'s (E20_S08_T02 covers those; this is the skill's own copy of the same limitation, since the person driving `/uncharted` may never open either agent file directly).

For genuinely undocumented code, there is often no reliable human oracle to confirm or correct a proposed understanding — the person answering may not know either, or may confidently confirm a wrong answer. Per the parent story's own scrutiny (scored 3/10 on this exact point) and its solution assessment's disposition ("Accept and Descope" on Problem 1): **conversational elicitation does not solve this, and does not claim to.** It is a complementary path for codebases where *some* human context exists, not a fix for the hardest, genuinely zero-oracle case.

- **The deterministic pipeline remains the tool of record for zero-oracle codebases.** `onboard --legacy` and `segment --mode delivery` never depend on anyone confirming intent — they ground everything in mechanical evidence (file structure, dependencies, test coverage) and say so explicitly under `Open Questions` when the evidence doesn't support a conclusion. When there is no one left who understands the code, reach for one of those, not the conversational flow.
- **When running the conversational flow, do not manufacture confidence.** If the user's answer is uncertain, hedged, or contradicts what discovery/Investigative Mode found, write the node honestly — do not round an uncertain answer up to a confirmed one. There is no schema field yet to tag confidence (the stub schema is intentionally minimal); until one exists, say so in the node's `description` text itself (e.g. "per the user, this module retries failed charges — unconfirmed against the code, which shows only a single retry attempt") rather than silently dropping the caveat.
- **A confidently wrong answer is not detectable by this flow.** Corroboration against a second signal (commit history, existing docs, a second person) is the only mitigation, and it is not built here — this is the accepted residual risk, not a gap to engineer around mid-conversation.

### Directory Triage

Runs once per elicitation, between discovery and the first Investigative Mode dispatch — never skipped, and never silently absorbed into the convergence loop below, because triaging noise out is exactly what keeps that loop from wasting turns (and the user's attention) on vendor/generated directories nobody wants a graph node for.

**Step 1 — deterministic pass.** Feed the candidate directories (from `discover-subsystems.sh`'s output for `onboard`, or the target's immediate subdirectories for `segment --mode investigate`) to:

```bash
discover-subsystems.sh <root> | jq -r '.candidates[].path' \
  | bash skills/j-uncharted/scripts/directory-triage.sh <root>
```

Read `ignored` (already excluded by `.gitignore`, or matching the fixed vendor/generated pattern list — see the script's own header for the full list) and `remaining`. This is a mechanical classification; do not second-guess it or re-run judgement over an `ignored` entry.

**Step 2 — judgement pass over `remaining`.** This is the generalize-list the deterministic pattern list can never catch: content-based cases where a directory is legitimately noise or a single coarse unit for reasons a pattern match cannot see — the task's own example is "this directory is SOAP request mock-ups for a test suite." Skim `remaining` (directory names, a shallow listing, README/comment hints) and propose, for each one that looks like a generalize candidate, a single-sentence rationale and the disposition: **exclude** (like `ignored`, zero graph nodes) or **generalize** (one coarse-tier node covering the whole directory, no per-file drill-down, no Investigative Mode dispatch into it). Everything not proposed for either disposition proceeds to full investigation.

**Step 3 — one confirmation gate, both lists together.** Per the task's own acceptance criterion, both the deterministic ignore-list and the judgement-based generalize-list are confirmed with the user **before any developer/tester Investigative Mode dispatch** — not after, and not as two separate gates:

```
Directory triage for <target>:

Excluded (pattern/gitignore match) — N directories:
<path> — <reason>
...

Proposed for exclusion or generalization (judgement) — M directories:
<path> — exclude|generalize — <one-line rationale>
...

Everything else (K directories) proceeds to investigation.

How should this be applied?
1. Accept as proposed
2. Revise — change a disposition before proceeding
3. Show me the full excluded/generalize lists in detail
4. Other (describe below)
```

Silence, a counter-question, or an ambiguous reply is not consent — re-ask, the same convention used at every other confirmation gate in this skill. Option 3 does not count as a decision; re-present the same choice after showing the detail. Checkpoint the confirmed triage result immediately via `elicitation-state.sh checkpoint` (see Multi-Session Persistence below) so a paused-and-resumed session never re-asks a question the user already answered.

### Convergence Loop

Runs once per surviving candidate (a subsystem, a named flow, a directory) after Directory Triage. This is the "propose understanding, ask the user to confirm or correct" cycle at the center of the redesign — and the one the scrutiny flagged as having no termination bound and no defense against confirmation fatigue. Both gaps are closed mechanically, not by agent discipline alone:

1. **Dispatch Investigative Mode.** Per `agents/developer.md`'s and `agents/tester.md`'s Investigative Mode sections (E20_S08_T02), dispatch the developer to trace what the code actually does for the candidate, and the tester to trace what the test suite actually exercises and verifies for the same candidate — two distinct vantage points, not two names for the same read. Both are read-only, worktree-sandboxed, no commits, no board writes.
2. **Propose understanding.** From both traces, draft the candidate's coarse graph node(s)/edge(s) (per the stub schema) and a plain-language summary of what they represent.
3. **Risk-weighted gating — not every finding gets a prompt.** This is the fix for confirmation fatigue (solution assessment, Problem 6, Solution B — RECOMMENDED): force an explicit confirmation only for **high-uncertainty or high-impact** findings — a node whose description depends on an inference the traces don't fully support, a node with many outgoing edges (structurally central), or one the Human-Oracle-Availability Limitation above already flagged as uncertain. **Auto-accept** low-risk, high-confidence findings — the traces agree, the finding is narrow in scope, nothing about it is surprising — without a prompt, but **log every auto-accepted node** in the elicitation state's checkpoint data (see below) so the decision is auditable later, per that solution's own mitigation for "the scoring mechanism itself misjudges impact."
4. **Confirm/correct, one round per call to `elicitation-state.sh turn`.** For a node requiring confirmation, present the draft and ask the user to confirm or correct it (per the Interaction Pattern in `CLAUDE.md` — confirm / correct-with-detail / defer as "unconfirmed" / other). Each round, call:

   ```bash
   bash skills/j-uncharted/scripts/elicitation-state.sh turn --id <elicitation-id> --node <node-id>
   ```

   Exit `0` means keep looping (cap not yet reached) if the user corrected rather than confirmed. Exit `3` means **the hard turn cap has been reached** — the node is now marked `flagged` in the state file. **Do not loop again on that node.** Instead present it as unresolved and offer an explicit choice rather than looping indefinitely (solution assessment, Problem 10, Solution A — RECOMMENDED):

   ```
   <node> has reached the confirmation round limit without converging.
   1. Accept the current best draft as-is (flagged low-confidence)
   2. Defer — skip this node for now, continue with the rest
   3. Continue past the limit (explicit override)
   4. Other (describe below)
   ```

   Option 3 is the only way past the cap, and it is a per-node, explicit, one-time override — it does not raise the cap for the rest of the run.
5. **On convergence** (confirmed, corrected-and-accepted, or resolved via the cap choice above), call:

   ```bash
   bash skills/j-uncharted/scripts/elicitation-state.sh converge --id <elicitation-id> --node <node-id> --note "<one-line summary of what was confirmed>"
   ```

   then write the node/edge to `project/knowledge-graph/graph.json` per the stub schema, and checkpoint the elicitation state (next section) — **after every converged node**, not only at the end of the whole run.

### Multi-Session Persistence

A whole-codebase `onboard` conversation, or an investigation of a large directory, can span more sessions than fit in one sitting. State persists via the existing `SessionEnd`/queue infrastructure — no new persistence mechanism (solution assessment, Problem 11, Solution A — RECOMMENDED).

- **`init` once, at the start of an elicitation:**

  ```bash
  bash skills/j-uncharted/scripts/elicitation-state.sh init --id <elicitation-id> --target "<path or description>" --cap 5
  ```

  Idempotent — safe to call again on a resumed `<elicitation-id>` without resetting progress. Choose `<elicitation-id>` so it is stable and re-derivable across sessions (e.g. `onboard-<root-slug>-<date>`, or `segment-investigate-<target-slug>`), since a resuming session must be able to reconstruct it to call `init` again.
- **`checkpoint` after every converged node and after the Directory Triage confirmation gate** — never only at the end. This is what makes a mid-run pause lossless: `checkpoint --id <id> --json <file>` merges arbitrary progress data (triage results, draft nodes not yet converged, anything else worth surviving a pause) into the state file.
- **`pause` when a session must end before the elicitation has converged.** Immediately after calling `elicitation-state.sh pause --id <elicitation-id>`, write the scrum-master's own `SessionEnd` handoff (per `templates/SCRUM_BOARD_SCHEMA.md`'s `handoffs/` convention) with `status: "elicitation_paused"` and both `elicitation_id` and `state_file` set — `hooks/on_session_end.sh` routes that into an `elicitation_resume` trigger on `scrum_triggers.jsonl`, which the next scrum-master session's Drain Scrum Triggers Queue procedure picks up (`agents/scrum-master.md`).
- **On resume**, read `state_file` directly — every converged node, every flagged node, and the checkpoint data (including the confirmed directory-triage lists) are already there. Do not re-run Directory Triage or re-ask about an already-converged node; resume the Convergence Loop only for nodes still `pending` or explicitly deferred.
- **`complete` when every candidate has converged, been deferred, or been explicitly accepted past the cap.** The state file is left on disk afterward as an audit trail — nothing currently prunes a completed elicitation's state file.

---

## Modes

<!--
  PLACEHOLDER SECTIONS — scaffolded by E40_S01_T01.

  Each mode below is a self-contained block under a stable `### ` heading.
  The owning task replaces the body of its own block and leaves the others
  and the surrounding shared sections untouched.
-->

### `segment`

Analyse a specific file, directory, or feature that has no board provenance. Since **E20_S08_T03**, `segment` has two explicit modes — it no longer silently always runs one:

| Flag | Mode | What it produces |
|---|---|---|
| `--mode delivery` (default when explicit) | Delivery-shaped proposal — today's unchanged flow | A standard epic/story/task proposal, per the Understanding Document |
| `--mode investigate` | Conversational architecture investigation (new, E20_S08_T03) | Coarse graph nodes/edges plus a `[ARCH]`-tagged board item |

**Step 0 — choose a mode.** If `--mode` is given, skip straight to that mode's subsection below. If it is missing, do **not** default silently — present the choice, per the Interaction Pattern in `CLAUDE.md`:

```
/uncharted segment <target> — which mode?
1. Delivery-shaped proposal (produces an epic/story/task to build on this target)
2. Conversational architecture investigation (produces graph nodes explaining what this target does)
3. Other (describe below)
```

Silence, a counter-question, or an ambiguous reply is not consent — re-ask. This choice is the entire mechanism by which existing callers keep getting exactly today's behavior (option 1, or `--mode delivery` passed explicitly) while new callers can reach the conversational path deliberately, per the parent story's own acceptance criterion that this split must be explicit, not a silent behavior change.

#### Delivery-shaped proposal (`--mode delivery`)

Unchanged from before E20_S08_T03 — every step below is exactly what `segment` has always done.

**Step 1 — Resolve the target.** Deterministic; do not eyeball it.

```bash
bash skills/j-uncharted/scripts/resolve-segment-target.sh --json-only "<path-or-description>"
```

It returns one `results[]` record. Read three fields:

| Field | Meaning |
|---|---|
| `kind` | `path` — the argument is an existing file or directory, already canonicalised in `target`. `description` — it is free text (exit 2). |
| `board_linkage.status` | `unlinked`, `linked`, or `not_checked` (with a `reason` — repo root, outside the repo, or no board directory). |
| `candidates[]` | Only for `kind: description`. Ranked path hints, capped by `--limit`. |

**When `kind` is `description`, you must ask.** Present `candidates[]` as a numbered choice list with a free-text option last, per the Interaction Pattern in `CLAUDE.md`. **Never** silently adopt the top-scored candidate — the score is a ranking hint, not a resolution, and picking for the user is how the wrong directory gets a whole epic written against it. An empty `candidates[]` is a normal result, not a failure: ask for the path directly. Exit 2 still prints its JSON, so read it rather than retrying.

**Report the linkage before doing anything else.** `unlinked` is the condition that justifies this whole workflow; say so. `linked` is a genuine finding — the target *already has* board provenance, so tell the user which items reference it and confirm they still want a segment pass rather than `/redo`. Do not proceed silently past a `linked` target.

> **Step 1 is authoritative on linkage.** `run-engine.sh` keeps its own private substring version for the document's `Board Linkage` row, and the two can disagree: a board item mentioning only `docs/hooks/guide.md` makes the document call `hooks/` *linked* while Step 1 correctly calls it *unlinked*. Where they differ, trust Step 1 and correct the row when you fill in the document — do not hand the user a document that contradicts what you just told them.
>
> The same script is also `/reconcile`'s board-linkage check (E40_S05_T02). Collapsing the two implementations into one is a deliberate follow-up, not something to do in passing — see the script's header.

**Step 2 — Run the engine** on the resolved absolute path:

```bash
DOC=$(bash skills/j-uncharted/scripts/run-engine.sh --mode segment "<resolved target>")
```

Options, streams, and exit codes are in **Shared Investigative Engine** above — do not restate them here, and do not reimplement enumeration, dependency, or test detection. Two mode-specific readings:

- **Exit 2 here means the resolution was wrong**, not that the engine is broken. Go back to Step 1 with the user.
- Pass `--origin` only when `import` handed the target over (E40_S03_T03). A plain in-repo segment derives its own origin.

Call the engine **once, unwrapped**. It writes `--json-out` before the document on purpose, so a failed JSON write never leaves an orphaned document behind; re-ordering or wrapping the call breaks that guarantee.

**Step 3 — Fill in the judgement sections** of the written document (`Purpose`, `Risk Areas`, `Open Questions`) per **Output: the Understanding Document** above, then give the user the document path.

**Step 4 — Choose the parent epic before proposing anything.** A segment rarely deserves an epic of its own.

List `project/board/epics/` and apply the normal scrum-master intake rule (`agents/scrum-master.md`): consider whether the segment belongs under an **existing** epic before creating a new one, and treat the standing **`Maintenance`** epic as the default home for chore-shaped work that belongs nowhere else. Three inputs decide it:

- **Step 1 said `linked`** — the epic of the item that already references the target is the default parent. Do not open a sibling epic for code that is already spoken for.
- **The document's `Purpose` matches an existing epic's Purpose** — that epic is the parent.
- **Neither** — `Maintenance` if the work is a chore; a new epic only when the segment is genuinely a body of work no existing epic covers.

A new epic is the last option, not the default, and needs a stated reason. Record the epics you weighed and rejected — "none fit" is a claim the user should be able to check.

**Step 5 — Draft the proposal** using `skills/j-uncharted/assets/SEGMENT_PROPOSAL_TEMPLATE.md`. Its six headings are fixed; fill every one of them. Two things it will not let you skip:

- **Every proposed task carries `execution_scope` and a non-empty `scope_rationale`** containing a file-count or line-count claim, assigned against `project/configs/scope-thresholds.json` rather than by feel — `inline` at or under 1 file / 20 lines, `story` when tasks share files across the story (up to 5 files), `task` otherwise. Never self-assign `execution_scope: epic`: it requires `epic_scope_approval: true`, which only a human sets. Propose `story` and say the task looks bigger instead. Field semantics live in `templates/SCRUM_BOARD_SCHEMA.md` — read them there, do not paraphrase them here.
- **The document's `Open Questions` carry over verbatim**, not re-derived, each with who can answer it and whether it blocks confirmation. A blocking question is resolved *before* the proposal is accepted, because the breakdown depends on its answer.
- **Propose everything the board file will contain**, not just titles. Each story's Acceptance Criteria and Definition of Done are proposed at the gate, and a new epic's Purpose and Definition of Done with it — `scripts/validate-story-format.sh` requires those sections, so anything missing here is text `E40_S02_T03` would have to invent after the user has already said yes.

Ground every story and task in a specific finding — the untested file, the named dependency, the oversized module. A breakdown that would fit any codebase has failed for the same reason a generic understanding document has.

**Step 6 — Stop at the confirmation gate.** Present the filled proposal in the session and offer the choice from its `## Decision` section, per the Interaction Pattern in `CLAUDE.md`. **The template's `## Decision` block is authoritative** — it is the presentation contract, and the copy below is a reading convenience. If the two ever disagree, the template wins and this passage is the one to fix:

1. **Accept as proposed** — write these items to `project/board/`
2. **Revise** — change the stories, tasks, or scopes before anything is written
3. **Fit it under a different epic** — re-parent the proposal and show it again
4. **Discard** — keep the understanding document, write no board items
5. **Other (describe below)**

Option 1 is unavailable while any Open Question is marked as blocking. Resolve it first — the answer usually changes the breakdown — then re-present.

**Nothing under `project/board/` is created or modified before option 1 is chosen.** Not a stub epic, not a placeholder task, not an ID reservation, not "just the epic so the stories have somewhere to hang". Everything from Step 4 onward leaves `git status` unchanged — the only file this flow has written by now is the understanding document from Step 2, and that lives in `project/rapports/analysis/`.

Options 2 and 3 loop back to Step 5 (or to Step 4 for a re-parent) and re-present the proposal **in full**; nothing is written between rounds, because a half-written board is exactly the outcome this gate exists to prevent. Option 4 leaves the understanding document as the output — a legitimate result, not a failure. Silence, a counter-question, or an ambiguous reply is **not** consent; re-ask.

**Where this stops.** Resolution, linkage, the understanding document, and a *confirmed* proposal are the whole of Steps 1-6. Nothing reaches `project/board/` until option 1 is chosen; then Step 7 writes it.

**Step 7 — Write the accepted items to the board.** Only reachable from option 1, and only after any blocking Open Question is resolved.

The proposal is the input and the **only** source of content. Everything the board files contain — the epic's Purpose and Definition of Done, each story's `As a …, I want …, so that …` line, Acceptance Criteria, and Definition of Done, each task's `execution_scope` and `scope_rationale` — was proposed at the gate and is transcribed **verbatim**. Nothing is composed, expanded, or improved at write time. If a field looks wrong now, that is a revision (option 2), not an edit in passing: text the user did not read has no business on the board, which is the whole point of the gate.

Shape, field names, and file naming come from `templates/SCRUM_BOARD_SCHEMA.md`. Read them there — do not paraphrase them here. Five things it will not let you skip:

- **Parent before child.** Epic (if new), then stories, then tasks. The schema's Linking Convention makes the epic's `stories[]` and each story's `tasks[]` the authoritative index, so a child written before its parent leaves an index nobody has updated.
- **IDs continue the sequence they belong to.** `E##` is the next free epic number board-wide, but `S##` is the next free story number **within its parent epic** and `T##` the next free task number **within its parent story** — that is what the `E##_S##_T##` shape means. Story numbers restarting per epic is normal and expected, not a collision. Nothing catches an error here: `validate-board.sh` checks an ID's *shape*, never its uniqueness or its sequence, so a well-formed wrong number passes every gate in Step 7 and quietly reuses an ID that already meant something else.
- **Take the advisory lock** described under the schema's File Locking section before each write, and release it with a `trap` so a failed write does not leave a `.lock` behind that blocks the next agent for good.
- **`status: Pending`, `date_created` today, `date_started` empty.** These items have not been executed. Only the tester moves a status off `Pending` — do not write anything else, however confident the proposal was.
- **`jenga_assigned: true`** for scopes assigned at Step 5 against `project/configs/scope-thresholds.json`. If the user changed a scope during a Revise round, that scope was a human override: `jenga_assigned: false` **with** an `override_justification` saying what they changed and why. Never set `epic_scope_approval` — only a human sets that.

Then prove it mechanically rather than asserting it:

```bash
bash skills/j-uncharted/scripts/validate-proposed-items.sh <every file just written>
```

It runs `scripts/validate-board.sh` over every file and `scripts/validate-story-format.sh` over every story file, and exits non-zero listing **each** failure — not just the first, because deciding whether to repair or roll back needs the whole list. Exit 2 means a usage error or a missing validator, not a bad board file.

**A non-zero exit leaves you mid-write, and that is the one state this flow must not end in.** Repair the named files and re-run, or delete everything written in this step and return to Step 5 with the failures. Deleting is safe here and only here: every one of these files is new, so there is nothing to restore. Never report success, and never hand off to Step 8, on a board that has not passed.

On success, tell the user exactly which files were created, with their IDs.

**Step 8 — Hand off to the standard path.** Queue each new task with the canonical todo owner — `scripts/todo_manager.sh add "<entry>"`, one call per task, referencing the task ID — and the work then proceeds through the ordinary `/todo` → `/do` → developer → tester path, with no special casing anywhere along it. Point the tasks' Description at the understanding document from Step 2; it is the context the developer picking one up would otherwise lack.

**`/uncharted` writes board files and stops there.** It does not adapt the segment to project conventions, edit or move the code it just analysed, open a worktree, or write an execution plan. That is ordinary developer work, driven by ordinary task files, and it is the developer agent's job — the same as for a task that came from `/brainstorm` or `/pi-plan`. A segment that has reached the board is no longer a special case, and this skill growing its own integration path would be a second, divergent execution route for work the existing one already handles.

#### Conversational investigation (`--mode investigate`)

New in **E20_S08_T03**. Produces a plain-language understanding plus graph nodes for a *specific* target — the same conversational mechanics as `onboard`'s default flow, applied at single-target scale instead of whole-codebase scale. Read **Conversational Elicitation** above (Human-Oracle-Availability Limitation, Directory Triage, Convergence Loop, Multi-Session Persistence) before running this — everything below only sequences those shared mechanics for `segment`'s scope; it does not redefine them.

**Step 1 — Resolve the target.** Reuse `resolve-segment-target.sh` exactly as the delivery-shaped path's own Step 1 does above — do not reimplement resolution or the board-linkage check for this mode. A `linked` target is a normal condition here (unlike the delivery-shaped path, an existing epic/story/task referencing the target doesn't disqualify investigating it), but still tell the user before proceeding, the same as the delivery-shaped path does.

**Step 2 — Directory triage, only if the target is a directory with subdirectories.** A single-file target has nothing to triage; skip straight to Step 3. For a directory target, run the shared Directory Triage procedure above against the target's immediate subdirectories as the candidate set.

**Step 3 — Convergence loop.** Run the shared Convergence Loop procedure above. For a single-file target this is one node; for a directory target (after triage) it is one node per surviving candidate. Initialize persistence first:

```bash
bash skills/j-uncharted/scripts/elicitation-state.sh init --id "segment-investigate-$(basename "$RESOLVED_TARGET")-$(date -u +%Y%m%d)" --target "$RESOLVED_TARGET"
```

**Step 4 — On convergence, write the graph and the board item.** Write each converged node/edge to `project/knowledge-graph/graph.json` per the stub schema (`source: "human"`), then present a single `[ARCH]`-tagged board item proposal — epic, story, or task, whichever level fits what was actually investigated (a single flow is usually task-scale; a whole subsystem may warrant a story or, rarely, an epic) — and stop at the same kind of confirmation gate the delivery-shaped path's Step 6 uses (accept / revise / discard / other). **Nothing is written to `project/board/` before that gate is confirmed**, matching the delivery-shaped path's own "nothing written before option 1" guarantee. On acceptance, write the board item and call `elicitation-state.sh complete`.

**This mode never produces a delivery-shaped epic/story/task proposal.** If the investigation surfaces work that should actually be *built* (not just understood), say so as a follow-up recommendation in the `[ARCH]` item's own text and let the user separately invoke `--mode delivery` or `/todo` for that — conversational investigation and delivery planning stay two distinct outputs, per this mode split's own purpose.

### `import`

Pull an external source into the repo, then investigate it as a segment.

> **Status: `import` is complete end to end (E40_S03_T01–T03).** Acquisition, provenance
> surfacing and placement confirmation, and the move-and-handoff into `segment` are all live.
> `import` contributes exactly two things `segment` does not — acquisition (Steps 1-2) and
> placement (Steps 3-6) — then Step 7 hands off into `segment`'s own flow for everything else.
> No enumeration, dependency-detection, or test-detection logic is duplicated here; that all
> lives in `segment` and the shared engine.

**Step 1 — Acquire into staging.** Deterministic; do not hand-roll a clone or a copy.

```bash
SUMMARY_JSON=$(bash skills/j-uncharted/scripts/import-source.sh --json-only "<source>")
```

`<source>` is a git URL, a local path **outside** this repo, or `-` (with the snippet piped
on stdin, `--type snippet --name <filename>`). Read four fields off `SUMMARY_JSON`:
`source_type`, `source`, `staging_path`, `content_path`, and `git_ref` (the short HEAD SHA,
present only for a `git`-type acquisition — `import-source.sh` deletes the clone's `.git`
directory immediately after reading it, as part of treating acquired content as hostile, so
this is the **only** point at which that SHA is ever recoverable). Exit codes and the full
security contract (no hooks, no install scripts, staging always outside the repo working
tree) are documented in the script's own header — read them there, do not restate them here.

**A non-zero exit here means nothing was acquired.** Surface the script's stderr to the user
and stop; there is no staging directory to clean up in that case (the script cleans up after
itself on failure).

**Step 2 — Inspect provenance.** Also deterministic, and mandatory before Step 3 — the
destination proposal is presented *alongside* these findings, never before them.

```bash
PROVENANCE_JSON=$(bash skills/j-uncharted/scripts/inspect-provenance.sh \
  --origin-source "$(echo "$SUMMARY_JSON" | jq -r .source)" \
  --origin-type   "$(echo "$SUMMARY_JSON" | jq -r .source_type)" \
  --origin-ref    "$(echo "$SUMMARY_JSON" | jq -r '.git_ref // ""')" \
  "$(echo "$SUMMARY_JSON" | jq -r .content_path)")
```

Forward `source` / `source_type` / `git_ref` from Step 1's summary exactly like this — do not
omit the `--origin-*` flags because they look redundant with what's already on disk.
`inspect-provenance.sh` cannot recover them itself: acquisition already deleted the `.git`
directory that held them. What it *does* find live on disk is reported independently: any
LICENSE/LICENCE/COPYING/UNLICENSE/NOTICE file (with a best-effort type classification), any
`SPDX-License-Identifier` headers, copyright lines near the top of files, and any **nested**
`.git` directory the acquisition didn't strip (a vendored checkout, for instance).

**Read every section's `message` field, not just `found`.** `inspect-provenance.sh` states
explicitly, per category, when nothing was found — `license.message`, `spdx_identifiers.message`,
`copyright.message`, `git_origin.message` are all non-null exactly when that section is empty —
and `overall.message` restates it plainly when *every* section comes back empty. **Never
translate "no license file was found" into "this source is unencumbered" or anything implying
it.** This is an informational surface, not a legal clearance: state what was found, state
plainly when nothing was, and let the user decide. The script's own stderr also carries
scan-scope notices (directories excluded from the content scan, symlinked files that were
found but never opened for safety, a `--max-files` cap being hit) — read them, the same as any
other engine script's stderr.

**Step 3 — Propose a destination.** Judgement, not a script: derive a short slug from the
source (the repo name, the snippet's `--name`, the last path component of a local source) and
propose a location under the repo that fits where similar content already lives — alongside a
related existing area when one is evident from the source's contents, or a clearly-named new
top-level location when nothing existing fits. State *why* briefly; a bare path with no
rationale gives the user nothing to evaluate at Step 4.

**Step 4 — Confirm before anything leaves staging.** Present the proposed destination
together with the Step 2 findings, then require an explicit numbered choice, per the
Interaction Pattern in `CLAUDE.md` — free-text last:

```
Provenance findings for <source>:
<Step 2's findings, summarised — license/SPDX/copyright status, and the overall message
 verbatim when nothing was found>

Proposed destination: <path>
<one-line rationale>

How should this be placed?
1. Use the proposed path
2. Use a different path (name it)
3. Abort the import
4. Other (describe below)
```

**Silence, a counter-question, or an ambiguous reply is not consent** — re-ask, the same
convention `segment`'s Step 6 uses. Option 2 loops back to Step 3 with the user's named path in
place of the derived one and re-presents this same confirmation; it does not silently accept a
path that was never shown back to the user for approval.

**Nothing under the repo working tree is written by reaching this gate.** Content stays in
`content_path`, exactly where Step 1 left it, until the user picks option 1 or a confirmed
option 2 path.

**Step 5 — Abort leaves no trace.** Option 3 removes the entire staging root (not just
`content_path`) —

```bash
rm -rf "$(echo "$SUMMARY_JSON" | jq -r .staging_path)"
```

— and stops. Confirm with `git status` that the working tree is unchanged; nothing from this
flow was ever written under it, so there is nothing to revert, only the staging directory to
discard.

**Step 6 — Move into place.** Reachable only from a confirmed destination: option 1 at Step 4, or
a confirmed option 2 path. This is a plain filesystem operation — `import-source.sh` staged
content, it does not place it, and there is no dedicated placement script because the semantics
are simple and specific to this one call site:

```bash
DESTINATION="<confirmed path, repo-relative>"
CONTENT_PATH="$(echo "$SUMMARY_JSON" | jq -r .content_path)"
STAGING_PATH="$(echo "$SUMMARY_JSON" | jq -r .staging_path)"

if [ -e "$DESTINATION" ] && [ -n "$(ls -A "$DESTINATION" 2>/dev/null)" ]; then
  echo "Destination already exists and is not empty — this would overwrite existing content." >&2
  # Stop. Go back to Step 4 with a different path; do not merge into or overwrite it.
else
  mkdir -p "$DESTINATION"
  cp -R "$CONTENT_PATH/." "$DESTINATION/"
  rm -rf "$STAGING_PATH"
fi
```

`content_path`'s contents land **directly under** the destination directory — never nested
inside an extra subdirectory — whether `content_path` holds a whole tree (a cloned repo, an
imported directory) or a single file (a snippet, a single imported file). The staging root is
removed afterward the same way Step 5 removes it on abort, but for the opposite reason: the
content now has a permanent home, not because it is being discarded.

**Refuse to overwrite.** A destination that already exists and is non-empty is not merged into
or clobbered — stop and return to Step 4 for a different path. This is the same "never silently
written into an arbitrary path" guarantee the confirmation gate exists to uphold; it applies just
as much to what is already there as to what the user did not confirm.

The placed files are new, uncommitted content in the working tree at this point — `/uncharted`
places them and stops; it does not commit. Committing them is ordinary work for whichever task
Step 7 below eventually queues, the same as any other new file a task depends on.

**Step 7 — Hand off to `segment`.** The source is now at its final in-repo path. From here,
`import` contributes nothing further: everything below is `segment` mode's own flow (above), run
against the destination, not a second implementation of it.

- Run **segment's Step 1** (`resolve-segment-target.sh`) against `$DESTINATION` for its
  board-linkage status. A freshly placed path is normally `unlinked`, but check rather than
  assume — a board item could already reference the intended path from prior planning.
- Run **segment's Step 2** (`run-engine.sh --mode segment "$DESTINATION" --origin "imported from
  $(echo "$SUMMARY_JSON" | jq -r .source)"`) — exactly the case segment's own Step 2 note
  anticipates ("Pass `--origin` only when `import` handed the target over").
- **At segment's Step 3 (filling the judgement sections), carry the provenance findings from
  this section's Step 2 (`PROVENANCE_JSON`) into `Risk Areas` — do not re-derive or rediscover
  them:**
  - Read `PROVENANCE_JSON`'s `license`, `spdx_identifiers`, `copyright`, and `git_origin`
    sections, plus `overall.message`, and fold every finding — and the fact of an empty one —
    into `Risk Areas`, grounded exactly as segment's Step 3 already requires elsewhere: a
    specific license file (or its stated absence), a specific SPDX identifier, a specific
    copyright line, a nested `.git` left over from a vendored checkout.
  - An unclear or absent license is itself a Risk Area entry. Word it the same cautious way
    `inspect-provenance.sh`'s own `overall.message` already does — the scan found nothing, which
    is not the same claim as the source being unencumbered — and never soften it into "no
    licensing concerns".
  - Where the licensing question needs a human answer before the segment is safely integrated
    (no license file, an unrecognised SPDX identifier, an un-vetted nested `.git`), also add it
    as an `Open Questions` entry, marked `Blocks confirmation? yes` when it is serious enough to
    hold up acceptance. Segment's Step 5 already carries `Open Questions` into the proposal
    **verbatim** — recording it once here is the entire mechanism by which a provenance finding
    reaches the board proposal. There is no separate provenance field on the proposal template
    and none is needed.
- Continue through **segment's Steps 4-8** exactly as written above: choose the parent epic,
  draft the proposal, stop at the confirmation gate, and — only on acceptance — write the board
  and queue the tasks. Do not skip Step 6's confirmation gate because this section's Step 4
  already asked a question; that gate confirmed *placement*, segment's Step 6 confirms the
  *board breakdown*, and they are different decisions the user must see separately.

Nothing about enumeration, dependency detection, or test detection is re-specified here —
segment's own Step 2 (`run-engine.sh`) already does all of that, once, against the placed
destination.

### `onboard`

Give an entire pre-existing codebase board representation at framework-adoption time. Since **E20_S08_T03**, `onboard` has two modes:

| Invocation | Mode | Output |
|---|---|---|
| `onboard <root>` (default) | Conversational — human-in-the-loop elicitation seeded by the same discovery scripts | `[ARCH]`-tagged board items + coarse graph nodes in `project/knowledge-graph/graph.json` |
| `onboard <root> --legacy` | Fully-automated, zero-prompt, capped-backfilled-epic pass — E40_S04's original behavior, byte-for-byte unchanged | `provenance: backfilled` epics |

**`--legacy` is not a deprecated fallback — it is the designated tool for a codebase with no available human oracle.** Read **Human-Oracle-Availability Limitation** under Conversational Elicitation above before choosing between the two; that section states explicitly when `--legacy` is the *correct* choice, not a lesser one.

> **Build status:** the legacy pipeline (`E40_S04_T01`-`T05`: `provenance` field, subsystem discovery, cap enforcement, backfilled epic generation, `PROJECT_SUMMARY.md` population) is complete and unchanged by this rework — see **Legacy mode** below. The conversational default is new as of `E20_S08_T03` — see **Conversational default** below.

#### The hard constraint: `onboard` never touches application code

This holds in **both** modes — conversational and legacy alike.

**`onboard` mode must never modify, move, rename, delete, or restructure any file that belongs to
the consumer's application.** This is not a best-effort convention — it is the reason `onboard`
exists as a *board-only* mode rather than a generic migration tool. Its entire output surface,
without exception, is:

- `project/board/` (backfilled epics in `--legacy` mode; `[ARCH]`-tagged epics/stories/tasks in conversational mode)
- `project/rapports/analysis/` (understanding documents and the subsystem cap record — `--legacy` mode only; conversational mode's primary output is the graph, not this document type — see Conversational Elicitation above)
- `project/PROJECT_SUMMARY.md` (populated by `E40_S04_T05`, `--legacy` mode only)
- `project/knowledge-graph/graph.json` (coarse graph nodes/edges — conversational mode only, per the stub schema)
- `project/queue/elicitation-state/` (multi-session persistence scratch state — conversational mode only, git-ignored, not a durable artifact)

Nothing under any other path is ever created, edited, or deleted by `onboard` mode, in either mode. Jenga's board
and skills live *alongside* the application; the application never has to conform to a Jenga
convention to be onboarded. This guarantee is enforced in three independent places, not just
stated here:

1. **This prohibition**, read by any agent driving `onboard` mode.
2. **A structural write-path guard** in `skills/j-uncharted/scripts/write-backfilled-epics.sh` — its
   `--epics-dir` and `--json-out` destinations are canonicalised and checked against
   `<repo-root>/project/` *before* any file is written, with no flag able to point either one
   outside it. A path that resolves outside `project/` is a hard failure (exit 3), nothing
   written — not a warning that can be missed.
3. **A verifiable post-run check** (below): after a full `onboard` run, `git status` in the
   analysed repository must show changes only under `project/`.

#### Conversational default

New in **E20_S08_T03**. Runs when `onboard` is invoked without `--legacy`.

**Step 1 — discovery stays scripted.** Run the exact same deterministic discovery chain the legacy pipeline uses — `discover-subsystems.sh` — unchanged. Evidence-gathering is not where this rework touches anything; only what happens with the output differs.

```bash
bash skills/j-uncharted/scripts/discover-subsystems.sh <root>
```

**Step 2 — directory triage.** Feed the discovery output's candidate paths into the shared Directory Triage procedure (see Conversational Elicitation above), and stop at its confirmation gate before anything else happens.

**Step 3 — initialize persistence.**

```bash
bash skills/j-uncharted/scripts/elicitation-state.sh init --id "onboard-$(basename "$(cd "$root" && pwd)")-$(date -u +%Y%m%d)" --target "<root>" --cap 5
```

**Step 4 — convergence loop, once per surviving candidate.** Run the shared Convergence Loop procedure (see Conversational Elicitation above) for each candidate that survived triage — this is where the legacy pipeline's `apply-subsystem-cap.sh` and `write-backfilled-epics.sh` would have silently produced a capped set of `provenance: backfilled` epics; the conversational default asks about each one instead, subject to the same risk-weighted gating and hard turn cap. There is deliberately **no subsystem cap** on the conversational path — the turn cap already bounds cost per candidate, and capping the *candidate count* the way the legacy path does would silently drop subsystems from a human-in-the-loop conversation the same way the legacy path drops them from an unattended one, which defeats the point of asking. A codebase with far more subsystems than is practical to walk through conversationally in one sitting is exactly the multi-session case Multi-Session Persistence exists for — pause, resume across sessions, rather than truncate the candidate list.

**Step 5 — on convergence, write the graph and the board item(s).** Per candidate: write the converged node(s)/edge(s) to `project/knowledge-graph/graph.json`, then present an `[ARCH]`-tagged board item proposal at whichever level fits (an individual subsystem is usually story-scale; the whole run may warrant a single `[ARCH]` epic containing one story per converged subsystem — judgement call, not a fixed rule) and stop at a confirmation gate before writing to `project/board/`, exactly as `segment --mode investigate`'s Step 4 does. Call `elicitation-state.sh complete` once every candidate has converged, been deferred, or been resolved past the turn cap.

**`PROJECT_SUMMARY.md` population still applies, unchanged in spirit.** Once the conversational pass has produced its `[ARCH]` items, hand off to the scrum-master for the same `PROJECT_SUMMARY.md` Overview/Architecture & Structure drafting-and-confirmation flow described under **Updating PROJECT_SUMMARY.md from onboard evidence** below (Steps A-D) — substituting the conversational pass's converged understanding for the legacy pipeline's `kept` array as the evidence source. Do not skip the stub-vs-real-content check in Step B just because the evidence came from a conversation instead of a script.

#### Legacy mode (`--legacy`)

Everything below is `E40_S04`'s original, fully-automated, zero-prompt pipeline — **unchanged** by this rework, reachable only via the explicit `--legacy` flag.

#### The subsystem cap

Live as of `E40_S04_T03`. `onboard` does **not** create one epic per discovered subsystem — a
40-subsystem repository would bury the board on day one. It caps how many become epics, and
`skills/j-uncharted/scripts/apply-subsystem-cap.sh` applies that cap to `discover-subsystems.sh`'s
ranked output:

```bash
bash skills/j-uncharted/scripts/discover-subsystems.sh <root> \
  | bash skills/j-uncharted/scripts/apply-subsystem-cap.sh --rapport "$DOC"
```

It emits JSON with two explicit arrays — `kept` (the subsystems that become backfilled epics) and
`dropped` (everything below the cap, each entry carrying its path, rank, score and the reason
string `below cap of N`).

| Option | Effect |
|---|---|
| `--cap N` | **The cap. Default 8.** Raise it to backfill more subsystems. Must be `1` or higher — `--cap 0` or a negative cap exits non-zero, because "produce no epics at all" is never a meaningful onboard run. |
| `--rapport <file>` | Append the cap record to the onboard analysis document `run-engine.sh --mode onboard` already wrote. This is the normal flow: the cap record belongs with the analysis that produced it. |
| `--out-dir <dir>` | Where a standalone cap record goes when `--rapport` is not given. Default `project/rapports/analysis/`. |
| `--json-out <file>` | Also write the report to a file. stdout gets it either way. |
| `--label "<text>"` | Human label for the codebase in the record. Defaults to the analysed root. |

**Dropped subsystems are always surfaced, and are never silently truncated.** Every run writes a
human-readable `## Subsystem Cap` section into an analysis rapport under
`project/rapports/analysis/` naming **every** dropped subsystem individually, with its rank, score
and reason. That record is the point of the script, not a side effect of it: a user who onboards a
40-subsystem repo and gets 8 epics must be able to find out, later and on disk, which 32 were left
off and why — long after the chat message saying so has scrolled away. There is deliberately no
flag to skip that write, no elision in the list, and an unwritable rapport fails the whole run
rather than returning a clean result with no audit trail.

Tell the user the drop count and the rapport path. Do not paste the whole dropped list into the
conversation — it is on disk, in full, which is exactly the durability being bought here.

Nothing is dropped when the candidate count is at or below the cap: `dropped` is an empty array
and the run still exits 0. A dropped subsystem is not a rejected one — it simply has no backfilled
epic, and can be brought onto the board individually later with `/uncharted segment <path>`, or by
re-running `onboard` with a higher `--cap`.

| Exit | Meaning |
|---|---|
| 0 | Cap applied; record written (including the nothing-was-dropped case). |
| 1 | Usage error — unknown flag, non-integer cap, or a cap of 0 or below. |
| 2 | Input error — the report is missing, unreadable, not JSON, or has no `candidates` array. |
| 4 | The drop record could not be written. Fatal by design. |

#### Generating the backfilled epics

Live as of `E40_S04_T04`. `skills/j-uncharted/scripts/write-backfilled-epics.sh` is the only thing
that actually writes backfilled epics to the board — it consumes `apply-subsystem-cap.sh`'s
`kept` array and renders one epic file per entry, following the Epic format in
`templates/SCRUM_BOARD_SCHEMA.md` exactly (`provenance: backfilled`, `status: Pending`, an empty
`stories` array, a Purpose section built from the discovery evidence, and a Definition of Done
framed around understanding and integration, never original construction):

```bash
bash skills/j-uncharted/scripts/discover-subsystems.sh <root> \
  | bash skills/j-uncharted/scripts/apply-subsystem-cap.sh --rapport "$DOC" \
  | bash skills/j-uncharted/scripts/write-backfilled-epics.sh
```

| Option | Effect |
|---|---|
| `--epics-dir <dir>` | Where epic files are written. Default `<repo-root>/project/board/epics`. Must resolve under `<repo-root>/project/` — see the write-path guard above. |
| `--json-out <file>` | Also write this script's JSON summary to a file. Same guard applies. |
| `--dry-run` | Compute IDs and render content without writing anything — useful for previewing what a run would produce. |
| `--label "<text>"` | Human label for the analysed codebase, used in each epic's Purpose section. |

**Epic ID continuation.** The next free `E##` is one past the highest epic number found under
both `--epics-dir` and the canonical `project/board/epics/`, so generated epics always continue
the existing board's numbering and never collide with an epic already on it.

**Evidence honesty.** `apply-subsystem-cap.sh`'s `kept` entries carry only `path`, `rank`,
`score`, `files`, and `lines` — not the richer per-candidate signals (`manifests`, `test_paths`,
`doc_paths`, `signals`) that `discover-subsystems.sh` computes internally but does not pass
through the cap step. Each generated epic's Purpose section says exactly this, and points at
`/uncharted segment <path>` for a full understanding document before the epic is broken into
stories. Never fabricate deeper Purpose detail than the `kept` entry actually supports.

**Verifying the read-only guarantee.** After a full `onboard` run (discovery → cap → epic
generation) against a repository containing application code, confirm the guarantee held:

```bash
git status --porcelain
```

Every line must start with a path under `project/`. Any other path in that output is a defect —
`onboard` mode has no legitimate reason to touch it — and the run should be treated as failed
even if every script above exited 0.

`git status --porcelain` has a blind spot: git does not track empty directories, so a run that
creates (and leaves behind) an empty directory outside `project/` — for example from a
misconfigured or typo'd `--epics-dir`/`--json-out` — would pass this check while still having
violated the guarantee. `write-backfilled-epics.sh`'s write-path guard resolves its target paths
before creating anything, specifically so this case cannot arise from a rejected path, but when
verifying by hand it is worth also diffing the raw filesystem tree, which has no such blind spot:

```bash
find . -mindepth 1 ! -path './project/*' ! -path './project' -newer <timestamp-file-from-before-the-run>
```

An empty result confirms nothing outside `project/` was even touched, not merely that nothing
outside `project/` ended up tracked by git.

| Exit | Meaning |
|---|---|
| 0 | Epics written (including a `kept` array of length zero: 0 epics is a valid outcome). |
| 1 | Usage error — unknown flag, missing value. |
| 2 | Input error — the report is missing, unreadable, not JSON, or has no `kept` array. |
| 3 | Write-path guard — `--epics-dir` or `--json-out` resolved outside `<repo-root>/project/`. |
| 4 | Write failure — an epic file could not be written, or an existing epic file could not be read while computing ID continuation. |

#### Updating PROJECT_SUMMARY.md from onboard evidence

Live as of `E40_S04_T05`, and reused by both `onboard` modes since `E20_S08_T03` — the conversational default's own Step 5 above hands off here too, substituting its converged understanding for the `kept` array as the evidence source described below. Nested under Legacy mode structurally only because it was written before the conversational path existed; treat "Steps A-D" as shared, not legacy-only.

This is the last step of an `onboard` run, after the backfilled epics (legacy) or `[ARCH]` items (conversational)
above have been written (or confirmed skipped). Its job is to close the gap the epic itself
describes: a project adopting Jenga should not end up with a populated board sitting underneath a
`PROJECT_SUMMARY.md` that still reads as if the codebase were empty.

**This is a scrum-master action, not a script.** Nothing under `skills/j-uncharted/scripts/` writes
`PROJECT_SUMMARY.md`, and the developer agent never touches it either — both `agents/developer.md`
and `agents/scrum-master.md` already establish `PROJECT_SUMMARY.md` as scrum-master-owned, sole
writer, no exceptions, and `onboard` does not get to be the exception just because the content
originated from an automated discovery pass. Whichever agent is driving `onboard` performs the
scripted steps above itself, but for this step it hands the drafting and the write to the
scrum-master rather than doing it inline.

**Inputs — reuse the evidence already produced, derive nothing new:**

- The onboard understanding document(s) under `project/rapports/analysis/` written by
  `run-engine.sh --mode onboard` (in particular their `Purpose` and `Structure` sections).
- The `kept` array from `apply-subsystem-cap.sh` — the same subsystems that became backfilled
  epics, with the same `path`, `rank`, `score`, `files`, and `lines` fields described under
  **Evidence honesty** above. Do not re-run discovery or invent detail those entries don't carry;
  if the epics' Purpose sections had to point at `/uncharted segment <path>` for deeper detail,
  the summary draft is bound by the same limit.

**Step A — Draft, don't write yet.** From the inputs above, draft replacement text for two
sections of `project/PROJECT_SUMMARY.md`:

- **Overview** — what the project is, in the terms the onboard evidence actually supports (what
  it does, for whom, at what scale), not a generic description that would fit any codebase.
- **Architecture & Structure** — one entry per **kept** subsystem: what it is and how it relates
  to the others (depends on, is depended on by, sits alongside). This is prose about
  responsibilities and relationships, not a listing of file paths. A draft that reads as "`src/`,
  `lib/`, `api/`" with no relationship stated has failed this step, even if every path is correct.

**Step B — Check both sections for existing content before proposing anything.** A section counts
as a **stub** only if its body is empty, whitespace-only, or is (or is limited to) the literal
placeholder text from `skills/init/assets/PROJECT_SUMMARY_template.md` — `_To be completed._`.
Anything else — a sentence, a partial list, a paragraph someone already wrote by hand — is real,
non-stub content, however short, and is never silently overwritten. Check the Overview and
Architecture & Structure sections independently; one can be a stub while the other is not.

**Step C — Present for confirmation, every time, stub or not.** Consistent with the
confirm-before-writing convention `segment` mode already uses at its Step 6, and with **Confirm
before writing to the board** under Constraints below (which this step extends explicitly to
`PROJECT_SUMMARY.md`, since that file sits outside `project/board/`): show the drafted Overview and
Architecture & Structure text in the session before writing anything. What is offered depends on
what Step B found:

- **Both sections are stubs.** Show the draft and ask for a straight go/no-go:

  ```
  Ready to populate PROJECT_SUMMARY.md's Overview and Architecture & Structure from the onboard
  evidence?
  1. Write it as drafted
  2. Revise — change the draft before writing
  3. Skip — leave PROJECT_SUMMARY.md untouched
  4. Other (describe below)
  ```

- **Either section has real, non-stub content.** Never overwrite it by default. Present the
  numbered choice from the task's Acceptance Criteria, per the Interaction Pattern in `CLAUDE.md`:

  ```
  PROJECT_SUMMARY.md's <Overview and/or Architecture & Structure> section already has content.
  How should the onboard findings be applied?
  1. Merge — integrate the onboard findings into the existing text, keeping what's there
  2. Replace — overwrite the existing section with the onboard draft
  3. Skip — leave this section untouched
  4. Other (describe below)
  ```

  Ask this once per affected section if only one of the two is non-stub, or once covering both if
  both are. **Replace is the only option that removes existing prose.** Merge means the
  scrum-master integrates the two — existing text stays, onboard findings are woven in or appended
  — never a silent supersede dressed up as a merge.

Silence, a counter-question, or an ambiguous reply is not consent, the same as at `segment`'s
Step 6 — re-ask rather than proceeding.

**Step D — Write, scoped to exactly what was confirmed.** Only the scrum-master writes, only to
`project/PROJECT_SUMMARY.md`, and only the section(s) and content actually confirmed in Step C —
a "skip" on one section must not carry an incidental edit to it from a "replace" on the other.
Like epic generation above it, "skip" on both sections is a valid outcome, not a failure: a run
that leaves `PROJECT_SUMMARY.md` untouched still respects the read/write surface named under **The
hard constraint** above, since that file was never a required write, only a permitted one.

---

## Constraints

These hold across every mode:

- **Read-only against application code**, with one exception: `import` mode writes an acquired source to a location the user has explicitly confirmed. Nothing else in this skill modifies, moves, or restructures a consumer's code.
- **Confirm before writing to the board.** Proposals are presented for approval first, consistent with the brainstorm-before-commit convention. Since `E20_S08_T03`, this also covers Directory Triage's confirmation gate and each converged node's graph/board write in the conversational elicitation flow — same convention, applied to a new output type (graph nodes), not a new exception to it.
- **No new rapport type.** Understanding documents use the existing `analysis` type and land in `project/rapports/analysis/`. Conversational elicitation's output (graph nodes + `[ARCH]` board items) is not an understanding document and does not need one — see Conversational Elicitation above for what it produces instead.
- **Never invent findings.** If the evidence does not support a conclusion, say so under Open Questions (delivery-shaped/legacy paths) or state the uncertainty plainly in the node itself (conversational paths — see Human-Oracle-Availability Limitation above).
- **Deterministic work belongs in `skills/j-uncharted/scripts/`**, agent judgement belongs here.
- **Existing zero-prompt behavior is never silently retired.** `onboard --legacy` and `segment --mode delivery` reproduce exactly what `/uncharted` did before `E20_S08_T03`, with no behavior drift for a caller who keeps using them.

---

## Entry Points

`/uncharted` is invocable directly, and is also offered automatically at the two moments it is most needed (E40_S05):

- **`/init`** — when scaffolding detects a non-empty, non-Jenga-scaffolded directory, it offers `onboard` instead of proceeding as though the project were empty. Since `E20_S08_T03`, this offer surfaces both `onboard` modes — the user picks conversational (default) or `--legacy` at that point, per the mode choice this section describes; `/init` itself makes no decision about which is appropriate.
- **`/reconcile`** — when its normal sync pass finds code with no board linkage, it offers `segment` for the affected paths. Since `E20_S08_T03`, this offer surfaces both `segment` modes the same way.

Both are offers, never automatic execution.

---

## Session End

When this skill's session concludes, emit the following signal on its own line so the Jenga Router clears the active session:

```
[JENGA:SESSION_END:uncharted]
```
