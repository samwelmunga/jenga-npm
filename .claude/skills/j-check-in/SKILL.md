---
name: j.check-in
description: Report whether the agents this session dispatched are actually alive right now — which are running, which have gone silent past the stall threshold, and which finished but left live processes behind — then offer the owning skill or agent for anything actionable. Use after fanning out work with j.do or j.dooo, or when an agent seems stuck. Complements j.status (declared board state) and j.reconcile (board-versus-git), neither of which answers the liveness question.
output_types: text
keywords:
  - check in
  - stand-up
  - agent liveness
  - is it still running
  - stuck agent
  - wedged agent
  - what is running
  - j-check-in
examples:
  - "j-check-in"
  - "are my agents still running?"
  - "check in on the agents"
  - "is that developer agent stuck or just slow?"
  - "did anything I dispatched go silent?"
---

# Check-In — Same-Session Agent Liveness

`skills/j-check-in/` is the **canonical, hand-edited** directory for this skill, per CLAUDE.md's "The Canonical Naming Contract" (the `E50` reopening of 2026-09-09, which promoted `skills/j-<name>/` from generated twin to sole canonical form). The `j-` prefix is there for collision safety — a real directory under a distinct name, so a host tool shipping its own same-named built-in command cannot shadow it (Claude Code's native skill resolution is a literal-string, directory-name-based match; see `project/documentation/skill-authoring.md`'s "Invocation Convention").

## What this skill is for

Three skills already report on execution state, and none of them answers the liveness question:

- **`j.status`** reports **declared board state** — epic/story/task `status`, open rapports, queue depth.
- **`j.reconcile`** repairs **board-versus-git** divergence.
- **`/break status`** (`E44_S03`) reports **what is in scope for this run**, and its Definition of Done forbids the evidence liveness needs: *"Scope resolution never reads a `.md` file outside `project/board/` and `project/todo.md`."*

The unowned third axis is: **is the thing the board calls `In Progress` actually alive right now, at the OS and harness level?** That is this skill's only job.

---

## 1. Hard rule — the host session collects, and collection is never delegated

Run these five steps **in this order**, and never collapse or reorder them:

1. The **host session** calls `ListAgents`.
2. The **host session** passes that output to `skills/j-check-in/scripts/collect-liveness.sh` on **stdin**.
3. The **host session** renders the report.
4. The **user** picks an option.
5. **Only then** is anything delegated.

**Why this cannot be collapsed.** Called from inside a delegated scrum-master subagent, `ListAgents` returned only **that subagent itself plus seven unrelated interactive peer sessions** — the parent's sibling developer and tester subagents were **invisible**. A delegated agent is therefore structurally blind to exactly the agents it would be asked to check on. A bash script cannot call `ListAgents` either, because it is a harness tool and not a command.

That is why this skill's frontmatter declares **no preferred-agent key at all** (the `metadata` delegation field documented in CLAUDE.md's Skill Frontmatter table is deliberately absent, and the literal key name is not written anywhere in this tree so that a grep for it stays a reliable check). If you find yourself about to delegate step 1, 2 or 3, you have already lost the data the report is about.

---

## 2. Write surface — an invariant, not a guideline

`j.check-in` performs **no board writes, no git operations, no worktree mutations, and no cross-session slot writes**, and it repairs nothing itself.

Its entire write surface is:

- **append-only** entries to `project/logs/events.json`, and
- **`TaskStop`** on an agent in *this* session, after explicit confirmation on a second prompt.

Everything else is delegated to whatever already owns it (see `### 5`). The reason is specific rather than stylistic: every incident recorded in `E37`'s Purpose is a case of one agent acting on an inference about another agent's state. A skill whose whole job is inferring other agents' state from indirect evidence is the worst possible place to also put mutation authority.

`scripts/collect-liveness.sh` enforces its half of this mechanically — it performs zero writes, and `tests/checkin-liveness.bats` asserts that both statically and behaviourally.

---

## 3. Cost rule

A scrum-master subagent is invoked **only** when at least one finding carries `actionable: true`.

A run whose findings are all clear or informational **spawns no agent at all**. This is a stated cost requirement, not an optimisation: a check-in that is cheap when nothing is wrong is what makes it acceptable to fire automatically (`E44_S07`). A clean run is one script invocation of roughly two seconds and nothing else.

