#!/usr/bin/env bash
# read-external-refs.sh - read-only lookup of the Jira keys recorded in a board item's `external_refs` (E79_S04_T04).
#
# The counterpart of scripts/link-external-ref.sh (the only WRITER of `external_refs`). This script only reads: it
# prints the `key` of each matching `external_refs` entry of one epic, story or task, one per line, in file order.
# The field contract is templates/SCRUM_BOARD_SCHEMA.md ("External Refs Fields"); the schema lets the developer and
# tester agents read the field and forbids them to write it. This script never writes any file, never takes a lock,
# never calls the network, never evals or interpolates a value into a command.
#
# Usage:
#   read-external-refs.sh <item-id> [--system jira|confluence|bitbucket] [--kind <kind>]
#   read-external-refs.sh -h | --help
#
#   <item-id>   E##, E##_S## or E##_S##_T##. The board directory comes from `scripts/resolve-root.sh get
#               epics|stories|tasks` (never a hardcoded project/ path), so JENGA_PROJECT_ROOT redirects the script
#               to a scratch board. The file is the unique <dir>/<id>_*.md (or <dir>/<id>.md), the same lookup rule
#               link-external-ref.sh uses.
#   --system    which system's entries to print (default jira). Only Jira entries carry a `key`; a confluence or
#               bitbucket entry has a `url`, which this script never prints, so those systems print nothing.
#   --kind      additionally require the entry's `kind` to equal this value (e.g. issue). Default: no filter.
#
# One level only. The script reads exactly the item it is asked about. Walking task -> story -> epic (decision 7 of
# epic E79: a Jira key identifies one imported board item at any level, so several tasks can share one key by
# inheriting it) is the ref resolver's job; the Jenga task id stays the trace key.
#
# What is read. A text-level pass over the frontmatter only, i.e. the lines between the first two `---` lines; the
# body is never read, so a body line that looks like frontmatter (`key: ASD-999`) is never seen. It understands the
# on-disk shape validate-board.sh accepts for external_refs: a block list of mappings (`  - system: jira` opens an
# entry, `    kind: issue` continues it), `external_refs: []`, and no field at all. `external_refs_declined` and
# `external_refs_declined_note` are ordinary top-level keys, not entries, and print nothing. (An item carrying a skip
# marker AND entries still prints its entries: the schema allows linking after a skip.)
#
# What is printed. Only values matching [A-Z][A-Z0-9]+-[0-9]+ (a Jira issue key such as PROJ-123), validated twice
# (once in awk, once in bash) before they reach stdout. The board file is untrusted data:
#   * an entry with a `url` and no `key` is skipped silently (it is not an error);
#   * an entry whose key is malformed, which has both `key` and `url`, which repeats a key, or which has a line that
#     is not `key: value`, is skipped with a notice on stderr. The notice names the entry's position and the expected
#     shape, never the offending value.
#   * an `external_refs` value that is neither empty nor `[]` (an inline list) is skipped with a notice.
#
# stdout: keys only, one per line. stderr: notices and error messages only.
# Exit codes: 0 found, or none found (printing nothing is a normal answer); 2 usage error; 3 the item file is
# missing, ambiguous, or its board directory cannot be resolved (never reported as "no refs"); 4 the file has no
# readable frontmatter (no opening or closing `---`) or repeats `external_refs:`, so it cannot be answered safely.
# On any non-zero exit stdout is empty.
#
# Compatible with macOS bash 3.2 and BSD awk (no associative-array-of-arrays tricks beyond a SUBSEP key, no mapfile,
# no case-modifying expansions); safe under `set -u`; no yq and no jq.

set -u
export LC_ALL=C

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROG="read-external-refs"

fail() { # fail <exit-code> <message>
  printf '%s: %s\n' "$PROG" "$2" >&2
  exit "$1"
}

usage_error() { fail 2 "$1 (see the header of scripts/read-external-refs.sh for usage)"; }

# --- argument parsing --------------------------------------------------------------------------------------
ID=""
SYSTEM="jira"
KIND=""

case "${1:-}" in
  -h|--help)
    sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

[ "$#" -ge 1 ] || usage_error "an item id is required"
case "$1" in
  -*) usage_error "the item id (E##, E##_S## or E##_S##_T##) must be the first argument" ;;
esac
ID="$1"
shift

while [ "$#" -gt 0 ]; do
  case "$1" in
    --system|--kind)
      opt="$1"
      [ "$#" -ge 2 ] || usage_error "$opt needs a value"
      case "$opt" in
        --system) SYSTEM="$2" ;;
        --kind) KIND="$2" ;;
      esac
      shift 2
      ;;
    -*)
      # Name only the flag, never a value.
      flag="${1%%=*}"
      usage_error "unknown option $flag"
      ;;
    *)
      usage_error "unexpected argument (values must follow --system or --kind)"
      ;;
  esac
done

ID_RE='^E[0-9]+(_S[0-9]+(_T[0-9]+)?)?$'
KEY_RE='^[A-Z][A-Z0-9]+-[0-9]+$'
WORD_RE='^[a-z][a-z-]*$'

[[ "$ID" =~ $ID_RE ]] || usage_error "item id must look like E##, E##_S## or E##_S##_T##"
case "$SYSTEM" in
  jira|confluence|bitbucket) ;;
  *) usage_error "unknown --system (expected jira, confluence or bitbucket)" ;;
esac
if [ -n "$KIND" ]; then
  [[ "$KIND" =~ $WORD_RE ]] || usage_error "--kind must be lowercase letters and hyphens (e.g. issue)"
fi

