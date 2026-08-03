---
id: E01_S05_T01
story_id: E01_S05
epic_id: E01
title: Implement training-results parser per training type
status: Done
date_created: 2026-04-29
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Implement training-results parser per training type

## Description
Implement a results parser that reads `training-results/` in a job directory and extracts structured metrics based on the training type:

- **classifiers**: reads `results.json` → extracts `accuracy`, `classification_report` (precision, recall, F1 per class)
- **transformers**: reads `training-results/logs/eval_results.json` → extracts `eval_loss`, `eval_accuracy`, per-epoch metrics if available
- **nlp**: reads `results.json` → extracts per-iteration losses and final entity/label F1 scores

Parser must return a normalised dict regardless of type:
```python
{ "type": "classifiers", "metrics": { ... }, "raw": { ... } }
```

Warn clearly (don't raise) if expected files are missing or malformed.

## Prerequisites
None — but training templates' `main.py` output format must be known (see training templates built in prior session).

## Acceptance Criteria
- [ ] Parser handles all three training types
- [ ] Returns normalised structure for each type
- [ ] Missing or malformed results files produce a warning, not a crash
- [ ] Parser is importable as a module AND runnable as a CLI (`python parser.py <job_dir> <type>`)
