#!/usr/bin/env bash
################################################################################
# resolve-default-suites.sh — the bounded default suite set, resolved to a
# runnable selection (E72_S08_T06)
#
# WHAT THIS IS FOR. `E72_S07_T03` moved this project onto a 61-rule
# project/configs/test-scope-map.json and dropped the shipped default's
# `**/*.sh` -> `tests/**/*.bats` catch-all, so a change in an area no rule covers
# now maps to NOTHING. scope-test-gate.sh's `no-mapped-suites` branch answered
# that by running the entire catalog, which is the behaviour story E72_S08 exists
# to remove. `E72_S08_T02` removes it; this script supplies what replaces it: a
# BOUNDED DEFAULT SUITE SET, a small explicitly configured always-run set that is
# never the full catalog and never empty. It is the FLOOR beneath a scoped gate.
#
# IT IS NOT the answer for `no-commits`. That case keeps exit 3 ("nothing was
# verified"), per story E72_S08's amended decision 3: no change set could be
# derived at all there, so running a default set would report a pass for an id
# whose change is unknown. This script is only ever reached when there IS a change
# set and no rule covers it.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   resolve-default-suites.sh [--root <dir>] [--suites <discovery.json|->]
#                             [--config <file>] [--set <value>] [--json]
#   resolve-default-suites.sh --help
#
#   --root <dir>     project root: where the configs directory, the working tree
#                    and the suites live. Default: the root
#                    scripts/resolve-root.sh resolves.
#   --suites <f|->   discovery JSON (discover-tests.sh's contract), or - for
#                    stdin. GIVE IT: a real discovery walks the tree (25-35 s on
#                    this repository), and scope-test-gate.sh already runs
#                    discovery once and shares it across every step. Without it,
#                    discover-tests.sh --root <root> is run here.
#   --config <file>  read the configured value from this file instead of
#                    <configs dir>/test-config.json.
#   --set <value>    use this value instead of reading any config file. The test
#                    seam, and the way a caller can resolve a hypothetical set.
#   --json           print the result object (the default and only output form;
#                    accepted so callers can be explicit).
#
# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------
# The flat top-level string key `test_default_suite_set` of test-config.json. Its
# value is a COMMA-SEPARATED list of root-relative TEST-FILE globs in the shared
# dialect (lib/glob-defs.jq; documented in map-scope.sh's header):
#
#   "test_default_suite_set": "tests/smoke-test-skills.bats,tests/resolve-root.bats"
#
# WHY A FLAT COMMA-SEPARATED STRING AND NOT A JSON ARRAY. The config descriptor
# schema can only express an EDITABLE key as a scalar (lib/config/descriptors.js),
# lib/config/store.js's parseValue refuses any non-scalar type given on the
# command line, and tests/config-descriptors.bats pins every array/object key in
# every shipped descriptor as `editable: false`. An array value could therefore
# never be read or written through `jenga config get/set`, which this key must
# support. Comma is the separator `j.test` already uses for a selection
# (parse-selection.sh).
#
# WHY TEST-FILE GLOBS AND NOT SUITE IDS. discover-tests.sh emits one bats suite
# PER DIRECTORY, so this repository's entire catalog is the single suite
# `bats:tests` whose command is `bats tests/*.bats`. A set named at suite
# granularity would therefore BE the whole catalog and could not be bounded at
# all - the exact defect E72_S07_T01 measured. Test-file granularity is the only
# granularity at which "smaller than a full run" is expressible, and it is the
# granularity narrow-suites.sh runs at.
#
# ABSENT OR EMPTY IS NOT A SILENT ANYTHING. An absent key, a null, or an empty
# string means NOT CONFIGURED and is exit 4 with a message naming the key. It is
# deliberately not a fall-through to the full catalog (what this story removes)
# and not a pass (a gate that ran nothing is not a pass, E72_S06). The shipped
# descriptor default and the j.init scaffold template are both "", because naming
# this repository's own test files in a generic default would be wrong for every
# consumer and naming nothing honestly reports "you have not set this yet".
#
# ---------------------------------------------------------------------------
# WHAT IT DOES
# ---------------------------------------------------------------------------
#   1. Resolve the configured value (--set, else the key, else exit 4).
#   2. Split on commas and validate every glob with `globprob` from
#      lib/glob-defs.jq - the ONE definition of the dialect, never a second copy.
#      An invalid glob is exit 3, naming the key and the offending glob (the same
#      treatment map-scope.sh gives an invalid scope-map rule).
#   3. Expand the globs against the working tree (git ls-files --cached --others
#      --exclude-standard, filtered for existence).
#   4. Hand that expansion to assert-bounded-subset.sh, which computes the full
#      runnable test-file universe from the discovery and build-catalog.sh's own
#      runnability verdict, drops any selected path no runnable suite would run,
#      and asserts a non-empty STRICT subset. Its exit codes 5 and 6 are passed
#      through unchanged. That script is SHARED with E72_S08_T03's scoped
#      invariant rather than duplicated here.
#   5. Resolve each surviving file to the discovery suites whose `paths` match it,
#      keep only suites the catalog calls runnable, and collapse suites that share
#      an identical command onto the lowest id (map-scope.sh's own step 6).
#
# Discovery is run at most once, and not at all when --suites is given.
# build-catalog.sh is run (inside assert-bounded-subset.sh) to learn what is
# runnable; the catalog is never re-derived here.
#
# ---------------------------------------------------------------------------
# OUTPUT (normative): one compact JSON object and a trailing newline on stdout
# ---------------------------------------------------------------------------
#   {"mapped_suites":["bats:tests"],
#    "mapped_tests":{"bats:tests":["tests/resolve-root.bats"]},
#    "unmapped_files":[],"warnings":[],
#    "default_set":{"source":"config","value":"tests/resolve-root.bats",
#                   "globs":["tests/resolve-root.bats"],"globs_matching_nothing":[],
#                   "files_selected":1,"files_available":264}}
#
# THE FIRST FOUR KEYS ARE map-scope.sh's OUTPUT CONTRACT, deliberately and
# exactly. narrow-suites.sh --mapped-tests reads only `.mapped_tests`, so
# E72_S08_T02 can substitute this script for map-scope.sh in the existing
# discovery -> narrow -> build-catalog -> run-suites pipeline with no change to
# any other script. `default_set` is an ADDITIVE trailing key, which that
# contract permits ("consumers must ignore keys they do not know").
#   mapped_suites          suite ids, sorted, unique
#   mapped_tests           one key per mapped suite, value its sorted unique files
#   unmapped_files         selected paths no runnable suite runs (dropped, with a
#                          warning). A selection emptied by the drop is exit 5.
#   warnings               sorted, unique, always an array; includes a named entry
#                          for every configured glob that matched nothing
#   default_set.source     "config" or "override" (--set)
#   default_set.value      the configured value verbatim, so a refusal or a report
#                          can quote the offending setting
#   files_available        the size of the full runnable universe, so a reader can
#                          see how much smaller the floor is
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0  resolved: a non-empty selection, strictly smaller than the full catalog
#   2  usage error (missing/unknown/repeated option, a --root that is not a
#      directory, an unreadable --suites, both --config and --set)
#   3  infrastructure error, or an INVALID CONFIGURED VALUE: jq or git missing, a
#      helper script missing, discovery or the catalog failing, an unreadable or
#      malformed test-config.json, a glob outside the dialect, an empty element
#      between two commas. (map-scope.sh gives an invalid scope-map file the same
#      code: an explicit setting that is wrong is a misconfiguration, never a
#      silent fallback.)
#   4  NOT CONFIGURED: the key is absent, null or empty
#   5  NOTHING TO RUN: the value resolves to zero runnable test files. Never a
#      pass - that is the whole point of the key
#   6  NOT A STRICT SUBSET: the value resolves to the entire runnable catalog, so
#      it is a misconfiguration and is refused rather than run. The message names
#      the offending value
#
# Writes nothing anywhere but a scratch directory under ${TMPDIR:-/tmp}, removed
# on every exit path. Runs no suite and no project code. macOS bash 3.2
# compatible; safe under `set -euo pipefail`.
################################################################################

