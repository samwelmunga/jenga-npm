---
name: j.jenga
description: Interactive-by-default board orchestrator with a fully automated escape hatch. Bare `/jenga` renders a picker and confirmation tree before scoping the run; `/jenga <ids>` resolves an explicit fuzzy-ID scope and confirms it; `/jenga *` reproduces the original zero-prompt behavior — decomposing any unbroken Epics into Stories, any unbroken Stories into Tasks, queuing all unqueued Tasks into todo.md, then executing every eligible item with no user prompts — until the board is fully started.
output_types:
  - when: detect-nl-intent
    type: id_list
keywords:
  - jenga
  - orchestrate
  - auto implement
  - full board
  - automated
examples:
  - "run jenga to implement everything"
  - "start the full automation"
metadata:
  prefered_agent: scrum-master
---

# Jenga — Auto-Implementation Orchestrator

## Purpose

`/jenga` is interactive by default — it never silently commits to the whole board without showing the user what it's about to run and letting them scope or edit that selection first. It has three entry modes:

- **Bare `/jenga`** (no argument) — renders a numbered picker of the full board, then an editable confirmation tree, before anything executes.
- **`/jenga <ids>`** (explicit comma-separated scope) — resolves the given IDs via the fuzzy-ID grammar, skipping the picker, then still shows the same editable confirmation tree before executing.
- **`/jenga *`** (literal wildcard) — the explicit escape hatch. Skips both the picker and the confirmation step entirely and reproduces the original hands-free "commit to everything on the board" pipeline: the entire board is fully decomposed, fully queued, and fully executing — without any user interaction, no user prompts. This is the only path where `/jenga` runs with no user prompts at all.

Once a run's scope is established (by confirmation, or unconditionally under `*`), `/jenga` runs the same underlying phases against that scope: **entry mode resolution → decompose → queue → execute → loop**.

## Instructions

### Phase 0 — Load threshold config

Read `project/configs/scope-thresholds.json`.

If the file does not exist, emit:
```
ERROR: project/configs/scope-thresholds.json not found. Cannot proceed.
```
and halt. Do not fall back to any default values.

If the file is not valid JSON, emit:
```
ERROR: project/configs/scope-thresholds.json is malformed (invalid JSON). Cannot proceed.
```
and halt.

Extract the following named values for use throughout this skill:
- `inline_max_files` — maximum files a task may touch to qualify for inline execution scope
- `inline_max_lines` — maximum total lines changed for inline scope
- `story_max_files` — maximum files a task may touch to qualify for story-scope bundling
- `bundle_lock_ttl_minutes` — time-to-live in minutes for a story-scope bundle lock

These values must be read fresh on each invocation. Never use hardcoded fallbacks.

### Phase 0.5 — Pre-flight Validation

Before accepting any task for decomposition or execution, the executing agent must validate the task's scope fields. The threshold values loaded in Phase 0 may be referenced in error messages for context, but are not required for the core validation rules below.

For each task read from the board, apply the following checks in order:

#### Rule 1 — Valid execution_scope value

If the task frontmatter contains an `execution_scope` field, its value must be one of: `task`, `story`, `epic`, `inline`.

If the value is anything else, halt immediately with:

```
VALIDATION ERROR [<task_id>]: execution_scope "<value>" is not a valid scope. Allowed: task, story, epic, inline.
```

Do not proceed with this task.

#### Rule 2 — scope_rationale must contain a measurable claim

If `execution_scope` is present, `scope_rationale` must also be present and must contain at least one digit (0–9) or the word "file" (case-insensitive).

If `scope_rationale` is absent, or present but contains no digit and does not contain the word "file", halt with:

```
VALIDATION ERROR [<task_id>]: scope_rationale is missing or lacks a numeric/file-count claim. Provide a rationale that includes a digit (e.g. "touches 2 files") or the word "file".
```

Do not proceed with this task.

#### Rule 3 — epic scope requires explicit human approval

If `execution_scope` is `"epic"`, the task must also have `epic_scope_approval: true` set explicitly in its frontmatter. A missing `epic_scope_approval` field and a value of `false` are both rejection conditions.

If `epic_scope_approval` is absent or is not exactly `true`, halt with:

```
VALIDATION ERROR [<task_id>]: execution_scope=epic requires epic_scope_approval: true (set by human operator). This field must be added manually — it is never assigned autonomously.
```

Do not proceed with this task.

#### Rule 4 — crucial_level: locked forces execution_scope: inline

