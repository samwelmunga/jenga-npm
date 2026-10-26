#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/audit-record.sh - durable trace of dependency audits (epic E85, task E85_S01_T04)
#
# The recording half of the audit feature. scripts/audit-deps.sh stays side-effect free; this script
# appends the events and writes the rapports. Paths come from scripts/resolve-root.sh (honours
# JENGA_PROJECT_ROOT) and every event goes through scripts/events-append.sh, never a direct write.
#
# USAGE
#   audit-record.sh consent --dir <path> [--session-id <id>] [--agent <name>]
#   audit-record.sh result  --file <audit.json> [--session-id <id>] [--agent <name>]
#   audit-record.sh -h | --help
#
#   consent   record that the user approved an audit in-session; an agent calls it only AFTER that approval
#   result    record the JSON printed by `audit-deps.sh --json` (read from --file)
#   --session-id defaults to $JENGA_SESSION_ID, else "". --agent defaults to "audit-record".
#
# EVENT CONTRACT (stable: the dashboard Security tab, E85_S03_T01, reads audit_result)
#   audit_consent  {"event":"audit_consent","agent":str,"tool_type":"vulnerability","approved_by":"user",
#                   "scanned_dir":str,"session_id":str,"date":ISO 8601 UTC str}
#                  scanned_dir is the absolute path when --dir exists, else the value as given.
#   audit_result   {"event":"audit_result","agent":str,"status":"clean|findings|unavailable|disabled",
#                   "threshold":str|null,
#                   "counts":{"low":int,"moderate":int,"high":int,"critical":int,"total":int},
#                   "scanned_dir":str|null,"consent_basis":str|null,"rapport":str|null,
#                   "session_id":str,"date":ISO 8601 UTC str}
#                  counts ALWAYS carries all five keys (a missing key becomes 0; a missing total becomes
#                  the sum of info, low, moderate, high and critical). rapport is the absolute path of the
#                  rapport written for this result, else null. Findings detail stays out of the event.
#
# RAPPORT (result with status "findings" only)
#   A problem rapport with "Type: security_concern", written to the rapports_problems directory as
#   audit-<scanned-dir-slug>-<YYYYMMDD>.md and listing every finding (name, severity, fix availability,
#   range). The date is the one in the result's generated_at, else today (UTC). A second result for the
#   same directory and date overwrites that file, so there is never a numbered duplicate. Status clean,
#   unavailable and disabled write NO rapport but still append the event, so "audit could not run" is
#   never silently equal to "clean".
#
# EXIT CODES
#   0  recorded
#   2  usage error, or the result file is unreadable / not a JSON object / has an unknown status
#   3  could not resolve a path or write the rapport or the event
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions). Uses jq.
# ---------------------------------------------------------------------------

set -u

SELF="audit-record.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

err() { printf '%s: %s\n' "$SELF" "$*" >&2; }

usage() {
  printf 'Usage: %s consent --dir <path> [--session-id <id>] [--agent <name>]\n' "$SELF"
  printf '       %s result --file <audit.json> [--session-id <id>] [--agent <name>]\n' "$SELF"
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

append_event() {
  "$SCRIPT_DIR/events-append.sh" "$1" || { err "could not append the event"; exit 3; }
}

[ $# -ge 1 ] || { usage >&2; exit 2; }
case "$1" in
  -h|--help) usage; exit 0 ;;
  consent|result) MODE="$1"; shift ;;
  *) err "unknown subcommand: $1"; usage >&2; exit 2 ;;
esac

DIR=""; FILE=""; SESSION_ID="${JENGA_SESSION_ID:-}"; AGENT="audit-record"
while [ $# -gt 0 ]; do
  case "$1" in
    --dir|--file|--session-id|--agent)
      [ $# -ge 2 ] || { err "$1 needs a value"; exit 2; }
      case "$1" in
        --dir) DIR="$2" ;;
        --file) FILE="$2" ;;
        --session-id) SESSION_ID="$2" ;;
        --agent) AGENT="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { err "jq is required"; exit 3; }

if [ "$MODE" = consent ]; then
  [ -n "$DIR" ] || { err "consent needs --dir"; exit 2; }
  if [ -d "$DIR" ]; then DIR="$(cd "$DIR" && pwd)"; fi
  rec="$(jq -n -c --arg agent "$AGENT" --arg dir "$DIR" --arg sid "$SESSION_ID" --arg date "$(now_utc)" \
    '{event:"audit_consent", agent:$agent, tool_type:"vulnerability", approved_by:"user",
      scanned_dir:$dir, session_id:$sid, date:$date}')" || { err "could not build the event"; exit 3; }
  append_event "$rec"
  exit 0
fi

