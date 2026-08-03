---
id: E19_S03
epic: E19
title: Run State Machine + Reproducibility + Metrics Schema
status: Backlog
date_created: 2026-07-10
date_started:
date_completed:
priority: P2
depends_on: E19_S02
---

# Story: Run State Machine + Reproducibility + Metrics Schema

## Goal
Introduce an explicit lifecycle for every run (with checkpoints and recovery), enforce reproducibility metadata capture, and normalize metrics across heterogeneous templates.

## Background
See deep-dive: `project/documentation/plans/train-roadmap.md` (Layer 3, reproducibility section)
See solution assessment: Problem 11, 12, 13.

## Acceptance Criteria
- [ ] **Run state machine** — each run has an explicit state: `created → env_ready → validating → smoke_running → smoke_passed → training → succeeded | failed | interrupted | rolled_back`; state persisted in `jobs/<job>/training-results/<run-id>/run.state.json`
- [ ] On interruption or failure, state is checkpointed; resume is possible for `env_ready` and later states
- [ ] On failure, emits clear cleanup/rollback instructions; partial artifacts are quarantined not deleted
- [ ] **Reproducibility metadata** captured before any run reports success: `config_hash`, `template_version`, `dataset_ref` (path + hash), `random_seed`, `python_version`, `package_lockfile_hash`, `git_commit` (if in a git repo). Stored in `jobs/<job>/training-results/<run-id>/run.meta.json`
- [ ] A run that cannot capture mandatory reproducibility fields fails with an explicit warning (not silently)
- [ ] **Normalized metrics schema** — a small core set required of all templates: `status` (succeeded/failed), `duration_seconds`, `primary_metric_name`, `primary_metric_value`, `primary_metric_direction` (higher_is_better | lower_is_better). Templates add custom metrics under a `custom:` namespace in `results.json`
- [ ] `/train history <job>` reads registry + run states, prints timeline table with metrics per run, highlights best run

## Definition of Done
A deliberately interrupted run can be resumed. `run.meta.json` is complete and verifiable. `/train history <job>` output shows comparable metrics across runs.
