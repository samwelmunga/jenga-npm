#!/usr/bin/env bash
################################################################################
# test-gate-scoped.sh — the scoped-run plan behind j.commit's option 1 (E72_S04_T02)
#
# "Test covering committed scope": turns the files a commit will record into a
# runnable plan, and runs NO suite. E72_S04_T03's runner executes the plan through
# run-suites.sh. This script only joins the outputs of the j-test scripts (it
# reimplements none of them):
#
#   discover-tests.sh   one discovery run -> <out-dir>/discovery.json (see below)
#   map-scope.sh        changed files -> mapped suites, mapped test files
#   build-catalog.sh    deduplicated runnable catalog (numbers each entry)
#
# They are located next to this skill through BASH_SOURCE (../../j-test/scripts),
# so the script works from a checkout and from node_modules/@jenga-ai/agent/.
#
# Usage:
#   test-gate-scoped.sh --out-dir <dir> [--root <dir>] [--source auto|staged|working]
#                       [--discovery-file <file>] [--map <file>]
#   test-gate-scoped.sh --help
#
#   --out-dir <dir>         required, an existing writable directory. The script
#                           writes only inside it (plus a private scratch directory
#                           under ${TMPDIR:-/tmp}, removed on every exit path):
#                           discovery.json (when it ran discovery), catalog.json,
#                           plan.json.
#   --root <dir>            project root; default: scripts/resolve-root.sh's root.
#   --source <s>            which changes to map. auto (default): `staged` when
#                           `git diff --cached --quiet` reports a non-empty index (that
#                           is exactly what `git commit` will record), else `working`
#                           (the skill is about to stage the work; also used outside a
#                           repository, where map-scope.sh then reports its own error).
#                           staged / working map to map-scope.sh --staged / --working.
#                           The value used is reported as `source` in the plan.
#   --discovery-file <f>    use this discovery JSON; discovery is not run at all.
#                           Without it, discover-tests.sh --root <root> runs exactly
#                           ONCE (25-35 s on a large tree) into <out-dir>/discovery.json
#                           and that one file feeds both map-scope.sh --suites and
#                           build-catalog.sh --discovery-file.
#   --map <file>            forwarded to map-scope.sh. Without it map-scope.sh resolves
#                           commit_scope_map_file itself (an absent key reads as
#                           templates/test-scope-map.json); that logic is not duplicated.
#
# Read-only on the repository: map-scope.sh never writes the index, and this
# script's own change count uses `git diff --cached` (no index write) or, for
# `working`, a throwaway index copy exactly as map-scope.sh does.
#
# ---------------------------------------------------------------------------
# PLAN JSON (normative; E72_S04_T03 reads it)
#   One compact JSON line on stdout, identical to <out-dir>/plan.json:
#
#   {"status":"mapped","source":"staged","changed_count":3,"selection":[1],
#    "suites":[{"n":1,"id":"bats:tests","name":"bats tests",
#               "command":"bats 'tests/a.bats' 'tests/b.bats'","narrowed":true,
#               "tests":["tests/a.bats","tests/b.bats"]}],
#    "unmapped_files":["README.md"],"warnings":[],
#    "message":"2 test file(s) in 1 suite(s) cover 2 of 3 changed file(s)",
#    "catalog_file":"<out-dir>/catalog.json"}
#
#   status          mapped  at least one runnable suite resolved
#                   zero    nothing to run: map-scope.sh exited 0 but mapped no suite
#                           (its warning `No tests found for the changed files` or
#                           `No changed files` is carried into `warnings`), or every
#                           mapped suite has no runnable catalog entry. `selection` is
#                           [] and `message` says plainly that no test covers the
#                           changed files (up to five `unmapped_files` listed). This
#                           is the never-a-vacuous-green guarantee: the caller offers
#                           the full suite or skip, it never reports a green run.
#                   error   map-scope.sh exited non-zero (the plan then also carries
#                           `"map_scope_exit":<code>` after `warnings`, and `message`
#                           is built from its first stderr line with every absolute
#                           path reduced to its last component), or discovery or
#                           catalog building failed. Callers treat it like `zero`.
#   source          staged | working: the resolved change source.
#   changed_count   unique changed files seen (0 when map-scope.sh failed).
#   selection       catalog numbers (the entries' ORIGINAL `n`, never renumbered),
#                   ascending; pass them to run-suites.sh --catalog <catalog_file>.
#   suites[]        one per selected catalog entry, ascending by n. `id`/`name` are
#                   the entry's own, `command` is what the derived catalog runs,
#                   `tests` the sorted unique union of the mapped test files that
#                   put the entry there. `narrowed` says whether `command` was
#                   narrowed to those files (below).
#   unmapped_files  map-scope.sh's list, sorted.
#   warnings        sorted unique union of map-scope.sh's warnings and this
#                   script's own; always an array.
#   catalog_file    <out-dir>/catalog.json (absolute), or null when no catalog could
#                   be built (an `error` plan whose cause precedes it).
#
# DERIVED CATALOG <out-dir>/catalog.json: a copy of build-catalog.sh's catalog whose
# `runnable` holds only the selected entries, each with its original `n` and, where
# narrowed, the narrowed `command`; `not_runnable` and `warnings` unchanged. Written
# for `zero` plans too (runnable []), whenever build-catalog.sh succeeded.
#
# MAPPING A MAPPED SUITE ID TO A CATALOG ENTRY. build-catalog.sh folds suites with the
# same effective command into one entry and lists the folded ones under `also`, so a
# mapped `bats:tests` may live in the entry `npm:test`. An id resolves to the runnable
# entry whose `id` equals it or whose `also[].id` contains it. Several mapped ids may
# land on one entry: one plan suite, tests unioned. A mapped id with no runnable
# entry is dropped with the warning `suite <id> has no runnable catalog entry; skipped`.
#
# NARROWING. A whole-suite "scoped" run is useless on a repository whose
# `bats tests/*.bats` takes over an hour, so, deterministically: when every mapped
# discovery suite landing on an entry has ecosystem `bats` and a command starting
# `bats `, the entry's command becomes `bats '<f1>' '<f2>' ...` over the union of
# mapped test files; likewise ecosystem `pytest` / command `pytest ` gives
# `pytest '<f1>' ...`. Every other ecosystem (npm, go, cargo, shellcheck, and any
# mixed group) runs the entry WHOLE, as its own command (an npm script is opaque, so
# over-selecting is the safe direction): `narrowed` is false and `tests` still lists
# the mapped files for information. Files are root-relative, single-quoted with an
# embedded ' written '\''; a name starting with `-` is written `./-name` in the
# command so the runner cannot read it as an option. A file name holding a control
# character (newline, tab, ...) is not narrowed: the whole suite runs, with a
# warning. Narrowing never adds a file map-scope.sh did not map.
#
# EXIT CODES
#   0  a plan was printed (read `status`, including zero and error)
#   1  jq or git missing (named on stderr), the j-test scripts or resolve-root.sh
#      not found, the root unresolvable, or plan.json could not be written
#   2  usage error: unknown flag, missing value, missing or non-directory or
#      non-writable --out-dir, bad --source, --root not a directory
#
# macOS bash 3.2 compatible; LC_ALL=C; deterministic output; runs no project code.
################################################################################

