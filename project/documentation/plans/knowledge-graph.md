# Knowledge Graph for JengaAgent

## Core Concept
A per-project, two-tier knowledge graph that maps application topology (services, modules) and data flows (functions, edges, data types) — maintained automatically by AI agents through a static analysis pipeline, and used by agents for context injection and impact analysis during task execution.

---

## Architecture

### Tier 1 — Coarse Graph (human-readable, git-tracked)
- **Location**: `project/knowledge-graph/graph.json`
- **Scope**: Service and Module level nodes + their relationships
- **Format**: JSON with JSON Schema validation (`project/knowledge-graph/schema.json`)
- **Written by**: Agents (developer drafts → tester verifies → session-end reconciles)
- **Purpose**: Stable, inspectable topology map; serves as the "index" for the fine-grained layer

### Tier 2 — Fine Graph (queryable, generated)
- **Location**: `project/knowledge-graph/kuzu/` (Kuzu embedded property graph DB)
- **Scope**: Function-level nodes + typed edges — auto-extracted from source code
- **Query language**: Cypher, wrapped as agent tools
- **Built by**: The indexing pipeline triggered on every commit
- **Purpose**: Enables precise context injection and impact analysis queries

---

## Source → Graph Pipeline

```
Commit fired
     ↓
git post-commit hook
     ↓
scripts/index-knowledge-graph.sh
     ├─ tree-sitter  →  parse changed files into ASTs
     ├─ ast-grep (.sgm patterns) or .scm walker  →  extract symbols + relationships
     ├─ git diff + tree-sitter span mapping  →  identify what changed (symbol-level diff)
     └─ Kuzu driver  →  upsert nodes/edges; mark changed nodes as `draft`
```

---

## Node Schema

```json
{
  "id": "AuthService:createUser",
  "type": "function | service | module | api_endpoint | database | external",
  "label": "createUser",
  "function": "createUser",
  "module": null,
  "service": "AuthService",
  "file": "src/auth/auth.service.ts",
  "description": "Creates a new user in the database",
  "data_in": ["UserDTO"],
  "data_out": ["User"],
  "tags": ["auth", "write"],
  "status": "draft | verified | stale"
}
```

## Edge Schema

```json
{
  "id": "edge-AuthService:createUser→UsersDB:users",
  "from": "AuthService:createUser",
  "to": "UsersDB:users",
  "type": "writes_to | reads_from | calls | transforms | depends_on | triggers",
  "data": "User",
  "description": "Persists the new user record",
  "status": "draft | verified | stale"
}
```

---

## Implementation Summary Frontmatter Extension

Every `E##_S##_T##-summary.md` gets two new fields:

```yaml
affected_nodes:
  - "AuthService:createUser"
  - "UsersDB:users"
changed_edges:
  - "AuthService:createUser → writes_to → UsersDB:users"
```

This links fine-grained code changes back to board items — giving the graph provenance and giving agents a task-scoped entry point into the graph.

---

## Update Lifecycle

| Trigger | Agent / Hook | Action |
|---|---|---|
| Task implementation complete | Developer | Writes `affected_nodes` / `changed_edges` in summary frontmatter; marks nodes as `draft` in graph |
| Test pass | Tester | Verifies `affected_nodes` match implementation; promotes nodes to `verified` in Kuzu |
| `git commit` | `hooks/post-commit` | Triggers `scripts/index-knowledge-graph.sh` — extracts and upserts symbols from changed files |
| Session end | `hooks/on_session_end.sh` (extended) | Validates `graph.json` schema; marks unreferenced or unverified nodes as `stale`; writes `graph_update` trigger to queue |

---

## Agent Usage

| Agent | How it uses the graph |
|---|---|
| **Developer** | At task start: queries subgraph by service/file (context injection); queries dependents of touched nodes (impact analysis) before implementing |
| **Tester** | Verifies `affected_nodes` from summary against graph; promotes verified entries |
| **Scrum Master** | At session start: loads relevant subgraph slice when processing triggers that touch known services |

---

## File & Directory Structure

