---
id: E11_S01_T03
story_id: E11_S01
epic_id: E11
title: Implement `ping` MCP tool
status: Passed
date_created: 2026-05-09
date_started: 2026-05-09
date_completed: 2026-05-09
assigned_to: developer
---

# Task: Implement `ping` MCP tool

## Description
Register a `ping` MCP tool on the router that returns `{ ok: true, uptime: <seconds since start> }`. Uptime is calculated from the process start timestamp.

## Prerequisites
- E11_S01_T01

## Acceptance Criteria
- [x] `ping` tool is callable via MCP client and returns `{ ok: true, uptime: <number> }`
- [x] Uptime increases with each call (seconds since server started)
- [x] Tool schema is valid MCP JSON Schema
