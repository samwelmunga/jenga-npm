#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-tidy/scripts/reap.sh - the destructive half of j.tidy (E56_S06_T03)
#
# THIS SCRIPT DELETES THINGS. Read the gate below before changing anything in it.
#
# Posture, settled with the user when E56_S06 was filed: AUTO-REAP PROVABLY SAFE, CONFIRM THE REST.
# The task carries `crucial_level: gated` because a classifier false positive here destroys unmerged
# work that exists nowhere else.
#
# ---------------------------------------------------------------------------
# THE GATE IS THE SHAPE OF THE INTERFACE, NOT A POLITENESS CONVENTION
# ---------------------------------------------------------------------------
# Two mutually exclusive modes, and no third:
#
#   --auto            removes every entry the classifier verdicted `reclaimable` - all four safety
#                     conditions held - with no prompting. It is STRUCTURALLY INCAPABLE of touching
#                     a `retained` entry: the verdict is the filter and there is no flag that
#                     widens it. No --all, no --force, no --yes.
#
#   --confirm <name>  removes EXACTLY ONE named entry that the classifier verdicted `retained`,
#                     because a human said so about that entry. There is deliberately no
#                     `--confirm all`, no glob and no list form. A name matching zero records, or
#                     more than one, is refused rather than guessed at.
#
# A shell script cannot verify that a human really consented. What it can do is make the only route
# to a risky removal a one-entry-at-a-time invocation that spells the entry out. SKILL.md instructs
# the agent to ask per entry and pass the answer through; DECLINING MEANS --confirm IS NEVER CALLED
# FOR THAT ENTRY, so the entry is left untouched by construction rather than by remembering to skip
# it. This is the same posture scripts/worktree-remove-guard.sh itself takes: make the unsafe thing
# require a deliberate, individually-spelled act.
#
# Entries whose reason begins "excluded: " - the primary checkout, the worktree this run is standing
# in, the target ref itself - are refused in BOTH modes. They are never removable, confirmation or
# not.
#
# ---------------------------------------------------------------------------
# RE-VERIFY IMMEDIATELY BEFORE DESTROYING
# ---------------------------------------------------------------------------
# A record stream can be minutes old - a full classification of the Jenga repo measured 11m31s on
# 2026-11-04 - and in that window a process can start or a file can change. So every entry is
# re-classified, individually, immediately before it is touched (`classify.sh --only <name>`), and
# the removal proceeds only if the verdict still matches what was authorised. Otherwise the entry is
# reported as `skipped`, naming the new reason.
#
# The re-check runs the SAME code path as the original verdict. There is no second copy of the four
# conditions in this file, and there must never be one.
#
# ---------------------------------------------------------------------------
# REMOVAL GOES THROUGH THE GUARD, NEVER AROUND IT
# ---------------------------------------------------------------------------
# Worktree removal is `scripts/worktree-remove-guard.sh <path>` and nothing else. This file contains
# no `git worktree remove` call, never passes `--force-ignore-liveness`, and never sets
# WORKTREE_REMOVE_FORCE_IGNORE_LIVENESS. The guard is the hard-block-by-default liveness
# precondition added by E37_S03_T02 after a real 2026-08-25 incident: a completed agent left shell
# polling loops running with their cwd inside a worktree, and that worktree was removed out from
# under them. A guard refusal is reported as `refused` and the entry is skipped - NEVER retried,
# with or without force.
#
# Branch deletion is `git branch -d`, the merge-checking form, NEVER `-d`'s capital sibling. A
# refusal there means git and the classifier disagree about the branch being merged, and git wins:
# the branch is kept and the refusal is reported. There is no fallback, anywhere, by design.
#
# Branch reclamation is separable from worktree reclamation: a branch with no worktree, fully
# represented in its target ref, is reclaimable on its own (the measured 350-vs-229 gap).
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   reap.sh --auto            [--repo <dir>] [--records <file>] [--dry-run]
#   reap.sh --confirm <name>  [--repo <dir>] [--records <file>] [--dry-run]
#   reap.sh -h | --help
#
#     --repo <dir>      act on this repository instead of the current directory
#     --records <file>  take the candidate list from an existing classify.sh record stream instead
#                       of running a full classification first. Every candidate is still
#                       re-verified individually before it is touched, so this is a speed
#                       optimisation and not a trust decision.
#     --dry-run         select, re-verify and report `would-remove`, touching nothing
#
# OUTPUT - one TAB-separated line per entry, then a summary. Outcomes, kept deliberately apart:
#
#     removed                        worktree removed and its branch deleted
#     removed-worktree-branch-kept   worktree removed, `git branch -d` refused - a PARTIAL outcome,
#                                    counted as neither a success nor a failure
#     branch-deleted                 a branch with no worktree, deleted on its own
#     branch-kept                    `git branch -d` refused for a branch with no worktree
#     refused                        the remove guard blocked it (liveness); skipped, never forced
#     failed                         the removal was attempted and failed
#     skipped                        the verdict changed since classification, or the entry is
#                                    structurally excluded, or it is not in the authorised verdict
#     would-remove                   --dry-run
#
# The summary states disk ACTUALLY reclaimed, disk retained, and separate counts for refusals and
# failures. A failed removal is never folded into the success count and its disk is never counted as
# reclaimed.
#
# EXIT CODES
#   0  everything attempted succeeded (including "nothing to do")
#   1  at least one refusal or failure
#   2  usage error
#   *  the classifier's own exit code, if the initial classification failed
# ---------------------------------------------------------------------------
set -u

