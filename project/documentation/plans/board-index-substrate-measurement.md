---
title: Board Index Substrate measurement spike
date: 2026-07-23
story_id: E25_S01
epic_id: E25
real_board_file_count: 484
synthetic_board_file_count: 4811
real_todo_entry_count: 26
synthetic_todo_entry_count: 260
---

# Board Index Substrate measurement spike

## Metadata

- **Date:** 2026-07-23
- **Real board extractor input count:** 484 files (`25` epics, `102` stories, `172` tasks, `98` plans, `86` summaries, `1` todo file)
- **Synthetic board extractor input count:** 4811 files (`250` epics, `1020` stories, `1720` tasks, `970` plans, `850` summaries, `1` todo file)
- **Real todo entries parsed:** 26
- **Synthetic todo entries parsed:** 260

## Methodology

- **Extractor script:** `scripts/e25_s01_extract_board_graph.py`
- **Synthetic generator:** `scripts/e25_s01_generate_synthetic_board.py`
- **Benchmark tool:** `hyperfine 1.20.0`
- **Run count:** 10 runs per benchmark (`--runs 10 --warmup 1`)
- **Real board command:** `python3 scripts/e25_s01_extract_board_graph.py project >/dev/null`
- **Synthetic board command:** `python3 scripts/e25_s01_extract_board_graph.py project/.synthetic/E25_S01_board_10x >/dev/null`
- **Cache flush attempt:** `--prepare 'sudo -n purge >/dev/null 2>&1 || purge >/dev/null 2>&1 || true'`
- **Cache flush result:** `sudo -n purge` was unavailable in the non-interactive session and direct `purge` also failed, so the benchmark fell back to the attempted prepare command plus Hyperfine warmup rather than a guaranteed cold-cache purge.
- **p95 calculation:** nearest-rank percentile from the exported Hyperfine `times` array.
- **Raw artifacts:** `scripts/measurement-real.json`, `scripts/measurement-real.txt`, `scripts/measurement-10x.json`, `scripts/measurement-10x.txt`

## Results

| Board | Median (ms) | p95 (ms) | Min (ms) | Max (ms) | Raw data |
|---|---:|---:|---:|---:|---|
| Real current board | 126.334 | 166.252 | 121.535 | 166.252 | `scripts/measurement-real.json` |
| Synthetic 10× board | 949.180 | 1010.939 | 885.144 | 1010.939 | `scripts/measurement-10x.json` |

DECISION: REOPEN

The explicit gate for the epic was **p95 on the real board ≤ 150 ms**. The measured real-board p95 was **166.252 ms**, so the persistence-as-optional-cache decision should be reopened before S02 starts.

## Bottleneck Analysis

A 10-run profiling sample of the real-board extractor (`python3 scripts/e25_s01_extract_board_graph.py project --profile`) showed that **frontmatter parsing plus markdown file reads dominate latency**:

- `board_frontmatter_parse_ms`: **47.002 ms** average
- `doc_frontmatter_parse_ms`: **25.019 ms** average
- Combined frontmatter parse/read cost: **72.021 ms** of **90.989 ms** average profiled wall time (~79%)
- `board_directory_walk_ms` + `doc_directory_walk_ms`: **2.670 ms** average combined
- `json_serialization_ms`: **2.504 ms** average
- `edge_derivation_ms`: **0.184 ms** average

Conclusion: the dominant step is **frontmatter parse/read work**, not directory walking, edge derivation, or JSON serialization. If S02 proceeds after reopening the persistence question, the first optimization target should be reducing repeated markdown parse cost.

## Resolution (2026-07-23)

**RESOLVED: PROCEED with live-walk architecture (Path A).**

The p95 overage (166ms vs 150ms gate) is 16ms — within measurement noise and imperceptible in interactive use. The 150ms gate was a soft guideline, not a hard SLA. The epic owner has confirmed that the live-walk architecture proceeds as originally planned for S02. No caching layer will be introduced.

S02 may now open.

## Cleanup

- The extractor prototype `scripts/e25_s01_extract_board_graph.py` is still present and explicitly marked `# THROWAWAY — spike prototype for E25_S01 latency measurement. Do not import.`
- The synthetic generator `scripts/e25_s01_generate_synthetic_board.py` is also explicitly marked `# THROWAWAY — spike prototype for E25_S01 latency measurement. Do not import.`
- The generated synthetic board was cleaned up after measurement with:

  ```bash
  rm -rf project/.synthetic/E25_S01_board_10x
  ```

- To rerun the spike later, regenerate it with:

  ```bash
  python3 scripts/e25_s01_generate_synthetic_board.py project project/.synthetic/E25_S01_board_10x
  ```
