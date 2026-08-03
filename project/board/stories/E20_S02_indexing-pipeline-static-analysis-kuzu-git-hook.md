---
id: E20_S02
epic_id: E20
title: Indexing Pipeline — Static Analysis, Kuzu DB & Git Hook
status: Pending
date_created: 2026-07-10
date_started:
date_completed:
tasks: []
---

# Story: Indexing Pipeline — Static Analysis, Kuzu DB & Git Hook

As a JengaAgent developer, I want an automated indexing pipeline that extracts function-level nodes and edges from source code and stores them in Kuzu, so that the fine-grained graph stays current without manual agent effort.

## Acceptance Criteria
- [ ] `scripts/index-knowledge-graph.sh` is the single entry point for the indexing pipeline
- [ ] Pipeline uses tree-sitter to parse changed files into ASTs (JS/TS supported at launch)
- [ ] Pipeline uses ast-grep patterns (`.sgm` files) or hand-rolled `.scm` tree-sitter query walkers to extract symbols and relationships
- [ ] Symbol-level diff is performed using git diff + tree-sitter span mapping; changed nodes are marked `draft`
- [ ] Kuzu embedded DB is initialised at `project/knowledge-graph/kuzu/` with a defined node and edge schema matching the JSON schema from S01
- [ ] Kuzu upsert is idempotent — running the pipeline twice on the same commit produces no duplicate nodes/edges
- [ ] Nodes have stable git-object-based IDs derived from the blob SHA of the symbol's first introduction into the repository. Renames and file moves update node metadata (`file`, `label`) but do not change the ID
- [ ] When a symbol is first introduced, the pipeline resolves its first-commit blob SHA via `git log --diff-filter=A` and stores it as the node ID seed
- [ ] Anonymous functions and framework-generated endpoints are mapped to coarse-level parent nodes rather than assigned false-precision fine-grained IDs
- [ ] `hooks/post-commit` fires `scripts/index-knowledge-graph.sh` on every commit; hook is registered by `/init`
- [ ] Hook is non-blocking: if indexing exceeds a configurable time budget (default 10s), it marks affected nodes `stale` and exits 0 — it never blocks the commit
- [ ] A fallback mode runs the pipeline asynchronously (e.g., as a background job) when the time budget is exceeded
- [ ] Supported languages at launch: JavaScript, TypeScript, Python; with framework-specific extraction patterns for Express, NestJS, Next.js (JS/TS) and FastAPI, Django (Python)
- [ ] Unsupported file types are logged and skipped with a clear `[SKIP] unsupported language: <ext>` message
- [ ] A `project/knowledge-graph/SUPPORTED_STACKS.md` file documents supported grammars, framework extractors, and known unsupported patterns

## Definition of Done
- [ ] Running `scripts/index-knowledge-graph.sh` on a JS/TS project populates Kuzu with nodes and edges
- [ ] git commit on a JS/TS project fires the hook and updates the graph within the time budget
- [ ] Duplicate-safe: running pipeline twice produces identical graph state
- [ ] Stable IDs survive a symbol rename (old node marked stale, new node created with provenance link)
