#!/usr/bin/env bats
#
# E80_S01_T07: guard that no scripts/workflow/*.sh hardcodes a working-file path literal (story E80_S01, AC 7).
#
# tests/workflow-lib.bats only sees lib.sh. This file is the other half: it scans EVERY file matching the glob
# scripts/workflow/*.sh (no hand-maintained list, so a script added later is checked automatically) and fails when
# any of them carries a project/ working-file path literal (project/.workflows, project/configs, project/board, ...)
# on a non-comment line. Locations must come from lib.sh (which resolves the working-file tree through the
# registry), not from a path typed into a script.
#
# Scan rules
#   - A "comment line" is one whose first non-blank character is '#' (this includes the shebang). Comment lines
#     describe the layout and are ignored. A trailing comment after code is NOT stripped: code that merely
#     mentions a path in a trailing comment is flagged, which is the strict, safe direction.
#   - Rule A: no non-comment line of any scripts/workflow/*.sh contains the literal "project/".
#   - Rule B: validate-workflow.sh and load-workflows.sh must source lib.sh on a non-comment line.
#   - Rule C: no script other than lib.sh names the consumer-install package path (node_modules plus the
#     @jenga-ai/agent scope) on a non-comment line. lib.sh is the one place that fallback lives.
#
# Known exemptions to Rule C (see KNOWN_FALLBACK_COPIES below and the E80_S01_T07 summary): step-skill.sh and
# verify-output.sh (both landed under E80_S03) each still carry their own copy of the consumer-install fallback.
# They are listed by name, so the rule is NOT weakened for any other script, present or future. A staleness
# test fails once an exempt script stops naming the path, forcing the exemption to be deleted.
#
# The scan is a function, so the negative self-check runs the very same logic against a synthetic offender.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
WF_DIR="$REPO_ROOT/scripts/workflow"

# Scripts allowed to name the consumer-install package path themselves (Rule C), until moved onto lib.sh.
KNOWN_FALLBACK_COPIES="step-skill.sh verify-output.sh"

# Prints "<file>:<line>:<text>" for each non-comment line of $1 that contains the literal $2. Prints nothing when
# the file is clean. Always returns 0; callers assert on the output.
scan_literal() {
  local file="$1" needle="$2"
  grep -n -F -e "$needle" "$file" | grep -v -E '^[0-9]+:[[:space:]]*#' | sed "s|^|$file:|" || true
}

# Rule A over one file.
scan_project_literal() {
  scan_literal "$1" "project/"
}

# Rule C over one file.
scan_package_path() {
  scan_literal "$1" "node_modules/@jenga-ai/agent"
}

# Succeeds when $1 has a non-comment line that sources lib.sh (". .../lib.sh" or "source .../lib.sh").
sources_lib() {
  grep -v -E '^[[:space:]]*#' "$1" | grep -E '^[[:space:]]*(\.|source)[[:space:]]+.*lib\.sh' >/dev/null
}

is_known_fallback_copy() {
  local name
  for name in $KNOWN_FALLBACK_COPIES; do
    [ "$name" = "$1" ] && return 0
  done
  return 1
}

# --- discovery ---------------------------------------------------------------------------------------------

@test "the glob finds the workflow scripts, including lib.sh" {
  local files=("$WF_DIR"/*.sh)
  [ "${#files[@]}" -ge 3 ]
  [ -f "$WF_DIR/lib.sh" ]
  [ -f "$WF_DIR/validate-workflow.sh" ]
  [ -f "$WF_DIR/load-workflows.sh" ]
}

# --- Rule A: no project/ literal in any script -------------------------------------------------------------

@test "no scripts/workflow/*.sh has a project/ path literal on a non-comment line" {
  local f found="" out
  for f in "$WF_DIR"/*.sh; do
    out="$(scan_project_literal "$f")"
    if [ -n "$out" ]; then
      found="$found$out
"
    fi
  done
  if [ -n "$found" ]; then
    echo "hardcoded project/ path literal(s) in workflow scripts:" >&2
    echo "$found" >&2
  fi
  [ -z "$found" ]
}

# --- Rule B: the two core scripts take their locations from lib.sh -----------------------------------------

@test "validate-workflow.sh sources lib.sh" {
  sources_lib "$WF_DIR/validate-workflow.sh"
}

@test "load-workflows.sh sources lib.sh" {
  sources_lib "$WF_DIR/load-workflows.sh"
}

# --- Rule C: only lib.sh names the consumer-install package path -------------------------------------------

@test "no script other than lib.sh (and the named exemptions) names the consumer-install package path" {
  local f name found="" out
  for f in "$WF_DIR"/*.sh; do
    name="$(basename "$f")"
    [ "$name" = "lib.sh" ] && continue
    is_known_fallback_copy "$name" && continue
    out="$(scan_package_path "$f")"
    if [ -n "$out" ]; then
      found="$found$out
"
    fi
  done
  if [ -n "$found" ]; then
    echo "consumer-install package path named outside lib.sh:" >&2
    echo "$found" >&2
  fi
  [ -z "$found" ]
}

@test "lib.sh itself still names the consumer-install package path (the fallback lives there)" {
  run scan_package_path "$WF_DIR/lib.sh"
  [ -n "$output" ]
}

@test "every named exemption still exists and still names the path (stale exemptions must be deleted)" {
  local name
  for name in $KNOWN_FALLBACK_COPIES; do
    [ -f "$WF_DIR/$name" ]
    run scan_package_path "$WF_DIR/$name"
    [ -n "$output" ]
  done
}

# --- negative self-checks: the scan must report a violation, not match nothing -------------------------------

@test "self-check: a synthetic script with project/.workflows is reported by the project/ scan" {
  local bad="$BATS_TEST_TMPDIR/bad.sh"
  printf '#!/usr/bin/env bash\nDIR="$ROOT/project/.workflows"\nls "$DIR"\n' > "$bad"
  run scan_project_literal "$bad"
  [ -n "$output" ]
  assert_output_contains "project/.workflows"
  assert_output_contains "bad.sh:2:"
}

@test "self-check: a project/ mention in a comment line of a synthetic script is not reported" {
  local ok="$BATS_TEST_TMPDIR/ok.sh"
  printf '#!/usr/bin/env bash\n# layout: project/.workflows holds the local definitions\n    # project/configs too\nls "$DIR"\n' > "$ok"
  run scan_project_literal "$ok"
  [ -z "$output" ]
}

@test "self-check: a synthetic script naming the package path is reported, and one that does not source lib.sh fails" {
  local bad="$BATS_TEST_TMPDIR/bad2.sh"
  printf '#!/usr/bin/env bash\nP="$A/node_modules/@jenga-ai/agent/skills"\n' > "$bad"
  run scan_package_path "$bad"
  [ -n "$output" ]
  assert_output_contains "bad2.sh:2:"
  run sources_lib "$bad"
  [ "$status" -ne 0 ]
}

@test "self-check: sources_lib accepts both '.' and 'source' forms and ignores a commented one" {
  local a="$BATS_TEST_TMPDIR/a.sh" b="$BATS_TEST_TMPDIR/b.sh" c="$BATS_TEST_TMPDIR/c.sh"
  printf '. "$D/lib.sh" || exit 2\n' > "$a"
  printf 'source "$D/lib.sh"\n' > "$b"
  printf '# . "$D/lib.sh"\n' > "$c"
  sources_lib "$a"
  sources_lib "$b"
  run sources_lib "$c"
  [ "$status" -ne 0 ]
}
