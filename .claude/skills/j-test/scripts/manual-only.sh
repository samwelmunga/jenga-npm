#!/usr/bin/env bash
################################################################################
# manual-only.sh — the one definition of "which test files are manual-only"
# (E77_S02_T01)
#
# A manual-only test file is excluded from every automated run (j.test, the
# j.commit test gate, npm test) because it runs too long to be part of one. Every
# runner asks THIS script; none keeps a copy of the list.
#
# Usage:
#   manual-only.sh list [--root <dir>]
#   manual-only.sh check <file>
#   manual-only.sh reason <file>
#   manual-only.sh --help
#
# ---------------------------------------------------------------------------
# THE MARKER (normative)
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
#       file found under <root>/tests/ (recursively), in byte (LC_ALL=C) order.
#       Empty output and exit 0 when there are none. <root> is --root, else the
#       root resolved through scripts/resolve-root.sh. Dot-directories,
#       node_modules, and directories named `fixtures` or `__fixtures__` are
#       skipped, like discover-tests.sh (inert test data is not a suite). Symlinks
#       are not followed. A path holding a tab is skipped with a warning on
#       stderr, since it cannot be written as a TSV line. If any file carries an
#       invalid tag, nothing is printed on stdout and the exit is 2.
#   check <file>
#       Exit 0 if <file> is manual-only, 1 if it is not (including any file that
#       is not `*.bats`). No output.
#   reason <file>
#       Print the reason and exit 0 if <file> is manual-only; exit 1 with no
#       output if it is not.
#
# EXIT CODES
#   0  ok / manual-only
#   1  not manual-only (check, reason)
#   2  usage error, unreadable or missing file/root, or an invalid (empty-reason)
#      tag
#
# READS FILES ONLY. It executes no project code, no test runner and no package
# manager: head, find, sort and the shell's own pattern matching.
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

# parse_tag <file>: sets TAG_REASON; returns 0 tagged, 1 untagged, 2 invalid tag.
TAG_REASON=""
parse_tag() {
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
