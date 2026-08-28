# Scrum Board Schema

This document is the authoritative reference for all scrum board files. Every agent that creates, reads, or updates board items must follow this schema exactly.

---

## Directory Layout

```
project/
  board/
    epics/          Epic files: E##_<slug>.md
    stories/        Story files: E##_S##_<slug>.md
    tasks/          Task files: E##_S##_T##_<slug>.md
  instructions/     User-action prerequisite files: E##_S##_T##_INSTRUCTIONS.md
                    (created on first use — not pre-provisioned)
  configs/
    workflow.json   Shared constants (statuses, paths, rapport types)
  data/
    baselines.json  Analytics baselines (owned by tester)
  documentation/
    plans/          Pre-execution plans: E##_S##_T##-plan.md (written by developer before implementation)
    summaries/      Post-execution summaries: E##_S##_T##-summary.md (written by developer before invoking tester)
  queue/
    scrum_triggers.jsonl         Trigger queue for scrum master
    developer_triggers.jsonl     Trigger queue for developer agent
    tester_triggers.jsonl        Trigger queue for tester agent
    project_summary_updates.jsonl Proposed PROJECT_SUMMARY.md edits
    handoffs/                    Per-session transient handoffs (written by agent, consumed by on_session_end.sh) — see `handoffs/` below
  rapports/
    problems/       Problem rapports from developer and tester
    analysis/       Analysis rapports from tester
  logs/
    events.json     Append-only inter-agent event log
```

> **Note:** `project/epics/` and `project/stories/` and `project/tasks/` are legacy paths from earlier skills. All new board items are written under `project/board/`. Skills and agents that reference the legacy paths should migrate to `project/board/` when next touched.

---

## ID & Filename Conventions

| Type  | ID Format     | Filename                          |
|-------|---------------|-----------------------------------|
| Epic  | `E##`         | `E##_<slug>.md`                   |
| Story | `E##_S##`     | `E##_S##_<slug>.md`               |
| Task  | `E##_S##_T##` | `E##_S##_T##_<slug>.md`           |

- Numbers are zero-padded to two digits: `E01`, `S03`, `T07`
- `<slug>` is a short lowercase kebab-case title derived from the item title
- Example: `E02_S04_T01_add-jwt-middleware.md`

---

## Status Values

All status fields must use one of the following exact strings:

| Status               | Meaning                                                    |
|----------------------|------------------------------------------------------------|
| `Pending`            | Created, not yet started                                   |
| `In Progress`        | Actively being worked on                                   |
| `Passed`             | All tests passed, no findings                              |
| `Passed with remarks`| Tests passed but non-blocking findings exist               |
| `Failed`             | Tests did not pass                                         |
| `Rejected`           | Deliberately rejected — not a test failure                 |
| `Blocked`            | Cannot proceed; human intervention required                |
| `Backlog`            | Epic-level only; queued but not yet prioritized for work    |
| `Done`               | Epic-level only; all child stories/tasks closed out          |

Only the **tester agent** may write status values to story and task files. Only the **scrum master** may write status values to epic files and may update story status as part of rollup.

---

## File Formats

### Epic — `E##_<slug>.md`

```markdown
---
id: E##
title: <Title>
status: Pending
date_created: YYYY-MM-DD
date_started:
date_completed:
dates_previously_completed:  # comma-separated list, e.g. 2026-01-15, 2026-03-22
reopened_on:                 # comma-separated list, e.g. 2026-02-01, 2026-04-10
reopened_reason:             # comma-separated list, e.g. "Scope expanded", "Bug found post-release"
docs: []                     # optional list of repo-relative documentation paths, e.g. ["README.md", "docs/API.md"]
epic_scope_approval: false     # set to true by the human operator only when any task in this epic has execution_scope: epic
provenance:                  # optional; only valid value is `backfilled` (epic reverse-engineered from pre-existing code by `/uncharted onboard`). Omit for normally-authored epics.
stories:
  - E##_S##
  - E##_S##
---

# Epic: <Title>

## Purpose
<What this epic achieves and why.>

## Definition of Done
- <Concrete, testable criterion>
- <Concrete, testable criterion>
```

> **`epic_scope_approval`** — This field is **set by the human operator only**. Neither the scrum-master nor the developer agent may set it to `true`. It must be `true` before any task with `execution_scope: epic` can be executed. Its absence is equivalent to `false`.

