# Plan: E01_S04_T01 — start.sh template and generation logic

## Goal
Generate an executable `start.sh` in the job directory when `train new` scaffolds a job.

## Status
Already implemented as `_generate_start_sh()` in `skills/train/train_cli.py` (done as part of E01_S01_T04).

## What was built
- `_generate_start_sh(dest, job_type)` writes `start.sh` with:
  1. `set -euo pipefail`
  2. `cd` to the script's own directory
  3. Activates `venv/bin/activate` if present
  4. Installs `requirements.txt` if present
  5. Runs `python train.py`
- `start_sh.chmod(0o755)` makes it executable
- Called from `cmd_new()` after scaffolding and flag patching
