#!/usr/bin/env bash
################################################################################
# scope-test-gate.sh — the policy-driven test gate for a task, story or epic
# (E72_S06_T03)
#
# The one script the tester agent calls before it closes a scope (and the scrum
# master asks for before it closes an epic). It resolves the configured test-run
# mode of the scope, runs what that mode asks for, and reports through its exit
# code. It decides nothing about board status: it never writes a status, never
# edits a file under the board, and never writes anywhere in the project. Whether
# a failing gate means `Failed` (task, story) or an epic that stays `In Progress`
# is the caller's rule. Its one write is a scratch directory under ${TMPDIR:-/tmp},
# removed on every exit path.
#
# Usage:
#   scope-test-gate.sh --scope <task|story|epic> --id <E##[_S##[_T##]]>
#                      [--range <a..b> | --rev <commit>] [--root <dir>]
#                      [--config <file>] [--json]
#   scope-test-gate.sh --help
#
#   --scope <s>      task, story or epic.
#   --id <id>        the item: E##_S##_T## for a task, E##_S## for a story, E## for
#                    an epic. A malformed id for the scope is a usage error.
#   --range <a..b>   scoped policy only: use this git range as the changed files,
#   --rev <commit>   or this commit against its first parent. Passed verbatim to
#                    map-scope.sh; the explicit override always wins over the
#                    derivation below. At most one of the two. Ignored (not
#                    validated) when the mode is `none` or `full`.
#   --root <dir>     the project root: where the board, `test-config.json`, the
#                    scope map, the git repository and the suites all live.
#                    Default: the root scripts/resolve-root.sh resolves. A story's
#                    and an epic's task lists are read from the board UNDER THIS
#                    ROOT, never from the directory of this script.
#   --config <file>  read the test-run policy from this file instead of
#                    <configs dir>/test-config.json (forwarded to scope-policy.sh).
#   --json           print one JSON object on stdout instead of the human summary
#                    (see OUTPUT). Human text and the suites' own output then go
#                    to stderr, so stdout carries the object and nothing else.
#
# BEHAVIOUR
#   1. Mode. `scope-policy.sh get <scope>` (E72_S06_T02) gives none | scoped | full
#      from test_run_task / test_run_story / test_run_epic of test-config.json,
#      applying its defaults (none / scoped / full) for an absent key and for an
#      invalid value (with its warning, relayed on stderr unchanged).
#   2. none. Prints exactly `no suite run (policy none)` and exits 0. Nothing is
#      derived, discovered or run.
#   3. full. discover-tests.sh -> build-catalog.sh -> run-suites.sh over the whole
#      runnable catalog. An EMPTY catalog is exit 3: a gate that ran nothing is not
#      a pass. This script adds no exclusion logic of its own (manual-only tests
#      stay excluded once the shared scripts exclude them).
#   4. scoped. Determine the changed files (DERIVATION below), run map-scope.sh
#      over them (the same scope map j.commit uses: `commit_scope_map_file` of
#      test-config.json, else templates/test-scope-map.json), narrow the discovery
#      to the mapped suites, build a catalog from that with build-catalog.sh and run
#      it with run-suites.sh. Discovery runs once and is shared by every step.
#      It never exits 0 having executed nothing, so two cases FALL BACK to the full
#      catalog, each with an explicit line on stdout and `effective_mode` "full":
#        - no commits at all were found for the id (nothing to derive):
#            scoped policy: no commits found for <id>; falling back to the full catalog
#            fallback_reason "no-commits"
#        - the changed files map to zero runnable suites (including an empty
#          change set):
#            scoped policy: no suite maps to the changed files; falling back to the full catalog
#            fallback_reason "no-mapped-suites"
#      The fallback then behaves exactly as `full`, including the empty-catalog
#      exit 3.
#
# DERIVATION of the changed files (scoped policy, without --range/--rev)
#   Commits are found on the history of HEAD of the repository at --root, by
#   subject (the board commit naming of j.commit, `task(E##_S##_T##): ...`):
#     - a task commit has a subject starting `task(<task id>)`;
#     - the merge commit of a task branch has a subject starting
#       `Merge branch '<task id>` followed by `-<slug>'` or `'`.
#   Other commits that merely mention the id (rapports, board bookkeeping,
#   `chore(<id>): ...`) are not part of the task's change.
#   Each commit contributes the files of its diff against its FIRST parent (a root
#   commit against the empty tree), so a merge commit contributes everything its
#   branch brought in; names are relative to --root. The changed files are the
#   unique, byte-sorted union over the commits, handed to map-scope.sh with its
#   additive `--files-from` input (one call, one discovery, one collapse of suites
#   that share a command; map-scope.sh takes a single change source, which is why
#   a per-commit call was rejected).
#     task   the commits of that one task id.
#     story  the union over the tasks listed in the `tasks:` frontmatter list of
#            the story file (<stories dir>/<story id>_*.md, or <story id>.md).
#     epic   the union over the stories listed in the `stories:` frontmatter list
#            of the epic file (<epics dir>/<epic id>_*.md), each expanded to its
#            tasks as for a story.
#   The directories are the `stories`/`epics` paths of the registry under --root
#   (default project/board/stories and project/board/epics, also tried under
#   .project). Block lists (`- E72_S06_T01`) and inline lists (`[a, b]`) are read.
#   When a board file or its list is missing (a worktree that does not carry the
#   uncommitted board files, a consuming project that keeps no board), the id
#   PREFIX is used instead, which finds the same commits by their naming alone:
#   a story E##_S## matches task ids E##_S##_T<n>, an epic E## matches
#   E##_S<n>_T<n>. An entry of a list that is not a well-formed id is ignored with
#   a warning. --range / --rev replace all of the above for any scope.
#
# OUTPUT
#   Human (default), on stdout: the policy line, the derivation summary, the
#   suites chosen, run-suites.sh's own output and Test Results summary, and a final
#   line `scope test gate: satisfied ...` or `scope test gate: FAILED ... do not
#   close <scope> <id>`. Warnings (relayed scope-policy.sh, map-scope.sh and
#   catalog warnings) go to stderr.
#   With --json, one compact JSON object on stdout, whenever the gate reached a
#   verdict (exit 0, 1 or 130; stdout is empty for exit 2 and 3):
#     {"scope":"story","id":"E99_S01","mode":"scoped","effective_mode":"full",
#      "fallback_reason":"no-mapped-suites","suites_run":2,"passed":2,"failed":0,
#      "suites":["bats tests (unit)", ...],"exit_code":0}
#   mode            what the policy asked for; effective_mode what ran (differs
#                   after a fallback). fallback_reason is null unless a fallback
#                   happened, else "no-commits" or "no-mapped-suites".
#   suites_run      number of suites executed; passed / failed their counts (read
#                   from run-suites.sh's summary); suites their labels, in run
#                   order. Under `none` all counts are 0 and suites is [].
#
# EXIT CODES
#   0    gate satisfied: policy none, or every suite that ran passed
#   1    at least one suite failed; the caller must not close the scope. Reserved
#        for test failures, so a caller can tell "tests failed" from "gate broke"
#   2    usage error (nothing ran): missing, unknown or repeated option, missing
#        or unknown --scope, missing --id or an id not well-formed for the scope,
#        both --range and --rev, a --range/--rev git rejects as malformed or as an
#        unknown revision, a --root that is not a directory
#   3    infrastructure error (nothing was verified): jq or git missing, no git
#        repository for a scoped derivation, the root or a helper script not
#        found, scope-policy / discovery / catalog / map-scope / run-suites
#        failing for a reason other than a test failing, a full (or fallback)
#        catalog with no runnable suite
#   130  interrupted while the suites ran (run-suites.sh's code, passed through)
#
# Requires jq and git (git only for the scoped policy). macOS bash 3.2 compatible.
################################################################################

