#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# skills/j-gitignore/scripts/repair-gitignore.sh
#
# Repairs an already-scaffolded project's .gitignore. Two jobs, in order:
#
#   1. Strips stray heredoc terminator lines (a bare `EOF`) left behind by the
#      botched `cat > .gitignore <<EOF` in pre-fix /init scaffolds. The upstream
#      fix (E31_S07_T02/T03, E42_S06_T01) repaired the TEMPLATE, which only helps
#      projects scaffolded afterwards; this repairs one already on disk.
#
#   2. Adds (mode `ignored`) or removes (mode `visible`) the Jenga path entries,
#      inside a managed block so the operation is exactly reversible.
#
# The managed block also ABSORBS loose duplicates: /init's
# apply-project-visibility.sh and apply-scaffold-visibility.sh append bare lines
# with no markers, so a previously-initialised project has loose `project/`,
# `.claude/` and `.agents/` entries. Any loose line exactly matching a selected
# catalog path is pulled out of the file and re-emitted inside the block, rather
# than left to sit alongside it as a duplicate.
#
# Everything outside the managed block is preserved byte for byte. The file is
# written atomically (temp + mv), so an interrupted run cannot truncate it.
#
# This does NOT untrack anything. .gitignore has no effect on a file git already
# tracks — that is untrack-jenga-files.sh's job, and it must run after this.
#
# Invoked via `bash`, not executed directly.
#
# Usage:
#   repair-gitignore.sh <ignored|visible> [project_root]
#                       [--tiers scaffold,hybrid,board,optional]
#                       [--dry-run] [--keep-eof]
#
# Options:
#   --tiers <csv>  Which catalog tiers to act on. Default: scaffold
#   --dry-run      Print a unified diff of the intended change; write nothing.
#   --keep-eof     Leave stray `EOF` lines alone. Use only if this project
#                  genuinely means to ignore a file literally named EOF.
#
# Exit codes:
#   0  Success (including "already correct — nothing to do")
#   1  Bad usage or missing prerequisite
#   2  Invalid mode or tier
#   3  Filesystem write failure
# -----------------------------------------------------------------------------

set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_catalog.sh"

info() { echo "[gitignore-repair] $*"; }
err()  { echo "[gitignore-repair] ERROR: $*" >&2; }

MODE=""
PROJECT_ROOT=""
TIERS="scaffold"
DRY_RUN=0
KEEP_EOF=0

while [ $# -gt 0 ]; do
  case "$1" in
    --tiers)   TIERS="${2:-}"; shift 2 ;;
    --tiers=*) TIERS="${1#*=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --keep-eof) KEEP_EOF=1; shift ;;
    -h|--help)
      echo "Usage: $(basename "$0") <ignored|visible> [project_root] [--tiers <csv>] [--dry-run] [--keep-eof]"
      exit 0 ;;
    -*) err "Unknown option: $1"; exit 1 ;;
    *)
      if [ -z "$MODE" ]; then MODE="$1"
      elif [ -z "$PROJECT_ROOT" ]; then PROJECT_ROOT="$1"
      else err "Unexpected argument: $1"; exit 1
      fi
      shift ;;
  esac
done

case "$MODE" in
  ignored|visible) ;;
  "") err "Missing mode. Usage: $(basename "$0") <ignored|visible> [project_root]"; exit 1 ;;
  *)  err "Invalid mode '${MODE}'. Allowed: ignored, visible"; exit 2 ;;
esac

PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"
validate_tiers "$TIERS" || exit 2
resolve_root "$PROJECT_ROOT" || exit 1
load_catalog "$TIERS" || exit 1

GITIGNORE=".gitignore"
TMP="${GITIGNORE}.jenga-repair.$$"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

# Fast membership test for "is this line one of our selected catalog paths".
is_catalog_path() {
  local line="$1" p
  for p in "${CATALOG_PATHS[@]}"; do
    [ "$line" = "$p" ] && return 0
  done
  return 1
}