# --- item resolution (same rule as link-external-ref.sh) ----------------------------------------------------
case "$ID" in
  *_T*) KIND_KEY="tasks" ;;
  *_S*) KIND_KEY="stories" ;;
  *) KIND_KEY="epics" ;;
esac

DIR="$(bash "$SELF_DIR/resolve-root.sh" get "$KIND_KEY" 2>/dev/null)" || DIR=""
[ -n "$DIR" ] || fail 3 "cannot look up $ID: the $KIND_KEY board directory could not be resolved"
[ -d "$DIR" ] || fail 3 "no board item $ID: the $KIND_KEY directory does not exist"

BOARD_FILE=""
count=0
for candidate in "$DIR/${ID}"_*.md "$DIR/${ID}.md"; do
  if [ -f "$candidate" ]; then
    BOARD_FILE="$candidate"
    count=$((count + 1))
  fi
done
[ "$count" -ge 1 ] || fail 3 "no board item $ID found in the $KIND_KEY directory"
[ "$count" -eq 1 ] || fail 3 "board item $ID matches more than one file in the $KIND_KEY directory"

# A path that starts with something other than "/" must never be read by awk as an option or a var=value operand.
case "$BOARD_FILE" in
  /*) ;;
  *) BOARD_FILE="./$BOARD_FILE" ;;
esac

# --- the frontmatter read ----------------------------------------------------------------------------------
# awk prints one tagged line per result and nothing else:
#   K <key>      a validated key to print
#   N <text>     a notice for stderr (fixed text plus an entry number, never a file value)
#   E <text>     a structural error (the script then exits 4 and prints no key)
# --system and --kind were validated above against [a-z-]+, so passing them with -v cannot inject anything.
RESULT="$(awk -v want_system="$SYSTEM" -v want_kind="$KIND" '
  function clean(v) {
    sub(/[ \t]+#.*$/, "", v)
    gsub(/^[ \t]+/, "", v)
    gsub(/[ \t]+$/, "", v)
    gsub(/^["\047]+/, "", v)
    gsub(/["\047]+$/, "", v)
    return v
  }
  function trim(v) {
    gsub(/^[ \t]+/, "", v)
    gsub(/[ \t]+$/, "", v)
    return v
  }
  { sub(/\r$/, "") }
  NR == 1 {
    if ($0 !~ /^---[ \t]*$/) { print "E the file has no frontmatter (no opening ---)"; fatal = 1; exit }
    next
  }
  /^---[ \t]*$/ { closed = 1; exit }
  /^external_refs:/ {
    if (seen) { print "E external_refs appears more than once in the frontmatter"; fatal = 1; exit }
    seen = 1
    rest = clean(substr($0, length("external_refs:") + 1))
    if (rest == "") { inrefs = 1 }
    else if (rest == "[]") { inrefs = 0 }
    else { inrefs = 0; print "N external_refs is not a block list or []; skipped" }
    next
  }
  inrefs {
    if ($0 ~ /^[ \t]*$/ || $0 ~ /^[ \t]*#/) next
    if ($0 ~ /^  - /) {
      ent++
      body = substr($0, 5)
    } else if ($0 ~ /^    / && ent > 0) {
      body = $0
    } else {
      inrefs = 0
      next
    }
    idx = index(body, ":")
    if (idx == 0) { bad[ent] = "has a line that is not key: value"; next }
    k = trim(substr(body, 1, idx - 1))
    v = clean(substr(body, idx + 1))
    if ((ent SUBSEP k) in seenk) { bad[ent] = "repeats a key"; next }
    seenk[ent, k] = 1
    if (k == "system") sysv[ent] = v
    else if (k == "kind") kindv[ent] = v
    else if (k == "key") { keyv[ent] = v; haskey[ent] = 1 }
    else if (k == "url") hasurl[ent] = 1
    next
  }
  END {
    if (fatal) exit 4
    if (!closed) { print "E the frontmatter has no closing ---"; exit 4 }
    for (i = 1; i <= ent; i++) {
      if (sysv[i] != want_system) continue
      if (want_kind != "" && kindv[i] != want_kind) continue
      if (i in bad) { print "N entry " i " " bad[i] "; skipped"; continue }
      if (!(i in haskey)) continue
      if (i in hasurl) { print "N entry " i " has both key and url; skipped"; continue }
      if (keyv[i] !~ /^[A-Z][A-Z0-9]+-[0-9]+$/) {
        print "N entry " i " has a key that is not a Jira issue key ([A-Z][A-Z0-9]+-[0-9]+); skipped"
        continue
      }
      print "K " keyv[i]
    }
  }
' "$BOARD_FILE")"
RC=$?

if [ "$RC" -ne 0 ]; then
  msg="the frontmatter of $(basename "$BOARD_FILE") could not be read"
  case "$RESULT" in
    "E "*) msg="$(basename "$BOARD_FILE"): ${RESULT#E }" ;;
  esac
  fail 4 "$msg"
fi

# Notices first (stderr), then keys (stdout), so a structural failure above never leaves partial stdout.
KEYS=""
while IFS= read -r line; do
  case "$line" in
    "N "*) printf '%s: %s: %s\n' "$PROG" "$ID" "${line#N }" >&2 ;;
    "K "*)
      key="${line#K }"
      # Second validation, in bash: only a well-formed Jira key ever reaches stdout.
      if [[ "$key" =~ $KEY_RE ]]; then
        KEYS="${KEYS}${key}"$'\n'
      fi
      ;;
  esac
done <<EOF_RESULT
$RESULT
EOF_RESULT

[ -z "$KEYS" ] || printf '%s' "$KEYS"
exit 0
