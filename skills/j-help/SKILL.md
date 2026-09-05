---
name: j:help
description: Polyfill alias of the help skill under a collision-safe directory name. Identical behavior to /help — List all available skills with a short description of what each one does. Also use this skill when the user wants to know what commands or skills are available in the project. Use when the bare /help form is shadowed by another tool's own built-in command of the same name.
keywords:
  - help
  - skills
  - commands
  - what can you do
  - list skills
  - j-help
  - polyfill
examples:
  - "what skills are available?"
  - "show me all commands"
  - "j-help"
---

# Help — List Available Skills

This skill is a literal-directory-name duplicate of `skills/help/`. It exists so that `/j-help` (and `j:j-help`) give a guaranteed-unshadowed way to reach the same flow as `/help`, even if a host tool's own built-in command of the same name would otherwise shadow or override the bare `/help` alias (Claude Code's native skill resolution is a literal-string, directory-name-based match — see `docs/skill-authoring.md`'s "Invocation Convention").

This file is generated/synced by `scripts/generate-j-alias.sh help` from `skills/help/SKILL.md` — do not hand-edit it; re-run the generator instead to pick up source changes.

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
