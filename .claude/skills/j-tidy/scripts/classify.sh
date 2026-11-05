#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-tidy/scripts/classify.sh - enumerate worktrees and branches, classify each one
# reclaimable or retained, with a reason (E56_S06_T01)
#
# READ-ONLY. This script removes nothing, deletes no branch, writes no ref and touches no working
# tree. It only measures and judges. Removal is skills/j-tidy/scripts/reap.sh (E56_S06_T03).
#
# ---------------------------------------------------------------------------
# WHY THE MERGE TEST IS CONTENT-BASED AND NOT AN ANCESTRY CHECK
# ---------------------------------------------------------------------------
# DO NOT "simplify" the content test below back to `git merge-base --is-ancestor`. It was an
# ancestry check once; it is wrong for this repository, and the measurement is on the record.
#
# Board commits land on main SQUASHED, so a branch tip is routinely not an ancestor of main even
# when every line of its content is already there. Measured in this repo on 2026-11-04, before any
# of this existed: an ancestry-only check classified 0 of 228 worktrees as reclaimable, while a
# content check on a ten-entry sample showed all ten at ahead=0 carrying nothing unique. The
# population is 229 worktrees / 350 branches / 9.5 GB of disk. An ancestry-only classifier
# reclaims none of it.
#
# THE TEST, for a ref R and its target ref T:
#
#   mb     = git merge-base T R                      the fork point
#   P      = git diff --name-only mb R               paths R touched since the fork point
#   D      = git diff --name-only T R                paths where R differs from T right now
#   unique = P intersect D
#
#   unique empty  =>  R carries no content that is not already in T.
#
# Both obvious one-liners are wrong, which is why this is an intersection:
#
#   - two-dot `git diff T R` alone is non-empty for every entry that is merely BEHIND T, so it
#     would retain the entire backlog in a repo whose main keeps moving (which is this one);
#   - three-dot `git diff T...R` (that is, mb -> R) is non-empty for exactly the squash-merged
#     case this story exists to catch, because mb predates the squashed work.
#
# The intersection is empty for a plain ancestor (P is empty), empty for a squash-merged branch
# whose touched files now match T, and NON-empty whenever R holds any content T does not - which
# is the only direction that can destroy work.
#
# On the story's "zero commits ahead" condition: a squash-merged branch is by definition ahead > 0,
# so requiring ahead == 0 as a separate gate would make the story's own squash-merge acceptance
# criterion unsatisfiable. The content test above is the decisive signal (as E56_S06_T01 states),
# and ahead == 0 is the strictly stronger case it already subsumes - an ancestor has an empty P.
# The raw ahead count is measured and reported for every entry regardless, and the reason text says
# which of the two merge shapes a reclaimable verdict rests on ("already merged" vs "squash-merged").
# Nothing is hidden behind the collapse.
#
# ---------------------------------------------------------------------------
# ASYMMETRIC BIAS - FAIL CLOSED, ALWAYS
# ---------------------------------------------------------------------------
# Wrongly retained is cheap (some disk stays used). Wrongly reclaimed destroys the only copy of
# someone's work. Every condition that cannot be affirmatively evaluated - unresolvable ref, failing
# merge-base, unreadable path, missing directory, indeterminate liveness, a path with an embedded
# newline that would corrupt the intersection - yields `retained`, never `reclaimable`. There is no
# code path to `reclaimable` that skips a condition.
#
# ---------------------------------------------------------------------------
# THE FOUR CONDITIONS (all must hold for `reclaimable`)
# ---------------------------------------------------------------------------
#   1+2. Carries no unique content vs its target ref - the content test above (ahead is reported).
#   3.   Clean tree - `git status --porcelain` empty, so MODIFIED and UNTRACKED both count as dirty.
#   4.   Liveness-clear - scripts/check-worktree-liveness.sh (E37_S03_T01) reports no process with
#        its cwd inside the path. Reused, never reimplemented. ANY non-zero exit (1 live process,
#        2 usage, 3 bad path, 4 cannot determine) is `retained`, consistent with that script's own
#        fail-closed design. Evaluated LAST and only for entries that passed the cheaper conditions,
#        because `lsof +D` over a multi-GB tree is the expensive one.
#
# ---------------------------------------------------------------------------
# TARGET REF
# ---------------------------------------------------------------------------
# Resolved ONLY through skills/j-tidy/scripts/target-ref.sh - the single seam E56_S06 requires, so
# E56_S01 can retarget task worktrees onto their story branch by editing that one file. The literal
# string "main" does not appear in this script.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   classify.sh [--repo <dir>] [--no-disk] [--header] [--only <name> | --only-path <path>]
#   classify.sh -h | --help
#
#     --repo <dir>  run against this repository instead of the current directory
#     --no-disk     skip the `du` pass (bytes reported as "-"); for callers that only need verdicts
#     --header      emit a leading "#"-prefixed field-name line (human debugging aid)
#     --only <name> classify ONLY entries with this exact name (branch name, or "(detached)").
#                   This is a filter on enumeration and nothing else - the verdict comes from the
#                   same code path as a full run. It exists so reap.sh (E56_S06_T03) can re-verify
#                   a single entry immediately before removing it, rather than trusting a record
#                   stream that may be minutes old, WITHOUT a second divergent copy of the
#                   conditions.
#
#                   WARNING - NOT UNIQUE FOR WORKTREES. Every detached worktree is named
#                   "(detached)", so --only "(detached)" emits one record PER detached worktree.
#                   Use --only-path for worktree entries. Branch names are unique, so --only is
#                   correct for kind=branch.
#
#     --only-path <path>
#                   classify ONLY the worktree whose path is this, emitting zero or one record.
#                   Matching is on the resolved physical path where the directory still exists,
#                   and on the literal string otherwise (so a worktree whose directory is gone is
#                   still addressable). Branch entries, which have no path, are never emitted
#                   under this filter.
#
#                   Added by the E56_S06_T03 rework. The verification pass found that reap.sh's
#                   re-verification read only the FIRST record of --only "(detached)", so with two
#                   detached worktrees it could validate entry A and then remove entry B - and the
#                   remove guard checks liveness, not dirtiness, so uncommitted work in B would be
#                   destroyed. `path` is unique where `name` is not; this selector is what makes
#                   re-verification address the entry it is actually about to delete.
#
#     --only and --only-path are mutually exclusive.
#
# OUTPUT - one TAB-separated record per entry on stdout, field order FIXED:
#
#   kind  name  path  population  target  verdict  ahead  bytes  age_days  reason
#
#     kind        worktree | branch           branch = a local branch with no worktree
#     name        branch name, or "(detached)" for a detached worktree
#     path        worktree path, or "-" for a branch with no worktree
#     population  board-task (<E##_S##_T##-slug>) | bundle (bundle-E##_S##) |
#                 agent (agent-<hash>) | other
#     target      the ref this entry's work should have reached (from target-ref.sh)
#     verdict     reclaimable | retained
#     ahead       commits on this ref not reachable from target, or "-" if unmeasurable
#     bytes       disk used by the worktree directory, 0 for a branch with no worktree,
#                 "-" under --no-disk
#     age_days    whole days since the ref's last commit, or "-" if unmeasurable
#     reason      human-readable; never contains a TAB. A reason starting with "excluded: " marks an
#                 entry that is STRUCTURALLY never reclaimable (the primary checkout, the worktree
#                 this run is standing in, the target ref itself). Those are reported, never
#                 silently dropped, but downstream must not offer them for removal even on
#                 confirmation. Every other `retained` reason names the failing safety condition.
#
# The `agent` population is the whole reason this enumeration exists: /reconcile walks the BOARD and
# matches worktrees by task-ID slug, so `agent-<hash>` worktrees (native EnterWorktree tool,
# `isolation: "worktree"` subagents) are invisible to it. They are the bulk of the 9.5 GB.
#
# EXIT CODES
#   0  classification completed (records on stdout; a `retained` verdict is not an error)
#   2  usage error, or not inside a git repository
#   3  the liveness script could not be located - condition 4 is unevaluable, so nothing can be
#      classified reclaimable; refuses to run rather than silently degrade
# ---------------------------------------------------------------------------
set -u

