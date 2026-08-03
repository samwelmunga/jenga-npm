---
id: E15_S03
epic: E15
title: jenga attach command
status: Done
date_created: 2026-05-10
tasks:
  - E15_S03_T01
  - E15_S03_T02
---

# Story: jenga attach command

## Goal
Add a `jenga attach` CLI command that writes (or updates) the MCP server entry for the jenga router into `.claude/settings.json` in the current project. After running it once, any new AI session opened on that project will auto-spawn a project-scoped router via stdio.

## Acceptance Criteria
- [ ] `jenga attach` reads `jenga.cli.json` from `process.cwd()` to confirm the project is initialised; errors clearly if not
- [ ] Writes (or merges) an MCP server entry into `.claude/settings.json` at `process.cwd()/.claude/settings.json`
- [ ] The entry uses the correct `mcpServers` shape expected by Claude Code (type: stdio, command: node, args: [path-to-router])
- [ ] Router path in the entry is the absolute path to the jenga router (`mcp/router/index.js`) resolved from the global jenga install
- [ ] Operation is idempotent — running `jenga attach` twice does not duplicate the entry
- [ ] Prints a clear success message: "Attached. Open a new session in this project to start routing through Jenga."
- [ ] If `.claude/settings.json` does not exist, it is created with the correct structure
