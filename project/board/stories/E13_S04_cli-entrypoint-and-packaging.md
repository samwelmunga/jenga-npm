---
id: E13_S04
epic_id: E13
title: CLI Entrypoint & Packaging
status: Passed
date_created: 2026-05-09
date_started:
date_completed: 2026-05-10
tasks: [E13_S04_T01, E13_S04_T02]
---

# Story: CLI Entrypoint & Packaging

As a developer, I want the `jenga` command to be installable via npm so that any project using this framework can add it as a dependency or install it globally.

## Acceptance Criteria
- [ ] CLI entrypoint lives at `bin/jenga.js` with a `#!/usr/bin/env node` shebang and is executable
- [ ] `package.json` `bin` field maps `"jenga"` to `"bin/jenga.js"`
- [ ] CLI supports subcommands: `init`, `start`, `status` — each delegating to their respective module
- [ ] Unknown subcommands print usage help and exit non-zero
- [ ] `jenga --version` prints the version from `package.json`
- [ ] `jenga --help` prints a concise usage summary with all subcommands
- [ ] `npm install -g .` (local) and `npm install -g jenga-agent` (published) both make `jenga` available in PATH

## Definition of Done
- [ ] `npm install -g .` in project root results in a working `jenga` command
- [ ] `jenga --version` and `jenga --help` work without any config file present
- [ ] All three subcommands are reachable via `jenga <cmd>`
