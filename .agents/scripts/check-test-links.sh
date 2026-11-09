#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/check-test-links.sh - is the derived test-links file still true to the repo? (epic E83, task E83_S04_T01)
#
# The deterministic "has anything changed" check of the test-to-architecture refresh flow. It reads the derived links
# file project/knowledge-graph/test-links.json (shape owned by scripts/validate-test-links.sh, written only by
# scripts/extract-test-links.sh), compares it with the graph and the test files as they are now, and reports `fresh` or
# `stale` with typed reasons. It never writes: no links file, no graph, no test file, and no temporary file.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   check-test-links.sh [--root <dir>] [--links <file>] [--json]
#   check-test-links.sh -h | --help       print this usage on stdout, exit 0
#
#   --root <dir>    the repository root whose graph and test files are compared; default: the project root from
#                   scripts/resolve-root.sh root. Also --root=<dir>. The project tree name (project or .project) used for
#                   the default paths comes from resolve-root.sh too (for an explicit --root it is resolved from inside
#                   that directory, ignoring JENGA_PROJECT_ROOT, and falls back to "project").
#   --links <file>  the links file to check; default: <root>/<tree>/knowledge-graph/test-links.json (normally
#                   <root>/project/knowledge-graph/test-links.json). Also --links=<file>.
#   --json          print ONE JSON object on stdout, {"status":"fresh|stale","reasons":[{"type":...}],"informational":[...]},
#                   and diagnostics on stderr. Without it a short human summary goes to stdout. The verdict and the exit
#                   status are the same either way.
#
# The graph compared is <root>/<tree>/knowledge-graph/graph.json; linked test files are resolved under <root>. Compatible
# with macOS bash 3.2 (no mapfile, no associative arrays, no case-modifying expansions); needs jq, awk, find, sort, grep and
# `shasum -a 256` or `sha256sum`, whichever exists (the same helper approach as extract-test-links.sh).
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   fresh: nothing in the links file is out of date (informational entries never change this)
#   1   stale: at least one reason was found, or the links file does not exist (reason no-links-file)
#   2   usage error (unknown flag, flag without a value, positional argument); the root is missing or unreadable; the links
#       path exists but is not a readable regular file; a linked test file is unreadable; a required tool (jq, a SHA-256
#       tool) is missing; or the links file is rejected by scripts/validate-test-links.sh (invalid JSON, wrong shape, or any
#       rule violation). The validator's own message is printed on stderr. No verdict is printed with exit 2.
#
# ---------------------------------------------------------------------------
# REASONS (each is an object with a "type"; every reason makes the verdict stale)
# ---------------------------------------------------------------------------
#   no-links-file     {links}                                   the links file does not exist; nothing else is checked
#   graph-changed     {recorded, current}                       SHA-256 of graph.json (or the literal `absent` when there
#                                                                is no graph.json) differs from generated_from.graph_sha256
#   test-changed      {file, recorded, current}                 a linked test file's SHA-256 differs from generated_from.tests
#   test-removed      {file, recorded}                          a linked test file no longer exists (or is not a regular file)
#   node-missing      {node_id, test_id, file}                  a link's node id is not a node of the graph (one reason per
#                                                                link; with no graph.json every link is reported)
#   node-superseded   {node_id, superseded_by, test_id, file}   the node exists with status: superseded; superseded_by names
#                                                                the node that replaced it (null when the graph omits it)
# Order: graph-changed, then test-changed / test-removed by file path, then node-missing / node-superseded in links order.
# When graph.json exists but is not valid JSON or has no .nodes array, the node checks are skipped with a note on stderr
# (graph-changed normally covers it, since the hash then differs from the recorded one).
#
# INFORMATIONAL (never changes the verdict; best effort)
#   unlinked-new-test {file}     a test file of the supported shapes (tests/*.bats direct children; *.test.js anywhere under
#                                the root except node_modules, .git, any directory named fixtures and dot-directories, the
#                                same scan set as extract-test-links.sh) that is in none of the links and carries no
#                                `arch-node:` annotation line (the links source). At most 20 names, in path order; when
#                                more exist a final entry {"type":"unlinked-new-test-omitted","count":<n>} says how many were
#                                left out. Skipped when the links file is missing. A file that is in the links source but
#                                missing from generated_from.tests is not covered by any reason here; re-extract.
# Paths containing a newline are not supported.
# ---------------------------------------------------------------------------

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$(basename "$0")"
VALIDATOR="$SELF_DIR/validate-test-links.sh"
US="$(printf '\037')"
CAP=20

