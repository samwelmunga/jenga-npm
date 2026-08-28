# Rapport: <Short Problem Description>

**Date:** YYYY-MM-DD (UTC)
**Agent:** Developer | Tester
**Related Epic:** <Epic name or N/A>
**Related Story:** <Story name or N/A>
**Related Task:** <Task name or N/A>
**Type:** `conflict` | `implementation_blocker` | `security_concern` | `test_failure` | `analysis` | `crucial_escalation`

> For `crucial_escalation`: the **Related Epic/Story/Task** field above must name the specific target item's ID (`E##`, `E##_S##`, or `E##_S##_T##`) whose `crucial_level` is being escalated — no separate field is used for this.

---

## Sender
```json
{
  "sender": {
    "agent": "",
    "session_id": "",
    "task_id": "",
    "story_id": "",
    "epic_id": "",
    "date": "",
    "paths": [],
    "worktree": ""
  }
}
```

---

## Summary
A one or two sentence description of what the problem is and why it blocked progress or requires attention.

---

## Context
What was being implemented or tested when this issue was encountered. Include relevant task or story goals.

---

## Problem Description
A detailed explanation of the issue.
- **Conflict:** describe both implementations and where they clash
- **Security concern:** describe the vulnerability or risk
- **Implementation blocker:** describe what failed and why
- **Test failure:** describe which tests failed, what was expected, and what was observed
- **Analysis:** describe the analysis scope, methodology, and findings
- **Crucial escalation:** describe what was discovered during implementation or testing, why it changes the target item's risk profile enough to warrant raising its `crucial_level`, and the concrete, checkable fact backing that claim (a specific file/path, an exact error message, a reproduction count, or a quantifiable impact — see `templates/SCRUM_BOARD_SCHEMA.md`'s Rapport Types section for the full concrete-reason requirement). A subjective statement alone (e.g. "this seems risky") is not sufficient.

---

## Attempts Made
_Only applicable for `conflict` and `implementation_blocker` types._

### Attempt 1
What was tried and why it did not work.

### Attempt 2
What was tried and why it did not work.

### Attempt 3
What was tried and why it did not work.

---

## Findings
_Only applicable for `test_failure` and `analysis` types._

| # | Finding | Severity | Notes |
|---|---------|----------|-------|
| 1 | | | |

---

## Impact
What cannot proceed until this is resolved. Which tasks, stories, or epics are blocked.

---

## Suggested Next Steps
Concrete suggestions for how a human or another agent could resolve this. Be specific.

---

## Ignore Log
_Only populated by the developer when this rapport is marked `.IGNORE.md`._

**Ignored by:** Developer
**Date:** YYYY-MM-DD (UTC)
**Reason:**