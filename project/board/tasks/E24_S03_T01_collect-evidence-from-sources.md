---
id: E24_S03_T01
story_id: E24_S03
epic_id: E24
title: Collect evidence from all configured sources
status: Passed
date_created: 2026-07-23
date_started:
date_completed: 2026-07-23
assigned_to: developer
---

# Task: Collect evidence from all configured sources

## Description
Implement the evidence collection step inside `skills/doc/SKILL.md`. The skill must gather relevant information from four sources before generating documentation:

1. **User prompt** — any description, context, or constraints provided in the `/doc` invocation
2. **Scrum board** — read `project/PROJECT_SUMMARY.md`, relevant epics (`project/board/epics/`), stories (`project/board/stories/`), and tasks (`project/board/tasks/`) that are linked to the target document via `docs` annotations or whose description mentions the target
3. **Codebase** — scan package manifests (e.g. `package.json`, `pyproject.toml`, `go.mod`), key source files, and any existing version of the target file
4. **Git history** — recent commits relevant to the target document (last 20 commits, filtered by files that relate to the target's subject)

Each source produces a structured evidence block. Missing or inaccessible sources produce an empty block (do not fail).

## Prerequisites
- E24_S02 story must be complete (skill scaffold and rule table exist)

## Acceptance Criteria
- [ ] Evidence is collected from all 4 sources
- [ ] Each source produces a structured evidence block (even if empty)
- [ ] Missing sources (no git history, no board, etc.) do not cause the skill to fail
- [ ] Evidence blocks are assembled into a single synthesis context object
