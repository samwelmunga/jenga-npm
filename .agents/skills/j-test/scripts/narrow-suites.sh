#!/usr/bin/env bash
################################################################################
# narrow-suites.sh — rewrite a discovery's suite commands to run only the test
# files that matter (E72_S07_T02)
#
# THE PROBLEM THIS EXISTS FOR. map-scope.sh resolves changed files to suites AND
# to the individual test files that put each suite in scope, and its header says
# `mapped_tests` exists so a caller can "narrow a run when the runner takes file
# arguments". Nothing ever read it. discover-tests.sh emits one bats suite PER
# DIRECTORY, so this repository has a single `bats:tests` suite whose command is
# `bats tests/*.bats`; scope-test-gate.sh filtered the suite LIST to the mapped
# ids and then ran that whole-directory command unchanged. The measured result
# (E72_S07_T01, 2026-11-01): the E28_S19 change set narrowed from 261 mapped test
# files to 11 under a targeted scope map and still ran all 261 files / 5666
# cases. `scoped` and `full` were operationally identical, and one unrelated red
# assertion anywhere failed every story's closing gate.
#
# This script closes that gap. It is the ONE place that turns "these are the test
# files that matter" into "this is the command to run", for both narrowing
# (scoped) and exclusion (a suite that cannot pass right now).
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   narrow-suites.sh --root <dir> --suites <discovery.json>
#                    [--mapped-tests <map-scope.json>] [--report <file>]
#   narrow-suites.sh --help
#
#   --root <dir>          the project root. Suite commands run here, and it is
#                         where the settings files, the level-2 baseline template
#                         and tests/ are read from.
#   --suites <file>       discovery JSON (discover-tests.sh's contract), or - for
#                         stdin. Unknown keys are preserved untouched.
#   --mapped-tests <file> map-scope.sh's output. When given, each suite's
#                         candidate test files are exactly its `mapped_tests`
#                         entry: SCOPED mode. When omitted, the candidates are
#                         the files the suite's own `paths` globs match in the
#                         working tree: FULL mode.
#   --report <file>       write the report JSON here (see REPORT). Without it the
#                         report is discarded and only the transformed discovery
#                         is printed.
#
# Prints the transformed discovery JSON on stdout: same shape, same key order,
# same suites in the same order, with only `command` values rewritten.
#
# ---------------------------------------------------------------------------
# WHAT IT REWRITES, AND WHAT IT REFUSES TO
# ---------------------------------------------------------------------------
# A suite's command is rewritten only when it is a BARE `bats` INVOCATION: the
# first token is `bats` and the command contains no shell metacharacter
# (|&;<>()$`\"' or a newline). The rewrite is `bats` followed by the candidate
# files, each shell-quoted, in byte order.
#
# Any other command is left EXACTLY as it is and reported under
# `not_narrowable`. That is the safe direction and map-scope.sh's header already
# declares it valid ("a whole-suite run stays valid"): an npm script is opaque, a
# pytest or go invocation takes different file syntax, and guessing would run the
# wrong thing. Narrowing more ecosystems is a later, additive change — each needs
# its own verified argument form.
#
# THE npm TWIN. build-catalog.sh folds suites that would run the same thing, and
# for an npm suite it keys on the BODY of the npm script read from package.json.
# Here `scripts.test` is `bats tests/*.bats`, so `npm:test` currently folds onto
# `bats:tests`; its header warns that without this "a run-all would run the
# hour-long bats suite twice". Rewriting only the bats suite would therefore
# UN-FOLD them and run the catalog twice. So when an npm suite's script body is
# byte-equal to the pre-rewrite command of a bats suite in the same discovery,
# that npm suite's command is rewritten to the SAME narrowed string.
#
# That rewrite alone does NOT keep them folded: build-catalog.sh keys the npm
# suite on the package.json body, which this script never rewrites, so the keys
# diverge the moment the bats command moves. build-catalog.sh therefore folds a
# SECOND time on the final command (its DEDUPLICATION rule 5, added in the same
# fix round); the rewrite here is what makes those two commands identical so
# that pass can fold them. Both halves are required.
#
# AN npm SUITE THE TWIN RULE CANNOT COVER IS DISABLED WHILE AN EXCLUSION IS IN
# FORCE. When the body is not byte-equal to any narrowable command -- any of
# `bats --tap tests/*.bats`, `bats -r tests`, `npm run test:all`, a
# `scripts/test.sh` wrapper -- the command stays `npm test` and still expands to
# the whole test directory, INCLUDING the file an exclusion just removed, while
# this report and the gate both state that file was not verified. So whenever at
# least one marked file was actually dropped, such a suite has its command set to
# the empty string (not runnable: see EXCLUSION below for the same mechanism) and
# is named in the report under `disabled`. It is never a silent drop, and no
# coverage is lost where a narrowable twin exists, because that twin runs the
# same files. With no exclusion in force nothing is disabled: a pure scoped
# narrowing claims nothing about files an opaque suite might additionally run.
# Full reasoning, both failure variants and the options weighed:
# project/documentation/scope-gate-npm-fold-double-execution.md.
#
# ---------------------------------------------------------------------------
# EXCLUSION
# ---------------------------------------------------------------------------
# When `baseline-permissions.sh check --root <root>` reports the precondition
# unsatisfied, every file it marks (`baseline-permissions.sh list`) is removed
# from every candidate set, and each removal is recorded in the report with the
# file's own stated reason. When the precondition holds, nothing is excluded.
#
# A suite whose candidate set becomes EMPTY has nothing left to verify. Its
# command is NOT rewritten to a bare `bats` (which would run the whole suite
# again, or fail opaquely); the suite is reported with `"emptied": true` and its
# command is replaced by the empty string, which discover-tests.sh's contract
# already defines as not runnable and which build-catalog.sh therefore moves to
# `not_runnable` — never numbered, never executed, never counted as pass or
# fail. The CALLER is responsible for treating "everything was emptied" as
# "nothing was verified"; scope-test-gate.sh exits 3 in that case.
#
# ---------------------------------------------------------------------------
# IDENTITY PROPERTY (relied on by the full gate)
# ---------------------------------------------------------------------------
# In FULL mode with the precondition satisfied, nothing is excluded and every
# candidate set is exactly what the suite's glob already selected, so the
# transformation is a NO-OP: stdout is the input discovery, unchanged. A full
# gate therefore behaves precisely as it did before this script existed unless a
# marked file is actually in play. This bounds the blast radius of the change.
#
# ---------------------------------------------------------------------------
# REPORT (normative)
# ---------------------------------------------------------------------------
#   {"precondition":"satisfied"|"unsatisfied","precondition_reason":"..."|null,
#    "narrowed":[{"id":"bats:tests","available":261,"selected":11,"emptied":false}],
#    "excluded":[{"file":"tests/x.bats","reason":"...","suites":["bats:tests"]}],
#    "not_narrowable":["npm:test"],
#    "disabled":[{"id":"npm:test","reason":"..."}]}
#
#   narrowed         one entry per suite whose command was rewritten, suite order
#   excluded         one entry per marked file actually removed, byte-sorted
#   not_narrowable   ids whose OWN command is not a bare `bats` invocation and so
#                    could not be rebuilt from a file list, byte-sorted. An npm
#                    twin appears here even when the twin rule gave it a narrowed
#                    command, because its own command string (`npm test`) was
#                    never the thing narrowed; cross-read it with `disabled`.
#   disabled         ids whose command was set to "" because they could not
#                    honour an exclusion that fired (the npm case above), each
#                    with the reason, byte-sorted by id. [] whenever no exclusion
#                    fired. Never overlaps `narrowed`: a suite that was rewritten
#                    is not disabled.
#   Arrays are never null. Byte-identical for identical input.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0  success (including the no-op case)
#   2  usage error (unknown flag, missing argument, a --root that is not a
#      directory, an unreadable or invalid --suites / --mapped-tests)
#   3  infrastructure error: jq or git missing, baseline-permissions.sh missing
#      or failing for a reason other than "unsatisfied", a jq failure
#
# Executes no project code and runs no suite: it only reads JSON, lists files
# with git, and prints JSON. Writes only the --report file. macOS bash 3.2
# compatible; safe under `set -euo pipefail`.
################################################################################

