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
#      applying its defaults (none / scoped / none) for an absent key and for an
#      invalid value (with its warning, relayed on stderr unchanged).
#   2. none. Prints exactly `no suite run (policy none)` and exits 0. Nothing is
#      derived, discovered or run.
#   3. full. discover-tests.sh -> narrow-suites.sh -> build-catalog.sh ->
#      run-suites.sh over the whole runnable catalog. An EMPTY catalog is exit 3: a
#      gate that ran nothing is not a pass. `full` has no selection to narrow, so
#      narrow-suites.sh only ever EXCLUDES there (see NARROWING AND EXCLUSION
#      below) and is a byte-for-byte no-op while the baseline precondition holds.
#      This script adds no exclusion logic of its own (manual-only tests stay
#      excluded once the shared scripts exclude them).
#   4. scoped. Determine the changed files (DERIVATION below), run map-scope.sh
#      over them (the same scope map j.commit uses: `commit_scope_map_file` of
#      test-config.json, else templates/test-scope-map.json), narrow the discovery
#      to the mapped suites, build a catalog from that with build-catalog.sh and run
#      it with run-suites.sh. Discovery runs once and is shared by every step.
#      It never exits 0 having executed nothing, and it NEVER RUNS THE FULL
#      CATALOG: E72_S08_T02 removed the escalation that used to, because a scoped
#      gate that amounts to a full one is the whole defect story E72_S08 exists to
#      remove. The two cases that used to escalate are now handled DIFFERENTLY
#      FROM EACH OTHER, because they are different situations:
#        - no commits at all were found for the id. There is genuinely nothing to
#          derive, so this is an explicit NON-PASS: nothing is run, exit 3,
#          `effective_mode` stays "scoped" (it can never read "full"), and the line
#          is
#            scoped policy: no commits found for <id>; nothing could be derived, so nothing was verified (not a pass)
#            fallback_reason "no-commits"
#          A default set here would report a pass for an id whose change set could
#          not be determined at all, which is why this is refused rather than
#          substituted (story E72_S08's amended decision 3). --json still prints
#          its object for this exit 3: see OUTPUT.
#        - the changed files map to zero runnable suites (including an empty change
#          set). There IS a change, only no rule covers it, so the BOUNDED DEFAULT
#          SUITE SET runs: resolve-default-suites.sh (E72_S08_T06) resolves
#          `test_default_suite_set` of test-config.json into a selection it asserts
#          is a non-empty STRICT subset of the runnable catalog, and that selection
#          goes through the same narrow -> catalog -> run path as a mapped one.
#          Never the full catalog, never nothing. `effective_mode` takes a THIRD
#          value, "default-set", and the line is
#            scoped policy: no suite maps to the changed files; running the bounded default suite set instead (never the full catalog)
#            fallback_reason "no-mapped-suites"
#          Every way the floor can fail to resolve is exit 3 with its own message,
#          and none of them is a pass or a fall-through: not configured (resolver
#          exit 4), no runnable test file (5), the entire catalog (6), an invalid
#          configured value (3).
#      A scoped run is also checked, just before anything executes, against the
#      catalog a `full` policy would run (E72_S08_T03): if it would execute every
#      unit of that catalog it is REFUSED, runs nothing and exits 3 with
#      `refusal: "scoped-equals-full"`. See THE STANDING scoped != full INVARIANT
#      above run_catalog, and project/documentation/test-runner.md.
#      So a caller can tell all THREE outcomes apart from the exit code and the
#      output alone: effective_mode "scoped" (a mapped selection ran),
#      "default-set" (nothing mapped, so the floor ran) and "full" (policy `full`
#      asked for the whole catalog, which no scoped run can reach).
#
# ---------------------------------------------------------------------------
# NARROWING AND EXCLUSION (E72_S07_T02)
# ---------------------------------------------------------------------------
# Narrowing the suite LIST to the mapped ids is NOT narrowing the run. This
# repository has ONE bats suite (discover-tests.sh emits one per directory) whose
# command is `bats tests/*.bats`, so a filtered list of one still ran all 261 test
# files / 5666 cases: `scoped` and `full` were operationally identical, and one
# unrelated red assertion anywhere failed every story's closing gate. Measured in
# E72_S07_T01; the decision record is
# project/documentation/scope-gate-fix-decision.md.
#
# So both paths now pass the discovery through narrow-suites.sh (its header is the
# contract), which rewrites a bats suite's command to the explicit list of files
# that matter:
#   scoped   the files are map-scope.sh's `mapped_tests` — the narrowing hook its
#            header always advertised and nothing had ever read.
#   full     no narrowing (full means everything), exclusion only.
#
# EXCLUSION. baseline-permissions.sh is the sole decider of whether the working
# tree sits at the level-2 (Guarded) baseline, and of which test files declare
# they need it (`# jenga:requires-baseline-permissions: <reason>`). While the
# precondition is unmet, those files are removed from the run.
#
# A SKIP IS NEVER A PASS. An excluded file is named on stdout with its reason and
# listed in `excluded_test_files`, so a gate that went green because something was
# skipped cannot be read as one that ran it. The pass/fail tally still comes from
# run-suites.sh's own summary, so an excluded file cannot enter `passed`. If
# exclusion empties every selected suite the gate exits 3 ("nothing was
# verified") and substitutes nothing for what the exclusion removed. There is no
# full catalog to reach from a scoped run any more (E72_S08_T02), and the bounded
# default suite set is only ever the answer to "no rule covered this change",
# never to "the suites that did match were all excluded" — substituting there
# would silently run around the exclusion instead of reporting it.
#
# A DELIBERATE MAP OMISSION IS VISIBLE TOO (fix round of E72_S07_T03, AC4).
# Narrowing makes a map-based omission invisible by construction: the file is
# simply never selected, so nothing lands in `excluded_test_files` and the reader
# sees only "selected N test file(s)". A scope map therefore declares its
# deliberate omissions in `excluded_tests`, map-scope.sh reports them, and this
# gate prints them under "deliberately not selected by the scope map (NOT
# verified, and NOT a pass)" and carries them in `map_excluded_test_files`. A
# declaration subtracts nothing, so one a rule selects anyway lands in
# `map_exclusion_conflicts` rather than being claimed as kept out.
#
# A DECLARED OMISSION THE RUN SUPERSEDES (fix round 3 of E72_S07_T03; the table
# below REWRITTEN by E72_S08_T02). The notice above is only true where the
# exclusion is IN FORCE. It used to be printed on the escalation to the full
# catalog, where it was not: that run executed every declared file, so the gate
# claimed "NOT verified, and NOT a pass" about a file it then ran and passed —
# the same correctness defect as narrowing variant 2, on the one path narrowing
# does not reach.
#
# THE RULE, and it is one rule rather than a list of paths: a declared file this
# run EXECUTES is reported as superseded (it WILL RUN and WILL be verified); a
# declared file this run DOES NOT execute is reported as kept out (NOT verified,
# and NOT a pass). Every declared file gets exactly one of the two, never both
# and never neither. map_excluded_test_files therefore keeps its single meaning
# throughout — files that really were not verified — and a superseded
# declaration is moved OUT of it into map_exclusions_superseded rather than left
# in it with a caveat.
#
# WHY THIS IS NOW KEYED PER DECLARED FILE and no longer, as until E72_S08_T02,
# per path with "never more than one statement per run". That phrasing held only
# while every path either ran ALL the declared files (the escalation to the full
# catalog) or NONE of them (a mapped scoped selection, which by construction
# cannot select a file no rule names). The bounded default suite set is a FOURTH
# combination the old three-row table could not express: the map WAS consulted,
# so a declaration is in hand, but the declared files are NOT run. It takes row
# 1's semantics on a path that is not a scoped selection — and because the floor
# is configured independently of the scope map it may name some declared files
# and not others, which is exactly why "one statement per run" had to become
# "one statement per declared file".
#
#   1. a mapped scoped selection                      effective_mode "scoped"
#      The declared file does not run: no rule names it, so narrowing cannot
#      select it. Said: "deliberately not selected by the scope map (NOT
#      verified, and NOT a pass)".
#        -> map_excluded_test_files; map_exclusions_superseded []
#
#   2. the bounded default suite set                   effective_mode
#      THE ROW E72_S08_T02 ADDS                        "default-set",
#                                                      fallback_reason
#                                                      "no-mapped-suites"
#      The map WAS consulted, so a declaration is in hand, but the floor is
#      configured independently of it. Each declared file is therefore
#      PARTITIONED on whether the floor's resolved selection actually runs it
#      (and survived exclusion): run -> superseded, not run -> kept out. Both
#      statements may appear in one run, each about a DISJOINT set of files.
#      With this repository's configured floor NONE of the three declared files
#      is in test_default_suite_set, so the declaration is back IN FORCE here:
#      map_exclusions_superseded is [] and map_excluded_test_files keeps them
#      all. That is the INVERSE of the escalation this task removed, and the
#      partition is what keeps the statement true either way instead of a
#      hardcoded [].
#        -> map_excluded_test_files and/or map_exclusions_superseded
#
#   3. policy `full` — the map is never consulted      effective_mode "full"
#      The declared file runs, incidentally: it is in the catalog like any other.
#      Nothing is said, because there is no declaration in hand to supersede, and
#      BOTH KEYS ARE []. Not false, but it IS silent: see
#      project/documentation/test-runner.md, "A declared map omission under
#      policy full".
#
#   4. fallback_reason "no-commits" — the map is       effective_mode "scoped"
#      never consulted either
#      Nothing runs at all: this is the explicit non-pass, exit 3. Nothing is
#      said and BOTH KEYS ARE []. Unchanged by E72_S08_T02 except that the path
#      now runs nothing where it used to run the whole catalog.
#
# AN EXCLUSION A SUITE CANNOT HONOUR (fix round of E72_S07_T02). An opaque entry
# point — an npm script whose body narrow-suites.sh could not rewrite — would
# still run the whole test directory, so the file this gate reports as excluded
# would in fact execute, fail for the baseline reason it was excluded over, and
# have that failure attributed to a suite the reader was told had been narrowed.
# narrow-suites.sh therefore disables such a suite while an exclusion is in
# force; the gate names it on stdout and in `disabled_suites`, and never counts
# it as a pass. When that leaves the scoped selection with no runnable entry the
# gate exits 3; there is nothing to fall back to any more (E72_S08_T02), and
# while there was, falling back would have run exactly what was removed. Full
# reasoning:
# project/documentation/scope-gate-npm-fold-double-execution.md.
#
# The suites also skip on their own (they call the same script), which keeps a
# hand-run `bats tests/mirror-*.bats` honest. The gate NEVER relies on that:
# run-suites.sh keys strictly on exit status and a bats `skip` exits 0, so a
# suite-only skip would reach the gate as a pass.
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
#   verdict: exit 0, 1 or 130, and ALSO the exit 3 of the scoped `no-commits`
#   non-pass (added by E72_S08_T02) and of the scoped-equals-full refusal (added
#   by E72_S08_T03), which are verdicts about the scope rather than a broken gate
#   — their objects carry suites_run 0 and exit_code 3. stdout
#   stays empty for exit 2 and for every OTHER exit 3:
#     {"scope":"story","id":"E99_S01","mode":"scoped","effective_mode":"default-set",
#      "fallback_reason":"no-mapped-suites","suites_run":2,"passed":2,"failed":0,
#      "suites":["bats tests (unit)", ...],"exit_code":0,
#      "test_files_run":11,"test_files_available":261,
#      "excluded_test_files":["tests/x.bats"],"exclusion_reason":"the session is ...",
#      "disabled_suites":["npm:test"],
#      "map_excluded_test_files":[{"file":"tests/x.bats","reason":"..."}],
#      "map_exclusion_conflicts":[],"map_exclusions_superseded":[],"refusal":null}
#   mode            what the policy asked for: none, scoped or full.
#   effective_mode  what actually ran, and it has FOUR values, not three:
#                   "none"; "scoped" (the mapped selection ran); "default-set"
#                   (nothing mapped, so the bounded default suite set ran); and
#                   "full" (policy `full`). A scoped run can NEVER report "full"
#                   — that is the escalation E72_S08_T02 removed — which is what
#                   makes the three outcomes tellable apart from the output
#                   alone.
#   fallback_reason null unless the mapped derivation produced nothing, else
#                   "no-commits" (nothing ran, exit 3, effective_mode stays
#                   "scoped") or "no-mapped-suites" (the floor ran,
#                   effective_mode "default-set"). The two values are unchanged,
#                   so a consumer that only told the two causes apart still
#                   works; one that read effective_mode "full" to detect a
#                   fallback now reads "default-set", which is the point.
#   suites_run      number of suites executed; passed / failed their counts (read
#                   from run-suites.sh's summary); suites their labels, in run
#                   order. Under `none` all counts are 0 and suites is [].
#   The last four keys were APPENDED by E72_S07_T02; the keys above them keep
#   their names, order and meaning, so an existing reader is unaffected.
#   test_files_run / test_files_available
#                   how many test files ran out of how many the selection covered
#                   — the numbers that show `scoped` is no longer the whole
#                   catalog. BOTH are null when the run was not narrowed at all
#                   (policy none, or a full run with nothing excluded), which is
#                   deliberately distinct from 0 ("nothing selected").
#   excluded_test_files
#                   every file removed because it cannot pass right now, with
#                   exclusion_reason naming the cause. [] and null when nothing
#                   was excluded. An excluded file never counts toward `passed`.
#   disabled_suites APPENDED by the E72_S07_T02 fix round. Suite ids
#                   narrow-suites.sh set to not-runnable because they could not
#                   honour an exclusion that fired — an opaque npm entry point
#                   whose package.json body is not byte-equal to any narrowable
#                   command, and which would therefore still run the whole test
#                   directory including the excluded file. [] whenever nothing
#                   was disabled. Such a suite is absent from `suites` and from
#                   the pass/fail tally, so it can never read as a pass; it is
#                   also named on stdout with its reason.
#   map_excluded_test_files / map_exclusion_conflicts
#                   APPENDED by the E72_S07_T03 fix round, and SCOPED runs only
#                   (a full run consults no map): both [] otherwise.
#                   map_excluded_test_files is every test file the scope map
#                   DECLARES it deliberately leaves out of every rule, with the
#                   declared reason — the distinction between "deliberately kept
#                   out" and "simply not mapped", which the narrowed selection
#                   alone cannot show. It is a different statement from
#                   excluded_test_files (a file baseline-permissions.sh removed
#                   because it cannot pass right now), and neither key changes
#                   the other. map_exclusion_conflicts names any declared file a
#                   rule selected ANYWAY: a declaration subtracts nothing, so
#                   such a file IS in the run and must not be reported as kept
#                   out — it is listed here instead, never in
#                   map_excluded_test_files. map-scope.sh also warns on it.
#   refusal         APPENDED by E72_S08_T03, the last key: null, or
#                   "scoped-equals-full" when the scoped selection was the entire
#                   runnable catalog and the gate refused (exit 3, suites_run 0).
#   map_exclusions_superseded
#                   APPENDED by fix round 3 of E72_S07_T03; its CONDITION
#                   INVERTED with E72_S08_T02. Declared omissions this run
#                   SUPERSEDED, which means it EXECUTED them: they move out of
#                   map_excluded_test_files into this key, so that key never
#                   names a file the run ran, and are announced on stdout as
#                   WILL RUN rather than as kept out. It is now derived PER FILE
#                   rather than per path: on the "no-mapped-suites" path the
#                   declared files are partitioned on whether the bounded
#                   default suite set actually runs them. That set is configured
#                   independently of the scope map and, with this repository's
#                   configured floor, contains none of the declared files — so
#                   the declaration is back IN FORCE there and this key is []
#                   while map_excluded_test_files keeps them all. BEFORE
#                   E72_S08_T02 that same path ran the whole catalog, so this key
#                   held every declared file; naming a file the floor does not
#                   run would now assert "WILL RUN and WILL be verified" about a
#                   file the run never executes — the same false statement fix
#                   round 3 was written to remove, pointing the other way.
#                   [] under policy `full` and under fallback_reason
#                   "no-commits", where no map is consulted at all and so no
#                   declaration exists to supersede.
#
# EXIT CODES
#   0    gate satisfied: policy none, or every suite that ran passed
#   1    at least one suite failed; the caller must not close the scope. Reserved
#        for test failures, so a caller can tell "tests failed" from "gate broke"
#   2    usage error (nothing ran): missing, unknown or repeated option, missing
#        or unknown --scope, missing --id or an id not well-formed for the scope,
#        both --range and --rev, a --range/--rev git rejects as malformed or as an
#        unknown revision, a --root that is not a directory
#   3    nothing was verified, which is never a pass. THREE KINDS, deliberately
#        sharing the one code E72_S06 gave that meaning:
#        (c) the scoped `scoped-equals-full` REFUSAL (E72_S08_T03): the scoped
#            selection would execute every unit of the catalog a full run
#            executes, so nothing is run. The cause and the remedy are on stdout
#            (stderr with --json) and --json DOES print its object, with
#            refusal "scoped-equals-full", suites_run 0 and effective_mode
#            "scoped". It is also exit 3, "cannot prove the scoped run is smaller
#            than a full run", with stdout empty, when a bats command cannot be
#            expanded safely.
#        (a) the scoped `no-commits` NON-PASS (E72_S08_T02): no commits were found
#            for the id, so no change set could be derived and nothing is run.
#            The reason is on stdout and --json DOES print its object (OUTPUT).
#        (b) infrastructure error, stdout empty: jq or git missing, no git
#            repository for a scoped derivation, the root or a helper script not
#            found, scope-policy / discovery / catalog / map-scope /
#            narrow-suites / resolve-default-suites / run-suites failing for a
#            reason other than a test failing, a `full` catalog with no runnable
#            suite, EVERY selected suite having been emptied by exclusion, a
#            selection whose suites produced no runnable catalog entry at all —
#            what happens when the only mapped suite was an opaque npm one that
#            had to be disabled — or the bounded default suite set failing to
#            resolve: not configured, resolving to no runnable test file, or
#            resolving to the ENTIRE runnable catalog, each with its own message.
#        No scoped path substitutes the full catalog for any of these. The
#        escalation that could is gone (E72_S08_T02), and while it existed it
#        would have run exactly what the exclusion had removed
#        (E72_S07_T02 — nothing verified is never a pass)
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
NARROWER="$SCRIPT_DIR/narrow-suites.sh"
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
# E72_S07_T02: narrowing and exclusion bookkeeping. TEST_FILES_* are -1 when the
# run was not narrowed at all, which JSON reports as null rather than 0 so that
# "not narrowed" can never be misread as "nothing selected".
TEST_FILES_RUN=-1
TEST_FILES_AVAILABLE=-1
EXCLUDED_FILES=""
EXCLUSION_REASON=""
# Suites narrow-suites.sh set to not-runnable because they could not honour an
# exclusion that fired (an opaque npm entry point). Newline separated ids.
DISABLED_SUITES=""
# E72_S07_T03 fix round. Test files the scope map DECLARES it deliberately
# leaves out of every rule (its `excluded_tests`), so a reader can tell a
# deliberate omission from a file that simply was not mapped. A compact JSON
# array of {file, reason}; and, separately, the newline-separated files whose
# declaration is contradicted because a rule selected them anyway.
MAP_EXCLUDED_JSON="[]"
MAP_EXCLUSION_CONFLICTS=""
# E72_S07_T03, fix round 3. Declared omissions the run SUPERSEDED: the scoped
# path found no mapped suite, fell back to the full catalog, and therefore RAN
# the files the map declares it keeps out. They move out of
# map_excluded_test_files (which must only ever hold files that really were not
# verified) and into here, where they are reported as run rather than kept out.
MAP_SUPERSEDED_JSON="[]"
# E72_S08_T02. The name of a function run_selection calls immediately after a
# successful narrow(), which is the one point where both what the run will
# execute and what an exclusion removed are known. Only the bounded default
# suite set path sets it (to partition the map's declared omissions); the scoped
# path leaves it empty, because no rule can select a declared file there.
POST_NARROW_HOOK=""
# E72_S08_T03. The name of the refusal this run ended in, or "" when it ended in
# none. Today there is one value, "scoped-equals-full". It is the --json key
# `refusal`, so a consumer can tell this exit 3 from the other exit 3 kinds.
REFUSAL=""
# The changed files the scoped derivation produced, when it wrote a list (it does
# not for --range/--rev, which map-scope.sh resolves itself). Only used to word
# the cause of a refusal; nothing decides on it.
CHANGED_FILES_LIST=""

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
      --argjson tfrun "$TEST_FILES_RUN" --argjson tfavail "$TEST_FILES_AVAILABLE" \
      --arg excluded "$EXCLUDED_FILES" --arg exreason "$EXCLUSION_REASON" \
      --arg disabled "$DISABLED_SUITES" \
      --argjson mapexcl "$MAP_EXCLUDED_JSON" --arg mapconf "$MAP_EXCLUSION_CONFLICTS" \
      --argjson mapsup "$MAP_SUPERSEDED_JSON" --arg refusal "$REFUSAL" \
      '{scope: $scope, id: $id, mode: $mode, effective_mode: $eff,
        fallback_reason: (if $fr == "" then null else $fr end),
        suites_run: $run, passed: $passed, failed: $failed,
        suites: ($labels | split("\n") | map(select(length > 0))),
        exit_code: $code,
        test_files_run: (if $tfrun < 0 then null else $tfrun end),
        test_files_available: (if $tfavail < 0 then null else $tfavail end),
        excluded_test_files: ($excluded | split("\n") | map(select(length > 0))),
        exclusion_reason: (if $exreason == "" then null else $exreason end),
        disabled_suites: ($disabled | split("\n") | map(select(length > 0))),
        map_excluded_test_files: $mapexcl,
        map_exclusion_conflicts: ($mapconf | split("\n") | map(select(length > 0))),
        map_exclusions_superseded: $mapsup,
        refusal: (if $refusal == "" then null else $refusal end)}'
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

