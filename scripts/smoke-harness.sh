#!/usr/bin/env bash
# smoke-harness.sh — the self-check j.do runs on inline, light and --trivial tasks (E95_S01_T01)
#
# Usage:
#   bash scripts/smoke-harness.sh [changed_file ...]
#
# Changed files are the positional arguments when given, else `git diff --name-only HEAD`.
#
# It runs only what the project opted into, in this order (first match wins):
#   1. scripts/smoke.sh present  — delegate to it and return its exit status.
#   2. docs-only change          — every changed file ends in .md or .txt (and there is at least
#                                  one): run nothing, print
#                                  `smoke-harness: docs-only change, no suite run`, exit 0.
#   3. project scope map present — the file `commit_scope_map_file` names in the project's own
#                                  test-config.json (configs directory resolved through
#                                  scripts/resolve-root.sh). A shipped default under templates/ or
#                                  node_modules/ does not count. The changed files go through
#                                  skills/j-test/scripts/map-scope.sh --files-from and
#                                  narrow-suites.sh --mapped-tests; the selected test files are
#                                  printed, then only the narrowed commands run. A mapped suite that
#                                  cannot be narrowed to files (an npm script, shellcheck, ...) is
#                                  named as not run and never executed.
#   4. otherwise                 — print `smoke-harness: nothing verified (<reason>)`, run nothing,
#                                  exit 3. <reason> is `no opt-in`, `no mapped tests` when step 3
#                                  selected no runnable test file, or `no runnable mapped command`
#                                  when every selected command was skipped, so nothing ran.
#
# It never infers a runner. The old tiers that ran `npm test`, `pytest` or `go test` whenever a
# project had one were removed after they ran this repository's whole bats suite (394 files,
# about 3 h) for a two-file change (epic E95). It never falls back to the bounded default suite set
# or any broader selection either: "nothing verified" is the answer, not a reason to run more.
#
# Exit codes:
#   0 — the opted-in or mapped tests passed, or the change is docs-only
#   1 — an opted-in or mapped test failed
#   3 — nothing was verified (no opt-in, no mapped tests, no runnable mapped command, or the scope
#       mapping itself failed).
#       A non-pass, not a failure: the caller must not record Passed or Failed on exit 3 alone.
#   Step 1 returns whatever scripts/smoke.sh returns.
#
# macOS /bin/bash 3.2 compatible: no mapfile, no associative arrays.

set -uo pipefail

# ---------------------------------------------------------------------------
# Resolve repo root and this script's own package root
# ---------------------------------------------------------------------------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SELF_PKG="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"

