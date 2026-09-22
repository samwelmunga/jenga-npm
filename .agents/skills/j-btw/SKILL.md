---
name: j.btw
description: Capture a new mission (feature, change, or addition) and fit it into the project's Epic/Story structure, then choose to implement now or defer.
keywords:
  - btw
  - capture
  - mission
  - new idea
  - side task
  - j-btw
examples:
  - "btw I also need to add X"
  - "capture this as a new task"
  - "j-btw"
metadata: 
  prefered_agent: scrum-master
---

# BTW — Capture a Mission

`skills/j-btw/` is the **canonical, hand-edited** directory for this skill, per CLAUDE.md's "The Canonical Naming Contract" (the `E50` reopening of 2026-09-09, which promoted `skills/j-btw/` from generated twin to sole canonical form). The `j-` prefix is there for collision safety — a real directory under a distinct name, so a host tool shipping its own same-named built-in command cannot shadow it (Claude Code's native skill resolution is a literal-string, directory-name-based match; see `docs/skill-authoring.md`'s "Invocation Convention").

> ⚠️ **`scripts/generate-j-alias.sh` was retired by `E50_S14` and no longer exists — there is nothing to run.** This file was previously generated from a bare `skills/btw/SKILL.md` source; `E50_S15` deleted that directory. This file is now the sole canonical, hand-edited source for this skill — edit it directly.

## Instructions

1. **Gather mission details** — Ask the user:
   - Where do you want to do this?
   - What would you like to do?
   - What is the goal?

2. **Classify the mission** — Based on the description, determine if it fits into:
   - An existing story
   - A new story inside an existing Epic
   - A new story inside a new Epic

3. **Update project documentation** — Add the mission to the appropriate board files:
   - **New story**: create a file in `project/board/stories/` using `../pi-plan/assets/story_template.md` as the structure.
   - **New epic**: append a new Epic object to `project/PROJECT_SUMMARY.md` using the schema in `../pi-plan/assets/epic.json`.
   - **Existing story**: append the new task or acceptance criterion to the matching file in `project/board/stories/`.

4. **Ask the user: "now" or "later"?**
   - If **"now"** — Produce a plan for the first story related to the mission and begin implementation.
   - If **"later"** — Confirm the mission has been recorded and resume the previous workflow.

## Examples
- `/btw` — Start the interactive mission capture flow
- `/btw add a dark mode toggle to the settings page` — Pre-fill the "what" and jump into classification
