#!/usr/bin/env bash
# atlassian-write-marker.sh - the ONLY sanctioned writer of the Atlassian marker (E71_S02_T02).
#
# The marker <configs>/atlassian.json (<configs> from `scripts/resolve-root.sh get configs`, never a hardcoded
# project/ path) is the cheap, offline "claim" that scripts/atlassian-configured.sh reads. It is written ONLY by
# this script, which the j.connect Atlassian flow invokes as its final step. DO NOT EDIT THE MARKER BY HAND, and
# no other skill or the linking layer may write it: a hand-written marker is a claim nothing has verified, which
# is exactly what the drift check in atlassian-configured.sh exists to catch.
#
# Usage:
#   atlassian-write-marker.sh --transport mcp|cli --deployment cloud|datacenter \
#                             --site <https-base-url> --products jira,confluence,bitbucket
#   atlassian-write-marker.sh --disable [same options, all optional]
#
#   --transport   mcp   the Atlassian MCP server entry is in .mcp.json
#                 cli   a local, authenticated `acli`
#   --deployment  cloud | datacenter
#   --site        https:// base URL: a host, optional :port and path; NO credentials (user:token@host), NO query
#                 string or fragment, no whitespace. Trailing slashes are stripped.
#   --products    comma-separated, any non-empty subset of jira, confluence, bitbucket (stored de-duplicated
#                 in that canonical order, so the same intent always produces the same file)
#   --disable     write "enabled": false. Needs no confirmation. Any option left out is taken from the existing
#                 marker; with no complete marker there is nothing to disable (exit 0, nothing written).
#
# Behavior:
#   * Every argument is validated first. Any bad input exits 2 with a message and writes nothing. Messages name
#     the offending option but never echo its value.
#   * Verify before claiming: "enabled": true is written only after `atlassian-configured.sh --check-transport
#     <transport>` confirms the connection. Otherwise it exits 3, prints the gate's reason on stderr and writes
#     nothing, so the marker is never a claim the confirmation step cannot back. (Confirmation logic lives in the
#     gate script alone; it is not duplicated here.)
#   * Atomic and serialised: the JSON is built in a temp file in the same directory, then moved into place under
#     scripts/with-lock.sh on the marker path. Identical arguments leave a byte-identical file and exit 0.
#   * The file holds exactly five fields (enabled, products, deployment, site_base_url, transport) and no secret,
#     token or env-var value. This script accepts, reads, writes and prints no secret: it takes no credential
#     option at all, and unknown options are rejected naming only the flag.
#
# stdout: one JSON object, {"written":true,"enabled":<bool>,"path":"<marker>"} (or {"written":false,...} when
# --disable has nothing to disable). stderr: error messages only.
# Exit codes: 0 ok, 2 invalid arguments, 3 connection not confirmed, 4 could not write (missing jq or
# resolver, unresolvable configs dir, lock timeout, filesystem error).
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions) and safe under
# `set -u`.

set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROG="atlassian-write-marker"
TMP=""

cleanup() {
  if [ -n "$TMP" ]; then rm -f "$TMP"; fi
}
trap cleanup EXIT

fail() { # fail <exit-code> <message>
  printf '%s: %s\n' "$PROG" "$2" >&2
  exit "$1"
}

usage_error() { fail 2 "$1 (see the header of scripts/atlassian-write-marker.sh for usage)"; }

# --- argument parsing --------------------------------------------------------------------------------------
TRANSPORT=""
DEPLOYMENT=""
SITE=""
PRODUCTS=""
DISABLE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --transport|--deployment|--site|--products)
      flag="$1"
      [ $# -ge 2 ] || usage_error "$flag needs a value"
      case "$flag" in
        --transport) TRANSPORT="$2" ;;
        --deployment) DEPLOYMENT="$2" ;;
        --site) SITE="$2" ;;
        --products) PRODUCTS="$2" ;;
      esac
      shift 2
      ;;
    --disable) DISABLE=1; shift ;;
    -h|--help)
      printf 'usage: %s --transport mcp|cli --deployment cloud|datacenter --site <https-url> --products jira,confluence,bitbucket\n       %s --disable [options]\n' "$PROG" "$PROG"
      exit 0
      ;;
    --*) usage_error "unknown option ${1%%=*}" ;;
    *) usage_error "unexpected positional argument" ;;
  esac
