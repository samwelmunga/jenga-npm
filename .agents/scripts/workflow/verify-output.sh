#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/workflow/verify-output.sh - verify a workflow step output against its playbook type
# (epic E80, task E80_S03_T02)
#
# A thin wrapper over scripts/validate-typed-object.sh, the single deterministic answer to "does this value
# conform to this type?" for the E62 descriptors in templates/playbook-types.json. It adds no type logic of its
# own: every type name, rule and transform is read by the validator from the registry. It only maps the
# validator's exit codes onto the contract below. The playbook runner (skills/jenga/scripts/run-playbook-step.sh)
# keeps its own embedded call site; that remaining duplication is recorded in E80_S03_T10's design note.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   verify-output.sh <type> <value>
#   verify-output.sh -h | --help       print this usage on stdout, exit 0
#
#   <type>    a key of the registry's "types" map (for example id_list, file_list, ranked_list, text)
#   <value>   the step output, as one argument (it may span several lines; the empty string is a valid value)
#
# The value is written to a temporary file and handed to the validator with --value-file, so it never passes
# through a second argument parser. The temporary directory is removed on every exit path (EXIT trap, also on
# INT and TERM).
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0  the value conforms, nothing on stderr
#        - validator exit 0 (conforming): the value is printed unchanged on stdout
#        - validator exit 2 (conforms after normalisation): the NORMALISED value is printed on stdout
#   1  the value is non-conforming: the failing rule (the validator's "reason") is printed on stderr, nothing
#      on stdout
#   2  the check could not be performed, and the value is NOT reported as non-conforming (same stance as
#      run-playbook-step.sh). A message naming the cause is printed on stderr. Covers: the type is not in the
#      registry (the unknown type is named), the validator or jq is missing, the package root cannot be
#      resolved, the registry is unreadable or violates its contract (validator exit 4, 5 or 6), a usage error
#      here, and any other unexpected validator status.
#
# ---------------------------------------------------------------------------
# WHERE THE VALIDATOR IS FOUND
# ---------------------------------------------------------------------------
# The package root is the first of these that applies:
#   1. JENGA_PLAYBOOKS_TEST_ROOT, when set and non-empty (the test override load-playbooks.sh and
#      run-playbook-step.sh already honour; no new variable is introduced). Taken as given.
#   2. The checkout this script lives in, <script dir>/../.., when it holds scripts/validate-typed-object.sh.
#   3. The consumer install, <project anchor>/node_modules/@jenga-ai/agent (anchor from scripts/resolve-root.sh).
# The validator is <package root>/scripts/validate-typed-object.sh, and reads <package root>/templates/
# playbook-types.json unless JENGA_PLAYBOOK_TYPES_FILE (its own test hook) says otherwise.
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions).
# ---------------------------------------------------------------------------

set -u

SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
VALIDATOR_REL="scripts/validate-typed-object.sh"

err() { printf 'verify-output.sh: %s\n' "$*" >&2; }

usage() {
  sed -n '/^# USAGE$/,/^# EXIT CODES$/p' "${BASH_SOURCE[0]}" | sed -e '1d;$d' -e '/^# -*$/d' -e 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if [ $# -ne 2 ]; then
  err "usage: verify-output.sh <type> <value>"
  exit 2
fi
TYPE="$1"
VALUE="$2"
if [ -z "$TYPE" ]; then
  err "the type name is empty"
  exit 2
fi

# --- locate the package root -------------------------------------------------
PKG_ROOT=""
if [ -n "${JENGA_PLAYBOOKS_TEST_ROOT:-}" ]; then
  PKG_ROOT="${JENGA_PLAYBOOKS_TEST_ROOT%/}"
elif [ -f "$SELF_DIR/../../$VALIDATOR_REL" ]; then
  PKG_ROOT="$(CDPATH='' cd -- "$SELF_DIR/../.." >/dev/null 2>&1 && pwd)"
else
  ANCHOR=""
  if [ -f "$SELF_DIR/../resolve-root.sh" ]; then
    ANCHOR="$(bash "$SELF_DIR/../resolve-root.sh" root 2>/dev/null)" || ANCHOR=""
  fi
  if [ -n "$ANCHOR" ] && [ -f "$ANCHOR/node_modules/@jenga-ai/agent/$VALIDATOR_REL" ]; then
    PKG_ROOT="${ANCHOR%/}/node_modules/@jenga-ai/agent"
  else
    err "cannot locate $VALIDATOR_REL (looked in $SELF_DIR/../.. and the consumer install node_modules/@jenga-ai/agent)"
    exit 2
  fi
fi

VALIDATOR="$PKG_ROOT/$VALIDATOR_REL"
if [ ! -f "$VALIDATOR" ]; then
  err "validator not found: $VALIDATOR"
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  err "jq is required to read the validator's result but was not found"
  exit 2
fi

# --- run the validator on a temp file (always removed) -----------------------
TMPDIR_VO="$(mktemp -d "${TMPDIR:-/tmp}/verify-output.XXXXXX")" || { err "cannot create a temporary directory"; exit 2; }
cleanup() { rm -rf "$TMPDIR_VO"; }
trap cleanup EXIT
trap 'exit 2' INT TERM

printf '%s' "$VALUE" > "$TMPDIR_VO/value" || { err "cannot write the temporary value file"; exit 2; }

RESULT="$(bash "$VALIDATOR" --value-file "$TMPDIR_VO/value" "$TYPE" 2>"$TMPDIR_VO/stderr")"
RC=$?

# Reads a string member of the validator's JSON result; empty when absent, null, or not JSON.
json_field() { printf '%s' "$RESULT" | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null; }

case "$RC" in
  0)
    printf '%s\n' "$VALUE"
    exit 0
    ;;
  2)
    NORMALISED="$(printf '%s' "$RESULT" | jq -r '.value // empty' 2>/dev/null)"
    printf '%s\n' "$NORMALISED"
    exit 0
    ;;
  3)
    REASON="$(json_field reason)"
    err "value does not conform: ${REASON:-no reason given by the validator}"
    exit 1
    ;;
  4)
    err "unknown type '$TYPE': it is not defined in the playbook type registry"
    exit 2
    ;;
  5|6)
    MSG="$(cat "$TMPDIR_VO/stderr" 2>/dev/null)"
    [ -n "$MSG" ] || MSG="$(json_field reason)"
    err "type '$TYPE' could not be checked (validator exit $RC): ${MSG:-no message from the validator}"
    exit 2
    ;;
  *)
    MSG="$(cat "$TMPDIR_VO/stderr" 2>/dev/null)"
    err "type '$TYPE' could not be checked (unexpected validator exit $RC): ${MSG:-no message from the validator}"
    exit 2
    ;;
esac
