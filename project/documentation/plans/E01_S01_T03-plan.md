# Plan: E01_S01_T03 — CLI flag parsing and config.yaml merge

## Goal
Add `--model`, `--epochs`, `--batch-size` flags to `train new`. Merge into the
scaffolded `config.yaml` under the appropriate keys, warn on unrecognised flags.

## Files to touch
- `skills/train/train_cli.py` — add flags to `new` parser, apply in `cmd_new()`

## Design

### Flag → config key mapping (by job type)
| Flag | classifiers | transformers | nlp |
|------|-------------|--------------|-----|
| `--model` | `model.type` | `model.name` | `model.name` |
| `--epochs` | (warn: no epochs key) | `training.num_train_epochs` | `training.n_iter` |
| `--batch-size` | (warn: no batch key) | `training.per_device_train_batch_size` | `training.batch_size` |

### Steps in `cmd_new()` (positional mode)
1. Scaffold the job directory as before
2. Build `overrides` dict from provided flags using the type-specific key map
3. Warn (not fatal) if a flag has no mapped key for the current type
4. Call `_patch_config(dest, job_type, overrides)` to write changes

### PyYAML dependency
If yaml is not installed, print a warning and skip the patch (non-fatal).

## Verification
- `train new classifiers foo --model gradient_boosting` writes `model.type: gradient_boosting`
- `train new transformers bar --epochs 5` writes `training.num_train_epochs: 5`
- `train new classifiers baz --epochs 10` prints a warning but does not crash
