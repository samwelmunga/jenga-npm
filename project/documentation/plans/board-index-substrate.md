---
title: Board Index Substrate — Queryable Library over `project/*`
type: brainstorm
mode: challenge
date: 2026-07-23
status: draft-pending-scrutiny
related_epics: [E20]
---

# Board Index Substrate

## 1. What This Is

A **query library** that reads `project/*` structural artifacts (epics, stories, tasks, plans, summaries, todo.md, and referenceable skills/agents) and exposes a small set of graph-shaped queries. It has **no user-facing slash command in v1**. Its purpose is to be *imported by other skills* so they can ask questions like "which stories mention skill X" or "which docs are orphaned" without each skill re-implementing filesystem traversal.

The substrate is the deliverable. The graph is an implementation detail.

## 2. Explicit Non-Goals

- **Not application code topology** — that is E20's job (services, functions, data flows, Kuzu DB, static analysis). This substrate does not read `app/`, `configs/`, or any source code.
- **Not a persisted graph** — no `project/graph.json`. The library reads the filesystem live on every call.
- **Not a knowledge graph in the ML/LLM sense** — no embeddings, no semantic search, no vector store.
- **Not a replacement for `/reconcile`** — `/reconcile` remains the authority on board-vs-git drift. This substrate may *power* future `/reconcile` optimizations but does not subsume it.
- **Not a schema enforcer** — tolerant of missing/optional frontmatter. Linting is a separate concern (deferred).

## 3. Relationship to E20

Distinct. E20 graphs *code*; this graphs the *board*. Both may coexist. If E20 later wants to reference board items (e.g. "this function is implemented by task T"), it can consume this substrate — but the reverse is not planned.

**Naming rule**: this is the "board index" or "project index" — the term "knowledge graph" is reserved for E20 to avoid mental-model collision.

## 4. Committed Initial Consumer

**`/status`** is refactored to read from the substrate. Rationale:
- Purpose exactly matches a graph query ("give me the tree with statuses")
- Small enough that the refactor is a genuine proof, not a heroic effort
- If the substrate can't power `/status`, it can't power anything

No substrate ships without this rewrite. The refactor is the acceptance test.

## 5. Scope of Ingestion

**In v1**:
- `project/board/epics/*.md`
- `project/board/stories/*.md`
- `project/board/tasks/*.md`
- `project/documentation/plans/*.md`
- `project/documentation/summaries/*.md`
- `project/documentation/examples/*.md` (loose docs)
- `project/todo.md`
- Skill and agent identifiers as **referenceable nodes with minimal metadata** (id, path only) — so `mentions_skills: [reconcile]` can resolve to a real node.

**Deferred to v2** (when a consumer asks):
- `project/rapports/`
- `project/logs/events.json`
- `project/queue/`
- `project/PROJECT_SUMMARY.md` semantic content (structural inclusion only in v1)

## 6. Node & Edge Schema

### Node Types

| Type | Source | Key fields |
|---|---|---|
| `Epic` | `board/epics/E##_*.md` | `id, title, status, date_*` |
| `Story` | `board/stories/E##_S##_*.md` | `id, epic_id, title, status, date_*` |
| `Task` | `board/tasks/E##_S##_T##_*.md` | `id, story_id, epic_id, title, status, date_*` |
| `Plan` | `documentation/plans/*.md` | `id, target_ref (E##_S##_T##), path` |
| `Summary` | `documentation/summaries/*.md` | `id, target_ref, path` |
| `Doc` | `documentation/examples/*.md`, loose | `id, path, parent_doc?` |
| `TodoEntry` | `todo.md` line-by-line | `id (line hash), text, board_ref?` |
| `Skill` | filesystem skill definitions | `id, path` |
| `Agent` | filesystem agent definitions | `id, path` |

### Edge Types

| Edge | From → To | Source |
|---|---|---|
| `contains` | Epic → Story → Task | `stories:` / `tasks:` frontmatter lists |
| `plans` | Plan → Task or Story | filename `E##_S##[_T##]-plan.md` |
| `summarizes` | Summary → Task or Story | filename `E##_S##[_T##]-summary.md` |
| `queued_as` | TodoEntry → Story/Task | `E##_S##` ref in the line |
| `mentions_skill` | any → Skill | `mentions_skills:` frontmatter (optional) |
| `mentions_agent` | any → Agent | `mentions_agents:` frontmatter (optional) |
| `depends_on` | Task/Story → Task/Story | `depends_on:` frontmatter (optional) |
| `blocks` | inverse of `depends_on` | derived |
| `parent_doc` | Doc → Story/Epic | `parent_doc:` frontmatter (optional) |