SELF_NAME="reap.sh"
SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
PACKAGE_ROOT="$(CDPATH='' cd -- "$SELF_DIR/../../.." >/dev/null 2>&1 && pwd -P)"
CLASSIFY="$SELF_DIR/classify.sh"
GUARD="$PACKAGE_ROOT/scripts/worktree-remove-guard.sh"

die() { printf '%s: %s\n' "$SELF_NAME" "$1" >&2; exit 2; }

MODE=""
CONFIRM_NAME=""
REPO=""
RECORDS_IN=""
DRY_RUN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help|help)
      sed -n '2,/^# ----*$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    --auto)
      [ -z "$MODE" ] || die "--auto and --confirm are mutually exclusive"
      MODE=auto; shift ;;
    --confirm)
      [ -z "$MODE" ] || die "--auto and --confirm are mutually exclusive"
      [ "$#" -ge 2 ] || die "--confirm needs exactly one entry name"
      MODE=confirm; CONFIRM_NAME="$2"; shift 2 ;;
    --confirm=*)
      [ -z "$MODE" ] || die "--auto and --confirm are mutually exclusive"
      MODE=confirm; CONFIRM_NAME="${1#--confirm=}"; shift ;;
    --repo)    [ "$#" -ge 2 ] || die "--repo needs a directory"; REPO="$2"; shift 2 ;;
    --repo=*)  REPO="${1#--repo=}"; shift ;;
    --records) [ "$#" -ge 2 ] || die "--records needs a file"; RECORDS_IN="$2"; shift 2 ;;
    --records=*) RECORDS_IN="${1#--records=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) die "unknown argument '$1'" ;;
  esac
done

[ -n "$MODE" ] || die "one of --auto or --confirm <name> is required (there is no default mode)"
if [ "$MODE" = confirm ]; then
  [ -n "$CONFIRM_NAME" ] || die "--confirm needs a non-empty entry name"
  case "$CONFIRM_NAME" in
    *'*'*|*'?'*|all|ALL|--*)
      die "--confirm takes ONE literal entry name: no glob, no 'all', no flag. Confirm entries one at a time." ;;
  esac
fi
[ -x "$GUARD" ] || die "cannot find an executable scripts/worktree-remove-guard.sh (looked at $GUARD); refusing to remove anything without it"

if [ -n "$REPO" ]; then
  [ -d "$REPO" ] || die "--repo '$REPO' is not a directory"
  CDPATH='' cd -- "$REPO" || die "cannot enter '$REPO'"
fi
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tidy-reap.XXXXXX")" || die "cannot create a scratch directory"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# candidate selection
# ---------------------------------------------------------------------------
CANDIDATES="$WORK/candidates"
RECORDS="$WORK/records"

if [ -n "$RECORDS_IN" ]; then
  [ -f "$RECORDS_IN" ] || die "--records '$RECORDS_IN' is not a file"
  grep -v '^#' "$RECORDS_IN" > "$RECORDS" || :
else
  # Disk IS measured here: the summary has to state disk actually reclaimed, and a `du`-less pass
  # would report every removal as zero bytes. --records is the fast path for a caller that already
  # paid for a measured classification.
  bash "$CLASSIFY" > "$RECORDS"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s: classification failed (classify.sh exited %s); nothing was touched.\n' "$SELF_NAME" "$rc" >&2
    exit "$rc"
  fi
