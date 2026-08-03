---
id: E20_S05
epic_id: E20
title: Quality & Measurement — Accuracy Benchmarks, Node Quality Dimensions & Audit Workflow
status: Pending
date_created: 2026-07-10
date_started:
date_completed:
tasks: []
---

# Story: Quality & Measurement — Accuracy Benchmarks, Node Quality Dimensions & Audit Workflow

As a JengaAgent maintainer, I want a measurement framework for the knowledge graph so that extraction accuracy, freshness, and agent task-outcome impact are observable and improvable over time.

## Acceptance Criteria
- [ ] Node `status` field is extended to a multi-dimensional quality object:
  ```json
  "quality": {
    "confidence": "high | med | low",
    "recency": "fresh | aging | stale",
    "evidence_source": "ast_extraction | agent_verified | tester_verified | manual"
  }
  ```
  Single `status` field is deprecated and removed from the schema
- [ ] `project/data/graph-baselines.json` stores accuracy baselines per project (analogous to `baselines.json` for test analytics)
- [ ] A benchmark suite (`scripts/benchmark-knowledge-graph.sh`) measures:
  - **Extraction precision**: nodes/edges extracted vs nodes/edges expected in a reference fixture
  - **Freshness ratio**: percentage of `verified` nodes with recency `fresh` or `aging`
  - **Coverage**: percentage of project services/modules represented in the coarse graph
- [ ] Benchmark runs on a reference fixture project included in the framework under `jobs/knowledge-graph-benchmark/`
- [ ] Results are written to `project/data/graph-baselines.json` and compared against previous baseline; regressions are reported
- [ ] An audit workflow is documented: periodic (configurable, default: monthly) manual review of a random 10% sample of nodes against actual source code, with discrepancies logged to a rapport
- [ ] `workflow.json` is extended with a `knowledge_graph_quality` block: `{ "confidence_threshold": "med", "freshness_max_age_days": 14 }`

## Definition of Done
- [ ] Benchmark script runs against the reference fixture and produces a JSON results file
- [ ] A baseline regression is detectable: changing the fixture causes the benchmark to report a delta
- [ ] Quality dimensions appear on nodes in Kuzu and `graph.json` after a full indexing run
- [ ] Audit workflow documentation is present in `project/documentation/`
