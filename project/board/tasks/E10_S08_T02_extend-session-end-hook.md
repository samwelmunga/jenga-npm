---
id: E10_S08_T02
story_id: E10_S08
epic_id: E10
title: Extend hooks/on_session_end.sh to call todo_cleanup.sh
status: Done
date_created: 2026-05-08
date_started: 2026-05-08
date_completed: 2026-05-08
assigned_to: developer
---

# Task: Extend hooks/on_session_end.sh to call todo_cleanup.sh

## Description
Edit `hooks/on_session_end.sh` to add a new final section that unconditionally calls `bash scripts/todo_cleanup.sh` on every session end. The extension must not break any existing hook behaviour — sections 1–4 must run as before. No agent-type filter is needed for this call.

## Prerequisites
- E10_S08_T01 (todo_cleanup.sh must exist)

## Acceptance Criteria
- [ ] `hooks/on_session_end.sh` calls `bash scripts/todo_cleanup.sh` as its last section
- [ ] Call is unconditional (no agent-type filter)
- [ ] Existing hook sections 1–4 are unchanged