fi

WANT_VERDICT=reclaimable
[ "$MODE" = confirm ] && WANT_VERDICT=retained

if [ "$MODE" = auto ]; then
  awk -F'\t' '$6 == "reclaimable" && index($10, "excluded: ") != 1' "$RECORDS" > "$CANDIDATES"
else
  awk -F'\t' -v n="$CONFIRM_NAME" '$2 == n' "$RECORDS" > "$CANDIDATES"
  found="$(wc -l < "$CANDIDATES" | tr -d ' ')"
  if [ "$found" -eq 0 ]; then
    die "--confirm '$CONFIRM_NAME' matches no entry in the current classification"
  fi
  if [ "$found" -gt 1 ]; then
    die "--confirm '$CONFIRM_NAME' matches $found entries; confirm one unambiguous entry at a time"
  fi
fi

# ---------------------------------------------------------------------------
# per-entry action
# ---------------------------------------------------------------------------
N_REMOVED=0
N_PARTIAL=0
N_BRANCH=0
N_BRANCH_KEPT=0
N_REFUSED=0
N_FAILED=0
N_SKIPPED=0
N_WOULD=0
BYTES_RECLAIMED=0
BYTES_RETAINED=0
BYTES_WOULD=0
RC=0

# Disk across EVERY classified entry, not just the candidates this mode acted on, so that "disk
# retained" below means "still in use after this run" rather than "of the handful I looked at" -
# which in --auto mode would always have been zero and read as if nothing was left.
BYTES_ALL="$(awk -F'\t' '$8 ~ /^[0-9]+$/ { s += $8 } END { printf "%d\n", s + 0 }' "$RECORDS")"

# bytes_add <var-ish accumulator> handled inline; "-" and "" count as zero without claiming disk.
num_or_zero() {
  case "${1:-}" in
    ''|'-'|*[!0-9]*) printf '0\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

line() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"; }

