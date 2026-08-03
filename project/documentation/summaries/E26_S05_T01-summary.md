# Execution Summary: Create npm_pipeline.sh

**Task ID:** E26_S05_T01
**Story ID:** E26_S05
**Epic ID:** E26
**Date Completed:** 2026-07-31 (UTC)
**Agent:** developer
**Session ID:** dev-E26_S05_T01

---

## What Was Implemented

Added `skills/publish/scripts/npm_pipeline.sh` — a bash script that runs the npm publish pipeline for the JengaAgent repo. It supports `--dry-run`, reads `dist_tag` from a `--dist-tag` flag, the `NPM_DIST_TAG` env var, or a `publish.json` target, and defaults to `latest`. It runs `npm publish --tag <dist_tag>` from the resolved repo root. Style, exit-code discipline, and repo-root resolution mirror the existing `ios_pipeline.sh`.

---

## Files Changed

| File | Summary of Changes |
|------|--------------------|
| `skills/publish/scripts/npm_pipeline.sh` | New executable (0755) bash script implementing the npm publish pipeline. |
| `project/board/tasks/E26_S05_T01_create-npm-pipeline.md` | Set `date_completed: 2026-07-31`. Status left as `Running` for the tester to promote. |
| `project/documentation/plans/E26_S05_T01-plan.md` | Execution plan written before implementation. |
| `project/documentation/summaries/E26_S05_T01-summary.md` | This file. |

---

## Commits

| SHA | Message |
|-----|---------|
| _pending_ | `feat(E26_S05_T01): create npm_pipeline.sh` |

---

## Acceptance Criteria Coverage

| Criterion | Status | Notes |
|-----------|--------|-------|
| Script exists and is executable | Pass | `git ls-files -s` shows mode `100755`. |
| `--dry-run` flag runs `npm publish --dry-run` | Pass | Verified locally against the JengaAgent `package.json`; final command line was `npm publish --tag latest --dry-run`. |
| Reads `dist_tag` and passes `--tag <dist_tag>` | Pass | Precedence: `--dist-tag` flag > `NPM_DIST_TAG` env > `npm.dist_tag` in `publish.json` > `latest`. |
| Exit codes 0 / 2 / 3 | Pass | Constants `EXIT_PRE_PUBLISH_FAILURE=2`, `EXIT_PUBLISH_FAILURE=3`. Verified: unknown flag → `2`; happy dry-run → `0`. |
| Passes `shellcheck` with no errors | Pass | `/opt/homebrew/bin/shellcheck` v0.11.0 returned exit 0. |
| Dry-run states "DRY RUN — nothing was published" before listing | Pass | Banner is printed immediately before the `npm publish --dry-run` invocation. |

---

## Edge Cases & Known Concerns

- **`validate_npm_env.sh` sibling task (E26_S05_T02) is being built in parallel.** The pipeline invokes it only when `TARGET_NAME` + `PUBLISH_JSON` are supplied and the file exists; otherwise it logs a warning and proceeds. Once T02 lands, both should coexist without changes to this script.
- **`node` fallback for JSON reading:** If `jq` is unavailable, the script falls back to `node -p` to read `package.json`. If neither is installed, the script exits `2` with a clear message (the `read_json_string` helper returns empty and the subsequent `[[ -n "$PACKAGE_NAME" ]]` guard fires).
- **`npm` must be on PATH.** Missing `npm` → exit `2`.
- **Registry default** is `https://registry.npmjs.org/` (with trailing slash to match npm's own default output); a target-supplied `npm.registry` overrides it.
- **T01 scope only:** the fuller adapter state machine (validating → gating → packing → publishing → tagging → published) documented in `skills/publish/adapters/npm.md` is intentionally out of scope; it will be layered in by E26_S06 tasks that integrate this pipeline with `run_gates.sh` and `publish_deploy.sh`.

---

## Notes for Tester

To exercise the script:

```bash
# Happy path (dry-run, no config):
bash skills/publish/scripts/npm_pipeline.sh --dry-run

# Dist-tag override via flag:
bash skills/publish/scripts/npm_pipeline.sh --dry-run --dist-tag beta

# Dist-tag from env:
NPM_DIST_TAG=next bash skills/publish/scripts/npm_pipeline.sh --dry-run

# Config-driven (uses publish.example.npm.json):
bash skills/publish/scripts/npm_pipeline.sh npm-public skills/publish/assets/publish.example.npm.json --dry-run

# Unknown flag → exit 2:
bash skills/publish/scripts/npm_pipeline.sh --bogus; echo $?

# Shellcheck:
shellcheck skills/publish/scripts/npm_pipeline.sh
```

Do **not** run without `--dry-run` in the test environment — that would publish `jenga-agent@1.0.0` to npmjs.org.
