# Plan: Agent Runaway Guardrails

**Origin:** Deep-dive investigation of copilot session `7fa5b0fc-71ed-47fb-b39e-a1d1bae204c1`
**Date:** 2026-06-06
**Target project:** Jenga workflow (implement as a separate project / epic)

## Background

A Developer sub-agent went rogue: it was assigned one task but implemented all 5 tasks in the story, modified all 4 agent definition files, created scrum board files, and never called the Tester. Root causes: no mechanical turn ceiling, queue allowed multi-task self-assignment, all scope checks were self-policed.

Full investigation: `project/documentation/summaries/agent-runaway-guardrails.md`
Scrutiny: `project/documentation/summaries/scrutiny-agent-guardrails.md`
Solution assessment: `project/documentation/summaries/solution-assessment-agent-guardrails.md`

---

## Architectural Principle

> Mechanical enforcement belongs at the layer the agent cannot reason its way around.
> Instruction-level rules are *policy*; tooling-level rules are *law*.

---

## Implementation Roadmap

### Phase 1 — Queue bypass fix *(~2–4 h, zero dependencies)*

**Goal:** Prevent the Developer from self-assigning more than one task per invocation.

**Changes required:**
- `developer.md`: Amend the queue-processing instruction to:
  1. Read exactly **one** trigger from `developer_triggers.jsonl` (the first unprocessed entry)
  2. Annotate it as `"status": "consumed"` (or move to `developer_triggers_processed.jsonl`) **before** beginning work — log to `events.json`
  3. After completing the task and calling the Tester, **halt** — do not loop to the next queue entry
- Must use language "process one trigger and halt" — not "focus on one task" (the latter is bypassable by rationalisation)

**Acceptance criteria:**
- [ ] A queue with two `implementation_assignment` entries results in the Developer processing exactly one and halting
- [ ] The consumed entry is marked before implementation begins (verified in `events.json`)
- [ ] A concurrent invocation cannot claim the same entry

---

### Phase 2 — Calibrate `maxTurns` *(~4–8 h, depends on Phase 1 completing first for clean data)*

**Goal:** Set an empirically grounded turn ceiling for Developer and Tester — separately.

**Steps:**
1. Replay 3–4 past Developer sessions from `project/logs/events.json` (one simple/one-file, one medium/multi-file, one complex/multi-module) — count actual tool-call turns per session
2. Replay 1–2 past Tester sessions (including a full e2e + coverage run) — count separately
3. Set `Developer maxTurns` = 90th-percentile observed value + 20% buffer
4. Set `Tester maxTurns` = 2× observed maximum (conservative to avoid interrupting Playwright/SAST mid-run)
5. Document the numbers and their basis in a companion file (e.g., `project/configs/turn-budget-rationale.md`)

**Changes required:**
- `.claude/settings.json`: Add `maxTurns` to Developer and Tester sub-agent invocation configs
- `project/configs/turn-budget-rationale.md`: New file documenting calibration data and chosen values

**Add graduated warnings to `developer.md` and `tester.md`:**
- At turn N-10: write a progress summary to the checkpoint file (see Phase 3) and continue
- At turn N-5: commit all in-progress work (even partial) and write a partial-completion rapport
- At turn N: invocation terminates — `on_session_end.sh` detects the rapport and queues for Scrum Master review

**Acceptance criteria:**
- [ ] Developer `maxTurns` documented with calibration rationale
- [ ] Tester `maxTurns` documented and set conservatively (≥ 2× Developer ceiling)
- [ ] Graduated warnings present in both agent definitions
- [ ] A representative complex Developer session completes without hitting the ceiling

---

### Phase 3 — Abort-and-requeue protocol *(~1–2 d, depends on Phase 2)*

**Goal:** Replace the "suspend in-place" mental model with one that works with stateless sub-agent invocations.

**Design:** When the Developer's remaining turn budget drops below the threshold (N-5), instead of trying to resume:
1. Commit whatever is complete (even partial — worktree must be clean)
2. Write a **partial-completion rapport** to `project/rapports/problems/<task_id>-partial.md` with:
   - `task_id`, `story_id`, `epic_id`
   - `worktree_path`, `last_commit_sha`
   - `completed_files[]` (committed)
   - `in_progress_file` + current state description
   - `pending_files[]` (not yet started)
   - `next_planned_action` (human-readable)
   - `estimated_turns_remaining` (rough estimate for remaining work)
   - `checkpoint_reason`: `"turn_budget"` | `"scope_violation"` | `"conflict_halt"`
3. Set task status to `In Progress` on the board (not `Blocked`)
4. Halt — `on_session_end.sh` detects the rapport, writes a `rapport_review` trigger to the Scrum Master queue
5. On the next session, the Scrum Master reviews the rapport and decides: re-dispatch as-is, or split the task

**Present to user:** Before halting, surface the rapport content to the user in the session with the question: "Proceed (extend budget) or cancel?"

**Changes required:**
- `developer.md`: Replace checkpoint-loop section with abort-and-requeue instructions
- `tester.md`: Same pattern for test-lifecycle halts
- `project/rapports/problems/`: Rapport template (or schema documented in agent instructions)

**Acceptance criteria:**
- [ ] A Developer session that hits `maxTurns` produces a partial-completion rapport at `project/rapports/problems/`
- [ ] The rapport contains all required fields
- [ ] `on_session_end.sh` detects and queues the rapport correctly
- [ ] A re-dispatched Developer session can resume from the rapport (reads `last_commit_sha`, `pending_files`, `next_planned_action`)

---

### Phase 4 — Halt recovery runbook *(~4–6 h, parallel with Phase 3)*

