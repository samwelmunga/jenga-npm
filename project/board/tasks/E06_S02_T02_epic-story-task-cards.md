---
id: E06_S02_T02
story_id: E06_S02
epic_id: E06
title: Implement Epic/Story/Task card components
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Implement Epic/Story/Task card components

## Description
Create three card components: `<EpicCard />`, `<StoryCard />`, and `<TaskCard />`. Each component receives its respective data object as a prop and renders the title, ID, and status. Status must be visually indicated — use a colour-coded badge or icon (e.g. Pending = grey, In Progress = blue, Done = green, Blocked = red). Cards are purely presentational with no click handlers or editable fields. `<EpicCard />` contains a list of `<StoryCard />` components; `<StoryCard />` contains a list of `<TaskCard />` components.

## Prerequisites
- E06_S02_T01 (data fetching) should be in progress or complete so real data shapes are known.

## Acceptance Criteria
- [ ] `<EpicCard />`, `<StoryCard />`, and `<TaskCard />` components exist in `dashboard/src/components/`
- [ ] Each card displays: ID, title, and status
- [ ] Status is indicated by a colour-coded badge (at minimum 4 colours: pending, in-progress, done, blocked)
- [ ] Cards are read-only — no inputs, buttons, or drag handles
- [ ] Components compose correctly: Epic → Stories → Tasks
