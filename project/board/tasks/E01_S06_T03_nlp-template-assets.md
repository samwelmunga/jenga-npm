---
id: E01_S06_T03
story_id: E01_S06
epic_id: E01
title: Scaffold nlp template assets
status: Passed
date_created: 2026-04-29
date_started:
date_completed: 2026-05-05
---

# Task: Scaffold nlp template assets

Create the full asset set for the `nlp` training type template directory.

## Description

Inside the `nlp` template directory, create:

- `train.py` — training script that accepts a `--smoke` flag to run one epoch using the stub data. Must produce at least one output artifact in smoke mode.
- `validate.py` — pre-flight script that (1) checks stub text file(s) exist, (2) opens and reads content, (3) verifies files are non-empty and contain readable text. Exits zero on pass; exits non-zero with descriptive error on failure.
- `data/train.txt` — one or more raw `.txt` files with non-empty text content. Must be parseable by `validate.py` out of the box.
- `requirements.txt` — pinned dependencies for the NLP training type.

## Acceptance Criteria
- `validate.py` passes when run against the included stub `.txt` file(s)
- `train.py --smoke` completes without error and produces an output artifact
- No references to shared lib or other template types