done

# --- validators (never echo the value) ---------------------------------------------------------------------
valid_transport() { case "$1" in mcp|cli) return 0 ;; esac; return 1; }
valid_deployment() { case "$1" in cloud|datacenter) return 0 ;; esac; return 1; }

# normalize_products <csv> -> sets PRODUCTS_JSON (canonical order, de-duplicated); returns 1 on bad input.
PRODUCTS_JSON=""
normalize_products() {
  local csv="$1" p jira=0 conf=0 bb=0 out="" oldifs="$IFS"
  [ -n "$csv" ] || return 1
  case "$csv" in ,*|*,|*,,*) return 1 ;; esac
  set -f
  IFS=,
  for p in $csv; do
    case "$p" in
      jira) jira=1 ;;
      confluence) conf=1 ;;
      bitbucket) bb=1 ;;
      *) IFS="$oldifs"; set +f; return 1 ;;
    esac
  done
  IFS="$oldifs"
  set +f
  [ "$jira" = 1 ] && out="\"jira\""
  if [ "$conf" = 1 ]; then
    [ -n "$out" ] && out="$out,"
    out="$out\"confluence\""
  fi
  if [ "$bb" = 1 ]; then
    [ -n "$out" ] && out="$out,"
    out="$out\"bitbucket\""
  fi
  [ -n "$out" ] || return 1
  PRODUCTS_JSON="[$out]"
  return 0
}

# normalize_site <url> -> sets SITE_NORM; returns 1 unless it is an https URL with a plain host[:port][/path],
# no credentials, query, fragment, backslash, whitespace or control character.
SITE_NORM=""
normalize_site() {
  local s="$1" rest auth path
  case "$s" in https://*) ;; *) return 1 ;; esac
  case "$s" in *[[:space:]]*|*[[:cntrl:]]*) return 1 ;; esac
  case "$s" in *\?*|*\#*|*\\*) return 1 ;; esac
  rest="${s#https://}"
  auth="${rest%%/*}"
  path="${rest#"$auth"}"
  case "$auth" in ''|*@*) return 1 ;; esac
  local host_re='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$'
  local path_re='^(/[A-Za-z0-9._~%/-]*)?$'
  [[ $auth =~ $host_re ]] || return 1
  [[ $path =~ $path_re ]] || return 1
  s="https://$auth$path"
  while [ "${s%/}" != "$s" ]; do s="${s%/}"; done
  SITE_NORM="$s"
  return 0
}

# Validate everything the caller supplied before touching anything.
if [ -n "$TRANSPORT" ]; then valid_transport "$TRANSPORT" || usage_error "--transport must be mcp or cli"; fi
if [ -n "$DEPLOYMENT" ]; then valid_deployment "$DEPLOYMENT" || usage_error "--deployment must be cloud or datacenter"; fi
if [ -n "$PRODUCTS" ]; then
  normalize_products "$PRODUCTS" || usage_error "--products must be a comma-separated, non-empty subset of jira, confluence, bitbucket"
fi
if [ -n "$SITE" ]; then
  normalize_site "$SITE" || usage_error "--site must be an https:// base URL with no credentials, query string or fragment"
fi

# --- environment -------------------------------------------------------------------------------------------
command -v jq >/dev/null 2>&1 || fail 4 "jq is required but was not found on PATH"
[ -f "$SELF_DIR/resolve-root.sh" ] || fail 4 "scripts/resolve-root.sh not found next to this script"
[ -f "$SELF_DIR/with-lock.sh" ] || fail 4 "scripts/with-lock.sh not found next to this script"
CONFIGS=$(bash "$SELF_DIR/resolve-root.sh" get configs 2>/dev/null) || CONFIGS=""
[ -n "$CONFIGS" ] || fail 4 "could not resolve the project configs directory"
MARKER="${CONFIGS%/}/atlassian.json"

