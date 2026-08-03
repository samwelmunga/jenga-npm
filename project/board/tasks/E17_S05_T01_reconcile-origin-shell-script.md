---
id: E17_S05_T01
story_id: E17_S05
epic_id: E17
title: reconcile-origin.sh — fetch, rebase, conflict detection & "Handle later" injection
status: Passed
date_created: 2026-07-18
date_started:
date_completed: 2026-07-18
assigned_to: developer
---

# Task: reconcile-origin.sh — fetch, rebase, conflict detection & "Handle later" injection

## Description
Create `.agents/skills/reconcile-origin/scripts/reconcile-origin.sh` — the shell script that performs all git operations for the `/reconcile-origin` skill. The `SKILL.md` will delegate all git logic to this script and interpret its structured output.

**Invocation contract:**
```
reconcile-origin.sh [<branch>]
```
- No argument: syncs the current branch against `origin/<current-branch>`
- `<branch>` argument: checks out the specified branch and syncs it against `origin/<branch>`

## Implementation Details

### Happy path
1. Determine the target branch (argument or current branch via `git branch --show-current`)
2. `git fetch origin <branch>` to update remote refs
3. `git rebase origin/<branch>` to replay local commits on top of the updated origin tip
4. On success: print a structured JSON summary `{"status":"ok","branch":"<branch>","rebased_commits":<n>}`

### Conflict path
When `git rebase` exits with a conflict:
1. Collect conflict details per file: file path, conflicting sections (use `git diff --name-only --diff-filter=U`)
2. For each conflicting file, extract the `<<<<<<< HEAD`, `=======`, `>>>>>>> origin/...` sections
3. Print a structured JSON conflict report:
```json
{
  "status": "conflict",
  "branch": "<branch>",
  "conflicts": [
    {
      "file": "<path>",
      "local_section": "<text>",
      "origin_section": "<text>",
      "description": "<short description of incompatibility>"
    }
  ]
}
```
4. Abort the rebase (`git rebase --abort`) to restore a clean state — **do not leave the repo in a mid-rebase state**

### "Handle later" mode
The script accepts a `--handle-later <file>` flag (called after the agent presents options and user selects "Handle later"). When passed:
1. Re-run the rebase up to the same conflict point
2. For the specified file, prepend a `# RECONCILE-ORIGIN CONFLICT:` comment block above the conflict markers describing the incompatibility
3. Stage the annotated file and continue the rebase (`git add <file> && git rebase --continue`)
4. Repeat for remaining conflicts in the file
5. Output `{"status":"handled_later","file":"<path>"}`

## Acceptance Criteria
- [ ] Script exists at `.agents/skills/reconcile-origin/scripts/reconcile-origin.sh` and is executable (`chmod +x`)
- [ ] No-argument invocation uses the current branch
- [ ] Branch-argument invocation checks out and syncs the specified branch
- [ ] Rebase (not merge) strategy — origin-first, local on top
- [ ] On success: JSON `{"status":"ok",...}` printed to stdout
- [ ] On conflict: rebase is aborted, JSON conflict report printed to stdout
- [ ] `--handle-later <file>` flag injects `# RECONCILE-ORIGIN CONFLICT:` comment block and resumes rebase
- [ ] No local commits are silently discarded under any path
