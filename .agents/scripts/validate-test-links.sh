#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/validate-test-links.sh - validate the derived test-to-architecture links file (epic E83, task E83_S02_T01)
#
# The single place that knows the shape of project/knowledge-graph/test-links.json. THIS HEADER IS THE SCHEMA'S SOURCE OF
# TRUTH: the field-by-field rules below are the rules the script enforces, and the feature documents link here rather than
# restate them. Decisions behind them: project/documentation/test-architecture-linking-spike.md (D2 link record, D4 node
# basis, D6 downstream changes).
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   validate-test-links.sh [--graph <graph.json>] [<links-file>]
#
#   <links-file>      the links file to check. When omitted, the resolved default
#                     <root>/<tree>/knowledge-graph/test-links.json is used, where <root> and <tree> come from
#                     scripts/resolve-root.sh (normally project/knowledge-graph/test-links.json).
#   --graph <file>    also check every link's node_id against the nodes of this graph.json (rule dangling-node).
#                     Also --graph=<file>. Without it, node ids are not checked.
#
# The script reads only its arguments and the resolved default above, writes no file, and compiles against macOS bash 3.2
# (it needs jq).
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   the file conforms; nothing is printed
#   1   a rule is violated; ONE line is printed on stdout naming the FIRST violated rule (rule order below), in the form
#       "<path> <problem> (rule <name>)", for example "links[3].node_id missing (rule field-missing)"
#   2   usage error (unknown flag, --graph without a value, more than one links file), or the links file or the --graph
#       file is missing, unreadable, not valid JSON, or not the expected top-level shape (the links file must be a
#       JSON object; the graph must carry a .nodes array); one line on stderr says which
#
# ---------------------------------------------------------------------------
# THE LINKS FILE
# ---------------------------------------------------------------------------
#   {"schema_version":1,
#    "generated_from":{"graph_sha256":"<64 lowercase hex, or the literal absent>",
#                      "tests":{"<file>":"<64 lowercase hex SHA-256 of that file's bytes>"}},
#    "links":[{"node_id":"E20_S09","test_id":"tests/x.bats::title","type":"integration","name":"title",
#              "file":"tests/x.bats","line":206}]}
#
# Keys not named here are tolerated at every level (a reader must ignore fields it does not use).
#
# ---------------------------------------------------------------------------
# ALLOWED `type` VOCABULARY (copied from the header of skills/j-test/scripts/discover-tests.sh; keep in step)
# ---------------------------------------------------------------------------
#   unit | integration | e2e | sast | vulnerability | performance | coverage | unknown
#
# ---------------------------------------------------------------------------
# RULES, in the order they are checked (the first one that fails is the one reported; one line per rule)
# ---------------------------------------------------------------------------
#   schema_version   top-level schema_version is the integer 1
#   hash-block       generated_from is an object; generated_from.graph_sha256 is 64 lowercase hex or the literal
#                    absent (never empty); generated_from.tests is an object whose every value is 64 lowercase hex
#   links            top-level links is an array (it may be empty)
#   -- then, for each link in index order, the fields in this order, then unhashed-file --
#   field-type       the link is a JSON object
#   field-missing    each of node_id, test_id, type, name, file, line is present
#   field-type       node_id is a non-empty string; test_id is a non-empty string (<file>::<name> test-level, <file>
#                    file-level); type is a string; name is a string; file is a non-empty string; line is an integer >= 1
#   type             type is one value of the vocabulary above
#   file-path        file is repo-root-relative POSIX: no leading ./ or /, no backslash, no empty segment, no .. segment
#   unhashed-file    file is a key of generated_from.tests
#   -- then, over the whole file --
#   duplicate        no two links share the same node_id AND test_id
#   orphan-hash      every key of generated_from.tests is the file of at least one link
#   -- last, only with --graph --
#   dangling-node    every link's node_id is the id of a node in the graph's .nodes; the line names the first dangling
#                    link by index and the total number of dangling links
# ---------------------------------------------------------------------------

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  printf 'usage: %s [--graph <graph.json>] [<links-file>]\n' "$(basename "$0")" >&2
}

