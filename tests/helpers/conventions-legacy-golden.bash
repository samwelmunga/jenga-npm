#!/usr/bin/env bash
#
# Shared case library for the legacy conventions golden outputs (E79_S03_T01).
#
# Purpose
# -------
# Epic E79 adds opt-in settings (commit-format.template, commit-trace) to the conventions machinery. A project that
# configures neither must behave byte for byte as it does today. This library defines the commands that pin that
# behaviour. It is used in two places and nowhere else:
#
#   tests/helpers/capture-conventions-legacy-golden.sh   renders every case and WRITES the goldens (deliberate, by hand)
#   tests/conventions-legacy-regression.bats             renders every case and COMPARES it with the goldens (cmp)
#
# Because both call the same renderer, the goldens are the real scripts' output, never hand-written expectations, and
# the comparison is on exactly the bytes that were captured.
#
# A "case" is a name plus a body (see clg_case). Rendering a case creates a fresh scratch project, runs the real
# scripts against it and writes one framed file:
#
#   $ <command line>          (normalised, one frame per command)
#   --- stdout
#   <bytes>
#   --- stderr
#   <bytes>
#   --- exit
#   <status>
#   === file <path>           (only where a case dumps a file the scripts wrote)
#
# Normalisation (scratch paths, the random draft-file suffix) is applied here, while rendering, so that it happens
# before capture and the comparison is a plain cmp of two already-normalised files.
#
# Scripts pinned (the full set that reads templates/conventions-schema.json, found with
# `grep -rl conventions-schema scripts skills`, plus one dependent consumer):
#   scripts/validate-conventions.sh
#   scripts/conventions-digest.sh
#   scripts/generate-convention-checklist.sh
#   skills/j-conventions/scripts/conventions-entry.sh
#   skills/j-conventions/scripts/detect-conventions.sh
#   skills/j-commit/scripts/commit-subject-check.sh   (reads conventions.json through the validator)
#
# Sourced, never executed. No top-level side effects except variable definitions. Compatible with macOS bash 3.2.
#
# Callers set CLG_WORK (an existing scratch directory they own) before calling any clg_ function.

CLG_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLG_GOLDEN_DIR_DEFAULT="$CLG_REPO/tests/fixtures/conventions-legacy-golden"

# The 9 core category ids, pinned here on purpose: the story promises they do not change, so a change must show up.
CLG_CATEGORIES="branching code-comments commit-format documentation-placement file-layout formatting-linting language-tooling naming testing"

CLG_VALIDATE="$CLG_REPO/scripts/validate-conventions.sh"
CLG_DIGEST="$CLG_REPO/scripts/conventions-digest.sh"
CLG_GENERATE="$CLG_REPO/scripts/generate-convention-checklist.sh"
CLG_ENTRY="$CLG_REPO/skills/j-conventions/scripts/conventions-entry.sh"
CLG_DETECT="$CLG_REPO/skills/j-conventions/scripts/detect-conventions.sh"
CLG_SUBJECT="$CLG_REPO/skills/j-commit/scripts/commit-subject-check.sh"
CLG_PRESETS="$CLG_REPO/templates/conventions-presets.json"

# --- the case list ------------------------------------------------------------------------------------------------

# clg_cases: every case name, one per line, in a fixed order.
clg_cases() {
  local c
  printf '%s\n' \
    validate-all9 validate-empty validate-fmt-only validate-fmt-custom validate-invalid validate-malformed \
    validate-missing-file validate-no-args validate-unknown-option validate-presets
  printf '%s\n' \
    digest-all9-none digest-all9-developer digest-all9-tester digest-all9-scrum-master digest-all9-commit \
    digest-all9-none-max4 digest-all9-developer-max4 digest-all9-commit-max4 digest-all9-developer-max5 \
    digest-empty-none digest-empty-developer digest-fmt-only-none digest-fmt-only-developer digest-fmt-only-commit \
    digest-fmt-custom-commit digest-no-file digest-invalid digest-bad-agent
  printf '%s\n' \
    generate-print-all9 generate-print-empty generate-print-fmt-only generate-print-fmt-custom \
    generate-print-no-file generate-print-invalid
  printf '%s\n' entry-categories-lines entry-categories-json entry-presets-unknown
  for c in $CLG_CATEGORIES; do printf 'entry-presets-%s\n' "$c"; done
  printf '%s\n' \
    entry-path entry-show-none entry-show-all9 entry-show-fmt-only entry-show-category-present \
    entry-show-category-absent entry-check entry-write-flow entry-write-flow-rejections
  printf '%s\n' detect-empty-dir
  printf '%s\n' \
    subject-board subject-board-chore-scope subject-non-board-ok subject-non-board-bad subject-non-board-too-long \
    subject-no-convention subject-empty-convention subject-invalid-convention
}

