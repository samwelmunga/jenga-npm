# Summary: E03_S03 — Jenga Empty-Board Fallback to /do

## What Changed

**`skills/jenga/SKILL.md`**

- **Step 6 (Exit condition)** was updated from an immediate exit to a two-phase check:
  1. When the eligible task list is empty, `/jenga` now invokes `/do` (without a specific task ID) to find stories not yet broken down into tasks.
  2. Only if `/do` also returns no eligible work does the skill output the completion message and exit.

- **"No eligible tasks at start" edge case** updated to reflect the new fallback: the skill no longer exits immediately but first delegates to `/do`.

- **New "Empty todo list" edge case** added: explicitly documents that an empty or actionless `project/todo.md` triggers the `/do` fallback rather than a silent exit.

## Why

The `/jenga` orchestrator is designed to run hands-free until all work is complete. Previously, if `project/todo.md` was empty (e.g., stories existed on the board but hadn't been decomposed into tasks), the skill would halt silently — missing work that `/do` could surface. The fallback ensures the orchestrator exhausts all possible sources of work before declaring completion.
