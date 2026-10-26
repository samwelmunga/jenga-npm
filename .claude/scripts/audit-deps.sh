#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/audit-deps.sh - dependency audit entry point (epic E85, task E85_S01_T02)
#
# The single deterministic entry point for dependency audits. Every other surface (skills, agents, CI
# templates) calls this script and never re-implements audit logic. npm only; --dir reaches the repo
# root, project/app, mcp/* and the trees of services Jenga builds.
#
# USAGE
#   audit-deps.sh [--dir <path>] [--threshold <low|moderate|high|critical>] [--approved] [--ci] [--json]
#   audit-deps.sh -h | --help
#
#   --dir <path>        directory to audit (default: current directory); must hold a package.json
#   --threshold <sev>   severity at or above which the run reports findings; overrides the config's
#                       severity_threshold for this run only
#   --approved          the caller (an agent) has just obtained approval from the user in this session
#   --ci                the caller is a committed CI workflow, which is itself the standing consent
#   --json              print only the JSON object on stdout (diagnostics always go to stderr);
#                       without it, print a short human summary
#
# CONFIG
#   Read from "$(scripts/resolve-root.sh get configs)/audit-config.json" (honours JENGA_PROJECT_ROOT).
#   Keys: config_version (int), mode (off|ask|on, default ask), severity_threshold
#   (low|moderate|high|critical, default high), offline_behavior (warn|fail, default warn),
#   production_only (bool, default false; adds --omit=dev to npm audit).
#   A missing file falls back to those defaults; a present but malformed or invalid one exits 2.
#
# CONSENT (evaluated before any npm invocation, so a refused run makes no network call)
#   mode off   always refused (exit 4), even with --approved or --ci
#   mode ask   refused (exit 4) unless --approved or --ci is given
#   mode on    runs (standing opt-in)
#   consent_basis in the JSON: --ci -> ci-workflow; else --approved -> session-approval; else
#   config-mode-on. When mode is on and a flag is also given, the flag-specific basis wins (ci-workflow
#   outranks session-approval). A refused run prints nothing on stdout.
#
# VERDICT
#   npm audit exits non-zero whenever it finds anything, so its exit code is never used; the JSON is parsed.
#   Severity order: low < moderate < high < critical. "info" counts are reported but never trip the threshold.
#
# EXIT CODES
#   0  clean (nothing at or above the threshold), or audit unavailable under offline_behavior warn
#   1  findings at or above the threshold
#   2  usage or config error (bad flag or value, no package.json in --dir, malformed audit-config.json)
#   3  audit unavailable (no npm, no lockfile, registry unreachable, unparseable output) under
#      offline_behavior fail
#   4  not permitted (mode off, or mode ask without --approved and without --ci)
#
# JSON (--json stdout)
#   status        clean | findings | unavailable | disabled
#   threshold     the effective threshold
#   counts        {info, low, moderate, high, critical, total}
#   findings[]    {name, severity, fix_available, range}, most severe first
#   scanned_dir   absolute path of the audited directory
#   generated_at  UTC ISO 8601 timestamp
#   consent_basis config-mode-on | session-approval | ci-workflow
#   "disabled" belongs to the contract's enum but is not emitted: a refused run (exit 4) must print nothing
#   on stdout, so there is no object to carry it.
#
# The script writes no board, event or rapport file; recording is the job of the caller (E85_S01_T04).
# npm is resolved through PATH only (command -v npm), so tests can put a stub first on PATH.
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions). Uses jq.
# ---------------------------------------------------------------------------

set -u

SELF="audit-deps.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

err() { printf '%s: %s\n' "$SELF" "$*" >&2; }

usage() {
  printf 'Usage: %s [--dir <path>] [--threshold <low|moderate|high|critical>] [--approved] [--ci] [--json]\n' "$SELF"
}

sev_rank() {
  case "$1" in
    info) echo 0 ;;
    low) echo 1 ;;
    moderate) echo 2 ;;
    high) echo 3 ;;
    critical) echo 4 ;;
    *) echo -1 ;;
  esac
}

