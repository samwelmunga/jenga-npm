# Execution Plan: Throwaway extractor prototype

**Task ID:** E25_S01_T01
**Story ID:** E25_S01
**Epic ID:** E25
**Date:** 2026-07-23
**Agent:** developer
**Session ID:** 4832cd66-1151-4980-94dc-c61f78f0497f

---

## Task Summary

Build a deterministic throwaway extractor script under `scripts/` that walks board markdown, plan/summary markdown, and `project/todo.md`, then emits a single JSON object with `nodes` and `edges` for the six required artifact types and four required edge types.

## Implementation Approach

1. Inspect representative epic, story, task, plan, summary, and todo formats to confirm the happy-path fields the spike needs.
2. Implement a self-contained Python 3 script with the required `# THROWAWAY` banner, lightweight frontmatter parsing, deterministic file ordering, and stable JSON ordering.
3. Derive `contains`, `plans`, `summarizes`, and `queued_as` edges from frontmatter and filename / todo reference conventions.
4. Validate the script by running it twice against `project/`, checking exit status, JSON validity, determinism, and coverage of all required node and edge types.
5. Write the execution summary documenting files changed, validation performed, and acceptance-criteria coverage.

## Files to Change

| File | Planned Change |
|------|----------------|
| `project/documentation/plans/E25_S01_T01-plan.md` | Add this execution plan |
| `scripts/e25_s01_extract_board_graph.py` | Add throwaway extractor prototype |
| `project/documentation/summaries/E25_S01_T01-summary.md` | Add execution summary after implementation |
| `project/logs/events.json` | Append task start event |

## Risks & Notes

- `project/logs/events.json` currently mixes array-style JSON with JSONL-style append-only events; only append new lines, do not normalize the historical file during this spike.
- The extractor should stay tolerant and happy-path only; no dependency on PyYAML or other build/setup steps.
- Determinism will come from sorted filesystem traversal, normalized todo parsing, and `json.dumps(..., sort_keys=True)`.