set -euo pipefail

SCRIPT_NAME="test-gate-scoped.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# skills/j-commit/scripts -> the checkout root, or node_modules/@jenga-ai/agent
# when installed as a dependency.
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
J_TEST_DIR="$SCRIPT_DIR/../../j-test/scripts"

# Locale must not influence sort order or tool output.
export LC_ALL=C
# Belt for the git calls that could otherwise do an opportunistic index refresh.
export GIT_OPTIONAL_LOCKS=0

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }
die() { local code="$1"; shift; err "$*"; exit "$code"; }

usage() {
  cat <<'EOF'
Usage: test-gate-scoped.sh --out-dir <dir> [--root <dir>] [--source auto|staged|working]
                           [--discovery-file <file>] [--map <file>]
       test-gate-scoped.sh --help

Turn the files a commit will record into a plan for the scoped test run: which
suites cover them, narrowed to the mapped test files for bats and pytest. Runs no
suite; prints the plan as one JSON line and writes it to <out-dir>/plan.json.

  --out-dir <dir>        existing directory the plan, catalog.json and (when it
                         ran) discovery.json are written to (required)
  --root <dir>           project root (default: resolved via scripts/resolve-root.sh)
  --source <s>           auto (default: staged when the index is non-empty, else
                         working), staged, or working
  --discovery-file <f>   use this discovery JSON; do not run discovery
  --map <file>           scope-map file, forwarded to map-scope.sh
  --help                 show this help and exit 0

Plan status: mapped, zero (nothing covers the change) or error. Exit: 0 whenever a
plan was printed, 1 jq/git missing or internal failure, 2 usage error.
EOF
}