# ---- argument parsing ------------------------------------------------------
dir="."
threshold_flag=""
approved=0
ci=0
json_out=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dir)
      [ $# -ge 2 ] || { err "--dir needs a value"; exit 2; }
      dir="$2"; shift 2 ;;
    --dir=*) dir="${1#--dir=}"; shift ;;
    --threshold)
      [ $# -ge 2 ] || { err "--threshold needs a value"; exit 2; }
      threshold_flag="$2"; shift 2 ;;
    --threshold=*) threshold_flag="${1#--threshold=}"; shift ;;
    --approved) approved=1; shift ;;
    --ci) ci=1; shift ;;
    --json) json_out=1; shift ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  err "jq is required but was not found on PATH"
  exit 2
fi

if [ -n "$threshold_flag" ]; then
  case "$threshold_flag" in
    low|moderate|high|critical) ;;
    *) err "invalid --threshold '$threshold_flag' (expected low, moderate, high or critical)"; exit 2 ;;
  esac
fi

if [ ! -d "$dir" ]; then
  err "--dir '$dir' is not a directory"
  exit 2
fi
scanned_dir="$(cd "$dir" && pwd)"
if [ ! -f "$scanned_dir/package.json" ]; then
  err "no package.json in $scanned_dir"
  exit 2
fi

# ---- config ----------------------------------------------------------------
mode="ask"
threshold="high"
offline="warn"
prod_only="false"

if ! configs_dir="$(bash "$SCRIPT_DIR/resolve-root.sh" get configs)" || [ -z "$configs_dir" ]; then
  err "could not resolve the project configs directory via resolve-root.sh"
  exit 2
fi
config_file="$configs_dir/audit-config.json"

if [ -f "$config_file" ]; then
  if ! jq -e 'type == "object"' "$config_file" >/dev/null 2>&1; then
    err "malformed config $config_file (not a valid JSON object)"
    exit 2
  fi
  cfg_problem="$(jq -r '
    [
      (if has("mode") and ((.mode | IN("off","ask","on")) | not) then "mode must be off, ask or on" else empty end),
      (if has("severity_threshold") and ((.severity_threshold | IN("low","moderate","high","critical")) | not)
        then "severity_threshold must be low, moderate, high or critical" else empty end),
      (if has("offline_behavior") and ((.offline_behavior | IN("warn","fail")) | not)
        then "offline_behavior must be warn or fail" else empty end),
      (if has("production_only") and ((.production_only | type) != "boolean")
        then "production_only must be a boolean" else empty end),
      (if has("config_version") and ((.config_version | type) != "number")
        then "config_version must be a number" else empty end)
    ] | join("; ")' "$config_file" 2>/dev/null)" || cfg_problem="unreadable"
  if [ -n "$cfg_problem" ]; then
    err "invalid config $config_file: $cfg_problem"
    exit 2
  fi
  mode="$(jq -r '.mode // "ask"' "$config_file")"
  threshold="$(jq -r '.severity_threshold // "high"' "$config_file")"
  offline="$(jq -r '.offline_behavior // "warn"' "$config_file")"
  prod_only="$(jq -r 'if has("production_only") then (.production_only | tostring) else "false" end' "$config_file")"
fi

[ -n "$threshold_flag" ] && threshold="$threshold_flag"

# ---- consent (before any npm invocation) ------------------------------------
consent_basis=""
case "$mode" in
  off)
    err "dependency audits are disabled (mode off in $config_file); not permitted"
    exit 4 ;;
  ask)
    if [ "$ci" -eq 1 ]; then
      consent_basis="ci-workflow"
    elif [ "$approved" -eq 1 ]; then
      consent_basis="session-approval"
    else
      err "dependency audits need consent (mode ask): rerun with --approved after the user agrees, or --ci from a workflow"
      exit 4
    fi ;;
  on)
    if [ "$ci" -eq 1 ]; then
      consent_basis="ci-workflow"
    elif [ "$approved" -eq 1 ]; then
      consent_basis="session-approval"
    else
      consent_basis="config-mode-on"
    fi ;;
esac

# ---- output helpers -----------------------------------------------------------
generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

emit() { # $1 status, $2 counts JSON, $3 findings JSON
  local status="$1" counts="$2" findings="$3" obj
  obj="$(jq -n \
    --arg status "$status" --arg threshold "$threshold" --argjson counts "$counts" \
    --argjson findings "$findings" --arg dir "$scanned_dir" --arg at "$generated_at" \
    --arg basis "$consent_basis" \
    '{status:$status, threshold:$threshold, counts:$counts, findings:$findings,
      scanned_dir:$dir, generated_at:$at, consent_basis:$basis}')"
  if [ "$json_out" -eq 1 ]; then
    printf '%s\n' "$obj"
  else
    printf 'Dependency audit: %s\n' "$status"
    printf '  directory: %s\n' "$scanned_dir"
    printf '  threshold: %s\n' "$threshold"
    printf '%s\n' "$obj" | jq -r '
      "  counts: critical \(.counts.critical), high \(.counts.high), moderate \(.counts.moderate), low \(.counts.low), info \(.counts.info) (total \(.counts.total))",
      (.findings[] | "  - \(.severity): \(.name) (fix available: \(.fix_available))")'
  fi
}

