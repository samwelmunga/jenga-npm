# E17_S05_T01 — Execution Plan

## Task
Create `.agents/skills/reconcile-origin/scripts/reconcile-origin.sh` to fetch origin, rebase local commits, emit structured JSON, abort cleanly on conflicts, and support a handle-later flow.

## Implementation Approach
1. Create the skill script with strict bash settings and argument parsing for branch selection, `--handle-later`, and tracking-branch creation support.
2. Implement preflight checks for git repository state, uncommitted changes, local/remote branch existence, and local commit counting.
3. Use `git fetch` + `git rebase origin/<branch>` for the main flow and emit JSON success output.
4. On rebase conflict, parse unmerged files and conflict-marker sections with Python, print structured JSON, then abort the rebase.
5. Implement a handle-later mode that replays the rebase to the conflict, injects `# RECONCILE-ORIGIN CONFLICT:` notes above conflict markers for the selected file, stages it, and continues until that file is cleared or another conflict blocks progress.

## Files to Change
| File | Planned Change |
|------|----------------|
| `.agents/skills/reconcile-origin/scripts/reconcile-origin.sh` | New executable script implementing all git operations |

## Dependencies & Risks
- Depends on `git` and `python3` being available in the runtime.
- Handle-later markers use `#` comments exactly as required, even in non-shell file types.
- Rebase continuation after annotating one file may still stop on other files; the script should surface that cleanly.

## Notes
No tests will be run in this session per Developer Agent rules.