SELF_NAME="classify.sh"
SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

die() { printf '%s: %s\n' "$SELF_NAME" "$1" >&2; exit 2; }

REPO=""
WANT_DISK=1
WANT_HEADER=0
ONLY=""
ONLY_PATH=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help|help)
      sed -n '2,/^# ----*$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --repo)
      [ "$#" -ge 2 ] || die "--repo needs a directory"
      REPO="$2"; shift 2 ;;
    --repo=*) REPO="${1#--repo=}"; shift ;;
    --no-disk) WANT_DISK=0; shift ;;
    --header)  WANT_HEADER=1; shift ;;
    --only)
      [ "$#" -ge 2 ] || die "--only needs an entry name"
      ONLY="$2"; shift 2 ;;
    --only=*) ONLY="${1#--only=}"; shift ;;
    --only-path)
      [ "$#" -ge 2 ] || die "--only-path needs a worktree path"
      ONLY_PATH="$2"; shift 2 ;;
    --only-path=*) ONLY_PATH="${1#--only-path=}"; shift ;;
    *) die "unknown argument '$1'" ;;
  esac
done

[ -n "$ONLY" ] && [ -n "$ONLY_PATH" ] && \
  die "--only and --only-path are mutually exclusive; pass one or the other"

# The seam. Sourced, so there is no subprocess per entry and exactly one implementation.
# shellcheck source=./target-ref.sh disable=SC1091
. "$SELF_DIR/target-ref.sh" || die "cannot source target-ref.sh"

