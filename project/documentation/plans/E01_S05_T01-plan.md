# Plan: E01_S05_T01 — Training results parsers

## Goal
Create `skills/train/assets/results-parsers/` with type-specific Python parsers.

## Files
- `skills/train/assets/results-parsers/__init__.py`
- `skills/train/assets/results-parsers/classifiers.py` — accuracy, loss
- `skills/train/assets/results-parsers/transformers.py` — perplexity
- `skills/train/assets/results-parsers/nlp.py` — F1 score

## Design
Each module exposes a `parse(job_dir: Path) -> dict` function that:
1. Looks for `results.json` in the job dir
2. Falls back to scanning `training-results/` for JSON/CSV files
3. Returns a dict with type-specific keys (or empty dict if nothing found)
4. Never raises — always handles missing files gracefully