# Mirrors the resolve_helper pattern of the j-test scripts: a checkout first, then
# the installed-package location.
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

# ---- scratch directory (stderr captures, change-count index copy) ------------------

TMPD=""
# shellcheck disable=SC2329  # invoked through the traps below
cleanup() {
  if [ -n "$TMPD" ]; then
    rm -rf -- "$TMPD"
    TMPD=""
  fi
}

# ---- arguments ----------------------------------------------------------------

OUT_DIR=""
ROOT_ARG=""
SOURCE_ARG="auto"
DISC_FILE_ARG=""
MAP_ARG=""
HAVE_DISC_FILE=0
HAVE_MAP=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --out-dir)
      [ "$#" -ge 2 ] || { err "--out-dir needs a directory argument"; usage >&2; exit 2; }
      OUT_DIR="$2"; shift 2 ;;
    --root)
      [ "$#" -ge 2 ] || { err "--root needs a directory argument"; usage >&2; exit 2; }
      ROOT_ARG="$2"; shift 2 ;;
    --source)
      [ "$#" -ge 2 ] || { err "--source needs a value"; usage >&2; exit 2; }
      SOURCE_ARG="$2"; shift 2 ;;
    --discovery-file)
      [ "$#" -ge 2 ] || { err "--discovery-file needs a file argument"; usage >&2; exit 2; }
      DISC_FILE_ARG="$2"; HAVE_DISC_FILE=1; shift 2 ;;
    --map)
      [ "$#" -ge 2 ] || { err "--map needs a file argument"; usage >&2; exit 2; }
      MAP_ARG="$2"; HAVE_MAP=1; shift 2 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

case "$SOURCE_ARG" in
  auto|staged|working) ;;
  *) err "--source must be auto, staged or working, got: $SOURCE_ARG"; usage >&2; exit 2 ;;
esac
[ -n "$OUT_DIR" ] || { err "--out-dir is required"; usage >&2; exit 2; }
[ -d "$OUT_DIR" ] || die 2 "--out-dir is not an existing directory: $OUT_DIR"
[ -w "$OUT_DIR" ] || die 2 "--out-dir is not writable: $OUT_DIR"
OUT_DIR="$(cd -- "$OUT_DIR" && pwd)"

command -v jq >/dev/null 2>&1 || die 1 "jq is required but was not found on PATH"
command -v git >/dev/null 2>&1 || die 1 "git is required but was not found on PATH"

for helper in discover-tests.sh build-catalog.sh map-scope.sh; do
  [ -f "$J_TEST_DIR/$helper" ] || die 1 "could not locate $helper next to the j-test skill ($J_TEST_DIR)"
done

RESOLVER="$(resolve_helper scripts/resolve-root.sh)" || RESOLVER=""
if [ -n "$ROOT_ARG" ]; then
  [ -d "$ROOT_ARG" ] || die 2 "--root is not a directory: $ROOT_ARG"
  ROOT="$(cd -- "$ROOT_ARG" && pwd)"
else
  [ -n "$RESOLVER" ] || die 1 "could not locate scripts/resolve-root.sh"
  ROOT="$(bash "$RESOLVER" root)" || die 1 "could not resolve the working root"
  [ -d "$ROOT" ] || die 1 "the resolved root is not a directory: $ROOT"
fi

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/test-gate-scoped.XXXXXX")" \
  || die 1 "could not create a scratch directory under ${TMPDIR:-/tmp}"
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

