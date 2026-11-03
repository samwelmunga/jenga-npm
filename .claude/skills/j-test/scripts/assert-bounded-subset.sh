#!/usr/bin/env bash
################################################################################
# assert-bounded-subset.sh — the ONE strict-subset guard for a bounded test
# selection (E72_S08_T06)
#
# THE PROPERTY THIS EXISTS FOR. Two separate places in this story need to prove
# that a selection of test files is provably SMALLER than what a full run would
# execute, and must refuse rather than run when it is not:
#   E72_S08_T06  the bounded default suite set a scoped gate falls to when the
#                changed files map to nothing. A configured set that names every
#                test file is a misconfiguration, not a floor.
#   E72_S08_T03  the standing invariant that a `scoped` selection is never the
#                whole runnable catalog, so a future coarse scope-map rule cannot
#                quietly restore the behaviour E72_S07 removed.
# Both are the SAME comparison, so it lives here once instead of twice. T06's
# resolver (resolve-default-suites.sh) calls it with the configured globs'
# expansion; T03 calls it with the union of map-scope.sh's `mapped_tests`.
#
# WHY THE COMPARISON IS ON TEST FILES, AND CANNOT BE ON ANYTHING ELSE. The two
# cheaper measures are both wrong here:
#   suite ids   discover-tests.sh emits one bats suite PER DIRECTORY, so this
#               repository's whole catalog is the single suite `bats:tests`. A
#               narrowed selection and a full run have an IDENTICAL suite-id set,
#               so set equality on ids is true for every selection, bounded or
#               not. That is precisely the defect E72_S07_T01 measured.
#   commands    a narrowed command (`bats tests/a.bats`) is not a member of the
#               full catalog's command set (`bats tests/*.bats`), so inclusion is
#               false for every narrowed selection, bounded or not.
# The test FILE set is the only quantity for which `smaller` means what the story
# means by it, and it is also the granularity narrow-suites.sh actually runs at.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   assert-bounded-subset.sh --root <dir> --suites <discovery.json|->
#                            --files <list|-> [--label <text>] [--json]
#   assert-bounded-subset.sh --help
#
#   --root <dir>     project root. Where the working tree is listed and where
#                    build-catalog.sh is pointed. Must be a directory.
#   --suites <f|->   discovery JSON (discover-tests.sh's contract), or - for
#                    stdin. The CALLER passes the discovery it already ran, so a
#                    gate keeps its single discovery pass; discovery is never run
#                    from here.
#   --files <f|->    the candidate selection: one root-relative path per line,
#                    blank lines ignored, `-` for stdin (not combinable with a
#                    `--suites -`). Duplicates and order do not matter.
#   --label <text>   what to quote back in a refusal as the offending value — the
#                    configured key's value for T06, the responsible scope-map
#                    rule for T03. Optional; omitted, refusals name the selection
#                    by its size alone.
#   --json           print the result object on stdout instead of the human line.
#                    Printed on EVERY outcome that reached a verdict (0, 5 and 6),
#                    so a caller can report the refusal as well as the pass.
#
# ---------------------------------------------------------------------------
# WHAT IT COMPUTES
# ---------------------------------------------------------------------------
#   available (F)  the full runnable test-file universe: every working-tree file
#                  that any RUNNABLE suite's `paths` globs match.
#                  * working-tree files are `git ls-files -z --cached --others
#                    --exclude-standard` filtered for existence on disk, the same
#                    list narrow-suites.sh expands suite paths against in full
#                    mode (a deleted-but-cached path runs nothing).
#                  * RUNNABLE is build-catalog.sh's own verdict, read from its
#                    catalog, never re-derived here: a runnable entry's id plus
#                    every id it folded into `also` (a folded suite's files really
#                    do run, under the survivor's command).
#                  * glob matching is lib/glob-defs.jq, the single definition of
#                    the dialect. A suite `paths` entry outside the dialect is
#                    ignored with a warning, as in map-scope.sh.
#   selected (S)   the candidate files that F covers.
#   uncovered      candidate files F does not cover: named by no runnable suite's
#                  paths, so nothing would run them. They are DROPPED with a
#                  warning rather than failing the call, matching map-scope.sh's
#                  `unmapped_files` treatment — but a selection left empty by the
#                  drop is exit 5, so they can never silently become a pass.
#
# The verdict is `S` non-empty AND `S` a STRICT subset of `F`.
#
# ---------------------------------------------------------------------------
# OUTPUT (--json; one compact object, key order fixed)
# ---------------------------------------------------------------------------
#   {"verdict":"strict-subset"|"empty"|"equals-catalog",
#    "label":"tests/a.bats,tests/b.bats"|null,
#    "selected":["tests/a.bats"],"selected_count":1,
#    "available_count":264,"uncovered":[],"warnings":[]}
#
#   selected        byte-sorted, unique; the files the caller may run
#   opaque_suites   RUNNABLE suite ids whose `paths` is empty after the dialect check —
#                   an npm script, shellcheck:all. See the limit below. [] when none
#   available_count the size of F. The LIST is deliberately not printed: on this
#                   repository it is hundreds of paths and no caller needs it.
#   verdict         mirrors the exit code, so a caller reading the object alone
#                   reaches the same conclusion as one reading the status
#
# THE LIMIT OF A FILE-LEVEL UNIVERSE. A runnable suite can decline to say which files
# it runs: discover-tests.sh gives `paths: []` to an npm suite (a script body is opaque)
# and to shellcheck:all (it checks sources, not test files). Those files are NOT in `F`,
# because there is no honest way to enumerate them — guessing would be the same error
# map-scope.sh refuses to make. Two consequences, both stated rather than hidden:
#   * `available_count` counts only ENUMERABLE files, so it under-reports a catalog that
#     contains such a suite. The ids are listed in `opaque_suites`, and the
#     equals-catalog message names them instead of claiming "the entire catalog".
#   * a selection covering every enumerable file is `equals-catalog` even though an
#     opaque suite would also have run. That direction is the safe one — a REFUSAL, never
#     a pass — which is why it is accepted rather than worked around. A project whose
#     ONLY runnable suite is opaque has `F` empty and gets exit 5 for any value: the
#     bounded default set is not expressible at file level there, and saying so is more
#     honest than selecting something arbitrary.
#
# THE SINGLE-SUITE / SINGLE-FILE PROJECT. A project whose entire runnable
# universe is one test file has S == F unavoidably, and this script reports
# `equals-catalog` for it. That is a FACT, not a policy: whether such a project
# is exempt is the CALLER's decision, and `available_count` is in the object so a
# caller can make it (E72_S08_T03 owns that decision for the scoped invariant;
# resolve-default-suites.sh refuses, because a "bounded default set" equal to
# everything is a contradiction whatever the catalog's size).
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0  strict subset: S is non-empty and strictly smaller than F
#   2  usage error (missing/unknown/repeated option, a --root that is not a
#      directory, an unreadable or invalid --suites / --files, both read from -)
#   3  infrastructure error: jq or git missing, build-catalog.sh missing or
#      failing, a jq failure
#   5  NOTHING TO RUN: S is empty, either because the candidate list was empty or
#      because every member was uncovered. Never a pass.
#   6  NOT A STRICT SUBSET: S covers the entire runnable universe
#
# Writes nothing anywhere but a scratch directory under ${TMPDIR:-/tmp}, removed
# on every exit path. Runs no suite and no project code. macOS bash 3.2
# compatible; safe under `set -euo pipefail`.
################################################################################

