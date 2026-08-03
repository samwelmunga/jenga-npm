# Plan: E02_S02 — /spinoff Skill

## Objective
Create the `/spinoff` skill that allows users to formally capture a diverging topic mid-conversation, and update E02_S01 to reference `/spinoff` as the recommended invocation path.

## Files to Create
- `skills/spinoff/SKILL.md` — the new skill

## Files to Modify
- `project/board/stories/E02_S01_subject-divergence-detection.md` — add `/spinoff` reference
- `project/board/stories/E02_S02_spinoff-skill.md` — update status
- `project/logs/events.json` — append sender object
- `project/documentation/summaries/E02_S02-summary.md` — execution summary

## Design Decisions
- Follow existing skill conventions: YAML front-matter, `metadata.prefered_agent`, numbered instruction steps
- Skill delegates to `/brainstorm` and `/todo` rather than reimplementing their logic
- E02_S01 gets a new "## Recommended Invocation" section pointing to `/spinoff`
- The flow is: detect divergence → `/spinoff` → (optional `/brainstorm`) → `/todo` → resume primary thread