# --- scratch project, environment, normalisation ------------------------------------------------------------------

# clg_new_project: a fresh scratch project (workflow.json registry only) and a clean environment. Re-run per case.
clg_new_project() {
  # Canonicalise the scratch root (a TMPDIR with a trailing slash yields "T//x", and macOS /var is a symlink), so the
  # path the scripts print is the one the normaliser replaces.
  CLG_WORK="$(cd "$CLG_WORK" && pwd -P)" || return 2
  CLG_PROJ="$CLG_WORK/proj"
  CLG_TMP="$CLG_WORK/tmp"
  CLG_CFG="$CLG_PROJ/project/configs"
  rm -rf "$CLG_PROJ" "$CLG_TMP"
  mkdir -p "$CLG_CFG" "$CLG_TMP"
  printf '{}\n' > "$CLG_CFG/workflow.json"
  unset JENGA_CONVENTIONS_SCHEMA JENGA_CONVENTIONS_PRESETS JENGA_CONVENTIONS_GENERATOR JENGA_CONVENTIONS_CHECKLIST_MAP
  unset JENGA_CONVENTIONS_DIGEST_MAX_LINES JENGA_CHECKLISTS_DEFAULT_FILE JENGA_CHECKLISTS_FILE
  unset WITH_LOCK_TIMEOUT_SECONDS WITH_LOCK_POLL_SECONDS WITH_LOCK_STALE_SECONDS
  export JENGA_PROJECT_ROOT="$CLG_PROJ"
  export TMPDIR="$CLG_TMP"
  # A scratch tree must never be mistaken for part of a git repository by the detector.
  export GIT_CEILING_DIRECTORIES="$CLG_WORK"
  clg_write_normaliser
}

# clg_sed_escape <literal>: the literal, escaped for use inside a sed s||| pattern.
clg_sed_escape() {
  printf '%s' "$1" | sed 's/[][\\.*^$|]/\\&/g'
}

# clg_write_normaliser: write $CLG_WORK/norm.sed. Longest/most specific roots first; the physical (pwd -P) form of
# each root is replaced as well, because macOS temp directories are symlinked (/var -> /private/var).
clg_write_normaliser() {
  local f="$CLG_WORK/norm.sed" pair name dir phys
  : > "$f"
  for pair in "PROJ:$CLG_PROJ" "TMP:$CLG_TMP" "WORK:$CLG_WORK" "REPO:$CLG_REPO"; do
    name="${pair%%:*}"
    dir="${pair#*:}"
    phys="$(cd "$dir" && pwd -P)"
    printf 's|%s|@%s@|g\n' "$(clg_sed_escape "$phys")" "$name" >> "$f"
    if [ "$phys" != "$dir" ]; then
      printf 's|%s|@%s@|g\n' "$(clg_sed_escape "$dir")" "$name" >> "$f"
    fi
  done
  printf 's|conventions-draft\\.[A-Za-z0-9]\\{6\\}|conventions-draft.@RAND@|g\n' >> "$f"
  # Platform noise, not script output: with the digest cap at 4 the script runs `head -n 0`, which BSD/macOS head
  # rejects ("illegal line count -- 0", stdout and exit status are unaffected) and GNU head accepts silently. The line
  # is dropped so the goldens are identical on both. (A latent portability defect in conventions-digest.sh, reported
  # in the E79_S03_T01 execution summary; this task changes no existing script.)
  printf '/^head: illegal line count -- 0$/d\n' >> "$f"
}

# clg_norm: stdin to stdout with scratch paths replaced.
clg_norm() {
  # `env` on purpose: a function whose only command is a bare `LC_ALL=C sed ...` segfaults when it runs inside a
  # subshell under bash 5.3.20 (found by the E79_S03_T01 tester through `run compare_case`). Going through `env` is
  # equivalent and avoids it.
  env LC_ALL=C sed -f "$CLG_WORK/norm.sed"
}

# --- fixtures -----------------------------------------------------------------------------------------------------

