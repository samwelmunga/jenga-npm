# E11_S06 — Intent Classification Model: Execution Plan

## Objective
Implement semantic similarity scoring in the router using `@xenova/transformers` (`Xenova/all-MiniLM-L6-v2`), blended with the existing keyword matching pipeline.

## Tasks

### T01 — Install @xenova/transformers and scaffold embedder module
- Add `@xenova/transformers` to `package.json` dependencies and run `npm install`
- Create `mcp/router/embedder.js` exporting:
  - `warmUp()` — loads the `feature-extraction` pipeline, no-op if already loaded
  - `embed(text)` — returns a `Float32Array` of length 384

### T02 — Pre-compute and cache skill description embeddings at index-build time
- Make `buildSkillIndex` async and accept optional `embedder` param
- Compute `skill.embedding` for each skill at index build time
- Update `index.js` to `await warmUp()` and pass `{ embed }` to `buildSkillIndex`
- Also update `reload_skills` handler to use async pattern

### T03 — Integrate semantic cosine similarity into matcher.js scoring pipeline
- Add private `cosineSimilarity(a, b)` helper in `matcher.js`
- Update `findBestMatch` to accept `promptEmbedding` as 4th arg
- Blend: `0.4 * keywordScore + 0.6 * semanticScore` when both embeddings present
- Fall back to keyword-only when either embedding is null
- In `index.js` `route_prompt`, compute prompt embedding before matching

## Key Design Decisions
- Embedder is a singleton (`_pipe`) — warm once at startup
- Cosine similarity result clamped to [0, 1] (normalized vectors should always be ≥ 0)
- Passthrough rule (`text.startsWith("/")`) fires before any embedding — no regression
- Keyword fallback preserved when embeddings are null (e.g., during testing)
