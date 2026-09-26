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

`skills/j-dooo/` is the **canonical, hand-edited** directory for this skill, per CLAUDE.md's "The Canonical Naming Contract" (the `E50` reopening of 2026-09-09, which promoted `skills/j-dooo/` from generated twin to sole canonical form). The `j-` prefix is there for collision safety — a real directory under a distinct name, so a host tool shipping its own same-named built-in command cannot shadow it (Claude Code's native skill resolution is a literal-string, directory-name-based match; see `docs/skill-authoring.md`'s "Invocation Convention").

> ⚠️ **`scripts/generate-j-alias.sh` was retired by `E50_S14` and no longer exists — there is nothing to run.** This file was previously generated from a bare `skills/dooo/SKILL.md` source; `E50_S15` deleted that directory. This file is now the sole canonical, hand-edited source for this skill — edit it directly.

## Instructions

### 1. Invoke `/do`
Call the `/do` skill to let the user select and start an implementation. `/do` will launch a background sub-agent to handle the implementation. Once the sub-agent is launched, `/do` returns control here.

After `/do` hands back control, mark the story/task that was just started as **In Progress** in its board file (update the `status:` field in the YAML front-matter).

### 2. Return to the board — identify parallelisable tasks

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
- There are no more eligible parallel tasks to offer
