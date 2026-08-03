---
id: E10_S08_T01
story_id: E10_S08
epic_id: E10
title: Implement scripts/todo_cleanup.sh
status: Done
date_created: 2026-05-08
date_started: 2026-05-08
date_completed: 2026-05-08
assigned_to: developer
---

# Task: Implement scripts/todo_cleanup.sh

## Description
Create `scripts/todo_cleanup.sh` — a safety-net script that deletes `project/todo.md` when it is effectively empty. "Effectively empty" means: the file contains only lines that are blank, exactly `# Todo`, or match the HTML comment pattern `<!--...-->`. If the file has real entries the script exits 0 silently. If the file does not exist it also exits 0 silently. If effectively empty it deletes the file and prints a message to stdout.

## Prerequisites
None

## Acceptance Criteria
- [ ] File exists at `scripts/todo_cleanup.sh` and is executable
- [ ] Effectively-empty detection covers: blank lines, `# Todo` line, `<!--...-->` comment lines
- [ ] Deletes and prints message when effectively empty
- [ ] Exits 0 silently when file has real entries
- [ ] Exits 0 silently when file is absent
