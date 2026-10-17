#!/usr/bin/env bash
# scripts/dryrun-pages-site-diff.sh
#
# Read-only dry run of scripts/build-pages-site.sh: generates the Pages site
# into a fresh `mktemp -d` directory, then classifies every file in the
# committed site source directory (site/ by default) as
#
#   identical       — the generator reproduces the committed file byte for byte
#   differs         — the generator produces this file, but with different bytes
#                     (i.e. a hand-edit the generator would overwrite)
#   not-generated   — the generator does not produce this file at all, so it is
#                     hand-maintained by definition, not drifted
#   missing-in-docs — the generator produces a file that the site source has no
#                     counterpart for (a repoint/rename safety net). The label
#                     keeps its historical name even though the source is now
#                     site/, because project/documentation/docs-site-drift-report.md
#                     quotes it verbatim and records that any `missing-in-*`
#                     line after the E70_S02 move is a repoint bug rather than
#                     pre-existing state.
#
# and emits a full unified diff for each `differs` file.
#
# WHY THIS EXISTS (E70_S01_T01): E70 moves the Pages site source out of docs/
# into site/, and the committed pages had been hand-edited in place while the
# generator still claimed ownership of them. Nothing hand-edited may be lost in
# the move, so the drift had to be measured before anything was moved. Note the
# measurement refuted part of the premise: docs/skills.md turned out to be
# byte-identical to generator output (drift report section 4), and the only real
# hand-edit was one blockquote in mcp-tools.md, folded into
# project/.wiki/documentation.md by E70_S02_T03. This harness is the measurement, and it
# is deliberately durable and idempotent rather than a one-off command:
#
#   - E70_S01_T02 turns its output into project/documentation/docs-site-drift-report.md
#   - E70_S01_T04 re-runs it to prove the intra-site link normalisation
#     introduced no new drift
#   - E70_S02 re-runs it to prove the move to site/ loses nothing
#   - E70_S05 re-runs it to verify post-cutover state
#
# READ-ONLY GUARANTEE: the generator is pointed at a temp directory, never at
# the site source. The harness fingerprints the site source before and after
# the run and exits 4 if a single byte changed, so the guarantee is asserted
# by the script rather than left to the caller to remember to check.
#
# INVENTORY IS MEASURED, NEVER ASSUMED: the set of generator-produced pages is
# derived from what actually lands in the temp directory, and every count
# printed is counted at runtime. Do not reintroduce a hardcoded page list or a
# hardcoded "12 files" figure here — the story and epic prose both say "the 12
# files currently in docs/", but one of those 12 (README.md) is a maintainer
# decision record and not a site page at all.
#
# Usage:
#   scripts/dryrun-pages-site-diff.sh [options]
#
#     --source-dir <dir>   Committed site source to compare against.
#                          Default: <repo root>/site
#                          Walked recursively: since E70_S02_T02 the pages live
#                          in site/guides/ and site/reference/, so a depth-1
#                          walk would compare only site/index.md and
#                          site/_config.yml and report all 7 generated pages as
#                          missing-in-docs.
#     --out <file>         Also write the full report (verdicts + diffs) to
#                          this file. Default: stdout only.
#     --no-diffs           Print verdicts and counts only, omit the unified
#                          diffs. Useful for an idempotency comparison.
#     -h, --help           Print this usage block and exit 0.
#
# Exit codes:
#   0  clean          — no `differs` and no `missing-in-docs`, source untouched
#   1  usage error    — bad option, or source directory missing
#   2  generator failed
#   3  drift detected — at least one `differs` or `missing-in-docs` file
#   4  source mutated — something under the source directory changed during the
#                       run. Takes precedence over every other outcome.

set -euo pipefail

# shellcheck source=lib/resolve-project-dir.sh disable=SC1091
source "$(git rev-parse --show-toplevel)/lib/resolve-project-dir.sh"

REPO_ROOT="$JENGA_PROJECT_DIR"
GENERATOR="$REPO_ROOT/scripts/build-pages-site.sh"
SOURCE_DIR="$REPO_ROOT/site"
OUT_FILE=""
SHOW_DIFFS=1

while [ $# -gt 0 ]; do
  case "$1" in
    --source-dir)
      [ $# -ge 2 ] || { echo "dryrun-pages-site-diff.sh: --source-dir needs a value" >&2; exit 1; }
      SOURCE_DIR="$2"; shift 2 ;;
    --out)
      [ $# -ge 2 ] || { echo "dryrun-pages-site-diff.sh: --out needs a value" >&2; exit 1; }
      OUT_FILE="$2"; shift 2 ;;
    --no-diffs)
      SHOW_DIFFS=0; shift ;;
    -h|--help)
      sed -n '/^# Usage:/,$p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "dryrun-pages-site-diff.sh: unknown argument: $1" >&2
      echo "Usage: scripts/dryrun-pages-site-diff.sh [--source-dir <dir>] [--out <file>] [--no-diffs]" >&2
      exit 1 ;;
  esac
