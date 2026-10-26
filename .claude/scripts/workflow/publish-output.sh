#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/workflow/publish-output.sh - publish one step output to the workflow output registry (epic E80,
# task E80_S06_T13; the logic is the former complete-step.sh _cs_publish, extracted so that complete-step.sh and
# run-compute.sh share it instead of copying it)
#
# USAGE
#   publish-output.sh <run_id> <workflow_id> <step_id> <name> <kind> <type> <value>
#   publish-output.sh -h | --help      print this usage on stdout, exit 0
#
#   kind data      <value> (the stored, already verified value) is written to a temporary file, one line per
#                  element for a list type, and registered with --kind data and the declared type
#   kind artifact  registered with --kind artifact only when <value> is the path of an existing regular file;
#                  otherwise nothing is registered (render-artifact.sh owns the registry entry of a rendered artifact)
#   other kinds    nothing to register
#   Registration always uses --replace: it only swaps this run's own record of the output, so a retried step is
#   never blocked by an earlier partial one and a re-run leaves no duplicate.
#
# EXIT CODES
#   0  registered, or there was nothing to register
#   1  artifacts.sh register failed; its message is on stderr
#   2  usage error (nothing written), or the temporary file could not be created
#
# The caller decides what a failure means (both callers mark the step failed and never complete it). This script
# reads and writes no run state. Compatible with macOS bash 3.2 and safe under "set -u".
# ---------------------------------------------------------------------------
set -u

_PO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PO_ARTIFACTS="$_PO_DIR/artifacts.sh"
_PO_TMP=""

_po_cleanup() {
  [ -z "$_PO_TMP" ] || rm -f "$_PO_TMP"
}

_po_usage() {
  sed -n '/^# USAGE$/,/^# EXIT CODES$/p' "${BASH_SOURCE[0]}" | sed -e '1d' -e '/^# EXIT CODES$/d' -e 's/^# \{0,1\}//'
}

_po_main() {
  local run wf step name kind type value src msg rc
  case "${1:-}" in
    -h|--help) _po_usage; return 0 ;;
  esac
  if [ "$#" -ne 7 ]; then
    printf 'Usage: publish-output.sh <run_id> <workflow_id> <step_id> <name> <kind> <type> <value>\n' >&2
    return 2
  fi
  run="$1"; wf="$2"; step="$3"; name="$4"; kind="$5"; type="$6"; value="$7"
  trap _po_cleanup EXIT
  case "$kind" in
    data)
      _PO_TMP=$(mktemp "${TMPDIR:-/tmp}/publish-output.XXXXXX") || {
        printf 'publish-output: cannot create a temporary file\n' >&2
        return 2
      }
      # One line per element for a list type: the stored value is already newline separated.
      if [ -n "$value" ]; then
        printf '%s\n' "$value" > "$_PO_TMP"
      else
        : > "$_PO_TMP"
      fi
      src="$_PO_TMP"
      ;;
    artifact)
      [ -f "$value" ] || return 0
      src="$value"
      ;;
    *) return 0 ;;
  esac
  msg=$(bash "$_PO_ARTIFACTS" register "$wf" "$run" "$step" "$name" --kind "$kind" --type "$type" --file "$src" --replace 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$msg" >&2
    return 1
  fi
  return 0
}

_po_main "$@"
exit $?
