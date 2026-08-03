---
id: E08_S04
epic_id: E08
title: SAD Map Interactivity
status: Done
date_started: 2026-05-05
date_completed: 2026-05-05
tasks: [E08_S04_T01]
---

# Story: SAD Map Interactivity

As a user, I want to click nodes on the SAD map to focus on a specific item and its direct connections, so I can explore the architecture diagram without being overwhelmed by the full graph.

## Acceptance Criteria
- [ ] Clicking a node selects it and filters the diagram to show only that node and its directly connected nodes/edges
- [ ] Clicking the same selected node deselects it and restores the full diagram
- [ ] Clicking a different node while one is already selected switches selection to the new node
- [ ] Hovering over any node shows a pointer cursor

## Definition of Done
- [ ] Selection state is managed in SADMap component (no external state needed)
- [ ] Filtered view correctly shows only the selected node and its immediate neighbours
- [ ] Deselection restores the original full diagram
- [ ] Pointer cursor applied via CSS on node elements
