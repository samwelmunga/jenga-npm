#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# skills/j-connect/scripts/detect-platform.sh
#
# Read-only platform probe for j.connect (E65_S02_T01). Prints ONE compact JSON
# object on stdout and never guesses:
#
#   {"os":"darwin","package_managers":["brew","npm"],"status":"ok",
#    "method":{"manager":"brew","package":"fakecli"},"fallback_docs_url":null}
#   {"os":"unknown","package_managers":[],"status":"unknown","method":null,
#    "fallback_docs_url":"https://example.invalid/fakeservice/install"}
#
# Usage:  detect-platform.sh [--descriptor <file>]
#
#   os                JENGA_CONNECT_PLATFORM if set (lower-cased; the same
#                     override run-descriptor.sh honours), else `uname -s`
#                     lower-cased. Anything but darwin/linux is "unknown".
#   package_managers  the subset of brew, npm found on PATH.
#   --descriptor      method = first install.methods entry whose platform equals
#                     os and whose manager is on PATH. If os is unknown or no
#                     method matches: status "unknown", method null and
#                     fallback_docs_url = install.docs_url (the official
#                     instructions; the caller prints it and never guesses a
#                     command). Otherwise status "ok", fallback_docs_url null.
#   (no descriptor)   method and fallback_docs_url are null; status is "ok" when
#                     the os is recognised, else "unknown".
#
# This script never prints, builds or runs an install command. It reports only
# the manager and bare package name taken from the descriptor.
#
# Exit: 0 whenever a result (including "unknown") was produced; 2 on a usage
#       error or an invalid/unreadable descriptor (nothing on stdout).
# Dependencies: jq only.
# -----------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE="$SCRIPT_DIR/validate-descriptor.sh"

usage_err() { echo "detect-platform: $1" >&2; echo "Usage: $(basename "$0") [--descriptor <file>]" >&2; exit 2; }

DESCRIPTOR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --descriptor) [ $# -ge 2 ] || usage_err "--descriptor needs a value"; DESCRIPTOR="$2"; shift 2 ;;
    -h|--help)    sed -n '/^# Usage:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            usage_err "unexpected argument: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || usage_err "jq is required but not found on PATH"

if [ -n "$DESCRIPTOR" ]; then
  [ -f "$DESCRIPTOR" ] || usage_err "descriptor not found: $DESCRIPTOR"
  if ! VOUT="$(bash "$VALIDATE" "$DESCRIPTOR" 2>&1 >/dev/null)"; then
    printf '%s\n' "$VOUT" >&2
    echo "detect-platform: descriptor rejected" >&2
    exit 2
  fi
fi

# ---- os ---------------------------------------------------------------------
if [ -n "${JENGA_CONNECT_PLATFORM:-}" ]; then
  RAW_OS="$(printf '%s' "$JENGA_CONNECT_PLATFORM" | tr '[:upper:]' '[:lower:]')"
else
  RAW_OS="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
fi
case "$RAW_OS" in darwin|linux) OS="$RAW_OS" ;; *) OS="unknown" ;; esac

# ---- package managers on PATH --------------------------------------------------
PMS=()
for m in brew npm; do
  if command -v "$m" >/dev/null 2>&1; then PMS+=("$m"); fi
done
if [ "${#PMS[@]}" -gt 0 ]; then
  PMS_JSON="$(jq -cn '$ARGS.positional' --args "${PMS[@]}")"
else
  PMS_JSON="[]"
fi

# ---- method ------------------------------------------------------------------
STATUS="ok"
METHOD_JSON="null"
URL_JSON="null"

if [ -n "$DESCRIPTOR" ]; then
  METHOD_JSON="null"
  if [ "$OS" != "unknown" ]; then
    while IFS=$'\t' read -r m_plat m_mgr m_pkg; do
      [ "$m_plat" = "$OS" ] || continue
      if command -v "$m_mgr" >/dev/null 2>&1; then
        METHOD_JSON="$(jq -cn --arg m "$m_mgr" --arg p "$m_pkg" '{manager:$m, package:$p}')"
        break
      fi
    done < <(jq -r '(.install.methods // [])[] | [.platform, .manager, .package] | @tsv' "$DESCRIPTOR")
  fi
  if [ "$METHOD_JSON" = "null" ]; then
    STATUS="unknown"
    URL_JSON="$(jq -c '.install.docs_url' "$DESCRIPTOR")"
  fi
else
  if [ "$OS" = "unknown" ]; then STATUS="unknown"; fi
fi

jq -cn --arg os "$OS" --argjson pms "$PMS_JSON" --arg st "$STATUS" \
  --argjson method "$METHOD_JSON" --argjson url "$URL_JSON" \
  '{os:$os, package_managers:$pms, status:$st, method:$method, fallback_docs_url:$url}'
exit 0
