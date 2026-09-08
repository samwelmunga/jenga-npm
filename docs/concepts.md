---
layout: page
title: Concepts
permalink: /concepts.html
---

## Concepts

The ideas behind Jenga AI's structure, and the how-tos for using it day to
day. Jump to any section:

- [Role Separation](#role-separation)
- [Board Hierarchy](#board-hierarchy)
- [Session Continuity](#session-continuity)
- [Your First Feature](#your-first-feature)
- [Working Across Sessions](#working-across-sessions)
- [Capturing Mid-Flow Ideas](#capturing-mid-flow-ideas)
- [Parallel Tasks](#parallel-tasks)

---

## Role Separation


> **Concept:** Why Jenga AI uses three distinct agents instead of one.

---

### The Problem with One Agent Doing Everything

When a single AI writes code *and* verifies it in the same context, you get **self-affirming feedback loops**. The model that wrote the code is the same model evaluating whether it's correct — which means it carries all the same assumptions, gaps, and blind spots into the review. It will tend to confirm what it just wrote.

This isn't hypothetical. Ask any AI to "write a function and test it" in one shot and it will produce tests that test the function it wrote, not the function the *spec* required.

---

### How Jenga AI Separates Roles

Jenga AI enforces three non-overlapping roles:

| Agent | Owns | Never does |
|---|---|---|
| **Scrum Master** | Planning, board, project memory | Write code, run tests |
| **Developer** | Implementation, worktrees, commits | Run tests, update task status |
| **Tester** | Validation, task/story status, baselines | Write implementation code |

The key constraints:

- **The Developer never runs tests.** It hands off to the Tester with a typed sender object containing commit SHAs.
- **The Tester is the sole writer of task/story status.** Not the Developer, not the Scrum Master.
- **The Scrum Master owns `PROJECT_SUMMARY.md` exclusively.** Other agents submit proposed changes to a queue; the Scrum Master decides what gets applied.

---

### Why Exclusive Ownership Matters

Each agent having exclusive write access to specific files prevents:
- **Race conditions** — two agents updating the same file simultaneously
- **Status drift** — the Developer marking its own work as passed
- **Context pollution** — the Tester carrying implementation assumptions into the review

The **file locking protocol** (`.lock` files adjacent to board items) enforces this mechanically. If you see a `.lock` file, an agent is currently writing to that item — no other agent may write until the lock is released.

---

### The Practical Implication for You

You don't instruct the Developer to test, and you don't ask the Tester to fix code. The workflow enforces this for you. If something breaks in a test, the Tester writes a rapport to `project/rapports/problems/` — the Developer picks that up in the next cycle.

This separation is what makes Jenga AI's results trustworthy across sessions: the Tester's verdict is independent.

---

→ Back to [Intro Guide](./getting-started.md) | Next concept: [Board Hierarchy](#board-hierarchy)

---

## Board Hierarchy


> **Concept:** Why work is structured as Epics → Stories → Tasks, and how to use that hierarchy well.

---

### The Three Levels

| Level | What it represents | Example |
|---|---|---|
| **Epic** | A large body of work with a clear goal | "User Authentication System" |
| **Story** | A complete user-facing or system-level outcome | "As a user, I want to log in with email/password" |
| **Task** | A concrete technical unit of work | "Add JWT validation middleware" |

The hierarchy isn't bureaucracy — it's a **scope contract**. Each level answers a different question:

- **Epic** → *What are we building and why?*
- **Story** → *Who benefits and what's the complete outcome?*
- **Task** → *What's the smallest independently-implementable unit?*

---

### Why the Hierarchy Exists

Without structure, AI-assisted development tends toward:
- **Scope creep** — a "small feature" quietly expands
- **Missing context** — the Developer picks up a task without knowing the broader goal
- **Incomplete verification** — the Tester doesn't know what "done" looks like

The board hierarchy solves all three:

1. **Stories have Acceptance Criteria** — written so a Tester can verify them without asking
2. **Tasks reference their parent story** — the Developer always knows the broader context
3. **Epics and Stories have a Definition of Done** — rollup only happens when all criteria are met

---

### How Rollup Works

Jenga AI automatically promotes status up the hierarchy when all children pass:

```
Task T01 → Passed ✅
Task T02 → Passed ✅
Task T03 → Passed ✅
           ↓
Story S01 → Passed ✅ (Tester triggers story_rollup)
           ↓
(When all stories under E01 pass)
Epic E01 → Passed ✅ (Scrum Master processes trigger)
```

This means you don't manually mark a story complete — the Tester writes the trigger, and the Scrum Master processes it at the start of the next session.

---

### Practical Guidelines

**When to create an Epic vs. a Story:**
- If the work naturally decomposes into 3+ complete user outcomes → Epic
- If it's a single complete outcome → Story directly under an existing Epic
- When in doubt, use `/brainstorm` — the Scrum Master will help you decide

**When to create a Task vs. a Story:**
- Tasks are technical sub-steps *within* a story, not standalone features
- If someone outside the project would say "I want X" about it → Story
- If only a Developer would say "I need to do X to implement Y" → Task

**The Maintenance Epic pattern:**
Jenga AI reserves a "Maintenance" epic as the default home for chores, refactors, and housekeeping tasks that don't belong under a feature epic. Use it rather than forcing technical debt into unrelated stories.

---

### Naming Conventions

Board files follow strict naming so they sort naturally and can be referenced unambiguously:

| Type | File name pattern | Example |
|---|---|---|
| Epic | `E##_<slug>.md` | `E01_auth-system.md` |
| Story | `E##_S##_<slug>.md` | `E01_S02_email-login.md` |
| Task | `E##_S##_T##_<slug>.md` | `E01_S02_T01_jwt-middleware.md` |

Numbers are zero-padded. Always. `E01`, `S03`, `T07` — never `E1`, `S3`, `T7`.

---

→ Back to [Intro Guide](./getting-started.md) | Next concept: [Session Continuity](#session-continuity)

---

## Session Continuity


> **Concept:** Why AI sessions losing context is the core problem — and how Jenga AI solves it structurally.

---

### The Core Problem

Every AI agent session starts fresh. There is no built-in memory of:
- What was built last session
- What was tested and passed
- What was blocked and why
- What the next task is

Without a framework, you re-orient the AI at the start of every session. You paste in context, re-explain decisions, and hope the model picks up roughly where things left off. On long projects, this becomes unsustainable.

---

### How Jenga AI Preserves Context

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

### The Session-End Hook

When any session ends, `hooks/on_session_end.sh` runs automatically. It:

1. Logs a `session_end` event to `events.json`
2. Scans for new problem rapports not yet reviewed
3. Writes a `rapport_review` trigger if any are found
4. Always writes a `status_review` trigger

The next time the Scrum Master starts, it processes these triggers before responding to you. This is how it "knows" what happened last session.

---

### The Worktree Pattern

The Developer creates an **isolated git worktree** for every task. This means:

- Each task's implementation is in its own branch from the start
- Multiple tasks can run in parallel without merge conflicts
- If a task is abandoned or fails, the worktree can be cleaned up without touching main

Worktree names match the task ID: `E01_S02_T01-jwt-middleware` — so you can always trace a worktree back to its task.

---

### What "Resuming" Looks Like

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

### The Practical Implication

The board is not optional overhead. It *is* the memory. If you skip updating it — working directly in the code without going through `/do` and the Tester — that context is lost at the next session boundary.

Use `/reconcile` if the board has drifted from actual git history. It cross-checks every task status against commits and corrects any discrepancies.

---

→ Back to [Intro Guide](./getting-started.md) | First how-to: [Your First Feature](#your-first-feature)

---

## Your First Feature


> **How-to:** Building a feature end-to-end — from idea to verified, committed code.

---

### The Pattern

```
/brainstorm → /todo → /do → /status
```

This is the core loop. Everything in Jenga AI flows through some version of it.

---

### Step 1: Shape the Work with `/brainstorm`

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

### Step 2: Add to the Board with `/todo`

Once the work is shaped:

```
/todo
"Add password reset flow" → links to E01_S05
```

The Scrum Master creates the story and tasks on the board, validates that acceptance criteria and DoD are present, and adds the task IDs to `project/todo.md`.

---

### Step 3: Execute with `/do`

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

### Step 4: Check Progress with `/status`

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

### When Things Go Wrong

**Task status: Failed**
The Tester writes a problem rapport. At the next session start, the Scrum Master reads it and creates a follow-up task. You then run `/do` on that task.

**Task status: Blocked**
The Developer couldn't resolve a conflict after three attempts. The task needs human intervention. Read the rapport in `project/rapports/problems/` — it will describe exactly what's blocking it.

**Task status: Rejected**
The Tester flagged something serious enough to reject the implementation outright. The Scrum Master will confirm with you before writing this status.

---

→ Back to [Intro Guide](./getting-started.md) | Next: [Working Across Sessions](#working-across-sessions)

---

## Working Across Sessions


> **How-to:** Picking up a project after a break — without losing momentum or context.

---

### The Problem This Solves

On a single-session project, context loss doesn't matter. On anything longer — a real feature, a multi-day sprint, a project you return to after a week — it does. Without structure, the start of every session is a re-orientation exercise.

With Jenga AI, the board, the event log, and the trigger queue hold the context. You just need to read them.

---

### Resuming a Session

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

### What the Scrum Master Does at Session Start

Before it responds to anything you say, the Scrum Master processes `project/queue/scrum_triggers.jsonl`. These triggers were written by `on_session_end.sh` at the end of the previous session.

Typical triggers and what they produce:

| Trigger | What the Scrum Master does |
|---|---|
| `status_review` | Scans the board for any stale statuses, surfaces a summary |
| `rapport_review` | Reads new problem rapports, creates fix tasks or marks stories Failed |
| `story_rollup` | Promotes story status to Passed if all tasks passed |

After processing, it clears the queue and reports to you: *"Processed 2 triggers: created T04 from rapport, story E01_S02 rolled up to Passed."*

---

### Keeping the Board Honest

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

### The Habit: Start and End Every Session Intentionally

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

### Long Breaks

If you haven't touched a project in weeks, the board is still there and accurate. `PROJECT_SUMMARY.md` holds the high-level context. Run `/status` for a full picture, then `/continue` to get moving again.

There's no re-onboarding ceremony. The system was designed for this.

---

→ Back to [Intro Guide](./getting-started.md) | Next: [Capturing Mid-Flow Ideas](#capturing-mid-flow-ideas)

---

## Capturing Mid-Flow Ideas


> **How-to:** Handling a new thought, tangent, or feature idea without derailing your current work.

---

### The Problem

You're three tasks into implementing a feature when a better idea surfaces — or a separate concern entirely. If you chase it, you lose the thread of your current work. If you ignore it, you lose the idea.

Jenga AI has two skills designed for exactly this tension: `/btw` and `/spinoff`.

---

### `/btw` — Capture and Continue

Use `/btw` when you have a new idea that's clearly related to your current epic or story but isn't what you're working on right now.

```
(You're implementing E01_S02 — Refresh Tokens)
/btw add a "remember me" checkbox to the login form
```

The Scrum Master:
1. Identifies which epic/story this belongs to (`E01_S03 — Login UI`)
2. Proposes: "Add as E01_S03_T04?"
3. You confirm — it's written to the board as Pending
4. Control returns to your current task

The idea is captured. Your current work is uninterrupted. Nothing is lost.

**`/btw` is for:** Small additions, clarifications, or enhancements that you can classify in 30 seconds and defer cleanly.

---

### `/spinoff` — Capture a Diverging Thread

Use `/spinoff` when the new topic is more substantial — it needs its own story or epic, or it requires prerequisite thinking before it can be properly sized.

```
(Mid-session on rate limiting)
You bring up caching strategy
/spinoff
```

The Scrum Master:
1. Confirms or asks you to describe the diverging topic
2. Summarises all context gathered so far in the conversation
3. Asks: *"Are the requirements clear enough to act on, or would you like to run `/brainstorm` first?"*
4. Saves a `/todo` entry with the full context summary
5. Returns focus to the primary thread

**`/spinoff` is for:** Topics that need their own planning, have prerequisites to flesh out, or would take more than a few minutes to properly size.

---

### The Divergence Detection Pattern

The Scrum Master is trained to detect when a conversation shifts subject. When it notices:

```
It looks like we're moving into a new topic. How would you like to handle it?
1. Capture the new topic as a /todo (I'll return to what we were working on)
2. Capture the current topic as a /todo (I'll continue with the new topic)
3. Capture both as /todo items (you choose which to continue first)
4. Ignore it — tell me which topic to continue with
```

This prompt appears automatically. You don't have to remember to use `/btw` or `/spinoff` — the Scrum Master will surface the choice for you.

---

### A Note on Context Preservation

Every `/todo` created through `/btw` or `/spinoff` includes:
- A one-sentence summary of the captured topic
- Key details and decisions already discussed
- Open questions or unknowns raised so far

This isn't just a title. It's everything the Developer and Tester will need when the task is eventually picked up — even if that's three weeks later.

---

### Choosing Between `/btw` and `/spinoff`

| Situation | Use |
|---|---|
| Quick addition to a known story | `/btw` |
| Needs its own story or epic | `/spinoff` |
| Unclear whether it belongs to current epic | `/spinoff` (Scrum Master will size it) |
| Already have full context, just need to defer | `/btw` |
| Needs `/brainstorm` before it can be sized | `/spinoff` |

When in doubt, `/spinoff` — it's the safer choice because it always preserves full context.

---

→ Back to [Intro Guide](./getting-started.md) | Next: [Parallel Tasks](#parallel-tasks)

---

## Parallel Tasks


> **How-to:** Running multiple tasks simultaneously with `/dooo` or automating board-wide parallel execution with `/jenga`.

---

### When Parallelism Applies

Most of the time, tasks in a story are sequential — Task 2 depends on Task 1, so you work through them in order. But often across *stories* or *epics*, tasks are genuinely independent: adding rate limiting has nothing to do with implementing the admin dashboard.

When tasks have no dependencies on each other, running them in parallel saves real time.

---

### `/dooo` — The Parallel Orchestrator

`/dooo` is the parallel version of `/do`. It:

1. Calls `/do` to start the first implementation in a background sub-agent
2. Returns to the board immediately and identifies other tasks that could run in parallel
3. Offers them to you in a loop — each confirmation starts another sub-agent
4. Monitors all running sub-agents until all complete

```
/dooo
→ Starting E01_S02_T02 (refresh tokens) as sub-agent...
→ Checking for parallelisable tasks...
→ E02_S01_T01 (rate limiting) has no dependencies on E01_S02_T02
→ Start E02_S01_T01 in parallel? [yes/no]
→ Yes
→ Starting E02_S01_T01 as sub-agent...
→ Both agents running. Monitoring...

(Later)
→ E01_S02_T02: Passed ✅
→ E02_S01_T01: Passed ✅
→ Board updated. Next tasks?
```

---

### `/jenga` — The Automated Board Orchestrator

`/jenga` is the board-wide alternative to approving each parallel batch yourself: bare `/jenga` or `/jenga <ids>` show a picker/scope plus a confirmation tree before anything executes, while `/jenga *` reproduces the original hands-free, zero-prompt run across the whole board. It uses the same background sub-agent mechanism as `/dooo`, but only after its earlier phases have decomposed epics into stories, decomposed stories into tasks, and queued the eligible work.

In **Phase 4**, `/jenga` executes by:

1. Resolving which queued tasks are eligible to run based on dependency state
2. Grouping independent tasks into a parallel batch
3. Launching each task in that batch as a background sub-agent simultaneously
4. Re-checking the board when tasks finish and repeating until no eligible items remain

```
/jenga
→ Phase 1: Decomposing epics into stories...
→ Phase 2: Decomposing stories into tasks...
→ Phase 3: Queueing eligible tasks into todo.md...
→ Phase 4: Launching E01_S02_T02 and E02_S01_T01 in parallel...
→ Waiting for sub-agents to report back...
→ Recomputing dependencies...
→ No more eligible tasks in this batch. Continuing until board is exhausted...
```

### `/dooo` vs `/jenga`

| Tool | Style | Scope | Prompts | Best when |
| --- | --- | --- | --- | --- |
| `/dooo` | Interactive parallel orchestration | A user-selected batch of independent tasks | Asks before starting each additional task | You want to inspect and approve each parallel batch |
| `/jenga` | Interactive-by-default orchestration (`*` = fully automated) | The whole board, across all eligible work | Picker + confirmation by default; zero prompts only under `/jenga *` | You want to scope/confirm a board-wide run, or go fully hands-free with `*` |

---

### What Makes a Task Parallelisable

Two tasks are safe to run in parallel if:

1. **They don't modify the same files** — overlapping edits cause merge conflicts
2. **Neither depends on the other's output** — if T02 imports something T01 creates, they're sequential
3. **They belong to different stories or epics** — within a single story, tasks often have implicit dependencies

The Scrum Master checks for these conditions before suggesting parallel execution. If it's uncertain, it will ask.

---

### After Parallel Execution: Reconcile

Running tasks in parallel creates multiple worktree branches that need to be merged. After a parallel session, always run:

```
/reconcile
→ Merges orphaned worktree branches
→ Cross-checks task statuses against git history
→ Cleans up todo.md
```

This ensures the board accurately reflects what happened across all the parallel sub-agents.

---

### A Note on Sub-Agent Sessions

Each sub-agent in `/dooo` is a separate Claude Code session. This means:

- Each has full access to the board and codebase
- Each creates its own worktree and commits independently
- Each calls the Tester independently when it finishes
- The Tester may be called multiple times in quick succession — this is expected

The board's file locking protocol ensures that concurrent writes don't corrupt status fields.

---

### When Not to Use `/dooo`

- When tasks are sequential (T02 needs T01's output)
- When the codebase is small and parallel overhead isn't worth it
- When you want to carefully review each task before starting the next
- When you're debugging — parallel noise makes it harder to isolate issues
- When you want to automate the entire board instead of approving each batch manually — use `/jenga`

For most day-to-day work, `/do` is the right tool. Reach for `/dooo` when you have a clear batch of independent tasks and want to move fast.

---

→ Back to [Intro Guide](./getting-started.md) | Full reference: [reference.md](./reference.md)

---

