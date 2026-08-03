---
id: E08_S03_T03
story_id: E08_S03
epic_id: E08
title: Build SADMap SVG React Component
status: Done
date_created: 2026-05-05
date_started:
date_completed:
assigned_to: developer
---

# Task: Build SADMap SVG React Component

## Description
Create `project/app/ui/src/components/architecture/SADMap.jsx` — a React component that renders a Software Architecture Diagram as an SVG graph (boxes and arrows). No third-party diagram library — use inline SVG.

**Props:**
```js
SADMap({ nodes, edges })
// nodes: [{ id, label, type }]
// edges: [{ from, to, label? }]
```

**Layout approach (simple, no physics):**
- Lay nodes out in a grid or layered top-down arrangement (calculate (x, y) per node from index)
- Render each node as a `<rect>` + `<text>` label
- Render each edge as a `<line>` or `<path>` with an arrowhead marker
- Color-code by node `type` (epic = blue, story = green, service = purple, dependency = grey)

**Empty / error state:**
- If `nodes` is empty or nullish, render a `<p className="sad-empty">No architecture map data available.</p>`

**Styles:**
- Add SAD map styles to the existing `architecture.css`

## Prerequisites
- None (standalone component, can be built in parallel with T01/T02)

## Acceptance Criteria
- [ ] `SADMap.jsx` exists in `src/components/architecture/`
- [ ] Component renders an SVG with at least one `<rect>` per node and one `<line>`/`<path>` per edge when data is present
- [ ] Each node displays its `label` text
- [ ] Arrowheads are visible on edges
- [ ] Node fill colour varies by `type`
- [ ] Empty state renders without errors
- [ ] No new npm dependencies added