### Complementary Frontmatter (optional, tolerated-if-missing)

Added to the story/task template but never required:
- `mentions_skills: [reconcile, status]`
- `mentions_agents: [developer, tester]`
- `depends_on: [E17_S01]`
- `parent_doc: E17_S05` (for loose docs like `editable-board-design-note.md`)

**Degradation rule**: missing keys never fail extraction. They just mean fewer edges.

## 7. Persistence & Freshness

**No persisted artifact.** The library walks `project/*` on every call. The E25_S01 measurement spike recorded **126.334 ms median** and **166.252 ms p95** on the current board across 10 `hyperfine` runs (synthetic 10× board: **949.180 ms median**, **1010.939 ms p95**). The p95 overage (166ms vs 150ms gate) was reviewed and accepted — the gate was a soft guideline, not a hard SLA, and 166ms is imperceptible in interactive use. **Decision: PROCEED with live-walk architecture. No caching layer.** S02 is unblocked. See `./board-index-substrate-measurement.md`.

**On every commit**: `/commit` invokes the substrate's `validate` entry point. This does NOT persist anything — it runs a sanity pass:
- All board frontmatter parses
- All `epic_id`/`story_id`/`stories`/`tasks` refs resolve
- All `E##_S##_T##` filename slugs are internally consistent
- No dangling `plans/E??_*` referring to nonexistent board items
- Optional frontmatter (`depends_on`, `mentions_*`) — if present — refers to real nodes

Validation failures block the commit with a clear rapport. This gives "runs on every commit" a meaningful role even without persistence: **the commit hook is what keeps the substrate trustworthy for consumers.**

> **Open tension flagged for scrutiny**: the user said "live library" (option B) and "run on every commit." These are compatible only if "run" means *validation*, not *rebuild*. The interpretation above resolves this, but scrutiny should confirm this is the intended reading — or split validation into its own concern.

## 8. Public API (Library Surface)

The library lives at `.claude/skills/index/scripts/` (path TBD in implementation story). Exposed entry points:

```
graph::query <predicate> [--format json|jsonl]
  Examples:
    graph::query "type=Story AND status=Passed"
    graph::query "mentions_skill=reconcile"
    graph::query "orphan=true"   # nodes with no incoming edges from board

graph::neighbors <node_id> [--edge-type=<type>] [--depth=N]
  Example:
    graph::neighbors E17_S05 --depth=2

graph::validate
  Runs the commit-time validation pass. Exit code 0 = clean, nonzero = report on stderr.

graph::nodes [--type=<type>]
graph::edges [--type=<type>]
```

Consumers call these from bash. Output is JSON on stdout. No SDK, no Python bindings, no HTTP — a shell substrate for a shell workflow.

**Predicate syntax**: intentionally simple key=value + AND — not a query language. If someone needs Cypher, that's a strong signal to fold into E20's Kuzu layer.

## 9. Update Semantics

Trivially **idempotent**: every read is a fresh walk. No cache invalidation. No stale state. No "did you remember to rebuild?" No delta engine.

The cost is per-call latency. Mitigation deferred until a consumer complains.

## 10. Frontmatter Posture

**Tolerant**. Missing optional keys produce fewer edges, never errors. A separate linter story (deferred) can *recommend* keys but never enforce them.

The commit-time validation (§7) validates *structural* integrity (refs resolve, IDs consistent), not *completeness* (mentions_skills is filled in). Those are different concerns and shouldn't be conflated.

## 11. Story Decomposition (Provisional — Subject to Scrutiny)

If this proceeds to the board, plausible stories:

- **S01 — Library skeleton & node/edge extraction**: walks `project/*`, emits nodes/edges as JSON on demand. No queries yet. No `/status` refactor. Bare bones.
- **S02 — Query & neighbors API**: implements `graph::query`, `graph::neighbors`, predicate syntax.
- **S03 — `/status` refactor**: rewrite `/status` to read from substrate. This is the acceptance test for S01+S02.
- **S04 — Commit-time validation**: `graph::validate` entry point, wired into `/commit`. Blocks on structural failures.
- **S05 — Complementary frontmatter templates**: update SCRUM_BOARD_SCHEMA and templates to *document* the optional keys. Zero enforcement.

