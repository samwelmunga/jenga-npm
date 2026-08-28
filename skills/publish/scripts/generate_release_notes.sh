#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/publish_common.sh"

usage() {
  cat <<'USAGE'
Usage: generate_release_notes.sh [--target <name>] [--from-tag <tag>] [--to-ref <git-ref>] [--output <path>] [<publish_json_path>]
USAGE
}

TARGET_NAME=""
FROM_TAG=""
TO_REF="HEAD"
OUTPUT_PATH=""
CONFIG_PATH=""
POSITIONAL_COUNT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      TARGET_NAME="$2"
      shift 2
      ;;
    --from-tag)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      FROM_TAG="$2"
      shift 2
      ;;
    --to-ref)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      TO_REF="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      usage >&2
      exit 1
      ;;
    *)
      POSITIONAL_COUNT=$((POSITIONAL_COUNT + 1))
      if (( POSITIONAL_COUNT > 1 )); then
        usage >&2
        exit 1
      fi
      CONFIG_PATH="$1"
      shift
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo 'jq is required.' >&2; exit 1; }

git rev-parse --verify "$TO_REF" >/dev/null 2>&1 || {
  echo "Unknown git ref: $TO_REF" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# .publicignore pre-filter (E36_S02_T02).
#
# A commit (or completed task) whose changed files are ALL covered by a
# repo-root .publicignore blocklist must never surface in CHANGELOG.md,
# since CHANGELOG.md itself is not blocklisted and ships to the public
# mirror via /mirror-public. Partial overlap is not grounds for exclusion.
# Absence of .publicignore is a strict no-op — PI_ACTIVE stays 0 and every
# _pi_* helper below fails open immediately.
#
# Matching semantics are borrowed from skills/mirror-public/scripts/mirror.sh
# rather than reimplemented: that script's compute_ship_list asks rsync
# itself "what would transfer past --exclude-from=.publicignore?" and that
# is the single source of truth /mirror-public --dry-run reports as
# shipped/blocked. This script has no real destination tree to rsync into,
# so _pi_classify_paths below builds a throwaway stub tree with zero-byte
# files at each candidate path and asks rsync the identical question.
# ---------------------------------------------------------------------------

PUBLICIGNORE="$PUBLISH_REPO_ROOT/.publicignore"
PI_ACTIVE=0
PI_SHIPPED_FILE=""
trap '[[ -n "$PI_SHIPPED_FILE" ]] && rm -f "$PI_SHIPPED_FILE"' EXIT

if [[ -f "$PUBLICIGNORE" ]]; then
  if command -v rsync >/dev/null 2>&1; then
    PI_ACTIVE=1
  else
    echo "generate_release_notes.sh: rsync not found; skipping .publicignore filtering" >&2
  fi
fi

# _pi_classify_paths <path-list-file> <out-shipped-file>
#
# <path-list-file> is a deduped, one-path-per-line file of repo-relative
# paths. Writes the subset rsync would transfer past .publicignore's
# --exclude-from (i.e. the NOT-blocked subset) to <out-shipped-file>. A path
# absent from that output is blocked.
_pi_classify_paths() {
  local path_list="$1" out_file="$2"
  local stub_src stub_dst p

  stub_src="$(mktemp -d)"
  stub_dst="$(mktemp -d)"

  while IFS= read -r p || [[ -n "$p" ]]; do
    [[ -n "$p" ]] || continue
    mkdir -p "$stub_src/$(dirname "$p")"
    : > "$stub_src/$p"
  done < "$path_list"

  rsync -a \
    --exclude-from="$PUBLICIGNORE" \
    --exclude=".git" \
    --dry-run --itemize-changes --out-format='%i %n' \
    "$stub_src/" "$stub_dst/" \
    | awk '{
        flag = $1;
        first  = substr(flag, 1, 1);
        second = substr(flag, 2, 1);
        if (second == "d") next;
        keep = 0;
        if (first == ">" || first == "<") keep = 1;
        else if (first == "c" && second == "L") keep = 1;
        else if (first == "h") keep = 1;
        if (!keep) next;
        $1 = "";
        sub(/^ /, "");
        sub(/\/$/, "");
        if (length($0) > 0) print $0;
      }' \
    | LC_ALL=C sort -u > "$out_file"

  rm -rf "$stub_src" "$stub_dst"
  return 0
}

