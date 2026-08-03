# Plan: E01_S03_T02 — Job directory and config validation

## Goal
Before running, validate: directory exists, config.yaml exists, required fields (type/model) present.

## Design
In `run_training_job` handler, before executing:
1. Check `job_dir` exists → error if not
2. Check `<job_dir>/input/config.yaml` exists → error if not
3. Load YAML, verify `model` key (with sub-key `type` or `name`) is present
4. Return structured error text on any failure
