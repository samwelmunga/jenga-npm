---
id: E14_S01_T02
story_id: E14_S01
epic_id: E14
title: Implement schema validation in router startup
status: Passed
date_created: 2026-05-09
date_started: 2026-05-09
date_completed: 2026-05-09
assigned_to: developer
---

# Task: Implement schema validation in router startup

## Description
On router startup, validate `jenga.cli.json` against the schema defined in E14_S01_T01. If validation fails, print a descriptive error message to stderr (e.g. "Missing required field: skillsPath") and exit non-zero.

## Prerequisites
- E14_S01_T01

## Acceptance Criteria
- [x] Missing required field: exit non-zero with "Missing required field: <field>" message
- [x] `matchThreshold` outside 0–1: clear validation error, exit non-zero
- [x] Valid config: router starts normally
