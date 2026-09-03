#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/close-story/scripts/check-privatized.sh
#
# Static (run-independent) `.publicignore` membership check for a single
# board ticket, invoked by /close-story at both task granularity (Step 2's
# per-task loop) and story granularity (Step 4's finalization), per
# E51_S03_T03. Unlike `Merged` (skills/self-sync/scripts/mark-merged.sh) and
# `Publicized` (skills/mirror-public/scripts/mark-publicized.sh, E51_S03_T02),
# which both react to a specific run's file diff, `Privatized` has NO
# dependency on any run ever having occurred -- it is a pure blocklist
# membership test against the ticket's own derived touched-file list, per
# templates/SCRUM_BOARD_SCHEMA.md's "Static vs. Reactive Status Setting"
# section.
#
# Usage: check-privatized.sh <id> <board-file-path>
#
#   <id>               EST ticket id -- a task id (E##_S##_T##) or a story id
#                       (E##_S##). The anchored-grep commit matching (below)
#                       is what keeps a story id from over-matching its own
#                       children's commits, so the same script handles both
#                       granularities with no separate code path.
#   <board-file-path>   Path to the ticket's own board markdown file (task or
#                       story), used to read its current `status:` and as the
#                       write target.
#
# Touched-file derivation -- IDENTICAL technique to
# skills/self-sync/scripts/mark-merged.sh (reused, not reinvented, per this
# task's own description):
#   1. git log --all --no-merges --extended-regexp \
#        --grep="<id>([^0-9_]|$)" --pretty=format:'%H'
#      The anchored pattern (not a plain substring grep) is required so a
#      story id like "E51_S03" does not over-match every one of its own
#      child tasks' commits -- the character immediately following a story
#      id in a child task's commit message is "_", which the anchor
#      excludes.
#   2. Per matched commit: `git diff --name-only <sha>~1..<sha>`, falling
#      back to `git diff-tree --no-commit-id --name-only -r <sha>` for a
#      root commit with no parent.
#   3. Union (dedup) the file paths across all matched commits.
#   4. Zero matched commits -> nothing to check -> UNCHANGED (not an error).
#
# .publicignore matching -- ported (not sourced) from
# skills/mirror-public/scripts/mirror.sh's `_publicignore_rule_for` helper:
# directory-prefix match for trailing-"/" lines, glob match against the full
# relative path and the basename for everything else, skipping comments,
# blank lines, and "+"-prefixed include lines (which never block anything).
# This is a deliberate, flagged duplication of matching logic -- not a
# `source` of mirror.sh, which unconditionally loads config.json and
# requires rsync near the top of its execution, neither of which this
# lighter, dependency-free check needs. Same tradeoff mark-merged.sh's own
# header comment already documents and accepts for its COPY_SET extraction.
#
# A ticket is "fully blocklisted" iff EVERY file in its derived touched-file
# list matches SOME .publicignore pattern. Partial coverage leaves the
# ticket unchanged, no error (mirrors AC5's "no files fully covered"
# language, applied to the blocklist side).
#
# Precedence / mismatch logging (AC4, this script's half of it): a ticket
# already at `status: Publicized` that is found fully blocklisted still gets
# overwritten to `Privatized` (Privatized wins -- the static, always-knowable
# check takes precedence per the story's AC4 and
# templates/SCRUM_BOARD_SCHEMA.md's "Publicized / Privatized / Deployed
# Lifecycle Relationship" section), but the contradiction is logged to
# project/logs/events.json as `event: publicized_privatized_mismatch` (same
# array-of-objects convention already used by session_start/etc., and the
# same event name E51_S03_T02's own task description documents for the
# reverse-direction mismatch) so it's flagged for investigation rather than
# silently resolved. The read-modify-write against events.json is wrapped in
# scripts/with-lock.sh since multiple sessions may be writing to it
# concurrently.
#
# A ticket already at `status: Privatized` is skipped without error
# (idempotency) -- same defensive-skip convention mark-merged.sh uses for
# its own terminal status.
#
# Output contract (stdout, single line) -- consumed by /close-story's prose
# steps to decide whether to report a Privatized ticket:
#   PRIVATIZED   status was written (or already Privatized -- treated the
#                same by the caller: either way the ticket ends this call at
#                status Privatized)
#   UNCHANGED    ticket left as-is (zero matched commits, partial coverage,
#                or already Privatized with nothing further to do)
#
# Exit codes:
#   0   success (covers both PRIVATIZED and UNCHANGED outcomes)
#   1   error (bad usage, missing file, or a status-write failure)
# ---------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