### Story — `E##_S##_<slug>.md`

```markdown
---
id: E##_S##
epic_id: E##
title: <Title>
status: Pending
date_created: YYYY-MM-DD
date_started:
date_completed:
dates_previously_completed:  # comma-separated list, e.g. 2026-01-15, 2026-03-22
reopened_on:                 # comma-separated list, e.g. 2026-02-01, 2026-04-10
reopened_reason:             # comma-separated list, e.g. "Scope expanded", "Bug found post-release"
docs: []                     # optional list of repo-relative documentation paths, e.g. ["README.md", "docs/API.md"]
crucial_level:                # optional; advisory | gated | locked; absence means no elevated caution
crucial_set_by:                # required when crucial_level is set; user | scrum-master | <agent>-escalation
crucial_note:                  # required when crucial_level is set; free-text justification
crucial_declined:              # optional; true only; absence means no declined proposal is on record
crucial_declined_note:         # required when crucial_declined: true; free-text: heuristic matched, proposed tier, date declined
tasks:
  - E##_S##_T##
  - E##_S##_T##
---

# Story: <Title>

As a [type of user], I want [goal] so that [reason/value].

## Acceptance Criteria
- [ ] <Verifiable criterion — specific enough for a tester to check without asking>

## Definition of Done
- [ ] <Concrete, testable criterion>
- [ ] <Concrete, testable criterion>
```

### Task — `E##_S##_T##_<slug>.md`

```markdown
---
id: E##_S##_T##
story_id: E##_S##
epic_id: E##
title: <Title>
status: Pending
date_created: YYYY-MM-DD
date_started:
date_completed:
dates_previously_completed:  # comma-separated list, e.g. 2026-01-15, 2026-03-22
reopened_on:                 # comma-separated list, e.g. 2026-02-01, 2026-04-10
reopened_reason:             # comma-separated list, e.g. "Scope expanded", "Bug found post-release"
assigned_to: developer | tester | scrum-master
docs: []                     # optional list of repo-relative documentation paths, e.g. ["README.md", "docs/API.md"]
execution_scope: task          # task | story | epic | inline; omit for legacy tasks (defaults to task)
needs_docs: true               # boolean; omit for legacy tasks (defaults to true)
scope_rationale: ""            # required when execution_scope is set; must contain a numeric/file-count claim
jenga_assigned: true           # boolean; true = machine-assigned, false = human override
override_justification: ""     # required when jenga_assigned: false
epic_scope_approval: false     # required (as true) when execution_scope: epic; set by human operator only
crucial_level:                  # optional; advisory | gated | locked; absence means no elevated caution
crucial_set_by:                  # required when crucial_level is set; user | scrum-master | <agent>-escalation
crucial_note:                    # required when crucial_level is set; free-text justification
crucial_declined:                # optional; true only; absence means no declined proposal is on record
crucial_declined_note:           # required when crucial_declined: true; free-text: heuristic matched, proposed tier, date declined
---

# Task: <Title>

## Description
<What needs to be done and why.>

## Prerequisites
<List any actions the user must take outside agent scope before or during implementation (e.g. creating accounts, configuring OAuth, provisioning services). Leave blank if none. If prerequisites exist, the developer must create an `_INSTRUCTIONS.md` file at `project/instructions/<E##_S##_T##>_INSTRUCTIONS.md`.>

## Acceptance Criteria
- [ ] <Verifiable criterion>
```

> **Backward compatibility:** Tasks that omit all six new fields (`execution_scope`, `needs_docs`, `scope_rationale`, `jenga_assigned`, `override_justification`, `epic_scope_approval`) are treated as `execution_scope: task` / `needs_docs: true` and are processed without error. Agents must not reject board files that lack these fields.

### Runtime-written task fields

These four fields are **not authored by hand**. They are appended to a task's frontmatter after execution and are absent from any task that has not yet run. They are listed here so that tooling — in particular `scripts/validate-board.sh` — recognises them as valid rather than unknown.

| Field | Written by | Meaning |
|---|---|---|
| `actual_files_changed` | `/close-story` | Count of files changed by the task, extracted from its EST-tagged commits |
| `actual_lines_delta` | `/close-story` | Net line delta for the task, from the same extraction |
| `scope_divergence_flag` | `/close-story` | Set when actual diff stats exceed the thresholds that justified the assigned `execution_scope` |
| `divergence_flag` | `/do` | Set to `true` by the intent-vs-diff check when a `needs_docs: false` task touched unregistered files |

All four are advisory and non-blocking — they record evidence for later review and never change a task's Passed/Failed outcome.

> `task_changed_files` is **not** a frontmatter field despite the similar name. It lives in the bundle manifest at `project/queue/bundle-<E##_S##>.json`, keyed by task ID.

