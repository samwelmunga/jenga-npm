---
id: E01_S06_T01
story_id: E01_S06
epic_id: E01
title: Scaffold classifiers template assets
status: Passed
date_created: 2026-04-29
date_started: 2026-04-29
date_completed: 2026-04-29
---

# Task: Scaffold classifiers template assets

Create the full asset set for the `classifiers` training type template directory.

## Description

Inside the `classifiers` template directory, create:

- `train.py` — training script that accepts a `--smoke` flag to run one epoch using the stub data. Must produce at least one output artifact (model checkpoint or `results.json`) in smoke mode.
- `validate.py` — pre-flight script that (1) checks the stub data file exists, (2) opens it and reads one row, (3) verifies expected column names are present. Exits zero on pass with a human-readable message; exits non-zero on failure with a descriptive error.
- `data/train.csv` — minimal stub CSV with labeled rows. Must include at minimum a features column and a label column. Must be parseable by `validate.py` out of the box.
- `requirements.txt` — pinned dependencies for the classifier training type.

## Acceptance Criteria
- `validate.py` passes when run against the included stub CSV
- `train.py --smoke` completes without error and produces an output artifact
- No references to shared lib or other template types
