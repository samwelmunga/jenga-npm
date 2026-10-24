---
name: j.dooo
description: Parallel execution orchestrator. Calls /do to start implementations via sub-agents, then loops back to the board to identify and offer parallelisable tasks until the user selects "Done".
keywords:
  - dooo
  - parallel
  - batch
  - multiple tasks
  - orchestrate
  - j-dooo
examples:
  - "run all pending tasks in parallel"
  - "execute multiple tasks at once"
  - "j-dooo"
metadata:
  prefered_agent: scrum-master
---

# Dooo — Parallel Execution Orchestrator

`skills/j-dooo/` is the **canonical, hand-edited** directory for this skill, per CLAUDE.md's "The Canonical Naming Contract" (the `E50` reopening of 2026-09-09, which promoted `skills/j-dooo/` from generated twin to sole canonical form). The `j-` prefix is there for collision safety — a real directory under a distinct name, so a host tool shipping its own same-named built-in command cannot shadow it (Claude Code's native skill resolution is a literal-string, directory-name-based match; see `project/documentation/skill-authoring.md`'s "Invocation Convention").

> ⚠️ **`scripts/generate-j-alias.sh` was retired by `E50_S14` and no longer exists — there is nothing to run.** This file was previously generated from a bare `skills/dooo/SKILL.md` source; `E50_S15` deleted that directory. This file is now the sole canonical, hand-edited source for this skill — edit it directly.

## Instructions

### 1. Invoke `/do`
Call the `/do` skill to let the user select and start an implementation. `/do` will launch a background sub-agent to handle the implementation. Once the sub-agent is launched, `/do` returns control here.

After `/do` hands back control, mark the story/task that was just started as **In Progress** in its board file (update the `status:` field in the YAML front-matter).

**Exception — a deferred unit is not started.** If `/do` reports the unit was **deferred** ("deferred: pre-flight checklist needs a user decision", per `skills/j-do/SKILL.md` step 4.1.2), do **not** mark it `In Progress`: nothing was started and `/do` has already left (or reverted) it at `Pending`. Say so explicitly to the user — that the unit was deferred, which checklist items need their decision, and that it will be offered again once resolved — then carry on to step 2 as usual.

**Task-completion cleanup is inherited, not re-implemented here.** `/dooo` never dispatches developer sub-agents itself; every task it starts goes through this step's `/do` call, so each one reaches `/do`'s own step 7 and its **Task-Completion Cleanup Procedure** (`skills/j-do/SKILL.md` `### 7.1`) unmodified. No separate wiring is needed in `/dooo` (`E37_S05_T04`). If `/dooo` ever gains a dispatch path that bypasses `/do`, that path must call the procedure by name.

### 2. Return to the board — identify parallelisable tasks

**Break check first** (`E44_S02`). This is the boundary where `/dooo` decides to widen the fan-out, so it is where a requested stop takes effect: after the previous `/do` has handed control back, and **before** the board is scanned for the next set of tasks.

```bash
bash "$([ -f skills/j-break/scripts/check-break.sh ] && echo skills/j-break/scripts/check-break.sh || echo node_modules/@jenga-ai/agent/skills/j-break/scripts/check-break.sh)"
```

- **Exit `0`** — no break. Continue with the scan below, unchanged.
- **Exit `10`** — a break was requested. The record is on stdout as `mode=<soft|hard> with_status=<true|false> requested_at=<ts> requested_by=<who>`. A `soft` break was consumed by that call; a `hard` break remains. **Dispatch nothing, skip the scan, and skip step 3's choice prompt entirely** — offering a numbered list and then refusing to act on the pick would be worse than not asking. Print the halt report below and end the loop (step 5).
- **Any other exit** — the checker itself failed, which is not a stop request. Print its stderr as a warning and continue with the scan.

Never read the flag file here; branch on the exit code and use the record the script prints.

**Halt report.**

1. **Stopped:** state that a break was requested and that **no new sub-agent was dispatched**.
2. **Still running:** a break stops *dispatch*, not execution. **Sub-agents already in flight are not cancelled** and will keep running to completion, writing their own statuses afterwards. List them, so their later status writes are not a surprise: the items this `/dooo` session marked `In Progress` in step 1 whose board status has not yet reached a terminal value. (`ListAgents` gives authoritative liveness, but only from the host session; it is not available to a delegated agent, so do not depend on it.)
3. **Mode:** soft or hard.
4. **Resume:** `/dooo` again for a soft break; for a hard break, `/break clear` first, then `/dooo`.
5. **Scoped rapport:** only when the record says `with_status=true`. Run `bash "$([ -f skills/j-break/scripts/render-execution-status.sh ] && echo skills/j-break/scripts/render-execution-status.sh || echo node_modules/@jenga-ai/agent/skills/j-break/scripts/render-execution-status.sh)"` and print its output verbatim. If it fails, say the rapport is unavailable and why. Never improvise one from the board.

The very first `/do` of a session is covered by `/do`'s own entry check, so a standing hard break also stops a `/dooo` that has not dispatched anything yet.

**Otherwise (no break):**

Run `scripts/render-ranked-list.sh` from the project root. It scans `project/board/stories/` and `project/board/tasks/` against `project/todo.md` and prints the eligible items as a ranked, 1-indexed `<id> — <title>` list (stories first, then tasks) — this is the same eligibility scan and rendering `/dooo` has always used (status `Pending`, no unresolved dependencies, directly listed in `project/todo.md` or — for tasks — parent story listed), now implemented once in a shared script rather than described here as inline prose (`E63_S01_T01`; see `scripts/render-ranked-list.sh`'s own header for the full rule and its env-var overrides). A sibling command, `/todo --ranked-list`, calls the same script for a non-interactive view of this same list.

### 3. Present choices to the user

Relay the script's output as the numbered list (use `ask_user` with `choices`). **Always append "Done" as the last option.**

Example:
```
Which task would you like to start next?
1. Create /spinoff skill (E02_S02)
2. Training Skill Assets & Templates (E01_S06)
3. Done
```

If there are **no eligible tasks** (all remaining todos are blocked or already running), skip straight to step 4.

### 4. Branch on user selection

- If the user selects **"Done"** — exit the loop and inform the user that no more implementations will be started in this session.
- If the user selects a task — go back to step 1 (invoke `/do` for the selected task, then loop).

### 5. Loop termination
The loop ends when:
- The user selects "Done", OR
- There are no more eligible parallel tasks to offer, OR
- **A break was requested** (`/break`) — detected by the check at the top of step 2. This is a requested stop, not a completion: work may remain, and in-flight sub-agents keep running (see the halt report in step 2).
