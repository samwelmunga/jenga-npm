---
id: E24_S05_T02
story_id: E24_S05
epic_id: E24
title: Define fallback when last_update provenance cannot be determined
status: Passed
date_created: 2026-07-23
date_started:
date_completed: 2026-07-24
assigned_to: developer
---

# Task: Define fallback when last_update provenance cannot be determined

## Description
Define and implement the fallback behavior for `last_update` when no Done board items carry `docs` annotations matching the target file. Two acceptable fallback options: omit `last_update` entirely from the frontmatter, or set it to `unknown`. Choose one approach and document it clearly.

Steps:
1. Decide on the fallback strategy (omit vs. `unknown`) — document the decision in the skill
2. Implement the fallback branch in the provenance resolution logic
3. Ensure the generated file frontmatter is well-formed regardless of whether provenance was found

## Prerequisites
- E24_S05_T01 (provenance resolution logic must exist before fallback can be wired in)

## Acceptance Criteria
- [ ] When no matching board item is found, the fallback strategy is applied consistently
- [ ] The generated file's frontmatter is valid YAML whether provenance is present or absent
- [ ] Fallback strategy is documented in a comment or note in `skills/doc/SKILL.md`