PLAN_FILE="$OUT_DIR/plan.json"
CATALOG_FILE="$OUT_DIR/catalog.json"
DISC_OUT="$OUT_DIR/discovery.json"
# Outputs of an earlier run must never be mistaken for this one's.
rm -f -- "$PLAN_FILE" "$CATALOG_FILE"

git_q() { git -C "$ROOT" -c core.quotepath=off "$@"; }

# ---- the plan --------------------------------------------------------------------

SOURCE=""

# publish_plan <compact plan json>: stdout and plan.json carry the same text.
publish_plan() {
  printf '%s\n' "$1" > "$PLAN_FILE" || die 1 "could not write $PLAN_FILE"
  printf '%s\n' "$1"
  exit 0
}

# first_line_of <file>: the first stderr line, with every absolute path reduced to
# its last component (no temp path in a message), at most 200 characters.
first_line_of() {
  local line
  line="$(sed -n '1p' "$1" 2>/dev/null || true)"
  line="$(printf '%s' "$line" \
    | sed -E "s#(^|[[:space:]'\"(:=])/([^[:space:]'\")]*/)*([^[:space:]/'\")]*)#\\1\\3#g" \
    | cut -c1-200)"
  printf '%s' "$line"
}

# emit_error <message> [<map_scope_exit>] [<changed_count>]
emit_error() {
  local msg="$1" mexit="${2:-}" count="${3:-0}" plan
  plan="$(jq -cn --arg source "$SOURCE" --argjson count "$count" --arg msg "$msg" --arg mexit "$mexit" '
    { status: "error", source: $source, changed_count: $count, selection: [], suites: [],
      unmapped_files: [], warnings: [] }
    + (if $mexit == "" then {} else { map_scope_exit: ($mexit | tonumber) } end)
    + { message: $msg, catalog_file: null }')" || die 1 "could not build the error plan"
  publish_plan "$plan"
}

# ---- change source -----------------------------------------------------------------

if [ "$SOURCE_ARG" = "auto" ]; then
  rc=0
  git_q diff --cached --quiet >/dev/null 2>&1 || rc=$?
  # 1 = the index differs from HEAD (non-empty); 0 = it does not; anything else
  # (not a repository, ...) falls back to working.
  if [ "$rc" -eq 1 ]; then SOURCE="staged"; else SOURCE="working"; fi
else
  SOURCE="$SOURCE_ARG"
fi

# ---- discovery (at most once) --------------------------------------------------------

if [ "$HAVE_DISC_FILE" -eq 1 ]; then
  DISC_FILE="$DISC_FILE_ARG"
else
  rc=0
  bash "$J_TEST_DIR/discover-tests.sh" --root "$ROOT" >"$DISC_OUT" 2>"$TMPD/discover.err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f -- "$DISC_OUT"
    detail="$(first_line_of "$TMPD/discover.err")"
    emit_error "test discovery failed (exit $rc)${detail:+: $detail}"
  fi
  DISC_FILE="$DISC_OUT"
fi

# ---- map-scope.sh --------------------------------------------------------------------

MAP_OUT="$TMPD/map.json"
rc=0
if [ "$SOURCE" = "staged" ]; then
  if [ "$HAVE_MAP" -eq 1 ]; then
    bash "$J_TEST_DIR/map-scope.sh" --root "$ROOT" --suites "$DISC_FILE" --map "$MAP_ARG" --staged \
      >"$MAP_OUT" 2>"$TMPD/map.err" || rc=$?
  else
    bash "$J_TEST_DIR/map-scope.sh" --root "$ROOT" --suites "$DISC_FILE" --staged \
      >"$MAP_OUT" 2>"$TMPD/map.err" || rc=$?
  fi
else
  if [ "$HAVE_MAP" -eq 1 ]; then
    bash "$J_TEST_DIR/map-scope.sh" --root "$ROOT" --suites "$DISC_FILE" --map "$MAP_ARG" --working \
      >"$MAP_OUT" 2>"$TMPD/map.err" || rc=$?
  else
    bash "$J_TEST_DIR/map-scope.sh" --root "$ROOT" --suites "$DISC_FILE" --working \
      >"$MAP_OUT" 2>"$TMPD/map.err" || rc=$?
  fi
