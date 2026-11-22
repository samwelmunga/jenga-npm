# E90_S03 usage backfill: coverage report and verification

Produced by `E90_S03_T04` on 2026-11-19 (run of the backfill 2026-11-19; this report written 2026-11-19, about 16:40 UTC
by the machine clock). Stored at `project/documentation/E90_S03-usage-backfill-coverage-report.md`.

Evidence files: `project/data/E90_S03_usage-coverage-before.json` (before `E90_S03_T02`),
`project/data/E90_S03_usage-coverage-after.json` (after `E90_S03_T02`, before `E90_S03_T03`),
`project/data/E90_S03_usage-coverage-final.json` (written by this task, after `E90_S03_T03`, with `--list`, so it carries
the 1281 still-unmeasured IDs), the eight `project/data/E90_S03_backfill-runs/out_batch_*.json` files, and
`project/documentation/task-usage-without-cost-units.md`.

## Coverage before and after

Produced by `scripts/task-usage-coverage.sh`. `possibly incomplete` and `no cost units` are subsets of `measured`.

| Moment | Total | Measured | Unmeasured | Unreadable | Possibly incomplete | Measured without cost units |
|---|---|---|---|---|---|---|
| Before (start of `E90_S03_T02`) | 1805 | 474 | 1331 | 0 | 0 | 474 |
| After `E90_S03_T02` | 1805 | 524 | 1281 | 0 | 0 | 474 |
| After `E90_S03_T03` (final) | 1805 | 524 | 1281 | 0 | 2 | 16 |

Every row adds up: 474 + 1331 + 0 = 524 + 1281 + 0 = 1805.

## Check 1: reconciliation

- `measured + unmeasured + unreadable = total` holds on all three rows (above).
- The change in `measured` is 524 - 474 = 50. The eight batch files report `persisted` for 4 (batch 02) + 1 (batch 05) + 45
  (batch 07) = 50 tasks. They agree.
- Five of the eight batch files (00, 01, 03, 04, 06) are empty (0 bytes). Those batches exited with code 8 ("every requested
  `--task` ID has no transcripts"), which prints nothing on stdout; the exit codes and timings are in the run's
  `progress.log`: batches 00, 01, 03, 04, 06 exit 8; batches 02, 05, 07 exit 0. So the empty files are the batches in which
  nothing could be measured, not lost output; the 50-versus-50 reconciliation above is the proof that nothing else was
  persisted.
- Of the 1331 unmeasured tasks, 1281 remain unmeasured (their transcripts are gone, "not measured (possibly pruned)"); only
  50 had transcripts.

## Check 2: spot check (15 tasks, 15 different epics)

Method: one read-only `scripts/task-usage.sh --report --task <id> ...` over the 15 IDs (a single background run, slow
wall on this machine), compared against the usage lines in each task file: `usage_input_tokens`, `usage_output_tokens`,
`usage_cache_write_tokens`, `usage_cache_read_tokens`, `usage_total_tokens`, `usage_transcripts` and `usage_cost_units`.
Eight tasks come from the `E90_S03_T02` backfill and seven from the `E90_S03_T03` cost-unit update. None carries
`usage_possibly_incomplete`, so no `kept-stored` difference applies to any of them.

| Task | Epic | Source | Result |
|---|---|---|---|
| E28_S22_T01 | E28 | T02 | equal in all 7 fields |
| E53_S16_T01 | E53 | T02 | equal |
| E89_S06_T20 | E89 | T02 | equal |
| E92_S08_T01 | E92 | T02 | equal |
| E95_S01_T03 | E95 | T02 | equal |
| E98_S01_T03 | E98 | T02 | equal |
| E99_S01_T05 | E99 | T02 | equal |
| E100_S01_T02 | E100 | T02 | equal |
| E43_S01_T01 | E43 | T03 | equal |
| E51_S03_T04 | E51 | T03 | equal |
| E72_S06_T01 | E72 | T03 | equal |
| E76_S01_T01 | E76 | T03 | equal |
| E80_S01_T01 | E80 | T03 | equal |
| E85_S01_T01 | E85 | T03 | equal |
| E87_S01_T01 | E87 | T03 | equal |

15 of 15 equal, no difference. The report also printed `transcript-without-usage` warnings for some transcripts (excluded from
sums by design, not counted as zero); they did not touch these tasks' values.

## Check 3: only `usage_*` lines changed

Command (run for `de3d99823`, the `E90_S03_T02` backfill commit, and `d057be2a8`, the `E90_S03_T03` commit):

```
git show --format= -U0 <sha> -- project/board/tasks | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' | grep -vE '^[+-]usage_'
```

Result: no output for either commit, so every added or removed line in task files starts with `usage_` (192 usage lines in
`de3d99823`, 1404 in `d057be2a8`). The non-task files in those commits are the data and documentation files named in the
commit messages (`project/data/E90_S03_*` and `project/documentation/task-usage-without-cost-units.md`); no script, test or
board file other than task files was changed.

Limits of this check, stated plainly:

- `de3d99823` contains the usage lines of 24 of the 50 persisted tasks. The other 26 persisted tasks are not in that commit,
  because their files were already modified or untracked by other agents in the shared working tree: 16 are untracked
  (`E90_S01_T02` to `E90_S01_T10`, `E90_S02_T01` to `E90_S02_T05`, `E90_S03_T01`, `E90_S03_T02`) and 10 are tracked with other
  uncommitted changes (`E100_S01_T01`, `E95_S02_T04`, `E95_S02_T09`, `E99_S01_T01`, `T02`, `T03`, `T04`, `T07`, `T12`, `T16`).
  Their usage lines are on disk but not committed here, and for the 10 tracked ones the working-tree diff also holds the other
  agents' changes (status, checkboxes), so the "usage only" claim cannot be shown for them from git. This task did not commit
  or alter them.
- Eight further task files carry backfilled or updated usage lines on disk but are untracked and owned by other agents:
  `E90_S01_T01`, `E92_S13_T01` to `E92_S13_T07`. They were not committed by this task.

## Exceptions to `E90_S03_T03` acceptance criterion 2

Criterion 2 of `E90_S03_T03` allowed raw fields to stay unchanged. Six tasks had their raw sums **raised** (never lowered) by
the update, because their sessions were still running when the persist ran: `E77_S04_T02` (1989102 to 4364749 total tokens,
3 to 4 transcripts), `E92_S09_T01` (15597732 to 15719631), `E92_S09_T02` (18627475 to 18750172), `E92_S09_T03` (17695667 to
17817850), `E92_S09_T04` (38150349 to 38271378), and `E90_S01_T01` (untracked, so not visible in git). The rule that a stored
value is never lowered held in every case. These six are an acknowledged break of that criterion, not a data error.

## Tasks that stay without a measurement or derived number

- **Unmeasured (transcripts gone): 1281 tasks.** Listed in `project/data/E90_S03_usage-coverage-final.json`, key
  `unmeasured_ids`. They carry no `usage_*` field and are never shown as 0.
- **Measured without cost units: 16 tasks** (14 with no transcripts, 2 with partial transcripts, which also carry
  `usage_possibly_incomplete: true`). Listed with reasons in `project/documentation/task-usage-without-cost-units.md`.
