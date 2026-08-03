# Rapport: reconcile-origin skill inline git status check

**Date:** 2026-07-18 (UTC+02)
**Agent:** Tester
**Related Epic:** E17
**Related Story:** E17_S05
**Related Task:** E17_S05_T02
**Type:** `test_failure`

---

## Sender
```json
{
  "sender": {
    "agent": "tester",
    "session_id": "tester-E17_S05-20260718T180443+0200",
    "task_id": "E17_S05_T02",
    "story_id": "E17_S05",
    "epic_id": "E17",
    "date": "2026-07-18T18:04:43.434+02:00",
    "paths": [
      "675c411",
      "9141072",
      "867b13f",
      "737b3ae"
    ],
    "worktree": "/Users/samwelmunga/Desktop/Projects/agents"
  }
}
```

---

## Summary
`/reconcile-origin` still includes an inline git command in `SKILL.md`, so T02 does not satisfy the “all git operations delegated to the script” acceptance criterion.

## Finding
- `SKILL.md` instructs the agent to run `git status --porcelain` directly before invoking `.agents/skills/reconcile-origin/scripts/reconcile-origin.sh`.
- T02 explicitly requires the skill body to delegate git operations to `scripts/reconcile-origin.sh` with no inline git commands.

## Impact
T02 cannot be marked passed. Story rollup to `Passed` was not performed.

## Suggested Next Step
1. Move the clean-worktree check fully behind `reconcile-origin.sh` and update `SKILL.md` to describe the script-mediated guard instead of instructing an inline `git status --porcelain` call.