---

## Story Format Standards

## Reopen Tracking Fields

**`dates_previously_completed`, `reopened_on`, `reopened_reason`** — These fields are **only populated when a previously completed item is being reopened and modified**. Leave them blank on first-run items. Each value is a comma-separated list to support multiple reopen cycles.

## Planning Fields

**`priority`** (stories, optional) — Relative planning priority, e.g. `P0`, `P2`, or a range such as `P0-P1`. Advisory only; no agent behaviour keys off it.

**`depends_on`** (stories and tasks, optional) — Board IDs this item depends on, e.g. `E19_S02`. Advisory only.

> **Deprecated spellings.** `epic:`, `story:`, `date_added:`, `dependencies:`, and `reopens:` were used on older board files and are **not** valid. Use `epic_id`, `story_id`, `date_created`, `depends_on`, and the reopen tracking fields respectively. All existing files were normalised on 2026-08-19; `scripts/validate-board.sh` rejects the old spellings so the drift cannot reappear.

## Documentation Provenance Field

**`docs`** — Optional YAML list of documentation files affected by the board item. Use repo-relative paths such as `README.md` or `docs/API.md`.

- Purpose: lets documentation workflows such as `/doc` trace which board items most recently affected a documentation file.
- Scope: may appear on epics, stories, or tasks.
- Optionality: existing board files remain valid when `docs` is omitted.
- Format: use a YAML list. Inline (`docs: ["README.md"]`) and expanded list styles are both valid.

## Epic Provenance Field

**`provenance`** (epics only, optional) — Records how the epic came to exist: whether it was
planned through the normal Jenga workflow or reverse-engineered from code that already existed.

- **Valid values:** `backfilled` — the only recognised value.
- **`provenance: backfilled`** means the epic was generated by `/uncharted onboard` from a
  pre-existing codebase, rather than authored through the normal planning flow (`/pi-plan`,
  `/brainstorm`, `/todo`, or the Scrum Master breaking down a user request).
- **Absence means normally-authored.** An epic with no `provenance` field was authored through
  the standard planning flow. There is no explicit value for this — omission *is* the signal.
- **Optional and backward compatible.** Every existing epic omits `provenance` and remains valid.
  `scripts/validate-board.sh` accepts the key when present and never requires it.
- **Scope:** epics only. Stories and tasks do not carry `provenance`; a backfilled epic's children
  are identified by their parent, not by a marker of their own.

### What `backfilled` implies

A backfilled epic describes **code that already exists**. Its Purpose section documents a
subsystem that was discovered, not a capability to be built. Consequently its stories and tasks
describe **understanding and integration work** — documenting behaviour, adding missing tests,
identifying risk areas, bringing the subsystem under board provenance — and **not original
construction**. Agents and humans reading the board should not treat a backfilled epic's
Definition of Done as a build plan, and should not assume that an incomplete-looking backfilled
epic represents unbuilt functionality.

## Execution Scope Fields (Task)

These six fields control the execution footprint of a task within the `/jenga` and `/do` workflows. They are **optional** — omitting all six is valid and equivalent to `execution_scope: task` / `needs_docs: true`.

**`execution_scope`**
- Valid values: `task` | `story` | `epic` | `inline`
- When required: optional; omit for legacy tasks (runtime default: `task`)
- Description: defines how broadly this task's implementation touches the codebase.
  - `task` — standard single-task scope (default)
  - `story` — task may touch files across multiple tasks in the same story
  - `epic` — task may touch files across stories; requires `epic_scope_approval: true` on the parent epic
  - `inline` — trivial change (e.g. config tweak, comment, schema doc); no execution plan or summary document is needed

**`needs_docs`**
- Valid values: `true` | `false`
- When required: optional; omit for legacy tasks (runtime default: `true`)
- Description: when `false`, the developer agent skips writing an execution plan and execution summary for this task. Automatically implied as `false` when `execution_scope: inline`.

