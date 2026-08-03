# E17_S05_T02 — Execution Plan

## Task
Create `.agents/skills/reconcile-origin/SKILL.md` with required frontmatter and instructions that delegate all git work to the shell script.

## Implementation Approach
1. Reuse the required YAML frontmatter exactly.
2. Write the skill body so it determines the branch argument, checks working tree cleanliness, and invokes the script instead of running inline git commands.
3. Document how the agent should interpret JSON statuses for success, conflict, missing local branch, and error conditions.
4. Include structured user-facing conflict handling with at least two resolution options plus a final handle-later option that re-invokes the script.

## Files to Change
| File | Planned Change |
|------|----------------|
| `.agents/skills/reconcile-origin/SKILL.md` | New skill definition delegating git logic to the script |

## Dependencies & Risks
- Must avoid embedding inline git operations in the skill body.
- Needs to align with actual script output statuses so the workflow is executable.

## Notes
The skill will document option-list formatting consistent with project interaction rules.
