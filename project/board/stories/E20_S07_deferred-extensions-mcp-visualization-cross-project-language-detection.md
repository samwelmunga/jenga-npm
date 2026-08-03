---
id: E20_S07
epic_id: E20
title: Deferred Extensions — MCP Server, Visualization, Cross-Project & Language Detection
status: Pending
date_created: 2026-07-10
date_started:
date_completed:
tasks: []
---

# Story: Deferred Extensions — MCP Server, Visualization, Cross-Project & Language Detection

As a JengaAgent framework consumer, I want the knowledge graph to offer richer interfaces and broader coverage beyond the initial JS/TS scope so that it scales to more complex setups and is accessible via standard tooling.

## Acceptance Criteria

### MCP Server
- [ ] `mcp/knowledge-graph/index.js` implements an MCP server exposing the following tools:
  - `get_node(id)` — retrieve a node by ID
  - `add_node(node)` — add a new node (validated against schema)
  - `update_node(id, patch)` — partial update a node
  - `get_edges(nodeId, direction?)` — retrieve edges for a node
  - `add_edge(edge)` — add a typed edge
  - `query_subgraph(filter)` — return a filtered subgraph (by service, module, tags, or quality dimensions)
- [ ] MCP server is documented in `mcp/knowledge-graph/README.md` and registered in `jenga.cli.json`
- [ ] MCP server reads from Kuzu via direct driver calls; write operations apply to both Kuzu and `graph.json`

### Visualization
- [ ] `scripts/render-knowledge-graph.sh` generates a Mermaid diagram from `graph.json` scoped to a service or the full coarse graph
- [ ] Output is saved to `project/knowledge-graph/graph.mmd` and optionally rendered to SVG if `mmdc` (Mermaid CLI) is available
- [ ] Diagram is regenerated as part of `scripts/reconcile-knowledge-graph.sh --render`

### Cross-Project Graphs
- [ ] A `jenga.config.json` option `knowledge_graph.cross_project` allows linking to another project's `graph.json` as a read-only dependency graph
- [ ] Cross-project nodes are tagged `source: external` and are never mutated by local agents

### Extended Language & Framework Coverage
- [ ] Additional language grammars beyond the initial JS/TS + Python scope are added here (e.g., Go, Java, Ruby)
- [ ] Additional framework-specific extractors beyond Express, NestJS, Next.js, FastAPI, Django are added here
- [ ] A plugin architecture with contract tests per language/framework adapter replaces the initial ad-hoc pattern files

## Definition of Done
- [ ] MCP server starts and responds to all six tool calls without error
- [ ] Mermaid diagram is generated from a populated `graph.json`
- [ ] Cross-project node linking works in a two-project test scenario
- [ ] Language auto-detection correctly selects grammar for `.js`, `.ts`, and `.py` files
