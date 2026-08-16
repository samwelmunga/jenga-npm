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
    .session_handoff.json        Transient inter-session handoff (written by agent, consumed by on_session_end.sh)
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

---

## Story Format Standards

## Reopen Tracking Fields

**`dates_previously_completed`, `reopened_on`, `reopened_reason`** — These fields are **only populated when a previously completed item is being reopened and modified**. Leave them blank on first-run items. Each value is a comma-separated list to support multiple reopen cycles.

## Documentation Provenance Field

**`docs`** — Optional YAML list of documentation files affected by the board item. Use repo-relative paths such as `README.md` or `docs/API.md`.

- Purpose: lets documentation workflows such as `/doc` trace which board items most recently affected a documentation file.
- Scope: may appear on epics, stories, or tasks.
- Optionality: existing board files remain valid when `docs` is omitted.
- Format: use a YAML list. Inline (`docs: ["README.md"]`) and expanded list styles are both valid.

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

Run `scripts/validate-board.sh <path-to-board-file>` to validate epic, story, or task frontmatter keys. The helper accepts optional `docs` annotations and remains backward compatible with existing board files that omit `docs`.

---

## Linking Convention

- Every story file must list its parent epic ID in the `epic_id` frontmatter field.
- Every task file must list both `story_id` and `epic_id`.
- Every epic file must list all of its constituent story IDs in the `stories` array.
- Every story file must list all of its constituent task IDs in the `tasks` array.
- These lists are the authoritative index. The scrum master maintains them; other agents must not modify them.

---

## File Locking (Concurrency Control)

Before writing to any board file, agents must:

1. Check for a `<filename>.lock` file adjacent to the target file.
2. If the lock file exists and its modification time is less than 60 seconds ago — wait up to 10 seconds and retry once. If still locked, abort and write a problem rapport.
3. If no lock exists (or it is stale, older than 60 seconds) — create the lock file, perform the write, then delete the lock file.
4. Always delete the lock file in success and failure paths. Use a `trap` or equivalent cleanup.

---

## Rapport Types

| Type                    | Used by            | Location                                        |
|-------------------------|--------------------|-------------------------------------------------|
| `conflict`              | developer          | `project/rapports/problems/`                    |
| `implementation_blocker`| developer          | `project/rapports/problems/`                    |
| `security_concern`      | developer          | `project/rapports/problems/`                    |
| `test_failure`          | tester             | `project/rapports/problems/`                    |
| `analysis`              | tester             | `project/rapports/analysis/`                    |

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

### `.session_handoff.json` — transient, consumed by on_session_end.sh

Written by an agent as the **last action** of its session. Consumed and deleted by `on_session_end.sh`. The file must not persist across sessions.

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
  "statuses": ["Pending", "In Progress", "Passed", "Passed with remarks", "Failed", "Rejected", "Blocked"],
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
