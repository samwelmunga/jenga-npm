---
id: E25_S01_T03
story_id: E25_S01
epic_id: E25
title: Measurement report + plan doc §7 update with decision line
status: Passed
date_created: 2026-07-23
date_started: 2026-07-23
date_completed: 2026-07-23
assigned_to: developer
---

# Task: Measurement report + plan doc §7 update with decision line

## Description
Depends on T02 (measurements must be complete).

### 1. Write the measurement report
Create `project/documentation/plans/board-index-substrate-measurement.md` with the following sections:

- **Metadata header**: date, board size (file count), synthetic board size
- **Methodology**: which extractor script, hyperfine version, cache-flush method, run count
- **Results table**: real board (median, p95) and 10× synthetic board (median, p95) — include raw hyperfine output or link to JSON exports
- **Decision line** (explicit, machine-readable):
  - `DECISION: PROCEED` — if p95 on **real board** ≤ 150ms
  - `DECISION: REOPEN` — if p95 on real board > 150ms; include which extraction step dominates latency (dir walk, frontmatter parse, edge derivation, JSON serialization)
- If `REOPEN`: add a "Bottleneck Analysis" section identifying the dominant step and its approximate share of latency

### 2. Update plan doc §7
In `project/documentation/plans/board-index-substrate.md`, section §7 ("Persistence & Freshness"), replace or annotate the "~50–200ms" estimate with the measured median from the real board run. Either:
- Replace the sentence in-place with the real number, or
- Add a footnote/annotation: `> Measured: <median>ms median, <p95>ms p95 on current board (E25_S01 spike, <date>). See board-index-substrate-measurement.md.`

Reference the measurement report file from §7 so future readers can find the raw data.

### 3. Cleanup
- Confirm the extractor prototype and generator script are either deleted or clearly marked `# THROWAWAY — do not import`
- Confirm the synthetic temp directory is cleaned up (or a cleanup command is documented in the report)

## Acceptance Criteria
- [ ] `project/documentation/plans/board-index-substrate-measurement.md` exists with all required sections
- [ ] Report includes median and p95 for both real board and 10× synthetic board
- [ ] Report contains an explicit `DECISION: PROCEED` or `DECISION: REOPEN` line
- [ ] If `REOPEN`: bottleneck analysis section present, naming the dominant extraction step
- [ ] Plan doc §7 references the measured number (in-place or annotated) and links to the measurement report
- [ ] Extractor prototype is deleted or marked `# THROWAWAY — do not import`
- [ ] Synthetic board temp directory is cleaned up or cleanup instructions are documented
