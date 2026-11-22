#!/usr/bin/env bash
################################################################################
# manual-only.sh — the one definition of "which test files are manual-only"
# (E77_S02_T01; tier:manual primary since E95_S02_T04)
#
# A manual-only test file is excluded from every automated run (j.test, the
# j.commit test gate, npm test) because it runs too long to be part of one. Every
# runner asks THIS script; none keeps a copy of the list.
#
# ---------------------------------------------------------------------------
# PRIMARY FORM: THE bats FILE TAG tier:manual (E95_S02_T04)
#
#   A `.bats` file is manual-only when EITHER
#     1. it carries `tier:manual` in a `# bats file_tags=` comment line (the tier
#        tags of E95_S02_T01, read as bats reads them: any such line in the file,
#        comma-separated, whitespace around a tag trimmed), or
#     2. it carries the legacy marker below (an ALIAS).
#
#   DECISION (story E95_S02): `tier:manual` is the primary form and the legacy
#   marker is kept as a documented alias, not removed. Reasons: this script is
#   called by E77_S06's in-flight scripts (long-running-report.sh,
#   time-shipping-tests.sh, test-subject-paths.sh under skills/j-mirror-public/),
#   whose disposition belongs to E95_S06; removing the marker would break or
#   pre-empt that work. The marker also remains the one place a manual file can
#   state WHY it is manual, since a tag carries no reason.
#
#   `reason` prints the legacy marker's reason when the file has one, otherwise
#   the literal `tier:manual`. A file with the legacy marker but a different
#   tier tag is an inconsistency; `scripts/test-tiers.sh check` reports it as
#   `legacy-marker-without-tier-manual`. This script still treats such a file as
#   manual-only (the safe direction: it is never run by accident).
#
# Usage:
#   manual-only.sh list [--root <dir>]
#   manual-only.sh check <file>
#   manual-only.sh reason <file>
#   manual-only.sh --help
#
# ---------------------------------------------------------------------------
# THE LEGACY MARKER (normative; an alias of tier:manual)
#
#   A comment line within the FIRST 40 LINES of the file:
#
#       # jenga:manual-only: <reason>
#
#   - <reason> is mandatory and one line. Surrounding whitespace is trimmed.
#   - Whitespace is allowed before the `#` and after it. The first matching line
#     wins; a later one is ignored.
#   - A tag with an empty reason (`# jenga:manual-only:` or a bare
#     `# jenga:manual-only`) is INVALID: it is reported as an error (exit 2),
#     so a file cannot be quietly excluded without saying why.
#   - A tag on line 41 or later is not a tag. `# jenga:manual-only-x: ...` is not
#     a tag either.
#
#   The marker lives in the file, not in project/configs/test-config.json: it
#   travels with the file (a private, blocklisted test never leaks its name
#   through a shipped config), cannot outlive a renamed or deleted file, and
#   sits next to the code that makes the test slow.
#
#   Only `.bats` files are wired. The same comment form (`# jenga:manual-only:
#   <reason>` in a language that uses `#` comments) would extend to other
#   ecosystems; the runtime threshold for choosing to tag is documented in
#   project/documentation/test-runner.md ("Manual-only tests").
#
# ---------------------------------------------------------------------------
# SUBCOMMANDS
#
#   list [--root <dir>]
#       One `<root-relative path><TAB><reason>` line per manual-only `*.bats`
#       file (tagged `tier:manual` or carrying the legacy marker; <reason> as
#       for `reason`) found under <root>/tests/ (recursively), in byte
#       (LC_ALL=C) order.
#       Empty output and exit 0 when there are none. <root> is --root, else the
#       root resolved through scripts/resolve-root.sh. Dot-directories,
#       node_modules, and directories named `fixtures` or `__fixtures__` are
#       skipped, like discover-tests.sh (inert test data is not a suite). Symlinks
#       are not followed. A path holding a tab is skipped with a warning on
#       stderr, since it cannot be written as a TSV line. If any file carries an
#       invalid legacy marker, nothing is printed on stdout and the exit is 2.
#   check <file>
#       Exit 0 if <file> is manual-only, 1 if it is not (including any file that
#       is not `*.bats`). No output.
#   reason <file>
#       Print the reason and exit 0 if <file> is manual-only: the legacy
#       marker's reason when present, else `tier:manual`. Exit 1 with no output
#       if it is not.
#
# EXIT CODES
#   0  ok / manual-only
#   1  not manual-only (check, reason)
#   2  usage error, unreadable or missing file/root, or an invalid (empty-reason)
#      tag
#
# READS FILES ONLY. It executes no project code, no test runner and no package
# manager: head, grep, find, sort and the shell's own pattern matching.
################################################################################

set -u

SCRIPT_NAME="manual-only.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# skills/j-test/scripts -> the checkout root, or node_modules/@jenga-ai/agent
# when installed as a dependency.
# shellcheck source=/dev/null
if [ -f "$SCRIPT_DIR/../../index/scripts/package-root.sh" ]; then . "$SCRIPT_DIR/../../index/scripts/package-root.sh"; else jenga_package_root() { (cd "$1/../../.." && pwd); }; fi
REPO_ROOT="$(jenga_package_root "$SCRIPT_DIR")" || true
MAX_HEADER_LINES=40