If the task frontmatter contains `crucial_level: locked` (per `$([ -f templates/SCRUM_BOARD_SCHEMA.md ] && echo templates/SCRUM_BOARD_SCHEMA.md || echo node_modules/@jenga-ai/agent/templates/SCRUM_BOARD_SCHEMA.md)`'s Crucial Flag Fields), `execution_scope` for that task MUST be `inline` — only the current foreground/inline session can pause mid-run for a live confirmation; a backgrounded subagent has no live channel back to the user.

This rule **auto-corrects and continues**; unlike Rules 1-3, it never halts.

- If `execution_scope` is present and its value is anything other than `inline`, correct it to `inline` directly in the task file, and record a logged note of the correction by appending to that task's `override_justification` frontmatter field (the auditable mechanism for this rule — do not use `events.json` or any other location) a line of the form:

  ```
  override_justification: "Rule 4 auto-correction <date>: execution_scope forced from '<previous_value>' to 'inline' because crucial_level: locked."
  ```

  Then emit (non-fatally — do not halt):

  ```
  AUTO-CORRECTION [<task_id>]: crucial_level=locked requires execution_scope=inline; corrected from "<previous_value>" to "inline".
  ```

- If `execution_scope` is absent entirely, set it to `inline` directly in the task frontmatter. Do **not** fall through to the Backward-compatibility default of `execution_scope: task` documented immediately below — a `locked` item overrides that default even when no other execution-scope fields are present. No `override_justification` note is required in this case, since there is no prior value being overridden.

Proceed to the next rule (or the next phase, if this was the last applicable rule) after applying the correction.

#### Backward compatibility — legacy tasks

If the task frontmatter contains **none** of `execution_scope`, `scope_rationale`, `needs_docs`, `jenga_assigned`, or `override_justification`, treat the task as a legacy task:

- Assume `execution_scope: task`
- Assume `needs_docs: true`
- Skip all three rules above and proceed without error.

#### Validation success

If all applicable rules pass (or the task is a legacy task), proceed to the next phase for that task without any error output.

---

### Phase 0.75 — Entry Mode Resolution

This phase determines **how `/jenga` was invoked** and, for two of the four entry modes, produces a **scoped set** — a confirmed list of board IDs (epics/stories/tasks) that Phases 1-4 must restrict themselves to. All board scanning, ID parsing, cascade expansion, and rendering used by this phase already live in `skills/jenga/scripts/` per this repo's "Scripts Over Inline Logic" principle — this phase never re-implements any of that logic inline. The executing agent's job here is limited to: invoking the right script with the right arguments, relaying its STDOUT verbatim to the user when the contract calls for that, capturing the `STATE_FILE:` line from STDERR for the next turn, and forwarding the user's raw reply back into the next invocation unmodified.

**Determine the invocation form** from the raw argument (if any) passed to `/jenga`:

- No argument at all → **bare branch**.
- The argument is the literal string `*` → **wildcard branch**.
- Any other non-empty argument → invoke `skills/jenga/scripts/detect-nl-intent.sh "<raw argument>"` (E53_S01_T01) and branch on its `classification` field:
  - `all_resolved` or `mixed` → **scoped branch** (below) — this is the same branch as before; only its internal mechanics changed (see below).
  - `nl_intent` → **natural-language branch** (below) — new for E53_S01, no new sigil or entry point, purely a new outcome of this same argument-shape detection.

#### Wildcard branch (`/jenga *`)

Skip both the picker and the confirmation step entirely. There is no scoped set — proceed to Phase 1 unrestricted, exactly as `/jenga` behaved before this phase existed.

#### Bare branch (`/jenga`)

1. Invoke `skills/jenga/scripts/render-picker.sh` with no arguments (start mode). Relay its STDOUT (the numbered checklist) to the user verbatim — no summarizing, no reformatting. Capture the `STATE_FILE:` path from STDERR.
2. Wait for the user's chat reply, then invoke `skills/jenga/scripts/render-picker.sh <state_file> "<raw_reply>"` (continue mode).
   - **Error turn** (plain text on STDOUT, state file retained) — relay verbatim and return to step 2 for another reply.
   - **Cancellation** — relay the cancellation acknowledgement and halt the entire `/jenga` run; do not proceed to any later phase.
   - **Resolved** (JSON object on STDOUT, state file removed) — extract `resolved_ids_csv` and continue to the shared confirmation step below.

#### Scoped branch (`/jenga <ids>`)

This branch is entered when `detect-nl-intent.sh` (invoked above) classifies the argument as `all_resolved` or `mixed` — the picker is skipped entirely in this branch. `detect-nl-intent.sh` has already invoked `resolve-id.sh` internally and reduced its per-segment output to one of these two shapes; `skills/jenga/SKILL.md` never parses `resolve-id.sh`'s raw array itself (see `detect-nl-intent.sh`'s own header comment for the full classification contract, E53_S01_T01).

1. On `all_resolved`, take the `resolved_ids` (or `resolved_ids_csv`) field directly from `detect-nl-intent.sh`'s output and continue to the shared confirmation step below.
2. On `mixed`, halt this phase (do not proceed to confirmation or Phase 1) and report each entry in `detect-nl-intent.sh`'s `rejected` array — its `input` and `reason` — to the user verbatim; a partial or ambiguous ID is never guessed. The user must re-invoke `/jenga <ids>` with corrected input.

#### Natural-language branch (`/jenga <free-form text>`)

This branch is entered when `detect-nl-intent.sh` classifies the argument as `nl_intent` — every comma-delimited segment failed the ID grammar, so the raw argument is treated as natural-language intent rather than a malformed ID list. This is purely a new *outcome* of the same argument-shape detection above — no new sigil, trigger prefix, or separate entry point is introduced.

