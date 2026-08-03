---
id: E01_S02
epic_id: E01
title: workflow: Config Block in Training Templates
status: Passed
date_created: 2026-04-29
date_started: 2026-05-05
date_completed: 2026-05-05
tasks:
  - E01_S02_T01
  - E01_S02_T02
---

# Story: workflow: Config Block in Training Templates

As a developer, I want all three template `config.yaml` files to ship with a fully documented `workflow:` block so that execution behaviour is explicit, self-documenting, and configurable out of the box without needing to read external docs.

## Acceptance Criteria
- [ ] `workflow:` section is added to `classifiers/input/config.yaml`, `transformers/input/config.yaml`, and `nlp/input/config.yaml`
- [ ] The block includes all five flags with inline comments: `auto_run`, `generate_start_sh`, `confirm_before_run`, `auto_summarize`, `auto_iterate`
- [ ] Defaults are sensible per type (e.g. `confirm_before_run: true` everywhere, `auto_run: false` as safe default)
- [ ] Each template's `README.md` includes a `## Workflow Configuration` section documenting every flag, its type, default, and effect

## Definition of Done
- [ ] All three `config.yaml` files updated
- [ ] All three `README.md` files updated
- [ ] Flags match exactly what the `/train` skill and `training_runner` MCP expect
