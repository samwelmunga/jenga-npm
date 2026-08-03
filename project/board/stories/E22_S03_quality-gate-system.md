---
id: E22_S03
epic_id: E22
title: Quality gate system
status: Passed
date_created: 2026-07-11
date_started:
date_completed: 2026-07-11
tasks:
  - E22_S03_T01
  - E22_S03_T02
  - E22_S03_T03
---

# Story: Quality gate system

## Goal
Implement the quality gate runner that `/publish deploy` invokes before and after
deployment. Mandatory global gates (build + tests) cannot be disabled by config.
Per-target gates are configurable in `publish.json`. Any gate failure halts the
pipeline with a clear error and a non-zero exit code.

## Acceptance Criteria
- [ ] Gate runner module implemented (invoked by the deploy flow before and after pipeline execution)
- [ ] Mandatory global pre-deploy gates: `build` and `test` — always run, cannot be disabled via config
- [ ] Configurable per-target gates (from `publish.json` `checks.pre` and `checks.post`): `lint`, `type-check`, `custom-script`
- [ ] Post-deploy gates configurable: `smoke-test`, `ping`, `custom-script`
- [ ] Any gate failure: halt pipeline, surface full error output, exit with code 2
- [ ] On gate failure, user is offered: "Fix and retry" or "Abort deploy"
- [ ] Gate results logged to `project/logs/publish-history.json` under the failed/aborted publish entry
- [ ] Non-interactive mode: gate failures always abort (no interactive prompt)

## Notes
- The distinction between mandatory and configurable gates is a security/governance decision — document it clearly in SKILL.md
- `custom-script` gate type runs a shell command specified in `publish.json` (allowlisted path pattern only — no arbitrary shell expansion)
- Do not allow configurable gates to override mandatory gates

## Definition of Done
- [x] `skills/publish/scripts/run_gates.sh` exists and is executable
- [x] Invocation contract documented (`<phase> <target> <publish_json_path> [--non-interactive]`)
- [x] Mandatory `build` and `test` gates always run first on `pre` phase
- [x] Configurable `lint`, `type-check`, `custom-script` gates readable from `publish.json`
- [x] Post-deploy `smoke-test` and `ping` gates implemented
- [x] `custom-script` path validated against allowlist pattern
- [x] Gate failures exit with code 2 and surface full error output
- [x] Interactive retry/abort UX with 3-retry cap
- [x] Non-interactive mode aborts immediately on failure
- [x] Gate failures logged to `project/logs/publish-history.json`