1. **Load the catalog** — invoke `skills/jenga/scripts/load-nl-catalog.sh` with no arguments (E53_S01_T02). Its stdout is the full skill catalog (`name`/`description`/`keywords`/`examples`/`prefered_agent` per skill), sourced exclusively from `lib/generate-skill-allow-list.js`'s generated inventory — see the script's own header for the full contract. Never re-derive this catalog by re-scanning `skills/` inline.
2. **Match** — run `skills/route/SKILL.md`'s **Step 2 — Match the Prompt to a Skill** (the three-pass keyword → example-similarity → description match, including its tie-break and no-match handling) against this catalog, treating `detect-nl-intent.sh`'s `raw_argument` field as the prompt. Reuse that section's matching logic by reference — do not re-author its prose here.
3. **Confident single match** — report the routing decision using `skills/route/SKILL.md`'s **Step 7 — Report Routing Decision** format (substitute `/jenga` for `/route` as the invoking command named in the report), then invoke the matched skill exactly as `skills/route/SKILL.md`'s **Step 6 — Invoke the Matched Skill** already does: load `agents/<prefered_agent>.md` when the matched skill specifies `metadata.prefered_agent`, otherwise execute the skill instructions directly. The matched skill's own execution takes over from here — do not continue into this `/jenga` invocation's Phase 1.
4. **No match, or an ambiguous multi-way tie (single-skill match)** — before surfacing `/route`'s generic disambiguation options, attempt a **playbook fallback** (E53_S02): invoke `skills/jenga/scripts/match-playbook.sh "<raw_argument>"`. This step only ever runs when step 3 above did NOT already commit to a confident single-skill match — a confident single-skill match always wins outright and this playbook fallback is never even invoked in that case. Branch on `match-playbook.sh`'s `classification` field:
   - `playbook_match` → continue to **step 5 (Playbook proposal and execution)** below.
   - `ambiguous` or `no_match` → continue to **step 6 (Fall through to `/route`'s disambiguation)** below — the exact behavior this branch already had before E53_S02, unchanged.
5. **Playbook proposal and execution** — entered only on a `playbook_match` result from step 4. A proposed playbook is an ordered chain of skills (e.g. the canonical `brainstorm -> j.todo -> j.do -> j.dev-done -> j.mirror-public` chain defined in `skills/jenga/playbooks/brainstorm-to-mirror.json`) that must be confirmed, editable, and confirmable per `CLAUDE.md`'s Interaction Pattern before any step executes — the same confirm-before-execute posture `/jenga` already applies to the bare/scoped branches via `render-confirmation.sh`.
   a. **Resolve conditional metadata** (`E53_S04_T02`/`T04`) — before rendering, inspect the
      matched playbook's own `steps` array (as returned by `load-playbooks.sh`'s catalog, not the
      flattened string list) for any StepObject carrying a `conditional: {"depends_on": "<name>",
      "predicate": "..."}` field. Build a JSON object mapping each such step's name to its
      `depends_on` step's name only (e.g. `{"stepC": "stepA"}` — the confirmation display needs no
      predicate detail, only which step to point at). If no step carries a `conditional`, this
      object is empty/omitted.
      **Also resolve composition origin metadata** (`E53_S05_T01`/`T03`) — inspect the SAME
      `steps` array (`match-playbook.sh`'s `steps` field is already load-playbooks.sh's fully
      FLATTENED, composition-resolved catalog output — composition is invisible to
      `match-playbook.sh` itself; there is nothing further to "flatten" at this point, only to
      read) for any StepObject carrying `_origin_playbook`/`_origin_depth` (present only on steps
      whose `_origin_depth` is greater than 1 — see `load-playbooks.sh`'s header "COMPOSITION
      RESOLUTION"). Build a JSON object mapping each such step's name to `{"playbook_id":
      "<_origin_playbook>", "depth": <_origin_depth>}`. If no step in this playbook came from a
      composed/nested playbook, this object is empty/omitted.
   b. **Render and confirm the chain** — invoke `skills/jenga/scripts/render-playbook-confirmation.sh "<playbook_id>" "<name>" "<comma-separated steps>" ["<json-conditionals from 5a>" ["<json-origins from 5a>"]]` (start mode, using `match-playbook.sh`'s `playbook_id`/`name`/`steps` fields verbatim; the 4th argument is omitted entirely when 5a produced no conditionals, and the 5th argument is omitted entirely when 5a produced no composition-origin metadata — omitting both reproduces the exact pre-`E53_S04` 3-arg call, and omitting only the 5th reproduces the exact pre-`E53_S05` 4-arg call). Relay STDOUT (the numbered chain + instructions, now marking any conditional step with "(may be skipped depending on step N's result)" and any composed/nested step with indentation plus "(from playbook: <id>, depth N)") to the user verbatim. Capture the `STATE_FILE:` path from STDERR.
   c. Wait for the user's chat reply, then invoke `skills/jenga/scripts/render-playbook-confirmation.sh <state_file> "<raw_reply>"` (continue mode).
      - **Toggle or error turn** (plain text on STDOUT, state file retained) — relay verbatim and return to step 5c for another reply. This loops exactly as the existing bare/scoped confirmation flow's own toggle/error turns already do.
      - **Cancellation** — relay the cancellation acknowledgement and halt the entire `/jenga` invocation immediately, with no step executed — identical posture to the existing picker/confirmation cancellation edge cases already documented for the bare/scoped branches (see "## Edge Cases" below).
      - **Confirmed** (JSON object on STDOUT, state file removed) — take the confirmed `steps` array (checked-only, in original playbook order) and continue to step 5d.
   d. **Initialize the sequential runner** — re-derive the `<json-conditionals>` object for `run-playbook-step.sh init` from the same StepObject data as 5a, but in `init`'s own richer shape (`{"<step>": {"depends_on": "...", "predicate": "..."}}`, `E53_S04_T02`), and apply one filtering rule first: **drop any conditional whose `depends_on` step is not present in the CONFIRMED step list from 5c.** The user may have unchecked the depended-on step at confirmation; `init` would otherwise reject such a conditional outright (its existence check requires `depends_on` to be an earlier step in the run), and the more sensible fallback than a hard failure over the user's own edit is to treat that now-conditionless step as always-running for this particular execution. **Also re-derive the composition origin metadata** (`E53_S05_T04`) for `init`'s optional 5th argument, from the same `_origin_playbook`/`_origin_depth` data as 5a, filtered the same way (drop any entry for a step the user unchecked at confirmation — `init` requires every key to be present in the confirmed step list). Invoke `skills/jenga/scripts/run-playbook-step.sh init "<playbook_id>" "<name>" "<comma-separated confirmed steps>" ["<json-conditionals, filtered>" ["<json-origins, filtered>"]]` (the 4th argument is omitted when empty, and the 5th is omitted when empty — omitting both reproduces the exact pre-`E53_S04` 3-arg call, and omitting only the 5th reproduces the exact pre-`E53_S05` 4-arg call). Its `step_ready` result names the first step to invoke.
   e. **Execute steps in a loop** — for the step named by the runner's most recent `step_ready` result:
      i. **Evaluate whether this step should run** (`E53_S04_T02`) — invoke `skills/jenga/scripts/run-playbook-step.sh should-skip <state_file>`.
         - `{"skip": true, ...}` — do **not** invoke the step. Call `skills/jenga/scripts/run-playbook-step.sh advance <state_file> skipped` directly (never `passed`/`failed` for a step that never ran), then handle its result exactly as iv-vi below (`step_ready`/`complete`/`halted`) — skip step 5e-ii and 5e-iii entirely for this step, since it never runs. This is non-blocking and non-failing — it never halts the chain, and is not narrated to the user turn-by-turn (it is folded into the final `completed`/`skipped` summary reported at `complete`/`halted`, the same posture already given to individual `passed` steps, which also aren't separately narrated mid-chain).
         - `{"skip": false, ...}` — proceed to step 5e-ii and invoke the step normally.
      ii. **Resolve `forward_from` and `resolve`, if the step declares either** (`E53_S03`, runtime-wired by `E53_S04_T02`; `resolve` runtime behavior added by `E53_S06_T01`) — invoke `skills/jenga/scripts/run-playbook-step.sh get-output <state_file> <named source step>` before invoking this step. On `{"status": "found", "value": "..."}`, use that value as this step's actual invocation input (per the design's forwarding semantics). On `{"status": "unavailable", "reason": "step_skipped"}` or `"reason": "not_captured"` — the named source produced no usable value (it was itself skipped, or never captured one) — do not guess a fallback value; treat this exactly like a step failure: call `advance <state_file> failed "forward_from source '<name>' unavailable (<reason>)"` and follow the `halted` handling in 5e-vi below, without ever invoking this step. This is the documented, non-silent failure mode for a `forward_from` naming a skipped step (`E53_S04_T06`'s fixture coverage).

         **Then, if the step also declares a non-empty `resolve` field** (`E53_S06_T01`) — this is a documented, named, scoped exception to `CLAUDE.md`'s "Skill Implementation Principle — Scripts Over Inline Logic": open-ended reshaping/filtering/type-bridging genuinely needs the agent's own LLM judgment, which a deterministic script cannot provide, and `resolve` is never used for anything else in this codebase's playbook mechanism — in particular, never to pre-authorize a downstream confirmation, a combination `load-playbooks.sh` already rejects outright at load time (see `docs/skill-authoring.md`'s "The `resolve` / confirmation-gate rule"):
         - **No-op without `forward_from`** — a step carrying `resolve` but no `forward_from` (or one that resolved to no forwardable value) has nothing to reshape. This is a defined, non-crashing runtime behavior, not an error: the `resolve` field is simply ignored for that step, and invocation proceeds exactly as it would with no `resolve` field at all.
         - **Apply the transform** — when both `forward_from` (successfully resolved immediately above) and `resolve` are present, use your own LLM judgment to reshape/filter/type-bridge the forwarded value per `resolve`'s natural-language instructions (e.g. "pick the first three items", "convert this file_list to a text summary"). The transformed value — never the raw forwarded value — becomes this step's actual invocation input.
         - **Hard-fail, never silent pass-through** — if the transform cannot cleanly produce a usable, type-compatible result (the instructions don't plausibly apply to the actual value, the value is empty/malformed for what's being asked, or the result would not plausibly satisfy the target step's expected input shape), do **not** invoke this step and do **not** guess or pass through a differently-shaped value. Instead call `skills/jenga/scripts/run-playbook-step.sh advance <state_file> failed "<note>"`, where `<note>` follows the format `resolve failed on step '<step name>': could not apply "<resolve text>" to raw value <raw pre-transform value> — <short reason>` (the raw pre-transform value is always included, for debugging). Then follow the `halted` handling in 5e-vi below exactly as any other step failure — immediately stop executing further steps, report `failed_step`/`failed_note`/`completed`/`skipped`/`never_run` verbatim.

         Then invoke the step exactly as `skills/route/SKILL.md`'s **Step 6 — Invoke the Matched Skill** already does for a single matched skill: load `agents/<prefered_agent>.md` when that step's own `SKILL.md` specifies `metadata.prefered_agent`, otherwise execute its instructions directly.
      iii. After a normally-invoked step's execution concludes, call `skills/jenga/scripts/run-playbook-step.sh advance <state_file> passed ["<typed-output-value>"]` (the step completed successfully — supply the step's declared typed output, per its `output_types`, if it produced one) or `... advance <state_file> failed "<short failure note>"` (the step failed).
      iv. On a `step_ready` result, repeat step 5e for the newly-named step.
      v. On a `complete` result, report the full lists of `completed` AND `skipped` steps to the user and stop — the playbook run is finished; do not continue into this `/jenga` invocation's Phase 1.
      vi. On a `halted` result, **immediately stop executing any further steps** — no silent skip-ahead. Report `failed_step`, `failed_note`, `completed`, `skipped` (steps that already finished or were skipped), and `never_run` (steps that never got a chance to run) to the user verbatim from the halt report. Do not continue into this `/jenga` invocation's Phase 1.
6. **Fall through to `/route`'s disambiguation** — entered when step 4 found no playbook match (`ambiguous` or `no_match`). Surface the same disambiguation options `skills/route/SKILL.md`'s **Step 2** already defines for these cases (browse `/help`, create a new skill via `/btw`, or proceed with the raw prompt) by reference to that section — do not re-copy its prose. Halt this `/jenga` invocation once the user picks an option; none of Phase 0.75's remaining steps or Phases 1-4 run for this branch.

#### Shared confirmation step (bare and scoped branches only)

1. Invoke `skills/jenga/scripts/render-confirmation.sh "<comma-separated resolved ids from whichever branch above>"` (start mode). Relay STDOUT (the confirmation tree) to the user verbatim. Capture the `STATE_FILE:` path from STDERR.
2. Wait for the user's chat reply, then invoke `skills/jenga/scripts/render-confirmation.sh <state_file> "<raw_reply>"` (continue mode).
   - **Toggle or error turn** (plain text on STDOUT, state file retained) — relay verbatim and return to step 2 for another reply.
   - **Cancellation** — relay the cancellation acknowledgement and halt the entire `/jenga` run; do not proceed to any later phase.
   - **Confirmed** (JSON object on STDOUT, state file removed) — this is the final **scoped set**. Take `resolved_ids` (or `resolved_ids_csv`) as the exact set of board IDs Phases 1-4 restrict themselves to for the rest of this run.
3. **Handoff to cascade resolution** — do not invoke `cascade-resolve.sh` again here. `render-confirmation.sh` already invoked it internally to build the tree, and the CONFIRMED JSON's own `undecomposed` field is that same result already scoped down to the checked-only set. Use that `undecomposed` field directly to identify which epics/stories in the scoped set still need Phase 1/2 decomposition.

After this phase completes (bare and scoped branches via confirmation, wildcard branch immediately), proceed to Phase 1.

---

### Phase 1 — Decompose Epics into Stories

If Phase 0.75 produced a scoped set, restrict this phase to epics that are members of that set (directly selected, or flagged in its `undecomposed` list). Under `/jenga *`, this phase is unrestricted, exactly as before.

Read all files in `project/board/epics/`. For each in-scope Epic that has no corresponding story files in `project/board/stories/` (i.e. no files whose name starts with that Epic's ID), invoke `/do` via a **scrum-master sub-agent** to break it down into Stories.

Repeat until every in-scope Epic has at least one Story on the board.

### Phase 2 — Decompose Stories into Tasks

If Phase 0.75 produced a scoped set, restrict this phase to stories that are members of that set (directly selected, expanded from an in-scope epic, or flagged in its `undecomposed` list). Under `/jenga *`, this phase is unrestricted, exactly as before.

Read all files in `project/board/stories/`. For each in-scope Story that has no corresponding task files in `project/board/tasks/` (i.e. no files whose name starts with that Story's ID), invoke `/do` via a **scrum-master sub-agent** to break it down into Tasks.

Repeat until every in-scope Story has at least one Task on the board.

### Phase 3 — Queue all Tasks into `todo.md`

If Phase 0.75 produced a scoped set, restrict this phase to tasks that are members of that set (directly selected, or expanded from an in-scope epic/story). Under `/jenga *`, this phase is unrestricted, exactly as before.

Read all files in `project/board/tasks/`. For every in-scope Task not already listed in `project/todo.md`, append its ID (and title as a comment) to `project/todo.md`.

After this phase, `todo.md` reflects the full set of in-scope work (or the full board, under `*`).

### Phase 3.5 — Story-bundle detection

Before dispatching individual tasks in Phase 4, check each story for bundle eligibility. This phase runs once after Phase 3 completes.

If Phase 0.75 produced a scoped set, restrict this phase to stories that are members of that set (directly selected, or expanded from an in-scope epic) — a story with tasks sitting in `todo.md` from an earlier, differently-scoped run but that is **not** a member of the current run's scoped set is skipped entirely by this phase (not considered for bundling, and not dispatched via the bundle path) so that Phase 4's own scoped-set exclusion is never bypassed by a bundle call issued here. Under `/jenga *`, this phase is unrestricted, exactly as before.

For each in-scope story that has one or more tasks listed in `todo.md`:

1. **Read the story file** — parse the `tasks:` frontmatter array to get the ordered list of task IDs.
2. **Guard: empty task list** — if the `tasks:` list is empty (zero entries), this story is **not** eligible for the bundle path. Skip to per-task dispatch in Phase 4.
3. **Read each task file** — for every task ID in the `tasks:` list, read the corresponding task file from `project/board/tasks/`.
4. **Collect `execution_scope`** — extract the `execution_scope` field from each task's YAML frontmatter. If the field is absent or has any value other than `story`, treat that task as **not** story-scoped.
5. **Guard: locked-task disqualifier (defense-in-depth)** — for each task file already read in step 3, also read `crucial_level` (per `$([ -f templates/SCRUM_BOARD_SCHEMA.md ] && echo templates/SCRUM_BOARD_SCHEMA.md || echo node_modules/@jenga-ai/agent/templates/SCRUM_BOARD_SCHEMA.md)`'s Crucial Flag Fields). If **any** task in the story's `tasks:` list has `crucial_level: locked`, this story is **not** eligible for the bundle path — skip to per-task dispatch in Phase 4 for this story, **regardless of that task's `execution_scope` value**, even if it already reads `inline`. This check is defense-in-depth alongside Phase 0.5's Rule 4 (which forces a locked task's own `execution_scope` to `inline` when Rule 4 processes it): it exists for the race window where Rule 4 hasn't (yet) corrected the task — e.g. the task was added to the story's `tasks:` list after Rule 4 last ran, or the file was edited by hand after validation. It is not a replacement for Rule 4.
6. **Apply the all-or-nothing rule** — a story qualifies for the bundle path **only if every task** in its `tasks:` list has `execution_scope: story`. A single task with a different scope (or a missing field) disqualifies the entire story.
7. **Route bundle candidates** — if all tasks in the story are `execution_scope: story` and the list is non-empty:
   a. Emit:
      ```
      BUNDLE DETECTED: story <E##_S##> — <N> story-scoped tasks will execute as a bundle.
      ```
      where `<E##_S##>` is the story ID and `<N>` is the count of tasks in the list.
   b. Call `/do <E##_S##>` once (with the story ID, not individual task IDs). This invokes the bundle execution path in `/do` (implemented in E32_S05_T02), which runs all tasks sequentially in one shared worktree.
   c. **Mark these tasks as bundled** — record their task IDs so Phase 4 skips individual dispatch for them.
