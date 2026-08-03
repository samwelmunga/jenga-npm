# Summary: E01_S05_T01 — Training results parsers per type

## What was done
Created `skills/train/assets/results-parsers/` with:

| File | Purpose |
|------|---------|
| `__init__.py` | Package marker; lists parser names |
| `classifiers.py` | Parses accuracy, precision, recall, f1_score, model_type |
| `transformers.py` | Parses perplexity (derived from eval_loss), eval_loss, train_loss, epochs, model_name |
| `nlp.py` | Parses f1, precision, recall, model_name, task, iterations |

Each parser:
1. Tries `results.json` at job root first
2. Falls back to scanning `training-results/*.json` and type-specific files (trainer_state.json, scores.json)
3. Returns empty dict on missing files — never raises

## Acceptance criteria
- [x] Separate parser functions for each type
- [x] classifiers: accuracy/f1_score; transformers: perplexity; nlp: F1
- [x] Handles missing files gracefully
