#!/usr/bin/env bash
################################################################################
# discover-tests.sh — ecosystem-agnostic test-suite detector (E72_S01_T01)
#
# Emits ONE JSON object on stdout describing every runnable test suite found in
# a directory tree. `j.test` (E72_S02) renders it as a numbered list and the
# scoped commit gate (E72_S03) filters it; both read the contract below, so a
# change to the contract is a change to those consumers.
#
# Usage:
#   discover-tests.sh [--root <dir>]
#   discover-tests.sh --help
#
#   --root <dir>  scan <dir> instead of the root resolved through
#                 scripts/resolve-root.sh. <dir> must exist.
#
# ---------------------------------------------------------------------------
# OUTPUT CONTRACT (normative)
#
#   {"suites":[{"id":"bats:tests","name":"bats tests","type":"unit",
#               "ecosystem":"bats","command":"bats tests/*.bats",
#               "paths":["tests/*.bats"]}],"warnings":[]}
#
#   suites     array sorted by `id` ascending in byte (LC_ALL=C-equivalent)
#              order. Locale never changes the order.
#   id         "<ecosystem>:<local-name>", unique across the array
#   name       human-readable label for a numbered list
#   type       unit | integration | e2e | sast | vulnerability | performance |
#              coverage | unknown   (the vocabulary of test-config.json's `type`)
#   ecosystem  npm | bats | pytest | go | cargo | shellcheck | config
#   command    the exact command a runner would execute, with the scanned
#              root as its working directory
#   paths      (E72_S03_T01) array of root-relative globs selecting the test
#              files the `command` runs; always present, [] when they are not
#              knowable; sorted in byte order and unique. Always the LAST key.
#   warnings   array of strings, sorted in the same byte order; [] when there
#              are none, never null
#
# Compact single-line JSON, key order fixed as above. Two runs over an
# unchanged tree are byte-identical.
#
# CONSUMERS MUST IGNORE KEYS THEY DO NOT KNOW. The contract grows by adding
# trailing keys (`paths` was the first), never by renaming or reordering, so a
# reader that picks out the keys it needs keeps working when one is added.
#
# `paths` glob dialect (shared with E72_S03_T02's scope map): `/`-separated,
# matched against the whole path; `*` is any run of characters except `/`; `?`
# is one character except `/`; `**` appears only as a complete path segment and
# matches zero or more segments; everything else is literal. No leading `./` or
# `/`, and no bracket, brace, backslash or `!` forms. A directory whose name
# holds one of `* ? [ ] { } \` (or `!`, or a control character) cannot be
# expressed, so its suite gets `paths: []` rather than a glob that would match
# the wrong files. Per ecosystem (<dir> as in the id, the scan root is `.`):
#     bats:<dir>               <dir>/*.bats                  root: *.bats
#     pytest:<dir>             <dir>/**/*_test.py, <dir>/**/test_*.py
#                              root: **/*_test.py, **/test_*.py
#     go:<dir>                 <dir>/*_test.go               root: **/*_test.go
#     cargo:unit               src/**/*.rs
#     cargo:integration:<name> tests/<name>.rs
#     npm:*, shellcheck:all    []   (an npm script is opaque; shellcheck checks
#                                    sources, not test files)
#     config:<tool>:<type>     the `paths` of the detected suite whose command
#                              it inherits; [] for a config-only suite
# A detected suite retyped by the overlay keeps its `paths`.
#
# ---------------------------------------------------------------------------
# DISCOVERY NEVER EXECUTES PROJECT CODE
#   Detection is manifest and file inspection only: jq over package.json, a
#   filesystem walk, and a PATH lookup. No project script, test runner or
#   package manager is invoked to enumerate suites. A detector that has to run
#   something in order to list tests is a defect; it must not be added here.
#   The commands in the output are strings for a later runner to execute.
#
# ---------------------------------------------------------------------------
# DETECTORS IN THIS FILE
#   npm         package.json `.scripts` keys equal to `test` or matching
#               ^test[:-]. Suffix -> type: unit, integration, e2e, coverage are
#               recognised, anything else is `unknown`, bare `test` is `unit`.
#   bats        one suite per directory holding *.bats files (not per file).
#   linter      one `shellcheck:all` suite when shellcheck is on PATH; nothing,
#               and no warning, when it is absent (an optional linter that is
#               not installed is not a problem).
#   pytest      a directory holding test_*.py or *_test.py is a suite
#               (id pytest:<dir>, command `pytest <dir>`). A directory holding
#               only a marker (conftest.py, pytest.ini, or a pyproject.toml with
#               [tool.pytest.ini_options]) is a suite too, unless a test-file
#               directory sits at or below it (that suite already covers it).
#   go          one suite per directory holding *_test.go (id go:<dir>, command
#               `go test ./<dir>/...`); directories under testdata/ are skipped.
#   cargo       needs ./Cargo.toml. `grep` for #[test] (never `cargo test`):
#               in src/**/*.rs -> `cargo:unit` (`cargo test --lib`); in each
#               tests/*.rs -> `cargo:integration:<file>`
#               (`cargo test --test <file>`, type integration).
#
# ---------------------------------------------------------------------------
# test-config.json OVERLAY (authoritative, not exclusive)
#   Read from the configs directory that scripts/resolve-root.sh resolves
#   (with --root, resolved against that root, falling back to
#   <root>/project/configs when the root has no registry). Its `tools` array is
#   merged with what was detected. A tool is "detected" when a detected suite
#   has that ecosystem.
#     - tool_name "-" is a "no tool for this type" placeholder: skipped, silently.
#     - listed AND detected: the suite keeps the detected `command`; its `type`
#       becomes the configured one (unless its own type is already one of the
#       tool's configured types). A configured type that no detected suite of
#       that tool carries is added as `config:<tool>:<type>`, ecosystem
#       "config", inheriting the tool's first detected command.
#     - listed, NOT detected: `config:<tool>:<type>`, ecosystem "config",
#       empty `command` (nothing is known to run), warning
#       `configured tool not detected on disk: <tool> (<type>)`.
#     - detected, NOT listed: kept, warning
#       `detected tool not listed in test-config.json: <tool>`.
#   Degradation, always a warning and exit 0: file absent, not valid JSON, no
#   `tools` array, or unreadable (the overlay is then skipped); an unreadable
#   directory in the walk (`could not read <path>; skipped`).
#
# The filesystem walk is done once. It skips dot-directories (VCS metadata, tool
# state, and the generated .claude/.agents trees with their nested worktrees),
# node_modules and site-packages (a venv's own tests are not the project's), and
# directories named `fixtures` or `__fixtures__` (inert test data, such as this
# repo's tests/fixtures/test-discovery/ trees, is not a suite). The name is matched
# on path components BELOW the scan root, so `--root <dir>/fixtures/x` still scans
# that tree. Known limitation: a project keeping real suites under a directory
# literally named `fixtures` does not have them discovered. It never follows
# symlinks and never writes a file.
#
# ---------------------------------------------------------------------------
# EXIT CODES
#   0  success, including the zero-suites case ({"suites":[],"warnings":[]})
#   1  internal failure (jq missing - named on stderr -, root unresolvable, jq error)
#   2  usage error (unknown flag, missing or non-directory --root)
#
# macOS bash 3.2 compatible: no associative arrays, no mapfile, no case
# modification expansions. Safe under `set -euo pipefail`.
################################################################################

