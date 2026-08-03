---
id: E08_S03_T01
story_id: E08_S03
epic_id: E08
title: Extend Architecture Parser with SAD Map Data
status: Done
date_created: 2026-05-05
date_started:
date_completed:
assigned_to: developer
---

# Task: Extend Architecture Parser with SAD Map Data

## Description
Extend the existing `project/app/api/parsers/architecture.js` to also parse local project files and produce a Software Architecture Diagram (SAD) map — a graph of service/component **nodes** and directional **edges** (connections) between them.

Data sources to parse (skip if missing — no network calls):
- `project/board/epics/` — each epic becomes a top-level component node (type: `epic`)
- `project/board/stories/` — each story becomes a child node linked to its parent epic (type: `story`)
- `project.config.json` — any `services`, `components`, or `integrations` arrays become additional nodes
- `package.json` — key runtime dependencies (express, react, etc.) become dependency nodes (type: `dependency`)

**Output shape** to add to the return value of `parseArchitecture()`:

```js
sad_map: {
  nodes: [
    { id: string, label: string, type: "epic" | "story" | "service" | "dependency" }
  ],
  edges: [
    { from: string, to: string, label?: string }
  ]
}
```

Node `id` should be the epic/story ID (e.g. `E08`, `E08_S01`) or the package/service name.
Edges connect:
- epic → its stories
- story → its tasks (if tasks are listed in front-matter)
- Any `integrations` or `components` in project.config.json → their declared dependencies

## Prerequisites
- None (extends existing parser in place)

## Acceptance Criteria
- [ ] `parseArchitecture()` return value now includes a `sad_map` key
- [ ] `sad_map.nodes` contains at minimum one node per parsed epic
- [ ] `sad_map.edges` contains at minimum one edge per epic→story relationship found
- [ ] Runtime dependency nodes are included from `package.json`
- [ ] Missing files are skipped without throwing
- [ ] No external network requests are made
- [ ] Existing `tech_stack` and `dependencies` output is unchanged
