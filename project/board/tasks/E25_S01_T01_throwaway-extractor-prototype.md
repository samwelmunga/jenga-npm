---
id: E25_S01_T01
story_id: E25_S01
epic_id: E25
title: Throwaway extractor prototype — walk board & emit JSON node/edge structure
status: Passed
date_created: 2026-07-23
date_started: 2026-07-23
date_completed: 2026-07-23
assigned_to: developer
---

# Task: Throwaway extractor prototype — walk board & emit JSON node/edge structure

## Description
Write a single throwaway script (place under `scripts/` or another sensible path at implementer's discretion) that walks `project/board/`, `project/documentation/`, and `project/todo.md` and emits a JSON node/edge structure to stdout.

This script is **not** the S02 library. It is a spike-only prototype: clearly mark the top of the file with:

```
# THROWAWAY — spike prototype for E25_S01 latency measurement. Do not import.
```

The script should:
- Walk `project/board/epics/*.md`, `project/board/stories/*.md`, `project/board/tasks/*.md`
- Walk `project/documentation/plans/*.md`, `project/documentation/summaries/*.md`
- Parse `project/todo.md` line by line
- For each artifact, extract the key frontmatter fields and emit a `node` object
- Derive edges from `contains` (epic→story→task via frontmatter lists), `plans`/`summarizes` (filename convention), and `queued_as` (todo.md `E##_S##` refs)
- Output JSON to stdout — either a single `{"nodes": [...], "edges": [...]}` object or newline-delimited objects (implementer's choice, but must be parseable by `jq`)

**Artifact types to handle** (happy path only):
- `Epic`, `Story`, `Task`, `Plan`, `Summary`, `TodoEntry`

**Edges to derive**:
- `contains`: Epic→Story (from `stories:` frontmatter), Story→Task (from `tasks:` frontmatter)
- `plans`: Plan→Task/Story (from filename `E##_S##[_T##]-plan.md`)
- `summarizes`: Summary→Task/Story (from filename `E##_S##[_T##]-summary.md`)
- `queued_as`: TodoEntry→Story/Task (from `E##_S##` ref in line)

## Acceptance Criteria
- [ ] Script exists and is executable (or runnable via `node`/`python`/`bash` — implementer's choice)
- [ ] Script exits 0 and emits valid JSON to stdout when run against the current board
- [ ] Emitted JSON contains node entries for all 6 artifact types (Epic, Story, Task, Plan, Summary, TodoEntry)
- [ ] Emitted JSON contains edge entries for all 4 edge types where applicable (contains, plans, summarizes, queued_as)
- [ ] Script is marked `# THROWAWAY` at the top
- [ ] Script is deterministic: repeated runs on the same board produce the same output (or structurally equivalent)
- [ ] No dependencies that require a build step — it must run from a fresh shell with standard tooling (bash, node, python3 — whichever is chosen)
