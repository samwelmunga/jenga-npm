---
id: E19
title: /train Skill Enhancement — Production-Grade ML Orchestration
status: Backlog
date_created: 2026-07-10
date_started:
date_completed:
stories:
  - E19_S01
  - E19_S02
  - E19_S03
  - E19_S04
  - E19_S05
  - E19_S06
  - E19_S07
---

# Epic: /train Skill Enhancement — Production-Grade ML Orchestration

## Purpose
Evolve the `/train` skill from its current incomplete state (scaffolding + smoke-test only, config flags unimplemented, `training/main.py` never called) into a production-grade ML training orchestrator with full execution lifecycle, experiment tracking, reproducibility guarantees, and AI-guided iteration.

This epic is informed by a deep-dive investigation (Resolve mode) whose output documents are co-located at:
- `project/documentation/plans/train-roadmap.md`
- `project/documentation/plans/scrutiny-train-roadmap.md`
- `project/documentation/plans/solution-assessment-train-roadmap.md`

## Target Users
1. Developer with ML knowledge — wants workflow convenience in Jenga
2. Non-ML developer — needs Jenga to guide them through training
3. AI agent — runs training jobs autonomously inside stories/tasks

## Definition of Done
- [ ] Canonical execution contract published and enforced for `/train run`, `train.py`, `training/main.py`
- [ ] All `config.yaml` workflow flags are implemented with versioned schemas and interaction-mode semantics
- [ ] `/train run <job> --full` executes three-phase pipeline: pre-flight → smoke → full training
- [ ] Per-job isolated environments with lock capture; auto-install is safe and deterministic
- [ ] `job.state.json` written after every `/train` command (agent-readable state)
- [ ] Versioned template manifest schema with run profiles (`smoke`, `full`) and capability declarations
- [ ] `auto_summarize` produces terminal summary + `summary.md` report after every run
- [ ] `jobs/registry.json` tracks all jobs and runs with atomic writes and recovery
- [ ] `/train list` and `/train history <job>` commands work
- [ ] Run state machine with explicit lifecycle states and checkpoint/recovery
- [ ] Reproducibility metadata captured on every run (seed, dataset ref, env fingerprint, config hash)
- [ ] Normalized core metrics schema with namespaced template extensions
- [ ] User-defined templates via `/train new custom <path> <name>` with trust/capability declarations
- [ ] `auto_iterate` recommendation-only phase: suggest config changes, require explicit approval
- [ ] `auto_iterate` AI overlay: agent proposes config edits with reasoning and confidence