set -euo pipefail

SCRIPT_NAME="assert-bounded-subset.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# skills/j-test/scripts -> the checkout root, or node_modules/@jenga-ai/agent
# when installed as a dependency.
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

export LC_ALL=C
export GIT_OPTIONAL_LOCKS=0

GLOB_DEFS_FILE="$SCRIPT_DIR/lib/glob-defs.jq"

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }
die() { local code="$1"; shift; err "$*"; exit "$code"; }

usage() {
  cat <<'EOF'
Usage: assert-bounded-subset.sh --root <dir> --suites <discovery.json|->
                                --files <list|-> [--label <text>] [--json]
       assert-bounded-subset.sh --help

Assert that a candidate selection of test files is non-empty and a STRICT subset
of the full runnable test-file universe of the tree. Runs nothing and writes
nothing to the project.

  --root <dir>    project root
  --suites <f|->  discovery JSON from discover-tests.sh (- for stdin)
  --files <f|->   candidate selection, one root-relative path per line (- for stdin)
  --label <text>  the offending value to quote back in a refusal
  --json          print the result object instead of the human line
  --help          show this help and exit 0

Exit: 0 strict subset, 2 usage error, 3 infrastructure error,
      5 nothing to run (empty selection), 6 the selection is the whole catalog
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
FILES_ARG=""
LABEL=""
LABEL_GIVEN=0
AS_JSON=0

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
    --files)
      [ "$#" -ge 2 ] || die_usage "--files needs a file or -"
      [ -z "$FILES_ARG" ] || die_usage "--files given more than once"
      FILES_ARG="$2"; shift 2 ;;
    --label)
      [ "$#" -ge 2 ] || die_usage "--label needs a value"
      [ "$LABEL_GIVEN" -eq 0 ] || die_usage "--label given more than once"
      LABEL="$2"; LABEL_GIVEN=1; shift 2 ;;
    --json) AS_JSON=1; shift ;;
    *) die_usage "unknown option \"$1\"" ;;
  esac