```
project/
  knowledge-graph/
    graph.json             ← coarse-grained graph (Tier 1)
    schema.json            ← JSON Schema for graph.json validation
    index.json             ← service/module lookup index (auto-generated)
    kuzu/                  ← Kuzu embedded DB (Tier 2, gitignored)

templates/
  KNOWLEDGE_GRAPH_NODE_TEMPLATE.json
  KNOWLEDGE_GRAPH_EDGE_TEMPLATE.json
  KNOWLEDGE_GRAPH_SCHEMA_TEMPLATE.json

scripts/
  validate-knowledge-graph.sh        ← validates graph.json against schema
  index-knowledge-graph.sh           ← main extraction + upsert pipeline
  migrate-knowledge-graph-to-db.sh   ← export Kuzu → external DB (Neo4j, Postgres, etc.)

hooks/
  post-commit                        ← fires index-knowledge-graph.sh on commit
  on_session_end.sh                  ← extended with graph validation + stale detection

mcp/ (planned — deferred story)
  knowledge-graph/
    index.js               ← MCP server: get_node, add_node, query_subgraph, add_edge, etc.
```

---

## Deferred Story (last story in epic)

The following are explicitly out of scope for the main implementation stories and are grouped into a final deferred story:

- MCP server (`mcp/knowledge-graph`) — architecture accommodated from day one, implemented here
- Visualization / diagram generation from graph data (Mermaid, D3, etc.)
- Cross-project graphs
- Automatic language detection in the extraction pipeline (initial support: JS/TS, configurable)

---

## 🔍 Deep Dive Synthesis

### Scrutiny Findings

Five risks were rated **High severity** by scrutiny:

1. **Graph accuracy risk** — Static extraction in dynamic/convention-heavy JS/TS codebases may produce misleading graphs, causing agents to become more confident *and* more wrong.
2. **Hook performance risk** — Commit-time indexing that is slow or brittle will be bypassed, leading to stale state.
3. **Multi-store drift risk** — Maintaining three synchronized stores (graph.json + frontmatter + Kuzu) has a high probability of partial-update bugs and hard-to-debug divergence.
4. **Unstable symbol identity** — Renames, moves, anonymous functions, and framework-generated endpoints make node IDs brittle without deliberate design.
5. **Unproven ROI** — No measurement framework exists to prove the graph improves agent outcomes.

→ Full assessment: `./scrutiny-knowledge-graph.md`

### Solution Paths

The solution assessment recommends a **progressive rollout** over a big-bang full implementation:

1. **Start coarse-only** — Implement Tier 1 (git-tracked JSON, Service/Module level) only. Validate value before adding Kuzu.
2. **Single canonical source** — One authoritative representation; all other stores (Kuzu, index.json) are derived and rebuildable.
3. **Non-blocking hooks** — Heavy indexing moves to async/CI paths; commit hooks stay lightweight with explicit stale-marking as degraded mode.
4. **Automated provenance** — Derive `affected_nodes` from AST diffs rather than relying on agent free-form reporting.
5. **Stable synthetic IDs** — Node IDs derived from symbol kind, file lineage, and structural signature — not from raw symbol text.
6. **Multi-dimensional quality signals** — Replace single `status` field with separate `confidence`, `recency`, and `evidence_source` dimensions.
7. **Explicit support boundaries** — Publish which stacks/patterns are supported, partial, or unsupported to prevent false confidence.
8. **Benchmark suite** — Define accuracy, freshness, and agent-task-outcome metrics before declaring the system useful.

→ Full assessment: `./solution-assessment-knowledge-graph.md`

### Resolved Decisions

All five pre-implementation decisions resolved on 2026-07-10:

1. **Pilot scope** — `roxana-paid-version` (registered in `.jenga_paths`). Pilot is exploratory — no hard success threshold.
2. **Canonical source** — `graph.json` is canonical. Agents write coarse topology to it directly. Kuzu is a derived, rebuildable cache (rebuilt from `graph.json` + source code by the indexing pipeline).
3. **Provenance strategy** — Fully automated. The indexing pipeline derives `affected_nodes` and `changed_edges` from AST diffs. Agents do not write these fields manually; they are read-only consumers.
4. **Node ID stability scheme** — Git-object-based. Each node ID is derived from the blob SHA at the symbol's first introduction into the repository. Renames and moves update node metadata but do not change the ID.
5. **Language/framework scope** — JS/TS + Python at launch, with framework-specific extractors for: Express, NestJS, Next.js (JS/TS) and FastAPI, Django (Python).