# scripts/check-worktree-liveness.sh sits three levels up from this skill's scripts directory, both
# in this repo and in a consumer install (node_modules/@jenga-ai/agent/...).
LIVENESS="$SELF_DIR/../../../scripts/check-worktree-liveness.sh"
if [ ! -x "$LIVENESS" ]; then
  printf '%s: cannot find an executable scripts/check-worktree-liveness.sh (looked at %s).\n' \
    "$SELF_NAME" "$LIVENESS" >&2
  printf '%s: condition 4 (liveness) would be unevaluable, so no entry could be classified reclaimable. Refusing to run.\n' \
    "$SELF_NAME" >&2
  exit 3
fi

if [ -n "$REPO" ]; then
  [ -d "$REPO" ] || die "--repo '$REPO' is not a directory"
  CDPATH='' cd -- "$REPO" || die "cannot enter '$REPO'"
fi

git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)" || die "cannot resolve the repository root"
HERE="$(CDPATH='' cd -P -- "$TOPLEVEL" && pwd -P)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tidy-classify.XXXXXX")" || die "cannot create a scratch directory"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

NOW="$(date +%s)"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# scrub <text> - make a string safe for a TAB-separated field and a single line.
scrub() { printf '%s' "$1" | tr '\t\n\r' '   ' | sed 's/  */ /g; s/^ //; s/ $//'; }

# population_of <branch-name> <dir-basename> - tag the entry's population.
population_of() {
  local b="${1:-}" d="${2:-}" s
  for s in "$b" "$d"; do
    [ -n "$s" ] || continue
    case "$s" in
      E[0-9]*_S[0-9]*_T[0-9]*) printf 'board-task\n'; return 0 ;;
      bundle-E[0-9]*_S[0-9]*)  printf 'bundle\n';     return 0 ;;
      agent-*)                 printf 'agent\n';      return 0 ;;
    esac
  done
  printf 'other\n'
}

# disk_bytes <path> - whole bytes used by a directory, or "-" when unavailable/disabled.
disk_bytes() {
  local p="$1" kb
  [ "$WANT_DISK" -eq 1 ] || { printf '%s\n' '-'; return 0; }
  [ -d "$p" ] || { printf '%s\n' '-'; return 0; }
  kb="$(du -sk "$p" 2>/dev/null | awk 'NR==1{print $1}')"
  case "$kb" in
    ''|*[!0-9]*) printf '%s\n' '-' ;;
    *) printf '%s\n' "$((kb * 1024))" ;;
  esac
}

# age_days <ref> - whole days since the ref's last commit, or "-".
age_days() {
  local ref="$1" ts
  ts="$(git log -1 --format=%ct "$ref" -- 2>/dev/null)"
  case "$ts" in
    ''|*[!0-9]*) printf '%s\n' '-' ;;
    *) printf '%s\n' "$(( (NOW - ts) / 86400 ))" ;;
  esac
}

# ahead_count <target> <ref> - commits on ref not reachable from target, or "-".
ahead_count() {
  local n
  n="$(git rev-list --count "$1..$2" 2>/dev/null)"
  case "$n" in
    ''|*[!0-9]*) printf '%s\n' '-' ;;
    *) printf '%s\n' "$n" ;;
  esac
}