---

## 4. Instructions

1. **Call `ListAgents`.**

2. **Transcribe its listing into the collector's input shape, then run the collector.**

   `ListAgents` returns a **human-readable listing, not JSON** — rows like `agents-51 [00eba3] · interactive · started 3h ago`. The collector takes a JSON array, so this transcription is a real step and cannot be a raw pipe. It is one of the few things here that genuinely needs an agent rather than a script: only the host session can call the tool and read its output.

   One object per row:

   ```json
   [{"name": "E71_S05_T02", "state": "running", "session_id": "<id if shown>"}]
   ```

   - **`name`** — the agent's name verbatim. For agents `j.do` dispatched this is the **board id** (`E##_S##_T##`, or `E##_S##` for a bundle), which is what joins a live agent to a board item (`E44_S05_T03`). Do not normalise, prettify or re-derive it.
   - **`state`** — `running` or `completed`. Use **`unknown`** when the listing does not say, and never guess: `unknown` produces no finding, whereas a wrong `running` produces a false stall and a wrong `completed` a false leak.
   - **`session_id`** — only if the listing shows one. Omit or `null` otherwise.

   Interactive **peer sessions** get transcribed too, with `state: "unknown"`. They are not units this session dispatched and the collector will correctly produce nothing for them — including them is what keeps `visibility` honest rather than quietly narrowing the input.

   Then:

   ```bash
   printf '%s' "$AGENTS_JSON" | bash "$([ -f skills/j-check-in/scripts/collect-liveness.sh ] && echo skills/j-check-in/scripts/collect-liveness.sh || echo node_modules/@jenga-ai/agent/skills/j-check-in/scripts/collect-liveness.sh)"
   ```

   If `ListAgents` is unavailable in this context, pass `--no-agents` instead and pipe nothing. That is the degraded mode `E44_S07`'s automatic path uses; the report must then say so (step 4).

   The script emits exactly **one JSON object** on stdout and **always exits `0`** — findings are signalled in the JSON, never in the exit code. A non-zero exit means the script itself failed, not that something is wrong with the session. Do not re-run it hoping for a different answer.

3. **Read the JSON.** Its shape:

   | Key | Meaning |
   |---|---|
   | `generated_at` | ISO 8601 collection timestamp |
   | `session_id` | the collecting session |
   | `visibility` | what this run could and could not see — `in_session`, `cross_session`, `agents_input`, `notes` |
   | `findings` | the finding objects (see `### 5`) |
   | `residue` | counts of on-disk leftovers from other or past sessions |
   | `counts` | finding totals by severity |

   Each finding carries `code`, `severity` (`error`/`warn`/`info`), **`actionable` as a separate boolean**, `subject`, `evidence`, `escalation`, and `owning_skill`. `severity` says how loud it is; `actionable` says whether there is anything to *do*. Never infer one from the other — an `info` finding with `actionable: false` gets reported and nothing more.

4. **Render the report** per `assets/output_format.md`. Two tiers, in order: this session's agents first and in detail, then residue as a counts-only footnote. **Always end with the could-not-see line**, sourced from `visibility`. Never omit or abbreviate it away because the run looked clean — a report that implies completeness when it was actually blind converts "I do not know" into a false "all clear", which is the failure mode that hurts most here.

5. **Offer options** for actionable findings only, per `### 5`. Every option list follows CLAUDE.md's numbered Interaction Pattern with free text as the final numbered option.