ZERO_COUNTS='{"info":0,"low":0,"moderate":0,"high":0,"critical":0,"total":0}'

unavailable() { # $1 reason
  err "audit unavailable: $1"
  emit "unavailable" "$ZERO_COUNTS" "[]"
  if [ "$offline" = "fail" ]; then exit 3; fi
  exit 0
}

# ---- run the audit ------------------------------------------------------------------
npm_bin="$(command -v npm 2>/dev/null)" || npm_bin=""
[ -n "$npm_bin" ] || unavailable "npm was not found on PATH"

if [ ! -f "$scanned_dir/package-lock.json" ] && [ ! -f "$scanned_dir/npm-shrinkwrap.json" ]; then
  unavailable "no package-lock.json or npm-shrinkwrap.json in $scanned_dir"
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/audit-deps.XXXXXX")" || { err "could not create a temp directory"; exit 2; }
trap 'rm -rf "$tmp"' EXIT

if [ "$prod_only" = "true" ]; then
  (cd "$scanned_dir" && "$npm_bin" audit --json --omit=dev >"$tmp/out.json" 2>"$tmp/err.txt")
else
  (cd "$scanned_dir" && "$npm_bin" audit --json >"$tmp/out.json" 2>"$tmp/err.txt")
fi
# npm audit exits non-zero when it finds vulnerabilities: the exit code is not the verdict.

if ! jq -e 'type == "object"' "$tmp/out.json" >/dev/null 2>&1; then
  unavailable "npm audit produced unparseable output"
fi

if jq -e 'has("error") and (has("vulnerabilities") | not) and (has("metadata") | not)' "$tmp/out.json" >/dev/null 2>&1; then
  reason="$(jq -r '.error | (if type == "object" then (.summary // .code // "unknown error") else tostring end)' "$tmp/out.json" 2>/dev/null)"
  unavailable "npm audit reported an error: ${reason:-unknown error}"
fi

if ! jq -e 'has("vulnerabilities") or ((.metadata // {}) | has("vulnerabilities"))' "$tmp/out.json" >/dev/null 2>&1; then
  unavailable "npm audit output has no vulnerabilities data"
fi

counts="$(jq -c '
  def n: if type == "number" then . else 0 end;
  (.metadata.vulnerabilities // null) as $meta
  | (if $meta != null then $meta
     else ((.vulnerabilities // {}) | [.[] | .severity] | group_by(.) | map({key: .[0], value: length}) | from_entries)
     end) as $c
  | {info: (($c.info // 0) | n), low: (($c.low // 0) | n), moderate: (($c.moderate // 0) | n),
     high: (($c.high // 0) | n), critical: (($c.critical // 0) | n)}
  | . + {total: (.info + .low + .moderate + .high + .critical)}' "$tmp/out.json")" \
  || unavailable "could not normalise npm audit counts"

findings="$(jq -c '
  def rank: {"critical":4,"high":3,"moderate":2,"low":1,"info":0}[.] // -1;
  [(.vulnerabilities // {}) | to_entries[] | .value
   | {name: (.name // "unknown"), severity: (.severity // "unknown"),
      fix_available: ((.fixAvailable // false) != false), range: (.range // "")}]
  | sort_by(-(.severity | rank), .name)' "$tmp/out.json")" \
  || unavailable "could not normalise npm audit findings"

thr_rank="$(sev_rank "$threshold")"
over="$(printf '%s' "$counts" | jq -r --argjson t "$thr_rank" '
  [(if $t <= 1 then .low else 0 end), (if $t <= 2 then .moderate else 0 end),
   (if $t <= 3 then .high else 0 end), .critical] | add')"

if [ "${over:-0}" -gt 0 ]; then
  emit "findings" "$counts" "$findings"
  exit 1
fi
emit "clean" "$counts" "$findings"
exit 0
