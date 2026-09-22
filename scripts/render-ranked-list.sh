#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/render-ranked-list.sh
#
# Shared implementation of /dooo's step 2 (identify parallelisable
# stories/tasks against project/todo.md) and step 3 (render them as a
# numbered list). Extracted per E63_S01_T01 so this logic exists exactly
# once — /dooo calls this script instead of describing the scan/render as
# inline prose, and a sibling task (E63_S01_T03, not yet started) wires
# `/todo --ranked-list` onto the same script rather than writing a second,
# independent copy of the eligibility scan.
#
# ---------------------------------------------------------------------------
# THE ELIGIBILITY RULE (verbatim from /dooo's prior prose — do not alter here
# without updating the source-of-truth prose in the parent story/task board
# files first; this script is a faithful extraction, not a redesign)
# ---------------------------------------------------------------------------
# A story or task is eligible if ALL of:
#   - its status is exactly `Pending`
#   - it has no unresolved dependencies: every ID listed in its `depends_on`
#     frontmatter field resolves to a board file whose own `status` is one of
#     `Running`, `In Progress`, or `Passed`. The pre-extraction SKILL.md prose
#     literally named only `Running`/`Passed`; `In Progress` is added here
#     per this task's own board-file description of the rule (which paired
#     `Running`/`In Progress` as the two items' in-work labels) and because no
#     board file has ever actually carried `status: Running` (the schema's
#     real in-work value is `In Progress` — see
#     templates/SCRUM_BOARD_SCHEMA.md's Status Values table), so this is a
#     faithful reproduction of the rule's real-world effect, not a behavior
#     change. This three-value set otherwise still excludes `Passed with
#     remarks`, `Merged`, and `Done`, same as the original prose.
#   - it is directly listed in project/todo.md's real entries, OR (for tasks)
#     its parent story is listed there
#
# Candidates are read from two directories: project/board/stories/*.md and
# project/board/tasks/*.md. A third directory, project/board/epics/*.md, is
# read only to resolve the status of a dependency that happens to be an
# epic ID.
#
# ---------------------------------------------------------------------------
# OUTPUT SHAPE — binding
# ---------------------------------------------------------------------------
# 1-indexed "<id> — <title>" lines, one per eligible item, stories first then
# tasks, each group in deterministic (sorted) board-file order. No trailing
# "Done" option, no prompt text — that is /dooo's own interactive framing,
# added on top of this script's output, not part of it.
#
# Fully deterministic: identical board/todo.md state produces byte-identical
# output across runs. No clock, no randomness, no filesystem-order dependence
# (directory reads are sorted under LC_ALL=C).
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   scripts/render-ranked-list.sh
#
# Assumes CWD is the project root, matching scripts/board_resolver.sh and
# scripts/todo_manager.sh's existing convention. Paths may be overridden via
# environment variables (for test fixtures, or for callers rooted somewhere
# other than the CWD), in the style of validate-typed-object.sh's
# JENGA_PLAYBOOK_TYPES_FILE hook:
#
#   JENGA_TODO_FILE           Default: project/todo.md
#   JENGA_BOARD_STORIES_DIR   Default: project/board/stories
#   JENGA_BOARD_TASKS_DIR     Default: project/board/tasks
#   JENGA_BOARD_EPICS_DIR     Default: project/board/epics
# ---------------------------------------------------------------------------

set -euo pipefail
export LC_ALL=C

TODO_FILE="${JENGA_TODO_FILE:-project/todo.md}"
STORIES_DIR="${JENGA_BOARD_STORIES_DIR:-project/board/stories}"
TASKS_DIR="${JENGA_BOARD_TASKS_DIR:-project/board/tasks}"
EPICS_DIR="${JENGA_BOARD_EPICS_DIR:-project/board/epics}"

# The literal, verbatim-preserved "resolved" status set for a dependency.
RESOLVED_STATUSES="Running
In Progress
Passed"

is_resolved_status() {
  local status="$1"
  local s
  while IFS= read -r s; do
    if [ "$status" = "$s" ]; then
      return 0
    fi
  done <<EOF
$RESOLVED_STATUSES
EOF
  return 1
}

# ---------------------------------------------------------------------------
# Frontmatter helpers
# ---------------------------------------------------------------------------

# frontmatter_values <file> <field>
# Prints each value for <field> on its own line: a single line for an inline
# scalar (`field: value`), or one line per `- item` for a YAML block list
# (`field:` with nothing after the colon, followed by indented `- ` lines).
# Prints nothing if the field is absent or has an empty/None-ish value.
frontmatter_values() {
  local file="$1" field="$2"
  awk -v f="$field" '
    BEGIN { infm = 0; found = 0 }
    /^---[[:space:]]*$/ {
      if (infm == 0) { infm = 1; next } else { exit }
    }
    infm == 1 {
      if (found == 1) {
        if ($0 ~ /^[[:space:]]*-[[:space:]]*/) {
          line = $0
          sub(/^[[:space:]]*-[[:space:]]*/, "", line)
          sub(/[[:space:]]*$/, "", line)
          print line
          next
        } else {
          exit
        }
      }
      if ($0 ~ "^" f ":[[:space:]]*$") { found = 1; next }
      if ($0 ~ "^" f ":[[:space:]]") {
        line = $0
        sub("^" f ":[[:space:]]*", "", line)
        sub(/[[:space:]]*$/, "", line)
        print line
        exit
      }
      if ($0 ~ "^" f ":$") { exit }
    }
  ' "$file"
}