done

[ -n "$SUITES_ARG" ] || die_usage "--suites is required"
[ -n "$FILES_ARG" ] || die_usage "--files is required"
[ "$SUITES_ARG" = "-" ] && [ "$FILES_ARG" = "-" ] \
  && die_usage "--suites and --files cannot both read from stdin"

command -v jq >/dev/null 2>&1 || die 3 "jq is required but was not found on PATH"
command -v git >/dev/null 2>&1 || die 3 "git is required but was not found on PATH"
[ -f "$GLOB_DEFS_FILE" ] || die 3 "the glob dialect definitions are missing: $GLOB_DEFS_FILE"

# ---- root --------------------------------------------------------------------
if [ -n "$ROOT_ARG" ]; then
  [ -d "$ROOT_ARG" ] || die_usage "--root is not a directory: $ROOT_ARG"
  ROOT="$(cd -- "$ROOT_ARG" && pwd)"
else
  RESOLVER=""
  for candidate in "$REPO_ROOT/scripts/resolve-root.sh" \
                   "$REPO_ROOT/node_modules/@jenga-ai/agent/scripts/resolve-root.sh"; do
    [ -f "$candidate" ] && { RESOLVER="$candidate"; break; }
  done
  [ -n "$RESOLVER" ] || die 3 "no --root given and scripts/resolve-root.sh was not found"
  ROOT="$(bash "$RESOLVER" 2>/dev/null || true)"
  [ -n "$ROOT" ] && [ -d "$ROOT" ] || die 3 "could not resolve the project root; pass --root"
fi

# ---- build-catalog.sh --------------------------------------------------------
BUILD_CATALOG=""
for candidate in "$SCRIPT_DIR/build-catalog.sh" \
                 "$REPO_ROOT/node_modules/@jenga-ai/agent/skills/j-test/scripts/build-catalog.sh"; do
  [ -f "$candidate" ] && { BUILD_CATALOG="$candidate"; break; }
done
[ -n "$BUILD_CATALOG" ] || die 3 "build-catalog.sh was not found next to $SCRIPT_NAME"

# ---- scratch -----------------------------------------------------------------
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jenga-bounded-subset.XXXXXX")" \
  || die 3 "could not create a scratch directory"
