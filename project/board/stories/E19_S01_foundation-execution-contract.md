---
id: E19_S01
epic: E19
title: Foundation — Execution Contract, Config Contract, Full Training Pipeline
status: Backlog
date_created: 2026-07-10
date_started:
date_completed:
priority: P0-P1
---

# Story: Foundation — Execution Contract, Config Contract, Full Training Pipeline

## Goal
Fix the structural incoherence at the heart of `/train`: write the canonical execution contract, formalize config flag semantics, wire `train.py → training/main.py`, add `--full` mode, set up isolated environments, and always emit `job.state.json`.

## Background
See deep-dive: `project/documentation/plans/train-roadmap.md` (Layer 1)

## Acceptance Criteria
- [ ] **Execution contract spec** written as `project/documentation/plans/train-execution-contract.md` — defines entrypoints, phases, exit codes, artifact locations, and invocation responsibilities for `/train run`, `train.py`, and `training/main.py`
- [ ] **Thin-orchestrator scope + non-goals** documented to prevent platform creep
- [ ] **Versioned config contract** — each flag in `config.yaml` has defined type, default, precedence, interaction rules, and non-interactive semantics; enforced at load time via schema validator
- [ ] **Interaction modes** implemented: `--interactive` (default), `--non-interactive` (auto-fail on prompts), `--yes` (confirm all without asking)
- [ ] **`train.py` fixed** — the root stub delegates to `training/main.py` respecting `config.yaml`; hardcoded `LogisticRegression` removed
- [ ] **`/train run <job> --full`** executes three-phase pipeline: Phase A (pre-flight `validate.py`) → Phase B (smoke `train.py --smoke`) → Phase C (full `training/main.py`)
- [ ] Phase C only runs if Phase B passes; `--full` must be explicit (no accidental full runs)
- [ ] **Per-job isolated environment**: each job gets its own venv under `jobs/<job>/env/`; `requirements.txt` installed once, lockfile captured in `jobs/<job>/env/requirements.lock`
- [ ] **`job.state.json`** written to `jobs/<job>/job.state.json` after every `/train` command with fields: `job_id`, `status`, `last_command`, `last_run_id`, `phases_passed`, `artifact_paths`, `timestamp`
- [ ] All three templates (`classifiers`, `transformers`, `nlp`) updated to conform to the new contract

## Definition of Done
All acceptance criteria met, existing smoke-test pipeline still passes, `job.state.json` is machine-readable and matches schema.