set -euo pipefail

SCRIPT_NAME="narrow-suites.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

export LC_ALL=C
export GIT_OPTIONAL_LOCKS=0

GLOB_DEFS_FILE="$SCRIPT_DIR/lib/glob-defs.jq"
BASELINE="$SCRIPT_DIR/baseline-permissions.sh"

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }
die() { local code="$1"; shift; err "$*"; exit "$code"; }

usage() {
  cat <<'EOF'
Usage: narrow-suites.sh --root <dir> --suites <discovery.json|->
                        [--mapped-tests <map-scope.json>] [--report <file>]
       narrow-suites.sh --help

Rewrite each suite's command so it runs only the test files that matter, and
drop files that cannot pass while the level-2 baseline precondition is unmet.

  --root <dir>          project root the commands run in
  --suites <file|->     discovery JSON from discover-tests.sh
  --mapped-tests <file> map-scope.sh output; its mapped_tests becomes the
                        candidate set per suite (scoped). Omit for full mode,
                        where the candidates come from each suite's own paths.
  --report <file>       write the report JSON here
EOF
}

# ---- arguments ---------------------------------------------------------------
ROOT_ARG=""
SUITES_ARG=""
MAPPED_ARG=""
REPORT_ARG=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --root)
      [ "$#" -ge 2 ] || die 2 "--root needs a directory"
      [ -z "$ROOT_ARG" ] || die 2 "--root given more than once"
      ROOT_ARG="$2"; shift 2 ;;
    --suites)
      [ "$#" -ge 2 ] || die 2 "--suites needs a file"
      [ -z "$SUITES_ARG" ] || die 2 "--suites given more than once"
      SUITES_ARG="$2"; shift 2 ;;
    --mapped-tests)
      [ "$#" -ge 2 ] || die 2 "--mapped-tests needs a file"
      [ -z "$MAPPED_ARG" ] || die 2 "--mapped-tests given more than once"
      MAPPED_ARG="$2"; shift 2 ;;
    --report)
      [ "$#" -ge 2 ] || die 2 "--report needs a file"
      [ -z "$REPORT_ARG" ] || die 2 "--report given more than once"
      REPORT_ARG="$2"; shift 2 ;;
    *) die 2 "unknown option: $1" ;;
  esac