# --- --disable: fill gaps from the existing marker -----------------------------------------------------------
if [ "$DISABLE" = 1 ]; then
  if [ -f "$MARKER" ] && jq -e 'type == "object"' "$MARKER" >/dev/null 2>&1; then
    if [ -z "$TRANSPORT" ]; then TRANSPORT=$(jq -r '.transport // empty | strings' "$MARKER" 2>/dev/null); fi
    if [ -z "$DEPLOYMENT" ]; then DEPLOYMENT=$(jq -r '.deployment // empty | strings' "$MARKER" 2>/dev/null); fi
    if [ -z "$SITE" ]; then SITE=$(jq -r '.site_base_url // empty | strings' "$MARKER" 2>/dev/null); fi
    if [ -z "$PRODUCTS" ]; then PRODUCTS=$(jq -r '.products // empty | arrays | join(",")' "$MARKER" 2>/dev/null); fi
  fi
  if [ -z "$TRANSPORT" ] || [ -z "$DEPLOYMENT" ] || [ -z "$SITE" ] || [ -z "$PRODUCTS" ]; then
    printf '{"written":false,"reason":"no complete Atlassian marker to disable; Atlassian is already not configured"}\n'
    exit 0
  fi
  # Re-validate values that came from the existing marker (it may have been edited by hand).
  valid_transport "$TRANSPORT" || fail 2 "the existing marker holds an invalid transport; pass --transport explicitly"
  valid_deployment "$DEPLOYMENT" || fail 2 "the existing marker holds an invalid deployment; pass --deployment explicitly"
  normalize_products "$PRODUCTS" || fail 2 "the existing marker holds invalid products; pass --products explicitly"
  normalize_site "$SITE" || fail 2 "the existing marker holds an invalid site_base_url; pass --site explicitly"
  ENABLED=false
else
  [ -n "$TRANSPORT" ] || usage_error "--transport is required"
  [ -n "$DEPLOYMENT" ] || usage_error "--deployment is required"
  [ -n "$SITE" ] || usage_error "--site is required"
  [ -n "$PRODUCTS" ] || usage_error "--products is required"
  ENABLED=true

  # Verify before claiming: the gate script is the single owner of the confirmation logic.
  if CHECK=$(bash "$SELF_DIR/atlassian-configured.sh" --check-transport "$TRANSPORT" 2>/dev/null); then
    :
  else
    REASON=$(printf '%s' "$CHECK" | jq -r '.reason // empty' 2>/dev/null)
    [ -n "$REASON" ] || REASON="the confirmation check failed"
    fail 3 "connection not confirmed, no marker written: $REASON"
  fi
fi

# --- atomic write under the lock -----------------------------------------------------------------------------
mkdir -p "$CONFIGS" 2>/dev/null || fail 4 "could not create the configs directory"
TMP=$(mktemp "${CONFIGS%/}/.atlassian.json.XXXXXX") || fail 4 "could not create a temp file in the configs directory"
jq -n --argjson enabled "$ENABLED" --argjson products "$PRODUCTS_JSON" \
      --arg deployment "$DEPLOYMENT" --arg site "$SITE_NORM" --arg transport "$TRANSPORT" \
      '{enabled: $enabled, products: $products, deployment: $deployment, site_base_url: $site, transport: $transport}' \
      > "$TMP" || fail 4 "could not build the marker JSON"
chmod 644 "$TMP" 2>/dev/null

# Inside the lock: identical content -> drop the temp file (idempotent), else rename it over the marker.
bash "$SELF_DIR/with-lock.sh" "$MARKER" -- sh -c \
  'if [ -f "$2" ] && cmp -s "$1" "$2"; then rm -f "$1"; else mv -f "$1" "$2"; fi' _ "$TMP" "$MARKER" \
  || fail 4 "could not write the marker (lock or filesystem error)"
TMP=""

jq -n -c --argjson enabled "$ENABLED" --arg path "$MARKER" '{written: true, enabled: $enabled, path: $path}'
exit 0