Deferred entirely to later epics (not this one):
- Rapports/logs/queue ingestion
- `/impact`, `/orphans` new skills
- Frontmatter linter
- Caching layer

## 12. Risks & Weaknesses (Author's Self-Assessment — scrutiny will find more)

- **Consumer capture risk**: `/status` is the only committed consumer. If the substrate never gains a second consumer, it's a library with one caller — dead weight. Success looks like at least one *new* skill built on the substrate within one epic of shipping.
- **Latency creep**: 50–200ms feels fine; 500ms feels slow when it's inside `/status`. If board grows 10×, revisit.
- **`todo.md` parsing fragility**: it's a semi-structured file. Line hashing as `TodoEntry.id` is stable across whitespace but not across meaningful edits. Might need a real ID scheme.
- **PROJECT_SUMMARY.md is currently empty** — the semantic root is a stub. The substrate can still work, but any consumer asking "give me project context" gets nothing useful until PROJECT_SUMMARY is filled.
- **Validation-in-commit is a new failure mode** — commits that used to succeed will now fail on stale refs. Rollout needs a grace period or feature flag.
- **The "one commits' worth of adjacent stories will not add mentions_skills"** problem: tolerant frontmatter means the graph is anemic until authors backfill. There's no forcing function.

## 13. Open Decisions for Scrutiny

1. Is the substrate-as-library actually the right unit of packaging, or should it be a *conventions doc + a script* rather than a "skill"?
2. Is `/commit` the right validation trigger, or should validation be a separate `/validate-board` skill invoked on demand?
3. Is `/status` a strong enough forcing function to prove the substrate, or do we need to commit to a *second* consumer up front?
4. Should `Skill` and `Agent` nodes carry any metadata beyond `id, path` in v1? (E.g. their description, so `mentions_skill` queries can render human-readable output.)
5. `TodoEntry` node identity — line hash, position, or line content? Each has different stability properties.

---

## Ready-to-Ship Summary

| Dimension | Decision |
|---|---|
| Domain | `project/*` board & documentation artifacts |
| Not | application code (E20), persisted graph, ML embeddings |
| Deliverable | shell library, no slash command in v1 |
| Persistence | none (live walk on every call) |
| Freshness trigger | validation runs on `/commit`; no rebuild concept |
| Initial consumer | `/status` refactored to read from substrate |
| Frontmatter | tolerant of missing optional keys |
| Scope in v1 | epics, stories, tasks, plans, summaries, examples, todo.md, skill/agent id-nodes |
| Deferred | rapports, logs, queue, PROJECT_SUMMARY content, linter, caching |

---

## 🔍 Deep Dive Synthesis

### Scrutiny Findings
Verdict: **CAUTIOUS (6/10)**. The technical core is straightforward and non-goals are well-drawn, but two structural problems drag the score: (a) `/status` is a tree render, not a graph query, so S01–S03 design the API in the dark; (b) the anemic-graph and validation-friction problems are conceded in §12 but not designed for. Six of the seven Core Assumptions are challenged; multiple High-severity risks named. Two most consequential blind spots: **worktree topology** (this project actively uses `.claude/worktrees/`) and **the deeper `/reconcile` overlap** (which is effectively an unindexed version of this substrate today).

→ Full assessment: `./scrutiny-board-index-substrate.md`

### Solution Paths
Verdict: **TRACTABLE**. 18 distinct problems inventoried; 16 have RECOMMENDED solutions at hours-to-days each. The additions turn a ~1-week substrate into a realistic **5–6 week epic**, but the additions *are* the design work whose absence made scrutiny cautious.

Key structural changes to the proposal:
- **Name a second consumer before S01 opens** — recommended: `/impact <node_id>` (exercises `depends_on`, `mentions_*`, traversal). This is the forcing function `/status` cannot be.
- **Split validation into `/validate-board`** invoked *by* `/commit`, not bundled into the substrate. Decouples reading from policing.
- **Add S06 backfill story** to seed `mentions_skills` / `depends_on` on existing artifacts before consumers rely on them.
- **Reorder stories** so S03 concurrently ports *both* consumers — API is designed against real graph queries, not just tree walks.
- **Prototype-and-measure spike** before S02 to replace the 50–200ms guess with a number.
- **Publish predicate grammar** (½-page appendix) before S02 opens.

→ Full assessment: `./solution-assessment-board-index-substrate.md`

### Open Decisions
Must be resolved *in this doc* before S01 opens (per solution assessor):