set -euo pipefail

SCRIPT_NAME="resolve-default-suites.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

export LC_ALL=C
export GIT_OPTIONAL_LOCKS=0

KEY="test_default_suite_set"
GLOB_DEFS_FILE="$SCRIPT_DIR/lib/glob-defs.jq"

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }
die() { local code="$1"; shift; err "$*"; exit "$code"; }

usage() {
  cat <<'EOF'
Usage: resolve-default-suites.sh [--root <dir>] [--suites <discovery.json|->]
                                 [--config <file>] [--set <value>] [--json]
       resolve-default-suites.sh --help

Resolve test-config.json's test_default_suite_set - the bounded default suite set
a scoped gate runs when the changed files map to nothing - into a runnable
selection, refusing an empty one and one that is the whole catalog.

  --root <dir>     project root (default: the resolved root)
  --suites <f|->   discovery JSON from discover-tests.sh; give it to avoid a
                   second tree walk
  --config <file>  read the value from this file instead of test-config.json
  --set <value>    use this value instead of reading a config file
  --json           print the result object (the only output form)
  --help           show this help and exit 0

Exit: 0 resolved, 2 usage error, 3 infrastructure error or an invalid value,
      4 not configured, 5 nothing to run, 6 the whole catalog (refused)
EOF
}

