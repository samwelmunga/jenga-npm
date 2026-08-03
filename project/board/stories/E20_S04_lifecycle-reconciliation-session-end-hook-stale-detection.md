---
id: E20_S04
epic_id: E20
title: Lifecycle & Reconciliation — Session-End Hook, Stale Detection & Branch Safety
status: Pending
date_created: 2026-07-10
date_started:
date_completed:
tasks: []
---

# Story: Lifecycle & Reconciliation — Session-End Hook, Stale Detection & Branch Safety

As a JengaAgent framework, I want the knowledge graph to stay coherent across sessions, branches, and worktrees so that agents never act on dangerously stale or corrupted graph data.

## Acceptance Criteria
- [ ] `hooks/on_session_end.sh` is extended with a "Knowledge Graph Reconciliation" step that:
  - Runs `scripts/validate-knowledge-graph.sh` on `graph.json`
  - Detects nodes whose source files have changed since their last `verified` timestamp (via git log)
  - Marks those nodes `stale` in both `graph.json` and Kuzu
  - Writes a `graph_update` trigger to `project/queue/scrum_triggers.jsonl` if any nodes were marked stale
- [ ] Kuzu DB is rebuildable from scratch by running `scripts/index-knowledge-graph.sh` with `--full` flag — treated as a disposable cache, not the canonical source
- [ ] `graph.json` is the canonical source for coarse topology; Kuzu is derived from it plus source code
- [ ] A `scripts/reconcile-knowledge-graph.sh` command is available that: re-validates the schema, recomputes stale status from git history, and optionally rebuilds Kuzu from scratch (`--rebuild` flag)
- [ ] After a git merge or rebase, running `scripts/reconcile-knowledge-graph.sh` correctly identifies newly stale nodes without false positives on unchanged nodes
- [ ] Parallel worktrees each operate on their own Kuzu instance; `graph.json` is branch-scoped (not shared across worktrees)
- [ ] Schema version is embedded in `graph.json` and `schema.json`; a mismatch causes `validate-knowledge-graph.sh` to fail with a descriptive migration message
- [ ] A schema migration path is documented for when the node/edge schema evolves between framework versions

## Definition of Done
- [ ] Session-end hook marks stale nodes and writes the trigger without blocking session completion
- [ ] Kuzu can be fully rebuilt from source code after deletion
- [ ] After a simulated merge conflict resolution, reconcile script correctly reflects the new file state
- [ ] Schema version check catches a deliberate version mismatch and exits with a clear error
