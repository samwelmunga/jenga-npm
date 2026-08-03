---
id: E01_S02_T01
story_id: E01_S02
epic_id: E01
title: Add workflow: block to all three template config.yaml files
status: Passed
date_created: 2026-04-29
date_started:
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Add workflow: block to all three template config.yaml files

## Description
Add a `workflow:` top-level section to each of the three training template `config.yaml` files:
- `.training/template/classifiers/input/config.yaml`
- `.training/template/transformers/input/config.yaml`
- `.training/template/nlp/input/config.yaml`

Each block must include all five flags with inline YAML comments explaining the flag:

```yaml
workflow:
  auto_run: false            # Run training immediately when /train is invoked
  generate_start_sh: true    # Emit a start.sh script for manual execution
  confirm_before_run: true   # Prompt for confirmation before executing training
  auto_summarize: true       # Parse and surface results after training completes
  auto_iterate: false        # Re-run with adjusted config based on results (reserved)
```

Defaults should be safe: `auto_run: false`, `confirm_before_run: true`, `auto_summarize: true`, `generate_start_sh: true`.

## Prerequisites
None.

## Acceptance Criteria
- [ ] All three `config.yaml` files contain the `workflow:` block
- [ ] All five flags are present with correct defaults and inline comments
- [ ] Files remain valid YAML after the addition
