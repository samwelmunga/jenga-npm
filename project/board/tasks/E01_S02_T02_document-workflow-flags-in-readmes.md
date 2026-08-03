---
id: E01_S02_T02
story_id: E01_S02
epic_id: E01
title: Document workflow flags in each template README
status: Passed
date_created: 2026-04-29
date_started:
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Document workflow flags in each template README

## Description
Add a `## Workflow Configuration` section to each of the three template README files:
- `.training/template/classifiers/README.md`
- `.training/template/transformers/README.md`
- `.training/template/nlp/README.md`

The section should include a table documenting each `workflow:` flag: name, type, default value, and a plain-English description of its effect.

## Prerequisites
- E01_S02_T01 must be complete (flags must be finalised before documenting)

## Acceptance Criteria
- [ ] All three READMEs have a `## Workflow Configuration` section
- [ ] Table covers all five flags with name, type, default, and description
- [ ] Descriptions accurately reflect how the `/train` skill and `training_runner` MCP use each flag
