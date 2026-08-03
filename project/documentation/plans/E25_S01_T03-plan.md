# Execution Plan: Measurement report and plan-doc decision update

**Task ID:** E25_S01_T03
**Story ID:** E25_S01
**Epic ID:** E25
**Date:** 2026-07-23
**Agent:** developer
**Session ID:** 4832cd66-1151-4980-94dc-c61f78f0497f

---

## Task Summary

Turn the T02 benchmark artifacts into a formal measurement report with a machine-readable decision line, update `board-index-substrate.md` §7 with the measured number and report link, and document synthetic-board cleanup plus the throwaway status of the spike scripts.

## Implementation Approach

1. Parse `scripts/measurement-real.json` and `scripts/measurement-10x.json` to compute median and p95 for both benchmark sets.
2. If the real-board p95 exceeds 150 ms, run the extractor with profiling across repeated real-board runs and summarize the dominant step for a required `DECISION: REOPEN` bottleneck section.
3. Compute board-file counts for the real and synthetic inputs used in the benchmark.
4. Write `project/documentation/plans/board-index-substrate-measurement.md` with metadata, methodology, results, decision, bottleneck analysis if required, and cleanup instructions.
5. Update §7 of `project/documentation/plans/board-index-substrate.md` to replace the rough latency guess with the measured real-board number and a reference to the measurement report.
6. Remove the generated synthetic board directory after collecting the metadata, then write the execution summary and final commit.

## Files to Change

| File | Planned Change |
|------|----------------|
| `project/documentation/plans/E25_S01_T03-plan.md` | Add this execution plan |
| `project/documentation/plans/board-index-substrate-measurement.md` | Add measurement report and decision |
| `project/documentation/plans/board-index-substrate.md` | Update §7 with measured latency and report link |
| `project/documentation/summaries/E25_S01_T03-summary.md` | Add execution summary after implementation |

## Risks & Notes

- The benchmark uses an attempted-but-unavailable cold-cache flush path (`sudo -n purge` / `purge`), so the report must describe that limitation explicitly.
- Because the real-board p95 may exceed the 150 ms gate, profiling evidence must be strong enough to name a dominant extraction step.
- The synthetic board directory must be removed before final handoff or clearly documented if retained; this implementation will prefer cleanup.
