#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/init/scripts/detect-existing-codebase.sh
#
# Deterministic front half of the /init "detect existing project state" step.
# /init currently always scaffolds as though the target directory were empty.
# That is wrong whenever a directory already carries a Jenga scaffold, or
# already carries substantial application code that predates Jenga entirely
# -- in the second case, scaffolding fresh produces an empty board and a stub
# PROJECT_SUMMARY.md that actively misrepresent the project.
#
# This script answers exactly one question -- "what kind of directory is
# this?" -- and nothing else. It never scaffolds, never prompts, never runs
# /uncharted, and never modifies anything on disk. Deciding what to DO with
# the verdict is agent judgement and lives in skills/init/SKILL.md.
#
# ---------------------------------------------------------------------------
# VERDICTS -- exactly one is printed on stdout, nothing else
# ---------------------------------------------------------------------------
#   empty               The target is empty, or contains only boilerplate
#                       that does not count as "there is a project here":
#                       .git (the directory itself, pruned entirely -- not
#                       merely excluded by name), .gitignore, and top-level
#                       README*/LICENSE*/LICENCE* files (case-insensitive),
#                       plus anything git itself reports as ignored. A repo
#                       containing only a README is empty for this purpose.
#   already-scaffolded  The target already carries a Jenga scaffold: any one
#                       of project/board/, project/PROJECT_SUMMARY.md, or
#                       project/configs/workflow.json is present. Checked
#                       BEFORE the emptiness scan, so a scaffolded project
#                       that also happens to look sparse is never misreported
#                       as "empty".
#   existing-codebase   The target has real content (source files, configs,
#                       docs beyond the boilerplate list above, etc.) and is
#                       not already Jenga-scaffolded. This is the case /init
#                       currently mishandles: scaffolding fresh here silently
#                       discards the fact that pre-existing code exists.
#
# ---------------------------------------------------------------------------
# NOTES ON GITIGNORE HANDLING
# ---------------------------------------------------------------------------
# /init runs this check BEFORE `git init` in the fresh-scaffold path, so the
# target directory is very often not a git work tree yet. Gitignore-based
# filtering is therefore best-effort: it only runs when the target already
# has a `.git` directory AND `git` is on PATH. A standalone `.gitignore` file
# with no repository behind it still counts as boilerplate via the name-based
# exclusion below -- it just cannot hide any OTHER file, because there is no
# git to ask "is this ignored".
#
# README/LICENSE exclusion applies to TOP-LEVEL entries only. A directory
# whose only content is a buried `docs/README.md` two levels down is real
# structure, not boilerplate, and must not be reported as empty.
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#   detect-existing-codebase.sh [target-dir]
#
#   target-dir   Directory to classify. Default: current directory.
#
# Options:
#   -h, --help   Show this help and exit 0.
#
# Exit codes:
#   0   A verdict was printed on stdout.
#   1   Usage error (unknown option, more than one positional argument).
#   2   target-dir does not exist or is not a directory.
#
# Requires: bash, find. git is used opportunistically for gitignore
# filtering when the target is already a git work tree; its absence never
# causes a failure.
# ---------------------------------------------------------------------------

set -euo pipefail

SELF="$(basename "$0")"

usage() {
  sed -n '/^# Usage$/,/^# Requires:/p' "$0" | sed -e 's/^# \{0,1\}//' -e '/^-\{10,\}$/d'
}

die_usage() {
  printf '%s: error: %s\n' "$SELF" "$*" >&2
  echo >&2
  usage >&2
  exit 1
}

TARGET_DIR="."
HAVE_TARGET=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --)
      shift
      [ "$#" -le 1 ] || die_usage "at most one target directory is allowed"
      if [ "$#" -eq 1 ]; then TARGET_DIR="$1"; HAVE_TARGET=1; fi
      shift $#
      ;;
    -*)
      die_usage "unknown option \"$1\"" ;;
    *)
      [ "$HAVE_TARGET" -eq 0 ] || die_usage "at most one target directory is allowed (got \"$TARGET_DIR\" and \"$1\")"
      TARGET_DIR="$1"; HAVE_TARGET=1; shift ;;
  esac
done

[ -d "$TARGET_DIR" ] || { printf '%s: error: not a directory: %s\n' "$SELF" "$TARGET_DIR" >&2; exit 2; }

TARGET_DIR="$(cd -- "$TARGET_DIR" && pwd -P)"

# --- already-scaffolded: checked first, independent of emptiness -----------
if [ -d "$TARGET_DIR/project/board" ] \
   || [ -f "$TARGET_DIR/project/PROJECT_SUMMARY.md" ] \
   || [ -f "$TARGET_DIR/project/configs/workflow.json" ]; then
  echo "already-scaffolded"
  exit 0
fi

# --- enumerate candidate files, pruning .git entirely -----------------------
ALL_FILES=$(mktemp "${TMPDIR:-/tmp}/detect-existing-codebase.XXXXXX")
IGNORED_FILES=$(mktemp "${TMPDIR:-/tmp}/detect-existing-codebase-ignored.XXXXXX")
cleanup() { rm -f "$ALL_FILES" "$IGNORED_FILES"; }
trap cleanup EXIT

find "$TARGET_DIR" -path "$TARGET_DIR/.git" -prune -o -type f -print > "$ALL_FILES"

# --- best-effort gitignore filtering ----------------------------------------
: > "$IGNORED_FILES"
if [ -d "$TARGET_DIR/.git" ] && command -v git >/dev/null 2>&1; then
  git -C "$TARGET_DIR" check-ignore --stdin < "$ALL_FILES" > "$IGNORED_FILES" 2>/dev/null || true
fi

# --- classify each candidate -------------------------------------------------
SOURCE_FOUND=0
while IFS= read -r f; do
  [ -n "$f" ] || continue

  if [ -s "$IGNORED_FILES" ] && grep -Fxq -- "$f" "$IGNORED_FILES"; then
    continue
  fi

  rel="${f#"$TARGET_DIR"/}"
  base="$(basename -- "$f")"
  dir_rel="$(dirname -- "$rel")"

  if [ "$dir_rel" = "." ]; then
    if [ "$base" = ".gitignore" ]; then
      continue
    fi
    base_upper="$(printf '%s' "$base" | tr '[:lower:]' '[:upper:]')"
    case "$base_upper" in
      README*|LICENSE*|LICENCE*) continue ;;
    esac
  fi

  SOURCE_FOUND=1
  break
done < "$ALL_FILES"

if [ "$SOURCE_FOUND" -eq 1 ]; then
  echo "existing-codebase"
else
  echo "empty"
fi