6. **Append exactly one event** to `project/logs/events.json` with `bash "$([ -f scripts/events-append.sh ] && echo scripts/events-append.sh || echo node_modules/@jenga-ai/agent/scripts/events-append.sh)" '<json-record>'` (the file is JSONL: one compact object per line, append only; never rewrite it). The record:

   ```json
   {
     "event": "checkin",
     "agent": "orchestrator",
     "session_id": "<the collector's session_id>",
     "session_key": "<bash scripts/checklist-marker.sh session-key>",
     "counts": {"error": 0, "warn": 2, "info": 3},
     "actionable": 2,
     "visibility": {"in_session": true, "cross_session": "partial", "agents_input": "listagents"},
     "date": "<ISO 8601 UTC>"
   }
   ```

   **`session_key` is load-bearing and not a duplicate of `session_id`.** It is what `scripts/checkin-gate.sh` matches on to decide whether a check-in has already run in this session (`E44_S07`), and it must come from `scripts/checklist-marker.sh session-key` — the single resolver the situation marker and the gate both use. The collector derives its own `session_id` from a different probe order (`SESSION_ID` / `HARNESS_SESSION_ID` / `hostname-pid`), so the two values legitimately differ and the gate would not match on `session_id` alone in a normal session. Write both: `session_id` is what the report showed the user, `session_key` is what the machinery joins on.

   **The event is spelled `checkin`, and that is the single canonical spelling** — no underscored, suffixed or synonymous variant of it anywhere, in this file or any other. `project/logs/events.json` already carries severe event-name drift — `test_run_complete` (30) / `test_run_completed` (26) / `test_run` (19) / `test_result` (16); `sender_received` (359) / `sender_object_received` (28) / `incoming_sender` (14) — plus 132 entries with no `event` key at all. This feature must not add to it, which is why the alternatives are described here rather than written out: a second spelling must not exist in this tree even as an example of what not to write. `E44_S07`'s gate greps for this exact spelling to decide whether a check-in already ran this session.

7. **Delegate** whatever the user picked, and nothing they did not.

---

## 5. Findings and what to do about them

### 5.1. The gate — options are for actionable findings only

Render an option list **only** for a finding whose `actionable` field is `true`. A finding with `actionable: false` is **reported and nothing more**: no options, no "would you like me to…", no implied next step. `severity` does not override this — an `actionable: false` finding at `warn` severity is still report-only.

The codes that carry option lists are **`F1`, `F2`, `F5` and `F6`**. `F3`, `F4` and `F13` never do.

**One narrow exception, driven by the collector and not by judgment.** An `F1` finding at `info` severity (idle past the warn threshold, under the stall threshold) is `actionable: false`, but when it carries `escalation.break_available: true` it gets the short `/break` option list in `### 5.3.1`. Nothing else does. The collector sets that field; never infer it.

**A scrum-master subagent is invoked only when at least one finding is `actionable`.** This is a cost requirement (`### 3`), not an optimisation: a run whose findings are all clear or informational must spawn no agent at all.

### 5.2. The delegation boundary

This is the whole point of the skill's containment: `j.check-in` resolves a finding to **the owner of that mutation** and offers to invoke it. It never does the owner's job.

| Residue / finding class | Goes to | Why |
|---|---|---|
| Undrained `scrum_triggers.jsonl` entries | **scrum-master** | Its Drain Scrum Triggers Queue procedure |
| Open rapports (not `*.IGNORE.md`) | **scrum-master** | `rapport_review` is its trigger type |
| `F5` / `F6` board-vs-reality disagreement | **scrum-master** for the `status_review` judgment, then **`j.reconcile`** for the actual demote/promote | The scrum-master decides, `j.reconcile` repairs; do not merge the two |
| Stale worktrees | **`j.reconcile`** | It already merges orphaned worktree branches |
| Worktree **removal** | **nobody, via this skill** | `scripts/worktree-remove-guard.sh` and the `WorktreeRemove` hook own it and already hard-block on this exact condition |
| Other sessions' slot files | **report-only** | Both `scripts/acquire-concurrency-slot.sh` and `scripts/release-concurrency-slot.sh` state in their headers that they never read or write a counter file for any session other than their own |
| `F13` liveness undeterminable | **report-only** | The script could not determine liveness; there is nothing to act on, only something to disclose |

**Sequencing.** Delegation happens at **step 5** of the host-session hard rule in `### 1` — after collection, rendering, and the user's pick. Never before. Do not pre-emptively spawn the scrum-master "to have it ready", and do not fold a delegation into the rendering step.

### 5.3. `F1` — running, but idle past the stall threshold

