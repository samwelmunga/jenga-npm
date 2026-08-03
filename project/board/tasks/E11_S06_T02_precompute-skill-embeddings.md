---
id: E11_S06_T02
story_id: E11_S06
epic_id: E11
title: Pre-compute and cache skill description embeddings at index-build time
status: Pending
date_created: 2026-05-11
---

# Task: Pre-compute and cache skill description embeddings at index-build time

## What to do

1. Update `mcp/router/skill-index.js` — make `buildSkillIndex` async and accept an optional `embedder` argument. After each skill record is built, if `embedder` is provided, call `await embedder.embed(skill.description)` and store the result as `skill.embedding` (a `Float32Array`). If no description or embedder is provided, set `skill.embedding = null`.

2. Update `mcp/router/index.js`:
   - Import `warmUp` and `embed` from `./embedder.js`
   - Before building the skill index, call `await warmUp()` to load the model
   - Pass `{ embed }` as the embedder argument to `buildSkillIndex`
   - Update the `reload_skills` tool handler to also call `await warmUp()` before rebuilding (model will already be warm — no-op cost)

## Acceptance Criteria
- [ ] Each skill record in `skillIndex` has an `embedding` property (non-null `Float32Array`) after startup
- [ ] Router startup log shows model warm-up completing before skill indexing
- [ ] `reload_skills` tool correctly re-embeds descriptions on rebuild
- [ ] No change to the existing skill record fields (`name`, `description`, `keywords`, `examples`, `path`)
