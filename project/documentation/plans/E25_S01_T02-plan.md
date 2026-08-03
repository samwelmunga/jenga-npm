# Execution Plan: Synthetic board generation and latency measurement

**Task ID:** E25_S01_T02
**Story ID:** E25_S01
**Epic ID:** E25
**Date:** 2026-07-23
**Agent:** developer
**Session ID:** 4832cd66-1151-4980-94dc-c61f78f0497f

---

## Task Summary

Create a deterministic throwaway generator that expands the current board structure to a synthetic 10× project tree, then benchmark the T01 extractor with `hyperfine` on both the real board and the synthetic board, saving machine-readable and human-readable results for the measurement report.

## Implementation Approach

1. Add a Python 3 generator script under `scripts/`, marked `# THROWAWAY`, that copies the required board and documentation files into a synthetic project root and prefixes all board IDs deterministically for ten replicas.
2. Rewrite frontmatter references inside copied epics, stories, tasks, plan filenames, summary filenames, and todo lines so the synthetic extractor input stays internally consistent and collision-free.
3. Validate the generator by producing the synthetic tree twice, checking file counts and identical content hashes, and verifying the extractor exits 0 with valid JSON against the generated root.
4. Install `hyperfine` with Homebrew if it is missing, then benchmark the extractor on the real `project/` tree and on the synthetic root for at least 10 runs each, exporting JSON plus human-readable reports.
5. Attempt cold-cache flushing with `sudo purge` via `hyperfine --prepare`; if unavailable in this non-interactive environment, preserve the attempted command and document the fallback in T03 artifacts.
6. Clean the generated synthetic board directory after measurement and write the execution summary with validation and measurement artifact locations.

## Files to Change

| File | Planned Change |
|------|----------------|
| `project/documentation/plans/E25_S01_T02-plan.md` | Add this execution plan |
| `scripts/e25_s01_generate_synthetic_board.py` | Add deterministic 10× synthetic board generator |
| `scripts/measurement-real.json` | Save hyperfine JSON export for real-board runs |
| `scripts/measurement-10x.json` | Save hyperfine JSON export for synthetic-board runs |
| `scripts/measurement-real.txt` | Save human-readable hyperfine output for real-board runs |
| `scripts/measurement-10x.txt` | Save human-readable hyperfine output for synthetic-board runs |
| `project/documentation/summaries/E25_S01_T02-summary.md` | Add execution summary after measurements |

## Risks & Notes

- The environment may not allow interactive `sudo purge`; the measurement flow must still use `hyperfine` and document the failed cold-cache attempt cleanly.
- The generator must avoid `/tmp`; synthetic output will be created under the repository and removed after measurement.
- Only the directories needed by the extractor will be generated inside the synthetic project root.