die2() {
  printf '%s: %s\n' "$(basename "$0")" "$*" >&2
  exit 2
}

GRAPH=""
LINKS=""
HAVE_LINKS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --graph)
      [ $# -ge 2 ] || { usage; die2 "--graph needs a value"; }
      GRAPH="$2"
      shift 2
      ;;
    --graph=*)
      GRAPH="${1#--graph=}"
      [ -n "$GRAPH" ] || { usage; die2 "--graph needs a value"; }
      shift
      ;;
    -h|--help)
      usage
      exit 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      die2 "unknown option: $1"
      ;;
    *)
      [ "$HAVE_LINKS" -eq 0 ] || { usage; die2 "more than one links file given"; }
      LINKS="$1"
      HAVE_LINKS=1
      shift
      ;;
  esac
done

# Arguments after "--" are positional.
while [ $# -gt 0 ]; do
  [ "$HAVE_LINKS" -eq 0 ] || { usage; die2 "more than one links file given"; }
  LINKS="$1"
  HAVE_LINKS=1
  shift
done

command -v jq >/dev/null 2>&1 || die2 "jq is required"

if [ "$HAVE_LINKS" -eq 0 ]; then
  ROOT="$("$SELF_DIR/resolve-root.sh" root 2>/dev/null)" || die2 "cannot resolve the project root for the default links file"
  TREE="$("$SELF_DIR/resolve-root.sh" tree 2>/dev/null)" || die2 "cannot resolve the project tree for the default links file"
  LINKS="$ROOT/$TREE/knowledge-graph/test-links.json"
fi

[ -f "$LINKS" ] && [ -r "$LINKS" ] || die2 "links file missing or unreadable: $LINKS"
jq empty "$LINKS" >/dev/null 2>&1 || die2 "links file is not valid JSON: $LINKS"
jq -e 'type == "object"' "$LINKS" >/dev/null 2>&1 || die2 "links file top level is not a JSON object: $LINKS"

# Set of node ids from the graph, as a JSON object {"<id>":true}; null means "do not check node ids".
IDS="null"
if [ -n "$GRAPH" ]; then
  [ -f "$GRAPH" ] && [ -r "$GRAPH" ] || die2 "graph file missing or unreadable: $GRAPH"
  jq empty "$GRAPH" >/dev/null 2>&1 || die2 "graph file is not valid JSON: $GRAPH"
  jq -e '(type == "object") and (.nodes | type == "array")' "$GRAPH" >/dev/null 2>&1 \
    || die2 "graph file has no .nodes array: $GRAPH"
  IDS="$(jq -c '[.nodes[] | select(type == "object") | .id | select(type == "string") | {key: ., value: true}] | from_entries' "$GRAPH")" \
    || die2 "cannot read node ids from graph file: $GRAPH"
fi

# One jq program emits violations lazily, in the documented rule order, and `first` takes the first one. Because the
# generators are lazy, a later rule only runs when every earlier rule held, so it may rely on their guarantees (for
# example that every link is an object with valid fields).
read -r -d '' PROGRAM <<'JQ'
def hex64: type == "string" and test("^[0-9a-f]{64}$");
def isint: type == "number" and . == floor;
def badpath:
  type != "string" or . == "" or startswith("./") or startswith("/") or contains("\\")
  or (split("/") | any(. == "" or . == ".."));
def vocab: ["unit","integration","e2e","sast","vulnerability","performance","coverage","unknown"];

def link_violations($i; $tests):
  . as $l
  | "links[\($i)]" as $p
  | if ($l | type) != "object" then
      "\($p) is not an object (rule field-type)"
    else
      ( ["node_id","test_id","type","name","file","line"][] as $k
        | if ($l | has($k) | not) then
            "\($p).\($k) missing (rule field-missing)"
          else
            $l[$k] as $v
            | ( if $k == "node_id" or $k == "test_id" or $k == "file" then
                  if ($v | type) != "string" or $v == "" then
                    "\($p).\($k) must be a non-empty string (rule field-type)"
                  else empty end
                elif $k == "type" then
                  if ($v | type) != "string" then "\($p).type must be a string (rule field-type)"
                  elif (vocab | index($v)) == null then
                    "\($p).type \($v | tojson) is not in the vocabulary (rule type)"
                  else empty end
                elif $k == "name" then
                  if ($v | type) != "string" then "\($p).name must be a string (rule field-type)" else empty end
                else
                  if ($v | isint | not) or $v < 1 then "\($p).line must be an integer >= 1 (rule field-type)" else empty end
                end ),
              ( if $k == "file" and ($v | badpath) then
                  "\($p).file \($v | tojson) is not a normalised repo-relative path (rule file-path)"
                else empty end )
          end ),
      ( if ($tests | has($l.file) | not) then
          "\($p).file \($l.file | tojson) is not a key of generated_from.tests (rule unhashed-file)"
        else empty end )
    end;

def structure_violations:
  ( if (.schema_version | isint and . == 1) | not then
      "schema_version must be the integer 1 (rule schema_version)" else empty end ),
  ( if (.generated_from | type) != "object" then
      "generated_from must be an object (rule hash-block)"
    else
      ( if (.generated_from.graph_sha256 | (hex64 or . == "absent")) | not then
          "generated_from.graph_sha256 must be 64 lowercase hex or the literal absent (rule hash-block)" else empty end ),
      ( if (.generated_from.tests | type) != "object" then
          "generated_from.tests must be an object (rule hash-block)"
        else
          ( .generated_from.tests | to_entries[]
            | select(.value | hex64 | not)
            | "generated_from.tests[\(.key | tojson)] must be 64 lowercase hex (rule hash-block)" )
        end )
    end ),
  ( if (.links | type) != "array" then "links must be an array (rule links)" else empty end );

def per_link_violations:
  .generated_from.tests as $tests
  | ( .links | to_entries[] | .key as $i | .value | link_violations($i; $tests) );

def duplicate_violation:
  reduce (.links | to_entries[]) as $e ({seen: {}, hit: null};
      ([$e.value.node_id, $e.value.test_id] | tojson) as $k
      | if .hit == null and (.seen | has($k)) then .hit = {i: $e.key, first: .seen[$k]} else . end
      | if (.seen | has($k)) then . else .seen[$k] = $e.key end)
  | .hit
  | if . == null then empty
    else "links[\(.i)] duplicates links[\(.first)]: same node_id and test_id (rule duplicate)" end;

def orphan_violations:
  ([.links[].file] | unique) as $used
  | .generated_from.tests | keys_unsorted[]
  | . as $k
  | select(($used | index($k)) == null)
  | "generated_from.tests[\($k | tojson)] is the file of no link (rule orphan-hash)";

def dangling_violation:
  if $ids == null then empty
  else
    [.links | to_entries[] | select(($ids[.value.node_id]) | not)] as $d
    | if ($d | length) == 0 then empty
      else "links[\($d[0].key)].node_id \($d[0].value.node_id | tojson) is not a node of the graph (rule dangling-node; \($d | length) dangling link(s))" end
  end;

first(structure_violations, per_link_violations, duplicate_violation, orphan_violations, dangling_violation)
JQ

if ! OUT="$(jq -r --argjson ids "$IDS" "$PROGRAM" "$LINKS" 2>&1)"; then
  die2 "cannot evaluate the links file: $OUT"
fi

if [ -n "$OUT" ]; then
  printf '%s\n' "$OUT"
  exit 1
fi
exit 0

