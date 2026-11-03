#!/usr/bin/env bash
################################################################################
# baseline-permissions.sh — the ONE decider for the level-2 baseline test
# precondition, and for which test files require it (E72_S07_T02)
#
# Some suites cannot pass unless the working tree's settings files sit at the
# level-2 (Guarded) baseline, because the thing they exercise — mirror.sh's
# check_permission_level_invariant — refuses a real push while they do not. In an
# elevated session those suites fail for a reason that has nothing to do with the
# change under test, which is what made every story's closing gate unpassable on
# 2026-10-22 (see project/board/stories/E72_S07_*.md and
# project/documentation/scope-gate-fix-decision.md).
#
# This script is the SOLE definition of two things:
#   1. whether the precondition currently holds  (`check`, `reason`)
#   2. which test files declare that they need it (`list`, `check-file`, `reason-file`)
# No runner, gate or suite keeps its own copy of either. narrow-suites.sh and the
# marked suites themselves both call this script.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   baseline-permissions.sh check  [--root <dir>]     exit 0 satisfied, 1 not
#   baseline-permissions.sh reason [--root <dir>]     one line, empty when satisfied
#   baseline-permissions.sh list   [--root <dir>]     <path>TAB<reason> per marked file
#   baseline-permissions.sh check-file  <file>        exit 0 marked, 1 not
#   baseline-permissions.sh reason-file <file>        the file's reason
#   baseline-permissions.sh --help
#
#   --root <dir>  the PROJECT root: where the settings files and tests/ live, and
#                 where an optional project override of the baseline template is
#                 looked for first. It is NOT where the shipped baseline template
#                 lives — that is package-relative; see PATH CLASSIFICATION
#                 below. Defaults to the root scripts/resolve-root.sh resolves. A
#                 fixture root makes the precondition testable without touching
#                 the real session, which is the only way to cover it (see WHY A
#                 FIXTURE, below).
#
# ---------------------------------------------------------------------------
# THE SIGNAL (normative) — field-diff, never session_level
# ---------------------------------------------------------------------------
# The precondition holds when, for each of `.claude/settings.json` and
# `.agents/settings.json` that EXISTS, both
#     .permissions.deny      and      .autoMode.allow
# equal the same field of templates/permission-levels/level-2-guarded.json.
# Arrays are compared sorted, so element order never matters.
#
# This is deliberately the SAME comparison check_permission_level_invariant
# performs, and for the reason its own header gives under "DESIGN DECISION —
# field-diff is the GATE, session_level is DIAGNOSTIC ONLY":
#   - `.jenga-permission-level.json`'s session_level is NOT consulted for the
#     verdict. It goes stale in both directions — a stale `2` while the files are
#     still loosened would false-pass, and a stale `5` after the files were
#     restored would false-fail. It is read ONLY to annotate `reason`'s message.
#   - It is NOT a whole-file comparison. settings.json also carries defaultMode,
#     env and hooks, which change for unrelated legitimate reasons (this repo's
#     PreToolUse block is registered across six files), and a whole-file diff
#     would false-positive on every one of those.
# Gating on the same two fields as the subject makes this check correct by
# construction: it cannot disagree with what the suite is asserting on.
#
# A settings file that does NOT exist is a skip for that file — there is nothing
# to diverge. A file that exists but is unparseable, or lacks the two fields,
# FAILS CLOSED (precondition unsatisfied), the same present-but-broken
# philosophy check_permission_level_invariant applies to the same two files.
#
# ---------------------------------------------------------------------------
# PATH CLASSIFICATION (normative) — every path this script builds
# ---------------------------------------------------------------------------
# Two roots exist and they are NOT interchangeable. Confusing them is what made
# the gate hard-block in every npm-installed project (E72_S07_T02, fix round 3):
# the baseline TEMPLATE was resolved from --root, i.e. the consuming project,
# although templates/ ships to node_modules/@jenga-ai/agent/templates/ and never
# to a consumer's project root. Classify every new path against this table
# before adding it.
#
#   REPO_ROOT  = SCRIPT_DIR/../../..  — the PACKAGE root. The checkout root in
#                this monorepo, .claude/ or .agents/ in a self-synced tree, and
#                node_modules/@jenga-ai/agent in a consumer install. Everything
#                Jenga SHIPS is under it.
#   ROOT       = --root, else scripts/resolve-root.sh, else REPO_ROOT as a last
#                resort — the PROJECT root. Everything the project OWNS is under
#                it.
#
# | path                                            | root     | why           |
# |-------------------------------------------------|----------|---------------|
# | templates/permission-levels/level-2-guarded.json| PACKAGE  | ships; a      |
# |   (project override honoured first, see         | (project | project copy  |
# |    resolve_baseline_template)                   |  first)  | may override  |
# | scripts/resolve-root.sh                         | PACKAGE  | ships         |
# | .claude/settings.json, .agents/settings.json    | PROJECT  | the subject   |
# | .jenga-permission-level.json                    | PROJECT  | session state |
# | tests/*.bats                                    | PROJECT  | project tests |
#
# Both package-relative lookups go through resolve_helper(), which tries
# REPO_ROOT and then REPO_ROOT/node_modules/@jenga-ai/agent — the same two
# candidates discover-tests.sh, map-scope.sh, run-suites.sh, build-catalog.sh
# and scope-test-gate.sh use. A one-candidate lookup is the same bug class as
# the one above and must not be reintroduced.
#
# The baseline template specifically follows map-scope.sh's resolution order for
# templates/test-scope-map.json: the root's own copy when it has one, else the
# shipped copy. A distributed tree can therefore carry its own level-2
# definition, and the npm layout — which carries none — falls through to the
# package. die 2 only when NEITHER exists.
#
# ---------------------------------------------------------------------------
# THE MARKER (normative)
# ---------------------------------------------------------------------------
#   # jenga:requires-baseline-permissions: <reason>
# A comment line within the FIRST 40 LINES of a `.bats` file. The reason is
# mandatory and one line; a marker with an empty reason is an ERROR (exit 2), so
# a suite can never be quietly excluded from a gate without saying why.
#
# In-file, not a list in project/configs/test-config.json. This follows the
# decision E77_S02_T01 recorded for its own `# jenga:manual-only:` marker, whose
# strongest reason applies verbatim here: test-config.json SHIPS in the public
# mirror, and a list entry would publish the name of a .publicignore-blocklisted
# test file. A tag inside the file travels with the file and is absent wherever
# the file is absent. It also cannot go stale across a rename or a delete.
#
# `list` walks <root>/tests/*.bats only. The same comment form would extend to
# another ecosystem's test files; nothing but the walk would need to change.
#
# ---------------------------------------------------------------------------
# WHY A FIXTURE ROOT MATTERS
# ---------------------------------------------------------------------------
# As of 2026-11-01 the real tree is baseline-clean, so the unsatisfied branch
# cannot be reached from ambient state and must be driven through --root against
# a scratch tree. Coverage does exactly that. Never "test" this by elevating the
# real session: the permission level is the user's own decision and E72_S07
# reserves it to them explicitly.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0  `check`/`check-file`: yes.  `reason`/`list`/`reason-file`: printed fine
#   1  `check`: the precondition does NOT hold. `check-file`: not marked
#   2  usage error, a marker with an empty reason, jq missing, an unresolvable
#      root, or a level-2 baseline template that is missing or unreadable in
#      BOTH the project override and the shipped package location (an
#      infrastructure problem is never reported as "satisfied")
#
# NORMATIVE — an inability to evaluate is NEVER a pass. exit 2 means "nothing was
# verified", per E72_S06's exit-code contract. Concretely: every caller of
# divergent_files() captures it to a VARIABLE and propagates the status by hand.
# It must never be invoked inside `[ -n "$(...)" ]` or any other construct that
# discards the substitution's exit status, because divergent_files() calls die
# and an exit inside a command substitution leaves only the subshell — which is
# precisely how `check` came to report a satisfied verdict against a baseline
# template that was absent. marker_reason() returns rather than dies for the
# mirror image of the same hazard; see its own header.
#
# `list`, `check-file` and `reason-file` answer "which test files DECLARE that
# they need the precondition". That is a property of the files alone, so they
# deliberately never read the baseline template and are unaffected by its
# absence. They are not a second, disagreeing verdict on the precondition: only
# `check` and `reason` decide that, and narrow-suites.sh reaches `list` only
# after `check` returned 1, which it can only do having read the template.
#
# Reads files only. Executes no project code and runs no test, the same rule
# discover-tests.sh states for itself. Writes nothing. macOS bash 3.2 compatible;
# safe under `set -euo pipefail`.
################################################################################