set -euo pipefail

SCRIPT_NAME="scope-test-gate.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# skills/j-test/scripts -> the checkout root, or node_modules/@jenga-ai/agent
# when installed as a dependency.
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }
die() { local code="$1"; shift; err "$*"; exit "$code"; }

usage() {
  cat <<'EOF'
Usage: scope-test-gate.sh --scope <task|story|epic> --id <E##[_S##[_T##]]>
                          [--range <a..b> | --rev <commit>] [--root <dir>]
                          [--config <file>] [--json]
       scope-test-gate.sh --help

Run the test-run policy of a board scope before it is closed: none (run nothing),
scoped (the suites mapped from the scope's changed files) or full (the whole
catalog). Never writes board status or any board file.

  --scope <s>      task, story or epic
  --id <id>        E##_S##_T## (task), E##_S## (story) or E## (epic)
  --range <a..b>   scoped policy: use this range as the changed files
  --rev <commit>   scoped policy: use this commit as the changed files
  --root <dir>     project root (default: the resolved root)
  --config <file>  read the policy from this file instead of test-config.json
  --json           one JSON object on stdout; human text goes to stderr
  --help           show this help and exit 0

Exit: 0 satisfied, 1 a suite failed, 2 usage error, 3 infrastructure error,
      130 interrupted
EOF
}

