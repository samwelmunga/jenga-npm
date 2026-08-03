---
id: E08_S04_T01
story_id: E08_S04
epic_id: E08
title: SAD Map node selection state and filtered view
status: Done
date_created: 2026-05-05
---

# Task: SAD Map node selection state and filtered view

Implement click-to-select behaviour in `SADMap.jsx`:

- Add `selectedId` state (useState, default null)
- Clicking a node sets `selectedId` to that node's id; clicking the same node clears it to null
- Clicking a different node while one is selected switches `selectedId`
- When `selectedId` is set, compute a filtered set: the selected node + any node directly connected to it via `edges` (either as `from` or `to`), and only render those nodes and the edges between them
- When no node is selected, render the full diagram as before

## Acceptance Criteria
- [ ] Clicking a node selects it; the diagram filters to that node and its direct neighbours
- [ ] Clicking the selected node deselects it; full diagram restored
- [ ] Clicking a different node while one is selected switches selection
- [ ] Filtered edges are only those connecting nodes in the visible subset