HISTORY_FILE="$(publish_resolve_history_file "$CONFIG_PATH")"
LAST_TAG="$FROM_TAG"
FIRST_RELEASE=0
CUTOFF_DATE=""

if [[ -z "$LAST_TAG" ]]; then
  if LAST_TAG="$(publish_resolve_last_publish_tag "$HISTORY_FILE" "$TO_REF" 2>/dev/null || true)" && [[ -n "$LAST_TAG" ]]; then
    :
  else
    LAST_TAG=""
    FIRST_RELEASE=1
  fi
fi

if [[ -n "$LAST_TAG" ]]; then
  git rev-parse --verify "$LAST_TAG" >/dev/null 2>&1 || {
    echo "Unknown git tag: $LAST_TAG" >&2
    exit 1
  }
  CUTOFF_DATE="$(git log -1 --format=%cI "$LAST_TAG" 2>/dev/null | cut -dT -f1)"
fi

FEATURES=()
BUG_FIXES=()
OTHER=()

if [[ -n "$LAST_TAG" ]]; then
  LOG_RANGE=("$LAST_TAG..$TO_REF")
else
  LOG_RANGE=("$TO_REF")
fi

COMMIT_SUBJECTS=()
COMMIT_SHORT_SHAS=()
COMMIT_FULL_SHAS=()

while IFS=$'\t' read -r subject short_sha full_sha || [[ -n "${subject:-}${short_sha:-}${full_sha:-}" ]]; do
  [[ -z "${subject:-}" ]] && continue
  COMMIT_SUBJECTS+=("$subject")
  COMMIT_SHORT_SHAS+=("$short_sha")
  COMMIT_FULL_SHAS+=("$full_sha")
done < <(git log "${LOG_RANGE[@]}" --pretty=format:'%s%x09%h%x09%H')

# COMMIT_FILES[i] holds the newline-joined changed-file list for the commit
# at the same index as COMMIT_SUBJECTS/COMMIT_SHORT_SHAS/COMMIT_FULL_SHAS.
# Only populated when PI_ACTIVE, and only used to decide exclusion — it does
# not change classification (feat/fix/other) for anything that survives.
COMMIT_FILES=()