die_usage() {
  err "$1"
  usage >&2
  exit 2
}

# A checkout first, then the installed-package location (the sibling pattern).
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

# ---- arguments ----------------------------------------------------------------
SCOPE=""
ID=""
RANGE_ARG=""
REV_ARG=""
ROOT_ARG=""
CONFIG_ARG=""
JSON=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --scope)
      [ "$#" -ge 2 ] || die_usage "--scope needs an argument"
      SCOPE="$2"; shift 2 ;;
    --id)
      [ "$#" -ge 2 ] || die_usage "--id needs an argument"
      ID="$2"; shift 2 ;;
    --range)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die_usage "--range needs a <a>..<b> argument"
      [ -z "$RANGE_ARG" ] || die_usage "--range was given more than once"
      RANGE_ARG="$2"; shift 2 ;;
    --rev)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die_usage "--rev needs a commit argument"
      [ -z "$REV_ARG" ] || die_usage "--rev was given more than once"
      REV_ARG="$2"; shift 2 ;;
    --root)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die_usage "--root needs a directory argument"
      ROOT_ARG="$2"; shift 2 ;;
    --config)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die_usage "--config needs a file argument"
      CONFIG_ARG="$2"; shift 2 ;;
    --json)
      JSON=1; shift ;;
    *)
      die_usage "unknown argument: $1" ;;
  esac
done

[ -n "$SCOPE" ] || die_usage "missing --scope (expected: task, story or epic)"
case "$SCOPE" in
  task|story|epic) ;;
  *) die_usage "unknown scope: $SCOPE (expected: task, story or epic)" ;;
esac
[ -n "$ID" ] || die_usage "missing --id"
case "$SCOPE" in
  task)  ID_PATTERN='^E[0-9]+_S[0-9]+_T[0-9]+$'; ID_SHAPE='E##_S##_T##' ;;
  story) ID_PATTERN='^E[0-9]+_S[0-9]+$';         ID_SHAPE='E##_S##' ;;
  epic)  ID_PATTERN='^E[0-9]+$';                 ID_SHAPE='E##' ;;
esac
printf '%s\n' "$ID" | grep -Eq "$ID_PATTERN" \
  || die_usage "--id $ID is not a $SCOPE id (expected $ID_SHAPE)"
if [ -n "$RANGE_ARG" ] && [ -n "$REV_ARG" ]; then
  die_usage "at most one of --range and --rev may be given"
fi
if [ -n "$ROOT_ARG" ] && [ ! -d "$ROOT_ARG" ]; then
  die_usage "--root is not a directory: $ROOT_ARG"
fi

# ---- environment --------------------------------------------------------------
command -v jq >/dev/null 2>&1 || die 3 "jq is required but was not found on PATH"

RESOLVER="$(resolve_helper scripts/resolve-root.sh)" || RESOLVER=""
if [ -n "$ROOT_ARG" ]; then
  ROOT="$(cd -- "$ROOT_ARG" && pwd)"
else
  [ -n "$RESOLVER" ] || die 3 "could not locate scripts/resolve-root.sh"
  ROOT="$(bash "$RESOLVER" root)" || die 3 "could not resolve the working root"
  [ -d "$ROOT" ] || die 3 "the resolved root is not a directory: $ROOT"
fi

