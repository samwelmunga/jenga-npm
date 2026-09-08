---
layout: page
title: Agents
permalink: /agents.html
---


Agents are defined in `.agents/agents/`. Each has a clearly bounded role and exclusive write permissions over specific project files. They communicate through typed sender objects and a shared trigger queue — never through direct conversation.

---

### Scrum Master

**File:** `.agents/agents/scrum-master.md`

**Role:** Plans and structures all work. Breaks user requests down into epics, stories, and tasks. Owns project memory.

**Owns:**
- `project/PROJECT_SUMMARY.md` — sole writer; the project's source of truth
- Epic status fields
- The queue processing loop

**Responsibilities:**
- At every session start, processes `project/queue/scrum_triggers.jsonl`: handles rapport reviews, status reviews, story/epic rollups, and proposed `PROJECT_SUMMARY.md` updates
- Creates, amends, and rollups board items following the schema in `templates/SCRUM_BOARD_SCHEMA.md`
- Uses advisory file locks before writing any board file
- In Brainstorm Mode (invoked via `/brainstorm`): explores ideas openly, challenges assumptions, proposes board mappings — holds off on writing anything until the user confirms
- In Mediator Mode (ML/AI tasks): translates between user plain language and the `ai_engineer` agent's technical output

**Trigger types it processes:**
- `rapport_review` — reads new problem rapports, creates backlog items or marks tasks as Failed
- `status_review` — checks board for items needing status updates
- `story_rollup` — if all tasks under a story passed, rolls up story status; then checks epic rollup
- `project_summary_update` — reviews proposed edits to `PROJECT_SUMMARY.md`, applies or rejects

**Example — Scrum Master in action:**
```
Session start:
Scrum Master reads scrum_triggers.jsonl:
→ Finds rapport_review for E01_S02_T03
→ Creates task E01_S02_T04 "Fix null pointer in auth middleware" with rapport reference
→ Clears the trigger file

User: "I want to add a password reset flow"
Scrum Master: "That fits under E01 (Auth). I'd structure it as S05 with three tasks:
  T01 — add forgot-password endpoint
  T02 — add reset token generation
  T03 — add reset-password endpoint
Does this look right before I write it to the board?"
```

---

### Developer

**File:** `.agents/agents/developer.md`

**Role:** Implements tasks. Works in isolation per task using git worktrees.

**Owns:**
- Code, worktrees, and commit history for tasks it picks up
- Pre-execution plans in `project/documentation/plans/`
- Post-execution summaries in `project/documentation/summaries/`

**Responsibilities:**
- Creates an isolated git worktree per task (`<E##_S##_T##-slug>`)
- Logs every incoming sender object to `project/logs/events.json` as its **first action**
- Writes a plan before implementing; writes a summary after
- Commits at meaningful milestones — not every line, and not just once at the end
- Passes a complete sender object (including commit SHAs) to the Tester on handoff
- **Never runs tests** — that is exclusively the Tester's responsibility
- After three failed conflict resolutions, writes a rapport to `project/rapports/problems/`, sets status to `Blocked`, and halts
- Never commits `.env` files or credentials

**Example — Developer flow:**
```
Receives sender object for E01_S02_T01 (JWT middleware)
→ Logs sender to events.json
→ Creates worktree: /projects/app-E01_S02_T01-jwt-middleware
→ Writes plan: project/documentation/plans/E01_S02_T01-plan.md
→ Implements JWT middleware
→ Commits: "feat: add JWT validation middleware"
→ Implements token extraction helper
→ Commits: "feat: extract bearer token from Authorization header"
→ Writes summary: project/documentation/summaries/E01_S02_T01-summary.md
→ Calls Tester with sender object including both commit SHAs
```

---

### Tester

**File:** `.agents/agents/tester.md`

**Role:** Validates all Developer output. The sole source of truth on whether a task passed.

**Owns:**
- Task and story status fields (sole writer)
- `project/configs/test-config.json` — test tool configuration, user-approved
- `project/data/baselines.json` — analytics baselines, maintained across sessions
- Rapports in `project/rapports/analysis/`

**Responsibilities:**
- Validates all required sender fields before proceeding — rejects with `"error"` if any are missing
- Runs the full testing lifecycle: unit, integration, e2e, SAST (opt-in), vulnerability scanning (opt-in), performance, coverage
- SAST and vulnerability scans require explicit user approval, logged to `events.json`
- Writes `Rejected` status only after notifying the user and receiving confirmation
- After every status update, checks for story/epic rollup and writes a trigger to the queue if warranted
- Maintains performance/coverage baselines so regressions surface across sessions

**Status values it can write:** `Passed`, `Passed with remarks`, `Failed`, `Rejected`, `Blocked`

**Example — Tester flow:**
```
Receives sender from Developer for E01_S02_T01
→ Validates: task_id ✅, commit SHAs ✅, worktree path ✅
→ Reads test-config.json: jest for unit, supertest for integration
→ Runs unit tests: 14 passed ✅
→ Runs integration tests: 3 passed ✅
→ Checks coverage: 87% (above baseline of 80%) ✅
→ Writes status: E01_S02_T01 → Passed
→ Checks rollup: all tasks in E01_S02 passed
→ Writes story_rollup trigger to scrum_triggers.jsonl
```

---

