---
id: E11_S06
epic_id: E11
title: Intent Classification Model
status: Pending
date_created: 2026-05-11
date_started:
date_completed:
tasks: [E11_S06_T01, E11_S06_T02, E11_S06_T03]
---

# Story: Intent Classification Model

As the router, I want `mcp/router/matcher.js` to incorporate a local intent/semantic classification model so that prompt categorization goes beyond keyword matching and correctly routes semantically similar but keyword-sparse prompts.

## Background

The current `matcher.js` scores prompts purely via keyword and example-word overlap — no embedding or classification model is involved. E11_S03's acceptance criteria originally specified a semantic similarity step using a local model (`all-MiniLM-L6-v2` via `@xenova/transformers`), but this was never implemented.

## Acceptance Criteria

- [ ] A local embedding/classification model (e.g. `all-MiniLM-L6-v2` via `@xenova/transformers`) is integrated into `matcher.js`
- [ ] `scoreSkill` (or an equivalent pipeline step) computes cosine similarity between the prompt embedding and each skill's description embedding
- [ ] Semantic score is blended with (or used as a fallback after) keyword score to produce the final confidence value
- [ ] Model is loaded once on startup and reused across calls (no per-call cold start)
- [ ] Skill description embeddings are pre-computed at index-build time and cached in memory
- [ ] No external API calls — inference runs entirely locally via ONNX runtime
- [ ] Confidence threshold (`0.75` default) remains configurable via `jenga.cli.json` `matchThreshold`

## Definition of Done

- [ ] "let's plan a new feature" routes to `brainstorm` or `do` with confidence ≥ 0.75 (no keyword overlap required)
- [ ] Routing completes in < 200ms per call after model warm-up
- [ ] Existing keyword-match behaviour is preserved and not regressed
