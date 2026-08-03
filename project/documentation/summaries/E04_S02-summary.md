# E04_S02 — Wire /convert into /train Interactive Wizard

## Status: Passed

## Summary
Wired the `/convert` skill into the `/train` interactive wizard so that non-CSV data
files entered by the user are automatically converted to CSV before job config is
written.

## Changes Made

### `skills/convert/convert_cli.py`
- Added `--yes` / `--no-confirm` flag to `main()` for non-interactive use
- Threaded `yes` parameter through `convert()` and `normalise_to_records()`
- `_confirm_object_conversion()` auto-confirms when `yes=True`

### `skills/train/train_cli.py`
- Added `CONVERT_EXTENSIONS` constant `{".json", ".jsonl", ".yaml", ".yml"}`
- Added `_auto_convert_data_file(file_path_str)` helper:
  - `.csv` or unknown extension → pass-through
  - File not found → pass-through with warning (defers error to job run)
  - Non-CSV file found → invokes `convert_cli.py --yes` as subprocess
  - On success → returns CSV output path with user-visible confirmation
  - On failure → aborts wizard with clear actionable error message
- Wired helper into `run_wizard()` after `data.train_file` field is captured

## Acceptance Criteria Results
- ✅ After the user enters a data file path, the tool checks the file extension
- ✅ If non-CSV, `/convert` is auto-invoked and the user is informed
- ✅ The converted CSV path is used in config.yaml (not the original)
- ✅ If `/convert` fails, wizard aborts with a clear error message (last error line shown)
- ✅ If file is already `.csv`, no conversion is attempted (pass-through)

## Test Results
1. `.json` input → auto-converted; config.yaml had `.csv` path ✅
2. `.jsonl` input → auto-converted; config.yaml had `.csv` path ✅
3. `.csv` input → no conversion attempted; original path used ✅
4. Corrupt `.json` input → wizard aborted with `JSONDecodeError` message ✅
5. Non-existent `.json` path → pass-through with warning ✅
