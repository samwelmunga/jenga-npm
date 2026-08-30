# Your First Feature

> **How-to:** Building a feature end-to-end — from idea to verified, committed code.

---

## The Pattern

```
/brainstorm → /todo → /do → /status
```

This is the core loop. Everything in Jenga AI flows through some version of it.

---

## Step 1: Shape the Work with `/brainstorm`

Don't jump straight to `/todo`. Before anything hits the board, talk through the feature with the Scrum Master.

```
/brainstorm
"I want to add a password reset flow to the app"
```

The Scrum Master will ask:
- Which users does this affect?
- What are the entry and exit points?
- Does this belong under an existing epic, or does it need its own?
- What does "done" look like for a tester?

This dialogue turns a vague idea into concrete acceptance criteria. Nothing is written to the board until you confirm. If the idea is half-formed, the Scrum Master will say so.

**Skip `/brainstorm` only if** the work is so small and clear that acceptance criteria are obvious. Even then, it's rarely a waste.

---

## Step 2: Add to the Board with `/todo`

Once the work is shaped:

```
/todo
"Add password reset flow" → links to E01_S05
```

The Scrum Master creates the story and tasks on the board, validates that acceptance criteria and DoD are present, and adds the task IDs to `project/todo.md`.

---

## Step 3: Execute with `/do`

```
/do
```

The skill reads `project/todo.md`, presents the pending tasks, and you select one (or let it auto-pick). It builds the full sender object and invokes the Developer agent.

The Developer will:
1. Log the sender object to `events.json`
2. Write a plan to `project/documentation/plans/`
3. Create an isolated git worktree
4. Implement at meaningful milestones, committing as it goes
5. Write a summary to `project/documentation/summaries/`
6. Hand off to the Tester with a sender object including commit SHAs

The Tester will:
1. Validate the sender object
2. Run the test suite against the implementation
3. Write the task status to the board (`Passed`, `Failed`, etc.)
4. If all tasks in the story pass, write a `story_rollup` trigger

You don't need to do anything during this phase. The agents communicate directly.

---

## Step 4: Check Progress with `/status`

```
/status
```

```
E01 — Auth System (In Progress)
  S05 — Password Reset ✅ Passed
    T01 — Forgot-password endpoint ✅
    T02 — Reset token generation ✅
    T03 — Reset-password endpoint ✅
```

If a task failed, the Tester will have written a rapport to `project/rapports/problems/`. The next Scrum Master session will pick it up, create a fix task, and add it to the queue.

---

## When Things Go Wrong

**Task status: Failed**
The Tester writes a problem rapport. At the next session start, the Scrum Master reads it and creates a follow-up task. You then run `/do` on that task.

**Task status: Blocked**
The Developer couldn't resolve a conflict after three attempts. The task needs human intervention. Read the rapport in `project/rapports/problems/` — it will describe exactly what's blocking it.

**Task status: Rejected**
The Tester flagged something serious enough to reject the implementation outright. The Scrum Master will confirm with you before writing this status.

---

→ Back to [Intro Guide](../intro-guide.md) | Next: [Working Across Sessions](./multi-session-work.md)
