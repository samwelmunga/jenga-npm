#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# skills/j-cloud-connect/scripts/configure-backend.sh
#
# Core of the j-cloud-connect setup wizard (E60_S01_T02): dynamic backend
# selection, that backend's own `rclone config create` flow, an explicit
# wait for user confirmation of any auth step it produced, then independent
# post-confirmation verification.
#
#   1. Backend menu is sourced LIVE from `rclone config providers` — never a
#      hardcoded list. This is true for both the printed menu and the
#      validation of a backend name passed as an argument.
#   2. Once a backend type + remote name are known (from arguments, or from
#      an interactive prompt driven by that same live menu), this script runs
#      `rclone config create <remote> <backend>` with stdin/stdout/stderr
#      fully inherited — no capturing, no re-formatting. Whatever that
#      backend's own flow prints, including an OAuth auth URL, reaches the
#      user exactly as rclone presents it. This script never parses or
#      special-cases any backend's own prompts.
#   3. After `config create` returns, this script explicitly asks the user to
#      confirm they've completed setup/authorization before doing anything
#      else — it never just detects "not configured" and stops, and it never
#      infers completion on its own.
#   4. Only after that confirmation, `rclone about <remote>:` is run to
#      INDEPENDENTLY verify the remote actually works. The user's
#      confirmation is never itself treated as success — a PASS/FAIL verdict
#      always comes from this real check.
#
# The exact same code path runs regardless of which backend was selected;
# there is no per-backend branch anywhere below beyond what rclone's own
# `config create` already does internally per-backend.
#
# This script assumes `rclone` is already on PATH (see install-rclone.sh,
# E60_S01_T01) and that `jq` is available (already a repo-wide dependency
# used to parse rclone's JSON provider list).
#
# Invoked via `bash`, not executed directly — it intentionally ships without
# the executable bit, matching the convention already documented in this
# skill's install-rclone.sh and in skills/j-dashboard/scripts/resolve-app-dir.sh.
# Whatever wires this into the j-cloud-connect skill (E60_S01_T03) should
# invoke it as `bash skills/j-cloud-connect/scripts/configure-backend.sh`.
#
# Usage:
#   configure-backend.sh --list
#   configure-backend.sh [<backend-type> <remote-name>]
#
#   --list                     Print the live backend menu and exit. No side
#                               effects.
#   <backend-type> <remote-name>
#                               Skip interactive selection; configure the
#                               given backend under the given remote name.
#                               <backend-type> is still validated against the
#                               live provider list before use.
#   (no arguments)              Print the live menu, prompt for a numeric
#                               selection and a remote name, then proceed
#                               through the same configure/confirm/verify
#                               flow as the two-argument form above.
#
# Exit codes:
#   0  --list succeeded, OR the remote was configured, confirmed, and
#      independently verified working (rclone about succeeded).
#   1  Any failure: rclone/jq missing, provider list unreadable, invalid
#      backend/selection, `rclone config create` failed, the user declined
#      to confirm setup was complete, or post-confirmation verification
#      (`rclone about`) failed. A human-readable reason is always printed.
# -----------------------------------------------------------------------------

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  configure-backend.sh --list
  configure-backend.sh [<backend-type> <remote-name>]

Sources a backend menu live from `rclone config providers`, runs the
selected backend's own `rclone config create` flow (surfacing any auth URL
it produces directly, with stdio fully inherited), waits for explicit user
confirmation that setup/authorization is complete, then independently
verifies the remote via `rclone about <remote>:` and reports PASS/FAIL.

  --list                        Print the live backend menu and exit.
  <backend-type> <remote-name>  Skip interactive selection.
  (no arguments)                Prompt interactively for both.

Exits 0 only once the remote is configured, confirmed, AND independently
verified working. Exits 1 on any failure, including a declined confirmation
or a failed post-confirmation verification — a user's confirmation alone is
never treated as success.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

# -----------------------------------------------------------------------------
# Preflight — required tools.
# -----------------------------------------------------------------------------

require_rclone() {
  command -v rclone >/dev/null 2>&1 || die "rclone is not on PATH. Install it first (see skills/j-cloud-connect/scripts/install-rclone.sh) and re-run."
}

require_jq() {
  command -v jq >/dev/null 2>&1 || die "'jq' is required to parse rclone's provider list but is not on PATH. Install jq and re-run."
}

# -----------------------------------------------------------------------------
# Live backend list — sourced from rclone itself, never hardcoded.
# -----------------------------------------------------------------------------

# Prints the raw `rclone config providers` JSON on stdout. Dies with rclone's
# own captured output on any failure (command failure or non-array JSON).
fetch_providers_json() {
  local json
  if ! json="$(rclone config providers 2>&1)"; then
    die "'rclone config providers' failed: $json"
  fi
  if ! printf '%s' "$json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    die "'rclone config providers' did not return a valid JSON array of backends. Output: $json"
  fi
  printf '%s' "$json"
}

# print_backend_menu <providers-json>
print_backend_menu() {
  printf '%s' "$1" | jq -r 'to_entries[] | "\(.key + 1)) \(.value.Name) — \(.value.Description)"'
}