done

[ -n "$SUITES_ARG" ] || die 2 "--suites is required"

command -v jq >/dev/null 2>&1 || die 3 "jq is required but was not found on PATH"
[ -f "$GLOB_DEFS_FILE" ] || die 3 "the shared glob definitions are missing at $GLOB_DEFS_FILE"
[ -f "$BASELINE" ] || die 3 "baseline-permissions.sh is missing at $BASELINE"

if [ -n "$ROOT_ARG" ]; then
  [ -d "$ROOT_ARG" ] || die 2 "--root is not a directory: $ROOT_ARG"
  ROOT="$(cd -- "$ROOT_ARG" && pwd)"
else
  ROOT="$REPO_ROOT"
fi

TMP_DIR=""
cleanup() { [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/narrow-suites.XXXXXX")" \
  || die 3 "could not create a scratch directory under ${TMPDIR:-/tmp}"

# ---- inputs ------------------------------------------------------------------
SUITES_FILE="$TMP_DIR/discovery.json"
if [ "$SUITES_ARG" = "-" ]; then
  cat > "$SUITES_FILE" || die 2 "could not read the discovery JSON from stdin"
else
  # Readability, not regular-file-ness: a caller may legitimately hand us a pipe
  # or a process substitution (/dev/fd/NN), which `-f` rejects.
  [ -r "$SUITES_ARG" ] || die 2 "--suites is not readable: $SUITES_ARG"
  cat -- "$SUITES_ARG" > "$SUITES_FILE" || die 2 "could not read --suites: $SUITES_ARG"
fi
jq -e '.suites | type == "array"' "$SUITES_FILE" >/dev/null 2>&1 \
  || die 2 "--suites is not discovery JSON (no suites array)"

MAPPED_FILE="$TMP_DIR/mapped.json"
SCOPED=0
if [ -n "$MAPPED_ARG" ]; then
  [ -r "$MAPPED_ARG" ] || die 2 "--mapped-tests is not readable: $MAPPED_ARG"
  cat -- "$MAPPED_ARG" > "$MAPPED_FILE" || die 2 "could not read --mapped-tests: $MAPPED_ARG"
  jq -e '.mapped_tests | type == "object"' "$MAPPED_FILE" >/dev/null 2>&1 \
    || die 2 "--mapped-tests is not map-scope.sh output (no mapped_tests object)"
  SCOPED=1
else
  printf '{"mapped_tests":{}}\n' > "$MAPPED_FILE"
fi

# ---- the precondition and the marked files -----------------------------------
# baseline-permissions.sh is the sole decider; this script never re-derives it.
rc=0
bash "$BASELINE" check --root "$ROOT" || rc=$?
case "$rc" in
  0) PRECONDITION="satisfied" ;;
  1) PRECONDITION="unsatisfied" ;;
  *) die 3 "baseline-permissions.sh check failed with exit status $rc" ;;
