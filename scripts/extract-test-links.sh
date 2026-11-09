#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/extract-test-links.sh - extract test-to-architecture links from test annotations (epic E83, task E83_S02_T02)
#
# The ONLY code that reads the link source (`arch-node:` annotation lines inside test files) and the ONLY writer of the
# derived links file project/knowledge-graph/test-links.json. The shape of that file is owned by
# scripts/validate-test-links.sh (its header is the schema's source of truth); this script writes exactly that shape and
# runs that validator over its own output before anything is moved into place. Decisions behind the grammar, binding
# rules and scan set: project/documentation/test-architecture-linking-spike.md (D1 method, D2 grammar and record, D6
# downstream changes).
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   extract-test-links.sh [--root <dir>] [--out <file>] [--stdout]
#   extract-test-links.sh -h | --help       print this usage on stdout, exit 0
#
#   --root <dir>   the directory to scan; default: the project root from scripts/resolve-root.sh root. Also --root=<dir>.
#                  The project tree name (project or .project) used for the default paths comes from resolve-root.sh
#                  too (for an explicit --root it is resolved from inside that directory, ignoring JENGA_PROJECT_ROOT,
#                  and falls back to "project").
#   --out <file>   where to write the links file; default: <root>/<tree>/knowledge-graph/test-links.json (normally
#                  <root>/project/knowledge-graph/test-links.json). Also --out=<file>. The directory is created.
#   --stdout       print the JSON on stdout and write no file. Cannot be combined with --out.
#
# The graph whose hash is recorded is <root>/<tree>/knowledge-graph/graph.json. The script never modifies a test file or
# graph.json, and writes nothing but the output file (plus its temporary file and lock directory, both removed).
# Compatible with macOS bash 3.2 (no mapfile, no associative arrays, no case-modifying expansions); needs jq, awk, find,
# sort and `shasum -a 256` or `sha256sum`, whichever exists.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   ok: every annotation was valid; the links file was written (or printed with --stdout)
#   1   the extracted JSON failed scripts/validate-test-links.sh (the validator's one-line verdict is printed on stderr),
#       or the output could not be moved into place: the previous output file is left exactly as it was, and with
#       --stdout nothing is printed
#   2   usage error (unknown flag, flag without a value, --stdout together with --out, positional argument), the root is
#       missing or unreadable, a scanned test file is unreadable, a required tool (jq, a SHA-256 tool) is missing, or the
#       type vocabulary cannot be read from the validator header
#   3   ok with skipped entries: at least one malformed (or duplicate) annotation was reported on stderr as
#       "<file>:<line>: ..." and skipped; every valid link was still extracted and written
#
# ---------------------------------------------------------------------------
# THE LINK SOURCE: ANNOTATIONS (the only method; there is no manifest)
# ---------------------------------------------------------------------------
#   <leader> arch-node: <node-id>[,<node-id>...] type=<type>
#
#   <leader>   `#` (bats, shell) or `//` (Node), optionally indented. Either leader is accepted in any scanned file.
#   <node-id>  [A-Za-z0-9_.-]+ ; several ids are comma separated with no spaces.
#   type=      REQUIRED; one value of the allowed `type` vocabulary. That vocabulary is read at run time from the
#              "ALLOWED `type` VOCABULARY" block of scripts/validate-test-links.sh, so there is one list and no second table here.
#
# Binding. If the next non-blank line after an annotation is a test declaration (`@test "..."` at column 0 in a .bats
# file; `test('...'` or `test("..."` in a .js file, optionally indented) the link is TEST-LEVEL: name is the title, line is
# the declaration line, test_id is "<file>::<title>". Anything else (a header comment, code, end of file) makes it
# FILE-LEVEL: name is the file path, line is the annotation line, test_id is "<file>". Consecutive annotation lines above
# one declaration are allowed and each links its own ids. A title is "plain" when it is one quoted literal whose only
# backslash escapes are \\ and an escaped quote, followed by `{` (bats) or `,` (Node).
#
# Malformed, reported on stderr as "<file>:<line>: ..." with the annotation's line, skipped, exit 3 at the end:
#   - no `type=` token                               - an unknown token after the ids (extra key=value tokens included)
#   - an empty id list, an empty or invalid id        - a `type=` value outside the vocabulary
#   - a test declaration whose title is not a plain string literal (the annotation above it is skipped)
#   - a duplicate: the same (node id, test_id) pair already extracted from the same file (the first one is kept)
#
# ---------------------------------------------------------------------------
# SCAN SET
# ---------------------------------------------------------------------------
#   <root>/tests/*.bats (direct children only), plus every *.test.js under <root> excluding node_modules, .git, any
#   directory named fixtures, and every dot-directory. Symbolic links are not followed. Paths containing a newline are
#   not supported.
#
# ---------------------------------------------------------------------------
# OUTPUT (exactly the schema scripts/validate-test-links.sh enforces)
# ---------------------------------------------------------------------------
#   {"schema_version":1,
#    "generated_from":{"graph_sha256":"<sha256 of graph.json, or the literal absent>",
#                      "tests":{"<file>":"<sha256 of that file>"}},
#    "links":[{"node_id":...,"test_id":...,"type":...,"name":...,"file":...,"line":...}]}
#
#   - One record per (test, node) pair. generated_from.tests holds ONLY files with at least one valid link, keys sorted.
#   - links are sorted by node_id, file, line, test_id. Keys are in the fixed order above, there is no timestamp, and the
#     file ends with a newline, so two runs on unchanged input are byte-identical.
#   - A link naming a node id that is not in graph.json is reported on stderr as a warning and STILL written (only
#     checked when graph.json exists and has a .nodes array). `validate-test-links.sh --graph` treats it as a problem.
#   - The file is built in a temporary file in the output directory, validated, and only then moved over the output with
#     mv, all while holding scripts/with-lock.sh on the output file.
#   - A one-line summary goes to stderr; nothing is printed on stdout except with --stdout.
# ---------------------------------------------------------------------------

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$(basename "$0")"
VALIDATOR="$SELF_DIR/validate-test-links.sh"
US="$(printf '\037')"

