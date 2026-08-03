---
id: E24_S04_T01
story_id: E24_S04
epic_id: E24
title: Implement full-file ownership flow
status: Passed
date_created: 2026-07-23
date_started:
date_completed: 2026-07-23
assigned_to: developer
---

# Task: Implement full-file ownership flow

## Description
Implement the core generation flow in `skills/doc/SKILL.md`. `/doc` owns the entire target file — it reads the existing file (if present) for intent and context, then regenerates the full file from scratch using the synthesis context object. It does NOT patch or append to the existing file.

Steps:
1. If the target file exists, read it to extract any author intent not captured by evidence (e.g. custom sections, warnings, known-issue callouts)
2. Incorporate that intent into the synthesis context as `existing_intent`
3. Generate the full new file content using the synthesis context
4. Write the complete file, replacing the old content

The skill must NOT partially update the file (e.g. only updating one section while leaving others stale).

## Prerequisites
- E24_S03 story must be complete (synthesis context object available)

## Acceptance Criteria
- [ ] If target file exists, it is read before generation
- [ ] Existing intent is captured in the synthesis context
- [ ] The generated output is a full file (not a patch)
- [ ] The entire file is written/replaced in one operation
