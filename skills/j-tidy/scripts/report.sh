#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-tidy/scripts/report.sh - render j.tidy's sweep and apply the config thresholds
# (E56_S06_T02)
#
# READ-ONLY, ALWAYS. This script reports. It removes nothing, deletes no branch and writes no ref,
# and it has no flag that makes it do so - a bare `j.tidy` can never delete anything. Removal is
# skills/j-tidy/scripts/reap.sh (E56_S06_T03), a separate script with its own confirmation gate.
#
# It is the deterministic half of the skill, per CLAUDE.md's "Scripts Over Inline Logic":
# invoking the classifier, aggregating, formatting, truncating and comparing the thresholds all
# happen here. SKILL.md keeps only the judgment - reading the report, asking for the confirmation,
# interpreting an unexpected result.
#
# ---------------------------------------------------------------------------
# NO THRESHOLD NUMBER APPEARS IN THIS FILE
# ---------------------------------------------------------------------------
# Retention age, the count ceilings and the disk ceiling are read at run time from a config file,
# resolved in this order:
#
#   1. $JENGA_TIDY_CONFIG_FILE                                  (test seam / explicit override)
#   2. "$(scripts/resolve-root.sh get configs)/tidy-config.json" (the project instance)
#   3. "<package root>/templates/tidy-config.json"               (the shipped default)
#
# A project instance REPLACES the shipped default whole; there is no merging. This is the same
# two-layer shape as checklists.json and test-scope-map.json.
#
# When no config can be resolved at all, the report says so, SKIPS the ceiling checks and
# truncates nothing. It does not fall back to a built-in number: a hardcoded threshold here is
# exactly what E56_S06_T02 forbids, and a silent default would misreport a project that never
# configured one.
#
# ---------------------------------------------------------------------------
# NO SILENT CAP, EVER
# ---------------------------------------------------------------------------
# Each (verdict, population) group lists at most `report_max_rows_per_group` entries. Whenever
# anything is held back, the report prints how many entries were NOT shown, unconditionally. A
# truncated list that looks complete reads as "nothing there", which is a reporting bug and not a
# display choice.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   report.sh [--repo <dir>] [--no-disk] [--max-rows <n>]
#   report.sh --records <file> [--max-rows <n>]
#   report.sh --print-thresholds
#   report.sh -h | --help
#
#     --repo <dir>        classify this repository instead of the current directory
#     --no-disk           skip the `du` pass (fast, verdict-only; the report says disk was not
#                         measured). A full `du` over a few hundred worktrees is slow.
#     --records <file>    render an existing classify.sh record stream instead of running it again
#                         (how reap.sh re-renders, and how the tests feed fixtures)
#     --max-rows <n>      override report_max_rows_per_group for this run; 0 means no truncation
#     --print-thresholds  print the resolved thresholds and the file they came from, then exit.
#                         This is the honest answer to "where did these numbers come from?" and is
#                         what the tests assert against.
#
# EXIT CODES
#   0  report rendered (a crossed ceiling is reported, not an error)
#   2  usage error
#   *  the classifier's own exit code, if classification failed (e.g. 3 = liveness script absent)
# ---------------------------------------------------------------------------
set -u

SELF_NAME="report.sh"
SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
PACKAGE_ROOT="$(CDPATH='' cd -- "$SELF_DIR/../../.." >/dev/null 2>&1 && pwd -P)"
CLASSIFY="$SELF_DIR/classify.sh"
TARGET_REF_SCRIPT="$SELF_DIR/target-ref.sh"
RESOLVE_ROOT="$PACKAGE_ROOT/scripts/resolve-root.sh"

die() { printf '%s: %s\n' "$SELF_NAME" "$1" >&2; exit 2; }

REPO=""
WANT_DISK=1
RECORDS_IN=""
MAXROWS_OVERRIDE=""
PRINT_THRESHOLDS=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help|help)
      sed -n '2,/^# ----*$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    --repo)    [ "$#" -ge 2 ] || die "--repo needs a directory"; REPO="$2"; shift 2 ;;
    --repo=*)  REPO="${1#--repo=}"; shift ;;
    --records) [ "$#" -ge 2 ] || die "--records needs a file"; RECORDS_IN="$2"; shift 2 ;;
    --records=*) RECORDS_IN="${1#--records=}"; shift ;;
    --max-rows) [ "$#" -ge 2 ] || die "--max-rows needs a number"; MAXROWS_OVERRIDE="$2"; shift 2 ;;
    --max-rows=*) MAXROWS_OVERRIDE="${1#--max-rows=}"; shift ;;
    --no-disk) WANT_DISK=0; shift ;;
    --print-thresholds) PRINT_THRESHOLDS=1; shift ;;
    *) die "unknown argument '$1'" ;;
  esac
