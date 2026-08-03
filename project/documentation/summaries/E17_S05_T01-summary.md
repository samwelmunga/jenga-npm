# E17_S05_T01 — Execution Summary

## What was done
Implemented `.agents/skills/reconcile-origin/scripts/reconcile-origin.sh` as the single entry point for reconcile-origin git operations.

## Delivered behaviour
- Determines the target branch from an argument or the current branch
- Fetches `origin/<branch>` and rebases local commits on top of it
- Emits JSON for success, conflicts, missing local branches, and operational errors
- Detects conflict files and extracts local vs origin sections into a structured report
- Aborts the rebase automatically after conflict reporting so the repository is not left mid-rebase
- Supports `--handle-later <file>` by annotating conflict markers with a `# RECONCILE-ORIGIN CONFLICT:` block and continuing the rebase
- Supports `--create-tracking` so the skill can create a missing local tracking branch without inline git logic

## Validation
- `bash -n .agents/skills/reconcile-origin/scripts/reconcile-origin.sh`
- Manual smoke verification in a disposable repo fixture covering:
  - happy-path reconcile
  - missing local branch detection
  - tracking-branch creation
  - conflict JSON reporting
  - handle-later annotation flow

## Commit
- `675c411` — `task(E17_S05_T01): add reconcile-origin shell script`