# narrow <in discovery> <out discovery> [<map-scope output>]
#
# E72_S07_T02. Hands the discovery to narrow-suites.sh, which rewrites each
# suite's command to run only the test files that matter and drops files that
# cannot pass while the level-2 baseline precondition is unmet. Sets
# TEST_FILES_RUN / TEST_FILES_AVAILABLE / EXCLUDED_FILES / EXCLUSION_REASON and
# says on stdout what it did, so a gate that went green having skipped something
# can never be mistaken for one that ran it.
#
# With a map-scope output this is the SCOPED narrowing — the fix for `scoped` and
# `full` having been operationally identical (E72_S07_T01). Without one it is the
# FULL path, where narrow-suites.sh only ever removes marked files and is
# otherwise a no-op.
#
# Returns 0 normally, and 1 when every selected suite was emptied by exclusion,
# which the caller must treat as "nothing was verified" (exit 3) and NEVER as a
# pass or as a reason to fall back to the full catalog.
narrow() {
  local in_disc="$1" out_disc="$2" mapped="${3:-}" report="$TMP_DIR/narrow-report.json"
  local rc=0 args line
  args=(--root "$ROOT" --suites "$in_disc" --report "$report")
  [ -z "$mapped" ] || args+=(--mapped-tests "$mapped")
  bash "$NARROWER" "${args[@]}" > "$out_disc" || rc=$?
  if [ "$rc" -ne 0 ]; then
    die 3 "narrow-suites.sh failed with exit status $rc"
  fi

  TEST_FILES_AVAILABLE="$(jq -r '[.narrowed[].available] | add // -1' "$report")"
  TEST_FILES_RUN="$(jq -r '[.narrowed[].selected] | add // -1' "$report")"
  EXCLUDED_FILES="$(jq -r '.excluded[].file' "$report")"
  EXCLUSION_REASON="$(jq -r '.precondition_reason // ""' "$report")"
  DISABLED_SUITES="$(jq -r '.disabled[]?.id' "$report")"

  if [ "$TEST_FILES_AVAILABLE" -ge 0 ] && [ "$TEST_FILES_RUN" -ne "$TEST_FILES_AVAILABLE" ]; then
    say "narrowed to $TEST_FILES_RUN of $TEST_FILES_AVAILABLE test file(s)"
  elif [ "$TEST_FILES_AVAILABLE" -ge 0 ]; then
    say "selected $TEST_FILES_RUN test file(s)"
  fi

  if [ -n "$EXCLUDED_FILES" ]; then
    say "excluded (NOT verified) because $EXCLUSION_REASON:"
    jq -r '.excluded[] | "  - " + .file + ": " + .reason' "$report" | while IFS= read -r line; do
      say "$line"
    done
  fi

  # A suite narrow-suites.sh disabled rather than narrowed. It is not in the
  # catalog at all, so without this line it would simply vanish from the gate
  # output and a reader could not tell it from a suite that ran and passed.
  if [ -n "$DISABLED_SUITES" ]; then
    say "not run (NOT verified) because the suite cannot honour the exclusion:"
    jq -r '.disabled[] | "  - " + .id + ": " + .reason' "$report" | while IFS= read -r line; do
      say "$line"
    done
  fi

  # Every suite the map named was emptied: there is nothing left to verify.
  if [ "$(jq -r '[.narrowed[]] | length' "$report")" -gt 0 ] \
     && [ "$(jq -r '[.narrowed[] | select(.emptied | not)] | length' "$report")" -eq 0 ]; then
    return 1
  fi
  return 0
}

