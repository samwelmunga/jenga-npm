---
id: E20
title: Knowledge Graph — Application Topology & Data Flow Mapping
status: Pending
date_created: 2026-07-10
date_started:
date_completed:
stories:
  - E20_S01
  - E20_S02
  - E20_S03
  - E20_S04
  - E20_S05
  - E20_S06
  - E20_S07
---

# Epic: Knowledge Graph — Application Topology & Data Flow Mapping

## Purpose
Add a per-project knowledge graph as a core JengaAgent framework component. The graph maps application topology (services, modules) and data flows (functions, edges, data types) at two tiers: a human-readable coarse graph (git-tracked JSON) and a queryable fine-grained graph (Kuzu embedded property graph DB). AI agents maintain the graph automatically through a static analysis pipeline, and use it for context injection and impact analysis during task execution. The graph complements existing documentation by tying components and data flows together into a living, machine-readable map of how an application functions.

## Definition of Done
- A validated `project/knowledge-graph/graph.json` exists with typed nodes and edges following the published JSON Schema
- Kuzu DB is populated by an automated extraction pipeline triggered on git commit
- Implementation summaries carry `affected_nodes` and `changed_edges` frontmatter fields
- Developer and tester agents query and update the graph as part of their normal workflow
- `on_session_end.sh` validates the graph, detects stale nodes, and writes `graph_update` triggers
- A benchmark suite measures extraction accuracy, node freshness, and task-outcome impact
- A DB migration job exports the graph to an external database
- A deferred-extensions story covers MCP server, visualization, and cross-project graph support