Actionable. The agent is reported `running` and nothing dated has come from it in over 45 minutes. It may be wedged, or it may be doing one long thing — the collector cannot tell, and neither can you from here.

    E71_S06_T01 has been running for 52 minutes with no logged activity.
    What would you like to do?
    1. Re-observe in a few minutes (recommended — long single tasks look identical to wedged ones)
    2. Show me the full evidence for this finding
    3. Stop this agent with TaskStop
    4. Leave it alone — report only
    5. Other (describe below)

**Re-observe is first and recommended, and `TaskStop` comes after it.** The ladder is observe → re-observe after a grace period → confirmed `TaskStop` (`### 6`).

**`TaskStop` requires a second, explicit confirmation prompt.** Picking option 3 does not call it:

    TaskStop will terminate E71_S06_T01 mid-task. Its worktree and any
    uncommitted work in it stay on disk, but the task will not finish and its
    board status will not be written by the agent.
    Confirm?
    1. No — go back
    2. Yes, stop E71_S06_T01
    3. Other (describe below)

Do **not** offer `/break` or `/j-break` in this list: this is the stalled-agent list, and `/break` cannot reach a stalled agent. See `### 6` for the honest line to print if the user asks for something gentler.

### 5.3.1. `F1` at `info` with `break_available: true` — healthy, but long

Only when the finding's `escalation.break_available` is `true`. The agent is a running dispatcher (a bundle agent, or an agent inside an epic with a live epic lock), it is **not** stalled, and work remains queued behind it. Show `escalation.break_reason` as the line explaining why.

    E71_S06 has been running for 31 minutes. <break_reason>
    What would you like to do?
    1. Re-observe in a few minutes (recommended)
    2. /break — stop new work being dispatched at the next task boundary; the running agent is not touched
    3. Show me the full evidence for this finding
    4. Leave it alone — report only
    5. Other (describe below)

`/break hard` and `/break clear` are mentioned only as follow-ups after the user picks option 2, never as list entries. Picking option 2 invokes `j.break` and nothing else: it halts the dispatcher, it does not stop `E71_S06`, and there is no `TaskStop` in this list. `TaskStop` is reachable only through `### 5.3` for a stalled agent, behind its own second prompt.

### 5.4. `F2` — completed, but processes are still rooted in its worktree

Actionable, and deliberately narrow.

    E69_S04_T03 reports completed, but 2 processes still have their cwd
    inside .claude/worktrees/E69_S04_T03-slug.
    What would you like to do?
    1. Leave it alone — report only (recommended)
    2. Show me the processes (PIDs and commands)
    3. Note it for later with j.todo
    4. Other (describe below)

**There is no worktree-removal option here, by design.** This finding is precisely the 2026-08-25 incident class recorded in `E37`'s Purpose and in `scripts/check-worktree-liveness.sh`'s header: a completed agent's orphaned shell loops had their cwd deleted out from under them. `scripts/worktree-remove-guard.sh` and the `WorktreeRemove` hook already own that path and already hard-block on exactly this condition. Offering removal here would either duplicate that guard or invite an override of it. **Do not add one, and do not route around the hook if the user asks.** Point them at the guard instead.

### 5.5. `F5` — board says `In Progress`, but nothing is alive

Actionable. A worktree exists, no agent of that board id is running, and no process is rooted inside it. Either the agent died without writing its status, or the board is stale.

    The board says E53_S11_T01 is In Progress, but no agent is running for it
    and nothing is alive in its worktree.
    What would you like to do?
    1. Ask the scrum-master to judge it (status_review) — recommended
    2. Run j.reconcile to repair the board against git
    3. Show me the full evidence for this finding
    4. Leave it alone — report only
    5. Other (describe below)

**Keep the two halves separate.** The scrum-master makes the `status_review` judgment; `j.reconcile` performs the demote or promote. Offering a single "fix it" option that does both would collapse a decision into a repair, and the decision is not this skill's to make.

### 5.6. `F6` — board says `In Progress`, but no worktree exists

Actionable, same ownership split as `F5`.

    The board says E53_S11_T01 is In Progress at task scope, but no worktree
    exists for it.
    What would you like to do?
    1. Ask the scrum-master to judge it (status_review) — recommended
    2. Run j.reconcile to repair the board against git
    3. Show me the full evidence for this finding
    4. Leave it alone — report only
    5. Other (describe below)

