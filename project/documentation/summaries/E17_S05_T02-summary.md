# E17_S05_T02 — Execution Summary

## What was done
Created `.agents/skills/reconcile-origin/SKILL.md` with the required frontmatter and instructions that delegate mutating git work to the script.

## Delivered behaviour
- Defines the `reconcile-origin` skill with the required description, keywords, and examples
- Documents branch selection and clean-working-tree preflight handling
- Instructs the agent to invoke the script and parse JSON statuses
- Covers success, conflict, handled-later, missing-local-branch, and error responses
- Presents conflict-resolution options in the required numbered format, with “Handle it later” as the final actionable option

## Notes
The skill keeps the required preflight cleanliness check explicit while routing all mutating git operations through the script.

## Commit
- `9141072` — `task(E17_S05_T02): add reconcile-origin skill definition`
