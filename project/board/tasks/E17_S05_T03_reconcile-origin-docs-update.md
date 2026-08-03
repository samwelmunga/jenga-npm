---
id: E17_S05_T03
story_id: E17_S05
epic_id: E17
title: Update README and WARP.md to document /reconcile-origin skill
status: Passed
date_created: 2026-07-18
date_started:
date_completed: 2026-07-18
assigned_to: developer
---

# Task: Update README and WARP.md to document /reconcile-origin skill

## Description
Update the project's user-facing documentation to include the new `/reconcile-origin` skill. This ensures users can discover the skill through the README and WARP.md reference.

## Implementation Details

### README.md
- Add `/reconcile-origin` to the skills table (or commands section) with a one-line description
- Entry format consistent with existing skill entries

### WARP.md
- Add a `/reconcile-origin` section documenting:
  - Purpose: sync local branch with origin via rebase
  - Usage: `/reconcile-origin` (current branch) and `/reconcile-origin <branch>` (named branch)
  - Conflict handling: structured rapport + "Handle it later" option
  - When to use it (long-running worktrees, cross-session drift)

## Acceptance Criteria
- [ ] `README.md` includes `/reconcile-origin` in the skills/commands listing
- [ ] `WARP.md` includes a `/reconcile-origin` section with purpose, usage, conflict handling, and when-to-use guidance
- [ ] Both files are consistent with the existing documentation style
