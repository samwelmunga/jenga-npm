---
id: E11_S01_T01
story_id: E11_S01
epic_id: E11
title: Scaffold `mcp/router/index.js` stdio MCP server
status: Passed
date_created: 2026-05-09
date_started: 2026-05-09
date_completed: 2026-05-09
assigned_to: developer
---

# Task: Scaffold `mcp/router/index.js` stdio MCP server

## Description
Create the initial `mcp/router/index.js` file following the same stdio MCP pattern used in `mcp/help`. The server must start up, register tools, and enter the stdio MCP read loop. Include a package stub (`mcp/router/package.json`) if needed.

## Prerequisites
None

## Acceptance Criteria
- [x] `mcp/router/index.js` exists and is runnable via `node mcp/router/index.js`
- [x] Server follows the same stdio MCP protocol pattern as `mcp/help`
- [x] Process stays alive after startup (enters read loop)