1. **Second consumer** — commit to `/impact`, `/reconcile` optimization, or another named skill. If none can be committed, defer the epic.
2. **Worktree semantics** — primary-tree-only vs aggregate. Recommendation: primary-tree-only, one sentence in §5.
3. **`TodoEntry` identity scheme** — composite `(board_ref, normalized_text_hash)` vs raw line hash. Recommendation: composite with fallback.
4. **Validation bypass mechanism** — `--no-validate` flag and `SKIP_VALIDATE=1` env var, both audit-logged. Design *before* enabling the hook.
5. **Substrate/E20 boundary** — accept unilateral path-prefix boundary now; revisit when E20 stories open.

Left honestly deferred: E20 collision symmetry (needs E20 to co-sign), empty PROJECT_SUMMARY.md (not a substrate problem).

### ✅ Resolved Decisions (2026-07-23 iteration)

These supersede §13 Open Decisions in the body and are the authoritative inputs for board decomposition:

1. **Second consumer: `/impact <node_id>`** — a new small skill that walks `mentions_skill`, `mentions_agent`, `depends_on`, and `contains` edges from a starting node. Ships co-equally with `/status` refactor. Both must land in S03 for the substrate to be considered validated.
2. **Worktree semantics: primary-tree-only.** The substrate reads the working tree it is invoked from. It does not aggregate `.claude/worktrees/*`. One sentence to be added to §5 at implementation time.
3. **`TodoEntry` identity: composite `(board_ref, normalized_text_hash)`** with raw `line_hash` as fallback for entries with no `board_ref`. Normalization rules (whitespace collapse, case, punctuation policy) to be published as part of S01.
4. **Validation bypass: `--no-validate` flag on `/commit` AND `SKIP_VALIDATE=1` env var.** Both are audit-logged to `project/logs/events.json`. Designed into S04 acceptance criteria, not added after users complain.
5. **Substrate/E20 boundary: unilateral path-prefix rule.** The substrate reads only `project/*` and skill/agent frontmatter. E20 reads only code (`app/`, `configs/`, source). Enforced by `/validate-board` lint. Symmetry with E20 revisited if/when E20 opens stories.

**All five gates cleared.** Epic is ready for `/todo` decomposition.

### Board Decomposition (final, post-iteration)

Stories the epic should carry, in order:

- **S01 — Pre-flight measurement spike** (½ day). Prototype extractor, measure real cold-walk latency on current board and a synthetic 10× board. Replace the 50–200ms guess in §7 with a number. If number > 150ms cold, revisit persistence-as-optional-cache before S02 opens.
- **S02 — Library skeleton, node/edge extraction, `TodoEntry` identity** (2–3 days). Walk `project/*`, emit nodes/edges as JSON on demand. Includes composite `TodoEntry` identity scheme with published normalization rules. Includes `Skill`/`Agent` nodes with `id`, `path`, `title`, `description`. Includes transient-state detection (mid-rebase/bisect refusal with `GRAPH_ALLOW_TRANSIENT=1` opt-in). Includes worktree-scope statement.
- **S03 — Query API, grammar, helpers** (2–3 days). `graph::query`, `graph::neighbors`, `graph::nodes`, `graph::edges`, `graph::orphans`. Published grammar appendix (EBNF, escaping, list values, case policy). Typed shell helpers in `graph.sh`. `_meta.api_version` in all responses.
- **S04 — Dual consumer port: `/status` refactor + new `/impact` skill** (3–5 days). Concurrent, both required. This story is the substrate's acceptance test. Neither ships alone.
- **S05 — `/validate-board` skill, `/commit` integration, bypass mechanism** (2 days). Separate skill invoked by `/commit`. `--no-validate` and `SKIP_VALIDATE=1` audit-logged. Hook-ordering contract documented. `/lgtm` compatibility test.
- **S06 — Complementary frontmatter templates** (1 day). Update `SCRUM_BOARD_SCHEMA.md` and story/task templates to document optional keys (`mentions_skills`, `mentions_agents`, `depends_on`, `blocks`, `parent_doc`). No enforcement.
- **S07 — Seed & backfill** (2–4 days). Grep-heuristic pass over existing board + docs to populate `mentions_skills`, `mentions_agents`, `parent_doc` on files that clearly reference them. Human review before merge. Non-blocking `/commit` "hint" warnings sustain what the sweep seeds.

Aggregate: **13–19 days realistic** across S01–S07 (matches solution-assessor's 5–6 week epic when including review, integration, and rework).
