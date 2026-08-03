# E03_S01 Implementation Plan — /dooo Parallel Execution Orchestrator

## Objective
Create the `/dooo` skill that wraps `/do` with a parallelism loop, allowing the user to fan out multiple implementation sub-agents simultaneously.

## Steps

1. **Update `workflow.json`**
   - Add `"Running"` to the `statuses` array so board files can track in-flight implementations.

2. **Scaffold `skills/dooo/SKILL.md`**
   - Create `skills/dooo/SKILL.md` following the same front-matter conventions as `skills/do/SKILL.md`.
   - Body describes the orchestration loop: invoke `/do`, mark started task as `Running`, read board for eligible parallel tasks, present choices, loop until "Done".

3. **Mirror to `.agents/skills/dooo/SKILL.md`**
   - Identical content to `skills/dooo/SKILL.md` (canonical definition used by skill loader).

4. **Update board statuses**
   - Story `E03_S01`: `Pending` → `In Progress`
   - Epic `E03`: `Pending` → `In Progress`

5. **Write documentation**
   - Plan: `project/documentation/plans/E03_S01-plan.md` (this file)
   - Summary: `project/documentation/summaries/E03_S01-summary.md`

6. **Help skill**
   - The `/help` skill uses dynamic MCP discovery, so no manual listing update is needed.
