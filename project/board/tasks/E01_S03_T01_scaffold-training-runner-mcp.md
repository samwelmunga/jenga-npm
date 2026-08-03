---
id: E01_S03_T01
story_id: E01_S03
epic_id: E01
title: Scaffold training_runner MCP server
status: Done
date_created: 2026-04-29
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Scaffold training_runner MCP server

## Description
Create the `mcp/training-runner/` directory with a Node.js MCP server following the same structure as the existing `mcp/execute-ticket/` server. Register a single MCP tool called `training_runner` that accepts a `job_dir` parameter (absolute path to the training job directory). Scaffold `package.json`, `index.js`, and wire up the MCP tool registration. The tool body can be a stub at this stage — logic is added in subsequent tasks.

## Prerequisites
None.

## Acceptance Criteria
- [ ] `mcp/training-runner/` exists with `package.json` and `index.js`
- [ ] MCP server starts without errors (`node index.js`)
- [ ] `training_runner` tool is registered and visible to MCP clients
- [ ] Structure mirrors `mcp/execute-ticket/` conventions
