## Output Format

Two tiers, in this order, always. Tier A is the product; Tier B is context. The could-not-see line closes every report without exception.

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 CHECK-IN · <generated_at>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

 THIS SESSION  (2 warn · 1 info)

 🟢 E71_S05_T02   running     idle 3m    1 proc
 🟡 E71_S06_T01   running     idle 52m   1 proc   F1 · past the 45m stall threshold
 🔴 E69_S04_T03   completed   —          2 procs  F2 · finished, processes still rooted in its worktree
 ⚪ E53_S11_T01   In Progress —          no worktree  F6 · board says In Progress, no worktree exists

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 RESIDUE  (other and past sessions · report only)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 13 undrained triggers · 10 open rapports · 40 slot files (other sessions) · 58 stale worktrees
 oldest: 2026-08-07T02:35:00Z

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Could not see: peer sessions are unattributable without a harness bridge;
 lsof or /proc may be unavailable. Cross-session visibility: partial.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Tier A — this session

The agents this session dispatched. **Authoritative, goes first, gets the detail.** One row per agent or board item that produced a finding, plus a row for every live agent even when it produced none — a check-in that lists only problems cannot answer "is it still running?", which is the question that brings people here.

**Row format**, in column order:

| Column | Source | Notes |
|---|---|---|
| Icon | `severity` + `actionable` | see the icon table below |
| Board id | `subject.task_id` (or `subject.agent`) | the `j.do` subagent name, which *is* the board id (`E44_S05_T03`) |
| State | `evidence.listagents_state`, or `evidence.board_status` when there is no agent | `running`, `completed`, or `In Progress` |
| Idle | `evidence.idle_minutes` | render as `idle <n>m`; render `—` when null, never `0m` |
| Worktree processes | `evidence.worktree_live_processes` | `<n> proc`/`<n> procs`; `no worktree` when `evidence.worktree` is null; `unknown` when the probe could not determine it |
| Finding | `code` + a one-line gloss | omit entirely for a clean row |

`idle —` and `idle 0m` mean different things: the first is "no dated event matched this agent", the second would be "active this minute". Never collapse the former into the latter, and never into a blank cell that reads as fine.

---

## The `/break` option and its reason line

Rendered **only** under a finding whose `escalation.break_available` is `true` (a healthy-but-long dispatcher with queued work; in practice an `F1` at `info`). Print `escalation.break_reason` as the finding's gloss, then the option, with this wording exactly:

```
 🟢 E71_S06   running     idle 31m   1 proc   F1 · long-running, not stalled
    a live bundle for E71_S06 is running and 4 item(s) are still queued;
    /break would stop new dispatch at the next task boundary and would not
    touch the running agent

 What would you like to do?
 1. Re-observe in a few minutes (recommended)
 2. /break — stop new work being dispatched at the next task boundary; the running agent is not touched
 3. Show me the full evidence for this finding
 4. Leave it alone — report only
 5. Other (describe below)
```

`/break hard` and `/break clear` appear only as follow-ups after option 2 is picked. Never render `/break` for a stalled agent, or for `F2`, `F3`, `F4`, `F5`, `F6` or `F13`, and never in the same list as `TaskStop`.

---

## Tier B — residue

A **short footnote**: counts only, plus the oldest residue timestamp. One line of counts, one line for the timestamp.

**No per-item enumeration.** Do not list the 13 triggers, do not name the 58 worktrees. This skill's scope is same-session liveness; residue is context, not the subject, and a long enumeration here buries Tier A — which is the only part the user came for. `j.status` already prints queue depth and open rapports; `j.reconcile` already enumerates stale worktrees.

Render it even when every count is zero (`no residue`), so its absence is never ambiguous with its omission.

---

## The could-not-see line — mandatory

**Every report ends with a statement of what the run could not see, sourced from the collector's `visibility` object.**

- It is **never omitted.**
- It is **never abbreviated away because the run looked clean.** A clean report with no visibility statement is indistinguishable from a blind one, and that is the failure mode that hurts most here: it converts "I do not know" into a false "all clear".
- Compose it from `visibility.notes`, and always state `visibility.cross_session` (`full` / `partial` / `none`) explicitly.

**When `cross_session` is `none`**, lead with it rather than appending it. The run could not determine liveness at all, and the reader must not have to reach the last clause to learn that:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 ⚠️  LIVENESS UNDETERMINED — this report is not a clear signal.
 check-worktree-liveness.sh could not determine liveness (neither lsof nor
 /proc available). Nothing below should be read as "nothing is running".
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**Under the automatic path** (`--no-agents`, `E44_S07`), the line must state that **the harness agent list was unavailable**, so the reader knows Tier A is on-disk evidence only and the per-agent lifecycle column is absent rather than empty:

```
 Could not see: the harness agent list was unavailable (automatic path), so
 this ran on on-disk evidence only — no per-agent lifecycle state.
 Cross-session visibility: partial.
```

---

## The empty case

When nothing is in flight — no findings, no live agents — say so plainly in **one line** and point at `j.status`. Then the residue footnote and the could-not-see line, both still required.

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 CHECK-IN · 2026-10-07T12:00:00Z
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Nothing in flight in this session. For the full board, run j.status.

 RESIDUE  6 undrained triggers · 153 open rapports · 44 slot files (other sessions) · 27 stale worktrees
          oldest: 2026-10-06T12:05:00Z

 Could not see: peer sessions are unattributable without a harness bridge.
 Cross-session visibility: partial.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**Never silently fall back to printing board state.** That would turn `j.check-in` into a worse `j.status` rather than an answer to a different question. "Nothing is running" is a complete and useful answer; padding it with the board is not.

---

## Icons

Consistent with `skills/j-status/assets/output_format.md`'s status-icon table, extended for the severity-plus-actionable pair this skill reports. `severity` sets the colour; `actionable` decides whether an option list follows the row.

| Icon | Meaning | Collector fields |
|------|---------|------------------|
| 🟢 | alive and recently active — no finding | no finding for this subject |
| 🟡 | needs a look | `severity: warn`, `actionable: true` |
| 🔴 | finished but leaking processes | `code: F2` |
| ⚪ | reported, nothing to do | `actionable: false` (any severity) |
| ⚠️ | could not determine | `code: F13`, or `visibility.cross_session: none` |
| 📖 | story-scoped unit (a `j.do` bundle) | `subject.task_id` matches `E##_S##` |
| 🔧 | task-scoped unit | `subject.task_id` matches `E##_S##_T##` |

An `error`-severity finding would render 🔴. The collector emits none in this scope — `counts.error` is always `0` today — so do not build the report around one, and do not hide the counter either.