cleanup() { [ -n "${TMP_DIR:-}" ] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM HUP

# ---- inputs ------------------------------------------------------------------
DISCOVERY_FILE="$TMP_DIR/discovery.json"
if [ "$SUITES_ARG" = "-" ]; then
  cat > "$DISCOVERY_FILE" || die 2 "could not read the discovery JSON from stdin"
else
  [ -f "$SUITES_ARG" ] || die_usage "--suites is not a readable file: $SUITES_ARG"
  cp "$SUITES_ARG" "$DISCOVERY_FILE" || die 2 "could not read --suites: $SUITES_ARG"
fi
jq -e '.suites | type == "array"' "$DISCOVERY_FILE" >/dev/null 2>&1 \
  || die 2 "--suites is not discover-tests.sh output (no suites array)"

SEL_RAW="$TMP_DIR/selection.txt"
if [ "$FILES_ARG" = "-" ]; then
  cat > "$SEL_RAW" || die 2 "could not read the selection from stdin"
else
  [ -f "$FILES_ARG" ] || die_usage "--files is not a readable file: $FILES_ARG"
  cp "$FILES_ARG" "$SEL_RAW" || die 2 "could not read --files: $FILES_ARG"
fi

# ---- the catalog's runnability verdict ---------------------------------------
# build-catalog.sh decides what is runnable (an empty command is not, a folded
# suite runs under its survivor's command). That verdict is READ here, never
# recomputed: a second implementation of "runnable" is exactly the kind of drift
# this script exists to prevent elsewhere.
CATALOG_FILE="$TMP_DIR/catalog.json"
bash "$BUILD_CATALOG" --root "$ROOT" --discovery-file "$DISCOVERY_FILE" > "$CATALOG_FILE" 2>"$TMP_DIR/catalog.err" \
  || die 3 "build-catalog.sh failed: $(tr '\n' ' ' < "$TMP_DIR/catalog.err")"

RUNNABLE_IDS="$TMP_DIR/runnable-ids.json"
jq -c '[ (.runnable // [])[] | .id, ((.also // [])[] | .id) ] | unique' \
  "$CATALOG_FILE" > "$RUNNABLE_IDS" || die 3 "could not read the catalog's runnable suites"

# ---- working-tree candidate files --------------------------------------------
# The same list narrow-suites.sh expands suite paths against in full mode.
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

# ---- the comparison ----------------------------------------------------------
RESULT_FILE="$TMP_DIR/result.json"
jq -cn \
  --slurpfile discovery "$DISCOVERY_FILE" \
  --slurpfile runnable "$RUNNABLE_IDS" \
  --rawfile treeraw "$TMP_DIR/tree.txt" \
  --rawfile selraw "$SEL_RAW" \
  --arg label "$LABEL" \
  --argjson labelGiven "$LABEL_GIVEN" \
  "$(cat "$GLOB_DEFS_FILE")"'

  ($runnable[0] // [])                                              as $runnableIds
| [ $treeraw | split("\n")[] | select(length > 0) ] | unique        as $tree
| [ $selraw  | split("\n")[] | select(length > 0) ] | unique        as $selection
| ($discovery[0].suites // [])                                      as $suites

# Only suites the catalog calls runnable contribute to the universe.
| [ $suites[] | . as $s | select(($runnableIds | index($s.id)) != null) ] as $runnableSuites

# A paths entry outside the dialect is ignored with a warning (map-scope.sh does
# the same: over-selecting is the safe direction, a silent bad regex is not).
| [ $runnableSuites[]
    | .id as $sid
    | ((.paths // []) | map(select(type == "string")))[]
    | select((. | globprob) != null)
    | "suite \($sid): ignoring path glob \(. | tojson) (\(. | globprob))" ] | unique as $globWarnings

| [ $runnableSuites[] | ((.paths // []) | map(select(type == "string")))[]
    | select((. | globprob) == null) ] | unique                     as $globs

# A runnable suite whose `paths` is empty (an npm script, shellcheck:all) runs files
# NOBODY can enumerate, so it contributes nothing to the universe. Named, never guessed
# at — see THE LIMIT OF A FILE-LEVEL UNIVERSE in the header.
| [ $runnableSuites[]
    | . as $s1
    | select((($s1.paths // []) | map(select(type == "string"))
              | map(select((. | globprob) == null)) | length) == 0)
    | $s1.id ] | unique                                             as $opaque

| any_re($globs)                                                    as $re
| [ $tree[] | select(matches($re)) ]                                as $available
| [ $selection[] | . as $f | select(($available | index($f)) != null) ] as $selected
| [ $selection[] | . as $f | select(($available | index($f)) == null) ] as $uncovered

| (if ($uncovered | length) > 0
   then ["\($uncovered | length) selected path(s) are not run by any runnable suite and were dropped: \($uncovered | join(", "))"]
   else [] end)                                                     as $dropWarnings

| (if ($selected | length) == 0 then "empty"
   elif ($selected | length) >= ($available | length) then "equals-catalog"
   else "strict-subset" end)                                        as $verdict

| {verdict: $verdict,
   label: (if $labelGiven == 1 then $label else null end),
   selected: $selected,
   selected_count: ($selected | length),
   available_count: ($available | length),
   uncovered: $uncovered,
   opaque_suites: $opaque,
   warnings: ($globWarnings + $dropWarnings)}
' > "$RESULT_FILE" || die 3 "the subset comparison failed"

# Every read is guarded. An unguarded VAR="$(jq ...)" under `set -euo pipefail` aborts
# the script with JQ'S OWN status, and jq uses 5 for a system error — which would be
# indistinguishable from this script's documented exit 5 ("nothing to run"). The exit
# contract is what E72_S08_T02 branches on, so it may never be forged by a helper.
VERDICT="$(jq -r '.verdict' "$RESULT_FILE")" || die 3 "could not read the comparison result"
SEL_COUNT="$(jq -r '.selected_count' "$RESULT_FILE")" || die 3 "could not read the comparison result"
AVAIL_COUNT="$(jq -r '.available_count' "$RESULT_FILE")" || die 3 "could not read the comparison result"
OPAQUE="$(jq -r '.opaque_suites | join(", ")' "$RESULT_FILE")" || die 3 "could not read the comparison result"

# Warnings go to stderr on both output modes, so --json keeps stdout to the object.
jq -r '.warnings[]?' "$RESULT_FILE" | while IFS= read -r w; do
  [ -n "$w" ] && err "$w"
done

quoted_label() {
  if [ "$LABEL_GIVEN" -eq 1 ]; then printf ' (%s)' "$LABEL"; fi
}

emit() {
  if [ "$AS_JSON" -eq 1 ]; then
    cat "$RESULT_FILE"
  else
    printf '%s\n' "$1"
  fi
}

case "$VERDICT" in
  strict-subset)
    emit "bounded selection: $SEL_COUNT of $AVAIL_COUNT runnable test file(s) — a strict subset"
    exit 0 ;;
  empty)
    emit "bounded selection: nothing to run — 0 runnable test file(s) selected$(quoted_label); this is NOT a pass"
    exit 5 ;;
  equals-catalog)
    if [ -n "$OPAQUE" ]; then
      # Say what the universe did NOT include, rather than claiming "the entire
      # catalog" when suites whose files cannot be enumerated were never in it.
      emit "bounded selection: NOT a strict subset — the selection covers all $AVAIL_COUNT ENUMERABLE runnable test file(s)$(quoted_label); refusing to run it. These runnable suite(s) declare no test-file paths and are outside this comparison: $OPAQUE"
    else
      emit "bounded selection: NOT a strict subset — the selection covers all $AVAIL_COUNT runnable test file(s)$(quoted_label); refusing to run it"
    fi
    exit 6 ;;
esac

die 3 "unreachable verdict \"$VERDICT\""
