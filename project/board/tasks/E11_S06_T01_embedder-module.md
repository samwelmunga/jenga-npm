---
id: E11_S06_T01
story_id: E11_S06
epic_id: E11
title: Install @xenova/transformers and scaffold embedder module
status: Pending
date_created: 2026-05-11
---

# Task: Install @xenova/transformers and scaffold embedder module

## What to do

1. Add `@xenova/transformers` to `package.json` dependencies and run `npm install`.
2. Create `mcp/router/embedder.js` that:
   - Imports `pipeline` from `@xenova/transformers`
   - Holds a module-level `_pipe` variable (null until warmed up)
   - Exports `warmUp()` — loads the `feature-extraction` pipeline for `Xenova/all-MiniLM-L6-v2` and assigns it to `_pipe`; safe to call multiple times (no-op if already loaded)
   - Exports `embed(text)` — calls `_pipe(text, { pooling: 'mean', normalize: true })` and returns the flat `Float32Array` of the embedding vector

## Acceptance Criteria
- [ ] `npm install` succeeds with `@xenova/transformers` present in `node_modules`
- [ ] `embedder.js` exports `warmUp` and `embed`
- [ ] Calling `warmUp()` twice does not reload the model
- [ ] `embed("hello world")` returns a `Float32Array` of length 384
