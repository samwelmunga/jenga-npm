# Role Separation

> **Concept:** Why Jenga AI uses three distinct agents instead of one.

---

## The Problem with One Agent Doing Everything

When a single AI writes code *and* verifies it in the same context, you get **self-affirming feedback loops**. The model that wrote the code is the same model evaluating whether it's correct — which means it carries all the same assumptions, gaps, and blind spots into the review. It will tend to confirm what it just wrote.

This isn't hypothetical. Ask any AI to "write a function and test it" in one shot and it will produce tests that test the function it wrote, not the function the *spec* required.

---

## How Jenga AI Separates Roles

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

## Why Exclusive Ownership Matters

Each agent having exclusive write access to specific files prevents:
- **Race conditions** — two agents updating the same file simultaneously
- **Status drift** — the Developer marking its own work as passed
- **Context pollution** — the Tester carrying implementation assumptions into the review

The **file locking protocol** (`.lock` files adjacent to board items) enforces this mechanically. If you see a `.lock` file, an agent is currently writing to that item — no other agent may write until the lock is released.

---

## The Practical Implication for You

You don't instruct the Developer to test, and you don't ask the Tester to fix code. The workflow enforces this for you. If something breaks in a test, the Tester writes a rapport to `project/rapports/problems/` — the Developer picks that up in the next cycle.

This separation is what makes Jenga AI's results trustworthy across sessions: the Tester's verdict is independent.

---

→ Back to [Intro Guide](../intro-guide.md) | Next concept: [Board Hierarchy](./board-hierarchy.md)
