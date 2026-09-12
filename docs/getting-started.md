---
layout: page
title: Getting Started
permalink: /getting-started.html
---


> **You've run `/init`. Your project directory is scaffolded. Now what?**

This guide answers that question. It covers the philosophy behind Jenga AI, how to think about the system, and four concrete patterns you'll use constantly. It's written for someone at the beginning — not a reference document, but a walkthrough.

For the full command reference, see [reference.md](./reference.md).

---

## Table of Contents

1. [What You Have After `/init`](#1-what-you-have-after-init)
2. [The Three Pillars](#2-the-three-pillars)
   - [Role Separation](#role-separation)
   - [Board Hierarchy](#board-hierarchy)
   - [Session Continuity](#session-continuity)
3. [Your First 15 Minutes](#3-your-first-15-minutes)
   - [New Project](#new-project)
   - [Starting From an Existing Project](#starting-from-an-existing-project)
4. [Common Patterns](#4-common-patterns)
   - [Building a Feature End-to-End](#building-a-feature-end-to-end)
   - [Working Across Sessions](#working-across-sessions)
   - [Capturing Mid-Flow Ideas](#capturing-mid-flow-ideas)
   - [Running Tasks in Parallel](#running-tasks-in-parallel)
   - [Chaining Workflows with Playbooks](#chaining-workflows-with-playbooks)
   - [How Playbooks Know What a Skill Produces](#how-playbooks-know-what-a-skill-produces)
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

→ [Read more: Role Separation](./concepts.md#role-separation)

---

### Board Hierarchy

All work on the board follows three levels: **Epics → Stories → Tasks**.

- An **Epic** is a large goal: "Build the auth system"
- A **Story** is a complete outcome: "As a user, I want to log in with email/password"
- A **Task** is a technical unit: "Add JWT validation middleware"

Each level has mandatory fields — acceptance criteria, definition of done — written specifically so a Tester can verify them without asking questions. When all tasks in a story pass, the story rolls up automatically. When all stories in an epic pass, the epic rolls up.

The hierarchy isn't overhead. It's the structure that makes every session resumable.

→ [Read more: Board Hierarchy](./concepts.md#board-hierarchy)

---

### Session Continuity

Every AI agent session starts with a blank slate. Jenga AI solves this by storing all project context in files, not in the model's memory. The board, the event log, the trigger queue, and `PROJECT_SUMMARY.md` all persist across sessions.

When a session ends, `on_session_end.sh` writes triggers for the Scrum Master. When a new session starts, the Scrum Master processes those triggers before responding to you. It knows what was built, what passed, what failed, and what needs attention — without you saying a word.

→ [Read more: Session Continuity](./concepts.md#session-continuity)

---

## 3. Your First 15 Minutes

Here's how to go from an empty board to your first task executing. Where you start depends on what you're bringing to Jenga AI:

- **Nothing built yet** — follow [New Project](#new-project) below.
- **An existing codebase, with no board history** — skip to [Starting From an Existing Project](#starting-from-an-existing-project). You'll still end up with the same Epic → Story → Task board; the first step is investigation instead of planning from scratch.

### New Project

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

Two more ways to verify a fresh task actually did what it was supposed to:
- **See it running** — `/run` launches the app itself so you can exercise the new behavior directly, not just trust a green test result.
- **Something looks wrong** — `/error` is guided troubleshooting: it gathers what broke, what you expected, and where it happens, then turns that into a fix task instead of leaving you to debug from scratch.

---

That's the core loop. Everything else is a variation on it.

---

### Starting From an Existing Project

If you're adopting Jenga AI into a codebase that already exists — no board, no Epics, nothing tracked yet — don't start with `/brainstorm`. Start with `/uncharted`, which is built specifically for code with no board provenance.

**Step 1 — Onboard the whole codebase**

```
/uncharted onboard .
```

By default this is conversational: it discovers the project's subsystems and walks you through confirming what each one does, writing `[ARCH]`-tagged board items as you go. It never touches your application code — its entire output is board files, an analysis rapport, and (in conversational mode) knowledge-graph nodes. If you'd rather skip the back-and-forth and get an automated best-guess pass instead, use `/uncharted onboard . --legacy`.

**Step 2 — Or onboard just one part**, if you'd rather understand a single file or directory before committing to a whole-codebase pass:

```
/uncharted segment path/to/directory
```

**Step 3 — From here, you're on the New Project path.** Once the board reflects what already exists, add your next feature the same way a new project would — pick up at [Step 2](#new-project) above with `/todo`.

---

## 4. Common Patterns

---

### Building a Feature End-to-End

The full cycle from idea to tested, committed code:

```
/brainstorm → /todo → /do → /commit
```

Use `/brainstorm` before every non-trivial feature. It takes a few minutes and prevents scope creep, missing acceptance criteria, and mid-implementation surprises.

→ [Full walkthrough: Your First Feature](./concepts.md#your-first-feature)

---

### Working Across Sessions

Jenga AI is designed for multi-session projects. At the start of a session:

```
/continue   ← orient yourself and get a recommendation
/status     ← full board overview
/proceed    ← orient and immediately resume execution
```

Use `/reconcile` if the board has drifted from actual git history.

→ [Full walkthrough: Working Across Sessions](./concepts.md#working-across-sessions)

---

### Capturing Mid-Flow Ideas

When a new idea surfaces while you're working on something else:

- **`/btw`** — quick capture of a small addition to a known story, returns to current task immediately
- **`/spinoff`** — deeper capture of a diverging topic, preserves full context, optionally runs `/brainstorm` before deferring

The Scrum Master also detects topic divergence automatically and will prompt you to choose how to handle it.

→ [Full walkthrough: Capturing Mid-Flow Ideas](./concepts.md#capturing-mid-flow-ideas)

---

### Running Tasks in Parallel

When multiple tasks are independent of each other:

```
/dooo
```

This orchestrates parallel sub-agents, each running a separate task simultaneously. After parallel execution, run `/reconcile` to sync the board with what actually happened.

→ [Full walkthrough: Parallel Tasks](./concepts.md#parallel-tasks)

---

### Chaining Workflows with Playbooks

Some workflows are always the same sequence of skills — plan it, build it, commit it. A **playbook** is a named, pre-defined chain of skills you can invoke as one unit instead of typing each skill separately.

Playbooks surface two ways:

- **Describe what you want, in plain language, to `/jenga`.** If your request spans more than one skill and matches a playbook, `/jenga` proposes the whole chain — a numbered, editable list — before running anything.
- **Name a playbook directly**, once you know which one you want:
  ```
  /playbook idea-to-committed
  ```

Either way, nothing executes until you confirm the chain, and you can uncheck individual steps before accepting.

**A basic example.** `idea-to-committed` chains exactly the core loop from [Your First 15 Minutes](#3-your-first-15-minutes) into a single call:

```
/playbook idea-to-committed
```

resolves to:

```
/brainstorm → /todo → /do → /commit
```

— planning, board capture, implementation, and a commit, run as one confirmed sequence. Two related playbooks build on the same idea: `brainstorm-to-mirror` extends it through `/dev-done` and `/mirror-public` for a full public release, and `understand-then-ship` prepends `/uncharted` investigation before running the same pipeline — useful when the feature touches code you don't fully understand yet.

---

### How Playbooks Know What a Skill Produces

A playbook step can name an earlier step as its `forward_from` source, so its output feeds directly into the next step's input. For that to work safely, something needs to know what *shape* of value each step actually produces — a plain string, a list of board IDs, a list of files — before the chain runs, not partway through it.

That's what a skill's **output type** declares. The vocabulary is small and fixed:

- **`text`** — a plain string
- **`id_list`** — a list of board IDs
- **`file_list`** — a list of file paths

**Adoption is partial by design.** Most skills don't declare an output type, and that's expected — it doesn't mean the skill is broken or unfinished. Only a skill that declares one can be named as a `forward_from` source in a playbook step; skills with no declared type simply aren't eligible for that role.

This section explains the concept once. For which specific skills declare an output type today, see the **Skills** section of the [full reference](./documentation.md#skills) — each skill's entry there shows its Output type, or `any` if it doesn't declare one.

---

## 5. Where to Go Next

**Full reference:** [reference.md](./reference.md) — every skill, every agent, MCP tools, hooks, and the inter-agent communication contract.

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
| Bring an existing codebase onto the board | `/uncharted` |
| Run a pre-defined multi-skill chain | `/jenga` (plain language) or `/playbook <id>` |

**When something breaks:** `/error` — guided troubleshooting that gathers context, diagnoses the issue, and creates a fix task.

**When you're not sure which skill to use:** `/route` — describe what you want to do in plain language, and it will find the right skill.
