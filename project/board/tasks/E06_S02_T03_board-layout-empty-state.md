---
id: E06_S02_T03
story_id: E06_S02
epic_id: E06
title: Implement board layout and empty state
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Implement board layout and empty state

## Description
Create the `<BoardView />` layout component that receives the full board data array and renders epics grouped in columns or stacked sections. Use CSS flexbox or grid for the layout so epics sit side-by-side (columns) on wide screens and stack vertically on narrow screens. When the board data is an empty array (no epics), render a friendly empty-state message (e.g. "No epics found. Run `/init` to get started.") instead of a blank page. Wire `<BoardView />` into the Board tab as the success-state child of the data-fetching component.

## Prerequisites
- E06_S02_T01 (data fetching) must be complete.
- E06_S02_T02 (card components) must be complete.

## Acceptance Criteria
- [ ] `<BoardView />` renders one `<EpicCard />` per epic in the data
- [ ] Epics are laid out in columns (flex/grid) on wide viewports and stack on narrow ones
- [ ] An empty-state message is rendered when the epics array is empty
- [ ] The empty-state message does not appear when data is loading or errored (only on successful empty response)
- [ ] `<BoardView />` is used as the success-state child of the Board tab
