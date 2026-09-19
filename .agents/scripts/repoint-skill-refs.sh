#!/usr/bin/env bash
# scripts/repoint-skill-refs.sh — repoint bare skills/<name>/ path references to their
# canonical skills/j-<name>/ twin (E50_S11).
#
# Purpose
# -------
# `skills/j-<name>/` was promoted to the sole canonical skill directory by the E50
# reopening of 2026-09-09; the old bare `skills/<name>/` directories are deleted later
# in the sequence (E50_S15). This script performs the ordering-safety half of that
# cutover: rewriting every functional (non-prose) reference of the form
# `skills/<bare-name>/...` to `skills/j-<bare-name>/...` WHILE both directories still
# exist. The twin is already byte-identical to its bare source, so applying this script
# is a behaviour-neutral no-op at runtime — it only changes which (already-working)
# path a reference resolves through, in preparation for the bare directory's later
# deletion.
#
# Per CLAUDE.md's "Skill Implementation Principle — Scripts Over Inline Logic", this is
# a deterministic, re-runnable, idempotent script — not inline agent judgment applied
# file-by-file.
#
# Modes
# -----
#   --dry-run   Report every candidate file, line number, and the before/after string.
#               Nothing is written.
#   --apply     Perform the rewrite in place.
#
# Exactly one of --dry-run/--apply is required. Either mode always runs the
# bare-vs-twin delta check FIRST (see below) before touching or reporting on any file.
#
# Usage
# -----
#   scripts/repoint-skill-refs.sh (--dry-run|--apply) [PATH...]
#
# PATH may be a file or a directory (searched recursively); it is resolved relative to
# the caller's cwd if relative, or used as-is if absolute. If no PATH is given, the
# script defaults to this repo's whole canonical source scope: skills/, agents/,
# hooks/, scripts/, lib/, and .github/agents/ — the exact set of "canonical, hand-edited
# source" locations named by CLAUDE.md's Source-of-Truth rule and this story's Context.
#
# Examples
# --------
#   scripts/repoint-skill-refs.sh --dry-run skills/j-do
#   scripts/repoint-skill-refs.sh --apply agents/developer.md .github/agents/developer.md
#   scripts/repoint-skill-refs.sh --apply          # full default canonical scope
#
# Exception list — single named source
# --------------------------------------
# REPOINT_SKILL_REFS_EXCEPTIONS below is the ONLY place this script's exception list is
# defined; every other check in this script calls is_exception() rather than
# re-listing the names. These three directories keep their bare names permanently
# (E50_S06/E50's "three permanent exceptions") and are never rewritten to a `j-` form,
# and never required to have a `j-` twin:
#   - skills/jenga/                  (root orchestrator command)
#   - skills/jenga-permission-level/ (root orchestrator command)
#   - skills/index/                  (not a skill — no SKILL.md, not part of routing)
#
# Double-prefix safety
# ---------------------
# The rewrite rule's source pattern is always `skills/<bare-name>/`, where <bare-name>
# is drawn from the LIVE list of non-"j-"-prefixed directory names under skills/ (see
# the delta check below), minus the exceptions above. Because every eligible name is
# itself bare (never starts with "j-") and the pattern requires the literal trailing
# "/" delimiter, the string `skills/<bare-name>/` can never occur as a substring of
# `skills/j-<bare-name>/` or of any other twin path — right after "skills/" a twin path
# always reads "j-", never the bare name directly. Double-prefixing
# (`skills/j-j-<name>/`) is therefore structurally impossible by construction, not
# merely avoided by a runtime guard.
#
# Bare-vs-twin delta check
# --------------------------
# Computed fresh from disk on every invocation (never a hardcoded list): every
# directory directly under skills/ is classified as either a twin (name starts with
# "j-") or bare (does not). Every bare, non-excepted directory MUST have a
# `skills/j-<name>/` twin on disk; if not, that directory is UNPAIRED. The script
# prints the bare count, the twin count, and every unpaired directory's name, then —
# if any unpaired directory exists — exits non-zero (naming the directory) BEFORE
# performing or reporting any rewrite. This does not require twin_count == bare_count:
# a twin-only skill authored after the E50 reopening (e.g. skills/j-playbook/ before it
# gained a jenga/scripts/load-playbooks.sh reference, or skills/j-cloud-connect/, which
# never had a bare form at all) is expected and not flagged — only a BARE directory
# lacking its twin is an error condition.
#
# Path excludes — single named source
# --------------------------------------
# PATH_EXCLUDE_PATTERNS below is the only place file/directory exclusions are defined.
# Always excluded, regardless of what PATHs are passed on the command line:
#   - .git/, node_modules/            (VCS / dependency internals)
#   - .claude/, .agents/              (generated mirrors — CLAUDE.md: never edit directly)
#   - docs/                           (prose/docs rewrite is E50_S17's scope, not this story's)
#   - .publicignore                   (owned by E50_S16)
#   - lib/legacy-shipped-paths.json   (deliberately retained bare-path list — see E50_S16)
#
# Idempotency
# -----------
# Because the rewrite eliminates every occurrence of `skills/<bare-name>/` (bare) that
# it can see, and never introduces a new one (only ever `skills/j-<bare-name>/`), a
# second --apply run over the same tree finds nothing left to change and reports zero
# files rewritten.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/resolve-project-dir.sh
source "$SCRIPT_DIR/../lib/resolve-project-dir.sh"