set -euo pipefail

SCRIPT_NAME="discover-tests.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# skills/j-test/scripts -> the checkout root, or node_modules/@jenga-ai/agent
# when installed as a dependency.
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

# Locale must not influence sort order or tool output.
export LC_ALL=C

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }

usage() {
  cat <<'EOF'
Usage: discover-tests.sh [--root <dir>]
       discover-tests.sh --help

Print a JSON catalog of the runnable test suites found under a directory.
Detection inspects manifests and files only; no project code is executed.

  --root <dir>  scan <dir> instead of the resolved working root
  --help        show this help and exit 0

Output: {"suites":[{"id","name","type","ecosystem","command","paths"}...],"warnings":[]}
Exit:   0 ok (an empty suites array is valid), 1 internal failure, 2 usage error
EOF
}

# Mirrors the resolve_helper pattern of skills/j-break/scripts/check-break.sh:
# a checkout first, then the installed-package location.
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

# ---- accumulators -----------------------------------------------------------
# One compact JSON object per line / one message per line. Sorted and wrapped
# into the contract object once, in emit().
SUITE_LINES=""
WARNING_LINES=""

# add_suite <id> <name> <type> <ecosystem> <command> [<paths>]
# <paths> is a newline-separated list of globs (one string, so an empty list needs
# no array handling under bash 3.2's `set -u`); sorted and de-duplicated here.
add_suite() {
  local obj
  obj="$(jq -cn --arg id "$1" --arg name "$2" --arg type "$3" \
    --arg ecosystem "$4" --arg command "$5" --arg paths "${6:-}" \
    '{id:$id,name:$name,type:$type,ecosystem:$ecosystem,command:$command,
      paths:($paths | split("\n") | map(select(length > 0)) | unique)}')"
  SUITE_LINES="${SUITE_LINES}${obj}"$'\n'
}