usage() {
  printf 'usage: %s [--root <dir>] [--links <file>] [--json]\n' "$SELF" >&2
}

die2() {
  printf '%s: %s\n' "$SELF" "$*" >&2
  exit 2
}

ROOT=""
HAVE_ROOT=0
LINKS=""
HAVE_LINKS=0
AS_JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      [ $# -ge 2 ] || { usage; die2 "--root needs a value"; }
      ROOT="$2"; HAVE_ROOT=1
      shift 2
      ;;
    --root=*)
      ROOT="${1#--root=}"; HAVE_ROOT=1
      [ -n "$ROOT" ] || { usage; die2 "--root needs a value"; }
      shift
      ;;
    --links)
      [ $# -ge 2 ] || { usage; die2 "--links needs a value"; }
      LINKS="$2"; HAVE_LINKS=1
      shift 2
      ;;
    --links=*)
      LINKS="${1#--links=}"; HAVE_LINKS=1
      [ -n "$LINKS" ] || { usage; die2 "--links needs a value"; }
      shift
      ;;
    --json)
      AS_JSON=1
      shift
      ;;
    -h|--help)
      printf 'usage: %s [--root <dir>] [--links <file>] [--json]\n' "$SELF"
      exit 0
      ;;
    *)
      usage
      die2 "unknown argument: $1"
      ;;
  esac
done

[ -n "$ROOT" ] || [ "$HAVE_ROOT" -eq 0 ] || die2 "--root needs a value"
[ -n "$LINKS" ] || [ "$HAVE_LINKS" -eq 0 ] || die2 "--links needs a value"

command -v jq >/dev/null 2>&1 || die2 "jq is required"
if command -v shasum >/dev/null 2>&1; then
  SHA_CMD="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
  SHA_CMD="sha256sum"
else
  die2 "neither shasum nor sha256sum is available"
fi

sha256_of() {
  # $1: path. Prints the 64 hex digits, nothing else.
  $SHA_CMD "$1" 2>/dev/null | awk '{print $1; exit}'
}

# ---- root and tree --------------------------------------------------------------------------------------------------
if [ "$HAVE_ROOT" -eq 0 ]; then
  ROOT="$("$SELF_DIR/resolve-root.sh" root 2>/dev/null)" || die2 "cannot resolve the project root (scripts/resolve-root.sh root failed)"
  TREE="$("$SELF_DIR/resolve-root.sh" tree 2>/dev/null)" || die2 "cannot resolve the project tree (scripts/resolve-root.sh tree failed)"
fi
[ -d "$ROOT" ] && [ -r "$ROOT" ] || die2 "root is not a readable directory: $ROOT"
ROOT="$(cd "$ROOT" && pwd)" || die2 "cannot enter root: $ROOT"
if [ "$HAVE_ROOT" -eq 1 ]; then
  TREE="$(cd "$ROOT" && env -u JENGA_PROJECT_ROOT "$SELF_DIR/resolve-root.sh" tree 2>/dev/null)" || TREE="project"
fi

GRAPH="$ROOT/$TREE/knowledge-graph/graph.json"
if [ "$HAVE_LINKS" -eq 0 ]; then
  LINKS="$ROOT/$TREE/knowledge-graph/test-links.json"
fi

