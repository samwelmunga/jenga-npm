---
id: E20_S03
epic_id: E20
title: Agent Integration — Context Injection, Impact Analysis & Summary Frontmatter
status: Pending
date_created: 2026-07-10
date_started:
date_completed:
tasks: []
---

# Story: Agent Integration — Context Injection, Impact Analysis & Summary Frontmatter

As an AI agent, I want to query and update the knowledge graph during normal task execution so that I have richer context about what I am touching and what depends on it.

## Acceptance Criteria
- [ ] `templates/EXECUTION_SUMMARY_TEMPLATE.md` is updated to include `affected_nodes` and `changed_edges` frontmatter fields
- [ ] `affected_nodes` and `changed_edges` are **fully automated** — derived exclusively from AST diffs by the indexing pipeline. Agents do not write or annotate these fields; they are read-only consumers of pipeline output
- [ ] The summary frontmatter fields are populated by a post-commit pipeline step that writes them back to the relevant summary file after resolving affected symbols
- [ ] Developer agent instructions (`agents/developer.md`) include a "Knowledge Graph" section covering:
  - Query the subgraph for the task's files/services at task start (context injection)
  - Run an impact analysis query ("what depends on nodes I am about to change") before implementing
  - Write `affected_nodes` and `changed_edges` to the summary as AST-derived hints
- [ ] Tester agent instructions (`agents/tester.md`) include a "Knowledge Graph" section covering:
  - Cross-reference `affected_nodes` from the summary against graph nodes
  - Promote verified nodes/edges from `draft` to `verified` in Kuzu after test pass
  - Flag discrepancies as a `graph_discrepancy` remark in the test analysis rapport
- [ ] Scrum master agent instructions (`agents/scrum-master.md`) include a "Knowledge Graph" section covering:
  - At session start: load the relevant subgraph slice for services mentioned in trigger payloads
  - Surface impacted services when creating backlog items from problem rapports
- [ ] A `lib/` helper (JS or shell) wraps common Cypher queries: `getSubgraph(service)`, `getDependents(nodeId)`, `upsertNode(node)`, `upsertEdge(edge)`, `promoteToVerified(nodeId)`
- [ ] `workflow.json` paths block is extended with `knowledge_graph` and `knowledge_graph_db` path entries

## Definition of Done
- [ ] Developer agent can query subgraph before implementing a task and the query returns meaningful results on a populated graph
- [ ] Tester agent promotes at least one node to `verified` status during a test pass on a graph-enabled project
- [ ] Scrum master loads subgraph context when processing a `rapport_review` trigger that references a known service
- [ ] Helper lib has unit-level tests or at minimum a usage example in documentation
