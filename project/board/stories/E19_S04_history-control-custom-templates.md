---
id: E19_S04
epic: E19
title: History, Control & Custom Templates
status: Backlog
date_created: 2026-07-10
date_started:
date_completed:
priority: P3
depends_on: E19_S03
---

# Story: History, Control & Custom Templates

## Goal
Complete the UX surface: `confirm_before_run`, `generate_start_sh`, user-defined templates with trust/capability declarations, and polish the `/train history` view.

## Background
See deep-dive: `project/documentation/plans/train-roadmap.md` (Layer 3, history & control section)

## Acceptance Criteria
- [ ] **`confirm_before_run`** — when `true` in config and running in interactive mode, prompts user before Phase C (full training); in `--non-interactive` mode, auto-fails with a clear message; decision is logged in `run.state.json`
- [ ] **`generate_start_sh`** — when `true` in config, writes `jobs/<job>/start.sh` after scaffolding; script activates the job's venv and runs `training/main.py` directly; script is executable
- [ ] **`/train new custom <template-path> <job-name>`** — scaffolds a job from any local path; validates that the source contains a `manifest.json`; registers the custom template in `.training/template/manifest.json` under a `custom` namespace
- [ ] **Template trust model** — custom templates must declare `trust_level: local` in manifest; if `environment.requires_network: true` or any install step is present, `/train` warns explicitly before proceeding; no silent network access
- [ ] **`/train history <job>`** — polished table view: run ID, date, phases passed, primary metric, status, duration; best run highlighted; `--json` flag emits machine-readable output
- [ ] `/train list` updated to show custom templates distinctly from built-in ones

## Definition of Done
Custom template roundtrip works (scaffold → validate → smoke → full). `confirm_before_run` correctly blocks non-interactive runs. `start.sh` is valid and executable.
