---
id: E01_S01
epic_id: E01
title: /train Skill — Job Scaffolding
status: Done
date_created: 2026-04-29
date_started: 2026-05-05
date_completed: 2026-05-05
tasks:
  - E01_S01_T01
  - E01_S01_T02
  - E01_S01_T03
  - E01_S01_T04
---

# Story: /train Skill — Job Scaffolding

As a developer, I want `/train new <type> <job-name>` to scaffold a ready-to-use job directory from the appropriate template so that I don't manually copy templates or wire config every time I start a training job.

## Acceptance Criteria
- [ ] Running `/train new <type> <job-name>` creates `.training/jobs/<job-name>/` by copying `.training/template/<type>/`
- [ ] Supported types are `classifiers`, `transformers`, and `nlp`; an unsupported type produces a clear error
- [ ] If `<job-name>` already exists, the job is created with an auto-suffix (`-2`, `-3`, …) and the user is notified of the rename
- [ ] CLI flag overrides (e.g. `--model xgboost`, `--epochs 10`) are merged into the correct keys in the scaffolded `config.yaml`
- [ ] The `workflow:` block is read from the merged config and the skill branches accordingly: invokes `training_runner` MCP if `auto_run: true`, calls `start.sh` generation if `generate_start_sh: true`, prompts user if `confirm_before_run: true`
- [ ] On completion, a clear next-steps message is printed: job path, how to edit config, how to run

## Definition of Done
- [ ] Skill file exists at `skills/train/SKILL.md` and is invocable as `/train`
- [ ] All acceptance criteria pass
- [ ] Collision behaviour is tested with an existing job directory