die_usage() {
  err "$1"
  usage >&2
  exit 2
}

# ---- arguments ---------------------------------------------------------------
ROOT_ARG=""
SUITES_ARG=""
CONFIG_ARG=""
CONFIG_GIVEN=0
SET_ARG=""
SET_GIVEN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --root)
      [ "$#" -ge 2 ] || die_usage "--root needs a directory"
      [ -z "$ROOT_ARG" ] || die_usage "--root given more than once"
      ROOT_ARG="$2"; shift 2 ;;
    --suites)
      [ "$#" -ge 2 ] || die_usage "--suites needs a file or -"
      [ -z "$SUITES_ARG" ] || die_usage "--suites given more than once"
      SUITES_ARG="$2"; shift 2 ;;
    --config)
      [ "$#" -ge 2 ] || die_usage "--config needs a file"
      [ "$CONFIG_GIVEN" -eq 0 ] || die_usage "--config given more than once"
      CONFIG_ARG="$2"; CONFIG_GIVEN=1; shift 2 ;;
    --set)
      [ "$#" -ge 2 ] || die_usage "--set needs a value"
      [ "$SET_GIVEN" -eq 0 ] || die_usage "--set given more than once"
      SET_ARG="$2"; SET_GIVEN=1; shift 2 ;;
    --json) shift ;;
    *) die_usage "unknown option \"$1\"" ;;
  esac
done

[ "$CONFIG_GIVEN" -eq 1 ] && [ "$SET_GIVEN" -eq 1 ] \
  && die_usage "--config and --set cannot be combined: --set replaces the config file"

command -v jq >/dev/null 2>&1 || die 3 "jq is required but was not found on PATH"
command -v git >/dev/null 2>&1 || die 3 "git is required but was not found on PATH"
[ -f "$GLOB_DEFS_FILE" ] || die 3 "the glob dialect definitions are missing: $GLOB_DEFS_FILE"

# ---- helper locations (a checkout first, then the installed package) ---------
resolve_helper() {
  local rel="$1" candidate
  for candidate in "$REPO_ROOT/$rel" "$REPO_ROOT/node_modules/@jenga-ai/agent/$rel"; do
    if [ -f "$candidate" ]; then printf '%s' "$candidate"; return 0; fi
  done
  return 1
}

DISCOVER="$SCRIPT_DIR/discover-tests.sh"
[ -f "$DISCOVER" ] || DISCOVER="$(resolve_helper skills/j-test/scripts/discover-tests.sh)" \
  || die 3 "discover-tests.sh was not found next to $SCRIPT_NAME"
ASSERT_SUBSET="$SCRIPT_DIR/assert-bounded-subset.sh"
[ -f "$ASSERT_SUBSET" ] || ASSERT_SUBSET="$(resolve_helper skills/j-test/scripts/assert-bounded-subset.sh)" \
  || die 3 "assert-bounded-subset.sh was not found next to $SCRIPT_NAME"

# ---- root --------------------------------------------------------------------
if [ -n "$ROOT_ARG" ]; then
  [ -d "$ROOT_ARG" ] || die_usage "--root is not a directory: $ROOT_ARG"
  ROOT="$(cd -- "$ROOT_ARG" && pwd)"
else
  RESOLVER="$(resolve_helper scripts/resolve-root.sh)" \
    || die 3 "no --root given and scripts/resolve-root.sh was not found"
  ROOT="$(bash "$RESOLVER" 2>/dev/null || true)"
  [ -n "$ROOT" ] && [ -d "$ROOT" ] || die 3 "could not resolve the project root; pass --root"
