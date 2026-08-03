# Plan: E01_S01_T04 — Workflow block and next-steps output

## Goal
After scaffolding, if `config.yaml` contains a `workflow:` key, read it and print
clear, actionable next-step instructions.

## Files to touch
- `skills/train/train_cli.py` — add `_print_next_steps()` helper, call from `cmd_new()`

## Design

### `_print_next_steps(dest, job_name)`
1. Load `dest/input/config.yaml` with PyYAML
2. If `workflow:` key is absent or yaml unavailable → print a generic next-steps line
3. Otherwise generate tailored hints:
   - If `generate_start_sh: true` → mention `start.sh`
   - If `confirm_before_run: true` → note confirmation prompt
   - Always print: `Next: jenga train run jobs/<job-name>`

### Output format
```
📋 Next steps for '<job-name>':
   1. Add your training data to jobs/<job-name>/input/data/
   2. Review jobs/<job-name>/input/config.yaml
   3. Run: python skills/train/train_cli.py run jobs/<job-name>
      (or execute jobs/<job-name>/start.sh directly)
   ℹ️  confirm_before_run is enabled — you will be prompted before training starts.
```

## Verification
- Scaffolding any type prints at least one next-step line
- If workflow block is present, start.sh and confirm_before_run are mentioned when true
