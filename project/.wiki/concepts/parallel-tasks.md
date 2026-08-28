# Parallel Tasks

> **How-to:** Running multiple tasks simultaneously with `/dooo` or automating board-wide parallel execution with `/jenga`.

---

## When Parallelism Applies

Most of the time, tasks in a story are sequential — Task 2 depends on Task 1, so you work through them in order. But often across *stories* or *epics*, tasks are genuinely independent: adding rate limiting has nothing to do with implementing the admin dashboard.

When tasks have no dependencies on each other, running them in parallel saves real time.

---

## `/dooo` — The Parallel Orchestrator

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

## `/jenga` — The Automated Board Orchestrator

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

## `/dooo` vs `/jenga`

| Tool | Style | Scope | Prompts | Best when |
| --- | --- | --- | --- | --- |
| `/dooo` | Interactive parallel orchestration | A user-selected batch of independent tasks | Asks before starting each additional task | You want to inspect and approve each parallel batch |
| `/jenga` | Interactive-by-default orchestration (`*` = fully automated) | The whole board, across all eligible work | Picker + confirmation by default; zero prompts only under `/jenga *` | You want to scope/confirm a board-wide run, or go fully hands-free with `*` |

---

## What Makes a Task Parallelisable

Two tasks are safe to run in parallel if:

1. **They don't modify the same files** — overlapping edits cause merge conflicts
2. **Neither depends on the other's output** — if T02 imports something T01 creates, they're sequential
3. **They belong to different stories or epics** — within a single story, tasks often have implicit dependencies

The Scrum Master checks for these conditions before suggesting parallel execution. If it's uncertain, it will ask.

---

## After Parallel Execution: Reconcile

Running tasks in parallel creates multiple worktree branches that need to be merged. After a parallel session, always run:

```
/reconcile
→ Merges orphaned worktree branches
→ Cross-checks task statuses against git history
→ Cleans up todo.md
```

This ensures the board accurately reflects what happened across all the parallel sub-agents.

---

## A Note on Sub-Agent Sessions

Each sub-agent in `/dooo` is a separate Claude Code session. This means:

- Each has full access to the board and codebase
- Each creates its own worktree and commits independently
- Each calls the Tester independently when it finishes
- The Tester may be called multiple times in quick succession — this is expected

The board's file locking protocol ensures that concurrent writes don't corrupt status fields.

---

## When Not to Use `/dooo`

- When tasks are sequential (T02 needs T01's output)
- When the codebase is small and parallel overhead isn't worth it
- When you want to carefully review each task before starting the next
- When you're debugging — parallel noise makes it harder to isolate issues
- When you want to automate the entire board instead of approving each batch manually — use `/jenga`

For most day-to-day work, `/do` is the right tool. Reach for `/dooo` when you have a clear batch of independent tasks and want to move fast.

---

→ Back to [Intro Guide](../intro-guide.md) | Full reference: [documentation.md](../documentation.md)