if (( PI_ACTIVE )) && (( ${#COMMIT_FULL_SHAS[@]} > 0 )); then
  PI_ALL_PATHS_FILE="$(mktemp)"
  : > "$PI_ALL_PATHS_FILE"
  ci=0
  while (( ci < ${#COMMIT_FULL_SHAS[@]} )); do
    files="$(git diff-tree --no-commit-id --name-only -r "${COMMIT_FULL_SHAS[$ci]}" 2>/dev/null || true)"
    COMMIT_FILES+=("$files")
    if [[ -n "$files" ]]; then
      printf '%s\n' "$files" >> "$PI_ALL_PATHS_FILE"
    fi
    ci=$((ci + 1))
  done
  LC_ALL=C sort -u "$PI_ALL_PATHS_FILE" -o "$PI_ALL_PATHS_FILE"
  if [[ -s "$PI_ALL_PATHS_FILE" ]]; then
    PI_SHIPPED_FILE="$(mktemp)"
    _pi_classify_paths "$PI_ALL_PATHS_FILE" "$PI_SHIPPED_FILE"
  fi
  rm -f "$PI_ALL_PATHS_FILE"
fi

# _pi_commit_is_fully_blocked <index>
#
# True (return 0) only when the commit at COMMIT_FILES[<index>] changed at
# least one file and NONE of its changed files are in the shipped set (i.e.
# every changed file is blocked by .publicignore). A commit with zero
# changed files (e.g. an empty commit) has nothing to check and fails open.
_pi_commit_is_fully_blocked() {
  local idx="$1" files f

  if (( ! PI_ACTIVE )); then
    return 1
  fi
  if [[ -z "$PI_SHIPPED_FILE" ]]; then
    return 1
  fi
  files="${COMMIT_FILES[$idx]:-}"
  if [[ -z "$files" ]]; then
    return 1
  fi

  while IFS= read -r f || [[ -n "$f" ]]; do
    [[ -n "$f" ]] || continue
    if grep -qxF "$f" "$PI_SHIPPED_FILE" 2>/dev/null; then
      return 1
    fi
  done <<< "$files"

  return 0
}

ci=0
while (( ci < ${#COMMIT_SUBJECTS[@]} )); do
  subject="${COMMIT_SUBJECTS[$ci]}"
  short_sha="${COMMIT_SHORT_SHAS[$ci]}"

  if _pi_commit_is_fully_blocked "$ci"; then
    ci=$((ci + 1))
    continue
  fi

  line="- $subject ($short_sha)"
  if printf '%s\n' "$subject" | grep -Eq '^feat(\([^)]+\))?!?: '; then
    FEATURES+=("$line")
  elif printf '%s\n' "$subject" | grep -Eq '^fix(\([^)]+\))?!?: '; then
    BUG_FIXES+=("$line")
  else
    OTHER+=("$line")
  fi
  ci=$((ci + 1))
done

# _pi_task_is_fully_blocked <task_id>
#
# Best-effort task-to-commit association: finds commits in the resolved
# LOG_RANGE whose subject follows this repo's own EST commit convention
# (e.g. "task(E36_S02_T01): ..." — confirmed against real history), via a
# literal (non-regex) substring match on "($task_id)". If no associated
# commit is found, fails open (returns 1 — keep the entry): we only ever
# suppress an entry we have positive evidence for, never one we can't
# determine. If associated commits are found, unions their changed files
# and excludes the task only when every one of those files is blocked.
_pi_task_is_fully_blocked() {
  local task_id="$1"
  local shas all_paths tmp_ship sha result

  result=1

  if (( PI_ACTIVE )); then
    shas="$(git log "${LOG_RANGE[@]}" --grep="($task_id)" -F --pretty=format:%H 2>/dev/null || true)"
    if [[ -n "$shas" ]]; then
      all_paths="$(mktemp)"
      : > "$all_paths"
      while IFS= read -r sha || [[ -n "$sha" ]]; do
        [[ -n "$sha" ]] || continue
        git diff-tree --no-commit-id --name-only -r "$sha" 2>/dev/null || true
      done <<< "$shas" >> "$all_paths"
      LC_ALL=C sort -u "$all_paths" -o "$all_paths"

      if [[ -s "$all_paths" ]]; then
        tmp_ship="$(mktemp)"
        _pi_classify_paths "$all_paths" "$tmp_ship"
        if [[ ! -s "$tmp_ship" ]]; then
          result=0
        fi
        rm -f "$tmp_ship"
      fi
      rm -f "$all_paths"
    fi
  fi

  if (( result == 0 )); then
    return 0
  fi
  return 1
}

collect_completed_tasks() {
  local cutoff_date="$1"
  local tasks_dir="$PUBLISH_REPO_ROOT/project/board/tasks"
  local collected=()
  local task_file status completed_date task_id task_title

  [[ -d "$tasks_dir" ]] || return 0

  while IFS= read -r -d '' task_file; do
    case "$task_file" in
      *_INSTRUCTIONS.md) continue ;;
    esac

    status="$(awk '/^status: /{sub(/^status: /, ""); print; exit}' "$task_file" 2>/dev/null || true)"
    [[ "$status" == "Passed" ]] || continue

    completed_date="$(awk '/^date_completed: /{sub(/^date_completed: /, ""); print; exit}' "$task_file" 2>/dev/null || true)"
    [[ -n "$completed_date" ]] || continue

    if [[ -n "$cutoff_date" && "$completed_date" < "$cutoff_date" ]]; then
      continue
    fi

    task_id="$(awk '/^id: /{sub(/^id: /, ""); print; exit}' "$task_file" 2>/dev/null || true)"
    task_title="$(awk '/^title: /{sub(/^title: /, ""); print; exit}' "$task_file" 2>/dev/null || true)"
    [[ -n "$task_id" ]] || continue
    [[ -n "$task_title" ]] || task_title="$task_id"

    if (( PI_ACTIVE )) && _pi_task_is_fully_blocked "$task_id"; then
      continue
    fi

    collected+=("- $task_id — $task_title")
  done < <(find "$tasks_dir" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null)

  if (( ${#collected[@]} > 0 )); then
    printf '%s\n' "${collected[@]}" | LC_ALL=C sort -u
  fi
}

STANDALONE=0
if [[ -n "$OUTPUT_PATH" ]]; then
  STANDALONE=1
else
  OUTPUT_PATH="$PUBLISH_REPO_ROOT/CHANGELOG.md"
fi
mkdir -p "$(dirname "$OUTPUT_PATH")"

write_section() {
  local heading="$1"
  local array_name="$2"
  local item_count

  eval "item_count=\${#${array_name}[@]}"
  {
    printf '### %s\n' "$heading"
    if (( item_count > 0 )); then
      eval "printf '%s\\n' \"\${${array_name}[@]}\""
    else
      printf -- '- None\n'
    fi
    printf '\n'
  } >> "$OUTPUT_PATH"
}

# ---------------------------------------------------------------------------
# Standing-changelog merge helpers.
#
# These operate on a plain indexed bash array (CL_LINES), loaded via a
# `while read` loop rather than `mapfile`/`readarray`. This repo's target
# shell is bash 3.2 (the stock macOS default; no Homebrew bash is assumed on
# PATH), which lacks `mapfile`, `declare -A`, and `local -n` namerefs
# (bash 4.0/4.3+ only) — none of those are used anywhere else in this repo's
# scripts either. Helper functions rely on bash's dynamic scoping (a
# function's `local`s are visible to functions it calls) instead of
# namerefs to share the working array and computed indices.
# ---------------------------------------------------------------------------

CL_LINES=()
CL_UNRELEASED_START=-1
CL_UNRELEASED_END=-1
CL_SUB_HEAD=-1
CL_SUB_END=-1
CL_NEW_ITEMS=()
CL_FILTERED=()

_cl_load() {
  CL_LINES=()
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    CL_LINES+=("$line")
  done < "$1"
}

_cl_save() {
  if (( ${#CL_LINES[@]} > 0 )); then
    printf '%s\n' "${CL_LINES[@]}" > "$1"
  else
    : > "$1"
  fi
}

# Locates the `## [Unreleased]` heading and the boundary of its section (the
# next line starting with `## `, or EOF). Sets CL_UNRELEASED_START/_END.
_cl_locate_unreleased() {
  local n=${#CL_LINES[@]}
  local i
  CL_UNRELEASED_START=-1
  CL_UNRELEASED_END=$n
  for (( i=0; i<n; i++ )); do
    if [[ "${CL_LINES[$i]}" == "## [Unreleased]" ]]; then
      CL_UNRELEASED_START=$i
      break
    fi
  done
  (( CL_UNRELEASED_START >= 0 )) || return 1
  for (( i=CL_UNRELEASED_START+1; i<n; i++ )); do
    case "${CL_LINES[$i]}" in
      "## "*) CL_UNRELEASED_END=$i; return 0 ;;
    esac
  done
  return 0
}

# Locates a `### <heading>` subsection within the current Unreleased bounds
# and its own boundary (next `### ` line, or the Unreleased boundary). Sets
# CL_SUB_HEAD (-1 if the heading doesn't exist yet) and CL_SUB_END.
_cl_locate_subsection() {
  local heading="$1"
  local j k
  CL_SUB_HEAD=-1
  CL_SUB_END=$CL_UNRELEASED_END
  for (( j=CL_UNRELEASED_START+1; j<CL_UNRELEASED_END; j++ )); do
    if [[ "${CL_LINES[$j]}" == "### $heading" ]]; then
      CL_SUB_HEAD=$j
      CL_SUB_END=$CL_UNRELEASED_END
      for (( k=j+1; k<CL_UNRELEASED_END; k++ )); do
        case "${CL_LINES[$k]}" in
          "### "*) CL_SUB_END=$k; break ;;
        esac
      done
      break
    fi
  done
  return 0
}

# Filters CL_NEW_ITEMS down to entries not already present within the
# current CL_SUB_HEAD..CL_SUB_END bounds, into CL_FILTERED. Dedup key is the
# trailing "(shortsha)" token for mode=suffix (git-log-derived entries), or
# the "- $task_id —" prefix for mode=prefix (completed-task entries).
_cl_filter_new() {
  local mode="$1"
  CL_FILTERED=()
  # bash 3.2 (no Homebrew bash assumed on PATH) treats a zero-element array
  # expansion as unset under `set -u`, so every "${arr[@]}" below is guarded
  # by an element-count check first — same convention collect_completed_tasks()
  # already uses in this file.
  (( ${#CL_NEW_ITEMS[@]} > 0 )) || return 0
  if (( CL_SUB_HEAD < 0 )); then
    CL_FILTERED=("${CL_NEW_ITEMS[@]}")
    return 0
  fi
  local item key dup l
  for item in "${CL_NEW_ITEMS[@]}"; do
    if [[ "$mode" == "suffix" ]]; then
      key="${item##* }"
    else
      key="${item%% — *} —"
    fi
    dup=0
    for (( l=CL_SUB_HEAD+1; l<CL_SUB_END; l++ )); do
      if [[ "${CL_LINES[$l]}" == *"$key"* ]]; then
        dup=1
        break
      fi
    done
    (( dup )) || CL_FILTERED+=("$item")
  done
  return 0
}

# Splices the given lines into CL_LINES at index $1.
#
# NOTE: guards below use explicit `if` rather than `(( cond )) && action`.
# The latter is fine as a mid-function statement, but bash's `set -e`
# propagates a false `(( cond ))` left operand as the *function's own*
# return status when it is the last statement executed in the function —
# even though the same construct is a documented-safe no-op at the top
# level of a script. That silently aborted the whole script under
# `set -euo pipefail` the first time this was exercised end-to-end.
_cl_splice() {
  local at="$1"; shift
  local before=()
  local after=()
  if (( at > 0 )); then
    before=("${CL_LINES[@]:0:at}")
  fi
  if (( at < ${#CL_LINES[@]} )); then
    after=("${CL_LINES[@]:at}")
  fi
  CL_LINES=()
  if (( ${#before[@]} > 0 )); then
    CL_LINES+=("${before[@]}")
  fi
  if (( $# > 0 )); then
    CL_LINES+=("$@")
  fi
  if (( ${#after[@]} > 0 )); then
    CL_LINES+=("${after[@]}")
  fi
  return 0
}

# Dedups CL_NEW_ITEMS against the named `### <heading>` subsection (creating
# the heading at the end of the Unreleased section if it doesn't exist yet —
# used for "Completed tasks", which the template doesn't pre-declare) and
# splices in whatever survives. Re-locates the Unreleased/subsection bounds
# fresh on every call, so calls can run in the subsections' natural file
# order (Features, Bug Fixes, Other, Completed tasks) without reasoning
# about earlier splices invalidating later indices.
_cl_process_subsection() {
  local heading="$1" mode="$2"

  _cl_locate_unreleased
  _cl_locate_subsection "$heading"
  _cl_filter_new "$mode"

  (( ${#CL_FILTERED[@]} > 0 )) || return 0

  if (( CL_SUB_HEAD >= 0 )); then
    local anchor=$CL_SUB_HEAD
    local m
    for (( m=CL_SUB_HEAD+1; m<CL_SUB_END; m++ )); do
      if [[ -n "${CL_LINES[$m]}" ]]; then
        anchor=$m
      fi
    done
    _cl_splice "$((anchor + 1))" "${CL_FILTERED[@]}"
  else
    local insert_at=$CL_UNRELEASED_END
    local new_block=()
    if (( insert_at > CL_UNRELEASED_START + 1 )) && [[ -n "${CL_LINES[$((insert_at - 1))]}" ]]; then
      new_block+=("")
    fi
    new_block+=("### $heading" "" "${CL_FILTERED[@]}")
    if (( insert_at < ${#CL_LINES[@]} )); then
      new_block+=("")
    fi
    _cl_splice "$insert_at" "${new_block[@]}"
  fi
  return 0
}

if (( STANDALONE )); then
  GENERATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  {
    printf '# Release notes\n\n'
    printf -- '- Generated: %s\n' "$GENERATED_AT"
    if [[ -n "$TARGET_NAME" ]]; then
      printf -- '- Target: %s\n' "$TARGET_NAME"
    fi
    if [[ -n "$LAST_TAG" ]]; then
      printf -- '- Changes: %s..%s\n\n' "$LAST_TAG" "$TO_REF"
    else
      printf -- '- Changes: full history through %s\n\n' "$TO_REF"
      if (( FIRST_RELEASE )); then
        printf '> First release — full history included\n\n'
      fi
    fi
  } > "$OUTPUT_PATH"

  write_section 'Features' FEATURES
  write_section 'Bug Fixes' BUG_FIXES
  write_section 'Other' OTHER

  COMPLETED_TASKS="$(collect_completed_tasks "$CUTOFF_DATE" || true)"
  if [[ -n "$COMPLETED_TASKS" ]]; then
    {
      printf '### Completed tasks\n'
      printf '%s\n' "$COMPLETED_TASKS"
      printf '\n'
    } >> "$OUTPUT_PATH"
  fi

  printf '📝 Release notes draft written to %s\n' "$OUTPUT_PATH"
else
  CHANGELOG_TEMPLATE="$PUBLISH_REPO_ROOT/templates/CHANGELOG_TEMPLATE.md"
  if [[ ! -f "$OUTPUT_PATH" ]]; then
    [[ -f "$CHANGELOG_TEMPLATE" ]] || {
      echo "Changelog template not found: $CHANGELOG_TEMPLATE" >&2
      exit 1
    }
    cp "$CHANGELOG_TEMPLATE" "$OUTPUT_PATH"
  fi

  _cl_load "$OUTPUT_PATH"
  _cl_locate_unreleased || {
    echo "generate_release_notes.sh: '## [Unreleased]' section not found in $OUTPUT_PATH — cannot merge entries." >&2
    exit 1
  }

  CL_NEW_ITEMS=()
  if (( ${#FEATURES[@]} > 0 )); then
    CL_NEW_ITEMS=("${FEATURES[@]}")
  fi
  _cl_process_subsection 'Features' suffix

  CL_NEW_ITEMS=()
  if (( ${#BUG_FIXES[@]} > 0 )); then
    CL_NEW_ITEMS=("${BUG_FIXES[@]}")
  fi
  _cl_process_subsection 'Bug Fixes' suffix

  CL_NEW_ITEMS=()
  if (( ${#OTHER[@]} > 0 )); then
    CL_NEW_ITEMS=("${OTHER[@]}")
  fi
  _cl_process_subsection 'Other' suffix

  COMPLETED_TASKS="$(collect_completed_tasks "$CUTOFF_DATE" || true)"
  CL_NEW_ITEMS=()
  if [[ -n "$COMPLETED_TASKS" ]]; then
    OLD_IFS="$IFS"
    IFS=$'\n'
    # Intentional word-split on newline (no mapfile in bash 3.2); each
    # collect_completed_tasks() line is a single "- ID — title" entry.
    # shellcheck disable=SC2206
    CL_NEW_ITEMS=($COMPLETED_TASKS)
    IFS="$OLD_IFS"
  fi
  _cl_process_subsection 'Completed tasks' prefix

  _cl_save "$OUTPUT_PATH"

  printf '📝 CHANGELOG.md updated: %s\n' "$OUTPUT_PATH"
fi