# The full ten-field record is read so the field order stays self-documenting and a future change
# does not have to re-derive it; only some of the fields are used below.
# shellcheck disable=SC2034
while IFS=$'\t' read -r kind name path population target verdict ahead bytes age reason; do
  [ -n "${name:-}" ] || continue
  bytes_n="$(num_or_zero "${bytes:-}")"

  # Structural exclusions are refused in both modes, confirmation or not.
  case "${reason:-}" in
    "excluded: "*)
      line skipped "$name" "${path:--}" "$bytes_n" "structurally excluded and never removable: $reason"
      N_SKIPPED=$((N_SKIPPED + 1)); BYTES_RETAINED=$((BYTES_RETAINED + bytes_n)); continue ;;
  esac

  if [ "$verdict" != "$WANT_VERDICT" ]; then
    line skipped "$name" "${path:--}" "$bytes_n" \
      "verdict is '$verdict'; this mode acts only on '$WANT_VERDICT' entries (--auto handles reclaimable ones)"
    N_SKIPPED=$((N_SKIPPED + 1)); BYTES_RETAINED=$((BYTES_RETAINED + bytes_n)); continue
  fi

  # Re-verify THIS entry, right now, through the same classifier.
  #
  # Address it by PATH for a worktree and by NAME for a branch. Paths are unique; names are not -
  # every detached worktree is called "(detached)". The E56_S06_T03 verification pass found that
  # reading NR==1 of `--only "(detached)"` meant that with two detached worktrees this loop could
  # validate entry A and then hand entry B to the guard; since the guard checks liveness and not
  # dirtiness, uncommitted work in B would have been destroyed. Hence --only-path, and hence the
  # ambiguity check below, which fails closed even if a future selector is non-unique again.
  if [ "$kind" = branch ]; then
    fresh="$(bash "$CLASSIFY" --only "$name" --no-disk 2>/dev/null)"
  elif [ -n "${path:-}" ] && [ "$path" != "-" ]; then
    fresh="$(bash "$CLASSIFY" --only-path "$path" --no-disk 2>/dev/null)"
  else
    line skipped "$name" "${path:--}" "$bytes_n" \
      "worktree record carries no path, so it cannot be re-verified unambiguously; refusing to remove it"
    N_SKIPPED=$((N_SKIPPED + 1)); BYTES_RETAINED=$((BYTES_RETAINED + bytes_n)); continue
  fi

  fresh_count="$(printf '%s' "$fresh" | grep -c . || true)"
  if [ "${fresh_count:-0}" -gt 1 ]; then
    line skipped "$name" "${path:--}" "$bytes_n" \
      "re-verification was ambiguous ($fresh_count records matched); refusing to remove on an uncertain match"
    N_SKIPPED=$((N_SKIPPED + 1)); BYTES_RETAINED=$((BYTES_RETAINED + bytes_n)); continue
  fi

  fresh_verdict="$(printf '%s\n' "$fresh" | awk -F'\t' 'NR==1{print $6}')"
  fresh_reason="$(printf '%s\n' "$fresh" | awk -F'\t' 'NR==1{print $10}')"
  if [ -z "$fresh_verdict" ]; then
    line skipped "$name" "${path:--}" "$bytes_n" "re-verification found no such entry any more"
    N_SKIPPED=$((N_SKIPPED + 1)); BYTES_RETAINED=$((BYTES_RETAINED + bytes_n)); continue
  fi
  if [ "$fresh_verdict" != "$verdict" ]; then
    line skipped "$name" "${path:--}" "$bytes_n" \
      "state changed since classification: now '$fresh_verdict' ($fresh_reason)"
    N_SKIPPED=$((N_SKIPPED + 1)); BYTES_RETAINED=$((BYTES_RETAINED + bytes_n)); continue
  fi

  # Structural exclusion, judged on the FRESH reason rather than the record's. Two of the three
  # exclusions are context-dependent ("the worktree this run is standing in", "is the target ref"),
  # so a --records stream captured in another context carries a reason that no longer applies -
  # and in --confirm mode those entries have verdict=retained, which is exactly WANT_VERDICT, so
  # the stale-reason gate near the top of this loop would wave them through.
  case "${fresh_reason:-}" in
    "excluded: "*)
      line skipped "$name" "${path:--}" "$bytes_n" \
        "structurally excluded as of re-verification and never removable: $fresh_reason"
      N_SKIPPED=$((N_SKIPPED + 1)); BYTES_RETAINED=$((BYTES_RETAINED + bytes_n)); continue ;;
  esac

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$kind" = branch ]; then
      line would-remove "$name" '-' "$bytes_n" "would delete the branch with git branch -d ($reason)"
    else
      line would-remove "$name" "$path" "$bytes_n" \
        "would remove the worktree through worktree-remove-guard.sh, then git branch -d ($reason)"
    fi
    N_WOULD=$((N_WOULD + 1)); BYTES_WOULD=$((BYTES_WOULD + bytes_n)); continue
  fi

  if [ "$kind" = branch ]; then
    # Branch-only reclamation: no worktree is involved at all.
    if branch_out="$(git branch -d "$name" 2>&1)"; then
      line branch-deleted "$name" '-' "$bytes_n" "git branch -d succeeded"
      N_BRANCH=$((N_BRANCH + 1)); BYTES_RECLAIMED=$((BYTES_RECLAIMED + bytes_n))
    else
      line branch-kept "$name" '-' "$bytes_n" \
        "git branch -d refused, branch kept (no -D fallback): $(printf '%s' "$branch_out" | tr '\n\t' '  ' | head -c 200)"
      N_BRANCH_KEPT=$((N_BRANCH_KEPT + 1)); BYTES_RETAINED=$((BYTES_RETAINED + bytes_n)); RC=1
    fi
    continue
  fi

  # Worktree removal - through the guard, never git worktree remove directly, never an override.
  #
  # `env -u` is load-bearing, not decoration. The guard honours
  # WORKTREE_REMOVE_FORCE_IGNORE_LIVENESS from its ambient environment, so without this an
  # operator (or a parent process) who had that variable exported would silently turn every
  # removal below into an unconditional `git worktree remove --force` - with every "no override is
  # used" test still passing, because those tests only prove this script never SETS it. Stripping
  # it here means the liveness precondition cannot be disabled from outside this script.
  guard_out="$(env -u WORKTREE_REMOVE_FORCE_IGNORE_LIVENESS "$GUARD" "$path" 2>&1)"
  guard_rc=$?
  if [ "$guard_rc" -ne 0 ]; then
    squashed="$(printf '%s' "$guard_out" | tr '\n\t' '  ' | head -c 300)"
    case "$guard_out" in
      *BLOCKED*)
        line refused "$name" "$path" "$bytes_n" "remove guard blocked it, not retried with force: $squashed"
        N_REFUSED=$((N_REFUSED + 1)) ;;
      *)
        line failed "$name" "$path" "$bytes_n" "removal failed (guard exited $guard_rc): $squashed"
        N_FAILED=$((N_FAILED + 1)) ;;
    esac
    BYTES_RETAINED=$((BYTES_RETAINED + bytes_n))
    RC=1
    continue
  fi

  if [ "$name" = "(detached)" ]; then
    line removed "$name" "$path" "$bytes_n" "worktree removed; detached HEAD, so there is no branch to delete"
    N_REMOVED=$((N_REMOVED + 1)); BYTES_RECLAIMED=$((BYTES_RECLAIMED + bytes_n)); continue
  fi

  if branch_out="$(git branch -d "$name" 2>&1)"; then
    line removed "$name" "$path" "$bytes_n" "worktree removed through the guard; branch deleted with git branch -d"
    N_REMOVED=$((N_REMOVED + 1)); BYTES_RECLAIMED=$((BYTES_RECLAIMED + bytes_n))
  else
    line removed-worktree-branch-kept "$name" "$path" "$bytes_n" \
      "worktree removed; git branch -d refused so the branch is kept (no -D fallback): $(printf '%s' "$branch_out" | tr '\n\t' '  ' | head -c 200)"
    N_PARTIAL=$((N_PARTIAL + 1)); BYTES_RECLAIMED=$((BYTES_RECLAIMED + bytes_n))
  fi
