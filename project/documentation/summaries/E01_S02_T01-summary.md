# Summary: E01_S02_T01 — Add workflow: block to all three template config.yaml files

## What was implemented
Added a `workflow:` block to all three training template `config.yaml` files:
- `.training/template/classifiers/input/config.yaml`
- `.training/template/transformers/input/config.yaml`
- `.training/template/nlp/input/config.yaml`

## workflow: block added
```yaml
workflow:
  auto_run: false            # Run training immediately when /train is invoked
  generate_start_sh: true    # Emit a start.sh script for manual execution
  confirm_before_run: true   # Prompt for confirmation before executing training
  auto_summarize: true       # Parse and surface results after training completes
  auto_iterate: false        # Re-run with adjusted config based on results (reserved)
```

## Verification
All three files were parsed with `yaml.safe_load` — all valid YAML, all five workflow keys present.

## Acceptance criteria
- [x] All three `config.yaml` files contain the `workflow:` block
- [x] All five flags present with correct defaults and inline comments
- [x] Files remain valid YAML after the addition
