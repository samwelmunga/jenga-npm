---
id: E25_S02
epic_id: E25
title: Library skeleton & node/edge extraction
status: Passed
date_created: 2026-07-23
date_started: 2026-07-23
date_completed: 2026-07-23
dates_previously_completed:
reopened_on:
reopened_reason:
tasks:
  - E25_S02_T01
  - E25_S02_T02
  - E25_S02_T03
  - E25_S02_T04
  - E25_S02_T05
---

# Story: Library skeleton & node/edge extraction

As a skill author, I want a shell-callable library at a stable path that walks `project/*` and emits structured node/edge JSON, so that downstream skills (`/status`, `/impact`, `/validate-board`) can stop re-implementing filesystem traversal.

## Background

E25_S01 measured real-board cold-walk latency at **126ms median / 166ms p95** and resolved to **PROCEED with live-walk architecture** (no persistence, no cache). S02 is now unblocked.

This story delivers the **bare-bones library skeleton**: a shell-dispatchable entry point that exposes `graph::nodes` and `graph::edges` with optional `--type` filtering, producing JSON output on stdout. No query predicates, no `graph::query` — those come in S03. No `/status` refactor — that comes in S04.

The throwaway prototype from S01 (`scripts/e25_s01_extract_board_graph.py`) is **not** the deliverable — it must not be imported. The S02 implementation is a clean, production-quality library at the path chosen in T01.

## Acceptance Criteria

- [x] Library entry point exists at `.claude/skills/index/scripts/board_index.py` (or equivalent agreed path) with a shell dispatch script `board-index` that routes `graph::nodes [--type=<type>]` and `graph::edges [--type=<type>]` subcommands
- [x] `graph::nodes` emits a JSON array of node objects; each node carries at minimum: `id`, `type`, `title`, `status`, `path`
- [x] `graph::edges` emits a JSON array of edge objects; each edge carries: `from`, `to`, `type`
- [x] All v1 node types are supported: `Epic`, `Story`, `Task`, `Plan`, `Summary`, `Doc`, `TodoEntry`, `Skill`, `Agent`
- [x] All v1 edge types are derived: `contains`, `plans`, `summarizes`, `queued_as`, `mentions_skill`, `mentions_agent`, `depends_on`, `blocks`, `parent_doc`
- [x] Missing/optional frontmatter keys (`mentions_skills`, `mentions_agents`, `depends_on`, `parent_doc`) never cause an extraction error — degradation rule: fewer edges, not a crash
- [x] `--type` filter on both subcommands returns only nodes/edges of that type; unrecognised type emits `[]` (not an error)
- [x] `Skill` and `Agent` nodes carry `id`, `path`, and `description` (first line of the SKILL.md/agent description, or empty string if absent) — not just id+path
- [x] `TodoEntry` node identity uses the `board_ref` extracted from the line (e.g. `E24_S03`) as the primary id when present; falls back to a SHA-256 of the normalised line content otherwise
- [x] Running `board-index graph::nodes | python3 -m json.tool` exits 0 on the current real board
- [x] Node count output matches the real-board numbers from the S01 measurement report (±10% tolerance for growth since measurement)
- [x] Library reads only `project/*`, `.claude/skills/`, and `.agents/` paths; it never reads application source directories or `.env` files
- [x] The S01 throwaway scripts (`scripts/e25_s01_extract_board_graph.py`, `scripts/e25_s01_generate_synthetic_board.py`) are cleaned up (deleted or confirmed already deleted/marked)

Verified via `skills/index/scripts/smoke_test.sh` on 2026-07-23; canonical implementation lives under root `skills/index/scripts/` per workflow source-of-truth rules.

## Definition of Done

- [ ] Library skeleton exists at the agreed path with `graph::nodes` and `graph::edges` working
- [ ] All nine node types extracted; all edge types derived from frontmatter
- [ ] Tolerant of missing optional frontmatter (never crashes)
- [ ] `--type` filter works on both subcommands
- [ ] Smoke test passes against the real board: valid JSON, non-empty, node count in expected range
- [ ] No references to the S01 throwaway prototype in the new library code
- [ ] Execution plan written to `project/documentation/plans/E25_S02-plan.md`
- [ ] Execution summary written to `project/documentation/summaries/E25_S02-summary.md`
