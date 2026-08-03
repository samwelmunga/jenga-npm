---
id: E01_S01_T03
story_id: E01_S01
epic_id: E01
title: Implement CLI flag parsing and config.yaml merge
status: Done
date_created: 2026-04-29
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Implement CLI flag parsing and config.yaml merge

## Description
After scaffolding the job directory, parse any CLI flags passed to `/train new` (e.g. `--model xgboost`, `--epochs 10`, `--learning-rate 2e-5`) and merge them into the corresponding keys in the scaffolded `config.yaml`. The merge must be non-destructive — only the specified keys are overwritten; all other config values remain as templated.

## Prerequisites
None.

## Acceptance Criteria
- [ ] Known flags map to correct `config.yaml` keys (document the mapping in the skill)
- [ ] Unknown flags produce a warning but do not abort scaffolding
- [ ] Merge is applied after copy so the template original is never modified
- [ ] Resulting `config.yaml` is valid YAML after merge
