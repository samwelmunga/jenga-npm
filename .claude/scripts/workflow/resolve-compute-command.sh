#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/workflow/resolve-compute-command.sh - confine a workflow compute step's `command` to the allow-listed
# script roots (epic E80, task E80_S04_T02)
#
# A compute step's `command` is the one place a workflow definition can make the framework execute something.
# This script decides whether a command string names a script the framework may run, and prints that script's
# absolute path. It NEVER runs the script (it only tests and resolves paths), it creates no file or directory,
# and it is the single place the confinement rule lives so it can be tested in isolation.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   resolve-compute-command.sh <command>
#   resolve-compute-command.sh -h | --help      print this usage on stdout, exit 0
#
#   <command>   ONE argument: a relative path, from the project anchor, to an executable regular file. Arguments
#               to that script are a separate step field and are never part of the command.
#
# On success: one line on stdout, the absolute real (symlink-resolved) path of the script, exit 0.
# On failure: nothing on stdout, one line on stderr naming the reason, a non-zero exit.
#
# ---------------------------------------------------------------------------
# ALLOW-LISTED ROOTS (relative to the anchor printed by `scripts/resolve-root.sh root`)
# ---------------------------------------------------------------------------
#   scripts/                          any depth
#   skills/<name>/scripts/            any depth, exactly one directory between skills/ and scripts/
#   <workflows>/scripts/              <workflows> is resolve-root.sh's `workflows` path key (default
#                                     project/.workflows, a relocated tree uses .project/.workflows); it is never
#                                     hardcoded here
#   node_modules/@jenga-ai/agent/scripts/ and node_modules/@jenga-ai/agent/skills/<name>/scripts/
#                                     the consumer-install counterparts of the first two
#
# The anchor honours JENGA_PROJECT_ROOT (resolve-root.sh does the work), so a relocated tree and a consumer install
# both work. Every root is itself resolved to its physical directory before comparing, so a symlinked package
# directory is fine; a symlink INSIDE a root that points outside it is not.
#
# ---------------------------------------------------------------------------
# CHECKS, in this order (each failure has its own message)
# ---------------------------------------------------------------------------
#   6  empty string
#   1  not a single plain path token: more than one argument, whitespace, a newline, a shell metacharacter
#      (; | & $ ` < > ( )), a glob character (* ? [ ]) or any character outside A-Z a-z 0-9 . _ @ + / -
#   2  an absolute path, or a `..` segment
#   -  (the anchor and workflow directory are located here; failure exits 3)
#   4  the path does not exist
#   3  after resolving symlinks, the real path is not inside an allow-listed root
#   4  the path is not a regular file (a directory, a device, ...)
#   5  the file is not executable
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0  resolved; the path is on stdout
#   1  rejected (one of the six reasons above)
#   2  usage error (no argument)
#   3  the working-file anchor or workflow directory cannot be resolved (resolve-root.sh's message is passed on)
#
# Compatible with macOS bash 3.2 (no realpath, no associative arrays, no mapfile) and safe under `set -u`.
# ---------------------------------------------------------------------------

set -u
LC_ALL=C

_CC_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
_CC_RESOLVE_ROOT="$_CC_DIR/../resolve-root.sh"
# shellcheck source=lib.sh
. "$_CC_DIR/lib.sh" || exit 3

_cc_usage() {
  printf '%s\n' "Usage: resolve-compute-command.sh <command>" \
    "  <command>  one relative path from the project anchor to an executable file under scripts/," \
    "             skills/<name>/scripts/ or <workflows>/scripts/ (also under the installed package directory)." \
    "  Prints the script's absolute path; never runs it. Exit: 0 ok, 1 rejected, 2 usage, 3 anchor unresolvable."
}

# Prints a one-line rejection on stderr and exits 1.
_cc_reject() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

# Prints the physical path of directory $1; returns 1 when it is not a directory. Runs in a subshell, so the
# caller's working directory is untouched.
_cc_realdir() {
  [ -d "$1" ] || return 1
  (CDPATH='' cd -P -- "$1" >/dev/null 2>&1 && pwd -P)
}