fi

# Prints the configs directory, or nothing. Same resolution as scope-policy.sh.
config_dir() {
  local root="$1" resolver dir="" rel=""
  if resolver="$(resolve_helper scripts/resolve-root.sh)"; then
    dir="$(JENGA_PROJECT_ROOT="$root" bash "$resolver" get configs 2>/dev/null)" || dir=""
    if [ -z "$dir" ]; then
      rel="$(cd -- "$root" && JENGA_PROJECT_ROOT="" bash "$resolver" --relative get configs 2>/dev/null)" || rel=""
      [ -z "$rel" ] || dir="$root/$rel"
    fi
  else
    dir="$root/project/configs"
  fi
  printf '%s' "$dir"
}

# ---- scratch -----------------------------------------------------------------
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jenga-default-suites.XXXXXX")" \
  || die 3 "could not create a scratch directory"
cleanup() { [ -n "${TMP_DIR:-}" ] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM HUP

# ---- the configured value ----------------------------------------------------
SOURCE="config"
if [ "$SET_GIVEN" -eq 1 ]; then
  SOURCE="override"
  VALUE="$SET_ARG"
else
  if [ "$CONFIG_GIVEN" -eq 1 ]; then
    CFG="$CONFIG_ARG"
  else
    CFG_DIR="$(config_dir "$ROOT")"
    CFG=""
    [ -z "$CFG_DIR" ] || CFG="$CFG_DIR/test-config.json"
  fi
  if [ -z "$CFG" ] || [ ! -f "$CFG" ]; then
    die 4 "$KEY is not configured (no test-config.json found); the bounded default suite set is empty, so nothing would be verified"
  fi
  [ -r "$CFG" ] || die 3 "$CFG is not readable"
  # One jq pass, tagged the way scope-policy.sh tags its own read so a value can
  # never be confused with a status: M malformed, T not a string, A absent, null
  # or empty, V<value> a real value. Every real value is V-prefixed, so the three
  # single-letter statuses are unambiguous.
  if ! RAW="$(jq -r --arg k "$KEY" '
        if type != "object" then "M"
        elif (has($k) | not) or (.[$k] == null) then "A"
        elif ((.[$k] | type) != "string") then "T"
        else "V" + .[$k] end
      ' "$CFG" 2>/dev/null)"; then
    die 3 "$CFG is not valid JSON; $KEY cannot be resolved"
  fi
  case "$RAW" in
    M) die 3 "$CFG does not hold a JSON object; $KEY cannot be resolved" ;;
    T) die 3 "$KEY in $CFG is not a string; it must be a comma-separated list of test-file globs" ;;
    A) VALUE="" ;;
    V*) VALUE="${RAW#V}" ;;
    *) die 3 "$KEY in $CFG could not be read" ;;
  esac
fi

if [ -z "$VALUE" ]; then
  die 4 "$KEY is not configured (absent or empty in ${CFG:-the given value}); set it with: jenga config set test-config.$KEY \"<glob>[,<glob>...]\""
fi

# ---- split and validate the globs -------------------------------------------
GLOBS_FILE="$TMP_DIR/globs.json"
if ! jq -cn --arg v "$VALUE" "$(cat "$GLOB_DEFS_FILE")"'
    [ $v | split(",")[] ]                                  as $parts
  | [ $parts[] | select(. == "") ] | length                 as $empties
  | [ $parts[] | select(. != "")
      | {glob: ., problem: (. | globprob)} ]                as $checked
  | {parts: $parts, empties: $empties, checked: $checked}
  ' > "$GLOBS_FILE" 2>/dev/null; then
  die 3 "$KEY could not be parsed: $VALUE"
fi

# Guarded, like every read below it: an unguarded jq substitution under `set -euo
# pipefail` aborts with JQ's own status, and jq uses 5 for a system error — which would
# be indistinguishable from this script's documented exit 5 ("nothing to run"). The exit
# contract is what E72_S08_T02 branches on, so a helper may never forge it.
EMPTIES="$(jq -r '.empties' "$GLOBS_FILE")" || die 3 "$KEY could not be validated"
if [ "$EMPTIES" != "0" ]; then
  die 3 "$KEY has an empty element (a leading, trailing or doubled comma): $VALUE"