8. **Non-bundle stories** — stories with a mixed scope, a zero-length task list, any task missing `execution_scope: story`, or any task with `crucial_level: locked` (step 5) use the normal per-task dispatch in Phase 4 without any change.

### Phase 4 — Execute

Loop through `todo.md` and execute all eligible items, running independent ones in parallel. Use the threshold values loaded in Phase 0 (`inline_max_files`, `inline_max_lines`, `story_max_files`, `bundle_lock_ttl_minutes`) when applying execution-scope logic to each task. **Skip any task that was bundled in Phase 3.5** — those tasks will be handled by the `/do` story-bundle call already issued.

1. **Collect eligible items** — from `todo.md`, find all items whose board file has `status: Pending` and no unresolved dependencies, **excluding tasks already dispatched as part of a story bundle in Phase 3.5**. If Phase 0.75 produced a scoped set, also exclude any item not a member of that set — execution never runs outside the confirmed/resolved scope. Under `/jenga *`, no such exclusion applies. A dependency is resolved if the blocking item's status is at least `In Progress` or `Passed`.
2. **Group by parallelism** — items with no shared dependencies and no overlapping output files can run concurrently. Items that depend on each other must be sequenced.
3. **Invoke `/do` in parallel** — launch each independent item as a **background sub-agent** simultaneously. Do not wait for one to finish before starting another if they are independent.
4. **Mark In Progress** — update `status: In Progress` in each launched item's board file (YAML front-matter) immediately after launch.
5. **Wait, drain, and loop** — once all active background agents in the wave have completed:
   a. **Drain the scrum triggers queue** — invoke the `## Drain Scrum Triggers Queue` procedure from `agents/scrum-master.md` against `project/queue/scrum_triggers.jsonl`. `/jenga`'s orchestrating agent is the scrum-master, and this is the same session-start procedure applied mid-run: process any `rapport_review`, `status_review`, and `story_rollup` triggers written by the tester sub-sessions that just completed, then clear the file. This ensures rollups become visible on the board (story/epic status updates) before the next wave is collected, instead of sitting unprocessed until some future scrum-master session start.
   b. **Return to step 1** of this phase to pick up any newly unblocked items — including items unblocked by the rollups just processed in (a).