POLICY="$SCRIPT_DIR/scope-policy.sh"
MAPPER="$SCRIPT_DIR/map-scope.sh"
DISCOVER="$SCRIPT_DIR/discover-tests.sh"
CATALOG_BUILDER="$SCRIPT_DIR/build-catalog.sh"
RUNNER="$SCRIPT_DIR/run-suites.sh"
for helper in "$POLICY" "$MAPPER" "$DISCOVER" "$CATALOG_BUILDER" "$RUNNER"; do
  [ -f "$helper" ] || die 3 "could not locate $(basename -- "$helper") next to $SCRIPT_NAME"
done

TMP_DIR=""
# shellcheck disable=SC2329  # invoked indirectly, through the EXIT trap below
cleanup() {
  if [ -n "$TMP_DIR" ]; then
    rm -rf -- "$TMP_DIR"
    TMP_DIR=""
  fi
}
trap cleanup EXIT
# Not ignored (an ignored signal would be inherited by run-suites.sh); the handler
# does nothing, run-suites.sh stops its suite and reports 130.
trap ':' INT TERM

# ---- result state and output -----------------------------------------------------
MODE=""
EFFECTIVE=""
FALLBACK_REASON=""
RUN_COUNT=0
PASSED=0
FAILED=0
SUITE_LABELS=""

# Human text: stdout normally, stderr with --json.
say() {
  if [ "$JSON" -eq 1 ]; then
    printf '%s\n' "$*" >&2
  else
    printf '%s\n' "$*"
  fi
}

note() { err "$1"; }

# finish <exit code>: the JSON object (when asked for) and the exit.
finish() {
  local code="$1"
  if [ "$JSON" -eq 1 ]; then
    jq -cn --arg scope "$SCOPE" --arg id "$ID" --arg mode "$MODE" --arg eff "$EFFECTIVE" \
      --arg fr "$FALLBACK_REASON" --argjson run "$RUN_COUNT" --argjson passed "$PASSED" \
      --argjson failed "$FAILED" --arg labels "$SUITE_LABELS" --argjson code "$code" \
      '{scope: $scope, id: $id, mode: $mode, effective_mode: $eff,
        fallback_reason: (if $fr == "" then null else $fr end),
        suites_run: $run, passed: $passed, failed: $failed,
        suites: ($labels | split("\n") | map(select(length > 0))),
        exit_code: $code}'
  fi
  exit "$code"
}

# ---- 1. mode -----------------------------------------------------------------------
policy_args=(get "$SCOPE" --root "$ROOT")
if [ -n "$CONFIG_ARG" ]; then
  policy_args+=(--config "$CONFIG_ARG")
fi
rc=0
MODE="$(bash "$POLICY" "${policy_args[@]}")" || rc=$?
[ "$rc" -eq 0 ] || die 3 "scope-policy.sh failed with exit status $rc"
case "$MODE" in
  none|scoped|full) ;;
  *) die 3 "scope-policy.sh printed an unexpected mode: $MODE" ;;
esac
EFFECTIVE="$MODE"

# ---- 2. none -----------------------------------------------------------------------
# Nothing but the one line (stdout is exactly `no suite run (policy none)`).
if [ "$MODE" = "none" ]; then
  say "no suite run (policy none)"
  finish 0
fi

say "scope test gate: $SCOPE $ID, policy $MODE"

# ---- helpers for scoped and full -----------------------------------------------------
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/scope-test-gate.XXXXXX")" \
  || die 3 "could not create a scratch directory under ${TMPDIR:-/tmp}"
DISCOVERY_FILE="$TMP_DIR/discovery.json"

discover() {
  local rc=0
  bash "$DISCOVER" --root "$ROOT" > "$DISCOVERY_FILE" || rc=$?
  [ "$rc" -eq 0 ] || die 3 "discover-tests.sh failed with exit status $rc"
}

# relay_warnings <json file> <jq path to a warnings array> <prefix>
relay_warnings() {
  local line
  jq -r "$2 | .[]?" "$1" 2>/dev/null | while IFS= read -r line; do
    [ -z "$line" ] || note "$3$line"
  done || true
}