# glob_literal <name>: true when <name> can be written into a `paths` glob as plain
# literal text. The dialect has no escape, so a name holding a metacharacter (or `!`,
# or a control character) cannot be expressed and its suite reports `paths: []`.
glob_literal() {
  case "$1" in
    *[\*\?\[\]\{\}\\\!]*) return 1 ;;
    *[[:cntrl:]]*) return 1 ;;
  esac
  return 0
}

# dir_glob <dir-as-in-id> <suffix>: "<dir>/<suffix>", or just "<suffix>" for the
# root ("."). Prints nothing when the directory cannot be expressed.
dir_glob() {
  glob_literal "$1" || return 0
  if [ "$1" = "." ]; then
    printf '%s' "$2"
  else
    printf '%s/%s' "$1" "$2"
  fi
}

add_warning() {
  WARNING_LINES="${WARNING_LINES}$1"$'\n'
}

# Quote a path or key for embedding in a command string, only when it needs it,
# so ordinary names stay readable.
shell_word() {
  case "$1" in
    *[!A-Za-z0-9._/:@%+=,-]*) printf '%q' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# ---- the single filesystem walk ---------------------------------------------

# FILES: every regular file under ROOT as a "./"-prefixed relative path, one per
# line, sorted. Walked once; every detector filters this list.
FILES=""

# find exits non-zero when it meets an unreadable directory but still prints what
# it reached. Keep that result, then re-run it only to learn the unreadable
# paths from stderr (stdout discarded) so each can be named in a warning.
scan_tree() {
  local rc=0 errs paths path
  FILES="$(cd "$ROOT" && find . \( -name '.?*' -o -name node_modules -o -name site-packages \
    -o -name fixtures -o -name __fixtures__ \) -prune \
    -o -type f -print 2>/dev/null | sort)" || rc=$?
  [ "$rc" -ne 0 ] || return 0
  errs="$(cd "$ROOT" && find . \( -name '.?*' -o -name node_modules -o -name site-packages \
    -o -name fixtures -o -name __fixtures__ \) -prune \
    -o -type f -print 2>&1 >/dev/null)" || true
  # BSD: "find: ./dir: Permission denied"   GNU: "find: './dir': Permission denied"
  paths="$(printf '%s\n' "$errs" | grep '^find: ' \
    | sed -e 's/^find: //' -e 's/: [A-Za-z ]*$//' -e "s/^'\\(.*\\)'\$/\\1/" -e 's|^\./||' \
    | sort -u || true)"
  if [ -z "$paths" ]; then
    add_warning "could not read part of the scanned tree; skipped"
    return 0
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    add_warning "could not read $path; skipped"
  done <<EOF
$paths
EOF
}

# dirs_with <ERE>: the unique directories ("./a/b", or ".") that hold a file whose
# basename matches the ERE.
dirs_with() {
  # The ERE goes in through the environment: awk -v would process its backslash escapes and gawk warns on stderr.
  printf '%s\n' "$FILES" | RE="$1" awk '
    BEGIN { re = ENVIRON["RE"] }
    { n = $0; sub(/^.*\//, "", n)
      if (n ~ re) { d = $0; sub(/\/[^\/]*$/, "", d); print d } }' | sort -u
}

# ---- detectors --------------------------------------------------------------

# npm: manifest inspection with jq. The scripts are never invoked.
detect_npm() {
  local manifest="$ROOT/package.json" keys key suffix type name command
  [ -e "$manifest" ] || return 0
  if [ ! -f "$manifest" ] || [ ! -r "$manifest" ]; then
    add_warning "package.json is not a readable file; npm suites were skipped"
    return 0
  fi
  if ! keys="$(jq -r 'if type == "object" and (.scripts | type) == "object"
                      then .scripts | keys[] else empty end' "$manifest" 2>/dev/null)"; then
    add_warning "package.json could not be parsed as JSON; npm suites were skipped"
    return 0
  fi
  [ -n "$keys" ] || return 0

  while IFS= read -r key; do
    case "$key" in
      test) suffix="" ;;
      test:*|test-*) suffix="${key#test?}" ;;
      *) continue ;;
    esac
    case "$suffix" in
      "") type="unit" ;;
      unit|integration|e2e|coverage) type="$suffix" ;;
      *) type="unknown" ;;
    esac
    if [ "$key" = "test" ]; then
      name="npm test"
      command="npm test"
    else
      command="npm run $(shell_word "$key")"
      name="$command"
    fi
    add_suite "npm:$key" "$name" "$type" "npm" "$command"
  done <<EOF
