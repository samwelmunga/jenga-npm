# Working Across Sessions

> **How-to:** Picking up a project after a break — without losing momentum or context.

---

## The Problem This Solves

On a single-session project, context loss doesn't matter. On anything longer — a real feature, a multi-day sprint, a project you return to after a week — it does. Without structure, the start of every session is a re-orientation exercise.

With Jenga AI, the board, the event log, and the trigger queue hold the context. You just need to read them.

---

## Resuming a Session

**Option 1 — Let the system orient you:**
```
/continue
→ Reads PROJECT_SUMMARY.md and board state
→ "E01_S02 is In Progress. T02 (refresh tokens) is Pending.
   Recommended next: /do E01_S02_T02"
```

**Option 2 — Get the full picture first:**
```
/status
→ Prints every epic, story, and task with current status
→ Lists open rapports and queue depth
```

**Option 3 — Let the Scrum Master decide:**
```
/proceed
→ Scrum Master reviews board and immediately resumes execution
→ No prompt needed — it picks up the most logical next task
```

---

## What the Scrum Master Does at Session Start

Before it responds to anything you say, the Scrum Master processes `project/queue/scrum_triggers.jsonl`. These triggers were written by `on_session_end.sh` at the end of the previous session.

Typical triggers and what they produce:

| Trigger | What the Scrum Master does |
|---|---|
| `status_review` | Scans the board for any stale statuses, surfaces a summary |
| `rapport_review` | Reads new problem rapports, creates fix tasks or marks stories Failed |
| `story_rollup` | Promotes story status to Passed if all tasks passed |

After processing, it clears the queue and reports to you: *"Processed 2 triggers: created T04 from rapport, story E01_S02 rolled up to Passed."*

---

## Keeping the Board Honest

The board is only as useful as it is accurate. Two things can cause drift:

1. **Work done outside the workflow** — you manually edited a file or committed directly without going through `/do`
2. **Interrupted sessions** — a task was started but never finished; the board still shows "In Progress"

Fix this with:
```
/reconcile
→ Cross-checks every task status against git history
→ Promotes tasks with matching commits that are still marked Pending
→ Demotes tasks marked Done with no commits found
→ Merges orphaned worktrees
→ Cleans stale entries from todo.md
```

Run `/reconcile` after any session where things got messy, after a big merge, or whenever the board feels off.

---

## The Habit: Start and End Every Session Intentionally

**At the start:**
```
/continue   ← or /status, or /proceed
```

**At the end:**
Let the session end hook do its work. If you're ending mid-task, just stop — the hook will log it and queue a `status_review`. The Scrum Master will pick it up next time.

If you've just finished a story and want to commit cleanly:
```
/lgtm       ← approve, commit, continue in one command
```

---

## Long Breaks

If you haven't touched a project in weeks, the board is still there and accurate. `PROJECT_SUMMARY.md` holds the high-level context. Run `/status` for a full picture, then `/continue` to get moving again.

There's no re-onboarding ceremony. The system was designed for this.

---

→ Back to [Intro Guide](../intro-guide.md) | Next: [Capturing Mid-Flow Ideas](./mid-flow-capture.md)