# run_catalog <catalog file>: run every runnable suite of the catalog; sets
# RUN_COUNT, PASSED, FAILED, SUITE_LABELS and finishes with the exit code.
run_catalog() {
  local catalog="$1" nums names counts rc=0 out="$TMP_DIR/run.out"
  RUN_COUNT="$(jq -r '.runnable | length' "$catalog")"
  [ "$RUN_COUNT" -gt 0 ] || die 3 "the catalog has no runnable suite; nothing could be run"
  nums="$(jq -r '[.runnable[].n | tostring] | join(" ")' "$catalog")"
  SUITE_LABELS="$(jq -r '.runnable[] | .name as $n | .type as $t
                         | if ($n | endswith(" (" + $t + ")")) then $n else $n + " (" + $t + ")" end' "$catalog")"
  names="$(printf '%s\n' "$SUITE_LABELS" | paste -sd ',' - | sed 's/,/, /g')"
  say "running $RUN_COUNT suite(s): $names"

  # The right side of the pipe ignores INT/TERM (inherited by exec), so a Ctrl-C
  # reaches run-suites.sh, which stops its suite and prints the summary through
  # the still-open pipe. Suite output reaches the caller live.
  set +e
  if [ "$JSON" -eq 1 ]; then
    # shellcheck disable=SC2086  # nums is a list of plain integers
    bash "$RUNNER" --catalog "$catalog" --root "$ROOT" $nums | ( trap '' INT TERM; exec tee "$out" >&2 )
    rc="${PIPESTATUS[0]}"
  else
    # shellcheck disable=SC2086
    bash "$RUNNER" --catalog "$catalog" --root "$ROOT" $nums | ( trap '' INT TERM; exec tee "$out" )
    rc="${PIPESTATUS[0]}"
  fi
  set -e

  counts="$(sed -n 's/^\([0-9][0-9]*\) passed, \([0-9][0-9]*\) failed.*/\1 \2/p' "$out" | tail -n 1)"
  if [ -n "$counts" ]; then
    PASSED="${counts%% *}"
    FAILED="${counts##* }"
  elif [ "$rc" -eq 1 ]; then
    PASSED=0; FAILED=1
  else
    PASSED=0; FAILED=0
  fi

  case "$rc" in
    0)
      say "scope test gate: satisfied ($SCOPE $ID, policy $MODE, ran $EFFECTIVE: $PASSED passed, $FAILED failed)"
      finish 0
      ;;
    1)
      say "scope test gate: FAILED ($SCOPE $ID, policy $MODE, ran $EFFECTIVE: $PASSED passed, $FAILED failed); do not close $SCOPE $ID"
      finish 1
      ;;
    130)
      say "scope test gate: interrupted ($SCOPE $ID); the gate is not satisfied"
      finish 130
      ;;
    *)
      die 3 "run-suites.sh failed with exit status $rc (this is not a test failure)"
      ;;
  esac
}

# run_full: discovery -> catalog -> run, for `full` and for a fallback.
run_full() {
  local catalog="$TMP_DIR/catalog-full.json" rc=0
  EFFECTIVE="full"
  bash "$CATALOG_BUILDER" --root "$ROOT" --discovery-file "$DISCOVERY_FILE" > "$catalog" || rc=$?
  [ "$rc" -eq 0 ] || die 3 "build-catalog.sh failed with exit status $rc"
  relay_warnings "$catalog" '.warnings' "catalog: "
  if [ "$(jq -r '.runnable | length' "$catalog")" -eq 0 ]; then
    die 3 "the full catalog has no runnable test suite; an empty catalog is an error, not a pass"
  fi
  run_catalog "$catalog"
}

# ---- 3. full -----------------------------------------------------------------------
if [ "$MODE" = "full" ]; then
  discover
  run_full
fi

# ---- 4. scoped -----------------------------------------------------------------------
command -v git >/dev/null 2>&1 || die 3 "git is required for the scoped policy but was not found on PATH"
[ "$(git -C "$ROOT" rev-parse --is-inside-work-tree 2>/dev/null || true)" = "true" ] \
  || die 3 "the scoped policy needs a git repository, and $ROOT is not inside one"

git_q() { git -C "$ROOT" -c core.quotepath=off "$@"; }