**`scope_rationale`**
- Valid values: any non-empty string; must include a measurable claim (e.g. a file count or line count)
- When required: required when `execution_scope` is explicitly set to any value
- Description: a brief justification explaining why the chosen scope is appropriate. Validators reject a blank value when `execution_scope` is present.

**`jenga_assigned`**
- Valid values: `true` | `false`
- When required: optional; omit for legacy tasks (runtime default: `true`)
- Description: indicates whether the execution scope was assigned by the `/jenga` orchestrator (`true`) or overridden by a human (`false`). When `false`, `override_justification` is required.

**`override_justification`**
- Valid values: any non-empty string
- When required: required when `jenga_assigned: false`
- Description: explains why the human operator overrode the machine-assigned scope. Must be non-empty when present.

**`epic_scope_approval`**
- Valid values: `true` | `false`
- When required: required on the **epic** frontmatter (as `true`) before any task with `execution_scope: epic` may be executed; the task frontmatter carries this field for reference only
- Description: the authoritative value is always read from the **epic** frontmatter, not the task. This field is **set by the human operator only** — neither the scrum-master nor the developer agent may set it to `true`. Its absence on the epic is equivalent to `false`.

These rules apply to every story file written or amended by the **Scrum Master**. They are enforced at write time by `scripts/validate-story-format.sh`.

## Crucial Flag Fields (Story, Task)

These three fields let a story or task declare an elevated caution tier — a signal that the item carries more risk than usual and should be handled with extra care during execution and review. They are **optional** — omitting all three is valid and means no elevated caution applies.

**`crucial_level`**
- Valid values: `advisory` | `gated` | `locked`
- When required: optional; absence means no elevated caution (same "absence is the signal" convention used by `provenance` and the execution-scope fields)
- Description: declares the item's caution tier.
  - `advisory` — proceed as normal but flag the elevated risk for reviewers
  - `gated` — requires explicit confirmation before execution proceeds
  - `locked` — execution is blocked until the tier is downgraded or cleared by an authorised party

**`crucial_set_by`**
- Valid values: `user` | `scrum-master` | `<agent>-escalation` (e.g. `developer-escalation`, `tester-escalation`)
- When required: required when `crucial_level` is set
- Description: records who or what set the caution tier — a human operator, the scrum-master during planning, or an agent escalating mid-execution.

**`crucial_note`**
- Valid values: any non-empty string
- When required: required whenever `crucial_level` is set (same required-when-present pattern as `scope_rationale`)
- Description: a free-text justification explaining why the item was assigned this caution tier. Validators reject a blank value when `crucial_level` is present.

**Scope: stories and tasks only.** Epics do not carry these fields — an epic's risk gating is already handled by `epic_scope_approval` (see Execution Scope Fields above). A story or task's `crucial_level` is independent of any execution-scope value on the same item.

**Backward compatibility.** Existing board files that omit all three fields (`crucial_level`, `crucial_set_by`, `crucial_note`) remain valid, exactly like the `docs` field and the execution-scope fields. Agents must not reject board files that lack them.

## Declined Crucial Proposal Fields (Story, Task)

These two fields record that a scrum-master heuristic proposed a `crucial_level` for this specific item (per the "Crucial Level Heuristic Proposal" step in `agents/scrum-master.md`) and the user explicitly declined it in-session. This is the **authoritative decline-tracking mechanism** — `agents/scrum-master.md`'s breakdown step checks it before evaluating the heuristic list again, so a declined proposal is not silently re-surfaced on a later breakdown pass over the same item. They follow the same "optional field, absence is the signal, backward compatible" convention already used by `docs`, `provenance`, and the execution-scope fields, and the same required-when-present pairing already used by `crucial_level`/`crucial_note`.

**`crucial_declined`**
- Valid values: `true` (the only recognised value)
- When required: optional; absence means no declined proposal is on record for this item — same "absence is the signal" convention used by `provenance`. There is no `false` state to write: an item either has a recorded decline or it doesn't.
- Description: a boolean marker, deliberately separate from free text, so the scrum-master breakdown step can check a single unambiguous field before re-proposing rather than parsing prose for intent.

