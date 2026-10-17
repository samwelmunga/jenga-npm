---
layout: page
title: MCP Tools
permalink: /mcp-tools.html
---


MCP (Model Context Protocol) tools extend Claude Code with additional capabilities. They are configured in `settings.json`.

> Where a project registers an MCP *server* for Claude Code (`.mcp.json` vs `.claude/settings.json`) is recorded in [mcp-registration-decision.md](https://github.com/samwelmunga/jenga-npm/blob/main/project/documentation/mcp-registration-decision.md).

---

### `mcp/help`

**Purpose:** Discovers available skills by scanning `.agents/skills/`. Returns skill folder names programmatically.

**Use case:** Building tooling that needs to enumerate available skills without reading the filesystem directly.

```bash
cd .agents/mcp/help && npm install
node index.js           # lists all skill names
node index.js skills/   # list with custom path
```

---

### `mcp/execute-ticket`

**Purpose:** Planned tool — creates a sub-agent, initialises a git worktree, and names the session after the task ID.

**Status:** In development. See `.agents/mcp/execute-ticket/index.js`.

---

### `mcp/training_runner`

**Purpose:** MCP server that validates and runs ML training jobs, executing a job's `start.sh` through the two-phase validate → train pipeline.

**Use case:** Backs `/j-train`'s `run` mode — see that skill's entry above.

---

