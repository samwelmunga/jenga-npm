#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXIT_ENV_INVALID=4

fail() {
  printf 'npm env validation failed: %s\n' "$1" >&2
  exit "$EXIT_ENV_INVALID"
}

# Presence test only (E85_S02_T03). Succeeds when $1 names an exported variable that has a non-empty value; the value
# itself is never assigned to a variable, printed, logged or passed to another command. It reproduces the contract of
# the earlier value-capturing check exactly:
#   - set but empty counts as missing (a bare existence test of the variable would succeed for an empty value);
#   - a name that is not a valid shell identifier counts as missing and never aborts the script (the names come from
#     publish.json strings), which is why the identifier test runs before any indirect expansion;
#   - only exported variables count (the case statement matches the NAME list from compgen -e, so a
#     script-internal shell variable of the same name is not mistaken for the user's environment);
#   - a value made up only of newlines counts as empty, as it did when it was captured with command substitution.
env_var_has_value() {
  [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  case $'\n'"$(compgen -e)"$'\n' in
    *$'\n'"$1"$'\n'*) ;;
    *) return 1 ;;
  esac
  [[ -n "${!1:-}" ]] || return 1
  [[ -n "${!1//$'\n'/}" ]]
}

if ! command -v npm >/dev/null 2>&1; then
  fail "'npm' was not found on PATH. Install Node.js (which provides npm) from https://nodejs.org/ or via your package manager, then re-run."
fi

if ! env_var_has_value NPM_TOKEN && ! env_var_has_value NODE_AUTH_TOKEN; then
  fail "no npm auth token found. Set NPM_TOKEN (or NODE_AUTH_TOKEN) in the environment before publishing, e.g. 'export NPM_TOKEN=<your-npm-automation-token>'. Generate a token at https://www.npmjs.com/settings/<user>/tokens."
fi

# One-time dependency-audit opt-in notice (E85_S04_T04). Best effort: the hook always exits 0.
[ -f "$SCRIPT_DIR/audit_notice_hook.sh" ] && bash "$SCRIPT_DIR/audit_notice_hook.sh" || true

exit 0