fi
if [ "$rc" -ne 0 ]; then
  detail="$(first_line_of "$TMPD/map.err")"
  emit_error "map-scope.sh failed (exit $rc)${detail:+: $detail}" "$rc"
fi
if ! jq -e '(.mapped_suites | type) == "array" and (.warnings | type) == "array"' "$MAP_OUT" >/dev/null 2>&1; then
  emit_error "map-scope.sh printed output this script cannot read" "0"
fi

# ---- changed-file count ----------------------------------------------------------------
# map-scope.sh does not report how many files changed, only the unmapped ones. The
# same git calls it makes, so the count agrees with the mapping: --staged reads
# the index against HEAD; --working diffs a throwaway copy of the index (a plain
# working-tree `git diff` refreshes and rewrites .git/index in the user's repository).

diff_z() { git_q diff --name-only -z --no-renames --relative "$@" --; }

count_changed() {
  local empty real idx
  empty="$(git_q hash-object -t tree /dev/null)" || return 1
  if [ "$SOURCE" = "staged" ]; then
    if git_q rev-parse --verify --quiet 'HEAD^{commit}' >/dev/null 2>&1; then
      diff_z --cached HEAD
    else
      diff_z --cached "$empty"
    fi
    return
  fi
  idx="$TMPD/index"
  real="$(git_q rev-parse --git-path index)" || return 1
  case "$real" in /*) ;; *) real="$ROOT/$real" ;; esac
  [ ! -f "$real" ] || cp -p -- "$real" "$idx" || return 1
  if git_q rev-parse --verify --quiet 'HEAD^{commit}' >/dev/null 2>&1; then
    GIT_INDEX_FILE="$idx" diff_z HEAD
  else
    GIT_INDEX_FILE="$idx" diff_z --cached "$empty"
    GIT_INDEX_FILE="$idx" diff_z
  fi
  git_q ls-files -z --others --exclude-standard
}

COUNT_RAW="$TMPD/changed.z"
count=0
if count_changed >"$COUNT_RAW" 2>/dev/null; then
  # A name holding a newline cannot be carried and is skipped by map-scope.sh too.
  count="$(jq -Rs 'split("\u0000") | map(select(. != "" and (contains("\n") | not))) | unique | length' \
    <"$COUNT_RAW" 2>/dev/null)" || count=0
fi
case "$count" in ''|*[!0-9]*) count=0 ;; esac

# ---- catalog ---------------------------------------------------------------------------

CAT_FULL="$TMPD/catalog.full.json"
rc=0
bash "$J_TEST_DIR/build-catalog.sh" --root "$ROOT" --discovery-file "$DISC_FILE" \
  >"$CAT_FULL" 2>"$TMPD/catalog.err" || rc=$?
if [ "$rc" -ne 0 ]; then
  detail="$(first_line_of "$TMPD/catalog.err")"
  emit_error "building the test catalog failed (exit $rc)${detail:+: $detail}" "" "$count"
fi
if ! jq -e '(.runnable | type) == "array"' "$CAT_FULL" >/dev/null 2>&1; then
  emit_error "build-catalog.sh printed output this script cannot read" "" "$count"
fi

# ---- plan and derived catalog (one jq pass) -----------------------------------------------

jq_program() {
  cat <<'EOF'
def eco: if (.ecosystem | type) == "string" and .ecosystem != ""
         then .ecosystem else (.id | split(":") | .[0]) end;
def sq: "'" + gsub("'"; "'\\''") + "'";
def arg: (if startswith("-") then "./" + . else . end) | sq;
def ctl: test("[\u0001-\u001f\u007f]");

$cat[0] as $c | $map[0] as $m | $disc[0] as $d
| ($c.runnable // []) as $run
| ($m.mapped_suites // []) as $ids
| ($m.mapped_tests // {}) as $mt
| ($m.unmapped_files // []) as $unm
| ([ ($d.suites // [])[]
     | { key: .id, value: { eco: eco, command: (if (.command | type) == "string" then .command else "" end) } } ]
   | from_entries) as $dsu
| [ $ids[] as $id
    | { id: $id,
        entry: ([ $run[] | select(.id == $id or (any(.also[]?; .id == $id))) ] | first // null) } ] as $res
| [ $res[] | select(.entry == null) | .id ] as $lost
| [ $res[] | select(.entry != null) ] as $found
| ( $found | group_by(.entry.n)
    | map( . as $g
           | $g[0].entry as $e
           | [ $g[].id ] as $gids
           | ([ $gids[] as $i | ($mt[$i] // [])[] ] | unique) as $tests
           | ( if ($tests | length) == 0 then null
               elif ($gids | all(. as $i | ($dsu[$i] // {eco: "", command: ""}) as $s
                                 | $s.eco == "bats" and ($s.command | startswith("bats ")))) then "bats"
               elif ($gids | all(. as $i | ($dsu[$i] // {eco: "", command: ""}) as $s
                                 | $s.eco == "pytest" and ($s.command | startswith("pytest ")))) then "pytest"
               else null end ) as $tool
           | ($tool != null and ($tests | any(ctl))) as $blocked
           | ($tool != null and ($blocked | not)) as $narrow
           | { n: $e.n, id: $e.id, name: $e.name,
               command: (if $narrow then $tool + " " + ($tests | map(arg) | join(" ")) else $e.command end),
               narrowed: $narrow, tests: $tests,
               warn: (if $blocked
                      then ["suite \($e.id): a test file name contains a control character; the whole suite runs"]
                      else [] end) } ) ) as $built
| ($built | map(del(.warn))) as $suites
| ($suites | map(.n)) as $selection
| ($suites | map(.tests[]) | unique | length) as $nt
| ($unm | length) as $nu
| ([ $count - $nu, 0 ] | max) as $covered
| ( $lost | map("suite \(.) has no runnable catalog entry; skipped") ) as $lostw
| ( (($m.warnings // []) + $lostw + ($built | map(.warn[]))) | unique ) as $warnings
| (if ($suites | length) > 0 then "mapped" else "zero" end) as $status
| ( if $status == "mapped"
    then "\($nt) test file(s) in \($suites | length) suite(s) cover "
         + (if $nu == 0 then "\($count) changed file(s)" else "\($covered) of \($count) changed file(s)" end)
    elif $count == 0 then "No test covers the changed files (there are no changed files)"
    elif ($ids | length) > 0
    then "No test covers the changed files: the mapped suite(s) \($ids | join(", ")) have no runnable catalog entry"
    else "No test covers the changed files"
         + (if $nu > 0
            then ": " + ($unm[:5] | join(", ")) + (if $nu > 5 then " and \($nu - 5) more" else "" end)
            else "" end)
    end ) as $message
| { plan: { status: $status, source: $source, changed_count: $count, selection: $selection,
            suites: $suites, unmapped_files: $unm, warnings: $warnings, message: $message,
            catalog_file: $catalog_file },
    derived: ( $c | .runnable = [ $run[] | . as $r
                 | ($suites | map(select(.n == $r.n)) | first // null) as $s
                 | select($s != null) | .command = $s.command ] ) }
EOF
}

COMBINED="$TMPD/combined.json"
rc=0
jq -cn --slurpfile cat "$CAT_FULL" --slurpfile map "$MAP_OUT" --slurpfile disc "$DISC_FILE" \
  --arg source "$SOURCE" --argjson count "$count" --arg catalog_file "$CATALOG_FILE" \
  "$(jq_program)" >"$COMBINED" 2>"$TMPD/plan.err" || rc=$?
if [ "$rc" -ne 0 ]; then
  detail="$(first_line_of "$TMPD/plan.err")"
  emit_error "assembling the plan failed${detail:+: $detail}" "" "$count"
fi

jq -c '.derived' "$COMBINED" >"$CATALOG_FILE" || die 1 "could not write $CATALOG_FILE"
PLAN="$(jq -c '.plan' "$COMBINED")" || die 1 "could not read the assembled plan"
publish_plan "$PLAN"
