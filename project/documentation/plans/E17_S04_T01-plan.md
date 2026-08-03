# Plan: E17_S04_T01 — Update /commit skill to invoke /reconcile as initial step

## Objective
Modify `skills/commit/SKILL.md` so that `/reconcile` is invoked as step 1 of the commit flow, before any other action.

## Approach
- Prepend a new step 1 to the commit instructions that invokes `/reconcile`
- Describe both outcomes: drift found (inform user, confirm before continuing) and no drift (continue silently)
- Renumber the existing steps (previously 1–3 → now 2–4)

## Files Changed
- `.agents/skills/commit/SKILL.md`

## Risk
Low — additive change; existing steps are preserved and only renumbered.