# A shipped helper: this checkout first, then the installed package, then the package this script
# itself was run from.
resolve_helper() {
  local rel="$1" candidate
  for candidate in "$REPO_ROOT/$rel" "$REPO_ROOT/node_modules/@jenga-ai/agent/$rel" "$SELF_PKG/$rel"; do
    if [[ -f "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

nothing_verified() {
  echo "smoke-harness: nothing verified ($1)"
  exit 3
}

# ---------------------------------------------------------------------------
# Collect changed files
# ---------------------------------------------------------------------------
# Uses a portable loop rather than mapfile/readarray (bash 3.x safe for macOS).
if [[ $# -gt 0 ]]; then
  CHANGED_FILES=("$@")
else
  CHANGED_FILES=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && CHANGED_FILES+=("$line")
  done < <(git diff --name-only HEAD 2>/dev/null || true)
fi

# ---------------------------------------------------------------------------
# Step 1: Delegate to scripts/smoke.sh if it exists
# ---------------------------------------------------------------------------
if [[ -f "$REPO_ROOT/scripts/smoke.sh" ]]; then
  echo "INFO: Found scripts/smoke.sh — delegating to project smoke test."
  bash "$REPO_ROOT/scripts/smoke.sh"
  exit $?
fi

# ---------------------------------------------------------------------------
# Step 2: Docs-only change runs nothing
# ---------------------------------------------------------------------------
if [[ ${#CHANGED_FILES[@]} -gt 0 ]]; then
  docs_only=true
  for f in "${CHANGED_FILES[@]}"; do
    case "$f" in
      *.md|*.txt) ;;
      *) docs_only=false; break ;;
    esac
  done
  if [[ "$docs_only" == "true" ]]; then
    echo "smoke-harness: docs-only change, no suite run"
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Step 3: The project's own scope map
# ---------------------------------------------------------------------------
# The configured scope-map path, printed only when it is the project's own opt-in.
project_scope_map() {
  local resolver configs cfg value
  command -v jq >/dev/null 2>&1 || return 1
  resolver="$(resolve_helper scripts/resolve-root.sh)" || return 1
  configs="$(cd "$REPO_ROOT" && bash "$resolver" get configs 2>/dev/null)" || return 1
  cfg="$configs/test-config.json"
  [[ -f "$cfg" ]] || return 1
  value="$(jq -r '.commit_scope_map_file // empty | strings' "$cfg" 2>/dev/null)" || return 1
  [[ -n "$value" ]] || return 1
  case "$value" in
    /*|../*|*/../*|*/..|..|templates/*|node_modules/*|*/node_modules/*) return 1 ;;
    *.json) ;;
    *) return 1 ;;
  esac
  [[ -f "$REPO_ROOT/$value" ]] || return 1
  printf '%s' "$value"
}

SCOPE_MAP="$(project_scope_map)" || SCOPE_MAP=""
[[ -n "$SCOPE_MAP" ]] || nothing_verified "no opt-in"
[[ ${#CHANGED_FILES[@]} -gt 0 ]] || nothing_verified "no mapped tests"

DISCOVER="$(resolve_helper skills/j-test/scripts/discover-tests.sh)" \
  || nothing_verified "scope mapping failed: discover-tests.sh not found"
MAPPER="$(resolve_helper skills/j-test/scripts/map-scope.sh)" \
  || nothing_verified "scope mapping failed: map-scope.sh not found"
NARROWER="$(resolve_helper skills/j-test/scripts/narrow-suites.sh)" \
  || nothing_verified "scope mapping failed: narrow-suites.sh not found"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/smoke-harness.XXXXXX")" \
  || nothing_verified "scope mapping failed: no scratch directory"
trap 'rm -rf "$TMP_DIR"' EXIT
trap 'rm -rf "$TMP_DIR"; exit 130' INT TERM HUP

printf '%s\n' "${CHANGED_FILES[@]}" > "$TMP_DIR/changed.txt"

echo "smoke-harness: mapping ${#CHANGED_FILES[@]} changed file(s) through $SCOPE_MAP"
bash "$DISCOVER" --root "$REPO_ROOT" > "$TMP_DIR/discovery.json" \
  || nothing_verified "scope mapping failed: discover-tests.sh"
bash "$MAPPER" --root "$REPO_ROOT" --map "$REPO_ROOT/$SCOPE_MAP" --suites "$TMP_DIR/discovery.json" \
    --files-from "$TMP_DIR/changed.txt" > "$TMP_DIR/mapped.json" \
  || nothing_verified "scope mapping failed: map-scope.sh"
bash "$NARROWER" --root "$REPO_ROOT" --suites "$TMP_DIR/discovery.json" \
    --mapped-tests "$TMP_DIR/mapped.json" --report "$TMP_DIR/report.json" > "$TMP_DIR/narrowed.json" \
  || nothing_verified "scope mapping failed: narrow-suites.sh"

# Runnable: only suites narrow-suites.sh actually rewrote to a file list (never an opaque command),
# not emptied, with a command, one per distinct command. TAB-separated id and command.
jq -r --slurpfile rep "$TMP_DIR/report.json" '
  ([ $rep[0].narrowed[]? | select(.emptied | not) | .id ]) as $ok
  | [ .suites[] | select(.id as $i | $ok | index($i)) | select((.command // "") != "") ]
  | unique_by(.command) | sort_by(.id) | .[] | [.id, .command] | @tsv
' "$TMP_DIR/narrowed.json" > "$TMP_DIR/runnable.tsv" 2>/dev/null \
  || nothing_verified "scope mapping failed: could not read the narrowed suites"

# A mapped suite that was not narrowed to files is named, never run.
jq -r --slurpfile rep "$TMP_DIR/report.json" '
  ([ $rep[0].narrowed[]? | .id ]) as $n
  | (.mapped_suites // [])[] | select(. as $i | $n | index($i) | not)
' "$TMP_DIR/mapped.json" 2>/dev/null | while IFS= read -r id; do
  echo "smoke-harness: not run (cannot be narrowed to test files): $id"
done

[[ -s "$TMP_DIR/runnable.tsv" ]] || nothing_verified "no mapped tests"

echo "smoke-harness: selected test files:"
jq -r --slurpfile rep "$TMP_DIR/report.json" --slurpfile map "$TMP_DIR/mapped.json" '
  ([ $rep[0].excluded[]?.file ]) as $x
  | [ $rep[0].narrowed[]? | select(.emptied | not) | .id ] as $ok
  | [ $ok[] as $i | ($map[0].mapped_tests[$i] // [])[] ] | unique
  | .[] | select(. as $f | $x | index($f) | not) | "  " + .
' "$TMP_DIR/narrowed.json"

status=0
ran=0
while IFS=$'\t' read -r id cmd; do
  # Belt: narrow-suites.sh only ever writes a `bats <files>` command for a narrowed suite.
  case "$cmd" in
    "bats "*) ;;
    *) echo "smoke-harness: not run (not a narrowed bats command): $id"; continue ;;
  esac
  echo "smoke-harness: running $id"
  ran=$((ran + 1))
  if ! (cd "$REPO_ROOT" && bash -c "$cmd") < /dev/null; then
    echo "smoke-harness: $id failed"
    status=1
  fi
done < "$TMP_DIR/runnable.tsv"

# Every command skipped by the belt means nothing ran: never report that as a pass.
[[ $ran -gt 0 ]] || nothing_verified "no runnable mapped command"

if [[ $status -eq 0 ]]; then
  echo "smoke-harness: mapped tests passed"
else
  echo "smoke-harness: mapped tests failed"
fi
exit "$status"