export LC_ALL=C

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }

usage() {
  # the header comment is the contract: print all of it
  sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed -e '/^set -u/d' -e '/^#\{20,\}$/d' -e 's/^# \{0,1\}//'
}

# a checkout first, then the installed-package location (same pattern as
# discover-tests.sh)
resolve_helper() {
  local rel="$1" candidate
  for candidate in "$REPO_ROOT/$rel" "$REPO_ROOT/node_modules/@jenga-ai/agent/$rel"; do
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# A `# bats file_tags=` comment line holding the tag tier:manual, matched the way
# bats (and scripts/test-tiers.sh) read file tags: comma-separated, trimmed.
TIER_MANUAL_RE='^[[:space:]]*#[[:space:]]*bats[[:space:]]+file_tags=(.*,)?[[:space:]]*tier:manual[[:space:]]*(,.*)?$'

# parse_tag <file>: sets TAG_REASON; returns 0 manual-only, 1 not, 2 invalid
# legacy marker. The legacy marker is read first, because it carries the reason;
# without one, a tier:manual tag makes the file manual-only with reason
# `tier:manual`.
TAG_REASON=""
parse_tag() {
  local rc
  parse_marker "$1"; rc=$?
  [ "$rc" -eq 1 ] || return "$rc"
  if grep -Eq -- "$TIER_MANUAL_RE" "$1" 2>/dev/null; then
    TAG_REASON="tier:manual"
    return 0
  fi
  return 1
}

# parse_marker <file>: the legacy marker only. Sets TAG_REASON; returns 0
# tagged, 1 untagged, 2 invalid (empty-reason) marker.
parse_marker() {
  local line n=0 rest
  TAG_REASON=""
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    if [[ "$line" =~ ^[[:space:]]*#[[:space:]]*jenga:manual-only(:(.*))?$ ]]; then
      rest="${BASH_REMATCH[2]:-}"
      rest="${rest#"${rest%%[![:space:]]*}"}"
      rest="${rest%"${rest##*[![:space:]]}"}"
      [ -n "$rest" ] || return 2
      TAG_REASON="$rest"
      return 0
    fi
    [ "$n" -lt "$MAX_HEADER_LINES" ] || break
  done < <(head -n "$MAX_HEADER_LINES" -- "$1" 2>/dev/null)
  return 1
}

# require_file <file>: a readable regular file, else exit 2.
require_file() {
  if [ ! -f "$1" ] || [ ! -r "$1" ]; then
    err "not a readable file: $1"
    exit 2
  fi
}

cmd_single() {
  local mode="$1" file rc
  [ "$#" -eq 2 ] && [ -n "$2" ] || { err "$mode requires exactly one file argument"; usage >&2; exit 2; }
  file="$2"
  require_file "$file"
  case "$file" in *.bats) ;; *) exit 1 ;; esac
  parse_tag "$file"; rc=$?
  case "$rc" in
    0) [ "$mode" = reason ] && printf '%s\n' "$TAG_REASON"; exit 0 ;;
    1) exit 1 ;;
    *) err "invalid manual-only tag (empty reason): $file"; exit 2 ;;
  esac
}

cmd_list() {
  local root_arg="" root resolver out="" bad=0 f rel rc
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --root)
        [ "$#" -ge 2 ] && [ -n "$2" ] || { err "--root requires a directory argument"; usage >&2; exit 2; }
        root_arg="$2"; shift 2 ;;
      *) err "unknown argument: $1"; usage >&2; exit 2 ;;
    esac
  done
  if [ -n "$root_arg" ]; then
    [ -d "$root_arg" ] || { err "--root is not a directory: $root_arg"; exit 2; }
    root="$(cd -- "$root_arg" && pwd)"
  else
    resolver="$(resolve_helper scripts/resolve-root.sh)" || { err "could not locate scripts/resolve-root.sh"; exit 2; }
    root="$(bash "$resolver" root)" && [ -d "$root" ] || { err "could not resolve the working root"; exit 2; }
  fi
  [ -d "$root/tests" ] || exit 0

  while IFS= read -r -d '' f; do
    rel="${f#"$root"/}"
    parse_tag "$f"; rc=$?
    [ "$rc" -eq 1 ] && continue
    if [ "$rc" -eq 2 ]; then
      err "invalid manual-only tag (empty reason): $rel"
      bad=1
      continue
    fi
    case "$rel" in
      *$'\t'*) err "skipping a path that holds a tab: $rel"; continue ;;
    esac
    out="${out}${rel}"$'\t'"${TAG_REASON}"$'\n'
  done < <(find "$root/tests" \
             \( -type d \( -name '.*' -o -name node_modules -o -name fixtures -o -name __fixtures__ \) ! -path "$root/tests" -prune \) \
             -o \( -type f -name '*.bats' -print0 \) | sort -z)

  [ "$bad" -eq 0 ] || exit 2
  [ -z "$out" ] || printf '%s' "$out"
  exit 0
}

case "${1:-}" in
  list) cmd_list "$@" ;;
  check|reason) cmd_single "$@" ;;
  -h|--help|help) usage; exit 0 ;;
  "") err "a subcommand is required"; usage >&2; exit 2 ;;
  *) err "unknown subcommand: $1"; usage >&2; exit 2 ;;
esac