PROJECT_DIR="$JENGA_PROJECT_DIR"
SKILLS_DIR="$PROJECT_DIR/skills"

# ---- Single named source: directory exception list ----
REPOINT_SKILL_REFS_EXCEPTIONS=(jenga jenga-permission-level index)

is_exception() {
  local name="$1" ex
  for ex in "${REPOINT_SKILL_REFS_EXCEPTIONS[@]}"; do
    if [ "$name" = "$ex" ]; then
      return 0
    fi
  done
  return 1
}

# ---- Single named source: path excludes ----
# Each entry is a pattern matched against the path relative to $PROJECT_DIR (POSIX
# separators). A path is excluded if it equals, or is nested under, any entry.
PATH_EXCLUDE_PATTERNS=(
  ".git"
  "node_modules"
  ".claude"
  ".agents"
  "docs"
  ".publicignore"
  "lib/legacy-shipped-paths.json"
  # This script's own source. Its header comments quote real, deliberately-unrewritten
  # bare-path content from other files as illustrative examples (e.g. "skills/wtf/"
  # inside a sentence explaining why skills/j-wtf/SKILL.md's own self-reference is
  # left alone) and one historical bug description (the original, broken
  # `mkdir -p ".../skills/do"` line this script's own fix commit corrected). Running
  # the sweep against itself would rewrite those intentional quotes, making them
  # inaccurate descriptions of the content/history they document. Not a "the tool
  # can't sweep its own kind" restriction — every other *.sh file is swept normally.
  "scripts/repoint-skill-refs.sh"
)

is_path_excluded() {
  local rel="$1" pattern
  for pattern in "${PATH_EXCLUDE_PATTERNS[@]}"; do
    if [ "$rel" = "$pattern" ] || [[ "$rel" == "$pattern"/* ]]; then
      return 0
    fi
  done
  return 1
}

# ---- Self-reference guard ----
# A file living under skills/j-<X>/... never has its OWN "skills/<X>/" (same name)
# occurrences rewritten, even though every other eligible name is still rewritten
# normally in that same file. This mirrors this story's own scope boundary
# (E50_S11_T02's title: "repoint CROSS-skill bare references inside skills/j-*/
# twins") — self-referential mentions of a twin's own bare source are out of scope
# for two concrete, evidenced reasons, not a hypothetical:
#
#   1. `scripts/generate-j-alias.sh` step 2 already rewrites self-referential
#      `skills/<X>/` occurrences to `skills/j-<X>/` for ordinary body content at
#      generation time — a REMAINING bare self-reference in a `skills/j-<X>/` file is
#      therefore either (a) inside the generator's own OWN appended note (L294-304),
#      whose bare self-mentions are inserted AFTER that rewrite pass and so were never
#      caught by it, and which is accurate AS WRITTEN (describes real generation
#      provenance) — see e.g. `skills/j-wtf/SKILL.md`'s "This skill is a
#      literal-directory-name duplicate of `skills/wtf/`" / "generated/synced by
#      ... from `skills/wtf/SKILL.md`" — or (b) deliberate, hand-written prose a later
#      task substituted in place of that note, e.g. `skills/j-do/SKILL.md`'s
#      "this file was previously generated from `skills/do/SKILL.md` ... `skills/do/`
#      is the copy awaiting deletion by E50_S15" and `skills/j-dev-done/SKILL.md`'s
#      equivalent — both intentionally keep referencing the BARE directory (as a
#      concept: its history, or its pending-deletion fate), and rewriting either
#      mention corrupts the sentence (turns "generated from X" into "generated from
#      itself", or turns "X is the copy awaiting deletion" into a false claim about
#      the twin itself).
#   2. `skills/j-init/` is the one hand-maintained (non-generator) pair predating this
#      mechanism entirely — `scripts/generate-j-alias.sh` explicitly refuses to touch
#      it. Its own prose ("Keep this file's instructions in lockstep with
#      `skills/init/SKILL.md`") and its `scripts/apply-scaffold-visibility.sh` ("Keep
#      this file's logic in lockstep with `skills/init/`'s copy") are legitimate,
#      current, hand-authored statements about a live sibling relationship between two
#      directories that both still exist and are both still hand-edited — rewriting
#      either turns "in lockstep with skills/init/" into "in lockstep with itself".
#
# In every case found, retiring/rewriting this content (once the generator itself is
# retired/inverted, or once E50_S15 deletes the bare directories these notes describe)
# is E50_S14's scope ("Retire or Invert the Twin-Generation Scripts"), not this
# story's — E50_S11 rewrites CROSS-skill path strings only.
file_self_reference_name() {
  local file="$1" rel
  rel="${file#"$PROJECT_DIR"/}"
  case "$rel" in
    skills/j-*)
      rel="${rel#skills/j-}"
      echo "${rel%%/*}"
      ;;
  esac
}

usage() {
  cat >&2 <<'EOF'
Usage: repoint-skill-refs.sh (--dry-run|--apply) [PATH...]

  --dry-run   Report every candidate file/line/before/after. Writes nothing.
  --apply     Perform the rewrite in place.

PATH may be a file or directory; repeatable. Defaults to this repo's canonical
source scope (skills/, agents/, hooks/, scripts/, lib/, .github/agents/) when
no PATH is given.
EOF
}

MODE=""
TARGET_ARGS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      MODE="dry-run"
      shift
      ;;
    --apply)
      MODE="apply"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        TARGET_ARGS+=("$1")
        shift
      done
      ;;
    -*)
      echo "repoint-skill-refs.sh: error: unknown flag '$1'" >&2
      usage
      exit 1
      ;;
    *)
      TARGET_ARGS+=("$1")
      shift
      ;;
  esac