frontmatter_scalar() {
  frontmatter_values "$1" "$2" | head -n1
}

# ---------------------------------------------------------------------------
# ID → status resolution
# ---------------------------------------------------------------------------

# id_dir <id> — picks the board directory an ID belongs to, by shape:
# 0 underscores -> epic, 1 -> story, 2 -> task.
id_dir() {
  local id="$1"
  local underscores
  underscores=$(printf '%s' "$id" | tr -cd '_' | wc -c | tr -d ' ')
  case "$underscores" in
    0) printf '%s' "$EPICS_DIR" ;;
    1) printf '%s' "$STORIES_DIR" ;;
    *) printf '%s' "$TASKS_DIR" ;;
  esac
}

# status_of <id> — prints the status of the board file matching <id>, or
# nothing if no such file exists (a dangling/unresolvable reference).
status_of() {
  local id="$1"
  local dir file
  dir=$(id_dir "$id")
  for file in "$dir"/"$id"_*.md; do
    [ -e "$file" ] || continue
    frontmatter_scalar "$file" "status"
    return 0
  done
  return 0
}

# deps_resolved <file> — true (exit 0) if every depends_on ID resolves to a
# board file whose status is in RESOLVED_STATUSES. No depends_on, or only
# empty/None-ish entries, counts as resolved.
deps_resolved() {
  local file="$1"
  local dep status
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    case "$dep" in
      [Nn]one) continue ;;
    esac
    status=$(status_of "$dep")
    if [ -z "$status" ] || ! is_resolved_status "$status"; then
      return 1
    fi
  done < <(frontmatter_values "$file" "depends_on")
  return 0
}

# ---------------------------------------------------------------------------
# todo.md real-entries + listing check
# ---------------------------------------------------------------------------

# Mirrors todo_manager.sh's real_entries() filter (blank lines, `#` comments,
# HTML `<!-- -->` comments stripped). Duplicated in miniature rather than
# shelled out to todo_manager.sh, since that script hardcodes its own
# project/todo.md path with no override hook and this script must also run
# against test fixtures and arbitrary project roots.
TODO_REAL_ENTRIES=""
if [ -f "$TODO_FILE" ]; then
  TODO_REAL_ENTRIES=$(grep -v '^[[:space:]]*$' "$TODO_FILE" 2>/dev/null \
    | grep -v '^[[:space:]]*#' \
    | grep -v '^[[:space:]]*<!--' || true)
fi

# todo_lists <id> — true if <id> appears, word-bounded, in a real todo.md
# entry line.
todo_lists() {
  local id="$1"
  [ -z "$TODO_REAL_ENTRIES" ] && return 1
  printf '%s\n' "$TODO_REAL_ENTRIES" \
    | grep -Eq "(^|[^A-Za-z0-9_])${id}([^A-Za-z0-9_]|\$)"
}

# ---------------------------------------------------------------------------
# Eligibility scan
# ---------------------------------------------------------------------------

ELIGIBLE=""

add_eligible() {
  local id="$1" title="$2"
  ELIGIBLE="${ELIGIBLE}${id}"$'\t'"${title}"$'\n'
}

scan_stories() {
  local file id status title
  for file in $(find "$STORIES_DIR" -maxdepth 1 -name '*.md' 2>/dev/null | sort); do
    id=$(frontmatter_scalar "$file" "id")
    [ -z "$id" ] && continue
    status=$(frontmatter_scalar "$file" "status")
    [ "$status" = "Pending" ] || continue
    deps_resolved "$file" || continue
    todo_lists "$id" || continue
    title=$(frontmatter_scalar "$file" "title")
    add_eligible "$id" "$title"
  done
}

scan_tasks() {
  local file id story_id status title
  for file in $(find "$TASKS_DIR" -maxdepth 1 -name '*.md' 2>/dev/null | sort); do
    id=$(frontmatter_scalar "$file" "id")
    [ -z "$id" ] && continue
    status=$(frontmatter_scalar "$file" "status")
    [ "$status" = "Pending" ] || continue
    deps_resolved "$file" || continue
    story_id=$(frontmatter_scalar "$file" "story_id")
    if todo_lists "$id" || { [ -n "$story_id" ] && todo_lists "$story_id"; }; then
      title=$(frontmatter_scalar "$file" "title")
      add_eligible "$id" "$title"
    fi
  done
}

scan_stories
scan_tasks

# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------

n=0
while IFS=$'\t' read -r id title; do
  [ -z "$id" ] && continue
  n=$((n + 1))
  printf '%d. %s — %s\n' "$n" "$id" "$title"
done <<EOF
$ELIGIBLE
EOF
