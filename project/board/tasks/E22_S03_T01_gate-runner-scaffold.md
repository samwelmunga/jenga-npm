---
id: E22_S03_T01
story_id: E22_S03
epic_id: E22
title: Gate runner module scaffold — structure and invocation interface
status: Passed
date_created: 2026-07-11
date_started:
date_completed:
assigned_to: developer
---

# Task: Gate runner module scaffold — structure and invocation interface

## Description
Scaffold the gate runner as an executable shell script at `skills/publish/scripts/run_gates.sh`. This script is the central entry point for all quality gate execution — it is invoked by the deploy flow with a phase (`pre` or `post`), a target name, and a path to `publish.json`.

Responsibilities of this task:
- Define the script's invocation contract:
  - `run_gates.sh <phase> <target> <publish_json_path> [--non-interactive]`
  - `<phase>`: `pre` or `post`
  - `<target>`: target name from `publish.json`
  - `--non-interactive`: if present, prompts are suppressed; failures abort immediately
- Define the exit code contract: `0` = all gates passed, `2` = one or more gates failed
- Structure: the script reads the gate list for the phase from `publish.json` (plus mandatory gates for `pre`), iterates each, calls a per-gate handler function, and aggregates results
- Document the invocation contract in a comment block at the top of the script
- The per-gate handler stubs can be empty at this stage (implemented in T02 and T03)

## Prerequisites
None. This is a scaffold task; stubs are acceptable.

## Acceptance Criteria
- [ ] `skills/publish/scripts/run_gates.sh` exists and is executable
- [ ] Script accepts `<phase> <target> <publish_json_path> [--non-interactive]` as arguments
- [ ] Script exits 0 when all gates pass, exits 2 when any gate fails
- [ ] Invocation contract documented in a header comment block
- [ ] Script structure iterates gate list (stubbed handlers acceptable)