# ---- accumulators: compact JSON objects, one per line, kept in shell variables (no scratch file) -----------------------
REASONS=""
INFO=""
NREASONS=0

add_reason() {
  REASONS="$REASONS$1"$'\n'
  NREASONS=$((NREASONS + 1))
}

NLINKS=0
NTESTS=0
INFO_NOTE=""

# ---- the links file: missing is a verdict, anything else wrong is an error ---------------------------------------------
if [ ! -e "$LINKS" ] && [ ! -L "$LINKS" ]; then
  add_reason "$(jq -nc --arg l "$LINKS" '{type: "no-links-file", links: $l}')"
else
  [ -f "$LINKS" ] && [ -r "$LINKS" ] || die2 "links file is not a readable regular file: $LINKS"

  VERDICT="$(bash "$VALIDATOR" -- "$LINKS" 2>&1)"
  vrc=$?
  if [ "$vrc" -ne 0 ]; then
    printf '%s: the links file is rejected by validate-test-links.sh (exit %s): %s\n' "$SELF" "$vrc" "$VERDICT" >&2
    exit 2
  fi

  NLINKS="$(jq '.links | length' "$LINKS")" || die2 "cannot read the links file: $LINKS"
  NTESTS="$(jq '.generated_from.tests | length' "$LINKS")" || die2 "cannot read the links file: $LINKS"

  # -- graph hash ---------------------------------------------------------------------------------------------------
  RECORDED="$(jq -r '.generated_from.graph_sha256' "$LINKS")"
  if [ -f "$GRAPH" ]; then
    CURRENT="$(sha256_of "$GRAPH")"
    [ -n "$CURRENT" ] || die2 "cannot hash the graph file: $GRAPH"
  else
    CURRENT="absent"
  fi
  if [ "$CURRENT" != "$RECORDED" ]; then
    add_reason "$(jq -nc --arg r "$RECORDED" --arg c "$CURRENT" '{type: "graph-changed", recorded: $r, current: $c}')"
  fi

  # -- linked test files --------------------------------------------------------------------------------------------
  while IFS="$US" read -r f rec; do
    [ -n "$f" ] || continue
    if [ ! -f "$ROOT/$f" ]; then
      add_reason "$(jq -nc --arg f "$f" --arg r "$rec" '{type: "test-removed", file: $f, recorded: $r}')"
      continue
    fi
    cur="$(sha256_of "$ROOT/$f")"
    [ -n "$cur" ] || die2 "cannot hash the test file: $f"
    if [ "$cur" != "$rec" ]; then
      add_reason "$(jq -nc --arg f "$f" --arg r "$rec" --arg c "$cur" '{type: "test-changed", file: $f, recorded: $r, current: $c}')"
    fi
  done <<EOF