$keys
EOF
}

# bats: one suite per directory that holds *.bats files. The files are only
# located, never executed.
detect_bats() {
  local dirs dir rel
  dirs="$(dirs_with '\.bats$')"
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    rel="${dir#./}"
    add_suite "bats:$rel" "bats $rel" "unit" "bats" "bats $(shell_word "$rel")/*.bats" \
      "$(dir_glob "$rel" '*.bats')"
  done <<EOF
$dirs
EOF
}

# pytest: directories holding test files are suites; a marker-only directory
# (conftest.py, pytest.ini, pyproject.toml with the pytest table) is a suite only
# when no test-file directory sits at or below it. Files are located and, for
# pyproject.toml, read with grep; nothing is executed.
detect_pytest() {
  local test_dirs marker_dirs pyproj_dirs dir rel candidate covered suite_dirs
  test_dirs="$(dirs_with '^(test_.*|.*_test)\.py$')"
  marker_dirs="$(dirs_with '^(conftest\.py|pytest\.ini)$')"
  pyproj_dirs=""
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    if [ "$dir" = "." ]; then
      rel="pyproject.toml"
    else
      rel="${dir#./}/pyproject.toml"
    fi
    if [ ! -r "$ROOT/$rel" ]; then
      add_warning "could not read $rel; skipped"
      continue
    fi
    if grep -q '^\[tool\.pytest\.ini_options\]' "$ROOT/$rel" 2>/dev/null; then
      pyproj_dirs="${pyproj_dirs}${dir}"$'\n'
    fi
  done <<EOF
$(dirs_with '^pyproject\.toml$')
EOF

  suite_dirs="$test_dirs"$'\n'
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    covered=0
    while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      case "$dir" in
        "$candidate"|"$candidate"/*) covered=1; break ;;
      esac
    done <<EOF
$test_dirs
EOF
    [ "$covered" -eq 1 ] || suite_dirs="${suite_dirs}${candidate}"$'\n'
  done <<EOF
$marker_dirs
$pyproj_dirs
EOF

  suite_dirs="$(printf '%s' "$suite_dirs" | sed '/^$/d' | sort -u)"
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    rel="${dir#./}"
    add_suite "pytest:$rel" "pytest $rel" "unit" "pytest" "pytest $(shell_word "$rel")" \
      "$(dir_glob "$rel" '**/*_test.py')"$'\n'"$(dir_glob "$rel" '**/test_*.py')"
  done <<EOF
$suite_dirs
EOF
}

# go: one suite per package directory holding *_test.go. The go tool ignores
# testdata/ trees, so they are not packages here either.
detect_go() {
  local dirs dir rel target globs
  dirs="$(dirs_with '_test\.go$')"
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    case "$dir/" in */testdata/*) continue ;; esac
    rel="${dir#./}"
    if [ "$rel" = "." ]; then
      target="./..."
      globs='**/*_test.go'   # `go test ./...` runs every package below the root
    else
      target="./$(shell_word "$rel")/..."
      globs="$(dir_glob "$rel" '*_test.go')"
    fi
    add_suite "go:$rel" "go test $rel" "unit" "go" "go test $target" "$globs"
  done <<EOF
$dirs
EOF
}

# True when the file (relative to the root, "./"-prefixed) contains #[test]. An
# unreadable file is reported and counted as no match. grep only; no cargo.
has_rust_test() {
  local f="$1"
  if [ ! -r "$ROOT/${f#./}" ]; then
    add_warning "could not read ${f#./}; skipped"
    return 1
  fi
  grep -q -F -e '#[test]' "$ROOT/${f#./}" 2>/dev/null
}