**`crucial_declined_note`**
- Valid values: any non-empty string
- When required: required when `crucial_declined: true` (same required-when-present pattern as `crucial_note`)
- Description: free-text record of which heuristic(s) matched (from the fixed list in `agents/scrum-master.md`'s "Crucial Level Heuristic Proposal" section), the `crucial_level` tier that was proposed, and the date the user declined it — e.g. `"Declined 2026-08-27: matched 'schema/frontmatter contracts' heuristic, proposed advisory tier; user declined without further reason."` Validators reject a blank value when `crucial_declined` is present.

**Scope: stories and tasks only** — same scope as the Crucial Flag Fields above.

**Relationship to `crucial_level`.** `crucial_declined` and `crucial_level` are mutually exclusive in the normal flow: if the user *confirms* a proposal, the item gets `crucial_level`/`crucial_set_by: scrum-master`/`crucial_note` and no decline is recorded; if the user *declines*, the item gets `crucial_declined: true`/`crucial_declined_note` and none of the three `crucial_level` fields are set. A human operator may still set `crucial_level` directly on an item that also carries a recorded decline (e.g. deciding later, independent of the scrum-master's proposal, that the item should be flagged) — the fields are not validated as exclusive, only documented as normally following one path or the other.

**Backward compatibility.** Existing board files that omit both fields remain valid — no item has ever had a decline recorded before this convention existed, so every pre-existing file is trivially compliant.

### Acceptance Criteria (`## Acceptance Criteria`)

- **Required** — the section must exist in every story file.
- **Format-agnostic** — may be prose, a numbered list, or checkboxes (`- [ ]`). No structural requirement beyond the section being present.
- **Owner: Scrum Master** writes the AC when creating or amending the story.

### Definition of Done (`## Definition of Done`)

- **Required** — the section must exist in every story file.
- **Must use `- [ ]` checkboxes** — plain bullet points (`- text`) are **not** valid. Each criterion must be written as an unchecked checkbox so the Tester can tick it during verification.
- **Owner: Scrum Master** writes the DoD checkboxes when creating or amending the story. **Tester** ticks each `- [ ]` to `- [x]` during the test run, before writing any `Passed` or `Passed with remarks` status.

### Validation script

Run `scripts/validate-story-format.sh <path-to-story-file>` to verify a story file meets these requirements. The script exits 0 on success and non-zero with a descriptive error message on failure.

Run `scripts/validate-board.sh <path-to-board-file>` to validate epic, story, or task frontmatter keys. The helper accepts optional `docs` and (on epics) `provenance` annotations, and remains backward compatible with existing board files that omit them.

---

## Linking Convention

- Every story file must list its parent epic ID in the `epic_id` frontmatter field.
- Every task file must list both `story_id` and `epic_id`.
- Every epic file must list all of its constituent story IDs in the `stories` array.
- Every story file must list all of its constituent task IDs in the `tasks` array.
- These lists are the authoritative index. The scrum master maintains them; other agents must not modify them.

---

## File Locking (Concurrency Control)

Board file writes (task/story/epic frontmatter updates) are enforced through `scripts/with-lock.sh`, not through agents manually implementing a check-wait-retry convention. The earlier prose-only protocol ("check for a `<filename>.lock` file, wait, retry, then create/delete it yourself") was purely advisory — nothing stopped two writers from both deciding the lock was free at the same instant. `scripts/with-lock.sh` closes that gap with a real mutual-exclusion primitive.

**Usage:**

```bash
scripts/with-lock.sh <target-file> -- <command> [args...]
```

The script acquires an exclusive lock keyed to `<target-file>`, runs `<command> [args...]` only once the lock is held, and always releases the lock afterward — on success, on failure, and on `INT`/`TERM` signals. Agents (scrum-master, tester) MUST wrap every board file write through this script rather than reading/writing a `.lock` file by hand.

**Lock primitive.** The script uses `mkdir "<target-file>.lock.d"` as the exclusivity check, not `flock`. `flock` is a Linux-only (`util-linux`) utility and is not available by default on macOS/BSD — this repo runs on Darwin, so a `flock`-only implementation would silently not work for every contributor on macOS. `mkdir` is atomic on every POSIX platform this project targets: when multiple processes race to create the same directory, exactly one succeeds and every other caller fails immediately (`EEXIST`) — there is no window where two callers can both believe they hold the lock.

**Waiting and failure behavior.** If the lock is already held, the script polls (default every 0.2s, `WITH_LOCK_POLL_SECONDS`) until either the lock is released or a timeout elapses (default 30s, `WITH_LOCK_TIMEOUT_SECONDS`). If the timeout elapses first, the script exits `2` **without ever running the wrapped command** — a fail-safe abort, never a silent overwrite. A lock still held after `WITH_LOCK_STALE_SECONDS` (default 60s) is treated as abandoned (e.g. a crashed holder) and reclaimed; reclamation only clears the lock directory, it does not itself grant the lock, so simultaneous reclaim attempts by multiple waiters still cannot let more than one of them proceed — the next `mkdir` in each waiter's loop remains the sole arbiter.

**Example — a status write wrapped in the lock:**

```bash
scripts/with-lock.sh project/board/tasks/E01_S02_T03_example.md -- \
  bash -c 'update_task_status project/board/tasks/E01_S02_T03_example.md Passed'
```

If a caller cannot acquire the lock within the timeout, treat it the same as the old protocol's "still locked after retry" case: abort the write and write a problem rapport rather than bypassing the script.

---

## Rapport Types

| Type                    | Used by            | Location                                        |
|-------------------------|--------------------|-------------------------------------------------|
| `conflict`              | developer          | `project/rapports/problems/`                    |
| `implementation_blocker`| developer          | `project/rapports/problems/`                    |
| `security_concern`      | developer          | `project/rapports/problems/`                    |
| `test_failure`          | tester             | `project/rapports/problems/`                    |
| `analysis`              | tester             | `project/rapports/analysis/`                    |
| `crucial_escalation`    | developer, tester  | `project/rapports/problems/`                    |

### `crucial_escalation` — concrete-reason requirement

A `crucial_escalation` rapport is filed mid-task when developer or tester discovers something that changes an item's risk profile and warrants raising its `crucial_level` (see E39 — Crucial Flag). It is routed through the same rapport/trigger queue as every other rapport type (`on_session_end.sh` → `scrum_triggers.jsonl`), since no synchronous interrupt exists for a backgrounded subagent.

The rapport's reason **must include at least one concrete, checkable fact** — a specific file/path, an exact error message, a reproduction count, or a quantifiable impact (e.g. "affects 12 downstream tasks", "data loss observed on 2 of 2 reproduction attempts"). A subjective statement alone (e.g. "this seems risky", "this feels important") is **not** acceptable.

This is the same numeric-claim bar already established for `scope_rationale` in `agents/scrum-master.md` (see its "scope_rationale — Mandatory Population Rules" section) — reused here deliberately so the concrete-reason standard is consistent across the codebase rather than a new one-off rule invented for this rapport type. Enforcing this rule (rejecting generic text) is scrum-master's responsibility when it reviews the rapport, not something checked at write time.

A `crucial_escalation` rapport must also name the target item's ID (`E##`, `E##_S##`, or `E##_S##_T##`) whose `crucial_level` is being escalated. No new field is introduced for this — it uses the rapport's existing "Related Epic" / "Related Story" / "Related Task" header fields (see `templates/PROBLEM_RAPPORT_TEMPLATE.md`).

---

## Queue Trigger Types

### `scrum_triggers.jsonl` — processed by scrum master at session start

| Type             | Written by  | Purpose                                                |
|------------------|-------------|--------------------------------------------------------|
| `rapport_review` | on_session_end.sh | New problem rapport(s) detected; create backlog items or mark Failed |
| `status_review`  | on_session_end.sh | Session ended; review board for stale statuses        |
| `story_rollup`   | tester / on_session_end.sh | All tasks under story complete; check rollup |

### `developer_triggers.jsonl` — processed by developer at session start

| Type                     | Written by          | Purpose                                       |
|--------------------------|---------------------|-----------------------------------------------|
| `implementation_assignment` | on_session_end.sh (from scrum-master handoff) | New tasks ready for implementation |
| `rework_assignment`      | on_session_end.sh (from tester handoff) | Tests failed; address rapport and re-implement |

### `tester_triggers.jsonl` — processed by tester at session start

| Type              | Written by          | Purpose                                         |
|-------------------|---------------------|-------------------------------------------------|
| `test_assignment` | on_session_end.sh (from developer handoff) | Implementation complete; run tests against worktree |

### `handoffs/` — per-session transient handoffs, consumed by on_session_end.sh

**Directory:** `project/queue/handoffs/`

Replaces the earlier single-slot `project/queue/.session_handoff.json` file (E37_S01_T01). The single fixed path allowed two sessions ending close together — an in-session tester invocation, or concurrent `/jenga` dispatch running multiple developer/tester pairs at once — to both write the same file before either write was consumed; the second write silently clobbered the first, and the loser's handoff (and, in the worst case, the task it represented) was lost with no error. Live incidents are recorded in `PROJECT_SUMMARY.md`'s E37 section.

**Filename convention:** `project/queue/handoffs/<agent>-<session_id>-<task_id>.json`

- `<agent>` — `scrum-master`, `developer`, or `tester` (matches the handoff body's own `agent` field).
- `<session_id>` — the writing session's id, verbatim. This alone already makes the path collision-free, since each session has a unique id and writes its terminal handoff exactly once (the "last action of its session").
- `<task_id>` — the primary task ID (`E##_S##_T##`) this handoff concerns, included for human-readability/debugging. For the scrum-master's batched `task_ids` array, use the first entry, or the literal string `batch` if the array is empty.

Each file is written by an agent as the **last action** of its session, and is single-use: consumed and deleted by `on_session_end.sh` (per-file, immediately after routing — see `hooks/on_session_end.sh` section 4) once that session's `SessionEnd` hook fires. A file must not persist once it has been consumed. `project/queue/handoffs/*.json` is git-ignored (E37_S01_T02) precisely to enforce this structurally — the directory itself is kept via `.gitkeep`, but individual handoff files must never become durable git artifacts, since a committed one can no longer be told apart from a live pending signal by inspection alone.

**Staleness guard (E37_S01_T02):** before routing a `developer` or `tester` handoff, `on_session_end.sh` checks whether the file's `task_id` is already in a terminal board status (`Passed`, `Passed with remarks`, `Rejected`, `Done`, or `Blocked`). If so, the file is deleted without routing — it is treated as a stale leftover (e.g. one that predates this consumer logic, or one that slipped past the git-ignore rule above) rather than a live signal for already-completed work. This closed a real regression found during testing: `project/queue/handoffs/` had accumulated ~25 committed files for already-`Passed` work before this consumer logic existed to clean them up, and a bare generic glob would have resurrected all of them as fresh `test_assignment`/`story_rollup` triggers on the first `SessionEnd` run after this feature landed. The check is not applied to `scrum-master`'s batched `task_ids` handoffs (a `planning_complete` handoff's tasks are freshly created and cannot already be terminal in practice).

| Field         | Required by          | Notes                                    |
|---------------|----------------------|------------------------------------------|
| `agent`       | all                  | `scrum-master`, `developer`, or `tester` |
| `status`      | all                  | See per-agent values below               |
| `session_id`  | all                  |                                          |
| `task_ids`    | scrum-master only    | Array of task IDs assigned for implementation |
| `task_id`     | developer, tester    | Single task ID                           |
| `story_id`    | all                  |                                          |
| `epic_id`     | all                  |                                          |
| `worktree`    | developer, tester    | Absolute path                            |
| `paths`       | developer, tester    | Commit SHAs                              |
| `rapport_file`| tester only          | Path to rapport if status is failed/error |
| `date`        | all                  | ISO 8601 UTC                             |

**Status values per agent:**
- `scrum-master`: `planning_complete`
- `developer`: `implementation_complete`
- `tester`: `passed`, `passed_with_remarks`, `failed`, `error`



Located at `project/configs/workflow.json`. Scaffolded by `/init` and owned by the scrum master.

```json
{
  "statuses": ["Pending", "In Progress", "Passed", "Passed with remarks", "Failed", "Rejected", "Blocked", "Backlog", "Done"],
  "rapport_types": ["conflict", "implementation_blocker", "security_concern", "test_failure", "analysis"],
  "paths": {
    "board": "project/board",
    "epics": "project/board/epics",
    "stories": "project/board/stories",
    "tasks": "project/board/tasks",
    "instructions": "project/instructions",
    "rapports_problems": "project/rapports/problems",
    "rapports_analysis": "project/rapports/analysis",
    "queue": "project/queue",
    "logs": "project/logs",
    "data": "project/data",
    "configs": "project/configs",
    "documentation": "project/documentation",
    "documentation_plans": "project/documentation/plans",
    "documentation_summaries": "project/documentation/summaries"
  },
  "agents": ["developer", "tester", "scrum-master"]
}
```
