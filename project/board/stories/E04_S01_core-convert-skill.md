---
id: E04_S01
epic_id: E04
title: Core /convert Skill
status: Passed
date_created: 2026-04-30
date_started: 2026-04-30
date_completed: 2026-04-30
tasks:
  - Scaffold skills/convert skill file and SKILL.md
  - Implement file extension auto-detection (.json, .jsonl, .yaml, .yml, .csv)
  - Implement JSON array → CSV conversion
  - Implement JSONL → CSV conversion
  - Implement YAML/YML → CSV conversion
  - Implement top-level structure sniff (warn + confirm if {} object, proceed if [] array)
  - Implement dot-notation flattening for nested structures
  - Implement pass-through behaviour (return input path as-is if already .csv)
  - Support standalone invocation: convert <path-to-file>
---

# Story: Core /convert Skill

As a user preparing data for a training job, I want to run `/convert` on a JSON, JSONL, or YAML dataset file and get back a clean CSV — so that I can feed it directly into any `/train` job without manual preprocessing.

## Acceptance Criteria
- [x] `convert <path>` auto-detects format from file extension
- [x] `.json` (array), `.jsonl`, `.yaml`, `.yml` are all converted to `.csv`
- [x] If top-level structure is a `{}` object (not an array), the tool warns and asks the user to confirm before proceeding
- [x] Nested structures are flattened using dot-notation (e.g. `{"user": {"age": 30}}` → `user.age` column)
- [x] If input is already `.csv`, the tool returns the path as-is with no conversion
- [x] Output CSV is written to the same directory as the input file with a `.csv` extension

## Definition of Done
- [x] `skills/convert/` scaffolded with a `SKILL.md`
- [x] All four input formats handled and tested
- [x] Dot-notation flattening implemented
- [x] Pass-through behaviour implemented
- [x] Standalone invocation documented
