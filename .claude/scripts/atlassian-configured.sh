#!/usr/bin/env bash
# atlassian-configured.sh - the single gate for "is Atlassian configured for this project?" (E71_S02_T01).
#
# The link prompts in /reconcile (E71_S05) and j.todo (E71_S06) call this script and show themselves only
# on exit 0. It is deterministic, makes NO network call on any path, never hangs, and never reads, stores
# or prints a secret value.
#
# Usage: atlassian-configured.sh
#        atlassian-configured.sh --check-transport mcp|cli
#
# --check-transport (E71_S02_T02, additive): runs ONLY the confirmation step for the named transport and
# neither requires nor reads the marker. scripts/atlassian-write-marker.sh uses it to verify a connection
# before it records "enabled: true", so the confirmation logic lives in one place. Same contract as below
# (one JSON object, exit 0 confirmed / 1 not), but the object is {configured, reason, transport} and a failure
# reason says the connection is "not confirmed" rather than naming marker drift. Without the flag nothing
# below changes.
#
# Output: exactly one JSON object on stdout, always.
#   configured (bool), reason (string)                         - always present
#   products, deployment, transport, site_base_url             - present only when configured
# Exit codes: 0 configured, 1 not configured (including drift and a malformed marker).
# Nothing is written to stderr on any ordinary path (a missing marker is the normal case, not an error).
#
# Marker: <configs>/atlassian.json, with <configs> from `scripts/resolve-root.sh get configs` (never a
# hardcoded project/ path). It is written ONLY by the j.connect Atlassian flow (E71_S02_T02) - do not edit
# it by hand. Schema, five fields, no secret, token or env-var VALUE:
#   enabled        bool                                      false (or a missing marker) = not configured
#   products       array, subset of jira|confluence|bitbucket
#   deployment     cloud | datacenter
#   site_base_url  string                                    e.g. https://example.atlassian.net
#   transport      mcp | cli                                 which confirmation method applies
#
# The marker is the cheap offline "claim"; the confirmation below is the cheap check that it still holds:
#   transport mcp  the project .mcp.json (anchor dir from resolve-root.sh) has the Atlassian server entry.
#                  The entry name/URL is read with jq from the atlassian-cloud descriptor's register_mcp
#                  (name, url; the URL is compared ignoring query string and fragment), never copied here.
#                  If the descriptor is absent, or registers no server (supported:false), any entry whose
#                  name or url mentions "atlassian" counts. Path override: JENGA_ATLASSIAN_DESCRIPTOR.
#   transport cli  a local `acli` auth-status check, each attempt bounded by ACLI_TIMEOUT seconds (5)
#                  via timeout/gtimeout or a portable background-and-kill fallback. acli's own output is
#                  discarded. JENGA_ATLASSIAN_ACLI_TIMEOUT overrides the 5 (whole seconds; tests use it).
#                  The exact acli subcommand is not verified against a real account (E71_S08);
#                  both `acli auth status` and `acli jira auth status` are tried, either succeeding counts.
# Drift (marker enabled but the entry is gone / acli unauthenticated, missing or timed out) is never treated
# as configured: exit 1, configured:false, and a reason naming the drift and the remedy.
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions) and safe
# under `set -u`.

set -u

ACLI_TIMEOUT="${JENGA_ATLASSIAN_ACLI_TIMEOUT:-5}"
case "$ACLI_TIMEOUT" in
  ''|*[!0-9]*|0) ACLI_TIMEOUT=5 ;;
esac
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMEDY="re-run j.connect for Atlassian, or set \"enabled\" to false in the marker"

# --check-transport <mcp|cli>: confirmation-only mode (see header). CHECK_TRANSPORT stays empty otherwise.
CHECK_TRANSPORT=""
TRANSPORT=""
if [ "${1:-}" = "--check-transport" ]; then
  case "${2:-}" in
    mcp|cli) CHECK_TRANSPORT="$2"; TRANSPORT="$2" ;;
    *)
      printf '{"configured":false,"reason":"--check-transport needs mcp or cli"}\n'
      exit 1
      ;;
  esac