esac

PRECONDITION_REASON=""
MARKED_FILE="$TMP_DIR/marked.json"
printf '[]\n' > "$MARKED_FILE"
if [ "$PRECONDITION" = "unsatisfied" ]; then
  PRECONDITION_REASON="$(bash "$BASELINE" reason --root "$ROOT")" \
    || die 3 "baseline-permissions.sh reason failed"
  rc=0
  bash "$BASELINE" list --root "$ROOT" > "$TMP_DIR/marked.tsv" || rc=$?
  [ "$rc" -eq 0 ] || die 3 "baseline-permissions.sh list failed with exit status $rc"
  # TAB-separated path/reason -> JSON array of {file, reason}.
  jq -Rn --rawfile tsv "$TMP_DIR/marked.tsv" '
    [ $tsv | split("\n")[] | select(length > 0)
      | (index("\t")) as $i
      | {file: .[0:$i], reason: .[$i+1:]} ]
  ' > "$MARKED_FILE" || die 3 "could not parse the marked-file list"
fi

# ---- candidate files for FULL mode -------------------------------------------
# Every tracked-or-untracked, non-ignored, existing file, so each suite's own
# `paths` globs can be expanded with the SHARED dialect (lib/glob-defs.jq) rather
# than a second implementation that could disagree with map-scope.sh.
CANDIDATES_FILE="$TMP_DIR/candidates.json"
printf '[]\n' > "$CANDIDATES_FILE"
if [ "$SCOPED" -eq 0 ]; then
  command -v git >/dev/null 2>&1 \
    || die 3 "git is required to expand suite paths in full mode but was not found on PATH"
  if [ "$(git -C "$ROOT" rev-parse --is-inside-work-tree 2>/dev/null || true)" = "true" ]; then
    git -C "$ROOT" -c core.quotepath=off ls-files -z --cached --others --exclude-standard \
      > "$TMP_DIR/candidates.z" 2>/dev/null || : > "$TMP_DIR/candidates.z"
  else
    : > "$TMP_DIR/candidates.z"
  fi
  # Keep only names that exist on disk (a deleted-but-cached path runs nothing).
  : > "$TMP_DIR/candidates.txt"
  while IFS= read -r -d '' name; do
    [ -e "$ROOT/$name" ] || continue
    printf '%s\n' "$name" >> "$TMP_DIR/candidates.txt"
  done < "$TMP_DIR/candidates.z"
  jq -Rn --rawfile t "$TMP_DIR/candidates.txt" \
    '[ $t | split("\n")[] | select(length > 0) ] | unique' \
    > "$CANDIDATES_FILE" || die 3 "could not build the candidate file list"
fi

