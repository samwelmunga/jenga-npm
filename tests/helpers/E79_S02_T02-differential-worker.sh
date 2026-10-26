#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tests/helpers/E79_S02_T02-differential-worker.sh
# (epic E79, story E79_S02, task E79_S02_T02)
#
# Compares scripts/commits-for-item.sh (the resolver) with the two legacy `git log --grep` calls for ONE board id,
# against ONE repository, and records a one-line verdict. It is the unit of work behind
# tests/commits-for-item-differential.bats; the bats file runs it once per id, in parallel.
#
# Run it with `bash`, never as ./worker: it needs no executable bit.
#
# USAGE
#   bash E79_S02_T02-differential-worker.sh <repo> <outdir> <resolver> <id>
#
#   <repo>      the repository to read (the test hands in a throwaway snapshot, never the working repository).
#               It is only ever read: `git log` and the resolver. No ref, index or working-tree write.
#   <outdir>    existing directory; the verdict goes to <outdir>/<id>.res
#   <resolver>  path of the resolver script (a stub in the mutation tests)
#   <id>        E##, E##_S## or E##_S##_T##
#
# THE TWO LEGACY CALLS (verbatim from the audit, project/documentation/commit-consumer-audit.md)
#   anchored    git log --all --no-merges --extended-regexp --grep="<id>([^0-9_]|$)" --pretty=format:%H
#               the commits_for_ticket copy in mark-merged.sh, check-privatized.sh, mark-publicized.sh and
#               mark-deployed.sh (M4 to M7)
#   unanchored  git log --all --no-merges --grep="<id>" --pretty=format:%H
#               extract-task-diff-stats.sh (M1), extract-diff-stats.sh (M2), the reconcile step (M8)
#
# THE VERDICT (one line, "<id> <verdict>", written to <outdir>/<id>.res; this script always exits 0)
#   OK                  resolver == anchored legacy (same SHAs, same order) AND resolver == unanchored legacy
#   INTENDED <n>        resolver == anchored legacy, and the unanchored legacy returned <n> more commits, every
#                       one of which names the id only as the PREFIX of a longer id (the id followed by a digit
#                       or an underscore). That is the anchoring fix, a difference by design.
#   FAIL <reason>       anything else: the resolver exited non-zero, differs from the anchored legacy call, lacks
#                       a commit the unanchored call has, or the unanchored call has an extra commit that is not
#                       a prefix collision. A FAIL is an unexplained difference and fails the test.
# ---------------------------------------------------------------------------

set -u

if [ $# -ne 4 ]; then
  printf 'usage: %s <repo> <outdir> <resolver> <id>\n' "$0" >&2
  exit 2
fi
REPO="$1"
OUT="$2"
RESOLVER="$3"
ID="$4"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/e79-diff.XXXXXX")" || {
  printf '%s FAIL cannot create a temporary directory\n' "$ID" >"$OUT/$ID.res"
  exit 0
}
trap 'rm -rf "$TMP"' EXIT

verdict() {
  printf '%s %s\n' "$ID" "$1" >"$OUT/$ID.res"
  exit 0
}

# lines_sorted <string> <file>: the string's lines, sorted, into the file (an empty string gives an empty file).
lines_sorted() {
  : >"$2"
  if [ -n "$1" ]; then
    printf '%s\n' "$1" | sort >"$2"
  fi
  return 0
}

bash "$RESOLVER" "$ID" --repo "$REPO" >"$TMP/resolver" 2>"$TMP/resolver.err"
rc=$?
[ "$rc" -eq 0 ] || verdict "FAIL resolver exited $rc: $(tr '\n' ' ' <"$TMP/resolver.err")"

git -C "$REPO" log --all --no-merges --extended-regexp --grep="${ID}([^0-9_]|\$)" \
  --pretty=format:%H >"$TMP/anchored" 2>"$TMP/anchored.err" ||
  verdict "FAIL anchored legacy git log failed: $(tr '\n' ' ' <"$TMP/anchored.err")"

git -C "$REPO" log --all --no-merges --grep="$ID" \
  --pretty=format:%H >"$TMP/unanchored" 2>"$TMP/unanchored.err" ||
  verdict "FAIL unanchored legacy git log failed: $(tr '\n' ' ' <"$TMP/unanchored.err")"

# Command substitution drops trailing newlines, which is the only way the resolver's output (newline-terminated) and
# git's `format:` output (no trailing newline) differ. Everything else, including order, is compared as is.
R="$(cat "$TMP/resolver")"
A="$(cat "$TMP/anchored")"
U="$(cat "$TMP/unanchored")"

lines_sorted "$R" "$TMP/r.sorted"
lines_sorted "$A" "$TMP/a.sorted"
lines_sorted "$U" "$TMP/u.sorted"

if [ "$R" != "$A" ]; then
  only_r="$(comm -23 "$TMP/r.sorted" "$TMP/a.sorted" | wc -l | tr -d ' ')"
  only_a="$(comm -13 "$TMP/r.sorted" "$TMP/a.sorted" | wc -l | tr -d ' ')"
  if [ "$only_r" = "0" ] && [ "$only_a" = "0" ]; then
    verdict "FAIL resolver and anchored legacy return the same commits in a different order"
  fi
  verdict "FAIL resolver differs from the anchored legacy call: $only_r only in the resolver, $only_a only in the legacy call"
fi

if [ "$R" = "$U" ]; then
  verdict "OK"
fi

# The unanchored set is a superset of the anchored one by construction. Check it, rather than assume it.
missing="$(comm -23 "$TMP/r.sorted" "$TMP/u.sorted" | wc -l | tr -d ' ')"
[ "$missing" = "0" ] || verdict "FAIL resolver returned $missing commit(s) the unanchored legacy call does not"

comm -13 "$TMP/r.sorted" "$TMP/u.sorted" >"$TMP/extra"
extra_n="$(wc -l <"$TMP/extra" | tr -d ' ')"

# Every extra commit must name the id as the prefix of a longer id. Ask git for that set independently.
git -C "$REPO" log --all --no-merges --extended-regexp --grep="${ID}[0-9_]" \
  --pretty=format:%H >"$TMP/prefix" 2>"$TMP/prefix.err" ||
  verdict "FAIL prefix-collision git log failed: $(tr '\n' ' ' <"$TMP/prefix.err")"
lines_sorted "$(cat "$TMP/prefix")" "$TMP/prefix.sorted"

unexplained="$(comm -23 "$TMP/extra" "$TMP/prefix.sorted" | wc -l | tr -d ' ')"
if [ "$unexplained" != "0" ]; then
  first="$(comm -23 "$TMP/extra" "$TMP/prefix.sorted" | head -1)"
  verdict "FAIL $unexplained of $extra_n unanchored-only commit(s) are not prefix collisions (first: $first)"
fi

verdict "INTENDED $extra_n"