# ---- the standing invariant: a scoped run is never the whole catalog (E72_S08_T03) --------------------
#
# E72_S07 narrowed what `scoped` selects and E72_S08_T02 removed the escalation to the full catalog.
# Both hold by the CONTENT of the scope map and of this script, not by machinery, so a coarse map rule
# or a regression could quietly restore a `scoped` gate that is a `full` one. This is the machinery.
#
# THE DEFINITION, ONE FOR BOTH SIDES. The UNITS of a catalog are what its runnable entries execute:
#   f:<path>     one test file, for every entry whose command is a bare `bats` invocation (the
#                command is expanded exactly as the shell expands it, at the project root, so
#                `bats tests/*.bats` and `bats 'tests/a.bats' 'tests/b.bats'` are the same units
#                whenever they name the same files, whatever their spelling)
#   c:<command>  one opaque unit for every entry that cannot be expanded to files (an npm script
#                whose body is not bats, shellcheck, pytest, ...), identified by its command text.
#                An `npm test` / `npm run <key>` entry is first resolved to its package.json script
#                body, as build-catalog.sh does, so an npm twin of a bats suite is the same units.
# WHAT IS COMPARED. The test FILES, whenever the reference has any. A scope map can only ever select
# a suite through the test files it covers (map-scope.sh's one exception, the .js -> npm extension
# fallback, selects opaque npm suites), so an opaque suite such as shellcheck:all is not something a
# selection can include or leave out: this repository's full catalog is bats:tests plus shellcheck:all,
# and a selection of every one of the 300-odd test files IS the hour-long run the story exists to remove
# even though shellcheck never ran. Comparing opaque suites too would make the invariant vacuous here.
# Refusing in that case is the safe direction, and it is what the task's own example describes
# (a rule mapping `**/*.sh` to `tests/**/*.bats`). Only a reference with NO test file at all (an
# all-opaque catalog) is compared on its opaque commands instead.
# A `scoped` run is REFUSED iff its compared units CONTAIN every compared unit of the reference
# catalog, the catalog a `full` policy would execute. Containment rather than equality, so a run
# that exceeds the reference is refused too. The reference is built by run_full's own steps (narrow-suites.sh in full mode, then
# build-catalog.sh, from the one discovery this run already has), so a file the level-2 baseline
# excludes is excluded from BOTH sides and cannot make a bounded run look whole.
#
# ONE CHOKEPOINT. The check is called at the top of run_catalog, the only caller of run-suites.sh, and
# keys on MODE (written once, before anything is derived) and on the catalog about to be executed.
# It does not key on EFFECTIVE, on which path produced the selection, or on how a command is spelled.
#
# FAIL CLOSED. If a reference or a run entry that looks like a `bats` invocation cannot be expanded
# safely, or the reference has no unit at all, the gate cannot prove the run is bounded and exits 3.
# Guessing here is exactly the escape the previous attempts kept finding.