# ---- npm script bodies -------------------------------------------------------
# build-catalog.sh folds an npm suite onto another suite by the BODY of its npm
# script, read from package.json with jq and never executed. The same lookup is
# needed here to recognise the twin, so it is built the same way: a map from the
# npm suite id (`npm:<key>`) to `.scripts[<key>]`. A missing, unreadable or
# unparseable package.json just means no twin (not an error), exactly as there.
NPM_BODIES_FILE="$TMP_DIR/npm-bodies.json"
printf '{}\n' > "$NPM_BODIES_FILE"
if [ -f "$ROOT/package.json" ]; then
  jq -n --slurpfile pkg "$ROOT/package.json" '
    ($pkg[0].scripts // {}) as $s
    | [ $s | to_entries[] | select((.value | type) == "string" and .value != "")
        | {key: ("npm:" + .key), value: .value} ] | from_entries
  ' > "$NPM_BODIES_FILE" 2>/dev/null || printf '{}\n' > "$NPM_BODIES_FILE"
fi

# ---- the transformation ------------------------------------------------------
# One jq pass computes, per suite: its candidate set, the marked files removed
# from it, and the narrowed command. Shell quoting of the file list is done in jq
# with @sh so a path containing a space or a quote can never split a command.
OUT_JSON="$TMP_DIR/out.json"
jq -c \
  --slurpfile mapped "$MAPPED_FILE" \
  --slurpfile marked "$MARKED_FILE" \
  --slurpfile candidates "$CANDIDATES_FILE" \
  --slurpfile npmbodies "$NPM_BODIES_FILE" \
  --argjson scoped "$SCOPED" \
  --arg precondition "$PRECONDITION" \
  --arg precondition_reason "$PRECONDITION_REASON" \
  "$(cat "$GLOB_DEFS_FILE")"'

# jq requires every `def` to come before the expression using it, so these sit
# first and read the --slurpfile / --argjson globals directly rather than any
# `as`-bound name (which would not be in scope inside a def declared earlier).

# A command is rewritable only when it is a bare `bats ...` invocation: the first
# token is `bats` and no shell metacharacter appears anywhere. A pipe, redirect,
# substitution or quote means the string is a small shell program rather than an
# argv this script may safely rebuild.
def bats_cmd:
  (. != null)
  and (type == "string")
  and test("\\A[[:space:]]*bats[[:space:]]")
  and ((test("[|&;<>()$`\\\\\"'"'"'\\n]")) | not);

# Candidate test files of one suite: its mapped_tests entry in scoped mode, else
# the working-tree files its own `paths` globs match, via the SHARED dialect.
def candidates_of($s):
  ( if $scoped == 1 then ((($mapped[0].mapped_tests // {})[$s.id]) // [])
    else
      ( ($s.paths // []) | map(select(type == "string")) ) as $globs
      | if ($globs | length) == 0 then []
        else any_re($globs) as $re
             | [ (($candidates[0]) // [])[] | select(matches($re)) ]
        end
    end
  ) | unique;

($marked[0] // [])                        as $markedList
| ([ $markedList[].file ])                as $markedFiles
| ($npmbodies[0] // {})                   as $npmBody
| .suites                                 as $suites

# Pre-rewrite bats commands, so an npm twin can be recognised by its script body.
| [ $suites[] | select((.command | bats_cmd)) | .command ] as $batsCommands

| [ $suites[]
    | . as $s
    | (candidates_of($s))                                   as $all
    | ( if $precondition == "unsatisfied"
        then [ $all[] | select(. as $f | ($markedFiles | index($f)) == null) ]
        else $all end )                                     as $kept
    | ( [ $all[] | select(. as $f | ($markedFiles | index($f)) != null) ] ) as $dropped
    # In scoped mode a suite with NO mapped_tests key was not selected by the
    # map at all. Leave it entirely alone: emptying it would disable a suite the
    # map never spoke about (the gate filters those out before calling us
    # anyway). Only a suite the map DID name may be narrowed or emptied.
    | ( ($scoped == 1) and (($mapped[0].mapped_tests // {}) | has($s.id)) ) as $inScope
    # Rewrite only when there is something to say: a scoped narrowing, or an
    # actual exclusion. Full mode with nothing excluded therefore leaves every
    # command byte-identical, which is the IDENTITY PROPERTY in the header.
    | ( ($s.command | bats_cmd)
        and ($inScope or (($dropped | length) > 0)) )       as $rewritable
    | {suite: $s, all: $all, kept: $kept, dropped: $dropped,
       rewritable: $rewritable,
       narrowable_command: ($s.command | bats_cmd)}
  ] as $plan

# A narrowed command per suite id, for the npm-twin pass to reuse.
| ( [ $plan[]
      | select(.rewritable)
      | {key: .suite.id,
         value: (if (.kept | length) == 0 then ""
                 else "bats " + (.kept | sort | map(@sh) | join(" ")) end),
         orig: .suite.command}
    ] ) as $rewrites
| ( $rewrites | map({key: .key, value: .value}) | from_entries ) as $byId
| ( $rewrites | map({key: .orig, value: .value}) | from_entries ) as $byOrigCommand

# Did an exclusion actually fire? Only then can an opaque suite contradict the
# report by running a file the report states was NOT verified. A pure scoped
# narrowing makes no such claim: an opaque suite that runs more than the
# narrowed set is wasteful, not wrong, so nothing is disabled for it.
| ( ([ $plan[] | select((.dropped | length) > 0) ] | length) > 0 ) as $exclusionFired

# AN UN-NARROWABLE npm SUITE IS NOT RUNNABLE WHILE AN EXCLUSION IS IN FORCE.
# npm test is opaque: the body lives in package.json, which this script will not
# rewrite. The twin rule below covers the case where that body is byte-equal to
# the command of a bats suite. When it is not -- bats --tap tests/*.bats,
# bats -r tests, npm run test:all, a scripts/test.sh wrapper -- the command
# stays npm test, which still expands to the WHOLE test directory INCLUDING the
# file the exclusion just removed, while the report and the gate key
# excluded_test_files both state that file was not verified. That is not a
# runtime cost, it is a false statement: the excluded file runs, fails for the
# very baseline reason it was excluded over, and the failure is attributed to a
# suite the reader was told had been narrowed.
# So the command is set to the empty string, which the discover-tests.sh
# contract already defines as not runnable and build-catalog.sh already routes
# to not_runnable -- never numbered, never executed, never counted as a pass or
# a fail. That is the same mechanism an emptied suite already uses, so it adds
# no new concept. The report names it under `disabled`, so it is never a silent
# drop, and no coverage is lost wherever a narrowable twin exists: that twin
# runs the same files. Where no twin exists and the npm suite was the only one a
# project has, the catalog ends up empty and the caller must report that nothing
# was verified (exit 3) -- the honest answer for an entry point that cannot
# honour a file-level exclusion, and never a pass.
| ( [ $plan[] | .suite as $s
      | select(($s.ecosystem == "npm")
               and ($s.command != "")
               and (($byId | has($s.id)) | not)
               and ((($npmBody | has($s.id))
                     and ($byOrigCommand | has($npmBody[$s.id]))) | not))
      | $s.id ] | sort ) as $opaqueNpm
| ( if $exclusionFired then $opaqueNpm else [] end ) as $disabledIds

| {
    discovery: (
      . as $doc
      | $doc | .suites |= [ .[]
          | . as $s
          | if ($byId | has($s.id)) then (.command = $byId[$s.id])
            # The npm twin: its declared command is opaque (`npm test`), but
            # build-catalog.sh folds it onto the bats suite by its package.json
            # script body. Keep them folded by giving it the same narrowed
            # string; otherwise a full run would execute the catalog twice.
            elif ($s.ecosystem == "npm")
                 and ($npmBody | has($s.id))
                 and ($byOrigCommand | has($npmBody[$s.id]))
              then (.command = $byOrigCommand[$npmBody[$s.id]])
            # An opaque npm suite no twin rule could narrow, while an exclusion
            # is in force: not runnable. See the $disabledIds block above.
            elif (($disabledIds | index($s.id)) != null) then (.command = "")
            else .
            end ]
    ),
    report: {
      precondition: $precondition,
      precondition_reason: (if $precondition_reason == "" then null else $precondition_reason end),
      narrowed: [ $plan[] | select(.rewritable)
                  | {id: .suite.id, available: (.all | length),
                     selected: (.kept | length), emptied: ((.kept | length) == 0)} ],
      excluded: [ $markedList[]
                  | . as $m
                  | ([ $plan[] | select(.dropped | index($m.file)) | .suite.id ] | sort) as $ids
                  | select(($ids | length) > 0)
                  | {file: $m.file, reason: $m.reason, suites: $ids} ]
                | sort_by(.file),
      not_narrowable: [ $plan[] | select(.narrowable_command | not) | .suite.id ] | sort,
      disabled: [ $disabledIds[]
                  | {id: .,
                     reason: ("an npm script is opaque and could not be narrowed, "
                              + "so it could run a file this run excluded")} ]
    }
  }
' "$SUITES_FILE" > "$OUT_JSON" || die 3 "the narrowing transformation failed"

if [ -n "$REPORT_ARG" ]; then
  jq -c '.report' "$OUT_JSON" > "$REPORT_ARG" \
    || die 3 "could not write the report to $REPORT_ARG"
fi
jq -c '.discovery' "$OUT_JSON" || die 3 "could not print the transformed discovery"
