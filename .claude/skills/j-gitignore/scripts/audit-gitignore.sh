#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# skills/j-gitignore/scripts/audit-gitignore.sh
#
# Read-only. Reports the Jenga-related git state of an already-scaffolded
# project. Changes nothing — this is the "check" half of the skill, safe to run
# anywhere, any number of times.
#
# Reports three independent things per catalog path:
#
#   entry     Is the exact entry literally present in .gitignore?
#   ignored   Does git actually ignore the path (`git check-ignore`)? This can
#             be true via a broader rule even when `entry` is no — and is
#             ALWAYS reported as "no" for a tracked path, because .gitignore
#             has no effect on a file git already tracks. That divergence is
#             the single most common cause of "I ignored it and it still keeps
#             getting committed".
#   tracked   Does git currently track anything under the path?
#
# Plus the stray-heredoc-terminator check: a bare `EOF` line left behind by the
# botched `cat > .gitignore <<EOF` in pre-fix /init scaffolds (fixed for NEW
# projects by E31_S07_T02/T03 and E42_S06_T01, which replaced the heredoc with
# a `cp` from assets/.gitignore_template — forward-only, so already-scaffolded
# projects still carry the damage).
#
# Invoked via `bash`, not executed directly — ships without the executable bit,
# same convention as skills/j-cloud-connect/scripts/install-rclone.sh.
#
# Usage:
#   audit-gitignore.sh [project_root] [--tiers scaffold,hybrid,board,optional]
#
# Exit codes:
#   0   Audit ran; nothing to fix
#   1   Bad usage or missing prerequisite (not a git repo, catalog missing)
#   2   Invalid tier name
#   10  Audit ran; findings exist (stray terminators, missing entries, or
#       tracked paths). Not an error — this is the signal to run the repair.
# -----------------------------------------------------------------------------

set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_catalog.sh"

PROJECT_ROOT=""
TIERS="scaffold"

while [ $# -gt 0 ]; do
  case "$1" in
    --tiers)   TIERS="${2:-}"; shift 2 ;;
    --tiers=*) TIERS="${1#*=}"; shift ;;
    -h|--help)
      echo "Usage: $(basename "$0") [project_root] [--tiers scaffold,hybrid,board,optional]"
      exit 0 ;;
    -*)
      echo "ERROR: Unknown option: $1" >&2
      echo "Usage: $(basename "$0") [project_root] [--tiers <csv>]" >&2
      exit 1 ;;
    *)
      if [ -n "$PROJECT_ROOT" ]; then
        echo "ERROR: More than one project root given: '$PROJECT_ROOT' and '$1'" >&2
        exit 1
      fi
      PROJECT_ROOT="$1"; shift ;;
  esac
done

PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"
validate_tiers "$TIERS" || exit 2
resolve_root "$PROJECT_ROOT" || exit 1
load_catalog "$TIERS" || exit 1

GITIGNORE=".gitignore"
FINDINGS=0

echo "═══════════════════════════════════════════════════════════════════════"
echo " Jenga gitignore audit — $(pwd)"
echo " Tiers: ${TIERS}"
echo "═══════════════════════════════════════════════════════════════════════"
echo

# ─── 1. Stray heredoc terminators ───────────────────────────────────────────
echo "── 1. Stray heredoc terminators ───────────────────────────────────────"
STRAY_COUNT=0
if [ ! -f "$GITIGNORE" ]; then
  echo "  No .gitignore at this root — nothing to check."
else
  # A line that is exactly EOF (tolerating trailing whitespace). Reported with
  # line numbers so a human can eyeball it before anything is removed.
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    echo "  ✗ line ${hit%%:*}: stray '${hit#*:}' terminator"
    STRAY_COUNT=$((STRAY_COUNT + 1))
  done < <(grep -nE '^[[:space:]]*EOF[[:space:]]*$' "$GITIGNORE" 2>/dev/null)

  if [ "$STRAY_COUNT" -eq 0 ]; then
    echo "  ✓ Clean — no stray terminator lines."
  else
    echo
    echo "  → ${STRAY_COUNT} stray line(s). repair-gitignore.sh removes these."
    FINDINGS=$((FINDINGS + STRAY_COUNT))
  fi