# is_plain_bats <command>: a bare `bats` invocation whose remaining words are only plain words,
# globs and single-quoted strings, so expanding it with the shell can execute nothing. After the
# single-quoted pieces (and `\'` pairs) are removed, none of | & ; < > ( ) $ ` " ' \ may remain.
is_plain_bats() {
  local rest
  case "$1" in "bats "*) ;; *) return 1 ;; esac
  rest="$(printf '%s' "$1" | sed -e "s/\\\\'//g" -e "s/'[^']*'//g")"
  if printf '%s' "$rest" | grep -q "[|&;<>()\$\`\"'\\\\]"; then
    return 1
  fi
  return 0
}

# expand_bats_files <bats command>: the existing test files the command names, one per line. Only
# ever called on a command is_plain_bats accepted. Directories expand to their *.bats files (all
# below them with -r/--recursive). Options and words that name nothing on disk are ignored.
expand_bats_files() {
  local words="${1#bats }"
  (
    cd "$ROOT" || exit 0
    recursive=0
    # shellcheck disable=SC2086,SC2294
    eval "set -- $words"
    for w in "$@"; do
      case "$w" in -r|--recursive) recursive=1 ;; esac
    done
    for w in "$@"; do
      case "$w" in -*) continue ;; esac
      if [ -d "$w" ]; then
        if [ "$recursive" -eq 1 ]; then
          find "$w" -type f -name '*.bats'
        else
          find "$w" -maxdepth 1 -type f -name '*.bats'
        fi
      elif [ -f "$w" ]; then
        printf '%s\n' "$w"
      fi
    done
  ) | sed 's#^\./##'
}