# nul_to_lines <raw> <out> - convert NUL-separated git output to one path per line.
# Fails (exit 1) when a path contains an embedded newline, which would silently corrupt the
# line-based intersection below. Fail closed: the caller turns this into `retained`.
nul_to_lines() {
  local raw="$1" out="$2" recs lines
  recs="$(tr -dc '\0' < "$raw" | wc -c | tr -d ' ')"
  tr '\0' '\n' < "$raw" > "$out" || return 1
  lines="$(wc -l < "$out" | tr -d ' ')"
  [ "$recs" = "$lines" ]
}

# content_unique <target> <ref> - the content test documented in the header.
# Sets UNIQUE_COUNT and UNIQUE_SAMPLE.
#   0 = carries nothing unique    1 = carries unique content    2 = undeterminable (fail closed)
UNIQUE_COUNT=0
UNIQUE_SAMPLE=""
content_unique() {
  local target="$1" ref="$2" mb
  UNIQUE_COUNT=0
  UNIQUE_SAMPLE=""

  mb="$(git merge-base "$target" "$ref" 2>/dev/null)" || return 2
  [ -n "$mb" ] || return 2

  git diff --name-only -z "$mb" "$ref" > "$WORK/p.raw" 2>/dev/null || return 2
  git diff --name-only -z "$target" "$ref" > "$WORK/d.raw" 2>/dev/null || return 2
  nul_to_lines "$WORK/p.raw" "$WORK/p" || return 2
  nul_to_lines "$WORK/d.raw" "$WORK/d" || return 2

  # A plain ancestor touched nothing since the fork point: nothing unique, by definition.
  [ -s "$WORK/p" ] || return 0

  LC_ALL=C sort -u "$WORK/p" > "$WORK/p.s" || return 2
  LC_ALL=C sort -u "$WORK/d" > "$WORK/d.s" || return 2
  LC_ALL=C comm -12 "$WORK/p.s" "$WORK/d.s" > "$WORK/u" || return 2

  UNIQUE_COUNT="$(wc -l < "$WORK/u" | tr -d ' ')"
  [ "$UNIQUE_COUNT" -gt 0 ] || return 0
  UNIQUE_SAMPLE="$(head -3 "$WORK/u" | tr '\n' ' ')"
  [ "$UNIQUE_COUNT" -gt 3 ] && UNIQUE_SAMPLE="$UNIQUE_SAMPLE(+$((UNIQUE_COUNT - 3)) more)"
  return 1
}

# dirty_summary <path> - prints "clean", "modified=N untracked=M", or "unreadable".
dirty_summary() {
  local p="$1" out mod unt
  out="$(git -C "$p" status --porcelain 2>/dev/null)" || { printf 'unreadable\n'; return 0; }
  [ -n "$out" ] || { printf 'clean\n'; return 0; }
  unt="$(printf '%s\n' "$out" | grep -c '^??' | tr -d ' ')"
  mod="$(printf '%s\n' "$out" | grep -vc '^??' | tr -d ' ')"
  printf 'modified=%s untracked=%s\n' "$mod" "$unt"
}

emit() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "$(scrub "${10}")"
}

