---
id: E25_S01_T02
story_id: E25_S01
epic_id: E25
title: Synthetic 10× board generator + hyperfine cold-walk latency measurement
status: Passed
date_created: 2026-07-23
date_started: 2026-07-23
date_completed: 2026-07-23
assigned_to: developer
---

# Task: Synthetic 10× board generator + hyperfine cold-walk latency measurement

## Description
Depends on T01 (extractor prototype must exist and run successfully).

Two deliverables:

### 1. Synthetic 10× board generator
Write a deterministic script (place under `scripts/` alongside the extractor, clearly marked `# THROWAWAY`) that:
- Reads the current board structure from `project/board/`
- Replicates it ~10 times under a temp directory (e.g. `$TMPDIR/board-10x-<date>/`)
- IDs in synthetic entries should be prefixed to avoid clashing (e.g. `SYNTH01_E01`, `SYNTH01_S01`, etc.)
- Generates valid `.md` frontmatter so the extractor prototype can parse them without error
- Is deterministic and idempotent: running it twice produces the same output

### 2. Hyperfine cold-walk latency measurement
Using `hyperfine` (install if not present: `brew install hyperfine`), run at least 10 iterations each of:
- **(a) Real current board** — run the T01 extractor against `project/`
- **(b) 10× synthetic board** — run the T01 extractor against the temp directory

For each measurement, use cold cache flushing between runs:
- macOS: `sudo purge` between hyperfine runs (or use `hyperfine --prepare 'sudo purge'`)
- If `sudo purge` is not available, note it in the report and use `hyperfine`'s built-in warmup/run separation

Capture the hyperfine output (both the human-readable table and `--export-json <file>`) so the raw numbers can be included in the measurement report.

## Acceptance Criteria
- [ ] Synthetic 10× board generator script exists, is runnable, and is marked `# THROWAWAY`
- [ ] Generator is deterministic: running it twice produces structurally identical output (same file count, same IDs)
- [ ] Extractor prototype (T01) runs successfully against the synthetic board (exit 0, valid JSON)
- [ ] `hyperfine` used for measurement (not `time` or manual loops)
- [ ] At least 10 runs completed for both (a) real board and (b) 10× synthetic board
- [ ] Cold cache flush attempted between runs (method documented if `sudo purge` unavailable)
- [ ] Hyperfine JSON export saved (e.g. `scripts/measurement-real.json` and `scripts/measurement-10x.json`) — these feed T03
- [ ] Hyperfine human-readable output saved or captured for inclusion in the measurement report