# catalog_units <catalog> <out>: the byte-sorted unique units of the runnable entries (see above).
# A line starting with `!` marks an entry that could not be enumerated; the caller fails closed.
catalog_units() {
  local catalog="$1" out="$2" id eco cmd eff key body f
  jq -r '.runnable[] | [.id, .ecosystem, .command] | @tsv' "$catalog" \
    | while IFS=$'\t' read -r id eco cmd; do
        eff="$cmd"
        if [ "$eco" = "npm" ]; then
          key=""
          case "$cmd" in
            "npm test"|"npm t") key="test" ;;
            "npm run "*) key="${cmd#npm run }" ;;
            "npm run-script "*) key="${cmd#npm run-script }" ;;
          esac
          if [ -n "$key" ] && [ -f "$ROOT/package.json" ]; then
            body="$(jq -r --arg k "$key" '(.scripts[$k] // "") | if type == "string" then . else "" end' \
                    "$ROOT/package.json" 2>/dev/null || true)"
            [ -z "$body" ] || eff="$body"
          fi
        fi
        if is_plain_bats "$eff"; then
          f="$(expand_bats_files "$eff")"
          if [ -n "$f" ]; then
            printf '%s\n' "$f" | sed 's/^/f:/'
          else
            printf '!:%s\n' "$eff"
          fi
        else
          case "$eff" in
            bats|"bats "*) printf '!:%s\n' "$eff" ;;
            *) printf 'c:%s\n' "$eff" ;;
          esac
        fi
      done > "$out.raw" || return 1
  LC_ALL=C sort -u "$out.raw" > "$out"
}