# classify_entry <kind> <name> <path> - evaluate one entry and emit its record.
# <path> is "-" for a branch with no worktree. Structural exclusions are decided by the caller.
classify_entry() {
  local kind="$1" name="$2" path="$3"
  local base pop target ref bytes age ahead rc dirt live_out live_rc reason

  base=""
  [ "$path" != "-" ] && base="$(basename -- "$path")"
  pop="$(population_of "$name" "$base")"
  target="$(tidy_target_ref "$pop" "$name")" || target=""
  ref="$name"
  [ "$ref" = "(detached)" ] && ref="$(git -C "${path}" rev-parse HEAD 2>/dev/null || echo '')"

  bytes=0
  [ "$path" != "-" ] && bytes="$(disk_bytes "$path")"
  [ "$WANT_DISK" -eq 0 ] && bytes='-'

  if [ -z "$target" ]; then
    emit "$kind" "$name" "$path" "$pop" "-" retained '-' "$bytes" '-' \
      "target ref could not be resolved for population $pop"
    return 0
  fi
  age="$(age_days "$ref")"

  # The entry must not be compared against itself: a ref IS trivially fully contained in itself,
  # which would classify the target ref (main today) as reclaimable and delete it.
  if [ -n "$ref" ] && [ "$ref" = "$target" ]; then
    emit "$kind" "$name" "$path" "$pop" "$target" retained '-' "$bytes" "$age" \
      "excluded: is the target ref ($target)"
    return 0
  fi

  if [ -z "$ref" ] || ! git rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1; then
    emit "$kind" "$name" "$path" "$pop" "$target" retained '-' "$bytes" "$age" \
      "ref '${ref:-$name}' could not be resolved to a commit"
    return 0
  fi
  if ! git rev-parse --verify --quiet "$target^{commit}" >/dev/null 2>&1; then
    emit "$kind" "$name" "$path" "$pop" "$target" retained '-' "$bytes" "$age" \
      "target ref '$target' does not exist in this repository"
    return 0
  fi

  ahead="$(ahead_count "$target" "$ref")"

  # Conditions 1+2 - content.
  content_unique "$target" "$ref"; rc=$?
  if [ "$rc" -eq 2 ]; then
    emit "$kind" "$name" "$path" "$pop" "$target" retained "$ahead" "$bytes" "$age" \
      "content comparison against $target could not be evaluated (merge-base or diff failed, or a path contains a newline)"
    return 0
  fi
  if [ "$rc" -eq 1 ]; then
    emit "$kind" "$name" "$path" "$pop" "$target" retained "$ahead" "$bytes" "$age" \
      "carries content not in $target: $UNIQUE_COUNT path(s) [$UNIQUE_SAMPLE]"
    return 0
  fi

  if [ "$path" != "-" ]; then
    # Condition 3 - clean tree.
    if [ ! -d "$path" ]; then
      emit "$kind" "$name" "$path" "$pop" "$target" retained "$ahead" "$bytes" "$age" \
        "worktree directory is missing (run git worktree prune)"
      return 0
    fi
    dirt="$(dirty_summary "$path")"
    if [ "$dirt" = "unreadable" ]; then
      emit "$kind" "$name" "$path" "$pop" "$target" retained "$ahead" "$bytes" "$age" \
        "working tree state could not be read"
      return 0
    fi
    if [ "$dirt" != "clean" ]; then
      emit "$kind" "$name" "$path" "$pop" "$target" retained "$ahead" "$bytes" "$age" \
        "dirty working tree ($dirt)"
      return 0
    fi

    # Condition 4 - liveness. Last, because it is the expensive one.
    live_out="$("$LIVENESS" "$path" 2>&1)"; live_rc=$?
    if [ "$live_rc" -ne 0 ]; then
      emit "$kind" "$name" "$path" "$pop" "$target" retained "$ahead" "$bytes" "$age" \
        "liveness check exited $live_rc: $(printf '%s' "$live_out" | head -1)"
      return 0
    fi
  fi

  if [ "$ahead" = "0" ]; then
    reason="already merged into $target (ancestor); clean; no live process"
  else
    reason="squash-merged into $target ($ahead commit(s) ahead, no unique content); clean; no live process"
  fi
  [ "$path" = "-" ] && reason="$reason; no worktree"
  emit "$kind" "$name" "$path" "$pop" "$target" reclaimable "$ahead" "$bytes" "$age" "$reason"
}

# ---------------------------------------------------------------------------
# pass 1 - worktrees
# ---------------------------------------------------------------------------
[ "$WANT_HEADER" -eq 1 ] && \
  printf '#kind\tname\tpath\tpopulation\ttarget\tverdict\tahead\tbytes\tage_days\treason\n'

BRANCHES_WITH_WORKTREE="$WORK/claimed"
: > "$BRANCHES_WITH_WORKTREE"

wt_path=""; wt_branch=""; wt_locked=0; wt_prunable=0; wt_bare=0; wt_first=1