# clg_fixture <name>: write $CLG_CFG/conventions.json for a named fixture.
clg_fixture() {
  local f="$CLG_CFG/conventions.json"
  case "$1" in
    none)
      rm -f "$f"
      ;;
    all9)
      # All 9 categories, built from the first shipped preset of each (as tests/conventions-generator.bats does).
      jq '{conventions_version: 1, categories: (.categories | to_entries | map({key: .key, value: {source: "preset", preset: .value[0].id, summary: .value[0].label, values: .value[0].values}}) | from_entries)}' "$CLG_PRESETS" > "$f"
      ;;
    empty)
      printf '{"conventions_version":1,"categories":{}}\n' > "$f"
      ;;
    fmt-only)
      jq '{conventions_version: 1, categories: {"commit-format": (.categories["commit-format"][0] | {source: "preset", preset: .id, summary: .label, values: .values})}}' "$CLG_PRESETS" > "$f"
      ;;
    fmt-custom)
      jq -n '{conventions_version: 1, categories: {"commit-format": {source: "custom", summary: "Tracker key then summary", values: {style: "tracker-key", message_regex: "^[A-Z]+-[0-9]+ .+", subject_max_length: 50}}}}' > "$f"
      ;;
    invalid)
      # Several independent problems, none of which this epic makes valid (no "template", no "commit-trace").
      jq -n '{conventions_version: 1, extra_key: true, categories: {
               "not-a-category": {source: "custom", summary: "x", values: {a: "b"}},
               "commit-format": {source: "custom", summary: "x", strength: "block", values: {style: "s", colour: "red", subject_max_length: "seventy"}},
               "naming": {source: "bogus", summary: "x", values: {identifier_case: "camelCase"}},
               "testing": "not-an-object"}}' > "$f"
      ;;
    malformed)
      printf '{ "conventions_version": 1, "categories": \n' > "$f"
      ;;
    *)
      printf 'clg_fixture: unknown fixture %s\n' "$1" >&2
      return 2
      ;;
  esac
}

# --- command runner -----------------------------------------------------------------------------------------------

# clg_exec <command...>: run the command in the scratch project (stdin closed), append one normalised frame to
# $CLG_OUT, and leave the status in CLG_RC and the raw stdout file path in CLG_STDOUT.
clg_exec() {
  local so="$CLG_WORK/so" se="$CLG_WORK/se"
  # `&& ... || ...` keeps a non-zero exit of the command under test from tripping errexit in a bats test.
  ( cd "$CLG_PROJ" && env LC_ALL=C "$@" ) < /dev/null > "$so" 2> "$se" && CLG_RC=0 || CLG_RC=$?
  CLG_STDOUT="$so"
  {
    printf '$ %s\n' "$(printf '%s' "$*" | clg_norm)"
    printf -- '--- stdout\n'
    clg_norm < "$so"
    printf -- '--- stderr\n'
    clg_norm < "$se"
    printf -- '--- exit\n%s\n' "$CLG_RC"
  } >> "$CLG_OUT"
}

# clg_dump <path relative to the scratch project>: append the file's normalised bytes, or a marker when absent.
clg_dump() {
  {
    printf '=== file %s\n' "$1"
    if [ -f "$CLG_PROJ/$1" ]; then clg_norm < "$CLG_PROJ/$1"; else printf '(absent)\n'; fi
  } >> "$CLG_OUT"
}

# --- the case bodies ----------------------------------------------------------------------------------------------

# clg_digest <fixture> <agent|-> [env assignment...]: one digest case.
clg_digest() {
  local fixture="$1" agent="$2" a=""
  shift 2
  clg_fixture "$fixture" || return 2
  [ "$agent" = "-" ] || a="--agent $agent"
  # shellcheck disable=SC2086
  clg_exec env "$@" bash "$CLG_DIGEST" $a
}

