---
id: E11_S06_T03
story_id: E11_S06
epic_id: E11
title: Integrate semantic cosine similarity into matcher.js scoring pipeline
status: Pending
date_created: 2026-05-11
---

# Task: Integrate semantic cosine similarity into matcher.js scoring pipeline

## What to do

Update `mcp/router/matcher.js` to add a semantic scoring step:

1. Add a private `cosineSimilarity(a, b)` helper that computes the dot product of two `Float32Array` vectors divided by the product of their L2 norms. Returns a value in [-1, 1].

2. Update `findBestMatch` to accept an optional fourth argument `promptEmbedding` (a `Float32Array`, or null/undefined).
   - If `promptEmbedding` is provided **and** a skill has a non-null `embedding`, compute `semanticScore = cosineSimilarity(promptEmbedding, skill.embedding)` (clamped to [0, 1]).
   - Blend with the keyword score using a weighted average: `finalScore = 0.4 * keywordScore + 0.6 * semanticScore`.
   - If no `promptEmbedding` is provided (or the skill has no embedding), fall back to the keyword-only score unchanged — do not regress existing behaviour.

3. Update `mcp/router/index.js` — in the `route_prompt` tool handler, before calling `findBestMatch`:
   - Import `embed` from `./embedder.js`
   - Call `const promptEmbedding = await embed(text)` (model is already warm)
   - Pass `promptEmbedding` as the fourth argument to `findBestMatch`

## Acceptance Criteria
- [ ] `cosineSimilarity` is not exported (internal helper only)
- [ ] When `promptEmbedding` is null/undefined, `findBestMatch` behaves identically to its current implementation
- [ ] When `promptEmbedding` is provided, the blended score is used
- [ ] "let's plan a new feature" returns a match for `brainstorm` or `do` with confidence ≥ 0.75
- [ ] "/brainstorm" still returns `action: "passthrough"` (passthrough rule fires before embedding)
- [ ] Routing completes in < 200ms after warm-up (embedding call is fast on cached model)
