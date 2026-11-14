#!/usr/bin/env bash
# scripts/pipeline-stage.sh - which stages of the Jenga pipeline currently have work (epic E92, task E92_S04_T01).
#
# The pipeline is todo -> do -> test -> rollup (CLAUDE.md "Workflow Lifecycle"). It is NOT a j.workflow run: no
# workflow run state is read. The rule for "which stage has work" is fixed here, once:
#
#   todo    the number of entries `scripts/todo_manager.sh list` prints (that script owns todo.md parsing; it is run with
#           the anchor directory as cwd because it reads the relative project/todo.md).
#   do      levels.tasks.totals.in_progress of `scripts/board-progress.sh --all` (no counting of its own; an empty scope,
#           exit 3, is count 0). This script knows no status names.
#   test    the lines of <queue>/tester_triggers.jsonl whose "type" is "test_assignment" (the tester's own queue). The
#           developer normally calls the tester synchronously, so this stage is lit only while a test_assignment is
#           queued and is usually 0.
#   rollup  the lines of <queue>/scrum_triggers.jsonl whose "type" is "story_rollup". status_review and rapport_review
#           lines are NOT counted: hooks/on_session_end.sh appends a status_review at every session end, so counting
#           them would keep the stage lit forever.
#
# <queue> is `scripts/resolve-root.sh get queue`. A missing queue file is count 0. A queue line that is not valid JSON, or
# is valid JSON but not an object, is skipped and counted in "skipped" (both queue files together); it never fails the run.
# A stage is "active" when its count is above 0. Several stages can be active at once and all are listed, in stage order;
# no single "the" current stage is forced. "idle" is true when no stage is active.
#
# Usage: pipeline-stage.sh [--root <dir>]
#   --root <dir>   working-file anchor (default: scripts/resolve-root.sh, i.e. JENGA_PROJECT_ROOT or an upward search)
# Prints one line of JSON, in this key order and stage order, with no timestamps (equal input gives identical bytes):
#   {"schema_version":1,"stages":[{"id":"todo","label":"To do","count":N,"active":bool},{"id":"do","label":"Do",...},
#    {"id":"test","label":"Test",...},{"id":"rollup","label":"Rollup",...}],"active":["do",...],"idle":bool,"skipped":N}
#
# Exit codes: 0 ok; 1 internal error (a called script failed); 2 usage error, unresolvable root, or jq missing (the message
# names jq). On a non-zero exit the message goes to stderr and stdout stays empty. No model call; writes nothing.
# Compatible with macOS bash 3.2.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { # <code> <message>
  printf 'pipeline-stage.sh: %s\n' "$2" >&2
  exit "$1"
}

usage() {
  cat <<'USAGE'
Usage: pipeline-stage.sh [--root <dir>]
  --root <dir>   working-file anchor (default: scripts/resolve-root.sh)
Prints JSON (schema_version 1): the four pipeline stages (todo, do, test, rollup) with counts, the active ones and idle.
Exit: 0 ok, 1 internal, 2 usage, unresolvable root or jq missing.
USAGE
}

ROOT_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --root)
      [ $# -ge 2 ] || { usage >&2; die 2 "--root needs a directory argument"; }
      ROOT_OVERRIDE="$2"; shift 2 ;;
    --root=*) ROOT_OVERRIDE="${1#*=}"; shift ;;
    *) usage >&2; die 2 "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die 2 "jq is required but was not found on PATH"

if [ -n "$ROOT_OVERRIDE" ]; then
  [ -d "$ROOT_OVERRIDE" ] || die 2 "--root is not a directory: $ROOT_OVERRIDE"
  JENGA_PROJECT_ROOT="$(cd "$ROOT_OVERRIDE" && pwd)"
  export JENGA_PROJECT_ROOT
fi

RESOLVE="$SCRIPT_DIR/resolve-root.sh"
ROOT="$("$RESOLVE" root)" || die 2 "cannot resolve the working-file root"
QUEUE="$("$RESOLVE" get queue)" || die 2 "cannot resolve the queue directory"

# ---- todo: entries todo_manager.sh lists (it reads the relative project/todo.md, so cwd is the anchor) -------------
TODO_COUNT="$(cd "$ROOT" && "$SCRIPT_DIR/todo_manager.sh" list 2>/dev/null | awk 'END { print NR + 0 }')" \
  || die 1 "todo_manager.sh list failed"

# ---- do: the in-progress bucket of board-progress.sh --all (exit 3 = empty scope = 0) --------------------------------
DO_COUNT=0
BP_OUT="$("$SCRIPT_DIR/board-progress.sh" --all --root "$ROOT" 2>/dev/null)"
BP_RC=$?
case "$BP_RC" in
  0) DO_COUNT="$(printf '%s' "$BP_OUT" | jq -r '.levels.tasks.totals.in_progress // 0')" \
       || die 1 "cannot read levels.tasks.totals.in_progress from board-progress.sh output" ;;
  3) DO_COUNT=0 ;;
  *) die 1 "board-progress.sh --all failed (exit $BP_RC)" ;;
esac

# ---- queue counting: "<matching> <skipped>" for one file and one trigger type ----------------------------------------
queue_counts() { # <file> <type>
  if [ ! -f "$1" ]; then
    printf '0 0\n'
    return 0
  fi
  jq -R -n -r --arg t "$2" '
    [ inputs | select(test("[^[:space:]]")) | (try ({ ok: fromjson }) catch { bad: true }) ]
    | (map(select(.ok? != null and (.ok | type) == "object")) | map(select(.ok.type == $t)) | length) as $n
    | (map(select(.ok? == null or (.ok | type) != "object")) | length) as $s
    | "\($n) \($s)"
  ' "$1"
}

TEST_LINE="$(queue_counts "$QUEUE/tester_triggers.jsonl" test_assignment)" || die 1 "cannot read tester_triggers.jsonl"
ROLL_LINE="$(queue_counts "$QUEUE/scrum_triggers.jsonl" story_rollup)" || die 1 "cannot read scrum_triggers.jsonl"
TEST_COUNT="${TEST_LINE% *}"; TEST_SKIP="${TEST_LINE#* }"
ROLL_COUNT="${ROLL_LINE% *}"; ROLL_SKIP="${ROLL_LINE#* }"
SKIPPED=$((TEST_SKIP + ROLL_SKIP))

jq -n -c \
  --argjson todo "$TODO_COUNT" --argjson do "$DO_COUNT" --argjson test "$TEST_COUNT" --argjson rollup "$ROLL_COUNT" \
  --argjson skipped "$SKIPPED" '
  [ { id: "todo",   label: "To do",  count: $todo },
    { id: "do",     label: "Do",     count: $do },
    { id: "test",   label: "Test",   count: $test },
    { id: "rollup", label: "Rollup", count: $rollup } ]
  | map(. + { active: (.count > 0) }) as $stages
  | { schema_version: 1,
      stages: $stages,
      active: ($stages | map(select(.active) | .id)),
      idle: ($stages | all(.active | not)),
      skipped: $skipped }
'
