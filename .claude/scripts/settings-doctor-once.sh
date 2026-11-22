#!/usr/bin/env bash
# scripts/settings-doctor-once.sh - tell the user ONCE per session that a skill's settings requirement is inactive (epic E100, task E100_S05_T05)
#
# Usage: settings-doctor-once.sh <skill> [--project-dir <dir>] [--home <dir>]
#        settings-doctor-once.sh --help
#
# <skill> is the skill directory name (e.g. j-workflow-recorder). Runs settings-doctor.sh --skill <skill> --quiet and prints, on
# stdout, a short notice for each inactive requirement of that skill only. Silent when everything is active, when the skill
# declares no fragment, when the doctor or jq is missing, or when the settings cannot be parsed.
#
# Once: after printing a notice it writes a marker file in ${TMPDIR:-/tmp} keyed by session (CLAUDE_SESSION_ID when set, else the
# parent pid), skill and requirement; later calls in the same session print nothing for that requirement. The marker is the only write;
# no settings file and no board file is touched.
#
# Always exits 0: it is advisory and never blocks a skill (a blocking guard such as check-recorder-hook.sh stays separate).
# The doctor is found beside this script, so it works in the monorepo and in node_modules/@jenga-ai/agent/scripts/. bash 3.2 compatible.
# smoke-invoke: --help
set -uo pipefail

case "${1:-}" in
  -h|--help) sed -n '2,/^# smoke-invoke/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
esac

SKILL="${1:-}"; [[ $# -gt 0 ]] && shift
PASS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir|--home) [[ $# -ge 2 ]] || exit 0; PASS+=("$1" "$2"); shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$SKILL" ]] || exit 0

SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || exit 0
DOCTOR="$SELF/settings-doctor.sh"
[[ -f "$DOCTOR" ]] || exit 0

OUT="$(bash "$DOCTOR" --skill "$SKILL" --quiet ${PASS[@]+"${PASS[@]}"} 2>/dev/null)" || true
[[ -n "$OUT" ]] || exit 0

SESSION="${CLAUDE_SESSION_ID:-ppid$PPID}"
SESSION="$(printf '%s' "$SESSION" | tr -c 'A-Za-z0-9._-' '_')"
SKILL_KEY="$(printf '%s' "$SKILL" | tr -c 'A-Za-z0-9._-' '_')"
MDIR="${TMPDIR:-/tmp}"; MDIR="${MDIR%/}"

emit() { # $1 = requirement line, $2 = detail lines
  local line="$1" detail="$2" key marker
  key="$(printf '%s' "$line" | cksum | awk '{print $1}')"
  marker="$MDIR/jenga-settings-once-$SESSION-$SKILL_KEY-$key"
  [[ -e "$marker" ]] && return 0
  { : > "$marker"; } 2>/dev/null || return 0
  printf 'Settings notice (%s): %s\n' "$SKILL" "$line"
  [[ -n "$detail" ]] && printf '%s\n' "$detail"
  return 0
}

CUR=""; DET=""
while IFS= read -r l || [[ -n "$l" ]]; do
  case "$l" in
    '') continue ;;
    [[:space:]]*) [[ -n "$CUR" ]] && DET="${DET:+$DET$'\n'}$l" ;;
    *": inactive") [[ -n "$CUR" ]] && emit "$CUR" "$DET"; CUR="$l"; DET="" ;;
    *) [[ -n "$CUR" ]] && emit "$CUR" "$DET"; CUR=""; DET="" ;;
  esac
done <<EOT
$OUT
EOT
[[ -n "$CUR" ]] && emit "$CUR" "$DET"
exit 0