done

case "${MAXROWS_OVERRIDE:-0}" in
  *[!0-9]*) die "--max-rows must be a non-negative integer" ;;
esac

# ---------------------------------------------------------------------------
# config resolution
# ---------------------------------------------------------------------------
CONFIG_FILE=""
CONFIG_SOURCE=""
CONFIG_LOOKED=""

resolve_config() {
  local configs=""
  if [ -n "${JENGA_TIDY_CONFIG_FILE:-}" ]; then
    CONFIG_LOOKED="$JENGA_TIDY_CONFIG_FILE"
    if [ -f "$JENGA_TIDY_CONFIG_FILE" ]; then
      CONFIG_FILE="$JENGA_TIDY_CONFIG_FILE"; CONFIG_SOURCE="JENGA_TIDY_CONFIG_FILE"; return 0
    fi
    return 1
  fi
  if [ -f "$RESOLVE_ROOT" ]; then
    configs="$(bash "$RESOLVE_ROOT" get configs 2>/dev/null)"
  fi
  if [ -n "$configs" ]; then
    CONFIG_LOOKED="$configs/tidy-config.json"
    if [ -f "$configs/tidy-config.json" ]; then
      CONFIG_FILE="$configs/tidy-config.json"; CONFIG_SOURCE="project instance"; return 0
    fi
  fi
  CONFIG_LOOKED="${CONFIG_LOOKED:+$CONFIG_LOOKED, }$PACKAGE_ROOT/templates/tidy-config.json"
  if [ -f "$PACKAGE_ROOT/templates/tidy-config.json" ]; then
    CONFIG_FILE="$PACKAGE_ROOT/templates/tidy-config.json"; CONFIG_SOURCE="shipped default"; return 0
  fi
  return 1
}

