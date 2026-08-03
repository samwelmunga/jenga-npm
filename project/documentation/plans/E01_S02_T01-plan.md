# Plan: E01_S02_T01 — Add workflow: block to all three template config.yaml files

## What
Add a `workflow:` top-level section to each of the three training template `config.yaml` files.

## Files to modify
- `.training/template/classifiers/input/config.yaml`
- `.training/template/transformers/input/config.yaml`
- `.training/template/nlp/input/config.yaml`

## Design
Append the `workflow:` block at the end of each file with all five flags and inline YAML comments:
- `auto_run: false` — safe default, do not auto-run on scaffold
- `generate_start_sh: true` — emit start.sh for manual use
- `confirm_before_run: true` — always prompt before executing
- `auto_summarize: true` — surface results after training
- `auto_iterate: false` — reserved, off by default

## Verification
Parse each file with `yaml.safe_load` and assert all five keys are present in `workflow:`.
