# E01_S08 — Interactive Train Wizard: Execution Summary

## What Was Implemented

An interactive wizard mode for `train new`, triggered by `--interactive` (with optional `--full`), that guides the user through critical configuration decisions and automatically patches `config.yaml` in the scaffolded job.

### Features delivered

| Feature | Status |
|---------|--------|
| `--interactive` / `-i` flag parsed in `train new` | ✅ |
| `--full` flag expands prompts to all configurable fields | ✅ |
| Prompt loop: job name, type, critical config fields | ✅ |
| Each prompt includes an inline hint/description | ✅ |
| SIGINT (Ctrl+C) handler with keep/delete prompt | ✅ |
| Existing positional `train new <type> <name>` flow preserved | ✅ |
| `config.yaml` patched with wizard responses via PyYAML | ✅ |

## Files Created / Modified

| File | Change |
|------|--------|
| `skills/train/train_cli.py` | **Modified** — added wizard schemas, `run_wizard()`, SIGINT handler, `--interactive`/`--full` flags, `_scaffold_job()` helper |
| `skills/train/SKILL.md` | **Modified** — documented `--interactive`, `--full`, wizard flow, Ctrl+C behaviour |
| `project/documentation/plans/E01_S08-plan.md` | **Created** — execution plan |
| `project/documentation/summaries/E01_S08-summary.md` | **Created** — this file |
| `project/board/stories/E01_S08_interactive-train-wizard.md` | **Modified** — status → Passed |

## How to Test

### Positional mode (no regression)
```bash
python3 skills/train/train_cli.py new classifiers my-job
# ✅ Scaffolded job 'my-job' from template 'classifiers' at jobs/my-job/
```

### Error when args missing without --interactive
```bash
python3 skills/train/train_cli.py new
# ❌ Positional mode requires both <type> and <job-name>.
```

### Interactive wizard (critical fields)
```bash
python3 skills/train/train_cli.py new --interactive
# Follow prompts for job name, type, 5 critical config fields
```

### Interactive wizard (all fields)
```bash
python3 skills/train/train_cli.py new --interactive --full
# Same as above but prompts for every field in config.yaml
```

### Ctrl+C keep/delete
```bash
python3 skills/train/train_cli.py new --interactive
# Enter a job name, enter a type, then press Ctrl+C
# Wizard asks: Delete scaffolded directory '...'? [y/N]
```

### Verify config.yaml is patched
After a wizard run, inspect `jobs/<name>/input/config.yaml` and confirm values match what was entered.

## Notable Decisions

1. **Positional args made optional (`nargs='?'`)** — Allows `--interactive` without type/name, while validation in `cmd_new()` enforces their presence in non-interactive mode.

2. **Scaffold-then-configure** — The directory is created before the config prompts so the SIGINT handler can offer to clean it up at any point.

3. **Explicit field schema** — All prompt copy, hints, and defaults are defined in `WIZARD_FIELDS`. This keeps UX consistent and easy to extend.

4. **Type coercion in `_set_nested()`** — Infers target type from the existing YAML value (int, float, bool) and coerces user input accordingly, preserving correct YAML types.

5. **PyYAML used for config patching** — Comments are not preserved (acceptable for scaffolded templates), but the structure is valid YAML that users can freely edit afterward.