# ─── Read the existing file ─────────────────────────────────────────────────
ORIGINAL=()
if [ -f "$GITIGNORE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    ORIGINAL+=("$line")
  done < "$GITIGNORE"
elif [ "$MODE" = "visible" ]; then
  info "No .gitignore at this root and mode is 'visible' — nothing to do."
  exit 0
else
  info "No .gitignore at this root — creating one."
fi

# ─── Filter: drop stray terminators, the old managed block, loose dupes ─────
FILTERED=()
in_block=0
removed_eof=0
removed_loose=0
had_block=0

for line in "${ORIGINAL[@]+"${ORIGINAL[@]}"}"; do
  if [ "$in_block" -eq 1 ]; then
    [ "$line" = "$MANAGED_END" ] && in_block=0
    continue
  fi
  if [ "$line" = "$MANAGED_BEGIN" ]; then
    in_block=1; had_block=1; continue
  fi
  if [ "$KEEP_EOF" -eq 0 ] && [[ "$line" =~ ^[[:space:]]*EOF[[:space:]]*$ ]]; then
    removed_eof=$((removed_eof + 1)); continue
  fi
  if is_catalog_path "$line"; then
    removed_loose=$((removed_loose + 1)); continue
  fi
  FILTERED+=("$line")
done

if [ "$in_block" -eq 1 ]; then
  err "Unterminated managed block — found '${MANAGED_BEGIN}' with no matching end marker."
  err "Refusing to write. Fix ${GITIGNORE} by hand, then re-run."
  exit 3
fi

# Trim trailing blank lines so repeated runs cannot accumulate whitespace.
# Indexed from the end by arithmetic, NOT via ${arr[-1]}: macOS still ships
# bash 3.2, which has no negative array subscripts — there the subscript
# silently evaluates empty, the loop condition stays true, and nothing is ever
# unset, so the script spins forever.
_last=$(( ${#FILTERED[@]} - 1 ))
while [ "$_last" -ge 0 ] && [ -z "${FILTERED[$_last]// /}" ]; do
  unset "FILTERED[$_last]"
  _last=$(( _last - 1 ))
done

# ─── Build the new file ─────────────────────────────────────────────────────
: > "$TMP" || { err "Cannot write temp file: $TMP"; exit 3; }

for line in "${FILTERED[@]+"${FILTERED[@]}"}"; do
  printf '%s\n' "$line" >> "$TMP" || { err "Write failed: $TMP"; exit 3; }
done

if [ "$MODE" = "ignored" ]; then
  [ "${#FILTERED[@]}" -gt 0 ] && printf '\n' >> "$TMP"
  {
    printf '%s\n' "$MANAGED_BEGIN"
    printf '%s\n' "# Managed by j.gitignore — regenerate with:"
    printf '%s\n' "#   bash <skill>/scripts/repair-gitignore.sh ignored . --tiers ${TIERS}"
    printf '%s\n' "# Remove with the same script in 'visible' mode. Edits inside this block"
    printf '%s\n' "# are overwritten; put your own patterns outside it."
    for i in "${!CATALOG_PATHS[@]}"; do
      printf '%s\n' "${CATALOG_PATHS[$i]}"
    done
    printf '%s\n' "$MANAGED_END"
  } >> "$TMP" || { err "Write failed: $TMP"; exit 3; }
fi

# ─── Report / apply ─────────────────────────────────────────────────────────
if [ -f "$GITIGNORE" ] && cmp -s "$GITIGNORE" "$TMP"; then
  info "Already correct — ${GITIGNORE} needs no change."
  exit 0
fi

echo
echo "── Proposed change to ${GITIGNORE} ────────────────────────────────────"
if [ -f "$GITIGNORE" ]; then
  diff -u "$GITIGNORE" "$TMP" | sed 's/^/  /' || true
else
  sed 's/^/  + /' "$TMP"
fi
echo

info "Stray 'EOF' terminators removed : ${removed_eof}"
info "Loose duplicate entries folded in: ${removed_loose}"
info "Pre-existing managed block       : $([ "$had_block" -eq 1 ] && echo replaced || echo none)"
info "Mode                             : ${MODE} (tiers: ${TIERS})"

if [ "$DRY_RUN" -eq 1 ]; then
  info "--dry-run — nothing written."
  exit 0
fi

if ! mv "$TMP" "$GITIGNORE"; then
  err "Failed to move ${TMP} into place."
  exit 3
fi
trap - EXIT

# Never report success without re-verifying the result on disk.
if [ "$MODE" = "ignored" ]; then
  for p in "${CATALOG_PATHS[@]}"; do
    if ! grep -qxF -- "$p" "$GITIGNORE"; then
      err "Post-write verification failed: '${p}' is not in ${GITIGNORE}."
      exit 3
    fi
  done
fi
if [ "$KEEP_EOF" -eq 0 ] && grep -qE '^[[:space:]]*EOF[[:space:]]*$' "$GITIGNORE"; then
  err "Post-write verification failed: a stray EOF line survived."
  exit 3
fi

info "Wrote ${GITIGNORE} (verified)."
exit 0
