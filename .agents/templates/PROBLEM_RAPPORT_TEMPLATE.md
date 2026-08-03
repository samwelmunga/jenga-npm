# Rapport: <Short Problem Description>

**Date:** YYYY-MM-DD (UTC)
**Agent:** Developer | Tester
**Related Epic:** <Epic name or N/A>
**Related Story:** <Story name or N/A>
**Related Task:** <Task name or N/A>
**Type:** `conflict` | `implementation_blocker` | `security_concern` | `test_failure` | `analysis`

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