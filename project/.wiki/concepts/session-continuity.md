# Session Continuity

> **Concept:** Why AI sessions losing context is the core problem — and how Jenga AI solves it structurally.

---

## The Core Problem

Every AI agent session starts fresh. There is no built-in memory of:
- What was built last session
- What was tested and passed
- What was blocked and why
- What the next task is

Without a framework, you re-orient the AI at the start of every session. You paste in context, re-explain decisions, and hope the model picks up roughly where things left off. On long projects, this becomes unsustainable.

---

## How Jenga AI Preserves Context

Jenga AI stores context in **files, not in the model's memory**. Several structures work together:

| Structure | Location | What it stores |
|---|---|---|
| Project summary | `project/PROJECT_SUMMARY.md` | Goals, architecture, conventions, current state |
| Scrum board | `project/board/` | Status of every epic, story, and task |
| Event log | `project/logs/events.json` | Append-only record of every inter-agent action |
| Trigger queue | `project/queue/scrum_triggers.jsonl` | Work deferred to the next Scrum Master session |
| Rapports | `project/rapports/` | Problems and analyses that need follow-up |

When a new session starts, the Scrum Master reads these files and reconstructs the full project state — without you having to explain anything.

---

## The Session-End Hook

When any session ends, `hooks/on_session_end.sh` runs automatically. It:

1. Logs a `session_end` event to `events.json`
2. Scans for new problem rapports not yet reviewed
3. Writes a `rapport_review` trigger if any are found
4. Always writes a `status_review` trigger

The next time the Scrum Master starts, it processes these triggers before responding to you. This is how it "knows" what happened last session.

---

## The Worktree Pattern

The Developer creates an **isolated git worktree** for every task. This means:

- Each task's implementation is in its own branch from the start
- Multiple tasks can run in parallel without merge conflicts
- If a task is abandoned or fails, the worktree can be cleaned up without touching main

Worktree names match the task ID: `E01_S02_T01-jwt-middleware` — so you can always trace a worktree back to its task.

---

## What "Resuming" Looks Like

With Jenga AI, resuming a project is not a re-orientation exercise. It's:

```
(New session)
/continue
→ Scrum Master reads PROJECT_SUMMARY.md and board state
→ "E01_S02 is In Progress. T02 (refresh tokens) is Pending.
   Recommended next: /do E01_S02_T02"
```

Or, if the session-end hook wrote triggers:

```
(Scrum Master processes queue first)
→ Found rapport_review for E01_S02_T01
→ Created task E01_S02_T04 "Fix null pointer in token service"
→ Status review: no other changes
→ "Ready. E01_S02_T02 and T04 are both pending — which do you want to start?"
```

You pick up exactly where you left off. The model doesn't need to remember — the files do.

---

## The Practical Implication

The board is not optional overhead. It *is* the memory. If you skip updating it — working directly in the code without going through `/do` and the Tester — that context is lost at the next session boundary.

Use `/reconcile` if the board has drifted from actual git history. It cross-checks every task status against commits and corrects any discrepancies.

---

→ Back to [Intro Guide](../intro-guide.md) | First how-to: [Your First Feature](./first-feature.md)
