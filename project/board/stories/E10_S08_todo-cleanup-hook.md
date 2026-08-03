---
id: E10_S08
epic_id: E10
title: "`scripts/todo_cleanup.sh` + session-end hook extension"
status: Done
date_created: 2026-05-08
date_started:
date_completed: 2026-05-10
tasks: []
---

# Story: `scripts/todo_cleanup.sh` + session-end hook extension

As a project maintainer, I want a safety-net script that runs on every session end and automatically deletes `project/todo.md` if it is effectively empty, so stale empty files are never left behind regardless of which skill ran.

## Acceptance Criteria
- [ ] Script lives at `scripts/todo_cleanup.sh` and is executable
- [ ] "Effectively empty" is defined as: the file contains only lines that are blank, exactly `# Todo`, or match the HTML comment pattern `<!--...-->`
- [ ] If the file is effectively empty, the script deletes it and prints a message to stdout
- [ ] If the file has real entries, the script exits 0 silently without modifying anything
- [ ] If `project/todo.md` does not exist, the script exits 0 silently (no error)
- [ ] `hooks/on_session_end.sh` is extended with a new final section that calls `bash scripts/todo_cleanup.sh`
- [ ] The hook extension runs unconditionally on every session end (no agent-type filter needed)

## Definition of Done
- [ ] A session that ends with an effectively-empty `todo.md` results in the file being deleted
- [ ] A session that ends with a non-empty `todo.md` leaves the file untouched
- [ ] The hook extension does not break any existing hook behaviour (sections 1–4 run as before)