fi
echo

# ─── 2. Managed block ────────────────────────────────────────────────────────
echo "── 2. Managed block ───────────────────────────────────────────────────"
if [ -f "$GITIGNORE" ] && grep -qxF -- "$MANAGED_BEGIN" "$GITIGNORE"; then
  echo "  ✓ Present — this project has been through repair-gitignore.sh before."
else
  echo "  · Absent — entries (if any) are loose, e.g. appended by /init's"
  echo "    apply-project-visibility.sh / apply-scaffold-visibility.sh."
fi
echo

# ─── 3. Per-path state ───────────────────────────────────────────────────────
echo "── 3. Per-path state ──────────────────────────────────────────────────"
printf "  %-34s %-7s %-8s %-8s %s\n" "PATH" "ENTRY" "IGNORED" "TRACKED" "TIER"
printf "  %-34s %-7s %-8s %-8s %s\n" "----" "-----" "-------" "-------" "----"

MISSING_ENTRIES=0
TRACKED_PATHS=()

for i in "${!CATALOG_PATHS[@]}"; do
  path="${CATALOG_PATHS[$i]}"
  tier="${CATALOG_TIERS[$i]}"

  entry="no"
  if [ -f "$GITIGNORE" ] && grep -qxF -- "$path" "$GITIGNORE"; then
    entry="yes"
  fi

  # check-ignore works on paths that do not exist on disk, so a not-yet-created
  # scaffold dir is still evaluated against the rules.
  ignored="no"
  if git check-ignore -q -- "$path" 2>/dev/null; then
    ignored="yes"
  fi

  tracked="no"
  if [ -n "$(git ls-files -- "$path" 2>/dev/null | head -n 1)" ]; then
    tracked="yes"
    TRACKED_PATHS+=("$path")
  fi

  flag=""
  if [ "$entry" = "no" ];   then flag="  ← no entry"; MISSING_ENTRIES=$((MISSING_ENTRIES + 1)); fi
  if [ "$tracked" = "yes" ]; then flag="${flag}  ← TRACKED"; fi

  printf "  %-34s %-7s %-8s %-8s %s%s\n" "$path" "$entry" "$ignored" "$tracked" "$tier" "$flag"
done
echo

# ─── 4. Origin state ─────────────────────────────────────────────────────────
echo "── 4. Origin ──────────────────────────────────────────────────────────"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"

if [ -z "$UPSTREAM" ]; then
  echo "  · Branch '${BRANCH}' has no upstream — nothing has been pushed from it."
  echo "    Untracking here only ever affects local history."
else
  echo "  Upstream: ${UPSTREAM}"
  ON_ORIGIN=0
  for path in "${TRACKED_PATHS[@]:-}"; do
    [ -z "$path" ] && continue
    if [ -n "$(git ls-tree -r --name-only "$UPSTREAM" -- "$path" 2>/dev/null | head -n 1)" ]; then
      echo "  ✗ ${path} — present on ${UPSTREAM}"
      ON_ORIGIN=$((ON_ORIGIN + 1))
    fi
  done
  if [ "$ON_ORIGIN" -eq 0 ]; then
    echo "  ✓ No catalog path is present on ${UPSTREAM}."
  else
    echo
    echo "  → ${ON_ORIGIN} path(s) live on the remote. untrack-jenga-files.sh"
    echo "    --commit --push removes them from the branch TIP. It does NOT"
    echo "    rewrite history — earlier commits still contain them."
  fi
fi
echo

# ─── Summary ─────────────────────────────────────────────────────────────────
FINDINGS=$((FINDINGS + MISSING_ENTRIES + ${#TRACKED_PATHS[@]}))
echo "═══════════════════════════════════════════════════════════════════════"
echo " Stray terminators : ${STRAY_COUNT}"
echo " Missing entries   : ${MISSING_ENTRIES}"
echo " Tracked paths     : ${#TRACKED_PATHS[@]}"
echo "═══════════════════════════════════════════════════════════════════════"

if [ "$FINDINGS" -gt 0 ]; then
  echo "AUDIT_RESULT=findings"
  exit 10
fi
echo "AUDIT_RESULT=clean"
exit 0
