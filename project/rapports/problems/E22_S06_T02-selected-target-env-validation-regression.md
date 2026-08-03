# Rapport: selected-target env validation regression

**Date:** 2026-07-11 (UTC)
**Agent:** Tester
**Related Epic:** E22 /publish Skill — Deployment Pipeline Orchestrator
**Related Story:** E22_S06 Full deploy orchestration & ownership matrix
**Related Task:** E22_S06_T02 Post-deploy steps, ledger write, dry-run mode, and non-interactive path
**Type:** `test_failure`

---

## Sender
```json
{
  "sender": {
    "agent": "tester",
    "session_id": "",
    "task_id": "E22_S06_T01",
    "story_id": "E22_S06",
    "epic_id": "E22",
    "date": "2026-07-11T10:26:35Z",
    "paths": [
      "f696287",
      "e72d659"
    ],
    "worktree": "/Users/samwelmunga/Desktop/Projects/agents/.claude/worktrees/E22_S06-full-deploy-orchestration"
  }
}
```

---

## Summary
The deploy flow validates the selected target's env vars in step 3, but `ios_pipeline.sh` re-validates **all** mobile-iOS targets and fails on unrelated targets.

---

## Context
Tester ran a dry-run deploy for `staging-appstore` using a config where the selected target had all required env vars, while a second target intentionally referenced different unset env vars.

---

## Problem Description
`publish_deploy.sh` correctly calls `validate_ios_env.sh <config> <target>` before the adapter step. However, `ios_pipeline.sh` later calls `validate_ios_env.sh <config>` without passing the selected target, which expands validation to every mobile-iOS target in the file.

Observed output excerpt:
```text
Missing required iOS environment variables: ALT_APP_STORE_CONNECT_API_KEY_ID ALT_APP_STORE_CONNECT_ISSUER_ID ALT_APP_STORE_CONNECT_PRIVATE_KEY_PATH ALT_CODE_SIGN_IDENTITY ALT_PROVISIONING_PROFILE_UUID
```

Expected behavior from the story/task AC: deploy should validate and execute against the selected target only.

---

## Findings
| # | Finding | Severity | Notes |
|---|---------|----------|-------|
| 1 | Selected-target deploy fails because a different target is missing env vars | High | Breaks T02/T06 flow correctness for multi-target configs. |

---

## Impact
T02 cannot be marked passed. A valid selected target can still fail at step 9, which makes the non-interactive deploy path unreliable for real multi-target configs.

---

## Suggested Next Steps
1. Change `ios_pipeline.sh` to call `validate_ios_env.sh "$PUBLISH_JSON" "$TARGET_NAME"`.
2. Add a regression test with at least two targets and disjoint env-var references.