The collector already exempts `light` and `inline` scopes from `F6`, because `j.do` implements those against the current checkout and never gives them a worktree. If you see `F6` on a `light` or `inline` item, that is a collector defect — report it rather than acting on it.

### 5.7. Report-only classes — rendered, never actioned

These appear in the report and carry **no option list at all**:

- **`F3`** — this session's slot holder past TTL. `scripts/acquire-concurrency-slot.sh` already drops stale holders before its cap check, atomically, inside one locked critical section. A manual release would duplicate an automatic mechanism that has already handled it.
- **`F4`** — another session's slot holder past TTL. Always `actionable: false`. Both slot scripts' headers state they never read or write a counter file for any session other than their own, so there is no action this session is permitted to take.
- **`F13`** — liveness undeterminable. There is nothing to act on, only something to disclose. Surface it per `assets/output_format.md` and leave it there.
- **Worktree removal**, for any finding. Owned by `scripts/worktree-remove-guard.sh` and the `WorktreeRemove` hook.
- **Residue counts** (Tier B). Undrained triggers and open rapports may be offered to the scrum-master as a single combined option when the user asks; the counts themselves are never acted on row by row, because Tier B does not enumerate rows.

---

## 6. The escalation ladder — three rungs

**observe, then `/break` (only when offered), then confirmed `TaskStop`.** The rungs act on **different subjects**, so they are not a graduated series for one problem:

| Rung | Acts on | Offered when |
|---|---|---|
| observe / re-observe | nothing | always first and recommended |
| `/break` | the **dispatcher**: stops new work being dispatched at the next task boundary; the running agent is not touched | only when the finding carries `escalation.break_available: true` |
| `TaskStop` | one **agent**: the only rung that reaches inside a running agent | a stalled agent (`F1` at `warn`), behind a **second**, explicit confirmation prompt |

**`/break` is not a gentler `TaskStop`.** Every break checkpoint sits at a task boundary (`/do` step 8, the story-bundle inner loop after each per-task status write, `/dooo` before the next wave, `/jenga` Phase 4 after each wave). A wedged agent in the middle of a task has no boundary to halt at, by design, so `/break` can never unwedge one. For that reason the collector sets `break_available: true` only for a running dispatcher that is **not** stalled and has queued work left behind it, with `check-break.sh` present and no break already pending (read through `check-break.sh --peek`). Stalled agents, `F2`, `F3`, `F4`, `F5`, `F6` and `F13` always carry `false`. Never decide eligibility yourself; read the field.

**When `break_available` is `true`**, offer `/break` per `### 5.3.1`, with the wording "stop new work being dispatched at the next task boundary; the running agent is not touched", and show `escalation.break_reason`. Mention `/break hard` and `/break clear` only as follow-ups.

**When `break_available` is `false`** and the user asks for something gentler than `TaskStop` for a wedged agent, print the honest line rather than inventing a rung:

> There is no softer intervention for a wedged agent. `/break` stops the *dispatcher* from starting new work at the next task boundary; it does not reach this agent, which has no boundary to halt at, so it does not apply here. Re-observing is the only gentler step; `TaskStop` is the only one that reaches this agent.

---

## 7. The empty case

When nothing is in flight, say so plainly in one line and point at `j.status` for the full board. Do **not** silently fall back to printing board state — that would make `j.check-in` a worse `j.status` instead of an answer to a different question.

---

## Notes

- Per CLAUDE.md's Skill Implementation Principle, every deterministic step here — gathering evidence from the six on-disk sources, joining it, computing idle times and TTL ages, and deciding which finding codes apply — lives in `scripts/collect-liveness.sh`, not in this file. What stays here is judgment: how to render, what to offer, and when to delegate.
- Idle-warn (20 minutes) and stall (45 minutes) thresholds are hardcoded in the collector in this scope, with a code comment naming their future config keys. **The stall threshold must not be lowered**: session `tester-E69_S06-bundle` logged nothing between `22:58:05Z` and `23:20:17Z` — 22 minutes of total silence from a perfectly healthy tester running test suites.
- The agent-to-board join relies on `j.do` naming each background subagent after the board id of the unit it is executing (`E44_S05_T03`). That name is load-bearing, not cosmetic.