# ---- result ----
[ -n "$FILE" ] || { err "result needs --file"; exit 2; }
[ -f "$FILE" ] && [ -r "$FILE" ] || { err "cannot read result file: $FILE"; exit 2; }
jq -e 'type == "object"' "$FILE" >/dev/null 2>&1 || { err "result file is not a JSON object: $FILE"; exit 2; }
STATUS="$(jq -r '.status // ""' "$FILE")"
case "$STATUS" in
  clean|findings|unavailable|disabled) ;;
  *) err "result file has an unknown status: '$STATUS'"; exit 2 ;;
esac

RAPPORT=""
if [ "$STATUS" = findings ]; then
  RAPPORTS_DIR="$("$SCRIPT_DIR/resolve-root.sh" get rapports_problems 2>/dev/null)" \
    && [ -n "$RAPPORTS_DIR" ] || { err "cannot resolve the rapports_problems directory"; exit 3; }
  SCANNED="$(jq -r '.scanned_dir // "unknown"' "$FILE")"
  SLUG="$(printf '%s' "$SCANNED" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed -e 's/^-*//' -e 's/-*$//')"
  [ -n "$SLUG" ] || SLUG="unknown"
  SLUG="$(printf '%s' "$SLUG" | awk '{ print (length($0) > 80) ? substr($0, length($0) - 79) : $0 }' | sed 's/^-*//')"
  DAY="$(jq -r '.generated_at // "" | .[0:10]' "$FILE")"
  case "$DAY" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) DAY="$(date -u +%Y-%m-%d)" ;;
  esac
  RAPPORT="$RAPPORTS_DIR/audit-$SLUG-$(printf '%s' "$DAY" | tr -d '-').md"
  mkdir -p "$RAPPORTS_DIR" || { err "cannot create $RAPPORTS_DIR"; exit 3; }
  TMP="$RAPPORT.tmp.$$"
  jq -r --arg agent "$AGENT" --arg sid "$SESSION_ID" --arg day "$DAY" --arg now "$(now_utc)" '
    def cell: tostring | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|");
    (.findings | if type == "array" then . else [] end) as $f
    | (.counts // {}) as $c
    | "# Rapport: Dependency audit findings in \(.scanned_dir // "unknown")\n\n"
    + "**Date:** \($day) (UTC)\n**Agent:** \($agent)\n**Related Epic:** N/A\n**Related Story:** N/A\n**Related Task:** N/A\n"
    + "**Type:** `security_concern`\n\n---\n\n## Sender\n```json\n"
    + ({sender: {agent: $agent, session_id: $sid, task_id: "", story_id: "", epic_id: "", date: $now, paths: [], worktree: ""}} | tojson)
    + "\n```\n\n---\n\n## Summary\nThe dependency audit of `\(.scanned_dir // "unknown")` found \($f | length) finding(s) at or above the \(.threshold // "configured") threshold.\n\n---\n\n"
    + "## Context\nAudit generated at \(.generated_at // "an unknown time"), consent basis \(.consent_basis // "unknown"). "
    + "Counts: low \($c.low // 0), moderate \($c.moderate // 0), high \($c.high // 0), critical \($c.critical // 0), total \($c.total // 0).\n\n---\n\n"
    + "## Problem Description\nEvery finding below is a vulnerable dependency reported by the npm audit of this directory.\n\n---\n\n"
    + "## Findings\n\n| # | Finding | Severity | Fix available | Range |\n|---|---------|----------|---------------|-------|\n"
    + (if ($f | length) == 0 then "| 1 | (no per-package detail in the audit result) | | | |\n"
       else ([range(0; $f | length) as $i | $f[$i]
         | "| \($i + 1) | \(.name // "unknown" | cell) | \(.severity // "unknown" | cell) | \(.fix_available // "unknown" | cell) | \(.range // "" | cell) |"] | join("\n")) + "\n" end)
    + "\n---\n\n## Impact\nVulnerable dependencies are present in the audited directory until they are upgraded or accepted.\n\n---\n\n"
    + "## Suggested Next Steps\nUpgrade the packages marked as having a fix available, review the rest, then re-run the audit.\n"
  ' "$FILE" > "$TMP" && mv -f "$TMP" "$RAPPORT" || { rm -f "$TMP"; err "could not write the rapport"; exit 3; }
fi

rec="$(jq -c --arg agent "$AGENT" --arg sid "$SESSION_ID" --arg date "$(now_utc)" --arg rapport "$RAPPORT" '
  (.counts // {}) as $c
  | ([$c.info, $c.low, $c.moderate, $c.high, $c.critical] | map(. // 0) | add) as $sum
  | {event: "audit_result", agent: $agent, status: .status, threshold: (.threshold // null),
     counts: {low: ($c.low // 0), moderate: ($c.moderate // 0), high: ($c.high // 0),
              critical: ($c.critical // 0), total: ($c.total // $sum)},
     scanned_dir: (.scanned_dir // null), consent_basis: (.consent_basis // null),
     rapport: (if $rapport == "" then null else $rapport end), session_id: $sid, date: $date}
' "$FILE")" || { err "could not build the event"; exit 3; }
append_event "$rec"
exit 0