flush_worktree() {
  [ -n "$wt_path" ] || return 0
  local is_first="$1" name physical pop base bytes age
  name="${wt_branch:-(detached)}"
  [ -n "$wt_branch" ] && printf '%s\n' "$wt_branch" >> "$BRANCHES_WITH_WORKTREE"

  # --only / --only-path filter at ENUMERATION, not at emit: a single-entry re-verification must
  # not pay for classifying the other few hundred entries (measured 11m31s for a full pass here).
  if [ -n "$ONLY" ] && [ "$name" != "$ONLY" ]; then
    return 0
  fi

  physical=""
  [ -d "$wt_path" ] && physical="$(CDPATH='' cd -P -- "$wt_path" 2>/dev/null && pwd -P)"

  # Path-keyed selection. Compare on the resolved physical path when the directory exists (so
  # /tmp vs /private/tmp, symlinked parents and trailing slashes cannot cause a miss), and on the
  # literal string otherwise, so a worktree whose directory has been deleted stays addressable.
  # Unlike --only this is unique per worktree, which is the whole point: see the --only-path note
  # in the usage block above for the defect that required it.
  if [ -n "$ONLY_PATH" ]; then
    local want_phys=""
    [ -d "$ONLY_PATH" ] && want_phys="$(CDPATH='' cd -P -- "$ONLY_PATH" 2>/dev/null && pwd -P)"
    if [ -n "$physical" ] && [ -n "$want_phys" ]; then
      [ "$physical" = "$want_phys" ] || return 0
    else
      [ "$wt_path" = "$ONLY_PATH" ] || return 0
    fi
  fi
  base="$(basename -- "$wt_path")"
  pop="$(population_of "$name" "$base")"

  if [ "$is_first" -eq 1 ] || [ "$wt_bare" -eq 1 ]; then
    bytes="$(disk_bytes "$wt_path")"
    age="$(age_days "${wt_branch:-HEAD}")"
    emit worktree "$name" "$wt_path" "$pop" "$(tidy_target_ref "$pop" "$name")" retained \
      '-' "$bytes" "$age" "excluded: primary checkout"
    return 0
  fi
  if [ -n "$physical" ] && [ "$physical" = "$HERE" ]; then
    bytes="$(disk_bytes "$wt_path")"
    age="$(age_days "${wt_branch:-HEAD}")"
    emit worktree "$name" "$wt_path" "$pop" "$(tidy_target_ref "$pop" "$name")" retained \
      '-' "$bytes" "$age" "excluded: current worktree (this run is standing in it)"
    return 0
  fi
  if [ "$wt_locked" -eq 1 ]; then
    bytes="$(disk_bytes "$wt_path")"
    age="$(age_days "${wt_branch:-HEAD}")"
    emit worktree "$name" "$wt_path" "$pop" "$(tidy_target_ref "$pop" "$name")" retained \
      '-' "$bytes" "$age" "locked worktree (git worktree lock)"
    return 0
  fi
  if [ "$wt_prunable" -eq 1 ]; then
    bytes="$(disk_bytes "$wt_path")"
    age="$(age_days "${wt_branch:-HEAD}")"
    emit worktree "$name" "$wt_path" "$pop" "$(tidy_target_ref "$pop" "$name")" retained \
      '-' "$bytes" "$age" "worktree directory is missing (run git worktree prune)"
    return 0
  fi
  classify_entry worktree "$name" "$wt_path"
}

WT_RECORDS="$(git worktree list --porcelain 2>/dev/null)"
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    "worktree "*) wt_path="${line#worktree }"; wt_branch=""; wt_locked=0; wt_prunable=0; wt_bare=0 ;;
    "branch "*)   wt_branch="${line#branch refs/heads/}" ;;
    "locked"*)    wt_locked=1 ;;
    "prunable"*)  wt_prunable=1 ;;
    "bare"*)      wt_bare=1 ;;
    "")           flush_worktree "$wt_first"; wt_first=0; wt_path="" ;;
  esac
done <<EOF
$WT_RECORDS

EOF

# ---------------------------------------------------------------------------
# pass 2 - local branches with no worktree (the 350-vs-229 gap)
# ---------------------------------------------------------------------------
LC_ALL=C sort -u "$BRANCHES_WITH_WORKTREE" > "$WORK/claimed.s"
git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null \
  | LC_ALL=C sort -u > "$WORK/branches.s"
LC_ALL=C comm -13 "$WORK/claimed.s" "$WORK/branches.s" > "$WORK/orphans"

while IFS= read -r br; do
  [ -n "$br" ] || continue
  if [ -n "$ONLY" ] && [ "$br" != "$ONLY" ]; then
    continue
  fi
  # A branch entry has no path, so --only-path can never match one. Emitting nothing here is what
  # lets reap.sh use --only-path for worktrees and --only for branches without either filter
  # leaking entries of the other kind into a single-entry re-verification.
  if [ -n "$ONLY_PATH" ]; then
    continue
  fi
  classify_entry branch "$br" '-'
done < "$WORK/orphans"

exit 0
