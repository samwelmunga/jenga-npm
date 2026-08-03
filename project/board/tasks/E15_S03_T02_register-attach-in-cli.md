---
id: E15_S03_T02
story: E15_S03
title: Register jenga attach in CLI entrypoint
status: Done
date_created: 2026-05-10
---

# Task: Register jenga attach in CLI entrypoint

## What to do
In `bin/jenga.js` (or wherever commands are registered), import `lib/commands/attach.js` and register it as the `attach` command.

Update the CLI help text so `jenga --help` shows:
```
  attach    Write MCP config for this project so new sessions route through Jenga
```

Also update the README or any usage docs that describe available commands.