# explain_scoped_cause: what to change, worded for the path that produced the selection. EFFECTIVE
# is read here to WORD the message and nowhere to decide anything.
explain_scoped_cause() {
  local cfgdir cfg rel map ids line
  if [ "$EFFECTIVE" = "default-set" ]; then
    say "  cause: the bounded default suite set (test_default_suite_set of test-config.json, resolve-default-suites.sh) names, once the exclusions in force are applied, everything a full run executes"
    say "         value: $(jq -r '.default_set.value // "(unknown)"' "$DEFAULT_SET_OUT" 2>/dev/null || printf '(unknown)')"
    return 0
  fi
  ids="$(jq -r '.mapped_suites | join(", ")' "$MAP_FILE_OUT" 2>/dev/null || true)"
  say "  cause: the scope map selected these suite definition(s), which together cover the whole catalog: ${ids:-(none)}"
  jq -r --argjson ids "$(jq -c '.mapped_suites' "$MAP_FILE_OUT")" \
    '.suites[] | select(.id as $i | ($ids | index($i)) != null)
     | "         - " + .id + " (paths: " + ((.paths // []) | if length == 0 then "none, opaque" else join(", ") end) + ")"' \
    "$DISCOVERY_FILE" 2>/dev/null | while IFS= read -r line; do say "$line"; done || true
  if [ -n "$CHANGED_FILES_LIST" ] && [ -s "$CHANGED_FILES_LIST" ]; then
    say "         changed files: $(head -n 5 "$CHANGED_FILES_LIST" | paste -sd ',' - | sed 's/,/, /g')$([ "$(wc -l < "$CHANGED_FILES_LIST")" -gt 5 ] && printf ', ...')"
    cfgdir=""
    [ -z "$RESOLVER" ] || cfgdir="$(JENGA_PROJECT_ROOT="$ROOT" bash "$RESOLVER" get configs 2>/dev/null || true)"
    cfg="${CONFIG_ARG:-$cfgdir/test-config.json}"
    rel=""
    [ ! -f "$cfg" ] || rel="$(jq -r '.commit_scope_map_file // ""' "$cfg" 2>/dev/null || true)"
    map="$ROOT/${rel:-templates/test-scope-map.json}"
    if [ -f "$map" ]; then
      say "         scope map: ${rel:-templates/test-scope-map.json}; rules whose source matches a changed file:"
      jq -r --rawfile f "$CHANGED_FILES_LIST" "$(cat "$SCRIPT_DIR/lib/glob-defs.jq")"'
        ($f | split("\n") | map(select(length > 0))) as $files
        | .rules | to_entries[]
        | any_re([.value.source]) as $re
        | select(any($files[]; matches($re)))
        | "           rule " + ((.key + 1) | tostring) + ": " + .value.source + " -> " + (.value.tests | join(", "))' \
        "$map" 2>/dev/null | head -n 8 | while IFS= read -r line; do say "$line"; done || true
    fi
  else
    say "         (the changed files came from --range/--rev; see the active scope map for the rule that selected them)"
  fi
}

# assert_scoped_is_bounded <catalog about to run>: returns 0 when the run is bounded or the policy
# is not scoped; otherwise REFUSES (prints, sets REFUSAL, finishes 3) and never returns.
assert_scoped_is_bounded() {
  local catalog="$1" disc="$TMP_DIR/discovery-full-reference.json" ref="$TMP_DIR/catalog-full-reference.json"
  local ref_units="$TMP_DIR/units-reference.txt" run_units="$TMP_DIR/units-run.txt" rc=0 total kind
  [ "$MODE" = "scoped" ] || return 0

  bash "$NARROWER" --root "$ROOT" --suites "$DISCOVERY_FILE" > "$disc" || rc=$?
  [ "$rc" -eq 0 ] || die 3 "narrow-suites.sh failed with exit status $rc while building the full-run reference"
  rc=0
  bash "$CATALOG_BUILDER" --root "$ROOT" --discovery-file "$disc" > "$ref" || rc=$?
  [ "$rc" -eq 0 ] || die 3 "build-catalog.sh failed with exit status $rc while building the full-run reference"
  catalog_units "$ref" "$ref_units" || die 3 "could not derive the units of the full-run reference"
  catalog_units "$catalog" "$run_units" || die 3 "could not derive the units of the catalog about to run"

  if [ ! -s "$ref_units" ] || grep -q '^!' "$ref_units" || grep -q '^!' "$run_units"; then
    die 3 "cannot prove the scoped run is smaller than a full run: a bats command could not be expanded to test files, or a full run has nothing to enumerate; nothing was verified, so this is not a pass"
  fi
  # Compare test files when the reference has any (see WHAT IS COMPARED), else opaque commands.
  kind="opaque suite command"
  if grep -q '^f:' "$ref_units"; then
    kind="test file"
    grep '^f:' "$ref_units" > "$ref_units.cmp" || true
    grep '^f:' "$run_units" > "$run_units.cmp" || true
  else
    cp "$ref_units" "$ref_units.cmp"
    cp "$run_units" "$run_units.cmp"
  fi
  if [ -n "$(LC_ALL=C comm -23 "$ref_units.cmp" "$run_units.cmp" | head -n 1)" ]; then
    return 0
  fi

  total="$(wc -l < "$ref_units.cmp" | tr -d ' ')"
  REFUSAL="scoped-equals-full"
  EFFECTIVE="$MODE"
  RUN_COUNT=0
  SUITE_LABELS=""
  say "scope test gate: REFUSED ($SCOPE $ID, policy scoped): the scoped selection is the entire runnable catalog, so nothing was run and nothing was verified (not a pass)"
  say "  a full run would execute $total $kind(s); this run would execute all of them"
  explain_scoped_cause
  if [ "$total" -le 1 ]; then
    say "  this catalog has exactly one $kind, so a scoped run can never be smaller than a full one"
  fi
  say "  remedy: narrow the rule or the suite definition named above so a scoped run selects strictly less, or set test_run_$SCOPE to full deliberately (project/documentation/test-runner.md, 'The standing scoped != full invariant')"
  finish 3
}

# run_catalog <catalog file>: run every runnable suite of the catalog; sets
# RUN_COUNT, PASSED, FAILED, SUITE_LABELS and finishes with the exit code.
run_catalog() {
  local catalog="$1" nums names counts rc=0 out="$TMP_DIR/run.out"
  # The standing scoped != full invariant, at the one point every run goes through.
  assert_scoped_is_bounded "$catalog"
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

# run_selection <selection file> <tmp tag> <singular noun> <plural noun>
#
# E72_S08_T02 EXTRACTED this from the scoped branch below so the bounded default
# suite set can reuse it unchanged. The selection file is map-scope.sh's output
# contract — `mapped_suites` plus `mapped_tests` — and resolve-default-suites.sh
# emits exactly that shape for exactly this reason, so one body serves both paths
# and neither narrow-suites.sh nor build-catalog.sh needed a change. The two
# nouns appear only in the messages, whose wording is per path; the scoped
# path's are byte-identical to what they were before the extraction.
#
# Finishes the script on every exit path: either run_catalog runs (and always
# finishes) or it dies 3 having verified nothing. Never returns.
run_selection() {
  local sel="$1" tag="$2" one="$3" many="$4"
  local derived="$TMP_DIR/discovery-$tag.json"
  local narrowed="$TMP_DIR/discovery-$tag-narrowed.json"
  local catalog="$TMP_DIR/catalog-$tag.json" rc=0

  jq -c --argjson ids "$(jq -c '.mapped_suites' "$sel")" \
    '.suites |= map(select(.id as $i | ($ids | index($i)) != null))' \
    "$DISCOVERY_FILE" > "$derived" || die 3 "could not narrow the discovery to the $many"

  # Filtering the suite LIST above is not narrowing: this repository has ONE bats
  # suite whose command globs the whole tests/ directory, so the filtered list ran
  # all 261 files anyway and `scoped` was identical to `full` (measured in
  # E72_S07_T01). The selection publishes `mapped_tests` precisely so a caller can
  # narrow a run to the files that matter; this is where that is used.
  if ! narrow "$derived" "$narrowed" "$sel"; then
    # Suites DID map (or the floor DID resolve); they were emptied by exclusion.
    # That is "nothing was verified" (exit 3), and nothing is substituted for it:
    # not the full catalog, which no scoped path can reach any more, and not the
    # bounded default set, which answers "no rule covered this change" and never
    # "what did match was all excluded".
    die 3 "every $one was excluded because $EXCLUSION_REASON; nothing was verified, so this is not a pass"
  fi

  if [ -n "$POST_NARROW_HOOK" ]; then
    "$POST_NARROW_HOOK" "$sel"
  fi

  rc=0
  bash "$CATALOG_BUILDER" --root "$ROOT" --discovery-file "$narrowed" > "$catalog" || rc=$?
  [ "$rc" -eq 0 ] || die 3 "build-catalog.sh failed with exit status $rc"
  relay_warnings "$catalog" '.warnings' "catalog: "
  if [ "$(jq -r '.runnable | length' "$catalog")" -gt 0 ]; then
    run_catalog "$catalog"
  fi
  # run_catalog always finishes, so reaching here means suites were selected but
  # the catalog has nothing runnable. Reachable since narrow-suites.sh began
  # disabling an opaque npm suite that cannot honour an exclusion: a selection
  # consisting only of such a suite ends here. Exit 3, never a substitution.
  die 3 "the $many produced no runnable catalog entry; nothing was verified, so this is not a pass"
}

# run_full: discovery -> catalog -> run, for policy `full` ONLY. No scoped path
# reaches it: E72_S08_T02 removed the two escalations that used to.
run_full() {
  local catalog="$TMP_DIR/catalog-full.json" rc=0
  local narrowed_disc="$TMP_DIR/discovery-full-narrowed.json"
  EFFECTIVE="full"
  # `full` means the whole catalog, so there is no selection to narrow here — but
  # a suite that cannot pass while the session is off the level-2 baseline must
  # still be excluded, because `full` is exactly where E72_S07_T01 showed
  # narrowing alone cannot help: a full run has no selection to narrow, so
  # without the exclusion it would keep running the elevated-session cluster and
  # keep failing. The premise that measurement rested on has since moved and the
  # reasoning has not: E72_S08_T01 re-tiered test_run_epic from `full` to `none`,
  # so a `full` gate is no longer the automatic epic one it was measured on — but
  # `full` is still an accepted value of all three keys, reachable whenever a
  # project sets it deliberately, which is precisely why the exclusion stays
  # here. With the precondition satisfied this is a byte-for-byte no-op.
  if ! narrow "$DISCOVERY_FILE" "$narrowed_disc"; then
    die 3 "every suite was excluded because $EXCLUSION_REASON; nothing was verified, so this is not a pass"
  fi
  bash "$CATALOG_BUILDER" --root "$ROOT" --discovery-file "$narrowed_disc" > "$catalog" || rc=$?
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
    CHANGED_FILES_LIST="$FILES_LIST"
    file_count="$(wc -l < "$FILES_LIST" | tr -d ' ')"
    map_args+=(--files-from "$FILES_LIST")
    say "changed files: $file_count file(s) from $commit_count commit(s) of $ID"
  fi
fi

if [ "$NO_COMMITS" -eq 1 ]; then
  # E72_S08_T02. An explicit NON-PASS, not a substitution. No change set could be
  # derived for this id at all, so there is nothing a default set could honestly
  # verify: running one would report a pass for a change nobody could determine
  # (story E72_S08's amended decision 3, which keeps E72_S06's exit-3 "nothing
  # was verified" meaning for exactly this cause). effective_mode stays "scoped"
  # — it must never be able to read "full" — and fallback_reason keeps
  # "no-commits" so a consumer can still tell this cause from the other one.
  #
  # finish, NOT die: this is a verdict about the scope rather than a broken gate,
  # so --json prints the object (suites_run 0, exit_code 3) instead of leaving
  # stdout empty. The map is not consulted on this path at all — this branch is
  # before the map-scope.sh call below — so both map-exclusion keys stay [].
  FALLBACK_REASON="no-commits"
  say "scoped policy: no commits found for $ID; nothing could be derived, so nothing was verified (not a pass)"
  finish 3
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

# E72_S07_T03 AC4, fix round. Narrowing makes a map-based omission INVISIBLE: the
# suite is simply never selected, nothing lands in excluded_test_files, and the
# reader sees only "selected N test file(s)" with no way to tell a file that was
# deliberately kept out from one that was merely not mapped. The map declares its
# deliberate omissions in `excluded_tests`, map-scope.sh reports them as
# `map_excluded_tests`, and they are surfaced here. This is a separate statement
# from `excluded_test_files`, which keeps its own meaning: a file removed by
# baseline-permissions.sh because it cannot pass right now.
#
# A declaration subtracts nothing, so one a rule selects anyway is NOT excluded.
# Those are kept out of map_excluded_test_files and reported separately, so the
# gate can never claim a file was kept out while in fact running it (map-scope.sh
# also warns, relayed just above).
MAP_EXCLUDED_JSON="$(jq -c '[.map_excluded_tests[]? | select(.mapped | not) | {file, reason}]' \
  "$MAP_FILE_OUT")" || die 3 "could not read the scope map exclusions from map-scope.sh output"
MAP_EXCLUSION_CONFLICTS="$(jq -r '.map_excluded_tests[]? | select(.mapped) | .file' "$MAP_FILE_OUT")"

# The notice is DEFERRED until the path is known, and that is the whole point.
#
# It used to print here, unconditionally, before the branch below decided whether
# the exclusion is in force at all. On the escalation to the full catalog it was
# not: that path ran the whole catalog, including every file the map declares it
# keeps out, so the gate printed "NOT verified, and NOT a pass" about a file it
# then executed and passed — the same correctness defect as narrowing variant 2
# ("a file the gate says it skipped was in fact executed"), reappearing on the
# one path the narrowing fix did not reach. In THIS repository that was concrete,
# not theoretical: the declared file is tests/mirror-test-subject-invariant.bats,
# which takes about two hours and mutates the real .publicignore, restoring it
# only in teardown().
#
# E72_S08_T02 removed that escalation, which changes WHICH announcement each path
# gets but not why the notice is deferred — it is still only decidable once the
# path, and now the floor's own selection, is known:
#   a mapped scoped selection       -> "deliberately not selected" (the exclusion
#                                      holds: no rule can select a declared file)
#   the bounded default suite set   -> PARTITIONED per declared file, in
#                                      partition_map_exclusions below: the ones
#                                      the floor runs are superseded, the rest
#                                      stay kept out. In this repository the
#                                      floor runs none of them, so all of them
#                                      stay kept out.
# Silence was the other option and is worse here: a reader who knows the map
# declares an omission would reasonably assume it held, and would get no warning
# before a two-hour .publicignore-mutating suite runs. A supersession is also the
# same CATEGORY of event as map_exclusion_conflicts (a declaration that does not
# hold), which already has its own channel rather than being dropped, so
# reporting it is the consistent choice.
announce_map_exclusions_kept_out() {
  [ "$MAP_EXCLUDED_JSON" != "[]" ] || return 0
  say "deliberately not selected by the scope map (NOT verified, and NOT a pass):"
  printf '%s' "$MAP_EXCLUDED_JSON" | jq -r '.[] | "  - " + .file + ": " + .reason' \
    | while IFS= read -r line; do say "$line"; done
}

# partition_map_exclusions <selection file>: the POST_NARROW_HOOK of the bounded
# default suite set path (E72_S08_T02), and it REPLACES the unconditional
# announce_map_exclusions_superseded that the escalation to the full catalog
# used. That one was right for its path — the full catalog ran every declared
# file, so every declaration really was superseded — and would be WRONG here: the
# floor runs none of them in this repository, so saying "WILL RUN and WILL be
# verified" would reinstate the very false statement fix round 3 of E72_S07_T03
# removed, pointing the other way.
#
# It cannot be settled per path either, only PER FILE: the floor is configured
# independently of the scope map, so it may name some declared files and not
# others. So partition instead of asserting either answer — a declared file this
# run executes is superseded, every other declared file stays kept out — and the
# two invariants hold by construction rather than by configuration:
# map_excluded_test_files never names a file the run ran, and
# map_exclusions_superseded never names a file it did not.
#
# Files an exclusion removed are subtracted, because narrow-suites.sh already
# reports them under excluded_test_files as NOT verified; a file cannot be
# announced as WILL RUN there and as excluded here in the same run.
# shellcheck disable=SC2329  # invoked indirectly, through POST_NARROW_HOOK
partition_map_exclusions() {
  local sel="$1" ran_list parts
  [ "$MAP_EXCLUDED_JSON" != "[]" ] || return 0
  ran_list="$(jq -r '[.mapped_tests[]?[]?] | unique | .[]' "$sel")" \
    || die 3 "could not read the bounded default suite set's test files"
  parts="$(printf '%s' "$MAP_EXCLUDED_JSON" | jq -c --arg ran "$ran_list" --arg excl "$EXCLUDED_FILES" '
      def lines: split("\n") | map(select(length > 0));
      (($ran | lines) - ($excl | lines)) as $r
      | {kept:       [.[] | select(.file as $f | ($r | index($f)) == null)],
         superseded: [.[] | select(.file as $f | ($r | index($f)) != null)]}')" \
    || die 3 "could not partition the scope map's declared omissions"
  MAP_EXCLUDED_JSON="$(printf '%s' "$parts" | jq -c '.kept')"
  MAP_SUPERSEDED_JSON="$(printf '%s' "$parts" | jq -c '.superseded')"

  announce_map_exclusions_kept_out
  if [ "$MAP_SUPERSEDED_JSON" != "[]" ]; then
    say "the scope map's declared omission is NOT in force for the following: the bounded default suite set runs them, so they WILL RUN and WILL be verified:"
    printf '%s' "$MAP_SUPERSEDED_JSON" | jq -r '.[] | "  - " + .file + " (declared omission: " + .reason + ")"' \
      | while IFS= read -r line; do say "$line"; done
  fi
}

if [ "$(jq -r '.mapped_suites | length' "$MAP_FILE_OUT")" -gt 0 ]; then
  # The exclusion IS in force on this path: no rule names a declared file, so
  # narrowing cannot select one, and every exit from this branch is inside it.
  announce_map_exclusions_kept_out
  say "scoped policy: $(jq -r '.mapped_suites | length' "$MAP_FILE_OUT") suite(s) map to the changed files"
  run_selection "$MAP_FILE_OUT" scoped "mapped suite" "mapped suites"
fi

# ---- 5. scoped, nothing mapped: the bounded default suite set (E72_S08_T02) -----------
#
# This used to escalate to the full catalog. It no longer can: a scoped gate that
# amounts to a full run is the whole defect story E72_S08 exists to remove, and
# E72_S07_T03's narrower 61-rule scope map made the escalation fire MORE often,
# not less, by leaving a larger uncovered surface behind the dropped `**/*.sh`
# catch-all.
#
# There IS a change set here — only no rule covers it — so running nothing would
# be the opposite error. What runs instead is the BOUNDED DEFAULT SUITE SET: a
# floor, resolved by resolve-default-suites.sh (E72_S08_T06) from
# `test_default_suite_set` and asserted there to be a non-empty STRICT subset of
# the runnable catalog. Its output is deliberately map-scope.sh-shaped, so it
# goes through run_selection exactly as a mapped selection does.
#
# WHICH OF THE TWO BAD OUTCOMES THIS AVOIDS: both, which is why it is a floor and
# not an exit 3 or an exit 0. It does not WEDGE A SOUND STORY — the escalation's
# exit code was decided by the whole catalog's unrelated pre-existing redness,
# and the scrum master's Rollup Logic holds a story open on any non-zero gate
# exit, so a sound story failed on failures it did not cause (five A/B-verified
# ones in the E28_S20 rapport "story scope gate fails on three pre-existing
# main-side suites", plus the red package-root sweep in the E87_S07_T01 one; both
# under project/rapports/problems/). A small, explicitly configured set
# cannot carry that in. And it does not MASK A STORY WITH NO COVERAGE — something
# is always run and named, and a floor that resolves to nothing, or to
# everything, is refused rather than passed.
FALLBACK_REASON="no-mapped-suites"
EFFECTIVE="default-set"
say "scoped policy: no suite maps to the changed files; running the bounded default suite set instead (never the full catalog)"

DEFAULT_RESOLVER="$SCRIPT_DIR/resolve-default-suites.sh"
[ -f "$DEFAULT_RESOLVER" ] \
  || die 3 "could not locate resolve-default-suites.sh next to $SCRIPT_NAME, so the bounded default suite set cannot be resolved; nothing was verified, so this is not a pass"
DEFAULT_SET_OUT="$TMP_DIR/default-set.json"
default_args=(--root "$ROOT" --suites "$DISCOVERY_FILE")
if [ -n "$CONFIG_ARG" ]; then
  default_args+=(--config "$CONFIG_ARG")
fi
rc=0
bash "$DEFAULT_RESOLVER" "${default_args[@]}" > "$DEFAULT_SET_OUT" || rc=$?
# Every way the floor can fail to resolve is exit 3 with its OWN message, so the
# reader is told which misconfiguration it is. None of them is a pass, and none
# of them falls through to anything.
case "$rc" in
  0) ;;
  4) die 3 "no suite maps to the changed files and the bounded default suite set is not configured (test_default_suite_set in test-config.json is absent, null or empty); nothing was verified, so this is not a pass" ;;
  5) die 3 "no suite maps to the changed files and the configured bounded default suite set resolves to no runnable test file; nothing was verified, so this is not a pass" ;;
  6) die 3 "no suite maps to the changed files and the configured bounded default suite set resolves to the ENTIRE runnable catalog, which is refused as a misconfiguration rather than run (a scoped gate must never amount to a full one); nothing was verified, so this is not a pass" ;;
  3) die 3 "no suite maps to the changed files and the configured bounded default suite set is invalid (see resolve-default-suites.sh's message above); nothing was verified, so this is not a pass" ;;
  *) die 3 "resolve-default-suites.sh failed with exit status $rc" ;;
esac
relay_warnings "$DEFAULT_SET_OUT" '.warnings' "default suite set: "
say "bounded default suite set: $(jq -r '.mapped_suites | join(", ")' "$DEFAULT_SET_OUT") ($(jq -r '.default_set.files_selected' "$DEFAULT_SET_OUT") of $(jq -r '.default_set.files_available' "$DEFAULT_SET_OUT") runnable test file(s), from test_default_suite_set)"
# The declared omissions are partitioned AFTER narrowing, where both what will
# run and what an exclusion removed are known. See partition_map_exclusions.
POST_NARROW_HOOK=partition_map_exclusions
run_selection "$DEFAULT_SET_OUT" default-set "suite of the bounded default suite set" "bounded default suite set"
