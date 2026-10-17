---
name: j.break
description: Stop an orchestration at the next safe task boundary — the task currently running finishes and records its status, then execution halts before the next one starts. Soft by default (one-shot), `hard` persists until `clear`, and `status` adds a progress rapport for the current scope of execution. Use when a /jenga, /do or /dooo run should pause without killing the turn mid-flight.
keywords:
  - break
  - stop after this task
  - pause the run
  - halt execution
  - stop the line
  - j-break
examples:
  - "j-break"
  - "stop after this task finishes"
  - "pause the run"
  - "halt execution but don't kill anything"
  - "j-break hard"
  - "j-break clear"
---

# Break — Stop at the Next Safe Boundary

`skills/j-break/` is the **canonical, hand-edited** directory for this skill, per CLAUDE.md's "The Canonical Naming Contract". The frontmatter name is `j.break`, never `j.j-break`.

## Why a flag file

A slash command typed during a run cannot reach a background sub-agent or an in-flight loop. `/jenga` Phase 4, `/do`'s step 8 and `/dooo`'s fan-out keep advancing on their own, and there is no channel for a command typed by the operator to arrive in them. So `/break` interrupts nothing: it leaves a request somewhere every loop will look, and each loop checks for it at its own task boundary. That is also why it is safe — nothing is aborted mid-flight, so no worktree is orphaned, no status write is skipped and no bundle manifest loses its rollback anchor.

The flag's schema and lifecycle are documented in `templates/SCRUM_BOARD_SCHEMA.md`, in the section on the break request flag. The file's name is deliberately not repeated here, so that a grep for it across the orchestrator skills stays a reliable check that nobody parses it. **This file contains none of that logic.** Every read, write, consume and clear lives in `skills/j-break/scripts/`; this skill only parses the argument, calls the right script, and tells the user what happened.

## Instructions

Resolve the scripts directory once:

```bash
BREAK_DIR="$([ -d skills/j-break/scripts ] && echo skills/j-break/scripts || echo node_modules/@jenga-ai/agent/skills/j-break/scripts)"
```

### 1. Dispatch on the argument

| Invocation | Run |
|---|---|
| `/break` | `bash "$BREAK_DIR/set-break.sh"` — soft break, consumed by the next loop that reaches a task boundary |
| `/break hard` | `bash "$BREAK_DIR/set-break.sh" --hard` — persists until `/break clear` |
| `/break clear` | `bash "$BREAK_DIR/clear-break.sh"` |
| `/break status` | `bash "$BREAK_DIR/set-break.sh" --status`, **then** `bash "$BREAK_DIR/render-execution-status.sh"` |
| `/break hard status` | `bash "$BREAK_DIR/set-break.sh" --hard --status`, **then** `bash "$BREAK_DIR/render-execution-status.sh"` |

Accept `status` and `hard` in either order. Match the argument words exactly; **never guess.**

### 1.1. `status` is a modifier, not a sub-command

`status` rides on top of a soft or hard break; it has no meaning on its own and **never clears anything**. Only `/break clear` removes a break, and `clear` does not combine with `status` (an unrecognised combination — see section 2).

**The rapport is rendered at two moments, and both matter.**

1. **Immediately**, when the operator runs `/break status`: set the break first, then run `render-execution-status.sh` and print its output verbatim, so the operator sees the state at the moment they asked.
2. **At the halt**, by whichever loop consumes the flag. The flag's `with_status` field is what carries the request across that gap, because the loop cannot see the operator's original arguments. Nothing to do here: `/do`, `/dooo` and `/jenga` already render it when they see `with_status=true`.

**What the rapport can tell you about each finished item.** `/do` appends a line to the gitignored `project/queue/execution-ledger.jsonl` (via `record-execution.sh`) each time it records a terminal status, keyed by session. The rapport marks a finished item `ran this session` when the ledger has an entry for it under the current session key, and `done earlier` otherwise. With no ledger file it shows board status only and says no per-session record exists. Print it verbatim; never guess which session finished an item.

**Standing hard break.** `/break status` against a hard break that is already standing renders the rapport and leaves the mode **hard**: `set-break.sh` never downgrades, and says so in its confirmation line. **Repeat that explicitly in your reply** — "the break remains hard; use `/break clear` to remove it". An operator who thinks they downgraded a break and did not is exactly the confusion to prevent.

**Reading the flag's current state** (for example to describe it to the operator) must use `bash "$BREAK_DIR/check-break.sh" --peek`, never a plain call. A plain call consumes a soft break, which would steal the break from the running loop it was armed for.

**The rendering itself stays in the script.** This skill adds no formatting, no scope resolution and no board reading. If the script fails, say the rapport is unavailable and why; do not improvise one from the board.

### 2. Unrecognised argument

Do **not** guess and do **not** touch the flag. Print the valid forms, per CLAUDE.md's interaction pattern, and take no action:

    That is not a /break form. Which did you mean?
    1. /break — stop after the current task (one-shot)
    2. /break hard — stop, and stay stopped until cleared
    3. /break clear — remove a standing break
    4. /break status — stop, and print a progress rapport for this run
    5. Other (describe below)

### 3. Relay the result

Show the script's one-line confirmation verbatim, then explain what it means in plain terms.

**After setting a break**, state the boundary semantics: the task currently running **finishes and records its status**, then execution **halts before the next one starts**. Nothing is aborted mid-flight.

- **Soft:** the first loop to reach a task boundary honours it and clears it. The next run proceeds normally.
- **Hard:** it stays in place across loops and sessions. **`/break clear` is required** before anything will run again.

**If nothing is in flight**, say so — and do not present it as an error. The flag is still armed and the next run will honour it, which is a legitimate way to use `/break`: arm it, then start the run you want to stop at its first boundary.

**After `clear`**, relay whether a break was actually standing. Clearing when none was set is a success, not a failure.

### 4. Failure

A non-zero exit from a script means the script itself failed, not that a break was requested. Report its stderr verbatim and do not claim a break is in place.

## What this does not do

`/break` halts the **dispatcher**, not a running agent. Every checkpoint sits at a task boundary, so a wedged agent in the middle of a task has no boundary to stop at — that is by design. The only intervention that reaches inside a running agent is `TaskStop`, which `j.check-in` offers behind a second confirmation.
