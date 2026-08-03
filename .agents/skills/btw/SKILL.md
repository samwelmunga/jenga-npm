---
name: btw
description: Capture a new mission (feature, change, or addition) and fit it into the project's Epic/Story structure, then choose to implement now or defer.
keywords:
  - btw
  - capture
  - mission
  - new idea
  - side task
examples:
  - "btw I also need to add X"
  - "capture this as a new task"
metadata: 
  prefered_agent: scrum-master
---

# BTW — Capture a Mission

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
