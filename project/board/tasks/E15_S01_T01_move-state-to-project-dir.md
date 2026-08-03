---
id: E15_S01_T01
story: E15_S01
title: Move PID and session state to <cwd>/.jenga/
status: Done
date_created: 2026-05-10
---

# Task: Move PID and session state to <cwd>/.jenga/

## What to do
In `mcp/router/index.js` and `lib/commands/start.js`, replace all paths that resolve state relative to `__dirname` with paths relative to `process.cwd()/.jenga/`.

Specifically:
- `const pidFile = join(__dirname, ".pid")` → `join(process.cwd(), ".jenga", "router.pid")`
- Any session state file similarly moved to `.jenga/session.json`
- Create the `.jenga/` directory if it does not exist (use `fs.mkdirSync(..., { recursive: true })`)
- `lib/commands/stop.js` and `lib/commands/status.js` must read from the same `<cwd>/.jenga/` paths
