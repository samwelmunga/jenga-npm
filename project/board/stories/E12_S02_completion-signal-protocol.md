---
id: E12_S02
epic_id: E12
title: Completion Signal Protocol
status: Passed
date_created: 2026-05-09
date_started:
date_completed: 2026-05-10
tasks: [E12_S02_T01, E12_S02_T02, E12_S02_T03]
---

# Story: Completion Signal Protocol

As the Jenga system, I want skills to emit a structured completion marker when they are done so that the router knows to clear the active session and resume normal matching.

## Acceptance Criteria
- [ ] Completion signal format is defined as: `[JENGA:SESSION_END:<skill_name>]` on its own line in the skill's output
- [ ] The hook or a post-response watcher detects this marker in Claude's output and calls `end_session(skill)` on the router
- [ ] The marker is stripped from the displayed output before the user sees it
- [ ] The signal protocol is documented in `docs/` or a `JENGA_PROTOCOL.md` file
- [ ] The SKILL.md template is updated to include a reminder/stub for emitting the completion signal at session end
- [ ] At least the `brainstorm` skill is updated to emit the signal when its session concludes

## Definition of Done
- [ ] After `/brainstorm` session ends and emits `[JENGA:SESSION_END:brainstorm]`, the next unrelated prompt is matched normally (not passed through)
- [ ] The marker does not appear in Claude's visible output
- [ ] Protocol doc clearly explains the format and responsibility for all skill authors
