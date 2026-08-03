---
id: E20_S01
epic_id: E20
title: Schema, Templates & Coarse Graph Foundation
status: Pending
date_created: 2026-07-10
date_started:
date_completed:
tasks: []
---

# Story: Schema, Templates & Coarse Graph Foundation

As a JengaAgent developer, I want a standardised schema and templates for the knowledge graph so that all agents produce consistent, validated graph data from day one.

## Acceptance Criteria
- [ ] `templates/KNOWLEDGE_GRAPH_NODE_TEMPLATE.json` exists with all required fields (`id`, `type`, `label`, `function`, `module`, `service`, `file`, `description`, `data_in`, `data_out`, `tags`, `status`)
- [ ] `templates/KNOWLEDGE_GRAPH_EDGE_TEMPLATE.json` exists with all required fields (`id`, `from`, `to`, `type`, `data`, `description`, `status`)
- [ ] `templates/KNOWLEDGE_GRAPH_SCHEMA_TEMPLATE.json` is a reusable JSON Schema definition that projects copy into `project/knowledge-graph/schema.json`
- [ ] `project/knowledge-graph/graph.json` is scaffolded by `/init` with an empty but valid coarse-tier structure (nodes: [], edges: [])
- [ ] `scripts/validate-knowledge-graph.sh` validates `graph.json` against its schema and exits non-zero with a descriptive error on failure
- [ ] Node `type` enum is enforced: `function | service | module | api_endpoint | database | external`
- [ ] Edge `type` enum is enforced: `writes_to | reads_from | calls | transforms | depends_on | triggers`
- [ ] Node and edge `status` enum is enforced: `draft | verified | stale`
- [ ] `project/knowledge-graph/kuzu/` is added to `.gitignore`

## Definition of Done
- [ ] Templates exist under `templates/` and are referenced in the framework documentation
- [ ] Validation script passes on a valid file and fails with a clear message on an invalid one
- [ ] `/init` scaffolds `project/knowledge-graph/graph.json` automatically for new projects
- [ ] Schema template is documented in `project/documentation/`
