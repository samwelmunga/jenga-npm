---
id: E17_S05
epic_id: E17
title: /reconcile-origin Skill — Sync Local Branch with Origin
status: Passed
date_created: 2026-07-18
date_started:
date_completed: 2026-07-18
tasks:
  - E17_S05_T01
  - E17_S05_T02
  - E17_S05_T03
---

# Story: /reconcile-origin Skill — Sync Local Branch with Origin

As a developer, I want a `/reconcile-origin` skill that pulls the latest version of a branch from origin and replays my local changes on top — so that my work is always based on the most recent upstream state without losing any local commits.

## Background
When working in long-running worktrees or across sessions, local branches can drift behind origin. The `/reconcile-origin` skill automates the sync: fetch the target branch from origin, rebase local commits on top, and where conflicts arise, report them clearly with recommended resolution paths. The user retains the option to defer conflict resolution, which leaves the conflict in place with an explanatory comment.

Usage:
- `/reconcile-origin` — syncs the current branch with its origin counterpart
- `/reconcile-origin feature/my-branch` — syncs the specified branch

## Implementation Notes
Per the project's **Skill Implementation Principle**, the git operations (fetch, rebase, conflict detection, comment injection) must be implemented as a shell script at `.agents/skills/reconcile-origin/scripts/reconcile-origin.sh`. `SKILL.md` instructs the agent to invoke the script and interpret its structured output — it does not re-implement the git logic inline.

## Acceptance Criteria
- [ ] Skill file created at `.agents/skills/reconcile-origin/SKILL.md` with correct YAML frontmatter
- [ ] Running `/reconcile-origin` with no argument syncs the current branch against `origin/<current-branch>`
- [ ] Running `/reconcile-origin <branch>` checks out the specified branch and syncs it against `origin/<branch>`
- [ ] The sync strategy preserves origin's commit history and replays local commits on top (rebase, not merge)
- [ ] Git commit history (including SHA references) is retained — no squashing or force-rewrites that would alter shared history
- [ ] When a conflict is detected, a structured conflict rapport is presented to the user with:
    - A description of the conflict (file, lines, nature of the incompatibility)
    - An explanation of why the changes are incompatible
    - Recommended actions to preserve both sides (at least 2 specific options)
    - "Handle it later" always as the final option — leaves the conflict markers in place, prepends a `# RECONCILE-ORIGIN CONFLICT:` comment block above the conflicting lines describing the issue
- [ ] No data loss — local changes are never silently discarded

## Definition of Done
- [x] Skill file exists and is correctly formatted
- [x] Skill handles no-argument and branch-argument invocations
- [x] Rebase-based sync implemented (origin-first, local on top)
- [x] Conflict detection, rapport, and "Handle later" comment injection all work
- [x] README or WARP.md updated to document the new skill
