# Rapport: <Short Problem Description>

**Date:** YYYY-MM-DD (UTC)
**Agent:** Developer | Tester
**Related Epic:** <Epic name or N/A>
**Related Story:** <Story name or N/A>
**Related Task:** <Task name or N/A>
**Type:** `conflict` | `implementation_blocker` | `security_concern` | `test_failure` | `analysis` | `crucial_escalation` | `checklist_suggestion`

> For `crucial_escalation`: the **Related Epic/Story/Task** field above must name the specific target item's ID (`E##`, `E##_S##`, or `E##_S##_T##`) whose `crucial_level` is being escalated — no separate field is used for this.

> For `checklist_suggestion`: a developer or tester may only **suggest** a new pre-flight checklist item (`project/configs/checklists.json`) — never write the file; only the Scrum Master does, after the user confirms. Non-blocking: keep working. The rapport must carry:
> - **Proposed item** — in the `checklists.json` item shape (`id`, `text`, `situations`, `kind`, `verify` for `machine` only, `enforcement`, `tick_scope`; see `project/documentation/preflight-checklists.md`).
> - **Origin** — `precautionary` (a risk you can see that has not caused a failure) or `recurrence` (a measure to stop an issue that already happened from happening again).
> - **Evidence** — at least one concrete, checkable fact: a specific file/path, an exact error message, a reproduction count, or a quantifiable impact. The same bar as `crucial_escalation`; "this seems risky" is rejected at review. This applies to both origins.
> - **For `recurrence`, additionally the originating incident** — a rapport path, a commit SHA, or a failed task id (`E##_S##_T##`) — so the item stays traceable to why it exists. A `recurrence` suggestion citing no incident is rejected at review.
>
> The accepted item records this as its `provenance` (`source: "suggested"`, `suggested_by`, `origin`, `evidence`, `accepted_on`). Do not write that key yourself.

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
- **Checklist suggestion:** give the proposed item (in the `checklists.json` item shape), its `origin` (`precautionary` | `recurrence`), and the evidence — at least one concrete, checkable fact (a specific file/path, an exact error message, a reproduction count, or a quantifiable impact). For `recurrence`, also cite the originating incident (a rapport path, a commit SHA, or a failed task id). A subjective statement alone is not sufficient.

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