done < "$CANDIDATES"

# ---------------------------------------------------------------------------
# summary - categories kept apart, failures never folded into successes
# ---------------------------------------------------------------------------
human() {
  awk -v b="$1" 'BEGIN {
    if (b >= 1073741824) { printf "%.1f GB\n", b / 1073741824; exit }
    if (b >= 1048576)    { printf "%.1f MB\n", b / 1048576; exit }
    if (b >= 1024)       { printf "%.1f KB\n", b / 1024; exit }
    printf "%d B\n", b
  }'
}

BYTES_STILL_IN_USE=$((BYTES_ALL - BYTES_RECLAIMED))
[ "$BYTES_STILL_IN_USE" -lt 0 ] && BYTES_STILL_IN_USE=0

# A --confirm run that removed nothing did not honour the request it was given; that is a non-zero
# outcome even though no removal "failed", so it is never reported as a plain success.
if [ "$MODE" = confirm ] && [ "$DRY_RUN" -eq 0 ] && \
   [ "$((N_REMOVED + N_PARTIAL + N_BRANCH))" -eq 0 ]; then
  RC=1
fi

printf '\n'
if [ "$DRY_RUN" -eq 1 ]; then
  printf 'DRY RUN - nothing was touched.\n'
  printf '  would remove                   %d\n' "$N_WOULD"
  printf '  disk that would be reclaimed   %s\n' "$(human "$BYTES_WOULD")"
else
  printf 'REAP SUMMARY (mode: %s)\n' "$MODE"
  printf '  removed (worktree + branch)    %d\n' "$N_REMOVED"
  printf '  removed, branch kept           %d\n' "$N_PARTIAL"
  printf '  branches deleted (no worktree) %d\n' "$N_BRANCH"
  printf '  branches kept (git refused -d) %d\n' "$N_BRANCH_KEPT"
  printf '  refused by the remove guard    %d\n' "$N_REFUSED"
  printf '  FAILED                         %d\n' "$N_FAILED"
fi
printf '  skipped                        %d\n' "$N_SKIPPED"
printf '  disk reclaimed                 %s\n' "$(human "$BYTES_RECLAIMED")"
printf '  disk retained (still in use)   %s\n' "$(human "$BYTES_STILL_IN_USE")"
if [ "$BYTES_RETAINED" -gt 0 ]; then
  printf '  of which, entries this run declined to remove: %s (reasons listed above)\n' \
    "$(human "$BYTES_RETAINED")"
fi
if [ "$N_REFUSED" -gt 0 ] || [ "$N_FAILED" -gt 0 ]; then
  printf '  => refusals and failures are listed above and are NOT counted as removals.\n'
fi
if [ "$MODE" = auto ]; then
  printf '  Retained entries were not considered here: each needs its own --confirm <name>.\n'
fi

exit "$RC"