# clg_case <name>: run the named case's commands. Returns 2 for an unknown name.
clg_case() {
  local id first
  case "$1" in
    validate-all9)          clg_fixture all9;      clg_exec bash "$CLG_VALIDATE" project/configs/conventions.json ;;
    validate-empty)         clg_fixture empty;     clg_exec bash "$CLG_VALIDATE" project/configs/conventions.json ;;
    validate-fmt-only)      clg_fixture fmt-only;  clg_exec bash "$CLG_VALIDATE" project/configs/conventions.json ;;
    validate-fmt-custom)    clg_fixture fmt-custom; clg_exec bash "$CLG_VALIDATE" project/configs/conventions.json ;;
    validate-invalid)       clg_fixture invalid;   clg_exec bash "$CLG_VALIDATE" project/configs/conventions.json ;;
    validate-malformed)     clg_fixture malformed; clg_exec bash "$CLG_VALIDATE" project/configs/conventions.json ;;
    validate-missing-file)  clg_exec bash "$CLG_VALIDATE" project/configs/conventions.json ;;
    validate-no-args)       clg_exec bash "$CLG_VALIDATE" ;;
    validate-unknown-option) clg_exec bash "$CLG_VALIDATE" --bogus ;;
    validate-presets)       clg_exec bash "$CLG_VALIDATE" --presets "$CLG_PRESETS" ;;

    digest-all9-none)           clg_digest all9 - ;;
    digest-all9-developer)      clg_digest all9 developer ;;
    digest-all9-tester)         clg_digest all9 tester ;;
    digest-all9-scrum-master)   clg_digest all9 scrum-master ;;
    digest-all9-commit)         clg_digest all9 commit ;;
    digest-all9-none-max4)      clg_digest all9 - JENGA_CONVENTIONS_DIGEST_MAX_LINES=4 ;;
    digest-all9-developer-max4) clg_digest all9 developer JENGA_CONVENTIONS_DIGEST_MAX_LINES=4 ;;
    digest-all9-commit-max4)    clg_digest all9 commit JENGA_CONVENTIONS_DIGEST_MAX_LINES=4 ;;
    digest-all9-developer-max5) clg_digest all9 developer JENGA_CONVENTIONS_DIGEST_MAX_LINES=5 ;;
    digest-empty-none)          clg_digest empty - ;;
    digest-empty-developer)     clg_digest empty developer ;;
    digest-fmt-only-none)       clg_digest fmt-only - ;;
    digest-fmt-only-developer)  clg_digest fmt-only developer ;;
    digest-fmt-only-commit)     clg_digest fmt-only commit ;;
    digest-fmt-custom-commit)   clg_digest fmt-custom commit ;;
    digest-no-file)             clg_digest none developer ;;
    digest-invalid)             clg_digest invalid developer ;;
    digest-bad-agent)           clg_digest all9 nobody ;;

    generate-print-all9)        clg_fixture all9;      clg_exec bash "$CLG_GENERATE" --print ;;
    generate-print-empty)       clg_fixture empty;     clg_exec bash "$CLG_GENERATE" --print ;;
    generate-print-fmt-only)    clg_fixture fmt-only;  clg_exec bash "$CLG_GENERATE" --print ;;
    generate-print-fmt-custom)  clg_fixture fmt-custom; clg_exec bash "$CLG_GENERATE" --print ;;
    generate-print-no-file)     clg_fixture none;      clg_exec bash "$CLG_GENERATE" --print ;;
    generate-print-invalid)     clg_fixture invalid;   clg_exec bash "$CLG_GENERATE" --print ;;

    entry-categories-lines)     clg_exec bash "$CLG_ENTRY" categories ;;
    entry-categories-json)      clg_exec bash "$CLG_ENTRY" categories --format json ;;
    entry-presets-unknown)      clg_exec bash "$CLG_ENTRY" presets not-a-category ;;
    entry-presets-*)
      id="${1#entry-presets-}"
      case " $CLG_CATEGORIES " in *" $id "*) ;; *) printf 'clg_case: unknown case %s\n' "$1" >&2; return 2 ;; esac
      clg_exec bash "$CLG_ENTRY" presets "$id"
      ;;
    entry-path)                 clg_exec bash "$CLG_ENTRY" path ;;
    entry-show-none)            clg_fixture none;      clg_exec bash "$CLG_ENTRY" show ;;
    entry-show-all9)            clg_fixture all9;      clg_exec bash "$CLG_ENTRY" show ;;
    entry-show-fmt-only)        clg_fixture fmt-only;  clg_exec bash "$CLG_ENTRY" show ;;
    entry-show-category-present) clg_fixture fmt-only; clg_exec bash "$CLG_ENTRY" show --category commit-format ;;
    entry-show-category-absent) clg_fixture fmt-only;  clg_exec bash "$CLG_ENTRY" show --category naming ;;
    entry-check)
      clg_exec bash "$CLG_ENTRY" check commit-format subject_max_length 72
      clg_exec bash "$CLG_ENTRY" check commit-format subject_max_length abc
      clg_exec bash "$CLG_ENTRY" check commit-format style ""
      clg_exec bash "$CLG_ENTRY" check commit-format colour red
      clg_exec bash "$CLG_ENTRY" check naming identifier_case camelCase
      clg_exec bash "$CLG_ENTRY" check formatting-linting lint_command "<lint command>"
      clg_exec bash "$CLG_ENTRY" check summary "one tidy line"
      clg_exec bash "$CLG_ENTRY" check summary ""
      clg_exec bash "$CLG_ENTRY" check not-a-category style x
      ;;
    entry-write-flow)
      # The write path: draft-init, draft-set (custom and preset), draft-diff, commit, and a no-change re-commit.
      clg_fixture none
      first="$(jq -r '.categories.naming[0].id' "$CLG_PRESETS")"
      clg_exec bash "$CLG_ENTRY" draft-init
      id="$(cat "$CLG_STDOUT")"
      clg_exec bash "$CLG_ENTRY" draft-set commit-format --draft "$id" --source custom --summary "Tracker key then summary" \
        --value style=tracker-key --value 'message_regex=^[A-Z]+-[0-9]+ .+' --value subject_max_length=50
      clg_exec bash "$CLG_ENTRY" draft-set naming --draft "$id" --source preset --preset "$first"
      clg_exec bash "$CLG_ENTRY" draft-set testing --draft "$id" --source custom --summary "unit tests for new logic" --value 'expectation=unit tests'
      clg_exec bash "$CLG_ENTRY" draft-skip testing --draft "$id"
      clg_exec bash "$CLG_ENTRY" draft-diff --draft "$id" --format text
      clg_exec bash "$CLG_ENTRY" draft-diff --draft "$id"
      clg_exec bash "$CLG_ENTRY" commit --draft "$id"
      clg_dump project/configs/conventions.json
      clg_exec bash "$CLG_ENTRY" draft-init
      id="$(cat "$CLG_STDOUT")"
      clg_exec bash "$CLG_ENTRY" commit --draft "$id"
      clg_dump project/configs/conventions.json
      ;;
    entry-write-flow-rejections)
      clg_fixture none
      clg_exec bash "$CLG_ENTRY" draft-init
      id="$(cat "$CLG_STDOUT")"
      clg_exec bash "$CLG_ENTRY" draft-set commit-format --draft "$id" --source custom --summary "x" --value style=s --strength block
      clg_exec bash "$CLG_ENTRY" draft-set commit-format --draft "$id" --source custom --summary "x" --value style=s --value subject_max_length=abc
      clg_exec bash "$CLG_ENTRY" draft-set commit-format --draft "$id" --source custom --summary "x" --value style=s --value colour=red
      clg_exec bash "$CLG_ENTRY" draft-set not-a-category --draft "$id" --source custom --summary "x" --value a=b
      clg_exec bash "$CLG_ENTRY" draft-show --draft "$id"
      clg_exec bash "$CLG_ENTRY" commit --draft "$id"
      clg_dump project/configs/conventions.json
      ;;

    detect-empty-dir)           clg_exec bash "$CLG_DETECT" ;;

    subject-board)              clg_fixture fmt-custom; clg_exec bash "$CLG_SUBJECT" "task(E79_S03_T01): pin legacy behaviour" ;;
    subject-board-chore-scope)  clg_fixture fmt-custom; clg_exec bash "$CLG_SUBJECT" "chore(E79_S03_T01): add rapport" ;;
    subject-non-board-ok)       clg_fixture fmt-custom; clg_exec bash "$CLG_SUBJECT" "ASD-001 add retry" ;;
    subject-non-board-bad)      clg_fixture fmt-custom; clg_exec bash "$CLG_SUBJECT" "add retry" ;;
    subject-non-board-too-long) clg_fixture fmt-custom; clg_exec bash "$CLG_SUBJECT" "ASD-001 add retry to the client with a rather long explanation" ;;
    subject-no-convention)      clg_fixture none;       clg_exec bash "$CLG_SUBJECT" "add retry" ;;
    subject-empty-convention)   clg_fixture empty;      clg_exec bash "$CLG_SUBJECT" "add retry" ;;
    subject-invalid-convention) clg_fixture invalid;    clg_exec bash "$CLG_SUBJECT" "add retry" ;;

    *)
      printf 'clg_case: unknown case %s\n' "$1" >&2
      return 2
      ;;
  esac
}

# clg_render <case> <output file>: render one case into a fresh scratch project. The output is written as a whole.
clg_render() {
  CLG_OUT="$2"
  : > "$CLG_OUT"
  clg_new_project || return 2
  clg_case "$1"
}
