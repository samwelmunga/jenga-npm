---
id: E11
title: Jenga Router
status: In Progress
date_created: 2026-05-09
date_started:
date_completed: 2026-05-10
stories:
  - E11_S01
  - E11_S02
  - E11_S03
  - E11_S04
  - E11_S05
  - E11_S06
---

# Epic: Jenga Router

## Purpose
Build the local Node.js MCP server (stdio transport) that acts as the central routing brain for the Jenga framework. On startup it scans the `skills/` directory, parses SKILL.md frontmatter (including `keywords` and `examples`), and builds an in-memory skill index. At runtime it exposes MCP tools for prompt routing (`route_prompt`), session management (`active_session`, `end_session`), and skill listing (`list_skills`). Matching uses keyword + lightweight semantic similarity with a configurable confidence threshold (default 0.75). Session state is tracked in-memory and auto-expires on timeout or on receipt of a `[JENGA:SESSION_END:skill_name]` completion signal.

## Definition of Done
- [ ] Router starts as a stdio MCP server and writes a PID file
- [ ] Skill index is built from `skills/` frontmatter on startup (name, description, keywords, examples)
- [ ] `route_prompt(text)` returns `{ action, transformed, skill, confidence }` reliably
- [ ] Passthrough rules enforced: `/`-prefixed prompts and active-session prompts pass unmodified
- [ ] Session tracker correctly activates, holds, and clears sessions on completion signal or timeout
- [ ] All four MCP tools exposed and callable
