# Plan: E01_S02_T02 — Document workflow flags in each template README

## What
Add a `## Workflow Configuration` section to each of the three template READMEs.

## Files to modify
- `.training/template/classifiers/README.md`
- `.training/template/transformers/README.md`
- `.training/template/nlp/README.md`

## Design
Append a table after the Output section covering all five `workflow:` flags:
- name, type, default, and plain-English description of each flag's effect
- Descriptions reflect how the `/train` skill and `training_runner` MCP interpret each flag

## Prerequisite
E01_S02_T01 (Passed) — flags are finalized in config.yaml templates.
