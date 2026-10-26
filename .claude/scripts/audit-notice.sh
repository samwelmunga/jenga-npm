#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/audit-notice.sh - one-time opt-in notice for dependency audits (epic E85, task E85_S04_T02)
#
# Audits ship in mode "ask", so nothing runs until the user opts in, and nothing tells them that. This script
# is the deterministic half of a one-time notice; j.init and j.publish only call it (E85_S04_T03/T04). It
# reads the same audit-config.json as scripts/audit-deps.sh and keeps its memory in one marker file.
# Paths come from scripts/resolve-root.sh (honours JENGA_PROJECT_ROOT).
#
# USAGE
#   audit-notice.sh show [--context init|publish]
#   audit-notice.sh status
#   audit-notice.sh -h | --help
#
#   show     decide whether the notice is due; print it when it is, and remember that it was shown
#   status   print "shown" or "not-shown" (from the marker alone, whatever the mode), for tests and skills
#   --context names the caller; it is validated but does not change the text, which is the same everywhere
#
# DECISION (show)
#   mode on                        print nothing, write nothing, exit 0 (audits already run)
#   mode off                       print nothing, write nothing, exit 0 (switched off on purpose, no nagging)
#   mode ask or no config file     notice not yet shown: print it to stdout, write the marker, exit 0
#                                  notice already shown: print nothing, exit 0
#   malformed config, or a mode
#   that is not off, ask or on     print nothing, write nothing, one line on stderr, exit 2 (a notice is
#                                  never built on a guess)
#
# MARKER
#   "$(resolve-root.sh get data)/audit-notice-shown" holds the UTC date the notice was shown. It is written
#   atomically (temp file plus rename) and only when the notice is actually printed. The check-and-write runs
#   under scripts/with-lock.sh, so concurrent callers print the notice once. The marker is git-ignored
#   (project/data/ is partly tracked, so a bare file there could be committed). A failed write never fails the
#   run: the notice is still printed, a warning goes to stderr and the exit status stays 0.
#
# EXIT CODES
#   0  ok (notice printed, or nothing due, or marker could not be written)
#   2  usage error, or malformed audit-config.json / unknown mode
#   3  could not resolve the configs or data path, or jq is missing
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions). Uses jq.
# ---------------------------------------------------------------------------

set -u

SELF="audit-notice.sh"
SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
MARKER_NAME="audit-notice-shown"

err() { printf '%s: %s\n' "$SELF" "$*" >&2; }

usage() {
  printf 'Usage: %s show [--context init|publish]\n' "$SELF"
  printf '       %s status\n' "$SELF"
}

print_notice() {
  printf '%s\n' \
    'Dependency audits are not running yet.' \
    'They are opt-in, so Jenga will not scan your dependencies until you agree.' \
    'To turn them on for this project, run: jenga config set audit-config.mode on' \
    'Or answer yes to the in-session approval prompt to run a single audit,' \
    'or add a committed CI workflow, which supplies the consent for its own runs.'
}

# Prints the mode (off|ask|on). Returns 2 (one stderr line) for a malformed config or unknown mode.
read_mode() { # <config-file>
  local cfg="$1" mode
  if [ ! -f "$cfg" ]; then printf 'ask'; return 0; fi
  if ! jq -e 'type == "object"' "$cfg" >/dev/null 2>&1; then
    err "malformed config $cfg (not a valid JSON object); no notice shown"; return 2
  fi
  mode="$(jq -r 'if has("mode") then (.mode | if type == "string" then . else "invalid" end) else "ask" end' "$cfg" 2>/dev/null)" \
    || { err "unreadable config $cfg; no notice shown"; return 2; }
  case "$mode" in
    off|ask|on) printf '%s' "$mode" ;;
    *) err "invalid mode in $cfg (expected off, ask or on); no notice shown"; return 2 ;;
  esac
}

resolve_dir() { # <key>
  local d
  d="$(bash "$SCRIPT_DIR/resolve-root.sh" get "$1" 2>/dev/null)" && [ -n "$d" ] || {
    err "could not resolve the $1 path via resolve-root.sh"; return 3; }
  printf '%s' "$d"
}

# Atomic marker write; returns non-zero on any failure (caller downgrades it to a warning).
write_marker() { # <marker>
  local marker="$1" dir tmp
  dir="$(dirname "$marker")"
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp="$marker.tmp.$$"
  date -u +%Y-%m-%d > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$marker" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# The check-and-write. Runs under the lock when invoked as `_decide` by cmd_show.
cmd_decide() { # <marker>
  local marker="$1"
  [ -f "$marker" ] && return 0
  print_notice
  write_marker "$marker" || err "warning: could not record the notice in $marker; it may be shown again"
  return 0
}

cmd_show() {
  local context="" configs data mode rc marker
  while [ $# -gt 0 ]; do
    case "$1" in
      --context)
        [ $# -ge 2 ] || { err "--context needs a value"; return 2; }
        context="$2"; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) err "unknown argument: $1"; usage >&2; return 2 ;;
    esac
  done
  case "$context" in
    ""|init|publish) ;;
    *) err "invalid --context '$context' (expected init or publish)"; return 2 ;;
  esac

  command -v jq >/dev/null 2>&1 || { err "jq is required"; return 3; }
  configs="$(resolve_dir configs)" || return 3
  mode="$(read_mode "$configs/audit-config.json")"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  [ "$mode" = ask ] || return 0

  data="$(resolve_dir data)" || return 3
  marker="$data/$MARKER_NAME"
  [ -f "$marker" ] && return 0

  # The lock lives beside the marker, so it can only be taken when that directory is writable. When it is not,
  # the marker cannot be written either: print the notice (once per call) and warn, per the contract.
  mkdir -p "$data" 2>/dev/null
  if [ -d "$data" ] && [ -w "$data" ]; then
    bash "$SCRIPT_DIR/with-lock.sh" "$marker" -- bash "$SCRIPT_PATH" _decide "$marker"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      err "warning: could not take the notice lock (exit $rc); no notice shown this time"
    fi
    return 0
  fi
  cmd_decide "$marker"
}

cmd_status() {
  local data
  data="$(resolve_dir data)" || return 3
  if [ -f "$data/$MARKER_NAME" ]; then printf 'shown\n'; else printf 'not-shown\n'; fi
  return 0
}

[ $# -ge 1 ] || { usage >&2; exit 2; }
sub="$1"; shift
case "$sub" in
  -h|--help) usage; exit 0 ;;
  show) cmd_show "$@"; exit $? ;;
  status)
    [ $# -eq 0 ] || { err "status takes no arguments"; usage >&2; exit 2; }
    cmd_status; exit $? ;;
  _decide) cmd_decide "$1"; exit $? ;;   # internal: the locked half of show
  *) err "unknown subcommand: $sub"; usage >&2; exit 2 ;;
esac
