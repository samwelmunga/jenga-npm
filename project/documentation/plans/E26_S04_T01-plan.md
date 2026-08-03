# Execution Plan: Create npm adapter definition

**Task ID:** E26_S04_T01
**Story ID:** E26_S04
**Epic ID:** E26
**Date:** 2026-07-31 (UTC)
**Agent:** developer
**Session ID:** dev-E26_S04_T01

---

## Task Summary
Author `.claude/skills/publish/adapters/npm.md`, mirroring the structure of `adapters/mobile-ios.md`. Documents the contract for a future `npm` publish adapter: inputs from `publish.json`, required env vars, pipeline entrypoint, execution phases, state machine, dry-run behaviour, exit codes, and post-deploy manual steps. Documentation only — no scripts.

---

## Implementation Approach

1. Read `adapters/mobile-ios.md` and internalise its section order, headings, and tone.
2. Read the npm settings block already in `schemas/publish.schema.json` (added in E26_S03_T02) so field names line up: `package_name`, `access`, `registry`, `dist_tag`; secret `NPM_TOKEN`.
3. Write `adapters/npm.md` with the same six sections adjusted for npm: Invocation Contract (inputs + env vars + pipeline entrypoint), Execution Phases, State Machine, Dry-run Mode, Exit Codes, Post-deploy manual steps.
4. Reference `scripts/npm_pipeline.sh` and `scripts/validate_npm_env.sh` as pipeline/validator entrypoints (do NOT create them — S05 tasks own those).
5. Map failure conditions from task AC into exit codes (missing token → 2, gate failure → 2, publish error → 3).

---

## Files to Change

| File | Planned Change |
|------|----------------|
| `.claude/skills/publish/adapters/npm.md` | New file — npm adapter contract, mirroring `mobile-ios.md`. |

---

## Dependencies & Risks

- Depends conceptually on E26_S03_T02 (schema npm block already merged @ 360b958).
- Does not depend on S05 pipeline scripts existing — the adapter is a contract, not the runner.
- Risk: naming drift between adapter doc and eventual pipeline script; mitigated by locking exact script names now (`npm_pipeline.sh`, `validate_npm_env.sh`).

---

## Notes

- Documentation-only task. Zero code changes elsewhere.
- Do not commit — /commit skill handles commits.
