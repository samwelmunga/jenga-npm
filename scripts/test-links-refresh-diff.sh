#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/test-links-refresh-diff.sh - the `diff` step of the test-links refresh workflow (epic E83, task E83_S04_T03)
#
# Summarises what the extract step changed: compares the PREVIOUS links file (the snapshot the check step took) with the
# regenerated project/knowledge-graph/test-links.json. A link is identified by its (node_id, test_id) pair:
#   added     a pair only in the regenerated file
#   removed   a pair only in the previous file
#   changed   a pair in both whose type, name, file or line differs
# Names are printed as `<node_id> <- <test_id>`, sorted.
#
# USAGE
#   test-links-refresh-diff.sh <snapshot> [--root <dir>]
#   test-links-refresh-diff.sh -h | --help       print this usage on stdout, exit 0
#   <snapshot>     the path printed by test-links-refresh-check.sh, or `none` (no previous file: every link is added).
#                  A real snapshot file is deleted once read (it is a temporary copy).
#   --root <dir>   the repository root; default: the project root from scripts/resolve-root.sh.
#
# STDOUT is ONE JSON object with exactly the keys the workflow declares: added_count, removed_count, changed_count
# (decimal strings) and added, removed, changed (newline-separated names, or `none`).
#
# EXIT CODES
#   0  summary printed
#   2  usage error, jq missing, the snapshot or the regenerated file is missing or not valid JSON
# Compatible with macOS bash 3.2; needs jq.
# ---------------------------------------------------------------------------
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die2() { printf 'test-links-refresh-diff.sh: %s\n' "$*" >&2; exit 2; }

SNAP=""
ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,/^# ----*$/p' "$0" | sed -n '2,$p' | sed 's/^# \{0,1\}//' | sed '$d'; exit 0 ;;
    --root) [ $# -ge 2 ] || die2 "--root needs a value"; ROOT="$2"; shift 2 ;;
    --root=*) ROOT="${1#--root=}"; shift ;;
    -*) die2 "unknown flag: $1" ;;
    *) [ -z "$SNAP" ] || die2 "unexpected argument: $1"; SNAP="$1"; shift ;;
  esac
done
[ -n "$SNAP" ] || die2 "usage: test-links-refresh-diff.sh <snapshot> [--root <dir>]"
command -v jq >/dev/null 2>&1 || die2 "jq is required"

if [ -n "$ROOT" ]; then
  TREE="$(cd "$ROOT" && env -u JENGA_PROJECT_ROOT "$SELF_DIR/resolve-root.sh" tree 2>/dev/null)" || TREE="project"
else
  ROOT="$("$SELF_DIR/resolve-root.sh" root 2>/dev/null)" || die2 "cannot resolve the project root"
  TREE="$("$SELF_DIR/resolve-root.sh" tree 2>/dev/null)" || die2 "cannot resolve the project tree"
fi
NEW="$ROOT/$TREE/knowledge-graph/test-links.json"
[ -f "$NEW" ] || die2 "the regenerated links file does not exist: $NEW"

if [ "$SNAP" = "none" ]; then
  OLD='{"links":[]}'
else
  [ -f "$SNAP" ] || die2 "the snapshot file does not exist: $SNAP"
  OLD="$(cat "$SNAP")"
  rm -f "$SNAP"
fi

printf '%s' "$OLD" | jq -e '.links | arrays' >/dev/null 2>&1 || die2 "the previous links file is not valid links JSON"

jq -c -n --argjson old "$OLD" --slurpfile new "$NEW" '
  def key: "\(.node_id) <- \(.test_id)";
  def idx: reduce .[] as $l ({}; .[$l | key] = $l);
  def lst: if length == 0 then "none" else join("\n") end;
  ($old.links | idx) as $o | ($new[0].links | idx) as $n
  | ($n | keys - ($o | keys)) as $added
  | ($o | keys - ($n | keys)) as $removed
  | ([$n | keys[] | select($o[.] != null and ($o[.] | {type, name, file, line}) != ($n[.] | {type, name, file, line}))]) as $changed
  | { added_count: ($added | length | tostring), removed_count: ($removed | length | tostring),
      changed_count: ($changed | length | tostring),
      added: ($added | lst), removed: ($removed | lst), changed: ($changed | lst) }' \
  || die2 "the regenerated links file is not valid links JSON"
