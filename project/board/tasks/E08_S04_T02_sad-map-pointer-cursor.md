---
id: E08_S04_T02
story_id: E08_S04
epic_id: E08
title: SAD Map pointer cursor on hover
status: Done
date_created: 2026-05-05
---

# Task: SAD Map pointer cursor on hover

Add a pointer cursor to node groups in `SADMap.jsx` and the supporting CSS so users get a clear affordance that nodes are clickable.

- Set `cursor: pointer` on each node `<g>` element (either via inline style or a CSS class)
- Ensure the cursor applies over the rect and text within the node

## Acceptance Criteria
- [ ] Hovering any node shows a pointer cursor
- [ ] Cursor style does not affect the background or edge lines
