---
id: E12_S01
epic_id: E12
title: UserPromptSubmit Hook
status: Passed
date_created: 2026-05-09
date_started:
date_completed: 2026-05-10
tasks: [E12_S01_T01, E12_S01_T02]
---

# Story: UserPromptSubmit Hook

As a Claude Code user, I want a `UserPromptSubmit` hook that transparently routes every prompt through the Jenga Router so that skill matching happens automatically without me doing anything special.

## Acceptance Criteria
- [ ] Hook script lives at `hooks/prompt_router.sh` and is executable
- [ ] Reads the incoming prompt from the environment variable provided by Claude Code's hook system
- [ ] Calls the Jenga Router via the MCP `route_prompt` tool (using a lightweight MCP client call or stdio pipe)
- [ ] If `action` is `"invoke"`: outputs the `transformed` prompt (e.g. `/do <original>`) as the rewritten prompt
- [ ] If `action` is `"passthrough"`: outputs the original prompt unchanged
- [ ] If the router is unreachable (not running), falls back to passthrough silently — never blocks the user
- [ ] Hook is registered in `settings.json` under `hooks.UserPromptSubmit`

## Definition of Done
- [ ] Typing "let's implement the login feature" in Claude Code results in Claude receiving "/do let's implement the login feature"
- [ ] Typing "/clear" passes through unchanged
- [ ] If router is down, prompts still reach Claude unmodified
- [ ] Hook executes in < 500ms including router round-trip
