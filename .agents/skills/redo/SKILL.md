---
name: redo
description: Redo parts or entire previous implementations identified by a commit SHA or an Epic/Story number (e.g. E01, E02_S03). Expects an identifier and a description of what to redo and why. Use when the user wants to revisit, rework, or rewrite previously completed work, including updating all affected documentation.
keywords:
  - redo
  - rework
  - rewrite
  - revisit
  - redo task
examples:
  - "redo the login implementation"
  - "rewrite story E02_S01"
metadata: 
  prefered_agent: scrum-master
---

# Redo — Rework a Previous Implementation

## Input Format

```
/redo <identifier> <description>
```

- **identifier** — One of:
  - A git commit SHA (full or short, e.g. `a1b2c3f`)
  - An Epic number (e.g. `E01`)
  - A Story number (e.g. `E02_S03`)
- **description** — What should be redone and, if relevant, why, how, or to what end.

If either part is missing, ask the user to provide it before proceeding.

## Instructions

### 1. Resolve the identifier
**Commit SHA:**
- Run `git --no-pager log --stat -1 <SHA>` to retrieve the commit message and changed files.
- Run `git --no-pager show <SHA>` to inspect the full diff.

**Epic / Story number:**
- Read the matching file under `$(bash scripts/board_resolver.sh)epics/` or `$(bash scripts/board_resolver.sh)stories/` to understand the scope.
- Use `git --no-pager log --all --oneline --grep="<epic or story title>"` to locate related commits and their diffs.

Collect the list of **files originally changed** and the **original intent** of the implementation.

### 2. Assess scope
Compare the user's redo description against the original implementation to determine:
- Which files need to change.
- Whether the redo is a partial revision (some files/logic) or a full rewrite.
- Which tests cover the affected code.
- Which documentation files reference the affected code or feature (check `project/`, `documentation/`, `project/documentation/`, `README.md`, `WARP.md`).

Summarise scope findings to the user in a brief list before continuing.

### 3. Plan the redo
Populate `skills/todo/assets/todo_handoff_template.md` with the following pre-collected context:
- **Mission title**: a short name for the redo work
- **Goal / objective**: the redo objective — what is changing and the desired outcome
- **Affected files or scope**: code, tests, and documentation files identified in step 2
- **Intended approach**: step-by-step changes
- **Epic/Story linkage**: the identifier resolved in step 1 (e.g. `E02_S03`), or `None` if a commit SHA

Then invoke the `/todo` skill with the populated template. Since the template fields are pre-filled, `/todo` should skip any questions already answered.

Wait for user approval before executing unless the user explicitly told you to go ahead.

## Examples
- `/redo a1b2c3f Rewrite the auth middleware to use JWT instead of session tokens`
- `/redo E02_S03 Replace the REST endpoints with GraphQL — the client team needs a flexible query interface`
- `/redo E01 Redo the entire onboarding epic using the new design-system components`
