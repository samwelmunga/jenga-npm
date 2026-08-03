# Execution Plan: Create npm_pipeline.sh

**Task ID:** E26_S05_T01
**Story ID:** E26_S05
**Epic ID:** E26
**Date:** 2026-07-31 (UTC)
**Agent:** developer
**Session ID:** dev-E26_S05_T01

---

## Task Summary
Create `skills/publish/scripts/npm_pipeline.sh` — a bash script that executes an npm publish pipeline for the JengaAgent repo. It must support `--dry-run`, pass `--tag <dist_tag>` to `npm publish`, run from the repo root (where `package.json` lives), emit clear output (package name, version, dist_tag, registry, dry-run indicator), use disciplined exit codes (0 success, 2 pre-publish gate failure, 3 publish error), and pass shellcheck.

Style follows `skills/publish/scripts/ios_pipeline.sh`.

---

## Implementation Approach

1. Write a bash script with `set -euo pipefail` and constants for the two failure exit codes (`EXIT_PRE_PUBLISH_FAILURE=2`, `EXIT_PUBLISH_FAILURE=3`).
2. Parse args:
   - Optional positional `<target>` (target name) and `<publish_json_path>` (kept for adapter-contract compatibility; T01 focuses on flag/env behaviour so both are optional).
   - Flags: `--dry-run`, `--dist-tag <tag>`, `--non-interactive`.
   - Env fallback for `dist_tag`: read `NPM_DIST_TAG` when the flag is not passed; fall back to `latest` (matches adapter default).
   - If `publish_json_path` + `target` are supplied and `jq` is available, read `npm.dist_tag`, `npm.registry`, `npm.package_name` from the config (as a convenience). Explicit `--dist-tag` and env override.
3. Resolve `REPO_ROOT` via `git rev-parse --show-toplevel`, falling back to `$SCRIPT_DIR/../../..` (mirrors ios_pipeline).
4. Validate that `package.json` exists at repo root — if not, exit `2` with a clear message (pre-publish gate).
5. Read `package_name` and `version` from `package.json` (prefer `jq` if available; otherwise fall back to `node -p` or a simple grep parser).
6. Determine registry: prefer value from config, else default to `https://registry.npmjs.org/`.
7. Print a clear header block:
   - `Package:  <name>`
   - `Version:  <version>`
   - `Dist tag: <tag>`
   - `Registry: <registry>`
   - `Mode:     dry-run` or `Mode:     live publish`
8. If `--dry-run`: print `DRY RUN — nothing was published` BEFORE invoking `npm publish --dry-run --tag <tag>`. On failure of the dry-run itself, exit `3`.
9. Otherwise: run `npm publish --tag <tag>` from the repo root. Exit `3` on failure. On success, print a confirmation line.
10. Return `0` on success.
11. Run shellcheck locally; iterate until clean.

---

## Files to Change

| File | Planned Change |
|------|----------------|
| `skills/publish/scripts/npm_pipeline.sh` | New file. Executable bash script implementing the npm publish pipeline per acceptance criteria. |
| `project/board/tasks/E26_S05_T01_create-npm-pipeline.md` | Set `date_completed: 2026-07-31` when work is done (status transition owned by tester). |

---

## Dependencies & Risks

- Depends on `validate_npm_env.sh` (E26_S05_T02) for token validation; that script is being built in parallel. `npm_pipeline.sh` will invoke it if present but not hard-fail on absence — the `npm publish` call itself surfaces auth errors as exit `3`. Guarded with an `if [[ -f "$VALIDATE_ENV_SCRIPT" ]]` check to avoid a race with the sibling task.
- No shellcheck in the repo CI; verified locally with brew-installed `shellcheck 0.11.0`.
- `--dry-run` still requires npm to be installed on the host; if `npm` is missing we exit `2` (pre-publish gate failure) with a clear message.

---

## Notes

- The adapter contract in `skills/publish/adapters/npm.md` describes a fuller state machine (validating → gating → packing → publishing → tagging → published) and history file writes. Those responsibilities are out of scope for T01, which is narrowly scoped to the `npm publish` invocation with dry-run + dist_tag + exit codes. Later tasks (e.g. run_gates, publish_deploy integration in E26_S06) will wire the pipeline into the wider adapter flow.
- Exit codes match the adapter table exactly (0 / 2 / 3).
- Dry-run banner uses an em dash per the acceptance criterion wording.
