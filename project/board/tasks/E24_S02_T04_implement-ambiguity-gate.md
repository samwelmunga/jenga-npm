---
id: E24_S02_T04
story_id: E24_S02
epic_id: E24
title: Implement ambiguity gate for unknown target paths
status: Passed
date_created: 2026-07-23
date_started:
date_completed: 2026-07-24
assigned_to: developer
---

# Task: Implement ambiguity gate for unknown target paths

## Description
Extend the `/doc` skill to include an ambiguity gate. When the target path does not match any entry in the path→objective rule table, the skill must halt and ask the user for explicit clarification before proceeding. The user must describe what the document should contain (its objective). Once the user clarifies, the skill proceeds with the provided objective.

The gate must NOT guess or infer an objective for unknown targets — it must always ask.

## Prerequisites
- E24_S02_T02
- E24_S02_T03

## Acceptance Criteria
- [ ] When target path is not in the rule table, the skill pauses and asks the user: "What should `<path>` document? Please describe the objective."
- [ ] The skill does NOT proceed until the user provides an explicit objective
- [ ] Once the user provides an objective, the skill continues with the provided objective as if it came from the rule table
- [ ] Known target paths bypass the ambiguity gate entirely