fi
BAD="$(jq -r '[.checked[] | select(.problem != null) | .problem] | join("; ")' "$GLOBS_FILE")" \
  || die 3 "$KEY could not be validated"
if [ -n "$BAD" ]; then
  die 3 "$KEY is not a valid list of test-file globs: $BAD"
fi

GLOB_LIST="$TMP_DIR/glob-list.json"
jq -c '[.checked[].glob] | unique' "$GLOBS_FILE" > "$GLOB_LIST" \
  || die 3 "could not read the validated globs"

# ---- working-tree files ------------------------------------------------------
if [ "$(git -C "$ROOT" rev-parse --is-inside-work-tree 2>/dev/null || true)" = "true" ]; then
  git -C "$ROOT" -c core.quotepath=off ls-files -z --cached --others --exclude-standard \
    > "$TMP_DIR/tree.z" 2>/dev/null || : > "$TMP_DIR/tree.z"
else
  : > "$TMP_DIR/tree.z"
fi
# ONE output redirect for the whole loop, never `>> file` per iteration: the
# append-per-line form reopens the file 6500 times and measured 76 s wall on this
# repository against 0.12 s for this form (0.24 s of CPU either way — it is
# filesystem, not compute).
while IFS= read -r -d '' name; do
  if [ -e "$ROOT/$name" ]; then printf '%s\n' "$name"; fi
done < "$TMP_DIR/tree.z" > "$TMP_DIR/tree.txt"

# ---- expand the globs --------------------------------------------------------
EXPANSION="$TMP_DIR/expansion.json"
jq -cn \
  --slurpfile globs "$GLOB_LIST" \
  --rawfile treeraw "$TMP_DIR/tree.txt" \
  "$(cat "$GLOB_DEFS_FILE")"'
    ($globs[0] // [])                                        as $gs
  | [ $treeraw | split("\n")[] | select(length > 0) ] | unique as $tree
  | [ $gs[]
      | . as $g
      | any_re([$g]) as $re
      | {glob: $g, files: [ $tree[] | select(matches($re)) ]} ] as $per
  | {files: ([ $per[].files[] ] | unique),
     empty_globs: [ $per[] | select((.files | length) == 0) | .glob ]}
  ' > "$EXPANSION" || die 3 "could not expand the configured globs"

jq -r '.files[]' "$EXPANSION" > "$TMP_DIR/selection.txt" \
  || die 3 "could not read the expanded selection"

EMPTY_GLOBS="$(jq -r '.empty_globs | join(", ")' "$EXPANSION")" \
  || die 3 "could not read the glob expansion"
[ -z "$EMPTY_GLOBS" ] || err "$KEY: these globs match no file in the working tree: $EMPTY_GLOBS"

# ---- discovery ---------------------------------------------------------------
DISCOVERY_FILE="$TMP_DIR/discovery.json"
if [ -n "$SUITES_ARG" ]; then
  if [ "$SUITES_ARG" = "-" ]; then
    cat > "$DISCOVERY_FILE" || die 2 "could not read the discovery JSON from stdin"
  else
    [ -f "$SUITES_ARG" ] || die_usage "--suites is not a readable file: $SUITES_ARG"
    cp "$SUITES_ARG" "$DISCOVERY_FILE" || die 2 "could not read --suites: $SUITES_ARG"
  fi
  jq -e '.suites | type == "array"' "$DISCOVERY_FILE" >/dev/null 2>&1 \
    || die 2 "--suites is not discover-tests.sh output (no suites array)"
else
  bash "$DISCOVER" --root "$ROOT" > "$DISCOVERY_FILE" 2>"$TMP_DIR/discover.err" \
    || die 3 "discover-tests.sh failed: $(tr '\n' ' ' < "$TMP_DIR/discover.err")"
fi

# ---- the shared strict-subset guard -----------------------------------------
# Exit 5 (nothing to run) and 6 (the whole catalog) are the guard's verdicts and
# are passed through unchanged. This is the ONE implementation of the property;
# E72_S08_T03's scoped invariant calls the same script with its own --files.
SUBSET_JSON="$TMP_DIR/subset.json"
set +e
bash "$ASSERT_SUBSET" --root "$ROOT" --suites "$DISCOVERY_FILE" \
  --files "$TMP_DIR/selection.txt" --label "$KEY=\"$VALUE\"" --json > "$SUBSET_JSON" 2>"$TMP_DIR/subset.err"
SUBSET_STATUS=$?
set -e
[ -s "$TMP_DIR/subset.err" ] && cat "$TMP_DIR/subset.err" >&2

case "$SUBSET_STATUS" in
  0) : ;;
  5) err "the bounded default suite set resolves to NO runnable test file, so nothing would be verified: $KEY=\"$VALUE\""
     exit 5 ;;
  6) err "the bounded default suite set is the ENTIRE runnable catalog (every enumerable runnable test file; a runnable suite that declares no paths is outside the comparison, see assert-bounded-subset.sh's THE LIMIT OF A FILE-LEVEL UNIVERSE), which is a misconfiguration, not a floor: $KEY=\"$VALUE\""
     exit 6 ;;
  *) die 3 "assert-bounded-subset.sh failed with status $SUBSET_STATUS" ;;
