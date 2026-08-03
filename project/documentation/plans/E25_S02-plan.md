# Execution Plan: E25_S02 — Library skeleton & node/edge extraction

**Task ID:** E25_S02
**Story ID:** E25_S02
**Epic ID:** E25
**Date:** 2026-07-23 (UTC)
**Agent:** developer
**Session ID:** c2fa9694-5596-4801-864b-8abab5461747

---

## Task Summary
Build the first production board-index library in the canonical root `skills/index/scripts/` path, expose shell-callable `graph::nodes` and `graph::edges` entry points, extract all v1 node and edge types from board/documentation/todo/skill/agent artifacts, add a smoke-test script, confirm S01 throwaway scripts remain isolated, and prepare the story for tester verification.

---

## Implementation Approach

1. Create the canonical `skills/index/scripts/` scaffold with a thin `board-index` bash shim and a Python stdlib-only CLI module.
2. Implement a tolerant frontmatter/file walker that only reads approved paths and can emit stubbed then real JSON arrays for nodes and edges.
3. Add Epic/Story/Task extraction first, including `contains` edges and optional frontmatter capture for later derivations.
4. Extend extraction to plans, summaries, loose docs, todo entries, skills, and agents, plus `plans`, `summarizes`, and `queued_as` edges.
5. Derive optional edges (`mentions_skill`, `mentions_agent`, `depends_on`, `blocks`, `parent_doc`) with graceful degradation for missing or malformed metadata.
6. Add `smoke_test.sh`, verify the library against the real board, confirm throwaway S01 scripts stay marked and unimported, and update the story AC notes if verification succeeds.
7. Write the execution summary, record milestone commits, create the required handoff payload, and invoke the tester with commit SHAs and worktree context.

---

## Files to Change

| File | Planned Change |
|------|----------------|
| `project/documentation/plans/E25_S02-plan.md` | Record the execution plan for the story implementation. |
| `skills/index/scripts/board_index.py` | Implement the shell-callable board index extractor and CLI. |
| `skills/index/scripts/board-index` | Add executable bash shim for the Python entry point. |
| `skills/index/scripts/smoke_test.sh` | Add real-board smoke test coverage for nodes and edges. |
| `project/board/stories/E25_S02_library-skeleton-and-node-edge-extraction.md` | Reflect completed smoke-test verification notes if needed. |
| `project/documentation/summaries/E25_S02-summary.md` | Summarize implementation, files changed, commits, and tester notes. |
| `project/queue/.session_handoff.json` | Record mandatory developer handoff metadata before session end. |

---

## Dependencies & Risks

- No third-party Python packages may be introduced; parsing must stay within stdlib limits.
- `.agents/` and `.claude/` are generated outputs, so new implementation files must be created only in canonical root paths.
- Frontmatter across board/docs files is semi-structured; parser tolerance is essential to avoid extraction failures.
- Skills and agents exist in both canonical and generated trees, so duplicate identifiers must be handled predictably.
- The story asks for smoke-test verification while the broader workflow reserves testing for the tester; implementation will keep validation scoped to the requested smoke test and leave broader acceptance to the tester.

---

## Notes

- The library will walk only `project/`, `skills/`, `.agents/`, and `agents/`.
- S01 spike scripts must remain isolated and must not be imported by the production library.
- Commit messages will follow the project’s story-level EST naming convention.