# fm_list <file> <key>: the entries of a frontmatter list, one per line. Reads a
# block list ("- item" lines) or an inline list ("key: [a, b]").
fm_list() {
  awk -v key="$2" '
    { sub(/\r$/, "") }
    NR == 1 { if ($0 != "---") exit; infm = 1; next }
    infm && $0 == "---" { exit }
    infm {
      if (inlist) {
        if ($0 ~ /^[[:space:]]*-[[:space:]]+/) {
          v = $0; sub(/^[[:space:]]*-[[:space:]]+/, "", v)
          gsub(/["\047 \t]/, "", v); if (v != "") print v
          next
        }
        inlist = 0
      }
      if (index($0, key ":") == 1) {
        rest = substr($0, length(key) + 2)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", rest)
        if (rest ~ /^\[/) {
          gsub(/\[|\]|"|\047/, "", rest)
          n = split(rest, parts, ",")
          for (i = 1; i <= n; i++) { v = parts[i]; gsub(/[ \t]/, "", v); if (v != "") print v }
        } else if (rest == "") {
          inlist = 1
        }
      }
    }' "$1"
}

# board_dir <registry key>: the board directory of that kind under ROOT.
board_dir() {
  local key="$1" dir="" cand
  if [ -n "$RESOLVER" ]; then
    dir="$(JENGA_PROJECT_ROOT="$ROOT" bash "$RESOLVER" get "$key" 2>/dev/null)" || dir=""
  fi
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    dir=""
    for cand in "$ROOT/project/board/$key" "$ROOT/.project/board/$key"; do
      if [ -d "$cand" ]; then dir="$cand"; break; fi
    done
  fi
  printf '%s' "$dir"
}

# board_file <dir> <id>: the item file for an id, or nothing.
board_file() {
  local dir="$1" id="$2" f
  [ -n "$dir" ] || return 0
  if [ -f "$dir/$id.md" ]; then
    printf '%s' "$dir/$id.md"
    return 0
  fi
  for f in "$dir/${id}_"*.md; do
    if [ -f "$f" ]; then
      printf '%s' "$f"
      return 0
    fi
  done
  return 0
}

STORIES_DIR=""
EPICS_DIR=""
if [ "$SCOPE" = "story" ] || [ "$SCOPE" = "epic" ]; then
  STORIES_DIR="$(board_dir stories)"
fi
if [ "$SCOPE" = "epic" ]; then
  EPICS_DIR="$(board_dir epics)"
fi

# valid_ids <pattern>: stdin -> the lines matching the id pattern; others warned.
valid_ids() {
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if printf '%s\n' "$line" | grep -Eq "$1"; then
      printf '%s\n' "$line"
    else
      note "ignoring a list entry that is not a well-formed id: $line"
    fi
  done
}

# story_patterns <story id>: id patterns (one per line) for the commits of a story.
story_patterns() {
  local sid="$1" file ids=""
  file="$(board_file "$STORIES_DIR" "$sid")"
  if [ -n "$file" ]; then
    ids="$(fm_list "$file" tasks | valid_ids '^E[0-9]+_S[0-9]+_T[0-9]+$')"
  fi
  if [ -n "$ids" ]; then
    printf '%s\n' "$ids"
  else
    printf '%s_T[0-9]+\n' "$sid"
  fi
}

# id_alternation: the ERE alternation of the task ids (or id prefixes) whose commits
# make up the scope; reads the board under ROOT.
id_alternation() {
  local patterns="" efile sids sid
  case "$SCOPE" in
    task)
      patterns="$ID"
      ;;
    story)
      patterns="$(story_patterns "$ID")"
      ;;
    epic)
      efile="$(board_file "$EPICS_DIR" "$ID")"
      sids=""
      if [ -n "$efile" ]; then
        sids="$(fm_list "$efile" stories | valid_ids '^E[0-9]+_S[0-9]+$')"
      fi
      if [ -n "$sids" ]; then
        while IFS= read -r sid; do
          patterns="${patterns}$(story_patterns "$sid")"$'\n'
        done <<EOF
$sids
EOF
      else
        patterns="${ID}_S[0-9]+_T[0-9]+"
      fi
      ;;
  esac
  printf '%s\n' "$patterns" | sed '/^$/d' | LC_ALL=C sort -u | paste -sd '|' -
}

discover

MAP_FILE_OUT="$TMP_DIR/map.json"
map_args=(--root "$ROOT" --suites "$DISCOVERY_FILE")
NO_COMMITS=0

if [ -n "$RANGE_ARG" ] || [ -n "$REV_ARG" ]; then
  if [ -n "$RANGE_ARG" ]; then
    map_args+=(--range "$RANGE_ARG")
    say "changed files: from --range $RANGE_ARG"
  else
    map_args+=(--rev "$REV_ARG")
    say "changed files: from --rev $REV_ARG"
  fi
else
  # Commits by subject, newest first, from the history of HEAD.
  ID_ALTERNATION="$(id_alternation)"
  TAB="$(printf '\t')"
  SHAS="$(git_q log --format='%H%x09%s' HEAD 2>/dev/null \
    | grep -E "^[0-9a-f]+${TAB}(task\\((${ID_ALTERNATION})\\)|Merge branch '(${ID_ALTERNATION})(-[^']*)?')" \
    | cut -f1 || true)"
  if [ -z "$SHAS" ]; then
    NO_COMMITS=1
  else
    empty_tree="$(git_q hash-object -t tree /dev/null)" || die 3 "git could not compute the empty tree"
    FILES_LIST="$TMP_DIR/files.txt"
    : > "$FILES_LIST.raw"
    commit_count=0
    while IFS= read -r sha; do
      [ -n "$sha" ] || continue
      commit_count=$((commit_count + 1))
      if git_q rev-parse --verify --quiet "$sha^1" >/dev/null 2>&1; then
        base="$sha^1"
      else
        base="$empty_tree"
      fi
      git_q diff --name-only -z --no-renames --relative "$base" "$sha" -- \
        | tr '\0' '\n' >> "$FILES_LIST.raw" || die 3 "git could not diff commit $sha"
    done <<EOF