esac

# ---- resolve the surviving files to runnable suites --------------------------
CATALOG_FILE="$TMP_DIR/catalog.json"
BUILD_CATALOG="$SCRIPT_DIR/build-catalog.sh"
[ -f "$BUILD_CATALOG" ] || BUILD_CATALOG="$(resolve_helper skills/j-test/scripts/build-catalog.sh)" \
  || die 3 "build-catalog.sh was not found next to $SCRIPT_NAME"
bash "$BUILD_CATALOG" --root "$ROOT" --discovery-file "$DISCOVERY_FILE" > "$CATALOG_FILE" 2>"$TMP_DIR/catalog.err" \
  || die 3 "build-catalog.sh failed: $(tr '\n' ' ' < "$TMP_DIR/catalog.err")"

jq -c \
  --slurpfile discovery "$DISCOVERY_FILE" \
  --slurpfile catalog "$CATALOG_FILE" \
  --slurpfile subset "$SUBSET_JSON" \
  --slurpfile globs "$GLOB_LIST" \
  --slurpfile expansion "$EXPANSION" \
  --arg value "$VALUE" \
  --arg source "$SOURCE" \
  --arg key "$KEY" \
  -n "$(cat "$GLOB_DEFS_FILE")"'
    ($discovery[0].suites // [])                                          as $suites
  | ($catalog[0] // {})                                                   as $cat
  | ($subset[0] // {})                                                    as $sub
  | ($sub.selected // [])                                                 as $selected
  | [ ($cat.runnable // [])[] | .id, ((.also // [])[] | .id) ] | unique   as $runnableIds

  # A file resolves to every RUNNABLE suite whose own paths match it. There is no
  # extension fallback here (map-scope.sh has one for opaque npm suites, whose
  # purpose is to over-select for a CHANGED source file); the floor names test
  # files directly, so a file no suite runs is reported, not guessed at.
  | [ $suites[]
      | . as $s0
      | select(($runnableIds | index($s0.id)) != null)
      | . as $s
      | ((.paths // []) | map(select(type == "string"))
         | map(select((. | globprob) == null)))                           as $gs
      | any_re($gs)                                                       as $re
      | {id: $s.id, command: ($s.command // ""),
         files: [ $selected[] | select(matches($re)) ]}
      | select((.files | length) > 0) ]                                   as $hits

  # map-scope.sh step 6: suites sharing an identical command collapse onto the
  # lowest id, which takes the union of their files. Without it a run could
  # execute the same command twice (discovery reports config:bats:integration
  # with bats:tests command).
  | [ $hits | group_by(.command)[]
      | (. | sort_by(.id)) as $g
      | {id: $g[0].id, files: ([ $g[].files[] ] | unique)} ]               as $collapsed

  | ($collapsed | sort_by(.id))                                           as $final
  | {mapped_suites: [ $final[].id ],
     mapped_tests: ([ $final[] | {key: .id, value: .files} ] | from_entries),
     unmapped_files: ($sub.uncovered // []),
     warnings: (((($sub.warnings // []))
                 + [ ($expansion[0].empty_globs // [])[]
                     | "\($key): glob \(. | tojson) matches no file in the working tree" ])
                | unique),
     default_set: {source: $source, value: $value,
                   globs: ($globs[0] // []),
                   globs_matching_nothing: ($expansion[0].empty_globs // []),
                   files_selected: ($selected | length),
                   files_available: ($sub.available_count // 0)}}
  ' || die 3 "could not build the resolver output"