done

if [ ! -x "$GENERATOR" ]; then
  echo "dryrun-pages-site-diff.sh: generator not found or not executable: $GENERATOR" >&2
  exit 1
fi
if [ ! -d "$SOURCE_DIR" ]; then
  echo "dryrun-pages-site-diff.sh: source directory not found: $SOURCE_DIR" >&2
  exit 1
fi

# Relative form of the source dir, for git invocations and for display.
SOURCE_REL="${SOURCE_DIR#"$REPO_ROOT"/}"

# --- fingerprinting -------------------------------------------------------
# Two independent views of "did the source change": a content fingerprint
# (catches any byte change, tracked or not) and git's own porcelain view
# (catches adds/deletes/renames as git sees them). Both are compared before
# and after the generator runs.
fingerprint_source() {
  find "$SOURCE_DIR" -type f -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 shasum -a 256 2>/dev/null \
    | sed "s|$REPO_ROOT/||"
}
git_view_source() {
  git -C "$REPO_ROOT" status --porcelain -- "$SOURCE_REL" 2>/dev/null || true
}

BEFORE_FP="$(fingerprint_source)"
BEFORE_GIT="$(git_view_source)"

TMP_OUT="$(mktemp -d)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$TMP_OUT" "$WORKDIR"' EXIT

REPORT="$WORKDIR/report.txt"

# --- run the generator against the temp directory -------------------------
GEN_LOG="$WORKDIR/generator.log"
GEN_RC=0
"$GENERATOR" "$TMP_OUT" >"$GEN_LOG" 2>&1 || GEN_RC=$?
if [ "$GEN_RC" -ne 0 ]; then
  echo "dryrun-pages-site-diff.sh: generator exited $GEN_RC" >&2
  cat "$GEN_LOG" >&2
  exit 2
fi

HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

{
  echo "# Pages site dry-run diff"
  echo
  echo "generated-at-commit : $HEAD_SHA"
  echo "source-dir          : $SOURCE_REL"
  echo "generator           : scripts/build-pages-site.sh"
  echo "generator-output-dir: (fresh mktemp -d, discarded on exit)"
  echo "harness-command     : scripts/dryrun-pages-site-diff.sh${OUT_FILE:+ --out $OUT_FILE}"
  echo
  echo "## Per-file verdicts"
  echo
} > "$REPORT"

# --- classify every file in the source directory --------------------------
count_total=0
count_identical=0
count_differs=0
count_not_generated=0
count_missing=0
count_generated=0
differs_list=""
nongenerated_list=""

# The generated set is whatever actually landed in the temp directory.
generated_files="$(cd "$TMP_OUT" && find . -type f -print | sed 's|^\./||' | LC_ALL=C sort)"
count_generated="$(printf '%s\n' "$generated_files" | grep -c . || true)"

# Recursive, to match the generated side above: both sides are listed as paths
# relative to their own root (guides/getting-started.md, reference/skills.md,
# ...), so the cmp/diff pairing below works on identical relative paths.
source_files="$(cd "$SOURCE_DIR" && find . -type f -print | sed 's|^\./||' | LC_ALL=C sort)"

while IFS= read -r f; do
  [ -n "$f" ] || continue
  count_total=$((count_total + 1))
  if [ -f "$TMP_OUT/$f" ]; then
    if cmp -s "$SOURCE_DIR/$f" "$TMP_OUT/$f"; then
      printf '%-34s %s\n' "$f" "identical" >> "$REPORT"
      count_identical=$((count_identical + 1))
    else
      src_bytes="$(wc -c < "$SOURCE_DIR/$f" | tr -d ' ')"
      gen_bytes="$(wc -c < "$TMP_OUT/$f" | tr -d ' ')"
      changed="$(diff -u "$TMP_OUT/$f" "$SOURCE_DIR/$f" | grep -c '^[+-][^+-]' || true)"
      printf '%-34s %s  (committed %s bytes, generated %s bytes, %s changed lines)\n' \
        "$f" "differs" "$src_bytes" "$gen_bytes" "$changed" >> "$REPORT"
      count_differs=$((count_differs + 1))
      differs_list="$differs_list$f"$'\n'
    fi
  else
    printf '%-34s %s\n' "$f" "not-generated" >> "$REPORT"
    count_not_generated=$((count_not_generated + 1))
    nongenerated_list="$nongenerated_list$f"$'\n'
  fi
done <<< "$source_files"

# Generated files with no counterpart in the source directory.
while IFS= read -r g; do
  [ -n "$g" ] || continue
  if [ ! -f "$SOURCE_DIR/$g" ]; then
    printf '%-34s %s\n' "$g" "missing-in-docs" >> "$REPORT"
    count_missing=$((count_missing + 1))
  fi
done <<< "$generated_files"