$SHAS
EOF
    sed '/^$/d' "$FILES_LIST.raw" | LC_ALL=C sort -u > "$FILES_LIST"
    file_count="$(wc -l < "$FILES_LIST" | tr -d ' ')"
    map_args+=(--files-from "$FILES_LIST")
    say "changed files: $file_count file(s) from $commit_count commit(s) of $ID"
  fi
fi

if [ "$NO_COMMITS" -eq 1 ]; then
  FALLBACK_REASON="no-commits"
  say "scoped policy: no commits found for $ID; falling back to the full catalog"
  run_full
fi

rc=0
bash "$MAPPER" "${map_args[@]}" > "$MAP_FILE_OUT" || rc=$?
case "$rc" in
  0) ;;
  2) die 2 "map-scope.sh rejected the --range/--rev argument (see its message above)" ;;
  4) die 2 "unknown revision in --range/--rev (map-scope.sh exit 4; a missing git repository was ruled out earlier)" ;;
  *) die 3 "map-scope.sh failed with exit status $rc" ;;
esac
jq -e '.mapped_suites | type == "array"' "$MAP_FILE_OUT" >/dev/null 2>&1 \
  || die 3 "map-scope.sh printed output that is not a scope map"
relay_warnings "$MAP_FILE_OUT" '.warnings' "map-scope: "

if [ "$(jq -r '.mapped_suites | length' "$MAP_FILE_OUT")" -gt 0 ]; then
  # Narrow the discovery to the mapped suites and build the catalog from that.
  derived="$TMP_DIR/discovery-mapped.json"
  jq -c --argjson ids "$(jq -c '.mapped_suites' "$MAP_FILE_OUT")" \
    '.suites |= map(select(.id as $i | ($ids | index($i)) != null))' \
    "$DISCOVERY_FILE" > "$derived" || die 3 "could not narrow the discovery to the mapped suites"
  catalog="$TMP_DIR/catalog-scoped.json"
  rc=0
  bash "$CATALOG_BUILDER" --root "$ROOT" --discovery-file "$derived" > "$catalog" || rc=$?
  [ "$rc" -eq 0 ] || die 3 "build-catalog.sh failed with exit status $rc"
  if [ "$(jq -r '.runnable | length' "$catalog")" -gt 0 ]; then
    say "scoped policy: $(jq -r '.mapped_suites | length' "$MAP_FILE_OUT") suite(s) map to the changed files"
    run_catalog "$catalog"
  fi
fi

FALLBACK_REASON="no-mapped-suites"
say "scoped policy: no suite maps to the changed files; falling back to the full catalog"
run_full
