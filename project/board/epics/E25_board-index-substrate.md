---
id: E25
title: Board Index Substrate — Queryable Library over project/*
status: Pending
date_created: 2026-07-23
date_started:
date_completed:
dates_previously_completed:
reopened_on:
reopened_reason:
stories:
  - E25_S01
  - E25_S02
  - E25_S03
  - E25_S04
  - E25_S05
  - E25_S06
  - E25_S07
---

# Epic: Board Index Substrate — Queryable Library over project/*

## Purpose
Ship a shell-callable query library that reads `project/*` structural artifacts (epics, stories, tasks, plans, summaries, todo.md, skills, agents) and exposes a small set of graph-shaped queries — `graph::query`, `graph::neighbors`, `graph::orphans`, etc. The substrate is infrastructure: it has **no user-facing slash command in v1**. Its job is to be *imported by other skills* (`/status`, `/impact`, and later `/reconcile`, `/doc-sync`, etc.) so each skill stops re-implementing filesystem traversal against the board.

Deliberately distinct from E20: E20 graphs *application code* topology (services, functions, data flows, Kuzu DB); this epic graphs *board & PM artifacts* over a live filesystem walk. Path-prefix boundary is enforced: this substrate reads only `project/*` and skill/agent frontmatter; E20 reads only code.

**Staged rollout**: only S01 (measurement spike) is queued in `todo.md` at epic creation time. **S02–S07 are gated on S01's measurement result** — if cold-walk latency exceeds 150ms, the persistence-as-optional-cache decision reopens before S02 is decomposed. See `project/documentation/plans/board-index-substrate.md` for the full plan, scrutiny, and solution assessment.

## Definition of Done
- [ ] Substrate library exists at a path per S02, with `graph::query`, `graph::neighbors`, `graph::nodes`, `graph::edges`, `graph::orphans` all implemented
- [ ] Predicate grammar published as an appendix to the plan doc before S03 opens
- [ ] `/status` refactored to read from the substrate; passes all pre-existing behavioral tests
- [ ] `/impact <node_id>` skill exists and traverses `depends_on`, `mentions_skill`, `mentions_agent`, and `contains` edges from the given starting node
- [ ] `/validate-board` skill exists, is invoked by `/commit`, and supports `--no-validate` flag plus `SKIP_VALIDATE=1` env var (both audit-logged to `project/logs/events.json`)
- [ ] `SCRUM_BOARD_SCHEMA.md` documents the optional frontmatter keys (`mentions_skills`, `mentions_agents`, `depends_on`, `blocks`, `parent_doc`) as tolerated-if-missing
- [ ] Seed & backfill sweep has populated the optional keys on existing artifacts where clearly applicable, with human review completed
- [ ] Measurement report from S01 is filed in `project/documentation/plans/` and referenced from plan doc §7
