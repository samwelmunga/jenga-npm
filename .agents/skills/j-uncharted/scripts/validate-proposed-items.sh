#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-uncharted/scripts/validate-proposed-items.sh
#
# Post-write gate for `/uncharted segment` Step 7. Given the board files a
# confirmed proposal just wrote, it answers one mechanical question: do these
# files pass the validators the rest of the project already enforces?
#
# It validates. It NEVER writes, moves, or repairs a board file, and it has no
# opinion about content — only about format. Deciding what to do with a failure
# (fix and re-run, or roll the write back) is agent judgement and lives in
# `skills/j-uncharted/SKILL.md`.
#
#   Usage: validate-proposed-items.sh <board-file> [more-files...]
#
# It reuses the two existing validators rather than reimplementing them:
#
#   scripts/validate-board.sh         frontmatter — run against EVERY supplied
#                                     file (epic, story, and task alike)
#   scripts/validate-story-format.sh  body sections — run against every supplied
#                                     STORY file only
#
# A file is treated as a story when its frontmatter `id` matches E##_S##. That
# is the same classification `validate-board.sh` makes, and it reads the file
# rather than trusting the path, so a story that landed in the wrong directory
# is still checked as a story.
#
# EVERY FAILURE IS REPORTED. The script does not stop at the first bad file: a
# half-checked board is the same problem as a half-written one, and an agent
# deciding whether to roll back needs the whole list, not the first line of it.
# Both validators run under `set -euo pipefail`, so each call here is guarded
# (`|| rc=$?`) — an unguarded call would abort this script on the first failure
# and silently under-report the rest.
#
# `validate-story-format.sh` exit codes are reported rather than flattened to
# "failed", because they name the defect: 2 = no `## Acceptance Criteria`,
# 3 = no `## Definition of Done`, 4 = a Definition of Done with no `- [ ]`
# checkboxes.
#
#   Exit  0  every supplied file passed every applicable validator
#         1  at least one file failed; each failure is printed
#         2  usage error, or a required validator is missing
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$REPO_ROOT" ] || REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd -P)

BOARD_VALIDATOR="$REPO_ROOT/scripts/validate-board.sh"
STORY_VALIDATOR="$REPO_ROOT/scripts/validate-story-format.sh"

usage() {
  echo "Usage: $(basename "$0") <board-file> [more-files...]" >&2
  echo "       Validates newly written epic/story/task files. Exits 1 listing every failure." >&2
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "")        echo "❌ no board files supplied" >&2; usage; exit 2 ;;
esac

# Checked for executability, not just existence. A present-but-non-executable validator would
# otherwise return 126 and be recorded as an ordinary per-file failure — and since SKILL.md reads
# exit 1 as "repair or roll the whole write back", a stripped exec bit would roll back a board
# write that was perfectly valid. A broken checkout must not read as a bad proposal.
for v in "$BOARD_VALIDATOR" "$STORY_VALIDATOR"; do
  if [ ! -f "$v" ]; then
    echo "❌ required validator not found: $v" >&2
    exit 2
  fi
  if [ ! -x "$v" ]; then
    echo "❌ required validator is not executable: $v" >&2
    exit 2
  fi
done

# Frontmatter `id` of a board file; empty when the frontmatter is absent or malformed
# (in which case validate-board.sh has already reported it as a failure).
item_id() {
  awk '
    NR == 1 { if ($0 !~ /^---[[:space:]]*$/) exit; next }
    /^---[[:space:]]*$/ { exit }
    /^id:[[:space:]]*/ {
      sub(/^id:[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, "")
      gsub(/"/, ""); gsub(/'"'"'/, ""); sub(/[[:space:]]+$/, "")
      print; exit
    }
  ' "$1" 2>/dev/null || true
}

# Runs one validator against one file, recording a failure instead of aborting.
FAILURES=()
check() {
  local label="$1" validator="$2" file="$3" rc=0 out=""
  out=$("$validator" "$file" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    FAILURES+=("❌ $file — $label ($(basename "$validator") exit $rc)
$(printf '%s\n' "$out" | sed 's/^/     /')")
  fi
}

CHECKED=0 STORIES=0
for file in "$@"; do
  CHECKED=$((CHECKED + 1))
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    FAILURES+=("❌ $file — file not found or not readable")
    continue
  fi
  check "board frontmatter" "$BOARD_VALIDATOR" "$file"
  if [[ "$(item_id "$file")" =~ ^E[0-9]{2}_S[0-9]{2}$ ]]; then
    STORIES=$((STORIES + 1))
    check "story format" "$STORY_VALIDATOR" "$file"
  fi
done

if [ "${#FAILURES[@]}" -gt 0 ]; then
  echo "❌ ${#FAILURES[@]} validation failure(s) across $CHECKED file(s):" >&2
  printf '%s\n' "${FAILURES[@]}" >&2
  exit 1
fi

echo "✅ $CHECKED board file(s) valid ($STORIES story file(s) additionally format-checked)"
exit 0