die() {
  printf 'check-privatized.sh: error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf 'check-privatized.sh: %s\n' "$*" >&2
}

usage() {
  cat <<'EOF'
Usage: check-privatized.sh <id> <board-file-path>

Static .publicignore membership check for a single ticket (task or story).
Prints PRIVATIZED or UNCHANGED to stdout. See script header for full
semantics.
EOF
}

if [ $# -ne 2 ]; then
  usage >&2
  die "expected exactly 2 arguments, got $#"
fi

ID="$1"
BOARD_FILE="$2"

[ -f "$BOARD_FILE" ] || die "board file not found: $BOARD_FILE"

# -----------------------------------------------------------------------------
# Locate script + repo root (same symlink-resolution + repo-root derivation
# pattern as mark-merged.sh, so this script behaves identically whether
# invoked directly or via a symlink).
# -----------------------------------------------------------------------------

SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -h "$SCRIPT_PATH" ]; do
  LINK_TARGET="$(readlink "$SCRIPT_PATH")"
  case "$LINK_TARGET" in
    /*) SCRIPT_PATH="$LINK_TARGET" ;;
    *)  SCRIPT_PATH="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/$LINK_TARGET" ;;
  esac
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || die "could not locate repo root (git rev-parse failed from $SCRIPT_DIR)"

PUBLICIGNORE="$REPO_ROOT/.publicignore"
[ -f "$PUBLICIGNORE" ] || die ".publicignore not found at $PUBLICIGNORE"

WITH_LOCK_SCRIPT="$REPO_ROOT/scripts/with-lock.sh"
UPDATE_FRONTMATTER_SCRIPT="$REPO_ROOT/skills/close-story/scripts/update-task-frontmatter.sh"
EVENTS_FILE="$REPO_ROOT/project/logs/events.json"

[ -f "$WITH_LOCK_SCRIPT" ] || die "expected script not found: $WITH_LOCK_SCRIPT"
[ -f "$UPDATE_FRONTMATTER_SCRIPT" ] || die "expected script not found: $UPDATE_FRONTMATTER_SCRIPT"

# -----------------------------------------------------------------------------
# Frontmatter field reader -- same "line == ---" boundary-detection style
# already used by update-task-frontmatter.sh / mark-merged.sh.
# -----------------------------------------------------------------------------

read_frontmatter_field() {
  local file="$1" key="$2"
  awk -v key="$key" '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---" { exit }
    infm && $0 ~ ("^" key ":") {
      sub("^" key ":[ \t]*", "", $0)
      print $0
      exit
    }
  ' "$file"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  s="${s%\"}"; s="${s#\"}"
  s="${s%\'}"; s="${s#\'}"
  printf '%s' "$s"
}

CURRENT_STATUS="$(trim "$(read_frontmatter_field "$BOARD_FILE" "status")")"

if [ "$CURRENT_STATUS" = "Privatized" ]; then
  log "$ID: already Privatized -- skip (idempotent no-op)"
  echo "UNCHANGED"
  exit 0
fi

# -----------------------------------------------------------------------------
# Touched-file derivation -- identical technique to mark-merged.sh.
# -----------------------------------------------------------------------------

commits_for_ticket() {
  local id="$1"
  git -C "$REPO_ROOT" log --all --no-merges --extended-regexp \
    --grep="${id}([^0-9_]|\$)" --pretty=format:'%H' 2>/dev/null || true
}

commit_files() {
  local sha="$1"
  if git -C "$REPO_ROOT" rev-parse --verify -q "${sha}~1" >/dev/null 2>&1; then
    git -C "$REPO_ROOT" diff --name-only "${sha}~1..${sha}" 2>/dev/null || true
  else
    git -C "$REPO_ROOT" diff-tree --no-commit-id --name-only -r "$sha" 2>/dev/null || true
  fi
}

collect_touched_files() {
  local id="$1"
  local shas sha
  shas="$(commits_for_ticket "$id")"
  [ -n "$shas" ] || return 0
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    commit_files "$sha"
  done <<< "$shas" | sort -u
}

TOUCHED="$(collect_touched_files "$ID")"

if [ -z "$TOUCHED" ]; then
  log "$ID: zero matched EST-tagged commits -- left unchanged"
  echo "UNCHANGED"
  exit 0
fi

# -----------------------------------------------------------------------------
# .publicignore matching -- ported from mirror.sh's _publicignore_rule_for.
#
# Prints the matching .publicignore line and returns 0 on a match; returns 1
# with no output if nothing matched. Directory-prefix match for trailing-"/"
# lines, glob match against the full relative path and the basename for
# everything else, skipping comments/blank lines/"+"-prefixed include lines.
# -----------------------------------------------------------------------------

_publicignore_rule_for() {
  local rel_path="$1" line pattern base dirpat
  base="$(basename "$rel_path")"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*|'+'*) continue ;;
    esac
    pattern="$line"
    case "$pattern" in
      '- '*) pattern="${pattern#- }" ;;
    esac
    [ -n "$pattern" ] || continue
    case "$pattern" in
      */)
        dirpat="${pattern%/}"
        case "$rel_path" in
          "$dirpat"/*)
            printf '%s\n' "$line"
            return 0
            ;;
        esac
        ;;
      *)
        case "$rel_path" in
          $pattern)
            printf '%s\n' "$line"
            return 0
            ;;
        esac
        case "$base" in
          $pattern)
            printf '%s\n' "$line"
            return 0
            ;;
        esac
        ;;
    esac
  done < "$PUBLICIGNORE"
  return 1
}

# True (0) iff every line of $1 (touched files, newline-separated) matches
# some .publicignore pattern.
is_fully_blocklisted() {
  local touched="$1"
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    _publicignore_rule_for "$line" >/dev/null || return 1
  done <<< "$touched"
  return 0
}

if ! is_fully_blocklisted "$TOUCHED"; then
  log "$ID: not fully covered by .publicignore -- left unchanged"
  echo "UNCHANGED"
  exit 0
fi

# -----------------------------------------------------------------------------
# Fully blocklisted. Precedence check against a contradictory Publicized
# status (AC4) before writing.
# -----------------------------------------------------------------------------

if [ "$CURRENT_STATUS" = "Publicized" ]; then
  log "$ID: WARNING -- ticket is status: Publicized but every touched file matches .publicignore; Privatized takes precedence (overwriting), logging mismatch"

  TOUCHED_JSON_LIST="$(printf '%s\n' "$TOUCHED" | awk '
    BEGIN { printf "[" ; first=1 }
    { if (!first) printf ","; printf "\"%s\"", $0; first=0 }
    END { printf "]" }
  ')"
  [ -n "$TOUCHED_JSON_LIST" ] || TOUCHED_JSON_LIST="[]"

  MISMATCH_EVENT=$(printf '{"event": "publicized_privatized_mismatch", "agent": "developer", "id": "%s", "file": "%s", "touched_files": %s, "date": "%s"}' \
    "$ID" "$BOARD_FILE" "$TOUCHED_JSON_LIST" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")

  if [ -f "$EVENTS_FILE" ]; then
    "$WITH_LOCK_SCRIPT" "$EVENTS_FILE" -- bash -c '
      set -euo pipefail
      events_file="$1"
      new_event="$2"
      tmp="$(mktemp)"
      if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json, sys
path = sys.argv[1]
new_event = json.loads(sys.argv[2])
with open(path) as f:
    data = json.load(f)
data.append(new_event)
with open(path, \"w\") as f:
    json.dump(data, f, indent=2)
    f.write(\"\n\")
" "$events_file" "$new_event"
      else
        echo "check-privatized.sh: python3 not available -- could not append mismatch event" >&2
        rm -f "$tmp"
        exit 1
      fi
    ' _ "$EVENTS_FILE" "$MISMATCH_EVENT" || log "WARNING: failed to log publicized_privatized_mismatch event for $ID (continuing with status overwrite)"
  else
    log "WARNING: $EVENTS_FILE not found -- could not log publicized_privatized_mismatch event"
  fi
fi

log "$ID: fully covered by .publicignore -- writing status: Privatized ($BOARD_FILE)"
if ! "$WITH_LOCK_SCRIPT" "$BOARD_FILE" -- bash "$UPDATE_FRONTMATTER_SCRIPT" "$BOARD_FILE" status Privatized; then
  die "failed to write status: Privatized for $ID ($BOARD_FILE)"
fi

echo "PRIVATIZED"
exit 0