fi

# drift <detail>: the marker is enabled but the connection no longer holds (normal mode), or the connection
# was never confirmed (check mode). <detail> completes "... with transport <t> <detail>".
drift() {
  if [ -n "$CHECK_TRANSPORT" ]; then
    emit false "Atlassian connection not confirmed for transport $TRANSPORT: ${1#but }; finish the j.connect Atlassian steps for this transport first"
  fi
  emit false "Atlassian marker drift: the marker is enabled with transport $TRANSPORT $1; $REMEDY"
}

# emit <configured:true|false> <reason> [marker-file]  -> prints the one JSON object, then exits with its code.
emit() {
  local configured="$1" reason="$2" marker="${3:-}"
  if ! command -v jq >/dev/null 2>&1; then
    # jq missing: reason strings we pass contain no quotes or backslashes except via REMEDY (escaped).
    printf '{"configured":false,"reason":"jq is required but was not found on PATH; install jq"}\n'
    exit 1
  fi
  if [ "$configured" = "true" ] && [ -n "$CHECK_TRANSPORT" ]; then
    jq -n -c --arg reason "$reason" --arg t "$CHECK_TRANSPORT" '{configured: true, reason: $reason, transport: $t}'
    exit 0
  fi
  if [ "$configured" = "true" ]; then
    jq -n -c --arg reason "$reason" --slurpfile m "$marker" \
      '{configured: true, reason: $reason, products: $m[0].products, deployment: $m[0].deployment,
        transport: $m[0].transport, site_base_url: $m[0].site_base_url}'
    exit 0
  fi
  jq -n -c --arg reason "$reason" '{configured: false, reason: $reason}'
  exit 1
}

# run_bounded <seconds> <cmd...>: run cmd with all output discarded, killed after <seconds>; returns its status
# (non-zero, 124 or the kill status, on timeout).
run_bounded() {
  local secs="$1" pid watcher rc
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@" >/dev/null 2>&1 </dev/null
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@" >/dev/null 2>&1 </dev/null
    return $?
  fi
  "$@" >/dev/null 2>&1 </dev/null 3>&- &
  pid=$!
  ( sleep "$secs"; kill -9 "$pid" ) >/dev/null 2>&1 3>&- &
  watcher=$!
  { wait "$pid"; } 2>/dev/null
  rc=$?
  kill "$watcher" >/dev/null 2>&1
  { wait "$watcher"; } 2>/dev/null
  return "$rc"
}

# --- resolve the marker location through the shared resolver -------------------------------------------
RESOLVER="$SELF_DIR/resolve-root.sh"
CONFIGS=""
ROOT=""
if [ -f "$RESOLVER" ]; then
  CONFIGS=$(bash "$RESOLVER" get configs 2>/dev/null) || CONFIGS=""
  ROOT=$(bash "$RESOLVER" root 2>/dev/null) || ROOT=""
fi
if [ -n "$CHECK_TRANSPORT" ]; then
  # check mode needs only the project root (for .mcp.json), never the marker
  if [ -z "$ROOT" ]; then
    emit false "Atlassian connection not confirmed for transport $TRANSPORT: could not resolve the project root"
  fi
elif [ -z "$CONFIGS" ] || [ -z "$ROOT" ]; then
  emit false "Atlassian is not configured for this project (could not resolve the project configs directory)"
fi

MARKER="${CONFIGS%/}/atlassian.json"

if [ -z "$CHECK_TRANSPORT" ]; then
# --- no marker: the normal case -------------------------------------------------------------------------
if [ ! -f "$MARKER" ]; then
  emit false "Atlassian is not configured for this project (no atlassian.json marker)"
fi

if ! command -v jq >/dev/null 2>&1; then
  emit false "jq is required but was not found on PATH"
fi

# --- malformed marker ------------------------------------------------------------------------------------
if ! jq -e 'type == "object"' "$MARKER" >/dev/null 2>&1; then
  emit false "Atlassian marker is malformed: atlassian.json is not a valid JSON object; $REMEDY"
