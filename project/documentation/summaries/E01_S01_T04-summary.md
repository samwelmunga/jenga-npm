# Summary: E01_S01_T04 — Workflow block and next-steps output

## What was done
Added `_print_next_steps()` function to `skills/train/train_cli.py` that:
1. Loads `dest/input/config.yaml` and reads the `workflow:` block
2. Prints numbered next-step instructions tailored to the workflow flags:
   - Step 1: add training data to `input/data/`
   - Step 2: review `config.yaml`
   - Step 3: run training (mentions `start.sh` when `generate_start_sh: true`)
3. Appends informational notes for `confirm_before_run` and `auto_summarize` flags

Called from `cmd_new()` after scaffolding + flag application.

## Acceptance criteria
- [x] If config.yaml contains a `workflow:` key, its behaviour flags drive the next-step output
- [x] Output is clear and actionable (numbered steps, specific file paths)
