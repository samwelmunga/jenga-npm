---
id: E11_S03_T01
story_id: E11_S03
epic_id: E11
title: Implement passthrough rules for the matching engine
status: Passed
date_created: 2026-05-09
date_started: 2026-05-09
date_completed: 2026-05-09
assigned_to: developer
---

# Task: Implement passthrough rules for the matching engine

## Description
Implement the first stage of the `route_prompt` pipeline: passthrough rules. Any prompt starting with `/` must immediately return `{ action: "passthrough", transformed: <original>, skill: null, confidence: 0 }` without consulting the skill index.

## Prerequisites
- E11_S02_T01

## Acceptance Criteria
- [x] Prompts starting with `/` always return `action: "passthrough"`
- [x] Passthrough is checked before any keyword or semantic matching
- [x] `transformed` equals the original prompt unchanged on passthrough
