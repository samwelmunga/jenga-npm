#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/workflow/load-workflows.sh - merged catalog of workflow definitions (epic E80, tasks E80_S01_T05, _T06)
#
# The single source of workflow definition data. It scans two directories, validates every file with
# scripts/workflow/validate-workflow.sh, merges the survivors into one catalog and prints it. Nothing else may
# re-scan those directories or keep its own list. Modelled on skills/jenga/scripts/load-playbooks.sh: the same
# builtin-plus-project merge, one validation pipeline for both sources, builtin wins on an `id` collision, a bad
# file is dropped with a warning and never aborts the load.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   load-workflows.sh
#   load-workflows.sh lookup <id>
#   load-workflows.sh -h | --help      print this usage on stdout, exit 0
#
# No other arguments. Bare, it prints ONE JSON array on stdout (pretty-printed), sorted by `id`. Each element is a valid
# definition, otherwise unchanged, plus two fields the loader adds:
#   "source"   "builtin" | "project"   which directory it came from
#   "file"     the path of the definition file as scanned (<directory>/<name>.json)
# A definition that already carries a `source` or `file` key of its own has it overwritten by the loader's value.
# With nothing to load the output is `[]`.
#
# `lookup <id>` (E80_S01_T06) runs the SAME catalog build (same validation, collision and drop rules, same stderr
# warnings; nothing is scanned a second way) and prints ONE element of it, pretty-printed, with `source` and `file`:
# the builtin one when a project file collided with it, none for an id that exists only in a dropped file. An id
# that is not in the catalog prints NOTHING on stdout and exits 2; stderr names the id and lists the available ids.
# Unlike `load-playbooks.sh lookup` (exit 0 with a status envelope) this mode signals failure by exit code; its usage
# error (no <id>, an empty <id>, extra arguments) is exit 2 in both.
#
# ---------------------------------------------------------------------------
# DATA SOURCE
# ---------------------------------------------------------------------------
#   1. BUILTIN  templates/workflows/   (lib.sh: workflow_builtin_dir) every `*.json` directly under it.
#   2. PROJECT  <working-file tree>/.workflows/   (lib.sh: workflow_project_dir) every `*.json` directly under it.
# Subdirectories are not scanned. Within a directory files are visited in C-locale filename order. Builtin is
# scanned and validated in full before the project directory is touched. A directory that does not exist is a
# SILENT no-op (no stderr output): a project with no custom workflows, or a fresh checkout whose builtin directory
# holds only .gitkeep, is the common case. The test override JENGA_WORKFLOWS_TEST_ROOT (see lib.sh) points both
# directories, the schema and the type registry at a synthetic tree; never set it in a real invocation.
#
# ---------------------------------------------------------------------------
# COLLISION RULE
# ---------------------------------------------------------------------------
#   - A project definition whose `id` equals that of a loaded builtin definition is SKIPPED; the builtin entry is
#     the one in the catalog. stderr names BOTH file paths and the id. Never a silent override either way.
#   - Two files in the same source with the same `id` (two project files, say): the lexicographically first file
#     (C-locale, by file name) wins and the later one is skipped; stderr names both files and the id.
#   - Only a file that passed validation takes part in a collision: an invalid builtin file does not shadow a
#     project definition with the same id.
#
# ---------------------------------------------------------------------------
# INVALID FILES
# ---------------------------------------------------------------------------
# A file the validator rejects (exit 1), or one that is unreadable or not valid JSON (exit 2 on that file), is
# dropped from the catalog. stderr gets one warning block naming the file and the validator's reason lines; every
# other definition still loads.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   the catalog was printed, including when files were dropped, skipped, or both directories are absent.
#   2   the loader could not run, or `lookup` found nothing: unexpected arguments, a missing `lookup` id, an id
#       that is not in the catalog, jq missing, a directory location or the validator could not
#       be resolved, or the validator could not run for a reason other than the file itself (the schema or type
#       registry unusable). One message on stderr.
#
# Needs jq. macOS bash 3.2 compatible (no associative arrays, mapfile). Creates and modifies nothing.
# ---------------------------------------------------------------------------

_LW_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
_LW_VALIDATOR="$_LW_DIR/validate-workflow.sh"

LC_COLLATE=C
export LC_COLLATE

_lw_usage() {
  printf 'Usage: load-workflows.sh [lookup <id>]\n'
}

_lw_warn() {
  printf 'load-workflows.sh: warning: %s\n' "$*" >&2
}