# cargo: a Cargo.toml at the scan root, then grep for #[test]. `cargo test` is
# never run.
detect_cargo() {
  local f name globs found=0
  printf '%s\n' "$FILES" | grep -qxF './Cargo.toml' || return 0

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if has_rust_test "$f"; then found=1; break; fi
  done <<EOF
$(printf '%s\n' "$FILES" | grep '^\./src/.*\.rs$' || true)
EOF
  if [ "$found" -eq 1 ]; then
    add_suite "cargo:unit" "cargo test --lib" "unit" "cargo" "cargo test --lib" 'src/**/*.rs'
  fi

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if has_rust_test "$f"; then
      name="${f##*/}"
      name="${name%.rs}"
      globs=""
      if glob_literal "$name"; then globs="tests/$name.rs"; fi
      add_suite "cargo:integration:$name" "cargo test --test $name" "integration" "cargo" \
        "cargo test --test $(shell_word "$name")" "$globs"
    fi
  done <<EOF
$(printf '%s\n' "$FILES" | grep '^\./tests/[^/]*\.rs$' || true)
EOF
}

# The shellcheck linter: an installed one is a runnable static-analysis suite. Absent is
# silent. The command is relative to the scanned root.
detect_shellcheck() {
  command -v shellcheck >/dev/null 2>&1 || return 0
  add_suite "shellcheck:all" "shellcheck" "sast" "shellcheck" \
    "find . -type f -name '*.sh' -not -path '*/node_modules/*' -not -path '*/.*/*' -print0 | xargs -0 shellcheck"
}

# ---- test-config.json overlay -----------------------------------------------

# The `tools` array of test-config.json, as JSON, when the overlay applies;
# empty when it does not (and the reason has been added as a warning).
CONFIG_TOOLS=""

# Where the configs directory is. With --root it is resolved against that root
# (JENGA_PROJECT_ROOT), so a scanned tree is judged by its own config rather than
# whatever registry sits above it. A root with no registry still gets its own
# <root>/<configs path>: the resolver's relative path is joined onto the root,
# so no tree name is hardcoded here.
config_dir() {
  local dir="" rel=""
  if [ -n "$RESOLVER" ]; then
    if [ -n "$ROOT_ARG" ]; then
      dir="$(JENGA_PROJECT_ROOT="$ROOT" bash "$RESOLVER" get configs 2>/dev/null)" || dir=""
      if [ -z "$dir" ]; then
        rel="$(cd "$ROOT" && JENGA_PROJECT_ROOT="" bash "$RESOLVER" --relative get configs 2>/dev/null)" || rel=""
        [ -z "$rel" ] || dir="$ROOT/$rel"
      fi
    else
      dir="$(cd "$ROOT" && bash "$RESOLVER" get configs 2>/dev/null)" || dir=""
    fi
  fi
  printf '%s' "$dir"
}

load_overlay() {
  local cfg tools cfg_dir
  cfg_dir="$(config_dir)"
  cfg="$cfg_dir/test-config.json"
  if [ -z "$cfg_dir" ] || [ ! -e "$cfg" ]; then
    add_warning "test-config.json not found; reporting detected suites only"
    return 0
  fi
  if [ ! -f "$cfg" ] || [ ! -r "$cfg" ]; then
    add_warning "could not read test-config.json; skipped"
    return 0
  fi
  # `type` always prints a string for a valid document and nothing for an empty
  # file, so -e fails for both invalid and empty input.
  if ! jq -e 'type' "$cfg" >/dev/null 2>&1; then
    add_warning "test-config.json is not valid JSON; ignoring overlay"
    return 0
  fi
  tools="$(jq -c 'if type == "object" and (.tools | type) == "array" then .tools else empty end' "$cfg")"
  if [ -z "$tools" ]; then
    add_warning "test-config.json has no tools array; ignoring overlay"
    return 0
  fi
  CONFIG_TOOLS="$tools"
}