# Prints the physical path of file $1 (absolute): follows a symlink in the final component with readlink (the
# BSD form without -f), then resolves the directory part with cd -P. Returns 1 on a loop or an unresolvable
# directory.
_cc_realfile() {
  local p="$1" n=0 t d b
  while [ -L "$p" ]; do
    n=$((n + 1))
    [ "$n" -le 40 ] || return 1
    t=$(readlink "$p") || return 1
    case "$t" in
      /*) p="$t" ;;
      *) p="${p%/*}/$t" ;;
    esac
  done
  d="${p%/*}"
  b="${p##*/}"
  [ -n "$d" ] || d="/"
  d=$(_cc_realdir "$d") || return 1
  if [ "$d" = "/" ]; then
    printf '/%s\n' "$b"
  else
    printf '%s/%s\n' "$d" "$b"
  fi
}

# True when path $1 lies strictly below directory $2.
_cc_under() {
  [ "${1#"$2"/}" != "$1" ]
}

# True when real file path $1 is inside an allow-listed root. Uses the globals ANCHOR and WFDIR.
_cc_confined() {
  local real="$1" base d rest after pkgdir
  pkgdir=$(workflow_consumer_pkg_dir "$ANCHOR") || return 1
  for base in "$ANCHOR" "$pkgdir"; do
    if d=$(_cc_realdir "$base/scripts") && _cc_under "$real" "$d"; then
      return 0
    fi
    if d=$(_cc_realdir "$base/skills") && _cc_under "$real" "$d"; then
      rest="${real#"$d"/}"
      after="${rest#*/}"
      case "$after" in
        scripts/?*) return 0 ;;
      esac
    fi
  done
  if d=$(_cc_realdir "$WFDIR/scripts") && _cc_under "$real" "$d"; then
    return 0
  fi
  return 1
}

_cc_main() {
  local cmd cand real

  if [ "$#" -eq 0 ]; then
    _cc_usage >&2
    return 2
  fi
  if [ "$#" -eq 1 ]; then
    case "$1" in
      -h|--help) _cc_usage; return 0 ;;
    esac
  fi
  if [ "$#" -gt 1 ]; then
    _cc_reject "command must be a single path token (arguments belong in the step's own field, not in command)"
  fi
  cmd="$1"

  # 6: empty
  [ -n "$cmd" ] || _cc_reject "command is empty"

  # 1: single plain path token (character allow-list, so whitespace, newlines, metacharacters and globs all fail)
  case "$cmd" in
    *[!A-Za-z0-9._@+/-]*)
      _cc_reject "command must be a single path token: no whitespace, newline, shell metacharacter (; | & \$ \` < > ( )) or glob character"
      ;;
  esac

  # 2: absolute path or '..' segment
  case "$cmd" in
    /*) _cc_reject "command must be a relative path: absolute paths and '..' segments are not allowed ('$cmd')" ;;
  esac
  case "/$cmd/" in
    */../*) _cc_reject "command must be a relative path: absolute paths and '..' segments are not allowed ('$cmd')" ;;
  esac

  # Locate the anchor and the workflow directory through the shared resolver.
  if [ ! -f "$_CC_RESOLVE_ROOT" ]; then
    printf 'Error: cannot resolve the working-file location; %s is missing\n' "$_CC_RESOLVE_ROOT" >&2
    return 3
  fi
  ANCHOR=$(bash "$_CC_RESOLVE_ROOT" root) || return 3
  WFDIR=$(bash "$_CC_RESOLVE_ROOT" get workflows) || return 3
  [ -n "$ANCHOR" ] && [ -n "$WFDIR" ] || {
    printf 'Error: cannot resolve the working-file location (empty answer from resolve-root.sh)\n' >&2
    return 3
  }

  cand="${ANCHOR%/}/$cmd"

  # 4: existence (a dangling symlink or a symlink loop does not exist)
  [ -e "$cand" ] || _cc_reject "command does not exist or is not a regular file ('$cmd')"

  # 3: confinement, judged on the real path
  real=$(_cc_realfile "$cand") || _cc_reject "command does not exist or is not a regular file ('$cmd')"
  _cc_confined "$real" || _cc_reject "command resolves outside the allow-listed script roots (scripts/, skills/*/scripts/, the workflows scripts directory): '$cmd'"

  # 4: regular file
  [ -f "$real" ] || _cc_reject "command does not exist or is not a regular file ('$cmd')"

  # 5: executable
  [ -x "$real" ] || _cc_reject "command is not executable ('$cmd')"

  printf '%s\n' "$real"
}

ANCHOR=""
WFDIR=""
_cc_main "$@"
exit $?
