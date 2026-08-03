---
id: E25_S01
epic_id: E25
title: Pre-flight measurement spike — extractor prototype & latency measurement
status: Passed
date_created: 2026-07-23
date_started: 2026-07-23
date_completed: 2026-07-23
dates_previously_completed:
reopened_on:
reopened_reason:
tasks:
  - E25_S01_T01
  - E25_S01_T02
  - E25_S01_T03
---

# Story: Pre-flight measurement spike — extractor prototype & latency measurement

As the Board Index Substrate epic owner, I want a throwaway extractor prototype that measures real cold-walk latency on the current board and on a synthetic 10× board, so that the persistence decision in the plan doc §7 rests on a number rather than a guess — and so that the remaining stories (S02–S07) can be decomposed with confidence.

## Background
This is the first gate story of epic **E25 — Board Index Substrate**. The plan document at `project/documentation/plans/board-index-substrate.md` explicitly conditions the rest of the epic on this spike's result:

> "If measured cold latency > 150ms, revisit the persistence-as-optional-cache decision *before* S02 opens."

The plan proposes a **live filesystem walk on every call** (no persistence, no cache) on the assumption that ~50–200ms is fast enough. That assumption is unmeasured. The scrutiny assessment (`scrutiny-board-index-substrate.md`) flagged this as Assumption A1 / Risk 4. This story replaces the guess with data.

Scope: this is a **throwaway** — the prototype is not the S02 implementation. Its only deliverables are the extractor stub, the two measurements, and a decision on whether to proceed with the live-walk architecture or reopen the persistence question.

## Acceptance Criteria
- [ ] A throwaway extractor script exists (path at implementer's discretion, under `.claude/skills/` or `scripts/`) that walks `project/board/`, `project/documentation/`, and `project/todo.md`, and emits a JSON node/edge structure to stdout
- [ ] Extractor handles the current happy-path artifact types: `Epic`, `Story`, `Task`, `Plan`, `Summary`, `TodoEntry` — with the `contains`, `plans`, `summarizes`, and `queued_as` edges
- [ ] A synthetic 10× board is generated (script that duplicates the current board's structure ~10x under a temp directory) and can be run against
- [ ] Cold-walk latency measured with `hyperfine` (or equivalent) on: (a) the real current board, (b) the 10× synthetic board — at least 10 runs each, cold cache (`sudo purge` on macOS between runs, or equivalent), report median + p95
- [ ] Numbers logged in a measurement report at `project/documentation/plans/board-index-substrate-measurement.md`
- [ ] The 50–200ms guess in `project/documentation/plans/board-index-substrate.md` §7 is replaced with the measured median (or the guess is annotated with the real number if the section is left intact)
- [ ] The measurement report includes an explicit **decision line**: either "PROCEED with live-walk architecture as planned" (if p95 on real board ≤ 150ms) or "REOPEN persistence decision — see below" with reasoning
- [ ] If the decision is REOPEN, the report identifies which specific extraction step dominates latency, so the S02 story (whenever it opens) can be scoped around that constraint

## Definition of Done
- [ ] Throwaway extractor prototype exists and runs against the current board
- [ ] Synthetic 10× board generator exists and is deterministic (repeatable across runs)
- [ ] Latency measured with a proper benchmarking tool (not `time`); median and p95 both reported
- [ ] Measurement report written to `project/documentation/plans/board-index-substrate-measurement.md` with a clear PROCEED / REOPEN decision line
- [ ] Plan doc §7 references the report (or embeds the measured number)
- [ ] Prototype code is either deleted or clearly marked `# THROWAWAY — do not import` — it is not the S02 deliverable