# The merge, as a jq program: --argjson suites <detected> --argjson tools <config>.
# Returns {suites, warnings} where suites is the detected list retyped and
# extended, and warnings are the overlay's own messages.
overlay_program() {
  cat <<'EOF'
def vocab: ["unit","integration","e2e","sast","vulnerability","performance","coverage","unknown"];
def norm: if (vocab | index(.)) != null then . else "unknown" end;

[ $tools[] | select(((type == "object") and (.tool_name == "-")) | not) ] as $live
| [ $live[] | select((type == "object") and ((.tool_name | type) == "string")
                     and (.tool_name | length) > 0 and ((.type | type) == "string")) ] as $valid
| (($live | length) - ($valid | length)) as $bad
| [ $valid[] | {tool_name: .tool_name, type: (.type | norm)} ] as $cfg
| ($suites | map(.ecosystem) | unique) as $det
| ($cfg | map(.tool_name) | unique) as $listed
| ( $suites | map(
      . as $s
      | [ $cfg[] | select(.tool_name == $s.ecosystem) | .type ] as $ts
      | if ($ts | length) == 0 or ($ts | index($s.type)) != null then .
        else .type = $ts[0] end ) ) as $typed
| ( [ $cfg[] | . as $c
      | select( [ $typed[] | select(.ecosystem == $c.tool_name and .type == $c.type) ] | length == 0 )
      | { id: ("config:" + $c.tool_name + ":" + $c.type),
          name: ($c.tool_name + " (" + $c.type + ")"),
          type: $c.type,
          ecosystem: "config",
          command: ( if ($det | index($c.tool_name)) != null
                     then ([ $typed[] | select(.ecosystem == $c.tool_name) ] | sort_by(.id) | .[0].command)
                     else "" end ),
          paths: ( if ($det | index($c.tool_name)) != null
                   then ([ $typed[] | select(.ecosystem == $c.tool_name) ] | sort_by(.id) | .[0].paths)
                   else [] end ) } ]
    | unique_by(.id) ) as $extra
| { suites: ($typed + $extra),
    warnings: (
      ( [ $cfg[] | . as $c | select(($det | index($c.tool_name)) == null)
          | "configured tool not detected on disk: \($c.tool_name) (\($c.type))" ] | unique )
      + [ $det[] | . as $e | select(($listed | index($e)) == null)
          | "detected tool not listed in test-config.json: \($e)" ]
      + ( if $bad > 0
          then ["test-config.json: ignored \($bad) tools entries without a string tool_name and type"]
          else [] end ) ) }
EOF
}

# ---- output -----------------------------------------------------------------

emit() {
  local suites warnings merged line
  suites="$(printf '%s' "$SUITE_LINES" | jq -cs '.')"
  if [ -n "$CONFIG_TOOLS" ]; then
    merged="$(jq -cn --argjson suites "$suites" --argjson tools "$CONFIG_TOOLS" "$(overlay_program)")"
    suites="$(printf '%s' "$merged" | jq -c '.suites')"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      add_warning "$line"
    done <<EOF
$(printf '%s' "$merged" | jq -r '.warnings[]')
EOF
  fi
  # jq compares strings by code point, which for UTF-8 is byte order: the same
  # result as LC_ALL=C and independent of the caller's locale. sort_by is stable.
  suites="$(printf '%s' "$suites" | jq -c 'sort_by(.id)')"
  warnings="$(printf '%s' "$WARNING_LINES" | jq -cRs 'split("\n") | map(select(length > 0)) | sort')"
  jq -cn --argjson suites "$suites" --argjson warnings "$warnings" \
    '{suites:$suites,warnings:$warnings}'
}

# ---- main -------------------------------------------------------------------

main() {
  local root_arg=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --root)
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
          err "--root requires a directory argument"
          usage >&2
          exit 2
        fi
        root_arg="$2"
        shift 2
        ;;
      -h|--help|help) usage; exit 0 ;;
      *) err "unknown argument: $1"; usage >&2; exit 2 ;;
    esac
  done

  if ! command -v jq >/dev/null 2>&1; then
    err "jq is required but was not found on PATH"
    exit 1
  fi

  ROOT_ARG="$root_arg"
  if [ -n "$root_arg" ]; then
    if [ ! -d "$root_arg" ]; then
      err "--root is not a directory: $root_arg"
      exit 2
    fi
    ROOT="$(cd -- "$root_arg" && pwd)"
    # Only the overlay needs the resolver here; without it the config falls back
    # to <root>/project/configs.
    RESOLVER="$(resolve_helper scripts/resolve-root.sh)" || RESOLVER=""
  else
    RESOLVER="$(resolve_helper scripts/resolve-root.sh)" || {
      err "could not locate scripts/resolve-root.sh"
      exit 1
    }
    ROOT="$(bash "$RESOLVER" root)" || {
      err "could not resolve the working root"
      exit 1
    }
    [ -d "$ROOT" ] || { err "the resolved root is not a directory: $ROOT"; exit 1; }
  fi

  scan_tree
  detect_npm
  detect_bats
  detect_pytest
  detect_go
  detect_cargo
  detect_shellcheck
  load_overlay

  emit
}

ROOT=""
ROOT_ARG=""
RESOLVER=""
main "$@"
