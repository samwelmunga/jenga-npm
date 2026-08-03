---
id: E01
title: Model Training Agentic Workflow
status: Done
date_created: 2026-04-29
date_started:
date_completed: 2026-05-10
stories:
  - E01_S01
  - E01_S02
  - E01_S03
  - E01_S04
  - E01_S05
  - E01_S06
  - E01_S07
  - E01_S08
---

# Epic: Model Training Agentic Workflow

## Purpose
Deliver an end-to-end agentic workflow for scaffolding, executing, and surfacing results from ML training jobs. Triggered by a single `/train` command, the workflow copies the appropriate template, merges user-supplied config overrides, optionally executes training via a managed MCP subprocess or emits a `start.sh` for manual execution, and surfaces structured results (terminal, markdown, JSON, and type-specific HTML dashboard) on completion.

All execution behaviours are opt-in and controlled via a `workflow:` block in `config.yaml` and/or CLI flags.

## Definition of Done
- [ ] `/train new <type> <job-name>` scaffolds a job directory from the correct template, handles collisions via auto-suffix, and merges CLI overrides into `config.yaml`
- [ ] All three template `config.yaml` files include a documented `workflow:` block with sensible defaults
- [ ] `training_runner` MCP tool validates, prompts (if configured), executes, and streams `python training/main.py`
- [ ] `start.sh` is emitted and executable when `generate_start_sh: true`
- [ ] Result surfacing produces all four outputs (terminal, `summary.md`, `results.json`, `dashboard.html`) and is skipped gracefully when `auto_summarize: false`
- [ ] All components are covered by tests and integrated end-to-end