set -euo pipefail

SCRIPT_NAME="baseline-permissions.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# skills/j-test/scripts -> the checkout root, or node_modules/@jenga-ai/agent
# when installed as a dependency.
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

export LC_ALL=C

MARKER_TAG="jenga:requires-baseline-permissions"
MARKER_SCAN_LINES=40

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }
die() { local code="$1"; shift; err "$*"; exit "$code"; }

usage() {
  cat <<'EOF'
Usage: baseline-permissions.sh check       [--root <dir>]
       baseline-permissions.sh reason      [--root <dir>]
       baseline-permissions.sh list        [--root <dir>]
       baseline-permissions.sh check-file  <file>
       baseline-permissions.sh reason-file <file>
       baseline-permissions.sh --help

Decide whether the tree satisfies the level-2 (Guarded) baseline precondition,
and which test files declare that they require it.

  check        exit 0 when .claude/settings.json and .agents/settings.json match
               templates/permission-levels/level-2-guarded.json on
               permissions.deny and autoMode.allow; exit 1 when they do not
  reason       one line naming the divergent files; empty when satisfied
  list         one "<path>\t<reason>" line per marked tests/*.bats file
  check-file   exit 0 when <file> carries the marker, 1 when it does not
  reason-file  print <file>'s marker reason

Marker: "# jenga:requires-baseline-permissions: <reason>" in the first 40 lines.
The reason is mandatory; an empty reason is an error (exit 2).
EOF
}

# ---- arguments ---------------------------------------------------------------
SUBCOMMAND=""
ROOT_ARG=""
FILE_ARG=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help|help)
      usage
      exit 0
      ;;
    --root)
      [ "$#" -ge 2 ] || die 2 "--root needs a directory"
      [ -z "$ROOT_ARG" ] || die 2 "--root given more than once"
      ROOT_ARG="$2"
      shift 2
      ;;
    --root=*)
      [ -z "$ROOT_ARG" ] || die 2 "--root given more than once"
      ROOT_ARG="${1#--root=}"
      shift
      ;;
    -*)
      die 2 "unknown option: $1"
      ;;
    check|reason|list|check-file|reason-file)
      [ -z "$SUBCOMMAND" ] || die 2 "more than one subcommand given ($SUBCOMMAND and $1)"
      SUBCOMMAND="$1"
      shift
      ;;
    *)
      if [ -z "$SUBCOMMAND" ]; then
        die 2 "unknown subcommand: $1"
      fi
      [ -z "$FILE_ARG" ] || die 2 "more than one file argument given"
      FILE_ARG="$1"
      shift
      ;;
  esac
done

[ -n "$SUBCOMMAND" ] || { usage >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die 2 "jq is required but was not found on PATH"

case "$SUBCOMMAND" in
  check-file|reason-file)
    [ -n "$FILE_ARG" ] || die 2 "$SUBCOMMAND needs a file argument"
    [ -z "$ROOT_ARG" ] || die 2 "$SUBCOMMAND takes a file, not --root"
    ;;
  *)
    [ -z "$FILE_ARG" ] || die 2 "$SUBCOMMAND takes no file argument"
    ;;
esac

# ---- package-relative asset resolution ---------------------------------------
# resolve_helper <relative path>: the first existing candidate under the PACKAGE
# root. Mirrors the resolve_helper of discover-tests.sh, map-scope.sh,
# run-suites.sh, build-catalog.sh and scope-test-gate.sh verbatim — a checkout
# (or node_modules/@jenga-ai/agent, when REPO_ROOT already points there) first,
# then an installed package beneath it. Returns 1 and prints nothing when the
# asset is in neither place; callers decide what that means.
#
# NEVER resolve a shipped asset from one candidate only. That is the bug class
# the PATH CLASSIFICATION block above exists to prevent.
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

# ---- root resolution ---------------------------------------------------------
resolve_root() {
  if [ -n "$ROOT_ARG" ]; then
    [ -d "$ROOT_ARG" ] || die 2 "--root is not a directory: $ROOT_ARG"
    (cd -- "$ROOT_ARG" && pwd)
    return 0
  fi
  # scripts/resolve-root.sh is package-relative, so it goes through
  # resolve_helper. It used to be built as "$SCRIPT_DIR/../../../scripts/..." —
  # one candidate, which silently fell through to REPO_ROOT in any layout where
  # only the node_modules copy exists. Same class as the baseline-template bug.
  local resolver out=""
  resolver="$(resolve_helper scripts/resolve-root.sh)" || resolver=""
  if [ -n "$resolver" ]; then
    out="$(bash "$resolver" 2>/dev/null || true)"
  fi
  if [ -n "$out" ] && [ -d "$out" ]; then
    printf '%s\n' "$out"
  else
    printf '%s\n' "$REPO_ROOT"
  fi
}

# ---- the marker --------------------------------------------------------------
# marker_reason <file>: print the reason on stdout and return 0 when <file>
# carries the marker in its first $MARKER_SCAN_LINES lines; return 1 when it does
# not; print the cause on stderr and return 2 when the marker is present with an
# empty reason.
#
# It RETURNS 2 rather than calling die, because every caller invokes it inside a
# command substitution — a subshell, where an exit would be swallowed and the
# empty-reason rule would silently degrade to "not marked". That is the one
# failure this rule exists to prevent, so the status is propagated by hand at
# each call site instead.
marker_reason() {
  local file="$1" line reason
  [ -f "$file" ] || return 1
  line="$(head -n "$MARKER_SCAN_LINES" -- "$file" 2>/dev/null \
            | grep -m1 -F "# $MARKER_TAG:" || true)"
  [ -n "$line" ] || return 1
  # Everything after the first "<tag>:" is the reason; trim surrounding blanks.
  reason="${line#*"# $MARKER_TAG:"}"
  reason="$(printf '%s' "$reason" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [ -z "$reason" ]; then
    err "$file: the $MARKER_TAG marker has an empty reason; a suite may not be excluded without one"
    return 2
  fi
  printf '%s\n' "$reason"
  return 0
}

# ---- the field diff ----------------------------------------------------------
# sorted_field <json file> <jq path>: the field as a compact sorted JSON array.
# Prints nothing and returns 1 when the file is unreadable, not valid JSON, or
# the field is absent or not an array.
sorted_field() {
  jq -ce --arg p "$2" '
    getpath($p | split(".")) as $v
    | if ($v | type) == "array" then ($v | sort) else empty end
  ' "$1" 2>/dev/null
}

# divergent_files <root>: print one relative path per settings file that diverges
# from the baseline (or that is present but broken). Empty output means the
# precondition holds.
#
# resolve_baseline_template <root>: print the level-2 baseline template's path.
# PROJECT OVERRIDE first, then the SHIPPED package copy — the order map-scope.sh
# uses for templates/test-scope-map.json. Returns 1, printing nothing, when the
# template is in neither place; the caller dies 2 on that.
#
# The template is a SHIPPED asset: it ships to
# node_modules/@jenga-ai/agent/templates/ and never to a consumer's project
# root, so resolving it from <root> alone hard-blocked every scoped and every
# full gate run in every npm-installed project. See PATH CLASSIFICATION above.
resolve_baseline_template() {
  local root="$1" rel="templates/permission-levels/level-2-guarded.json"
  if [ -f "$root/$rel" ]; then
    printf '%s' "$root/$rel"
    return 0
  fi
  resolve_helper "$rel"
}

divergent_files() {
  local root="$1" baseline=""
  baseline="$(resolve_baseline_template "$root")" || baseline=""
  [ -n "$baseline" ] \
    || die 2 "the level-2 baseline template was not found; looked for templates/permission-levels/level-2-guarded.json under the project root ($root) and under the package root ($REPO_ROOT, and its node_modules/@jenga-ai/agent)"

  local base_deny base_allow
  base_deny="$(sorted_field "$baseline" permissions.deny)" \
    || die 2 "could not read .permissions.deny from $baseline (invalid JSON?)"
  base_allow="$(sorted_field "$baseline" autoMode.allow)" \
    || die 2 "could not read .autoMode.allow from $baseline (invalid JSON?)"

  local rel abs actual_deny actual_allow
  for rel in ".claude/settings.json" ".agents/settings.json"; do
    abs="$root/$rel"
    # Absent is a skip: nothing to diverge, so nothing a suite could trip over.
    [ -f "$abs" ] || continue
    # Present but broken fails closed, as in check_permission_level_invariant.
    actual_deny="$(sorted_field "$abs" permissions.deny)" || { printf '%s\n' "$rel"; continue; }
    actual_allow="$(sorted_field "$abs" autoMode.allow)" || { printf '%s\n' "$rel"; continue; }
    if [ "$actual_deny" != "$base_deny" ] || [ "$actual_allow" != "$base_allow" ]; then
      printf '%s\n' "$rel"
    fi
  done
}

# ---- subcommands -------------------------------------------------------------
case "$SUBCOMMAND" in
  check)
    ROOT="$(resolve_root)"
    # Capture to a variable, then propagate the status by hand — exactly as
    # `reason` does, and for the reason marker_reason's header states.
    #
    # This used to read `if [ -n "$(divergent_files "$ROOT")" ]`. `[` discards
    # the command substitution's exit status entirely, so a `die 2` inside
    # divergent_files (a missing or unreadable baseline template) printed its
    # message to stderr, exited only the SUBSHELL, left `[` testing the empty
    # string, and the parent exited 0 — an infrastructure failure reported as a
    # SATISFIED verdict, produced from a baseline that was never read. An
    # inability to evaluate must never read as a pass; exit 2 is the contract's
    # "nothing was verified" (E72_S06, and the EXIT CODES block above).
    rc=0
    divergent="$(divergent_files "$ROOT")" || rc=$?
    [ "$rc" -eq 0 ] || exit "$rc"
    [ -z "$divergent" ] || exit 1
    exit 0
    ;;

  reason)
    ROOT="$(resolve_root)"
    # Same capture-then-propagate shape as `check` above: explicit rather than
    # relying on `set -e` to carry divergent_files' status out of the assignment.
    rc=0
    divergent="$(divergent_files "$ROOT")" || rc=$?
    [ "$rc" -eq 0 ] || exit "$rc"
    if [ -z "$divergent" ]; then
      exit 0
    fi
    # session_level is diagnostic only — it never reached the verdict above.
    level="$(jq -r '.session_level // empty' "$ROOT/.jenga-permission-level.json" 2>/dev/null || true)"
    [ -n "$level" ] || level="missing/unreadable"
    printf 'the session is elevated: %s diverge(s) from the level-2 (Guarded) baseline on permissions.deny/autoMode.allow (session_level reads %s, diagnostic only)\n' \
      "$(printf '%s' "$divergent" | tr '\n' ' ' | sed -e 's/ $//' -e 's/ /, /g')" "$level"
    exit 0
    ;;

  list)
    ROOT="$(resolve_root)"
    [ -d "$ROOT/tests" ] || exit 0
    # Accumulate first and print only once every file parsed cleanly: a consumer
    # must never act on a partial list that quietly omitted a broken file.
    listing=""
    for f in "$ROOT"/tests/*.bats; do
      [ -f "$f" ] || continue
      rc=0
      reason="$(marker_reason "$f")" || rc=$?
      case "$rc" in
        0) listing="${listing}tests/$(basename -- "$f")	${reason}
" ;;
        1) ;;
        *) exit "$rc" ;;
      esac
    done
    [ -z "$listing" ] || printf '%s' "$listing" | sort
    exit 0
    ;;

  check-file)
    rc=0
    marker_reason "$FILE_ARG" >/dev/null || rc=$?
    exit "$rc"
    ;;

  reason-file)
    rc=0
    reason="$(marker_reason "$FILE_ARG")" || rc=$?
    [ "$rc" -eq 0 ] || exit "$rc"
    printf '%s\n' "$reason"
    exit 0
    ;;
esac
