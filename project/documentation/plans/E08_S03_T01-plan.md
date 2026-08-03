# Plan: E08_S03_T01 — Extend Architecture Parser with SAD Map Data

## Approach
Extend `parseArchitecture()` in `project/app/api/parsers/architecture.js` to:
1. Read all epic markdown files from `project/board/epics/`
2. Read all story markdown files from `project/board/stories/`
3. Build nodes array (epics, stories, key runtime deps from package.json)
4. Build edges array (epic→story relationships + package.json runtime deps as dependency nodes linked to a root project node)
5. Return `sad_map: { nodes, edges }` alongside existing tech_stack and dependencies

## Key Details
- Use `gray-matter` (already installed) to parse front-matter from epic/story markdown files
- Key deps to include as nodes: express, react, react-dom, vite, cors, gray-matter
- Epic nodes: type "epic", id from front-matter `id` field, label from `title`
- Story nodes: type "story", id from front-matter `id` field, label from `title`
- Dependency nodes: type "dependency", id = dep name, label = dep name
- Root project node: type "service", id = package.json `name`, label = package.json `name`
- Edges: epic→story for each story listed in epic's `stories` array; root→dependency for each key dep
- Handle errors gracefully — return `sad_map: { nodes: [], edges: [] }` on failure
