---
id: E10_S01
epic_id: E10
title: "`scripts/todo_manager.sh`"
status: Done
date_created: 2026-05-08
date_started:
date_completed: 2026-05-10
tasks: []
---

# Story: `scripts/todo_manager.sh`

As a skill or script author, I want a single canonical shell script that owns all `todo.md` operations so that no skill needs to contain inline file manipulation logic.

## Acceptance Criteria
- [ ] Script lives at `scripts/todo_manager.sh` and is executable (`chmod +x`)
- [ ] `add "<entry>"` appends the entry to `project/todo.md`; if the file does not exist, it is auto-created first by copying `skills/todo/assets/todo_template.md`
- [ ] `remove "<title>"` removes the first line matching the given title; fails loudly (non-zero exit + stderr) if no match is found
- [ ] `list` prints all non-comment, non-blank entries to stdout; exits 0 silently if file is missing or empty
- [ ] `exists` exits 0 if `project/todo.md` has at least one non-comment, non-blank entry; exits 1 otherwise with a distinct stderr message for "file missing" vs "file empty"
- [ ] `teardown` deletes `project/todo.md` if it is effectively empty (only whitespace, `# Todo` title, and `<!-- ... -->` comment lines); no-op if already absent
- [ ] Script is self-contained — no dependency on other scripts in this epic
- [ ] `skills/todo/assets/todo_template.md` is used as the source for `add` auto-init; it is NOT modified or deleted by the script

## Definition of Done
- [ ] All commands behave correctly in both the "file present" and "file absent" states
- [ ] `remove` on a non-existent entry exits non-zero and prints an error to stderr
- [ ] `teardown` leaves a non-empty `todo.md` untouched