$(jq -r '.generated_from.tests | to_entries | sort_by(.key)[] | "\(.key)\u001f\(.value)"' "$LINKS")
EOF

  # -- link nodes against the graph ---------------------------------------------------------------------------------
  NODES=""
  if [ ! -f "$GRAPH" ]; then
    NODES="[]"
  elif jq -e '(type == "object") and (.nodes | type == "array")' "$GRAPH" >/dev/null 2>&1; then
    NODES="$(jq -c '[.nodes[] | select(type == "object" and (.id | type) == "string")]' "$GRAPH")" || NODES=""
  fi
  if [ -z "$NODES" ]; then
    printf '%s: note: %s is not valid JSON or has no .nodes array; node checks skipped\n' "$SELF" "$GRAPH" >&2
  else
    NODE_REASONS="$(jq -c --argjson nodes "$NODES" '
      ($nodes | map({key: .id, value: .}) | from_entries) as $n
      | .links[]
      | . as $l
      | $n[$l.node_id] as $node
      | if $node == null then
          {type: "node-missing", node_id: $l.node_id, test_id: $l.test_id, file: $l.file}
        elif $node.status == "superseded" then
          {type: "node-superseded", node_id: $l.node_id, superseded_by: ($node.superseded_by // null), test_id: $l.test_id, file: $l.file}
        else empty end' "$LINKS")" || die2 "cannot compare the links with the graph"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      add_reason "$line"
    done <<EOF
$NODE_REASONS
EOF
  fi

  # -- informational: test files in none of the links and not in the links source ------------------------------------
  CANDIDATES="$(
    cd "$ROOT" || exit 0
    {
      if [ -d tests ]; then
        find tests -maxdepth 1 -type f -name '*.bats' -print
      fi
      find . -type d \( -name node_modules -o -name .git -o -name fixtures -o -name '.?*' \) -prune -o \
        -type f -name '*.test.js' -print | sed 's|^\./||'
    } | LC_ALL=C sort -u
  )"
  LINKED_FILES="$(jq -r '.generated_from.tests | keys[]' "$LINKS")"
  NUNLINKED=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if printf '%s\n' "$LINKED_FILES" | grep -F -x -q -- "$f"; then
      continue
    fi
    if grep -E -q '^[[:space:]]*(#|//)[[:space:]]*arch-node:' "$ROOT/$f" 2>/dev/null; then
      continue
    fi
    NUNLINKED=$((NUNLINKED + 1))
    if [ "$NUNLINKED" -le "$CAP" ]; then
      INFO="$INFO$(jq -nc --arg f "$f" '{type: "unlinked-new-test", file: $f}')"$'\n'
    fi
  done <<EOF
$CANDIDATES
EOF
  if [ "$NUNLINKED" -gt "$CAP" ]; then
    INFO="$INFO$(jq -nc --argjson n "$((NUNLINKED - CAP))" '{type: "unlinked-new-test-omitted", count: $n}')"$'\n'
    INFO_NOTE="$((NUNLINKED - CAP))"
  fi
fi

# ---- verdict and report ---------------------------------------------------------------------------------------------
if [ "$NREASONS" -eq 0 ]; then
  STATUS="fresh"
else
  STATUS="stale"
fi

REASONS_JSON="$(printf '%s' "$REASONS" | jq -sc '.')" || die2 "cannot build the report"
INFO_JSON="$(printf '%s' "$INFO" | jq -sc '.')" || die2 "cannot build the report"

if [ "$AS_JSON" -eq 1 ]; then
  jq -nc --arg s "$STATUS" --argjson r "$REASONS_JSON" --argjson i "$INFO_JSON" \
    '{status: $s, reasons: $r, informational: $i}' || die2 "cannot build the report"
else
  if [ "$STATUS" = "fresh" ]; then
    printf 'fresh: %s link(s) from %s test file(s) match the graph and the tests\n' "$NLINKS" "$NTESTS"
  else
    printf 'stale: %s reason(s)\n' "$NREASONS"
    printf '%s' "$REASONS_JSON" | jq -r '.[] |
      "  " + .type + ": " + (
        if .type == "no-links-file" then .links
        elif .type == "graph-changed" then "graph.json is \(.current) (recorded \(.recorded))"
        elif .type == "test-changed" then .file
        elif .type == "test-removed" then .file
        elif .type == "node-missing" then "\(.node_id) (\(.test_id))"
        elif .type == "node-superseded" then "\(.node_id) superseded by \(.superseded_by // "unknown") (\(.test_id))"
        else "" end)'
  fi
  if [ "$(printf '%s' "$INFO_JSON" | jq 'length')" -gt 0 ]; then
    printf 'informational:\n'
    printf '%s' "$INFO_JSON" | jq -r '.[] | select(.type == "unlinked-new-test") | "  unlinked-new-test: \(.file)"'
    if [ -n "$INFO_NOTE" ]; then
      printf '  (and %s more unlinked test file(s) not listed)\n' "$INFO_NOTE"
    fi
  fi
fi

[ "$STATUS" = "fresh" ] || exit 1
exit 0