done

if [ -z "$MODE" ]; then
  echo "repoint-skill-refs.sh: error: exactly one of --dry-run or --apply is required" >&2
  usage
  exit 1
fi

# ============================================================================
# 1. Live bare-vs-twin delta check — ALWAYS runs first, before any file I/O.
# ============================================================================
BARE_DIRS=()
TWIN_DIRS=()
UNPAIRED=()

if [ -d "$SKILLS_DIR" ]; then
  for d in "$SKILLS_DIR"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    case "$name" in
      j-*)
        TWIN_DIRS+=("$name")
        continue
        ;;
    esac
    BARE_DIRS+=("$name")
    if is_exception "$name"; then
      continue
    fi
    if [ ! -d "$SKILLS_DIR/j-$name" ]; then
      UNPAIRED+=("$name")
    fi
  done
fi

echo "== repoint-skill-refs.sh: bare-vs-twin delta =="
echo "  bare directories (skills/<name>/, incl. exceptions): ${#BARE_DIRS[@]}"
echo "  twin directories (skills/j-<name>/):                 ${#TWIN_DIRS[@]}"
if [ "${#UNPAIRED[@]}" -gt 0 ]; then
  echo "  UNPAIRED bare directories (no twin, not on the exception list):"
  for u in "${UNPAIRED[@]}"; do
    echo "    - $u"
  done
  echo "repoint-skill-refs.sh: error: the directory(ies) named above have no skills/j-<name>/ twin and are not on the exception list. Disposition each one (generate the missing twin, add it to REPOINT_SKILL_REFS_EXCEPTIONS, or record another explicit decision) before running this script." >&2
  exit 1
fi
echo "  delta check clean — every bare directory is either excepted or paired with a twin."
echo

# ============================================================================
# 2. Determine the rewrite name set: every bare directory minus exceptions.
# ============================================================================
REWRITE_NAMES=()
for name in "${BARE_DIRS[@]}"; do
  if ! is_exception "$name"; then
    REWRITE_NAMES+=("$name")
  fi
done

# ============================================================================
# 3. Resolve targets -> a flat file list (excluding PATH_EXCLUDE_PATTERNS and
#    binary files).
# ============================================================================
if [ "${#TARGET_ARGS[@]}" -eq 0 ]; then
  DEFAULT_SCOPE=(skills agents hooks scripts lib .github/agents)
  for d in "${DEFAULT_SCOPE[@]}"; do
    if [ -e "$PROJECT_DIR/$d" ]; then
      TARGET_ARGS+=("$PROJECT_DIR/$d")
    fi
  done
fi

