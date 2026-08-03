---
id: E19_S02
epic: E19
title: Template Manifest Schema + Run Profiles + Observability
status: Backlog
date_created: 2026-07-10
date_started:
date_completed:
priority: P1-P2
depends_on: E19_S01
---

# Story: Template Manifest Schema + Run Profiles + Observability

## Goal
Give every template a formal manifest declaring its capabilities, run profiles, and metrics contract. Then wire `auto_summarize` to actually produce terminal summaries and markdown reports. Add timestamped run folders and the central job registry.

## Background
See deep-dive: `project/documentation/plans/train-roadmap.md` (Layer 2)

## Acceptance Criteria
- [ ] **Template manifest schema** — each template ships a `manifest.json` with fields: `name`, `version`, `entrypoints` (`validate`, `train`, `full_train`), `run_profiles` (`smoke`, `full` — with required checks, artifact paths, max duration hints), `required_metrics` (with `direction`: higher/lower is better), `capabilities` (`supports_iteration`, `supports_auto_summarize`), `environment` (`requires_network`, `requires_gpu`)
- [ ] Existing `.training/template/manifest.json` updated to reference per-template manifests; `manifest.json` added to all three template dirs
- [ ] **`/train new`** stamps `template_version` and copies `manifest.json` into the scaffolded job dir
- [ ] **Timestamped run folders** — each run writes artifacts to `jobs/<job>/training-results/<run-id>/` (e.g., `run-2026-07-10-153200/`); no more result overwrites
- [ ] **`auto_summarize`** (when `true` in config): after any successful full run, prints a terminal table of key metrics and writes `jobs/<job>/training-results/<run-id>/summary.md`
- [ ] **`jobs/registry.json`** created on first run, maintained with atomic writes (write-to-temp-then-rename), tracks: job list with `job_id`, `type`, `template_version`, `created_at`, `last_run_id`, `best_metric`, `status`
- [ ] **`/train list`** subcommand reads `registry.json` and prints a formatted table of all registered jobs

## Definition of Done
All three templates have valid manifests. Registry is consistent after a run. `auto_summarize` report matches metrics from `results.json`. `/train list` output is human and machine readable.
