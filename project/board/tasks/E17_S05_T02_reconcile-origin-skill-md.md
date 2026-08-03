---
id: E17_S05_T02
story_id: E17_S05
epic_id: E17
title: SKILL.md — /reconcile-origin skill definition with frontmatter and agent instructions
status: Passed
date_created: 2026-07-18
date_started:
date_completed: 2026-07-18
assigned_to: developer
---

# Task: SKILL.md — /reconcile-origin skill definition with frontmatter and agent instructions

## Description
Create `.agents/skills/reconcile-origin/SKILL.md` — the skill file that wires up the `/reconcile-origin` command. Per the project's Skill Implementation Principle, this file must **not** re-implement git logic inline; it instructs the agent to invoke `scripts/reconcile-origin.sh` and interpret its structured JSON output.

## Implementation Details

### YAML frontmatter (required fields)
```yaml
---
name: reconcile-origin
description: Sync the current (or specified) branch with origin by rebasing local commits on top of the latest upstream state.
keywords:
  - "sync branch"
  - "rebase origin"
  - "reconcile origin"
  - "pull rebase"
examples:
  - "sync my branch with origin"
  - "rebase local commits on top of origin"
  - "reconcile-origin feature/my-branch"
---
```

### Agent instructions (body of SKILL.md)
The skill body must cover:

1. **Determine branch** — no argument → use current branch; branch argument → use that branch
2. **Invoke the script** — run `.agents/skills/reconcile-origin/scripts/reconcile-origin.sh [<branch>]` and capture stdout
3. **Parse JSON output**:
   - `status == "ok"` → report success to user: branch name, number of rebased commits
   - `status == "conflict"` → present each conflict as a structured rapport to the user:
     - File path and nature of the conflict
     - Local section vs origin section
     - At least 2 recommended resolution options (how to preserve both sides)
     - "Handle it later" as the final option — if selected, call the script with `--handle-later <file>`
4. **Guard rails**:
   - If `git status` shows uncommitted changes, warn the user and ask whether to stash first
   - If the specified branch does not exist locally, offer to create it tracking `origin/<branch>`

## Acceptance Criteria
- [ ] File exists at `.agents/skills/reconcile-origin/SKILL.md`
- [ ] YAML frontmatter includes `name`, `description`, `keywords`, and `examples`
- [ ] Skill body delegates all git operations to `scripts/reconcile-origin.sh` — no inline git commands in the instruction prose
- [ ] Success path: reports branch name and rebased commit count
- [ ] Conflict path: presents structured rapport with ≥2 resolution options + "Handle it later"
- [ ] "Handle it later" option invokes `reconcile-origin.sh --handle-later <file>`
- [ ] Uncommitted-changes guard is documented in the instructions
