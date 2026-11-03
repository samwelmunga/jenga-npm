#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-verify/scripts/verify-context.sh - the deterministic half of /j-verify
# (epic E87, story E87_S07, task E87_S07_T01)
#
# /j-verify calls the Tester retroactively on ONE already-implemented task, with the evidence the
# caller supplies. It exists for the case /j-close-task deliberately refuses: a task registered on the
# board after the work was built, so no commit carries its EST id and the SHA derivation finds nothing.
#
# This script holds the two deterministic steps so SKILL.md carries only the prompts and the dispatch.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   verify-context.sh expand  <id>
#   verify-context.sh context <task_id> [--evidence <value>] [--session <id>]
#   verify-context.sh -h | --help | help      print this usage on stdout, exit 0
#
# expand <id>   Converts an id of any of the three widths into the tasks beneath it, because the task is
#               /j-verify's unit of work and a story or epic id is an input convenience only.
#                 E##_S##_T##  that one task
#                 E##_S##      the ids in the story's `tasks:` frontmatter list, in order
#                 E##          for every id in the epic's `stories:` list, that story's `tasks:` list
#               One task per line, TAB-separated, no header:
#                 <task_id>\t<current status>\t<title>
#               A listed id with no board file is still printed, with the status `missing`, and a warning
#               goes to stderr - a board inconsistency is surfaced, never swallowed.
#
# context <task_id>
#               Prints ONE JSON object with everything the Tester prompt and the sender object need. It is
#               `close-task-context.sh context` output, verbatim, plus three evidence fields:
#                 {task_id, story_id, epic_id, task_file, story_file, epic_file, task_status, status_class,
#                  commits[], other_branch_commits[], sender{...},
#                  evidence[], evidence_shas[], evidence_paths[], evidence_source}
#               The base fields come from skills/j-close-task/scripts/close-task-context.sh, which is
#               invoked as a subprocess: board resolution, the status-writer rule and the sender contract
#               are already correct there and are reused, not reimplemented. `commits` and
#               `other_branch_commits` therefore stay exactly what that script derived, even when evidence
#               is supplied, so the Tester can see that the derivation found nothing.
#
#               --evidence <value>  A comma-separated list of commit SHAs and/or repo-relative paths, used
#                                   INSTEAD of the derived SHAs. May be repeated; the lists concatenate.
#                                   Each item is classified and checked:
#                                     a 7-40 character hex token must resolve to a commit in this repo
#                                     anything else is a repo-relative path and must exist on disk
#                                   A SHA that does not resolve, or a path that does not exist, exits 4
#                                   naming the item - a bad input is reported, never passed on to the
#                                   Tester. SHAs are normalised to their full 40-character form.
#                                   With evidence: evidence_source is `supplied`.
#               --session <id>      The caller's session id, handed to close-task-context.sh unchanged and
#                                   so used verbatim in the sender object. A fresh one is minted without it.
#
#               With no --evidence it falls back to the derivation close-task-context.sh already does, so a
#               normally EST-tagged task needs no extra argument: evidence is the HEAD-reachable `commits`
#               and evidence_source is `derived`.
#
#               sender.paths is always the evidence, whichever way it was obtained.
#
# WHY expand DOES NOT CALL close-task-context.sh PER TASK
#   It needs only a status and a title per task, while close-task-context.sh derives each task's commits
#   through a repository-wide git log scan. Calling it for every task of an epic would cost seconds per
#   task to produce two fields that are read straight out of the frontmatter. Per-task resolution and the
#   sender object - the parts whose shape is a contract - are delegated to it in `context` mode, which is
#   what the story asks for.
#
# This script is READ-ONLY. It writes no board file, no queue trigger and no status: the Tester is the
# only writer of a judged status (templates/SCRUM_BOARD_SCHEMA.md, "Status Writers"), and rollup stays
# /j-close-task's job.
#
# Written for macOS bash 3.2: no associative arrays, no mapfile, no realpath.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0  ok
#   1  a board file is missing or ambiguous, or a helper script is unavailable
#   2  usage
#   3  `context` found no evidence at all - none supplied and none derivable. The JSON is still printed on
#      stdout (with evidence [] and evidence_source `none`) so the caller can report the specifics, but the
#      non-zero status says: do not dispatch the Tester, /j-verify never invents evidence.
#   4  an --evidence item is not a resolvable commit, or is a path that does not exist
#   5  `expand` was given a story or epic that contains no tasks
# ---------------------------------------------------------------------------
set -u

ME="verify-context.sh"
die() { printf '%s: %s\n' "$ME" "$1" >&2; exit "${2:-1}"; }