if [ "$#" -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
  _lw_usage
  exit 0
fi
MODE="catalog"
LOOKUP_ID=""
if [ "$#" -ge 1 ] && [ "$1" = "lookup" ]; then
  if [ "$#" -ne 2 ] || [ -z "$2" ]; then
    _lw_usage >&2
    exit 2
  fi
  MODE="lookup"
  LOOKUP_ID="$2"
elif [ "$#" -ne 0 ]; then
  _lw_usage >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'load-workflows.sh: jq is required but was not found on PATH\n' >&2
  exit 2
fi
if [ ! -f "$_LW_VALIDATOR" ]; then
  printf 'load-workflows.sh: validator not found: %s\n' "$_LW_VALIDATOR" >&2
  exit 2
fi

# shellcheck source=lib.sh
. "$_LW_DIR/lib.sh" || exit 2

BUILTIN_DIR="$(workflow_builtin_dir)" || {
  printf 'load-workflows.sh: cannot locate the builtin workflow directory\n' >&2
  exit 2
}
PROJECT_DIR="$(workflow_project_dir)" || {
  printf 'load-workflows.sh: cannot locate the project workflow directory\n' >&2
  exit 2
}

# SEEN: one line per loaded definition, "<id><TAB><source><TAB><file>". ENTRIES: one compact JSON object per line.
SEEN=""
ENTRIES=""
_LW_TAB="$(printf '\t')"

# _lw_scan <directory> <source>
# Validates and collects every *.json directly under <directory>. Returns non-zero only for a fatal condition.
_lw_scan() {
  local dir="$1" source="$2" f verr rc id prior prior_src prior_file label

  [ -d "$dir" ] || return 0
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue

    verr="$(bash "$_LW_VALIDATOR" "$f" 2>&1 >/dev/null)"
    rc=$?
    if [ "$rc" -eq 2 ]; then
      if [ -r "$f" ] && jq -e -s 'length == 1' "$f" >/dev/null 2>&1; then
        # The file itself is fine, so the validator could not run for an environmental reason.
        printf 'load-workflows.sh: the validator could not run: %s\n' "$verr" >&2
        return 2
      fi
      _lw_warn "dropped $source workflow $f: $verr"
      continue
    elif [ "$rc" -ne 0 ]; then
      _lw_warn "dropped invalid $source workflow $f:"
      printf '%s\n' "$verr" | sed 's/^/  /' >&2
      continue
    fi

    id="$(jq -r '.id | tostring' "$f")" || return 2
    prior="$(printf '%s\n' "$SEEN" | ID="$id" awk -F"$_LW_TAB" '$1 == ENVIRON["ID"] { print $2 "\t" $3; exit }')"
    if [ -n "$prior" ]; then
      prior_src="${prior%%"$_LW_TAB"*}"
      prior_file="${prior#*"$_LW_TAB"}"
      if [ "$prior_src" = "builtin" ] && [ "$source" = "project" ]; then
        label="builtin wins"
      else
        label="the first file wins"
      fi
      _lw_warn "$source workflow $f skipped: id '$id' is already defined by $prior_src workflow $prior_file ($label)"
      continue
    fi

    SEEN="${SEEN}${id}${_LW_TAB}${source}${_LW_TAB}${f}
"
    ENTRIES="${ENTRIES}$(jq -c --arg source "$source" --arg file "$f" '. + {source: $source, file: $file}' "$f")
" || return 2
  done
  return 0
}

_lw_scan "$BUILTIN_DIR" builtin || exit $?
_lw_scan "$PROJECT_DIR" project || exit $?

if [ "$MODE" = "lookup" ]; then
  FOUND="$(printf '%s' "$ENTRIES" | jq -s --arg id "$LOOKUP_ID" 'map(select((.id | tostring) == $id)) | .[0] // empty')" || exit 2
  if [ -z "$FOUND" ]; then
    AVAILABLE="$(printf '%s' "$ENTRIES" | jq -s -r 'map(.id | tostring) | sort | join(", ")')" || exit 2
    printf "load-workflows.sh: unknown workflow id '%s'; available ids: %s\n" "$LOOKUP_ID" "${AVAILABLE:-(none)}" >&2
    exit 2
  fi
  printf '%s\n' "$FOUND"
  exit 0
fi

if [ -z "$ENTRIES" ]; then
  printf '[]\n'
else
  printf '%s' "$ENTRIES" | jq -s 'sort_by(.id)'
fi
exit 0