# --- measured inventory ---------------------------------------------------
# A "site page" is a file Jekyll renders: it carries `---` front matter on its
# first line. Detected, not assumed. This is what made the old "12 files in
# docs/" figure wrong: docs/README.md had no front matter and was a maintainer
# decision record, never a site page (E70_S02_T01 moved it to
# project/documentation/site-decisions.md). The honest figure is 11 files under
# site/.
count_pages=0
count_nonpages=0
nonpage_list=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    *.md)
      if [ "$(head -n 1 "$SOURCE_DIR/$f")" = "---" ]; then
        count_pages=$((count_pages + 1))
      else
        count_nonpages=$((count_nonpages + 1))
        nonpage_list="$nonpage_list$f"$'\n'
      fi
      ;;
    *) : ;;  # _config.yml and friends: site assets, neither page nor non-page
  esac
done <<< "$source_files"

{
  echo
  echo "## Measured inventory"
  echo
  echo "files in $SOURCE_REL (recursive)    : $count_total"
  echo "  of which markdown with front matter: $count_pages  (rendered site pages)"
  echo "  of which markdown without         : $count_nonpages  (not rendered as pages)"
  echo "generator-produced files            : $count_generated"
  echo
  echo "## Verdict tally"
  echo
  echo "identical      : $count_identical"
  echo "differs        : $count_differs"
  echo "not-generated  : $count_not_generated"
  echo "missing-in-docs: $count_missing"
  if [ -n "${nonpage_list//[$'\n']/}" ]; then
    echo
    echo "markdown files with no front matter (not rendered as pages):"
    printf '%s' "$nonpage_list" | sed 's/^/  - /'
  fi
  if [ -n "${nongenerated_list//[$'\n']/}" ]; then
    echo
    echo "hand-maintained by definition (generator does not produce these):"
    printf '%s' "$nongenerated_list" | sed 's/^/  - /'
  fi
} >> "$REPORT"

# --- unified diffs for every differing file -------------------------------
if [ "$SHOW_DIFFS" -eq 1 ] && [ "$count_differs" -gt 0 ]; then
  {
    echo
    echo "## Unified diffs (generator output -> committed copy)"
    echo
    echo "Read a '+' line as content present in the committed file but absent from"
    echo "generator output: a hand-edit the generator would overwrite. Read a '-'"
    echo "line as content the generator would introduce."
  } >> "$REPORT"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    {
      echo
      echo "### $f"
      echo
      echo '```diff'
      diff -u \
        --label "generated/$f" \
        --label "$SOURCE_REL/$f" \
        "$TMP_OUT/$f" "$SOURCE_DIR/$f" || true
      echo '```'
    } >> "$REPORT"
  done <<< "$differs_list"
fi

# --- read-only assertion (story AC 4) -------------------------------------
AFTER_FP="$(fingerprint_source)"
AFTER_GIT="$(git_view_source)"

MUTATED=0
if [ "$BEFORE_FP" != "$AFTER_FP" ]; then
  MUTATED=1
  echo "dryrun-pages-site-diff.sh: FAIL — content fingerprint of $SOURCE_REL changed during the run" >&2
  diff <(printf '%s\n' "$BEFORE_FP") <(printf '%s\n' "$AFTER_FP") >&2 || true
fi
if [ "$BEFORE_GIT" != "$AFTER_GIT" ]; then
  MUTATED=1
  echo "dryrun-pages-site-diff.sh: FAIL — git status for $SOURCE_REL changed during the run" >&2
  diff <(printf '%s\n' "$BEFORE_GIT") <(printf '%s\n' "$AFTER_GIT") >&2 || true
fi

{
  echo
  echo "## Read-only assertion"
  echo
  if [ "$MUTATED" -eq 0 ]; then
    echo "$SOURCE_REL is byte-identical before and after this run (content"
    echo "fingerprint and \`git status --porcelain\` both unchanged)."
  else
    echo "FAILED: $SOURCE_REL changed during this run. See stderr."
  fi
  echo
  echo "git status --porcelain -- $SOURCE_REL:"
  if [ -z "$AFTER_GIT" ]; then
    echo "  (empty)"
  else
    printf '%s\n' "$AFTER_GIT" | sed 's/^/  /'
  fi
  echo "git diff --stat -- $SOURCE_REL:"
  _stat="$(git -C "$REPO_ROOT" diff --stat -- "$SOURCE_REL" 2>/dev/null || true)"
  if [ -z "$_stat" ]; then
    echo "  (empty)"
  else
    printf '%s\n' "$_stat" | sed 's/^/  /'
  fi
} >> "$REPORT"

cat "$REPORT"
if [ -n "$OUT_FILE" ]; then
  mkdir -p "$(dirname "$OUT_FILE")"
  cp "$REPORT" "$OUT_FILE"
  echo
  echo "dryrun-pages-site-diff.sh: report written to $OUT_FILE"
fi

if [ "$MUTATED" -ne 0 ]; then
  exit 4
fi
if [ "$count_differs" -gt 0 ] || [ "$count_missing" -gt 0 ]; then
  exit 3
fi
exit 0
