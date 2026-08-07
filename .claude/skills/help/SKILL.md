---
name: help
description: List all available skills with a short description of what each one does. Also use this skill when the user wants to know what commands or skills are available in the project.
keywords:
  - help
  - skills
  - commands
  - what can you do
  - list skills
examples:
  - "what skills are available?"
  - "show me all commands"
---

# Help — List Available Skills

## Instructions

List all available skills (from the current skill list) with a short description of what each one does. Format the output as a table with columns for the slash command and its description.

## MCP Tool (Dynamic Discovery)

An MCP server ships inside the `jenga-agent` package at `mcp/help/` that dynamically discovers skills at runtime.

To install and run (from a consumer project that has `jenga-agent` installed):
```bash
cd node_modules/jenga-agent/mcp/help && npm install
node index.js
```

Or wire it as an MCP server in `.claude/settings.json` — `jenga attach` does this automatically for the router; the help server can be added the same way, pointing `args` at `node_modules/jenga-agent/mcp/help/index.js`.

The `help` tool accepts an optional `path` argument (defaults to `cwd`) and:
1. Looks for a `.claude/skills` directory at that path, falling back to `.agents/skills`.
2. If found, returns a list of all folder names inside it.
3. If neither exists, returns a clear message listing the paths it checked.
