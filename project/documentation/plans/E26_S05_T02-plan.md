# Execution Plan: Create validate_npm_env.sh

**Task ID:** E26_S05_T02
**Story ID:** E26_S05
**Epic ID:** E26
**Date:** 2026-07-31 (UTC)
**Agent:** developer
**Session ID:** dev-E26_S05_T02

---

## Task Summary
Create `skills/publish/scripts/validate_npm_env.sh` — a pre-flight environment check for npm publishing. The script asserts that at least one of `NPM_TOKEN` or `NODE_AUTH_TOKEN` is set and that `npm` is on `PATH`. It exits 0 on success and non-zero with a clear, actionable error on failure. Style must mirror `validate_ios_env.sh`.

---

## Implementation Approach

1. Create `skills/publish/scripts/validate_npm_env.sh` with the shebang `#!/usr/bin/env bash` and `set -u`.
2. Define exit code `EXIT_ENV_INVALID=4` to match the iOS script convention.
3. Define a `fail()` helper that prints `npm env validation failed: <msg>` to stderr and exits with `EXIT_ENV_INVALID`.
4. Check that `npm` is available via `command -v npm >/dev/null 2>&1`; if not, fail with a message that names the missing binary and suggests installing Node.js/npm.
5. Read `NPM_TOKEN` and `NODE_AUTH_TOKEN` via `printenv` (matching the iOS pattern) so `set -u` is safe. Accept either variable.
6. If both are empty, fail with a message that explicitly names both variables, states that at least one is required, and shows how to set one (`export NPM_TOKEN=<token>`), without echoing any actual value.
7. Exit 0 when both checks pass.
8. Make the file executable (`chmod +x`).
9. Run `shellcheck` and confirm no errors.

---

## Files to Change

| File | Planned Change |
|------|----------------|
| `skills/publish/scripts/validate_npm_env.sh` | Create new script |

---

## Dependencies & Risks

- No dependency on other tasks. `npm_pipeline.sh` (E26_S05_T01) is being built in parallel and may source or invoke this script — we align on the shared exit code (`4` = environment invalid) so the caller can distinguish env failures.
- No external libraries; only `printenv` and `command -v`, both POSIX-standard on macOS and Linux.
- Risk: leaking token values in error output. Mitigated by never referencing the variable *values* — only the *names*.

---

## Notes

- The task description marks the `npm` binary check as "optional", but the story's Acceptance Criteria and the task's own AC list it as required. Treating it as required.
- Not checking `node` since it is not in the AC and `npm` on PATH implies Node.js is installed in every realistic distribution.
- Script does not take arguments — it inspects the ambient environment, matching how CI-injected token vars work in GitHub Actions and similar systems.