usage() {
  printf 'usage: %s [--root <dir>] [--out <file>] [--stdout]\n' "$SELF" >&2
}

die2() {
  printf '%s: %s\n' "$SELF" "$*" >&2
  exit 2
}

ROOT=""
HAVE_ROOT=0
OUT=""
HAVE_OUT=0
TO_STDOUT=0

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
    --out)
      [ $# -ge 2 ] || { usage; die2 "--out needs a value"; }
      OUT="$2"; HAVE_OUT=1
      shift 2
      ;;
    --out=*)
      OUT="${1#--out=}"; HAVE_OUT=1
      [ -n "$OUT" ] || { usage; die2 "--out needs a value"; }
      shift
      ;;
    --stdout)
      TO_STDOUT=1
      shift
      ;;
    -h|--help)
      printf 'usage: %s [--root <dir>] [--out <file>] [--stdout]\n' "$SELF"
      exit 0
      ;;
    *)
      usage
      die2 "unknown argument: $1"
      ;;
  esac
done

[ -n "$ROOT" ] || [ "$HAVE_ROOT" -eq 0 ] || die2 "--root needs a value"
[ -n "$OUT" ] || [ "$HAVE_OUT" -eq 0 ] || die2 "--out needs a value"
if [ "$TO_STDOUT" -eq 1 ] && [ "$HAVE_OUT" -eq 1 ]; then
  usage
  die2 "--stdout cannot be combined with --out"
fi

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
if [ "$HAVE_OUT" -eq 0 ]; then
  OUT="$ROOT/$TREE/knowledge-graph/test-links.json"
fi

