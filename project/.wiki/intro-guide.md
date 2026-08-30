# Jenga AI — Intro Guide

> **You've run `/init`. Your project directory is scaffolded. Now what?**

This guide answers that question. It covers the philosophy behind Jenga AI, how to think about the system, and four concrete patterns you'll use constantly. It's written for someone at the beginning — not a reference document, but a walkthrough.

For the full command reference, see [documentation.md](./documentation.md).

---

## Table of Contents

1. [What You Have After `/init`](#1-what-you-have-after-init)
2. [The Three Pillars](#2-the-three-pillars)
   - [Role Separation](#role-separation)
   - [Board Hierarchy](#board-hierarchy)
   - [Session Continuity](#session-continuity)
3. [Your First 15 Minutes](#3-your-first-15-minutes)
4. [Common Patterns](#4-common-patterns)
   - [Building a Feature End-to-End](#building-a-feature-end-to-end)
   - [Working Across Sessions](#working-across-sessions)
   - [Capturing Mid-Flow Ideas](#capturing-mid-flow-ideas)
   - [Running Tasks in Parallel](#running-tasks-in-parallel)
5. [Where to Go Next](#5-where-to-go-next)

---

## 1. What You Have After `/init`

Running `/init` creates the skeleton of a live project:

```
project/
├── board/
│   ├── epics/       ← where Epics will live
│   ├── stories/     ← where Stories will live
│   └── tasks/       ← where Tasks will live
├── configs/
│   └── workflow.json
├── queue/           ← trigger queue for inter-session handoffs
├── logs/
│   └── events.json  ← append-only event log
├── rapports/        ← problem and analysis reports
├── documentation/
└── PROJECT_SUMMARY.md   ← owned by the Scrum Master
```

The board is empty. The `PROJECT_SUMMARY.md` is a stub. No agents have been invoked yet.

This is intentional. Jenga AI doesn't make assumptions about what you're building — you define that next.

---

## 2. The Three Pillars

Before using Jenga AI effectively, it helps to understand why it works the way it does. There are three core ideas.

---

### Role Separation

Jenga AI uses three agents — **Scrum Master**, **Developer**, and **Tester** — each with a non-overlapping role and exclusive write access to specific files.

The most important constraint: **the Developer never tests its own work, and the Tester never writes implementation code.** This is what makes the system's results trustworthy. An AI that writes code and verifies it in the same context tends to confirm what it just wrote — not what the spec required.

The Scrum Master is your planning partner. The Developer is your implementer. The Tester is your independent validator. You don't need to coordinate between them — they communicate through typed sender objects and a shared board.

→ [Read more: Role Separation](./concepts/role-separation.md)

---

### Board Hierarchy

All work on the board follows three levels: **Epics → Stories → Tasks**.

- An **Epic** is a large goal: "Build the auth system"
- A **Story** is a complete outcome: "As a user, I want to log in with email/password"
- A **Task** is a technical unit: "Add JWT validation middleware"

Each level has mandatory fields — acceptance criteria, definition of done — written specifically so a Tester can verify them without asking questions. When all tasks in a story pass, the story rolls up automatically. When all stories in an epic pass, the epic rolls up.

The hierarchy isn't overhead. It's the structure that makes every session resumable.

→ [Read more: Board Hierarchy](./concepts/board-hierarchy.md)

---

### Session Continuity

Every AI agent session starts with a blank slate. Jenga AI solves this by storing all project context in files, not in the model's memory. The board, the event log, the trigger queue, and `PROJECT_SUMMARY.md` all persist across sessions.

When a session ends, `on_session_end.sh` writes triggers for the Scrum Master. When a new session starts, the Scrum Master processes those triggers before responding to you. It knows what was built, what passed, what failed, and what needs attention — without you saying a word.

→ [Read more: Session Continuity](./concepts/session-continuity.md)

---

## 3. Your First 15 Minutes

Here's how to go from an empty board to your first task executing.

**Step 1 — Define your project (2–5 min)**

```
/brainstorm
"I'm building a habit tracker with a social feed and analytics"
```

The Scrum Master will ask focused questions to shape your goals into Epics. Once you agree on the structure, it writes to `PROJECT_SUMMARY.md` and creates the epic files on the board.

Alternatively, if you already know your epics:
```
/pi-plan
```
This skips the dialogue and lets you define epics directly.

---

**Step 2 — Add your first feature to the board (3–5 min)**

```
/todo
"Add user registration with email/password"
```

The Scrum Master creates a Story under the appropriate Epic, decomposes it into Tasks, validates that acceptance criteria are present, and adds the task IDs to `project/todo.md`.

---

**Step 3 — Execute**

```
/do
```

Select a task. The Developer agent takes over: creates a worktree, writes a plan, implements, commits, and hands off to the Tester. The Tester runs the tests and updates the board. You watch it happen.

---

**Step 4 — Check the result**

```
/status
```

See what passed, what's pending, and what (if anything) needs attention. If a task failed, the Tester will have written a rapport explaining why — the Scrum Master will surface it next session.

---

That's the core loop. Everything else is a variation on it.

---

## 4. Common Patterns

---

### Building a Feature End-to-End

The full cycle from idea to tested, committed code:

```
/brainstorm → /todo → /do → /status
```

Use `/brainstorm` before every non-trivial feature. It takes a few minutes and prevents scope creep, missing acceptance criteria, and mid-implementation surprises.

→ [Full walkthrough: Your First Feature](./concepts/first-feature.md)

---

### Working Across Sessions

Jenga AI is designed for multi-session projects. At the start of a session:

```
/continue   ← orient yourself and get a recommendation
/status     ← full board overview
/proceed    ← orient and immediately resume execution
```

Use `/reconcile` if the board has drifted from actual git history.

→ [Full walkthrough: Working Across Sessions](./concepts/multi-session-work.md)

---

### Capturing Mid-Flow Ideas

When a new idea surfaces while you're working on something else:

- **`/btw`** — quick capture of a small addition to a known story, returns to current task immediately
- **`/spinoff`** — deeper capture of a diverging topic, preserves full context, optionally runs `/brainstorm` before deferring

The Scrum Master also detects topic divergence automatically and will prompt you to choose how to handle it.

→ [Full walkthrough: Capturing Mid-Flow Ideas](./concepts/mid-flow-capture.md)

---

### Running Tasks in Parallel

When multiple tasks are independent of each other:

```
/dooo
```

This orchestrates parallel sub-agents, each running a separate task simultaneously. After parallel execution, run `/reconcile` to sync the board with what actually happened.

→ [Full walkthrough: Parallel Tasks](./concepts/parallel-tasks.md)

---

## 5. Where to Go Next

**Full reference:** [documentation.md](./documentation.md) — every skill, every agent, MCP tools, hooks, and the inter-agent communication contract.

**Key skills to know early:**

| You want to… | Use |
|---|---|
| Plan a feature before building it | `/brainstorm` or `/deep-dive` |
| Add work to the board | `/todo` or `/btw` |
| Start implementing | `/do` or `/dooo` |
| Check progress | `/status` or `/continue` |
| Rework something | `/redo` |
| Sync documentation with code | `/doc-sync` |
| Clean up a messy board | `/reconcile` |
| Propagate workflow changes | `/distribute` |

**When something breaks:** `/error` — guided troubleshooting that gathers context, diagnoses the issue, and creates a fix task.

**When you're not sure which skill to use:** `/route` — describe what you want to do in plain language, and it will find the right skill.
