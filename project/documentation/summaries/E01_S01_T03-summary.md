# Summary: E01_S01_T03 — CLI flag parsing and config.yaml merge

## What was done
Added three new flags to the `train new` subcommand in `skills/train/train_cli.py`:
- `--model VALUE` — overrides model name/type in config.yaml
- `--epochs N` — overrides training epochs/iterations
- `--batch-size N` — overrides batch size

Added `_FLAG_KEY_MAP` dict mapping each flag to the correct `config.yaml` dot-path per job type.
Added `_apply_cli_flags()` function that:
1. Reads the flag map for the current job type
2. Warns (non-fatal) for flags with no applicable key (e.g. `--epochs` for classifiers)
3. Calls `_patch_config()` to write overrides into the scaffolded `config.yaml`

## Acceptance criteria
- [x] `--model`, `--epochs`, `--batch-size` flags are parsed
- [x] Values are merged into the copied `config.yaml` under appropriate keys
- [x] Unrecognised flag combinations print a warning (not fatal)