# ---- type vocabulary: one list, read from the validator header ------------------------------------------------------
VOCAB_LINE="$(grep -m1 -E '^#[[:space:]]+unit[[:space:]]*\|' "$VALIDATOR" 2>/dev/null)"
VOCAB="$(printf '%s' "$VOCAB_LINE" | sed -e 's/^#//' -e 's/[[:space:]]//g' -e 's/|/,/g')"
case "$VOCAB" in
  unit,*) ;;
  *) die2 "cannot read the type vocabulary from the header of $VALIDATOR" ;;
esac
VOCAB=",$VOCAB,"

# ---- scratch space --------------------------------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/extract-test-links.XXXXXX")" || die2 "cannot create a scratch directory"
TMPOUT=""
cleanup() {
  rm -rf "$WORK"
  if [ -n "$TMPOUT" ]; then rm -f "$TMPOUT"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---- scan set -------------------------------------------------------------------------------------------------------
LIST="$WORK/files"
(
  cd "$ROOT" || exit 1
  if [ -d tests ]; then
    find tests -maxdepth 1 -type f -name '*.bats' -print
  fi
  find . -type d \( -name node_modules -o -name .git -o -name fixtures -o -name '.?*' \) -prune -o \
    -type f -name '*.test.js' -print | sed 's|^\./||'
) | LC_ALL=C sort -u > "$LIST" || die2 "cannot list the test files under $ROOT"

# ---- parse every file with one awk pass ----------------------------------------------------------------------------
# Output records, fields separated by the US character (0x1f):
#   L <file> <line> <name> <node_id> <type> <test_id>     one valid link (one per node id)
#   E <file> <line> <message>                              one malformed or duplicate entry (skipped)
read -r -d '' AWK_PROG <<'AWK'
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }

function bad(ln, msg) {
  printf "E%s%s%s%d%s%s\n", US, cur, US, ln, US, msg
}

function emit(aln, ln, name, tid, ids, type,   n, parts, i, key) {
  n = split(ids, parts, ",")
  for (i = 1; i <= n; i++) {
    key = parts[i] SUBSEP tid
    if (key in seen) {
      bad(aln, "duplicate link (node " parts[i] ", test " tid ") already declared at line " seen[key] "; skipped")
      continue
    }
    seen[key] = ln
    printf "L%s%s%s%d%s%s%s%s%s%s%s%s\n", US, cur, US, ln, US, name, US, parts[i], US, type, US, tid
  }
}

# Sets ann_err (empty when valid), ann_ids and ann_type from the text after "arch-node:".
function parse_ann(rest,   toks, n, ids, k, i, t) {
  ann_err = ""; ann_ids = ""; ann_type = ""
  rest = trim(rest)
  if (rest == "") { ann_err = "empty id list"; return }
  n = split(rest, toks, /[ \t]+/)
  if (index(toks[1], "=") > 0) { ann_err = "empty id list (the ids must come before type=)"; return }
  k = split(toks[1], ids, ",")
  for (i = 1; i <= k; i++) {
    if (ids[i] == "") { ann_err = "empty node id in the id list"; return }
    if (ids[i] !~ /^[A-Za-z0-9_.-]+$/) { ann_err = "invalid node id \"" ids[i] "\""; return }
  }
  if (n < 2) { ann_err = "missing type= token"; return }
  if (toks[2] !~ /^type=/) { ann_err = "unknown token \"" toks[2] "\" (expected type=<type>)"; return }
  t = substr(toks[2], 6)
  if (t == "" || index(vocab, "," t ",") == 0) { ann_err = "unknown type \"" t "\""; return }
  if (n > 2) { ann_err = "unknown token \"" toks[3] "\" after type="; return }
  ann_ids = toks[1]
  ann_type = t
}