FILES=()
for target in "${TARGET_ARGS[@]}"; do
  case "$target" in
    /*) abs_target="$target" ;;
    *) abs_target="$PWD/$target" ;;
  esac
  if [ ! -e "$abs_target" ]; then
    echo "repoint-skill-refs.sh: error: target '$target' does not exist" >&2
    exit 1
  fi
  if [ -f "$abs_target" ]; then
    candidates=("$abs_target")
  else
    while IFS= read -r -d '' f; do
      candidates+=("$f")
    done < <(find "$abs_target" -type f -print0)
  fi
  for f in "${candidates[@]-}"; do
    [ -n "${f:-}" ] || continue
    rel="${f#"$PROJECT_DIR"/}"
    if is_path_excluded "$rel"; then
      continue
    fi
    # Skip binary files.
    if ! grep -Iq . "$f" 2>/dev/null; then
      continue
    fi
    FILES+=("$f")
  done
  candidates=()
done

# Deduplicate FILES (a file could be reachable via more than one target arg).
# Avoid `mapfile` (a bash 4+ builtin) — this repo must stay compatible with macOS's
# stock /bin/bash 3.2 (see PROJECT_SUMMARY.md's E47_S04 note on this exact class of
# portability defect), so dedup via a plain while-read loop instead.
if [ "${#FILES[@]}" -gt 0 ]; then
  DEDUPED_FILES=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    DEDUPED_FILES+=("$f")
  done < <(printf '%s\n' "${FILES[@]}" | sort -u)
  FILES=("${DEDUPED_FILES[@]}")
fi

# ============================================================================
# 4. Scan (and, in --apply mode, rewrite) every file for every eligible name.
#
# Line-at-a-time (not a whole-file sed pass), against a per-file EFFECTIVE name list
# that excludes the file's own self-reference name (see file_self_reference_name()
# above) — so a skills/j-<X>/... file never has its own "skills/<X>/" mentions
# rewritten, while every other eligible cross-skill name is still rewritten normally
# in that same file.
#
# Boundary rule (not just a trailing slash): a match requires `skills/<name>`
# followed by either end-of-line or a character that is NOT [A-Za-z0-9_-] — i.e. not
# something that could continue the same identifier. A bare directory REFERENCE
# almost always has a trailing "/" (`skills/do/SKILL.md`), but a small, real set of
# prose/code mentions the bare name with no trailing slash at all — e.g.
# `mkdir -p "$dir/skills/do" "$dir/agents"` (found in
# scripts/verify-legacy-seed-reconcile.sh: this exact line, unrewritten, left the
# fixture creating a "do" directory while a nearby line wrote into "j-do/SKILL.md",
# breaking the rehearsal), or a comment like "Consumed by skills/do (Step 0)". A
# trailing-slash-only pattern would silently miss both. The boundary class still
# blocks a match from firing on a mere PREFIX of a longer name (`do` inside `doc`,
# `reconcile` inside `reconcile-origin`) because the very next character in those
# cases (`c`, `-`) is itself in the blocked class.
# ============================================================================
CHANGED_FILES=()
REPORT_COUNT=0
SKIPPED_COUNT=0

# Extended-regex boundary suffix shared by every match/replace in this section: end
# of line, or any character that is not part of a bare skill-directory-name token.
BOUNDARY_SUFFIX='([^A-Za-z0-9_-]|$)'

join_by_pipe() {
  local IFS='|'
  echo "$*"
}

for f in "${FILES[@]-}"; do
  [ -n "${f:-}" ] || continue

  self_name="$(file_self_reference_name "$f")"

  # Effective rewrite name list for THIS file: every eligible name except its own
  # self-reference name (if any).
  FILE_REWRITE_NAMES=()
  for name in "${REWRITE_NAMES[@]-}"; do
    [ -n "${name:-}" ] || continue
    if [ -n "$self_name" ] && [ "$name" = "$self_name" ]; then
      continue
    fi
    FILE_REWRITE_NAMES+=("$name")
  done

  self_ref_regex=""
  if [ -n "$self_name" ]; then
    self_ref_regex="skills/${self_name}${BOUNDARY_SUFFIX}"
  fi

  # Cheap short-circuit: does this file contain any EFFECTIVE candidate at all? A
  # plain substring pre-check ("skills/" anywhere) gates the more expensive
  # boundary-regex grep below, since the overwhelming majority of files never
  # mention "skills/" at all.
  has_candidate=0
  if [ "${#FILE_REWRITE_NAMES[@]}" -gt 0 ] && grep -qF -- "skills/" "$f" 2>/dev/null; then
    file_rewrite_alt="$(join_by_pipe "${FILE_REWRITE_NAMES[@]}")"
    if grep -Eq -- "skills/(${file_rewrite_alt})${BOUNDARY_SUFFIX}" "$f" 2>/dev/null; then
      has_candidate=1
    fi
  fi

  if [ "$has_candidate" -eq 0 ]; then
    # Still report the self-reference skip, if this file has one, so the report stays
    # transparent about why a visible "skills/<self_name>" mention was left alone.
    if [ -n "$self_name" ] && grep -Eq -- "$self_ref_regex" "$f" 2>/dev/null; then
      while IFS=: read -r lineno linetext; do
        [ -n "$lineno" ] || continue
        echo "$f:$lineno: SKIP (self-reference to skills/${self_name} — E50_S14 scope): $linetext"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      done < <(grep -En -- "$self_ref_regex" "$f" 2>/dev/null)
    fi
    continue
  fi

  file_changed=0
  tmp_file=""
  if [ "$MODE" = "apply" ]; then
    tmp_file="$(mktemp "${f}.repoint.XXXXXX")"
    # `cp -p` before truncating: mktemp's own file is created with fresh default
    # permissions (typically 600), which would silently drop an executable bit (or
    # any other mode/timestamp) when moved over the original. Copying the original
    # onto the temp path first inherits its mode; the later truncate-and-rewrite
    # (via `>`/`>>` redirection below) only replaces content, never permissions.
    cp -p "$f" "$tmp_file"
    : > "$tmp_file"
  fi

  lineno=0
  while IFS= read -r linetext || [ -n "$linetext" ]; do
    lineno=$((lineno + 1))
    newtext="$linetext"

    case "$linetext" in
      *"skills/"*)
        # Per-line effective name list: drop any name whose TWIN form already
        # appears on this same line. Handles the "named pair" sentence shape —
        # e.g. scripts/generate-j-alias.sh: "the skills/init/ <-> skills/j-init/
        # pair" — where the bare mention and the twin mention are deliberately
        # both present, describing the pair itself. Rewriting the bare half there
        # would turn it into "skills/j-init/ <-> skills/j-init/", a duplicate that
        # erases the sentence's actual point. This is a per-LINE check (not
        # per-file, unlike the self-reference guard above) because a pair sentence
        # like this can appear anywhere, including files with no self-reference
        # name at all.
        line_names=()
        for name in "${FILE_REWRITE_NAMES[@]-}"; do
          [ -n "${name:-}" ] || continue
          case "$linetext" in
            *"skills/j-${name}"*) continue ;;
          esac
          line_names+=("$name")
        done
        if [ "${#line_names[@]}" -gt 0 ]; then
          line_rewrite_alt="$(join_by_pipe "${line_names[@]}")"
          # sed -E (POSIX extended regex, portable across GNU and BSD sed) does the
          # actual boundary-preserving substitution: \1 is the matched name, \2 is
          # the boundary character (or empty at end-of-line), both re-emitted after
          # the "j-" prefix so only the name itself changes.
          newtext="$(printf '%s' "$linetext" | sed -E "s#skills/(${line_rewrite_alt})${BOUNDARY_SUFFIX}#skills/j-\\1\\2#g")"
        fi
        ;;
    esac

    if [ -n "$self_name" ] && [[ "$linetext" =~ $self_ref_regex ]]; then
      echo "$f:$lineno: SKIP (self-reference to skills/${self_name} — E50_S14 scope): $linetext"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    fi

    if [ "$newtext" != "$linetext" ]; then
      echo "$f:$lineno: $linetext"
      echo "$f:$lineno: -> $newtext"
      REPORT_COUNT=$((REPORT_COUNT + 1))
      file_changed=1
    fi

    if [ "$MODE" = "apply" ]; then
      printf '%s\n' "$newtext" >> "$tmp_file"
    fi
  done < "$f"

  if [ "$MODE" = "apply" ]; then
    if [ "$file_changed" -eq 1 ]; then
      mv "$tmp_file" "$f"
    else
      rm -f "$tmp_file"
    fi
  fi

  if [ "$file_changed" -eq 1 ]; then
    CHANGED_FILES+=("$f")
  fi
done

echo
if [ "$MODE" = "dry-run" ]; then
  echo "== repoint-skill-refs.sh: dry-run complete — $REPORT_COUNT line(s) would change, $SKIPPED_COUNT line(s) skipped (self-reference) =="
else
  echo "== repoint-skill-refs.sh: apply complete — ${#CHANGED_FILES[@]} file(s) changed, $REPORT_COUNT line(s) rewritten, $SKIPPED_COUNT line(s) skipped (self-reference) =="
  for cf in "${CHANGED_FILES[@]-}"; do
    [ -n "${cf:-}" ] || continue
    echo "  - ${cf#"$PROJECT_DIR"/}"
  done
fi

exit 0