usage() {
  sed -n '/^# ----*$/,/^set -u$/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//' -e 's/^#$//'
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac

[ "$#" -ge 2 ] || die "usage: $ME expand <id> | $ME context <task_id> [--evidence <value>] [--session <id>]" 2
mode="$1"; target="$2"; shift 2

session=""
evidence_raw=""
have_evidence=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session) [ "$#" -ge 2 ] || die "--session needs a value" 2; session="$2"; shift 2 ;;
    --evidence)
      [ "$#" -ge 2 ] || die "--evidence needs a value" 2
      have_evidence=1
      if [ -n "$evidence_raw" ]; then evidence_raw="$evidence_raw,$2"; else evidence_raw="$2"; fi
      shift 2 ;;
    *) die "unknown argument '$1'" 2 ;;
  esac
done

case "$mode" in
  expand|context) ;;
  *) die "unknown mode '$mode' (expected expand or context)" 2 ;;
esac
if [ "$mode" = "expand" ] && [ "$have_evidence" -eq 1 ]; then
  die "--evidence is only meaningful for 'context'" 2
fi

command -v jq >/dev/null 2>&1 || die "jq is required"

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$PROJECT_ROOT" ] || die "could not locate the project root from $SCRIPT_DIR"

# The package root holds skills/ and templates/: this checkout, or the installed package for a consumer.
# Same repo-or-node_modules fallback the sibling skills use.
if [ -f "$PROJECT_ROOT/skills/j-close-task/scripts/close-task-context.sh" ]; then PKG_ROOT="$PROJECT_ROOT"
else PKG_ROOT="$PROJECT_ROOT/node_modules/@jenga-ai/agent"; fi
CLOSE_CTX="$PKG_ROOT/skills/j-close-task/scripts/close-task-context.sh"
[ -f "$CLOSE_CTX" ] || die "missing helper: $CLOSE_CTX"

# --------------------------------------------------------------------------- board paths
cfg="$PROJECT_ROOT/project/configs/workflow.json"
cfg_path() { # <key> <default>
  local v=""
  [ -f "$cfg" ] && v="$(jq -r --arg k "$1" '.paths[$k] // empty' "$cfg" 2>/dev/null)"
  printf '%s' "${v:-$2}"
}
TASKS_DIR="$PROJECT_ROOT/$(cfg_path tasks project/board/tasks)"
STORIES_DIR="$PROJECT_ROOT/$(cfg_path stories project/board/stories)"
EPICS_DIR="$PROJECT_ROOT/$(cfg_path epics project/board/epics)"

find_item() { # <dir> <id> -> the one board file for the id, or empty (and status 1) when there is none
  local matches count
  matches="$(ls -1 "$1/$2.md" "$1/$2"_*.md 2>/dev/null)"
  count="$(printf '%s' "$matches" | grep -c . || true)"
  [ "$count" -eq 1 ] || return 1
  printf '%s' "$matches"
}

fm_get() { # <file> <key> -> the key's scalar value in the first frontmatter block
  awk -v k="$2" '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    index($0, k ":") == 1 { sub("^" k ":[ ]*", ""); gsub(/^"|"$/, ""); print; exit }
  ' "$1"
}