# cfg_num <key> - the key's numeric value, or empty when absent or not a number.
cfg_num() {
  [ -n "$CONFIG_FILE" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r --arg k "$1" 'if (.[$k] | type) == "number" then (.[$k] | tostring) else "" end' \
    "$CONFIG_FILE" 2>/dev/null
}

THRESHOLDS_OK=0
RETENTION_DAYS=""
WT_CEILING=""
BR_CEILING=""
DISK_CEILING_MB=""
MAXROWS=""

if resolve_config; then
  THRESHOLDS_OK=1
  RETENTION_DAYS="$(cfg_num retention_age_days)"
  WT_CEILING="$(cfg_num worktree_count_ceiling)"
  BR_CEILING="$(cfg_num branch_count_ceiling)"
  DISK_CEILING_MB="$(cfg_num disk_ceiling_mb)"
  MAXROWS="$(cfg_num report_max_rows_per_group)"
fi
[ -n "$MAXROWS_OVERRIDE" ] && MAXROWS="$MAXROWS_OVERRIDE"

if [ "$PRINT_THRESHOLDS" -eq 1 ]; then
  if [ "$THRESHOLDS_OK" -eq 0 ]; then
    printf 'config_file=\nconfig_source=none\n'
    printf 'looked_at=%s\n' "$CONFIG_LOOKED"
    exit 0
  fi
  printf 'config_file=%s\nconfig_source=%s\n' "$CONFIG_FILE" "$CONFIG_SOURCE"
  printf 'retention_age_days=%s\n' "$RETENTION_DAYS"
  printf 'worktree_count_ceiling=%s\n' "$WT_CEILING"
  printf 'branch_count_ceiling=%s\n' "$BR_CEILING"
  printf 'disk_ceiling_mb=%s\n' "$DISK_CEILING_MB"
  printf 'report_max_rows_per_group=%s\n' "$MAXROWS"
  exit 0
fi

# ---------------------------------------------------------------------------
# records
# ---------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tidy-report.XXXXXX")" || die "cannot create a scratch directory"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

RECORDS="$WORK/records"
if [ -n "$RECORDS_IN" ]; then
  [ -f "$RECORDS_IN" ] || die "--records '$RECORDS_IN' is not a file"
  grep -v '^#' "$RECORDS_IN" > "$RECORDS" || :
else
  # Positional parameters rather than an array: "$@" with nothing in it is safe under `set -u` on
  # bash 3.2, whereas an empty "${arr[@]}" is an unbound-variable error there.
  set --
  [ -n "$REPO" ] && set -- "$@" --repo "$REPO"
  [ "$WANT_DISK" -eq 0 ] && set -- "$@" --no-disk
  # Status captured from the command itself, NOT from inside an `if ! ...` branch: there, `$?` is
  # the negation's own status (always 0) and the classifier's real exit code is lost.
  bash "$CLASSIFY" "$@" > "$RECORDS"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s: classification failed (classify.sh exited %s); nothing to report.\n' "$SELF_NAME" "$rc" >&2
    exit "$rc"
  fi
fi

REPO_DISPLAY="$REPO"
[ -n "$REPO_DISPLAY" ] || REPO_DISPLAY="$PWD"
TARGET_DISPLAY="$(bash "$TARGET_REF_SCRIPT" --default 2>/dev/null)"
[ -n "$TARGET_DISPLAY" ] || TARGET_DISPLAY="(unresolved)"

CONFIG_DISPLAY="$CONFIG_FILE"
[ -n "$CONFIG_DISPLAY" ] || CONFIG_DISPLAY="(none found; looked at $CONFIG_LOOKED)"

# ---------------------------------------------------------------------------
# render
# ---------------------------------------------------------------------------
awk -F'\t' \
  -v maxrows="${MAXROWS:-}" \
  -v retention="${RETENTION_DAYS:-}" \
  -v wt_ceiling="${WT_CEILING:-}" \
  -v br_ceiling="${BR_CEILING:-}" \
  -v disk_ceiling_mb="${DISK_CEILING_MB:-}" \
  -v thresholds_ok="$THRESHOLDS_OK" \
  -v config_display="$CONFIG_DISPLAY" \
  -v repo_display="$REPO_DISPLAY" \
  -v target_display="$TARGET_DISPLAY" '
function human(b) {
  if (b == "" || b == "-") return "not measured"
  if (b >= 1073741824) return sprintf("%.1f GB", b / 1073741824)
  if (b >= 1048576)    return sprintf("%.1f MB", b / 1048576)
  if (b >= 1024)       return sprintf("%.1f KB", b / 1024)
  return sprintf("%d B", b + 0)
}
function bucket_of(verdict, reason) {
  if (index(reason, "excluded: ") == 1) return "excluded"
  return verdict
}
function label(bucket) {
  if (bucket == "reclaimable") return "RECLAIMABLE - safe to reap automatically (all four conditions hold)"
  if (bucket == "retained")    return "RETAINED - a safety condition failed; each needs an explicit decision"
  return "NOT ELIGIBLE - structurally never reclaimable; never offered, not even on confirmation"
}
function print_bucket(bucket,    p, i, n, shown, row, hidden, any) {
  any = 0
  for (i = 1; i <= pop_n; i++) {
    p = pop_name[i]
    n = gcount[bucket, p]
    if (n == 0) continue
    any = 1
    if (any == 1 && printed_header[bucket] == 0) {
      printf "\n%s\n", label(bucket)
      printf "  %d entr%s, %s\n", bcount[bucket], (bcount[bucket] == 1 ? "y" : "ies"), human(bbytes[bucket])
      printed_header[bucket] = 1
    }
    printf "\n  %s (%d entr%s, %s)\n", p, n, (n == 1 ? "y" : "ies"), human(gbytes[bucket, p])
    shown = 0
    for (row = 1; row <= n; row++) {
      if (maxrows != "" && maxrows + 0 > 0 && shown >= maxrows + 0) break
      printf "    %s\n", gline[bucket, p, row]
      shown++
    }
    hidden = n - shown
    if (hidden > 0)
      printf "    ... and %d more %s %s entr%s NOT SHOWN (report_max_rows_per_group = %s)\n",
        hidden, bucket, p, (hidden == 1 ? "y" : "ies"), maxrows
  }
  return any
}
BEGIN {
  pop_n = 0
  total = 0; worktrees = 0; branches = 0; unmeasured = 0; stale = 0; disk_total = 0
}
NF == 0 { next }
{
  kind = $1; name = $2; population = $4; verdict = $6; bytes = $8; age = $9; reason = $10
  bucket = bucket_of(verdict, reason)

  if (!(population in pop_seen)) { pop_seen[population] = 1; pop_name[++pop_n] = population }

  total++
  if (kind == "worktree") worktrees++; else branches++
  if (bytes == "-" || bytes == "") unmeasured++; else { disk_total += bytes; }
  if (retention != "" && age != "-" && age + 0 >= retention + 0) stale++

  bcount[bucket]++
  gcount[bucket, population]++
  if (bytes != "-" && bytes != "") {
    bbytes[bucket] += bytes
    gbytes[bucket, population] += bytes
  }
  shown_name = name (kind == "branch" ? " (branch, no worktree)" : "")
  gline[bucket, population, gcount[bucket, population]] = \
    sprintf("%-42s %12s  %s", shown_name, human(bytes), reason)
}
END {
  print  "j.tidy - worktree and branch sweep"
  print  "  mode        REPORT ONLY - nothing was changed"
  printf "  repository  %s\n", repo_display
  printf "  target ref  %s (resolved by skills/j-tidy/scripts/target-ref.sh, the single seam)\n", target_display
  printf "  thresholds  %s\n", config_display

  if (total == 0) {
    print  "\nNo worktrees and no branches to assess."
    exit 0
  }

  print_bucket("reclaimable")
  print_bucket("retained")
  print_bucket("excluded")

  print  "\nTOTALS"
  printf "  entries           %d (%d worktree%s, %d branch%s with no worktree)\n",
    total, worktrees, (worktrees == 1 ? "" : "s"), branches, (branches == 1 ? "" : "es")
  printf "  reclaimable       %d entr%s, %s\n",
    bcount["reclaimable"] + 0, (bcount["reclaimable"] + 0 == 1 ? "y" : "ies"), human(bbytes["reclaimable"] + 0)
  printf "  retained          %d entr%s, %s\n",
    bcount["retained"] + 0, (bcount["retained"] + 0 == 1 ? "y" : "ies"), human(bbytes["retained"] + 0)
  printf "  not eligible      %d entr%s, %s\n",
    bcount["excluded"] + 0, (bcount["excluded"] + 0 == 1 ? "y" : "ies"), human(bbytes["excluded"] + 0)
  printf "  disk accounted    %s\n", human(disk_total)
  if (unmeasured > 0)
    printf "  disk NOT measured for %d entr%s (--no-disk was in effect, or the path was unreadable)\n",
      unmeasured, (unmeasured == 1 ? "y" : "ies")

  print  "\nTHRESHOLDS"
  if (thresholds_ok != 1) {
    printf "  !! UNAVAILABLE - no tidy-config.json could be resolved (%s).\n", config_display
    print  "     Ceiling checks were skipped and nothing was truncated. No default was substituted:"
    print  "     a hardcoded threshold would misreport a project that never configured one."
  } else {
    crossed = 0
    if (wt_ceiling != "") {
      if (worktrees > wt_ceiling + 0) { printf "  !! worktrees        %d > ceiling %s   CEILING CROSSED\n", worktrees, wt_ceiling; crossed++ }
      else                             printf "     worktrees        %d (ceiling %s)\n", worktrees, wt_ceiling
    }
    if (br_ceiling != "") {
      if (branches > br_ceiling + 0) { printf "  !! branches         %d > ceiling %s   CEILING CROSSED\n", branches, br_ceiling; crossed++ }
      else                            printf "     branches         %d (ceiling %s)\n", branches, br_ceiling
    }
    if (disk_ceiling_mb != "") {
      if (unmeasured > 0 && disk_total == 0)
        printf "     disk             not measured, so the %s MB ceiling was not checked\n", disk_ceiling_mb
      else if (disk_total > disk_ceiling_mb * 1048576) { printf "  !! disk             %s > ceiling %s MB   CEILING CROSSED\n", human(disk_total), disk_ceiling_mb; crossed++ }
      else                                              printf "     disk             %s (ceiling %s MB)\n", human(disk_total), disk_ceiling_mb
    }
    if (retention != "")
      printf "     stale            %d entr%s older than %s day%s\n",
        stale, (stale == 1 ? "y" : "ies"), retention, (retention + 0 == 1 ? "" : "s")
    if (crossed > 0)
      printf "  => %d ceiling%s crossed. This sweep is overdue.\n", crossed, (crossed == 1 ? "" : "s")
  }

  print  "\nThis was a report. To act on it, run the reap step documented in skills/j-tidy/SKILL.md:"
  print  "reclaimable entries are removed automatically, and every retained entry is offered"
  print  "one at a time for an explicit decision. Nothing above has been deleted."
}
' "$RECORDS"

exit 0
