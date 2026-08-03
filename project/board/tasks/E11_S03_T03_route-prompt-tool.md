---
id: E11_S03_T03
story_id: E11_S03
epic_id: E11
title: Expose `route_prompt` MCP tool
status: Passed
date_created: 2026-05-09
date_started: 2026-05-09
date_completed: 2026-05-09
assigned_to: developer
---

# Task: Expose `route_prompt` MCP tool

## Description
Register the `route_prompt(text: string)` MCP tool on the router, wiring together the passthrough rules and keyword matching pipeline. Tool returns `{ action, transformed, skill, confidence }`. Tool schema must be valid MCP JSON Schema.

## Prerequisites
- E11_S03_T02

## Acceptance Criteria
- [x] `route_prompt` tool is callable via MCP client
- [x] Returns correct `action`, `transformed`, `skill`, `confidence` fields
- [x] Tool schema passes MCP schema validation
- [x] Completes in < 200ms per call after warm-up
