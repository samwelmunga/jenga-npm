---
id: E16_S03_T01
story_id: E16_S03
epic_id: E16
title: Document hook parity matrix
status: Done
date_created: 2026-05-10
date_started: 2026-05-10
date_completed: 2026-05-10
assigned_to: developer
---

# Task: Document hook parity matrix

## Description
Create `docs/hook-parity.md` — a reference document mapping each Claude Code hook event to its GitHub Copilot CLI equivalent. For hooks with no native Copilot equivalent, document the recommended workaround.

Cover at minimum:
- `UserPromptSubmit` — Claude intercepts every prompt; Copilot equivalent is `copilot-instructions.md` routing guidance
- `WorktreeCreate` / `WorktreeRemove` — Claude manages git worktrees; Copilot equivalent is manual or script-based
- `SessionEnd` — Claude fires on session close; Copilot equivalent is skill post-execution hook via `hooks/on_session_end.sh`

## Prerequisites
None.

## Acceptance Criteria
- [ ] `docs/hook-parity.md` exists
- [ ] All four Claude hook events are documented with Copilot equivalents or workarounds
- [ ] Document is accurate and references `JENGA_*` vars (not `CLAUDE_*`)
