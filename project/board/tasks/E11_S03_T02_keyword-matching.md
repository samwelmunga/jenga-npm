---
id: E11_S03_T02
story_id: E11_S03
epic_id: E11
title: Implement keyword matching stage
status: Passed
date_created: 2026-05-09
date_started: 2026-05-09
date_completed: 2026-05-09
assigned_to: developer
---

# Task: Implement keyword matching stage

## Description
Implement the second stage of the `route_prompt` pipeline: keyword matching. Match the incoming prompt text against each skill's `name`, `keywords`, and `examples` fields. Return the best match if confidence meets the threshold (default 0.75, configurable via `matchThreshold` in `jenga.cli.json`). If matched, return `{ action: "invoke", transformed: "/<skill_name> <original>", skill: <name>, confidence: <score> }`.

## Prerequisites
- E11_S03_T01

## Acceptance Criteria
- [x] Keyword matching runs after passthrough rules
- [x] Confidence threshold is respected (no match below threshold)
- [x] `transformed` is `/<skill_name> <original>` when action is invoke
