---
id: E01_S06_T02
story_id: E01_S06
epic_id: E01
title: Scaffold transformers template assets
status: Passed
date_created: 2026-04-29
date_started:
date_completed: 2026-05-05
---

# Task: Scaffold transformers template assets

Create the full asset set for the `transformers` training type template directory.

## Description

Inside the `transformers` template directory, create:

- `train.py` — training script that accepts a `--smoke` flag to run one epoch using the stub data. Must produce at least one output artifact in smoke mode.
- `validate.py` — pre-flight script that (1) checks the stub data file exists, (2) reads at least one token sequence record, (3) verifies structural shape (e.g. non-empty sequences, expected format). Exits zero on pass; exits non-zero with descriptive error on failure.
- `data/train.txt` (or equivalent) — minimal token sequence stub file. Newline-delimited sequences readable without additional preprocessing.
- `requirements.txt` — pinned dependencies for the transformer training type.

## Acceptance Criteria
- `validate.py` passes when run against the included stub data
- `train.py --smoke` completes without error and produces an output artifact
- No references to shared lib or other template types
