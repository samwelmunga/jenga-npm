---
id: E18_S03_T01
story_id: E18_S03
epic_id: E18
title: Update parallel-tasks.md to mention /jenga
status: Passed
date_created: 2026-07-10
date_started:
date_completed: 2026-07-10
---

# Task: Update parallel-tasks.md to mention /jenga

## Description

The `project/.wiki/concepts/parallel-tasks.md` concept card covers `/dooo` as the parallel orchestrator but entirely omits `/jenga`, which also runs independent tasks in parallel as part of its Phase 4 loop.

This task updates the page to acknowledge `/jenga` and draw a clear distinction between the two tools.

## File to Edit

`project/.wiki/concepts/parallel-tasks.md`

## Acceptance Criteria

- [ ] `/jenga` is mentioned in `parallel-tasks.md`
- [ ] A clear distinction is drawn between `/dooo` (interactive, user selects tasks) and `/jenga` (fully automated, board-wide)
- [ ] The "When Not to Use `/dooo`" section (or an equivalent) mentions `/jenga` as the hands-free alternative when you want full-board automation
- [ ] A brief description of `/jenga`'s Phase 4 parallel execution mechanics is included (background sub-agents, dependency resolution)
- [ ] All existing content about `/dooo`, `/reconcile`, and sub-agent sessions is preserved unchanged
- [ ] No broken links introduced

## Reference

Evaluation rapport: `project/rapports/analysis/mention-jenga-in-parallel-tasks-eval.md`
