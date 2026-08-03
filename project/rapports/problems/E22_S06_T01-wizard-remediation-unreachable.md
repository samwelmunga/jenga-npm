# Rapport: publish deploy wizard remediation unreachable

**Date:** 2026-07-11 (UTC)
**Agent:** Tester
**Related Epic:** E22 /publish Skill — Deployment Pipeline Orchestrator
**Related Story:** E22_S06 Full deploy orchestration & ownership matrix
**Related Task:** E22_S06_T01 publish_deploy.sh — full end-to-end deploy orchestrator (steps 1–8)
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
Interactive remediation for an incomplete target config cannot run because `publish_deploy.sh` validates the whole config file before it reaches `check_target_config.sh`.

---

## Context
Tester verified the T01 orchestration contract in the E22_S06 worktree, including incomplete-config handling and the setup-wizard fallback path.

---

## Problem Description
`publish_deploy.sh` calls `validate_config` before `run_target_completeness_check`. An incomplete target therefore fails schema validation immediately with exit code `4`, so the intended interactive fallback (`setup_wizard.sh`) is never reached.

Observed command:
```bash
bash skills/publish/scripts/publish_deploy.sh --target broken-app --config <invalid-config>
```

Observed output:
```text
publish config validation failed: invalid target: broken-app
```

Expected behavior from the task/story AC: interactive runs should auto-trigger the setup wizard for incomplete target config.

---

## Findings
| # | Finding | Severity | Notes |
|---|---------|----------|-------|
| 1 | Wizard remediation path is unreachable for schema-invalid target configs | High | T01 AC `Auto-trigger wizard on incomplete config (interactive)` is not met. |

---

## Impact
T01 cannot be marked passed. Interactive `/publish deploy` remediation breaks at the exact point the story promised to recover incomplete target config.

---

## Suggested Next Steps
1. Rework `publish_deploy.sh` so target completeness remediation happens before strict whole-file schema rejection, or introduce a validation mode that permits incomplete targets during setup remediation.
2. Add an automated regression test covering an incomplete target in interactive mode.
