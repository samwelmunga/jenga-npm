#!/usr/bin/env bash
# audit_notice_hook.sh - show the one-time dependency-audit opt-in notice from /publish (E85_S04_T04).
#
# Called at the end of a successful `/publish setup` and per-type env validation for npm and npm-ci targets only
# (setup_wizard.sh, validate_npm_env.sh, validate_npm_ci_env.sh). It runs `scripts/audit-notice.sh show --context
# publish` and nothing else: whether the notice is due (audit mode ask, marker not yet written) is decided entirely
# by audit-notice.sh, which also owns the shared one-time marker, so a user who already saw the notice from j.init is
# not told again. This hook never re-implements the mode check.
#
# Best effort by contract: it ALWAYS exits 0. A missing audit-notice.sh is silent; a failing one yields a single
# stderr line. It can therefore never change the exit status of setup or validate.
#
# audit-notice.sh is found the way run_gates.sh's find_repo_script finds repo scripts (monorepo checkout, git
# toplevel, installed @jenga-ai/agent package), plus $JENGA_PROJECT_ROOT/scripts when that variable is set.
#
# Compatible with macOS bash 3.2.

set -u

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

find_audit_notice() {
  local root candidate
  if root="$(git -C "$HOOK_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
    :
  else
    root="$(cd "$HOOK_DIR/../../.." && pwd)"
  fi
  for candidate in \
    "$HOOK_DIR/../../../scripts/audit-notice.sh" \
    "$root/scripts/audit-notice.sh" \
    "${JENGA_PROJECT_ROOT:-$root}/scripts/audit-notice.sh" \
    "$root/node_modules/@jenga-ai/agent/scripts/audit-notice.sh"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

notice_script="$(find_audit_notice)" || exit 0

if ! bash "$notice_script" show --context publish 2>/dev/null; then
  printf 'audit_notice_hook: audit-notice.sh failed; the opt-in notice was skipped.\n' >&2
fi
exit 0
