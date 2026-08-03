# Plan: E08_S03_T03 — Build SADMap SVG React Component

## Approach
Create `project/app/ui/src/components/architecture/SADMap.jsx`:
1. Accept `nodes` and `edges` props
2. Use `layoutNodes()` to position nodes grouped by type (epic, story, service, dependency)
3. Render inline SVG with `<rect>` + `<text>` for nodes, `<line>` with arrow markers for edges
4. Colour-code nodes by type (blue=epic, green=story, purple=service, grey=dependency)
5. Truncate long labels to 18 chars
6. Handle empty/null props gracefully with a placeholder message

Also append SAD map CSS rules to `architecture.css`.
