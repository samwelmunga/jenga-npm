---
id: E11_S03
epic_id: E11
title: Matching Engine
status: Passed
date_created: 2026-05-09
date_started:
date_completed: 2026-05-10
tasks: [E11_S03_T01, E11_S03_T02, E11_S03_T03]
---

# Story: Matching Engine

As the router, I want to match an incoming prompt against the skill index using keyword and lightweight semantic similarity so that I can return the best skill invocation or a passthrough decision.

## Acceptance Criteria
- [ ] `route_prompt(text)` tool accepts a prompt string and returns `{ action, transformed, skill, confidence }`
- [ ] `action` is either `"invoke"` or `"passthrough"`
- [ ] Matching pipeline: (1) passthrough rules check, (2) keyword match against `name`/`keywords`/`examples`, (3) semantic similarity against `description` using a local model (e.g. `all-MiniLM-L6-v2` via `@xenova/transformers` or similar ONNX runtime — no API calls)
- [ ] Confidence threshold defaults to `0.75`; configurable via `jenga.cli.json` `matchThreshold`
- [ ] Prompts starting with `/` always return `{ action: "passthrough" }` regardless of threshold
- [ ] When `action` is `"invoke"`, `transformed` is the skill invocation string (e.g. `/do <original prompt>`)
- [ ] When `action` is `"passthrough"`, `transformed` equals the original prompt unchanged

## Definition of Done
- [ ] `/brainstorm` prompt routes correctly to the `brainstorm` skill in tests
- [ ] "let's plan a new feature" routes to `brainstorm` or `do` with confidence ≥ 0.75
- [ ] "/clear" returns passthrough regardless of skill index contents
- [ ] Matching completes in < 200ms per call after model warm-up
