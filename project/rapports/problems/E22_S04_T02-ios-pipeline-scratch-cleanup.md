# Rapport: iOS Pipeline Scratch Cleanup Remark

**Date:** 2026-07-11 (UTC)
**Agent:** Tester
**Related Epic:** E22 — /publish Skill — Deployment Pipeline Orchestrator
**Related Story:** E22_S04 — iOS App Store adapter v1
**Related Task:** E22_S04_T02 — Build, sign, and export steps — xcodebuild pipeline
**Type:** `test_failure`

---

## Sender
```json
{
  "sender": {
    "agent": "tester",
    "session_id": "tester-E22_S04-20260711T093013Z",
    "task_id": "E22_S04_T01",
    "story_id": "E22_S04",
    "epic_id": "E22",
    "date": "2026-07-11T09:31:26Z",
    "paths": [
      "cfb69e7",
      "ba8a5f8",
      "613a0c6"
    ],
    "worktree": "/Users/samwelmunga/Desktop/Projects/agents/.claude/worktrees/E22_S04-ios-adapter-v1"
  }
}
```

---

## Summary
Validation passed for the iOS adapter story, but the dry-run pipeline leaves generated ExportOptions scratch files under `.claude/publish-tmp/` after completion.

---

## Context
The tester ran config validation, env validation, shell syntax checks, and dry-run staging/production iOS pipeline executions for E22_S04. The pipeline correctly printed dry-run `xcodebuild` / `xcrun` commands and wrote uploaded state-machine entries.

---

## Problem Description
The execution plan says ExportOptions scratch files should be cleaned up after use, but `skills/publish/scripts/ios_pipeline.sh` creates `$REPO_ROOT/.claude/publish-tmp/<run-id>/ExportOptions.plist` and does not register a cleanup trap or remove the run directory at the end. The tester removed the scratch directories produced during validation, but future runs will recreate and retain them.

---

## Findings

| # | Finding | Severity | Notes |
|---|---------|----------|-------|
| 1 | `ios_pipeline.sh` leaves generated `.claude/publish-tmp/<run-id>/ExportOptions.plist` directories after successful dry-runs. | Low | Core AC/DoD passed; this is a cleanup/privacy hygiene remark rather than a deploy blocker. |

---

## Impact
The story is not blocked, but repeated dry-runs or real runs will accumulate repo-local scratch files that may contain signing metadata such as signing identity and provisioning profile UUID.

---

## Suggested Next Steps
Add an `EXIT` trap or explicit success/failure cleanup in `ios_pipeline.sh` to remove the run-specific scratch directory after the export step is no longer needed. Preserve cleanup after failure only if debugging artifacts are intentionally desired and documented.

---

## Ignore Log
_Only populated by the developer when this rapport is marked `.IGNORE.md`._

**Ignored by:** Developer
**Date:** YYYY-MM-DD (UTC)
**Reason:**

---

## Resolution Verification
**Verified by:** Tester  
**Date:** 2026-07-11T09:35:07Z  
**Result:** Resolved

Re-ran the targeted iOS adapter validation after commit `ad843ff`. The dry-run pipeline completed successfully, appended a valid `uploaded` state-machine entry to `project/logs/publish-history.json`, and left no run-specific `.claude/publish-tmp/<run-id>/` scratch directory behind.