# Reads a plain string-literal title at the start of s; sets ttl and returns 1, else returns 0.
function parse_title(s,   q, i, c, nx, n, out, rest) {
  sub(/^[ \t]+/, "", s)
  q = substr(s, 1, 1)
  if (q != "\"" && q != "'") return 0
  out = ""; n = length(s); i = 2
  while (1) {
    if (i > n) return 0
    c = substr(s, i, 1)
    if (c == "\\") {
      nx = substr(s, i + 1, 1)
      if (nx == q || nx == "\\") { out = out nx; i += 2; continue }
      return 0
    }
    if (c == q) break
    out = out c
    i++
  }
  rest = substr(s, i + 1)
  if (is_bats) { if (rest !~ /^[ \t]*\{/) return 0 }
  else if (rest !~ /^[ \t]*,/) return 0
  ttl = out
  return 1
}

# Binds the pending annotations to the first non-blank, non-annotation line (or to end of file when ln == 0).
function bind(text, ln,   isdecl, rest, i) {
  isdecl = 0
  if (ln > 0) {
    if (is_bats) {
      if (text ~ /^@test[ \t]/) { isdecl = 1; rest = substr(text, 6) }
    } else if (text ~ /^[ \t]*test[ \t]*\(/) {
      isdecl = 1
      rest = text
      sub(/^[ \t]*test[ \t]*\(/, "", rest)
    }
  }
  if (!isdecl) {
    for (i = 1; i <= np; i++) emit(pl[i], pl[i], cur, cur, pi[i], pt[i])
  } else if (!parse_title(rest)) {
    for (i = 1; i <= np; i++) bad(pl[i], "the test declaration at line " ln " has a title that is not a plain string literal; link skipped")
  } else {
    for (i = 1; i <= np; i++) emit(pl[i], ln, ttl, cur "::" ttl, pi[i], pt[i])
  }
  np = 0
}

FNR == 1 {
  if (np > 0) bind("", 0)
  cur = FILENAME
  sub(/^\.\//, "", cur)
  is_bats = (cur ~ /\.bats$/)
  np = 0
}

{
  line = $0
  sub(/\r$/, "", line)
  if (line ~ /^[ \t]*(#|\/\/)[ \t]*arch-node:/) {
    match(line, /arch-node:/)
    parse_ann(substr(line, RSTART + RLENGTH))
    if (ann_err != "") {
      bad(FNR, "malformed arch-node annotation: " ann_err)
    } else {
      np++
      pl[np] = FNR; pi[np] = ann_ids; pt[np] = ann_type
    }
    next
  }
  if (line ~ /^[ \t]*$/) next
  if (np > 0) bind(line, FNR)
}

END { if (np > 0) bind("", 0) }
AWK

RAW="$WORK/raw"
: > "$RAW"
if [ -s "$LIST" ]; then
  FILES=()
  while IFS= read -r f; do
    [ -r "$ROOT/$f" ] || die2 "test file is not readable: $f"
    FILES[${#FILES[@]}]="./$f"
  done < "$LIST"
  (cd "$ROOT" && LC_ALL=C awk -v US="$US" -v vocab="$VOCAB" "$AWK_PROG" "${FILES[@]}") > "$RAW" \
    || die2 "awk failed while reading the test files"
fi

# ---- report skipped entries ----------------------------------------------------------------------------------------
SKIPPED="$(awk -F "$US" '$1 == "E" { n++ } END { print n + 0 }' "$RAW")"
awk -F "$US" '$1 == "E" { printf "%s: %s:%s: %s\n", self, $2, $3, $4 }' self="$SELF" "$RAW" >&2

# ---- hashes: graph, and every file with at least one valid link ----------------------------------------------------
if [ -f "$GRAPH" ]; then
  GSHA="$(sha256_of "$GRAPH")"
  [ -n "$GSHA" ] || die2 "cannot hash the graph file: $GRAPH"
else
  GSHA="absent"
fi

HASHES="$WORK/hashes"
: > "$HASHES"
LINKED="$WORK/linked"
awk -F "$US" '$1 == "L" { print $2 }' "$RAW" | LC_ALL=C sort -u > "$LINKED"
NFILES=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  h="$(sha256_of "$ROOT/$f")"
  [ -n "$h" ] || die2 "cannot hash the test file: $f"
  printf '%s%s%s\n' "$f" "$US" "$h" >> "$HASHES"
  NFILES=$((NFILES + 1))
done < "$LINKED"

# ---- build the JSON ------------------------------------------------------------------------------------------------
read -r -d '' JQ_PROG <<'JQ'
def fields: split("\u001f");
($hashes | split("\n") | map(select(length > 0) | fields | {key: .[0], value: .[1]}) | sort_by(.key) | from_entries) as $tests
| [inputs | fields | select(.[0] == "L")
   | {node_id: .[4], test_id: .[6], type: .[5], name: .[3], file: .[1], line: (.[2] | tonumber)}] as $links
| {schema_version: 1,
   generated_from: {graph_sha256: $g, tests: $tests},
   links: ($links | sort_by([.node_id, .file, .line, .test_id]))}
JQ

if [ "$TO_STDOUT" -eq 1 ]; then
  JSON="$WORK/test-links.json"
else
  OUT_DIR="$(dirname "$OUT")"
  mkdir -p "$OUT_DIR" 2>/dev/null || die2 "cannot create the output directory: $OUT_DIR"
  TMPOUT="$(mktemp "$OUT_DIR/.$(basename "$OUT").XXXXXX")" || die2 "cannot create a temporary file in $OUT_DIR"
  JSON="$TMPOUT"
fi

jq -n -R --arg g "$GSHA" --rawfile hashes "$HASHES" "$JQ_PROG" "$RAW" > "$JSON" \
  || { printf '%s: cannot build the links JSON\n' "$SELF" >&2; exit 1; }

NLINKS="$(jq '.links | length' "$JSON")"

# ---- warn about node ids missing from the graph (still written) ---------------------------------------------------
if [ -f "$GRAPH" ]; then
  if jq -e '(type == "object") and (.nodes | type == "array")' "$GRAPH" >/dev/null 2>&1; then
    jq -r --slurpfile g "$GRAPH" '
      ($g[0].nodes | map(select(type == "object") | .id)) as $ids
      | .links[] | .node_id as $n | select(($ids | any(. == $n)) | not)
      | "warning: \(.file):\(.line): node id \(.node_id) is not in graph.json (link still written)"' "$JSON" \
      | awk -v self="$SELF" '{ print self ": " $0 }' >&2
  else
    printf '%s: warning: %s has no .nodes array, node ids were not checked\n' "$SELF" "$GRAPH" >&2
  fi
fi

# ---- validate, then write atomically under the lock ----------------------------------------------------------------
if [ "$TO_STDOUT" -eq 1 ]; then
  VERDICT="$(bash "$VALIDATOR" "$JSON" 2>&1)" || {
    printf '%s: the extracted links failed validation: %s\n' "$SELF" "$VERDICT" >&2
    exit 1
  }
  cat "$JSON"
else
  bash "$SELF_DIR/with-lock.sh" "$OUT" -- bash -c '
    verdict="$(bash "$1" "$2" 2>&1)" || { printf "%s\n" "$verdict" >&2; exit 11; }
    mv -f "$2" "$3"
  ' _ "$VALIDATOR" "$TMPOUT" "$OUT"
  rc=$?
  if [ "$rc" -eq 11 ]; then
    printf '%s: the extracted links failed validation; %s left untouched\n' "$SELF" "$OUT" >&2
    exit 1
  elif [ "$rc" -ne 0 ]; then
    printf '%s: could not write %s (exit %s); the previous file is left in place\n' "$SELF" "$OUT" "$rc" >&2
    exit 1
  fi
  TMPOUT=""
fi

printf '%s: %s link(s) from %s test file(s)%s\n' "$SELF" "$NLINKS" "$NFILES" \
  "$([ "$SKIPPED" -gt 0 ] && printf ', %s malformed entr%s skipped' "$SKIPPED" "$([ "$SKIPPED" -eq 1 ] && printf y || printf ies)")" >&2

[ "$SKIPPED" -eq 0 ] || exit 3
exit 0
