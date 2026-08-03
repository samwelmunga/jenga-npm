# E04_S02 — Wire /convert into /train Interactive Wizard

## Goal
After a user enters a data file path in the `/train` interactive wizard, automatically
detect non-CSV files and invoke `/convert` to produce a CSV before writing config.yaml.

## Approach

### 1. Add `--yes` flag to `convert_cli.py`
`convert_cli.py` prompts for confirmation when the top-level data structure is a dict
(`{}`). In automation mode (wizard), we need to bypass this. We add a `--yes` /
`--no-confirm` flag that auto-confirms the prompt.

### 2. Add `_auto_convert_data_file()` helper in `train_cli.py`
A function that:
- Receives the raw data file path entered by the user
- Checks the file extension
- If `.csv` → returns path unchanged (pass-through)
- If `.json`, `.jsonl`, `.yaml`, `.yml` and file exists → runs `convert_cli.py --yes`
- On success → returns the `.csv` output path and prints a confirmation message
- On failure → prints a clear error message and exits (aborts wizard)
- If file doesn't exist → returns path unchanged (can't convert; train job will fail later)

### 3. Wire the helper into `run_wizard()`
In the field-collection loop, after collecting a response for key `data.train_file`,
call `_auto_convert_data_file()` and update the response value before moving on.

## Files Modified
- `skills/convert/convert_cli.py` — add `--yes` flag
- `skills/train/train_cli.py` — add helper + wire into wizard loop

## Test Cases
1. `.json` file → auto-converts, config.yaml has `.csv` path
2. `.csv` file → no conversion, config.yaml has original `.csv` path
3. Corrupt/missing conversion → wizard aborts with error
