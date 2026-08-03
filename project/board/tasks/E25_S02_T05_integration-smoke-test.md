---
id: E25_S02_T05
story_id: E25_S02
epic_id: E25
title: Integration smoke test against real board
status: Passed
date_created: 2026-07-23
date_started: 2026-07-23
date_completed: 2026-07-23
dates_previously_completed:
reopened_on:
reopened_reason:
---

# Task: Integration smoke test against real board

## Description

Run the completed library against the real board and verify the output is valid, non-trivially-populated JSON with node counts in the expected ranges (based on S01 measurement report numbers ± 10% growth tolerance).

Write a small smoke-test script `skills/index/scripts/smoke_test.sh` that:
1. Runs `board-index graph::nodes` and pipes to `python3 -m json.tool` — must exit 0
2. Runs `board-index graph::edges` and pipes to `python3 -m json.tool` — must exit 0
3. Asserts node counts are within acceptable ranges (load from a config or hardcode with comments):
   - Epic nodes: ≥ 22
   - Story nodes: ≥ 90
   - Task nodes: ≥ 150
   - TodoEntry nodes: ≥ 10
   - Skill nodes: ≥ 5
   - Agent nodes: ≥ 2
4. Asserts `contains` edges are non-empty
5. Asserts `queued_as` edges are non-empty (todo.md has board refs)
6. Prints "SMOKE TEST PASSED" and exits 0 on success; prints failures and exits 1

Also verify:
- The library reads **only** expected paths (`project/`, `.agents/`, `skills/`) and does not touch `.env`, `node_modules`, `.git`, or application source dirs
- The S01 throwaway scripts are either deleted or still carry the `# THROWAWAY` marker and are not imported anywhere in the new library

Update the story's Acceptance Criteria checklist in `project/board/stories/E25_S02_library-skeleton-and-node-edge-extraction.md` to reflect the verified smoke test results.

## Acceptance Criteria
- [ ] `smoke_test.sh` exists at `skills/index/scripts/smoke_test.sh` and is executable
- [ ] `smoke_test.sh` exits 0 on the current real board
- [ ] All node count assertions pass
- [ ] `contains` and `queued_as` edge assertions pass
- [ ] No accidental reads outside `project/`, `.agents/`, `skills/` paths
- [ ] S01 throwaway scripts confirmed deleted or clearly marked THROWAWAY and not imported

## Definition of Done
- [ ] `smoke_test.sh` passes all assertions against the real board
- [ ] Library is confirmed safe (no stray reads)
- [ ] THROWAWAY scripts confirmed clean
- [ ] Story AC updated with verified smoke test results
