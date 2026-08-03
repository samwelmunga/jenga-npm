---
id: E14_S01_T01
story_id: E14_S01
epic_id: E14
title: Define `jenga.cli.json` JSON Schema
status: Passed
date_created: 2026-05-09
date_started: 2026-05-09
date_completed: 2026-05-09
assigned_to: developer
---

# Task: Define `jenga.cli.json` JSON Schema

## Description
Define the JSON Schema for `jenga.cli.json` covering all required fields: `skillsPath` (string), `matchThreshold` (number, 0–1), `sessionTimeout` (number, ms), `agentTarget` (string enum: "claude"/"copilot"/"custom"). Store schema in a reusable location (e.g. `mcp/router/schema.js` or `lib/config-schema.json`).

## Prerequisites
None

## Acceptance Criteria
- [x] Schema covers all 4 required fields with correct types and constraints
- [x] `matchThreshold` is constrained to 0–1 range
- [x] `agentTarget` is restricted to allowed enum values
- [x] Schema is importable/usable by the router and CLI