### Exit condition

When no eligible candidates remain in Phase 4, exit and output:

```
✅ Jenga complete. All eligible tasks have been started.
```

## Edge Cases

- **Epic with no stories after breakdown** — log a warning and continue to the next Epic; do not block the pipeline.
- **Story with no tasks after breakdown** — log a warning and continue to the next Story.
- **Task already in `todo.md`** — skip; do not duplicate.
- **All tasks in `todo.md` already In Progress/Passed** — exits cleanly with the completion message.
- **Unresolved dependencies** — item is skipped in Phase 4 until its blockers are at least `In Progress`.
- **`/do` failure (background agent)** — treated as a skip; mark the item's status back to `Pending` and continue the loop with remaining candidates.
- **Story with zero tasks (empty `tasks:` list)** — does not enter the bundle path in Phase 3.5; tasks (if any appear in `todo.md` independently) are dispatched normally in Phase 4.
- **Story with mixed `execution_scope` values** — falls back entirely to per-task dispatch in Phase 4; no partial bundling occurs.
- **Task file missing `execution_scope` field** — treated as not story-scoped; the containing story is disqualified from the bundle path.
- **Story containing a `crucial_level: locked` task** — disqualified from the bundle path at Phase 3.5 step 5, independent of that task's `execution_scope`; falls back to per-task dispatch in Phase 4, where `/do` Section 4.2's locked-task dispatch guard (E39_S03_T04) provides the second enforcement layer before any worktree or subagent is created.
- **Bundle `/do` call failure** — treated as a skip for the entire bundle; mark all bundled tasks' status back to `Pending` and continue Phase 4 with remaining non-bundled candidates.
- **Picker cancelled (bare branch)** — the entire `/jenga` run halts immediately after relaying the cancellation acknowledgement; no phase past 0.75 runs, and nothing on the board is modified.
- **Confirmation cancelled (bare or scoped branch)** — same as picker cancellation: the entire `/jenga` run halts immediately; no scoped set is produced and no later phase runs.
- **`detect-nl-intent.sh` classifies the argument as `mixed` (scoped branch)** — the whole invocation halts at Phase 0.75 with each rejected segment's `input`/`reason` reported verbatim, per `detect-nl-intent.sh`'s own classification contract (E53_S01_T01); no partial scope is assembled from the segments that did resolve, and no fallback guess is made for the rejected ones. The user must re-invoke `/jenga <ids>` with corrected input.
- **`detect-nl-intent.sh` classifies the argument as `nl_intent`, no confident single-skill match, and `match-playbook.sh` (E53_S02) also finds no playbook match** — the natural-language branch's step 4 attempts the playbook fallback first (see the Natural-language branch's step 4/6), and only THEN surfaces `skills/route/SKILL.md`'s Step 2 no-match disambiguation options (browse `/help`, create a new skill via `/btw`, proceed with the raw prompt) instead of guessing; no phase past 0.75 runs until the user picks one.
- **`detect-nl-intent.sh` classifies the argument as `nl_intent`, no confident single-skill match, and `match-playbook.sh` returns an ambiguous multi-way tie between playbooks** — treated the same as the no-playbook-match case above: falls through to `skills/route/SKILL.md`'s Step 2 tie-break prompt (top candidates + a "neither, describe what you need" option) instead of guessing; no phase past 0.75 runs until the user picks one. (`match-playbook.sh`'s own `ambiguous` result — a tie between playbooks — is intentionally not given its own separate disambiguation UI; it is treated identically to `no_match` and routed to the same `/route` Step 2 fallback prose, which already has its own tie-break handling.)
- **`match-playbook.sh` returns `playbook_match` and the user confirms the full chain, and every step succeeds** — the Natural-language branch's step 5e reports the full `completed` AND `skipped` steps lists to the user and stops; `/jenga`'s own Phase 1 never runs for this invocation (execution was already fully handled by the playbook's own steps, e.g. `j.do`/`j.dev-done`).
- **`match-playbook.sh` returns `playbook_match` but the user cancels at the chain confirmation step (step 5c)** — identical posture to the existing picker/confirmation cancellation cases above: the entire `/jenga` run halts immediately after relaying the cancellation acknowledgement, with NO step of the chain executed; nothing on the board is modified by this invocation.
- **`match-playbook.sh` returns `playbook_match`, the user confirms, and a step mid-chain fails** — the Natural-language branch's step 5e(vi) halts immediately on `run-playbook-step.sh`'s `halted` result: no step after the failed one runs (no silent skip-ahead), and the user is shown exactly which steps already completed or were skipped, which step failed (with its note), and which steps never ran.
- **A step's conditional predicate evaluates false (`E53_S04_T02`)** — the Natural-language branch's step 5e(i) never invokes that step at all; it calls `advance <state_file> skipped` directly, the step is recorded under the run's `skipped` list (never `completed`, never `failed`), and the chain continues to the next step exactly as it would after a `passed` step — a skipped step never halts the chain and is not narrated to the user as a separate turn, only reflected in the final `completed`/`skipped` summary (or the `halted` report's `skipped` field, if a later step fails).
- **A `skipped` step is later named by a `forward_from`** — the Natural-language branch's step 5e(ii) calls `get-output` for the named source before invoking the dependent step; a skipped source returns `{"status": "unavailable", "reason": "step_skipped"}`. This is the documented, non-silent failure mode (`E53_S04_T06`'s fixture coverage): the calling agent does NOT guess a fallback value or silently forward an empty string — it calls `advance <state_file> failed "forward_from source '<name>' unavailable (<reason>)"` and the chain halts with a `halted` report naming the dependent step as `failed_step`, exactly as any other step failure would.
- **A `resolve` step carries no `forward_from` (`E53_S06_T01`)** — the Natural-language branch's step 5e(ii) treats this as a defined no-op: there is no forwarded value to reshape, so the `resolve` field is simply ignored and the step is invoked normally with whatever input it would otherwise have received. This is never surfaced to the user as an error or a warning.
- **A `resolve` step's transform cannot cleanly produce a usable result (`E53_S06_T01`)** — the Natural-language branch's step 5e(ii) never invokes the target step and never guesses or passes through a differently-shaped value; it calls `advance <state_file> failed "<note>"` with a note that includes the raw pre-transform value, and the chain halts exactly as any other step failure would (5e-vi) — no silent skip-ahead, no fallback value.
- **A playbook step carries a `conditional`, shown at confirmation (`E53_S04_T04`)** — the Natural-language branch's step 5b relays `render-playbook-confirmation.sh`'s rendered chain, which visibly marks that step's line with "(may be skipped depending on step N's result)" — confirming a chain with a conditional step never hides its real conditional structure from the user, even though checking/unchecking that step still works exactly like any other step (the marker is display-only; the actual runtime skip decision belongs entirely to `should-skip`, independent of what the user checks or unchecks here).
- **The user unchecks, at confirmation, the specific step a later step's conditional depends on** — the Natural-language branch's step 5d drops that conditional before calling `init` (its `depends_on` step is no longer in the confirmed list, and `init` would otherwise reject the conditional outright as naming a nonexistent earlier step). The dependent step becomes unconditional for this run and always executes — a deliberate, documented fallback rather than a hard failure over the user's own edit.
- **A playbook contains a cyclic `{"playbook": "<id>"}` reference (`E53_S05_T01`)** — rejected entirely at `load-playbooks.sh` load time, before `/jenga` ever runs: the whole cyclic playbook is dropped from the catalog with a stderr warning naming the cycle. It is never surfaced as a `match-playbook.sh` candidate at all (a dropped playbook simply doesn't exist in the catalog `match-playbook.sh` matches against) — there is no runtime-visible error for this case, only a load-time one a human reviewing stderr output would see.
- **A playbook's composition nests deeper than the configured `max_composition_depth` (`E53_S05_T01`, default 3)** — same posture as the cyclic-reference case above: dropped at `load-playbooks.sh` load time with a stderr warning, never surfaced as a `match-playbook.sh` candidate, no runtime-visible error.
- **A `forward_from` crosses a composition boundary (`E53_S05_T02`)** — transparent in both directions with no special handling required anywhere in this SKILL.md: `load-playbooks.sh`'s composition resolution runs before its `forward_from`/`conditional` validation, so by the time a playbook reaches `match-playbook.sh`'s catalog, its `steps` array is already fully flattened — a step from a composed/nested playbook forwarding from (or being forwarded into by) a step outside it behaves exactly like any other `forward_from` relationship in step 5e(ii); the Natural-language branch never needs to know or care which originating playbook a step came from.
- **A playbook step carries composition origin metadata (depth > 1), shown at confirmation (`E53_S05_T03`)** — the Natural-language branch's step 5b relays `render-playbook-confirmation.sh`'s rendered chain, which now visibly indents and labels that step's line with "(from playbook: <id>, depth N)" — composing another playbook's steps into a chain never hides where one playbook ends and another begins from the user, even though the whole chain is still ONE numbered, editable, confirmable list (never a separate confirmation per nested playbook) and checking/unchecking a composed step still works exactly like any other step.
- **`/jenga *` (wildcard branch)** — never produces a scoped set; Phases 1-4 run fully unrestricted over the entire board, identical to `/jenga`'s behavior before Phase 0.75 existed.
- **Stale out-of-scope story queued in `todo.md` from an earlier run (scoped run only)** — Phase 3.5's scoped-set guard skips it entirely (not considered for bundling), so it cannot be dispatched via a bundle `/do <E##_S##>` call that would otherwise bypass Phase 4's own scoped-set exclusion; it remains untouched in `todo.md` until a future run's scope includes it.