# backend_name_at_index <providers-json> <1-based-index>
backend_name_at_index() {
  local json="$1" index="$2"
  printf '%s' "$json" | jq -r --argjson i "$((index - 1))" '.[$i].Name // empty'
}

# backend_exists <providers-json> <backend-name>
backend_exists() {
  local json="$1" name="$2"
  printf '%s' "$json" | jq -e --arg n "$name" 'any(.[]; .Name == $n)' >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# Argument parsing.
# -----------------------------------------------------------------------------

LIST_ONLY=0
BACKEND_TYPE=""
REMOTE_NAME=""

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --list)
    LIST_ONLY=1
    if [ "$#" -gt 1 ]; then
      usage >&2
      die "unexpected extra arguments after --list"
    fi
    ;;
  "")
    ;;
  *)
    if [ "$#" -ne 2 ]; then
      usage >&2
      die "expected exactly two arguments (<backend-type> <remote-name>), got $#"
    fi
    BACKEND_TYPE="$1"
    REMOTE_NAME="$2"
    ;;
esac

require_rclone
require_jq

PROVIDERS_JSON="$(fetch_providers_json)"

if [ "$LIST_ONLY" -eq 1 ]; then
  echo "Backends supported by your installed rclone:"
  print_backend_menu "$PROVIDERS_JSON"
  exit 0
fi

# -----------------------------------------------------------------------------
# Step 1 — Resolve a backend type and remote name (from args, or
# interactively from the same live menu). Both paths converge below into the
# identical configure/confirm/verify flow.
# -----------------------------------------------------------------------------

if [ -z "$BACKEND_TYPE" ]; then
  echo "Select a cloud storage backend:"
  print_backend_menu "$PROVIDERS_JSON"
  SELECTION=""
  read -r -p "Enter the number of the backend to configure: " SELECTION || die "no input provided for the backend selection prompt (unexpected end of input)."
  case "$SELECTION" in
    ''|*[!0-9]*) die "invalid selection '$SELECTION' — expected a number from the list above." ;;
  esac
  BACKEND_TYPE="$(backend_name_at_index "$PROVIDERS_JSON" "$SELECTION")"
  [ -n "$BACKEND_TYPE" ] || die "invalid selection '$SELECTION' — no backend at that number."

  REMOTE_NAME=""
  read -r -p "Enter a name for this remote (e.g. 'gdrive'): " REMOTE_NAME || die "no input provided for the remote name prompt (unexpected end of input)."
  [ -n "$REMOTE_NAME" ] || die "a remote name is required."
else
  backend_exists "$PROVIDERS_JSON" "$BACKEND_TYPE" || die "'$BACKEND_TYPE' is not a backend your installed rclone supports. Run this script with --list to see the current list."
fi

# -----------------------------------------------------------------------------
# Step 2 — Run the backend's own `rclone config create` flow. stdio is fully
# inherited (no capture, no suppression): any prompts or auth URL this
# produces reach the user exactly as rclone presents them. Identical for
# every backend — no per-backend branch here.
# -----------------------------------------------------------------------------

echo ""
echo "Running: rclone config create $REMOTE_NAME $BACKEND_TYPE"
echo "Follow any prompts below, including opening any authorization link shown,"
echo "exactly as rclone presents them."
echo ""

CONFIG_EXIT=0
rclone config create "$REMOTE_NAME" "$BACKEND_TYPE" || CONFIG_EXIT=$?
if [ "$CONFIG_EXIT" -ne 0 ]; then
  die "'rclone config create $REMOTE_NAME $BACKEND_TYPE' exited with status $CONFIG_EXIT. Remote was not configured — see rclone's output above for the reason."
fi

# -----------------------------------------------------------------------------
# Step 3 — Wait for EXPLICIT user confirmation before proceeding any further.
# Never inferred, never skipped.
# -----------------------------------------------------------------------------

echo ""
echo "If rclone showed an authorization link above, open it now and complete the"
echo "authorization before continuing."
CONFIRM=""
read -r -p "Have you finished completing setup/authorization for '$REMOTE_NAME'? [y/N] " CONFIRM || die "no input provided for the confirmation prompt (unexpected end of input)."
case "$CONFIRM" in
  [Yy]|[Yy][Ee][Ss])
    ;;
  *)
    die "Setup was not confirmed complete. Re-run this script once you've finished authorization for '$REMOTE_NAME' — verification was skipped, so it has NOT been confirmed working."
    ;;
esac

# -----------------------------------------------------------------------------
# Step 4 — Independently verify the remote actually works. Confirmation
# alone is NEVER treated as success — this real check decides PASS/FAIL.
# -----------------------------------------------------------------------------

echo ""
echo "Verifying remote '$REMOTE_NAME'..."

VERIFY_EXIT=0
VERIFY_OUTPUT="$(rclone about "$REMOTE_NAME": 2>&1)" || VERIFY_EXIT=$?

if [ "$VERIFY_EXIT" -eq 0 ]; then
  echo "PASS: remote '$REMOTE_NAME' is configured and verified working."
  echo "$VERIFY_OUTPUT"
  exit 0
else
  echo "FAIL: remote '$REMOTE_NAME' did not verify — 'rclone about $REMOTE_NAME:' failed (exit $VERIFY_EXIT)." >&2
  echo "$VERIFY_OUTPUT" >&2
  exit 1
fi
