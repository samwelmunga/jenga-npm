# Plan: E16_S01_T02 — Create `lib/resolve-project-dir.sh`

## Objective
Write a sourced shell helper that exports `JENGA_PROJECT_DIR`, `JENGA_AGENT_TYPE`, and `JENGA_SESSION_ID` by probing known agent environment variables in priority order, with safe fallbacks.

## Steps

1. **Append sender object** to `project/logs/events.json`.

2. **Create `lib/resolve-project-dir.sh`**:
   - Guard: if `JENGA_PROJECT_DIR` is already set, return immediately (idempotent).
   - Probe `CLAUDE_PROJECT_DIR` → `COPILOT_WORKSPACE_FOLDER` → `git rev-parse --show-toplevel` → `pwd`.
   - Export `JENGA_PROJECT_DIR`.
   - Export `JENGA_AGENT_TYPE` by probing `CLAUDE_AGENT_TYPE` with fallback `"generic"`.
   - Export `JENGA_SESSION_ID` by probing `CLAUDE_SESSION_ID` with UUID fallback via `uuidgen` or `date +%s`.
   - No stdout/stderr output when sourced.
   - Mark executable with `chmod +x`.

3. **Test** by sourcing in a clean subshell and verifying the exported values.

4. **Write summary** to `project/documentation/summaries/E16_S01_T02-summary.md`.

5. **Update task file** status to `Done`.

## Design Decisions
- Use `[ -n "$VAR" ]` checks to probe each var without expanding empty strings.
- `git rev-parse` errors are suppressed with `2>/dev/null`.
- UUID generation uses `uuidgen` if available, else falls back to `date +%s$$`.
- Script is designed to be sourced (`source` / `.`), not executed directly.