fm_list() { # <file> <key> -> one list item per line; handles the block form and the inline [a, b] form
  awk -v k="$2" '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    index($0, k ":") == 1 {
      rest = $0; sub("^" k ":[ ]*", "", rest)
      if (rest == "") { inlist = 1; next }
      gsub(/[][,"]/, " ", rest)
      n = split(rest, parts, / +/)
      for (i = 1; i <= n; i++) if (parts[i] != "") print parts[i]
      inlist = 0; next
    }
    inlist && /^[ \t]*-[ \t]*/ {
      line = $0; sub(/^[ \t]*-[ \t]*/, "", line); gsub(/^"|"$/, "", line)
      if (line != "") print line
      next
    }
    inlist && /^[^ \t]/ { inlist = 0 }
  ' "$1"
}

print_task_line() { # <task_id>
  local f st ti
  f="$(find_item "$TASKS_DIR" "$1")" || f=""
  if [ -z "$f" ]; then
    printf '%s: warning: no single board file for task %s in %s\n' "$ME" "$1" "$TASKS_DIR" >&2
    printf '%s\t%s\t%s\n' "$1" "missing" "(no board file for this id)"
    return 0
  fi
  st="$(fm_get "$f" status)"; [ -n "$st" ] || st="(no status)"
  ti="$(fm_get "$f" title)"; [ -n "$ti" ] || ti="(no title)"
  printf '%s\t%s\t%s\n' "$1" "$st" "$ti"
}

# --------------------------------------------------------------------------- expand
if [ "$mode" = "expand" ]; then
  if printf '%s' "$target" | grep -Eq '^E[0-9]+_S[0-9]+_T[0-9]+$'; then
    find_item "$TASKS_DIR" "$target" >/dev/null || die "expected exactly one board file for $target in $TASKS_DIR"
    print_task_line "$target"
    exit 0
  fi

  if printf '%s' "$target" | grep -Eq '^E[0-9]+_S[0-9]+$'; then
    story_file="$(find_item "$STORIES_DIR" "$target")" || die "expected exactly one board file for $target in $STORIES_DIR"
    tasks="$(fm_list "$story_file" tasks)"
    [ -n "$tasks" ] || die "story $target contains no tasks: its tasks: frontmatter list in $story_file is empty" 5
    printf '%s\n' "$tasks" | while IFS= read -r t; do [ -n "$t" ] && print_task_line "$t"; done
    exit 0
  fi

  if printf '%s' "$target" | grep -Eq '^E[0-9]+$'; then
    epic_file="$(find_item "$EPICS_DIR" "$target")" || die "expected exactly one board file for $target in $EPICS_DIR"
    stories="$(fm_list "$epic_file" stories)"
    [ -n "$stories" ] || die "epic $target contains no stories: its stories: frontmatter list in $epic_file is empty" 5
    out=""
    story_count=0
    for s in $stories; do
      story_count=$((story_count + 1))
      sf="$(find_item "$STORIES_DIR" "$s")" || sf=""
      if [ -z "$sf" ]; then
        printf '%s: warning: no single board file for story %s in %s\n' "$ME" "$s" "$STORIES_DIR" >&2
        continue
      fi
      st_tasks="$(fm_list "$sf" tasks)"
      if [ -z "$st_tasks" ]; then
        printf '%s: warning: story %s contains no tasks (empty tasks: list in %s)\n' "$ME" "$s" "$sf" >&2
        continue
      fi
      if [ -n "$out" ]; then out="$out
$st_tasks"; else out="$st_tasks"; fi
    done
    [ -n "$out" ] || die "epic $target expands to no tasks: none of its $story_count stories has a non-empty tasks: list" 5
    printf '%s\n' "$out" | while IFS= read -r t; do [ -n "$t" ] && print_task_line "$t"; done
    exit 0
  fi

  die "invalid id '$target' (expected E##, E##_S## or E##_S##_T##)" 2
fi

# --------------------------------------------------------------------------- context
printf '%s' "$target" | grep -Eq '^E[0-9]+_S[0-9]+_T[0-9]+$' \
  || die "invalid task id '$target' (expected E##_S##_T##; use 'expand' to turn a story or epic id into tasks)" 2

if [ -n "$session" ]; then
  base="$(bash "$CLOSE_CTX" context "$target" --session "$session")" || die "close-task-context.sh context $target failed"
else
  base="$(bash "$CLOSE_CTX" context "$target")" || die "close-task-context.sh context $target failed"
fi
[ -n "$base" ] || die "close-task-context.sh context $target produced no output"

shas="[]"; paths="[]"
if [ "$have_evidence" -eq 1 ]; then
  source_label="supplied"
  while IFS= read -r item; do
    item="$(printf '%s' "$item" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$item" ] || continue
    if printf '%s' "$item" | grep -Eq '^[0-9a-fA-F]{7,40}$'; then
      full="$(git -C "$PROJECT_ROOT" rev-parse --verify --quiet "${item}^{commit}" 2>/dev/null || true)"
      [ -n "$full" ] || die "evidence '$item' looks like a commit sha but does not resolve to a commit in $PROJECT_ROOT" 4
      shas="$(printf '%s' "$shas" | jq -c --arg s "$full" '. + [$s]')"
    else
      case "$item" in
        /*) abs="$item" ;;
        *)  abs="$PROJECT_ROOT/$item" ;;
      esac
      [ -e "$abs" ] || die "evidence path '$item' does not exist (looked for $abs)" 4
      paths="$(printf '%s' "$paths" | jq -c --arg p "$item" '. + [$p]')"
    fi
  done <<EVIDENCE
$(printf '%s' "$evidence_raw" | tr ',' '\n')
EVIDENCE
  if [ "$(printf '%s%s' "$shas" "$paths")" = "[][]" ]; then
    die "--evidence was given but contains no items" 2
  fi
else
  source_label="derived"
  shas="$(printf '%s' "$base" | jq -c '.commits')"
fi

out="$(printf '%s' "$base" | jq -c \
  --argjson shas "$shas" --argjson paths "$paths" --arg src "$source_label" '
  ($shas + $paths) as $ev
  | . + {evidence: $ev, evidence_shas: $shas, evidence_paths: $paths,
         evidence_source: (if ($ev | length) == 0 then "none" else $src end)}
  | .sender.paths = $ev')" || die "could not assemble the context JSON"

printf '%s\n' "$out"

if [ "$(printf '%s' "$out" | jq -r '.evidence | length')" = "0" ]; then
  die "no evidence for $target: none supplied with --evidence and none derivable from EST-tagged commits - supply evidence rather than dispatching the Tester without it" 3
fi
exit 0