fi

ENABLED_TYPE=$(jq -r '.enabled | type' "$MARKER" 2>/dev/null)
if [ "$ENABLED_TYPE" != "boolean" ]; then
  emit false "Atlassian marker is malformed: \"enabled\" must be true or false; $REMEDY"
fi
if [ "$(jq -r '.enabled' "$MARKER")" != "true" ]; then
  emit false "Atlassian is not configured for this project (marker has enabled: false)"
fi

PROBLEM=$(jq -r '
  if ((.products | type) != "array") or ((.products | length) == 0)
     or (.products | any(. != "jira" and . != "confluence" and . != "bitbucket"))
    then "\"products\" must be a non-empty array of jira, confluence, bitbucket"
  elif (.deployment != "cloud" and .deployment != "datacenter")
    then "\"deployment\" must be cloud or datacenter"
  elif (.transport != "mcp" and .transport != "cli")
    then "\"transport\" must be mcp or cli"
  elif ((.site_base_url | type) != "string") or (.site_base_url == "")
    then "\"site_base_url\" must be a non-empty string"
  else "" end' "$MARKER" 2>/dev/null)
if [ -n "$PROBLEM" ]; then
  emit false "Atlassian marker is malformed: $PROBLEM; $REMEDY"
fi

TRANSPORT=$(jq -r '.transport' "$MARKER")
fi

# --- confirm ---------------------------------------------------------------------------------------------
if [ "$TRANSPORT" = "mcp" ]; then
  MCP_FILE="${ROOT%/}/.mcp.json"
  if [ ! -f "$MCP_FILE" ]; then
    drift "but .mcp.json is missing"
  fi

  DESC="${JENGA_ATLASSIAN_DESCRIPTOR:-}"
  if [ -z "$DESC" ]; then
    for cand in "$SELF_DIR/../skills/j-connect/descriptors/atlassian-cloud.json" \
                "$SELF_DIR/../../skills/j-connect/descriptors/atlassian-cloud.json"; do
      if [ -f "$cand" ]; then DESC="$cand"; break; fi
    done
  fi
  WANT_NAME=""
  WANT_URL=""
  if [ -n "$DESC" ] && [ -f "$DESC" ]; then
    WANT_NAME=$(jq -r 'if .register_mcp.supported == true then (.register_mcp.name // "") else "" end' "$DESC" 2>/dev/null) || WANT_NAME=""
    WANT_URL=$(jq -r 'if .register_mcp.supported == true then (.register_mcp.url // "") else "" end' "$DESC" 2>/dev/null) || WANT_URL=""
  fi

  FOUND=$(jq -r --arg name "$WANT_NAME" --arg url "$WANT_URL" '
    def strip: sub("[?#].*$"; "");
    def lc: ascii_downcase;
    (.mcpServers // {}) as $s
    | if (($s | type) != "object") then "false"
      elif ($name != "" or $url != "") then
        (($name != "" and ($s | has($name)))
         or ($url != "" and ($s | to_entries | any(((.value.url // "") | strip) == ($url | strip))))) | tostring
      else
        ($s | to_entries | any((.key | lc | contains("atlassian")) or ((.value.url // "") | lc | contains("atlassian")))) | tostring
      end' "$MCP_FILE" 2>/dev/null) || FOUND="false"

  if [ "$FOUND" != "true" ]; then
    drift "but the Atlassian MCP server entry is not in .mcp.json"
  fi
  emit true "Atlassian is configured (MCP server entry confirmed in .mcp.json)" "$MARKER"
fi

# transport cli
if ! command -v acli >/dev/null 2>&1; then
  drift "but acli is not installed"
fi
if run_bounded "$ACLI_TIMEOUT" acli auth status || run_bounded "$ACLI_TIMEOUT" acli jira auth status; then
  emit true "Atlassian is configured (acli authenticated)" "$MARKER"
fi
drift "but acli is not authenticated (or its auth check failed or timed out after ${ACLI_TIMEOUT}s)"
