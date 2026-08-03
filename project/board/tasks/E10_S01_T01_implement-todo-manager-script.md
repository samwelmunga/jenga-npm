---
id: E10_S01_T01
story_id: E10_S01
epic_id: E10
title: Implement scripts/todo_manager.sh
status: Done
date_created: 2026-05-08
date_started: 2026-05-08
date_completed: 2026-05-08
assigned_to: developer
---

# Task: Implement scripts/todo_manager.sh

## Description
Create `scripts/todo_manager.sh` — a canonical shell script that owns all `todo.md` file operations. It must support six subcommands: `add`, `remove`, `list`, `exists`, and `teardown`, plus auto-init via `skills/todo/assets/todo_template.md` when `add` is called and the file does not yet exist. The script must be `chmod +x` and self-contained with no dependencies on other scripts in E10.

## Prerequisites
None

## Acceptance Criteria
- [ ] File exists at `scripts/todo_manager.sh` and is executable
- [ ] `add "<entry>"` appends the entry; auto-creates `project/todo.md` from `skills/todo/assets/todo_template.md` first if absent
- [ ] `remove "<title>"` removes the first matching line; exits non-zero + stderr if not found
- [ ] `list` prints all non-comment, non-blank entries; exits 0 silently if file is missing or empty
- [ ] `exists` exits 0 if at least one real entry exists; exits 1 with distinct stderr for "file missing" vs "file empty"
- [ ] `teardown` deletes `project/todo.md` if it is effectively empty (only blanks, `# Todo`, and HTML comments); no-op if absent
- [ ] Script is self-contained — no dependency on other scripts in this epic