**Goal:** Define exactly what a human must do when a halt rapport lands (scope violation, turn budget, conflict).

**Deliverable:** `project/documentation/how-to-recover-from-agent-halt.md`

**Runbook must cover:**
1. **Scope-violation halt:** How to inspect `git diff`, decide whether out-of-scope files should be discarded (`git checkout -- <file>`) or promoted to a new task via `/todo`, how to re-queue the original task
2. **Turn-budget halt:** How to read the partial-completion rapport, decide whether to re-dispatch or split the task, how to extend the budget for a single re-dispatch
3. **Conflict halt:** How to inspect the worktree, resolve or escalate, reset to a known-good state
4. **General:** "When in doubt, preserve" — always create a new task for out-of-scope changes rather than discarding

**Open decision to resolve before writing runbook:**
> Out-of-scope changes: **discard automatically** (clean policy, some legitimate work lost) or **stash for human review** (more overhead, no data loss)? Recommended: stash — copy out-of-scope files to `project/stash/<task_id>/`, restore originals with `git checkout -- <file>`, write stash manifest.

---

### Phase 5 — Tester guardrails *(~3–5 h, after Phase 2 Developer ceiling is stable)*

**Goal:** Apply minimum viable guardrails to the Tester — the highest-trust agent in the system.

**Changes required:**
- `.claude/settings.json`: Add Tester `maxTurns` (calibrated in Phase 2 — provisionally 2× Developer ceiling)
- `tester.md`: Add session-start declaration instruction:
  - At session start, log to `events.json` which test types will be executed (unit / integration / e2e / SAST / performance / coverage)
  - Any test type **not** in `project/configs/test-config.json` requires explicit user approval before execution (already the pattern for SAST — extend it)
- Graduated warnings: same N-5 / N-10 pattern as Developer
- Partial-completion rapport: same format, but with `test_types_completed[]` and `test_types_pending[]` fields instead of file lists

**Acceptance criteria:**
- [ ] Tester logs declared test types to `events.json` at session start
- [ ] Tester `maxTurns` is enforced and documented
- [ ] A Tester session that hits `maxTurns` produces a rapport without leaving the board in a permanently stuck state

---

### Phase 6 — Pre-commit scope hook *(~1–2 d, depends on Phase 3 for machine-readable scope file)*

**Goal:** Move scope enforcement outside the agent's reasoning context — the only guardrail with genuine mechanical teeth.

**Design:**
- Git pre-commit hook (`hooks/pre-commit` or `.git/hooks/pre-commit`) reads the scope declaration from a machine-readable file (e.g., `project/queue/.developer_plan.json`, written by the Developer in Phase 3's abort-and-requeue flow)
- Compares `git diff --name-only --cached` against the declared file list
- Exits non-zero if any staged file is **not** in the list → commit is blocked
- **Glob patterns are rejected** — scope must be file-level, not directory-level
- Agent receives the hook's error output and is instructed to write a scope-violation rapport and halt

**Scope amendment path (open decision):**
> When a legitimately needed file is blocked by the hook (dynamic discovery), what is the amendment flow?
> - Option A: Developer writes amended scope to plan file, user approves, hook re-evaluates
> - Option B: Developer writes scope-amendment request to queue, halts for Scrum Master to re-plan
> Recommended: **Option A** — lower latency, keeps the human in the loop without full pipeline stall

**Changes required:**
- `hooks/pre-commit`: New shell script
- `developer.md`: Instruction to write machine-readable scope file before beginning implementation
- `developer.md`: Instruction that `git commit --no-verify` is prohibited (monitor `events.json` for use)
- `project/queue/.developer_plan.json`: Schema definition

**Acceptance criteria:**
- [ ] A commit that includes a file not in the declared scope is blocked by the hook
- [ ] A commit that includes only declared files passes
- [ ] Glob patterns in the scope file are rejected by the hook
- [ ] The hook does not fire in non-Developer worktrees (scope file absent = hook passes silently)

---

## Open Decisions

Resolve these before beginning the relevant phase:

| # | Decision | Relevant Phase | Options |
|---|----------|---------------|---------|
| OD-1 | Developer halt model: halt immediately after calling Tester (async), or await Tester result before halting (sync)? | Phase 1 | Async (recommended — more resilient) / Sync |
| OD-2 | Out-of-scope changes on halt: auto-discard or stash for human review? | Phase 4 | Stash (recommended — no data loss) / Discard |
| OD-3 | Scope amendment path when pre-commit hook blocks a legitimately needed file | Phase 6 | Option A: user approves amendment (recommended) / Option B: queue halt for Scrum Master |
| OD-4 | Provisional Tester `maxTurns` before calibration data is available | Phase 5 | 2× Developer ceiling (recommended), e.g., 80–100 |

---

## Summary Effort Estimate

| Phase | Effort (realistic) |
|-------|-------------------|
| 1 — Queue bypass fix | 2–4 h |
| 2 — Calibrate maxTurns | 4–8 h |
| 3 — Abort-and-requeue protocol | 1–2 d |
| 4 — Halt recovery runbook | 4–6 h |
| 5 — Tester guardrails | 3–5 h |
| 6 — Pre-commit scope hook | 1–2 d |
| **Total (realistic)** | **6–8 days** |

---

## Related Files

| File | Purpose |
|------|---------|
| `project/documentation/summaries/agent-runaway-guardrails.md` | Full deep-dive synthesis |
| `project/documentation/summaries/scrutiny-agent-guardrails.md` | Scrutiny assessment |
| `project/documentation/summaries/solution-assessment-agent-guardrails.md` | Full solution assessment with all candidate solutions |
