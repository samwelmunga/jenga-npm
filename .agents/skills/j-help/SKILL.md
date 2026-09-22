---
name: j.help
description: List all available skills with a short description of what each one does. Also use this skill when the user wants to know what commands or skills are available in the project.
keywords:
  - help
  - skills
  - commands
  - what can you do
  - list skills
  - j-help
examples:
  - "what skills are available?"
  - "show me all commands"
  - "j-help"
---

# Help — List Available Skills

`skills/j-help/` is the **canonical, hand-edited** directory for this skill, per CLAUDE.md's "The Canonical Naming Contract" (the `E50` reopening of 2026-09-09, which promoted `skills/j-help/` from generated twin to sole canonical form). The `j-` prefix is there for collision safety — a real directory under a distinct name, so a host tool shipping its own same-named built-in command cannot shadow it (Claude Code's native skill resolution is a literal-string, directory-name-based match; see `docs/skill-authoring.md`'s "Invocation Convention").

> ⚠️ **`scripts/generate-j-alias.sh` was retired by `E50_S14` and no longer exists — there is nothing to run.** This file was previously generated from a bare `skills/help/SKILL.md` source; `E50_S15` deleted that directory. This file is now the sole canonical, hand-edited source for this skill — edit it directly.

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
