---
id: E11_S05_T02
story_id: E11_S05
epic_id: E11
title: Add structured MCP error handling to all tools
status: Passed
date_created: 2026-05-09
date_started: 2026-05-09
date_completed: 2026-05-09
assigned_to: developer
---

# Task: Add structured MCP error handling to all tools

## Description
Ensure all 6 MCP tools (`ping`, `reload_skills`, `route_prompt`, `active_session`, `end_session`, `list_skills`) return structured MCP error responses on failure rather than unhandled exceptions. Each tool should catch errors and return a properly formatted MCP error response.

## Prerequisites
- E11_S05_T01

## Acceptance Criteria
- [x] No tool throws an unhandled exception under normal operating conditions
- [x] Tool errors return structured MCP error responses
- [x] All 6 tools are callable via any MCP client
