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

### 0. Front-loaded foreground ask (once per `/dooo` invocation)

Before the first `/do` call, `/dooo` asks the `pre-task` judgment item **once for the whole invocation** (`E67_S11_T04`), so no inner `/do` asks again. It is the same mechanism as `/jenga` Phase 0.8 and `skills/j-do/SKILL.md` `### 1.4`, not a second design. The deterministic work lives in `scripts/foreground-preflight.sh`; this section holds only the branch decisions, the prompt reference and the threading rule. Write `FG` for `bash "$([ -f scripts/foreground-preflight.sh ] && echo scripts/foreground-preflight.sh || echo node_modules/@jenga-ai/agent/scripts/foreground-preflight.sh)"`.

1. **Empty pool.** If `scripts/render-ranked-list.sh` prints no eligible item there is no cost to state: skip the rest of this section, show no prompt, mint no id and pass an empty `checklist_run_id`. An inner `/do` then answers for itself as a standalone invocation (`skills/j-do/SKILL.md` `### 1.4`), and `/dooo` still never mints a second id.
2. **Mint.** Run `FG mint` and keep its single line as this invocation's `checklist_run_id`. This is the **only** place `/dooo` mints one: never mint a second id mid-invocation, on any later iteration, after a deferral or after a break check.
3. **Check in, in the host session.** Run `j.check-in` yourself, in this session, never in a sub-agent.
4. **Show the prompt.** Read `skills/j-do/assets/foreground-prompt.md` (or `node_modules/@jenga-ai/agent/skills/j-do/assets/foreground-prompt.md`) and show its **Prompt** section verbatim with the placeholders filled: `<N>` is the number of items `scripts/render-ranked-list.sh` prints now (the pool this invocation draws from; the user has not chosen yet, so this is an upper bound for the first wave, which is the safe direction for a cost statement), `<scope mix>` is those items' `execution_scope` read from their board files, and `<cap>` is `max_concurrent_developers` from `project/configs/scope-thresholds.json`. Do not copy the wording into this file; the asset owns it.
5. **Branch on the answer** (free text is the last option):
   - **Proceed** (option 1): run `FG gate --run "<checklist_run_id>" --via dooo --user-yes`. This is the only call in this section that passes that flag. Exit `0` means both items are ticked for this id: continue to step 1. Any non-zero exit is reported verbatim and ends the `/dooo` invocation with nothing started.
   - **Cancel** (option 2): end the `/dooo` invocation and say so. No `/do` is called, nothing is started and no status is touched, and `dispatch-cost-and-cadence` stays unticked. `gate` is never called on this path, so the flag is never passed.
   - **Other** (option 3), or any free text: unresolved. Answer what was asked, then show the prompt again. Free text is never read as a yes, and `gate` is not called on this path.

**Threading.** The id obtained here is the `checklist_run_id` of the sender object of **every** inner `/do` call, on **every** iteration of the loop (step 1 to step 4), verbatim and unchanged. An inner `/do` is a standalone invocation (`skills/j-do/SKILL.md` `### 4.4` case (a)): its `### 1.4` runs `verify` on the supplied id, finds both items ticked and does not ask a second time. A `/do` that cannot verify the id does not use it. `/dooo` itself never ticks anything except through the one `gate` call above, and never from a sub-agent.

### 1. Invoke `/do`
Call the `/do` skill to let the user select and start an implementation, passing this invocation's `checklist_run_id` from step 0 in the sender object of the call, on every iteration of this loop and unchanged (never re-minted; it is what lets `/do` skip its own ask). `/do` will launch a background sub-agent to handle the implementation. Once the sub-agent is launched, `/do` returns control here.

**Progress ownership (`E92`).** Every `/do` call this loop makes, on every iteration including each loop-back from step 4, passes `progress_owner: "caller"` in its sender object, next to the `checklist_run_id`. An inner `/do` then prints no progress line; `/dooo` owns the print, once per wave, in `### 1.1`.

After `/do` hands back control, mark the story/task that was just started as **In Progress** in its board file (update the `status:` field in the YAML front-matter).

**Exception — a deferred unit is not started.** If `/do` reports the unit was **deferred** ("deferred: pre-flight checklist needs a user decision", per `skills/j-do/SKILL.md` step 4.1.2), do **not** mark it `In Progress`: nothing was started and `/do` has already left (or reverted) it at `Pending`. Say so explicitly to the user — that the unit was deferred, which checklist items need their decision, and that it will be offered again once resolved — then carry on to step 2 as usual.

**Task-completion cleanup is inherited, not re-implemented here.** `/dooo` never dispatches developer sub-agents itself; every task it starts goes through this step's `/do` call, so each one reaches `/do`'s own step 7 and its **Task-Completion Cleanup Procedure** (`skills/j-do/SKILL.md` `### 7.1`) unmodified. No separate wiring is needed in `/dooo` (`E37_S05_T04`). If `/dooo` ever gains a dispatch path that bypasses `/do`, that path must call the procedure by name.

### 1.1. Progress line (`E92`), once per wave

Shows a one-line progress bar after each wave. This section says only **when** to call `skills/j-break/scripts/run-progress.sh`; which story the bar covers, the counting and the drawing all live in that script and the scripts it calls, never here. Write `RP` for `bash "$([ -f skills/j-break/scripts/run-progress.sh ] && echo skills/j-break/scripts/run-progress.sh || echo node_modules/@jenga-ai/agent/skills/j-break/scripts/run-progress.sh)"`. Copy the lines it prints into your reply as a fenced code block (the tool-call row is folded away in the desktop app); `skills/j-break/SKILL.md` ("Progress lines") has the rest of the rule.

**What a wave is here.** One pass through step 1: the `/do` call that pass made and its hand-back to `/dooo`, before step 2. A pass that launched several background sub-agents is still one wave. This step runs between step 1 and step 2 on every pass, the deferral path included, so it always comes before the break check and before step 3 offers the next wave.

1. **Print once per wave.** On every pass, the first included, run `RP --scope story --task <the ids of the tasks this wave finished, comma separated> --after-story --charset utf8 --color never` and copy the lines it prints into your reply as a fenced code block: one bar per distinct story, then one more line for each story this wave just finished (the script groups and decides, not this skill). Print once per wave, never once per task of the wave and never from an inner `/do`. It is best-effort: it never blocks, fails or re-statuses anything, and a warning on stderr is not an error.

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

**Persist usage (`E76_S02_T05`), on every termination above, the break path included.** Before the closing message or halt report, call `bash "$([ -f scripts/task-usage.sh ] && echo scripts/task-usage.sh || echo node_modules/@jenga-ai/agent/scripts/task-usage.sh)" --persist --task <id> [--task <id>]...` once for the task ids this session started in step 1 (`/do` may already have persisted some; repeating is harmless). Existence test first: if `scripts/task-usage.sh` exists in neither location (public mirror), or no task was started, do nothing and print nothing. Otherwise print one line per task from the stdout `results[]`: `persisted` (`persisted`/`updated`/`unchanged`), `possibly incomplete` (`kept-stored`) or `not measured: <message>` (`not-measured`); any other status or non-zero exit is a warning only. This never changes the halt report, the closing message or any task status.
