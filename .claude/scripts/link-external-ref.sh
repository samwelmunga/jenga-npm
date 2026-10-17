#!/usr/bin/env bash
# link-external-ref.sh - the ONLY sanctioned writer of `external_refs` on a board item (E71_S04_T01).
#
# Validates a Jira issue key, a Confluence page URL or a Bitbucket repo / pull-request URL, entirely offline, and
# records it as an `external_refs` entry in the frontmatter of an epic, story or task file. The field contract is
# in templates/SCRUM_BOARD_SCHEMA.md ("External Refs Fields"); scripts/validate-board.sh enforces it. Nothing here
# calls the network, and nothing requires Atlassian to be configured: the scripts/atlassian-configured.sh gate only
# decides whether a link PROMPT is shown, never whether this script may run.
#
# Usage:
#   link-external-ref.sh <item-id> --system jira|confluence|bitbucket --kind issue|page|repo|pull-request \
#                        (--key <KEY> | --url <URL>)
#   link-external-ref.sh <item-id> --decline        (record a skipped link prompt; see Decline mode below)
#
#   <item-id>   E##, E##_S## or E##_S##_T##. The board directory is read from `scripts/resolve-root.sh get
#               epics|stories|tasks` (never a hardcoded project/ path), so JENGA_PROJECT_ROOT redirects the script
#               to a scratch board. The file is the unique <dir>/<id>_*.md (or <dir>/<id>.md).
#   --system / --kind / value, accepted combinations (anything else is rejected, nothing is written):
#       jira        issue         --key  [A-Z][A-Z0-9]+-[0-9]+                  e.g. PROJ-123
#       confluence  page          --url  https://<site>.atlassian.net/wiki/spaces/<SPACE>/pages/<id>[/<title>]
#       bitbucket   repo          --url  https://bitbucket.org/<workspace>/<repo>
#       bitbucket   pull-request  --url  https://bitbucket.org/<workspace>/<repo>/pull-requests/<number>
#   URLs must be https, host and path only: no credentials (user:token@host), port, query string, fragment,
#   whitespace or quote. The host is lowercased and trailing slashes are stripped before the value is compared or
#   stored, so the same page written two ways is one link. Atlassian Cloud hosts only in v1 (*.atlassian.net for
#   Confluence, bitbucket.org for Bitbucket); Data Center / custom-host URLs are rejected.
#
# Write behavior:
#   * Serialised: the edit runs under `scripts/with-lock.sh <board-file> --`. If the lock cannot be acquired the
#     script exits 4 having written nothing; it never bypasses the lock.
#   * Text-level insertion, not a YAML round trip: every byte of the file outside the external_refs lines is left
#     exactly as it was (key order, comments, quoting, line endings, a missing final newline).
#       - no external_refs field   -> `external_refs:` plus the entry are added as the LAST lines of the
#                                     frontmatter, immediately before the closing `---`
#       - `external_refs: []`      -> the `[]` is dropped and the entry added beneath it
#       - existing block list      -> the entry is appended after the last line of that block
#   * Entry shape (the on-disk form validate-board.sh reads), `linked_on` is today's UTC date:
#         external_refs:
#           - system: jira
#             kind: issue
#             key: PROJ-123
#             linked_on: 2026-10-06
#   * Idempotent: the same system + kind + key-or-url already on the item changes nothing and exits 0 printing
#     "already linked". A different ref is appended.
#   * Self-check: after a write, scripts/validate-board.sh runs on the file. If it fails the original bytes are
#     restored and the script exits 5.
#
# Decline mode (E71_S04_T02): `link-external-ref.sh <item-id> --decline` records that the user was offered the link
# prompt and skipped it. It is the only writer of that skip, which the E71_S05 / E71_S06 prompts check before asking
# again. It adds two top-level frontmatter lines (contract: templates/SCRUM_BOARD_SCHEMA.md, "Declined External Refs
# Fields") as the LAST lines of the frontmatter, immediately before the closing `---`:
#         external_refs_declined: true
#         external_refs_declined_note: "Skipped 2026-10-06: user skipped the external link prompt."
#   * Takes no --system/--kind/--key/--url (any of them with --decline is a usage error, exit 2, nothing written).
#   * Same item resolution, same lock (exit 4 when not acquired), same text-level byte-preserving edit, same
#     validate-board.sh self-check with restore (exit 5). `external_refs` entries on the item are left untouched.
#   * Idempotent: an item already carrying `external_refs_declined: true` and its note changes nothing, exits 0
#     printing "already declined". A skip marker in any other shape (a value other than `true`, a missing note, a note
#     without the marker, a duplicated key) is refused untouched with exit 6.
#   * There is deliberately no option that removes a link or a skip (out of scope for v1).
#
# Secrets: there is no credential option. A rejected value is never echoed back (messages name the expected shape
# only), and a credential-bearing URL is rejected before anything is read or written.
#
# stdout: one line, "linked: ...", "already linked: ...", "declined: ..." or "already declined: ...". stderr: error messages only.
# Exit codes: 0 linked or already linked, 2 invalid arguments or shape, 3 unknown item id, 4 lock not acquired
# (nothing written), 5 the written file failed validate-board.sh (original restored), 6 any other failure
# (unresolvable board directory, ambiguous item file, unrecognised external_refs form, filesystem error).
# The locked child process never exits 1 or 2, because scripts/with-lock.sh reserves those for its own failures.
#
# Structure: parse -> validate_<mode> -> resolve item -> (re-exec under lock) -> apply_<mode>. The `link` and
# `decline` modes each have a validate_ and an apply_ function; the lock wrapper, item resolution and the
# prepare_edit / finish_edit (backup, replace, validate-and-restore) helpers are mode-independent.
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions) and safe under
# `set -u`.

set -u
export LC_ALL=C

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/$(basename "${BASH_SOURCE[0]}")"
PROG="link-external-ref"
ORIG_ARGS=("$@")

TMP_NEW=""
TMP_BACKUP=""
TMP_ERR=""
cleanup() {
  [ -n "$TMP_NEW" ] && rm -f "$TMP_NEW"
  [ -n "$TMP_BACKUP" ] && rm -f "$TMP_BACKUP"
  [ -n "$TMP_ERR" ] && rm -f "$TMP_ERR"
  return 0
}
trap cleanup EXIT

LOCKED=0
fail() { # fail <exit-code> <message>
  local code="$1"
  printf '%s: %s\n' "$PROG" "$2" >&2
  # Inside the locked child, exit 1 and 2 are with-lock.sh's own codes; never let a child failure impersonate them.
  if [ "$LOCKED" -eq 1 ] && { [ "$code" -eq 1 ] || [ "$code" -eq 2 ]; }; then code=6; fi
  exit "$code"
}

usage_error() { fail 2 "$1 (see the header of scripts/link-external-ref.sh for usage)"; }

# --- argument parsing --------------------------------------------------------------------------------------
MODE="link"
ID=""
SYSTEM=""
KIND=""
KEY=""
URL=""
HAVE_KEY=0
HAVE_URL=0
HAVE_SYSTEM=0
HAVE_KIND=0

[ "$#" -ge 1 ] || usage_error "an item id is required"

case "$1" in
  --*) usage_error "the item id (E##, E##_S## or E##_S##_T##) must be the first argument" ;;
esac
ID="$1"
shift

while [ "$#" -gt 0 ]; do
  case "$1" in
    --system|--kind|--key|--url)
      opt="$1"
      [ "$#" -ge 2 ] || usage_error "$opt needs a value"
      case "$opt" in
        --system) SYSTEM="$2"; HAVE_SYSTEM=1 ;;
        --kind) KIND="$2"; HAVE_KIND=1 ;;
        --key) KEY="$2"; HAVE_KEY=1 ;;
        --url) URL="$2"; HAVE_URL=1 ;;
      esac
      shift 2
      ;;
    --decline)
      MODE="decline"
      shift
      ;;
    --__locked)
      # Private: set by the re-exec below once with-lock.sh holds the lock. It skips only the lock wrapper; the
      # child re-runs every validation on the same arguments.
      LOCKED=1
      shift
      ;;
    --*)
      # Name only the flag, never a value.
      flag="${1%%=*}"
      usage_error "unknown option $flag"
      ;;
    *)
      usage_error "unexpected argument (values must follow an option such as --key or --url)"
      ;;
  esac
done

# --- validation (offline, no board access) -----------------------------------------------------------------
ID_RE='^E[0-9]+(_S[0-9]+(_T[0-9]+)?)?$'
JIRA_KEY_RE='^[A-Z][A-Z0-9]+-[0-9]+$'
URL_RE='^https://[a-z0-9][a-z0-9.-]*(/[A-Za-z0-9._~%+-]+)*$'
CONFLUENCE_HOST_RE='^[a-z0-9][a-z0-9-]*\.atlassian\.net$'
CONFLUENCE_PATH_RE='^/wiki/spaces/[A-Za-z0-9~][A-Za-z0-9_.~-]*/pages/[0-9]+(/[A-Za-z0-9._~%+-]+)?$'
BITBUCKET_REPO_RE='^/[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$'
BITBUCKET_PR_RE='^/[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*/pull-requests/[0-9]+$'

FIELD=""   # key | url
VALUE=""   # the normalised value that is compared and stored

validate_id() {
  [[ "$ID" =~ $ID_RE ]] || usage_error "item id must look like E##, E##_S## or E##_S##_T##"
}

# Normalises URL into VALUE, or exits 2 naming the expected shape. $1 = the expected-shape text for this kind.
validate_url_value() {
  local expected="$1" rest authority host path
  case "$URL" in
    https://*) ;;
    *) usage_error "--url must be an https:// URL; expected $expected" ;;
  esac
  rest="${URL#https://}"
  authority="${rest%%/*}"
  case "$authority" in
    *@*) usage_error "--url must not contain credentials (user:token@host); no secret value is accepted" ;;
  esac
  case "$URL" in
    *\?*|*\#*) usage_error "--url must not carry a query string or fragment; expected $expected" ;;
  esac
  host="$(printf '%s' "$authority" | tr 'A-Z' 'a-z')"
  case "$rest" in
    */*) path="/${rest#*/}" ;;
    *) path="" ;;
  esac
  while [ -n "$path" ] && [ "${path%/}" != "$path" ]; do path="${path%/}"; done
  VALUE="https://$host$path"
  [[ "$VALUE" =~ $URL_RE ]] || usage_error "--url must be a plain https URL (host and path only: no port, whitespace or quotes); expected $expected"
  URL_HOST="$host"
  URL_PATH="$path"
}

validate_link() {
  validate_id
  case "$SYSTEM" in
    jira|confluence|bitbucket) ;;
    "") usage_error "--system is required (jira, confluence or bitbucket)" ;;
    *) usage_error "unknown --system (expected jira, confluence or bitbucket)" ;;
  esac
  case "$SYSTEM:$KIND" in
    jira:issue|confluence:page|bitbucket:repo|bitbucket:pull-request) ;;
    jira:*) usage_error "--kind for jira must be: issue" ;;
    confluence:*) usage_error "--kind for confluence must be: page" ;;
    *) usage_error "--kind for bitbucket must be: repo or pull-request" ;;
  esac

  if [ "$SYSTEM" = "jira" ]; then
    [ "$HAVE_URL" -eq 0 ] || usage_error "jira links take --key, not --url"
    [ "$HAVE_KEY" -eq 1 ] || usage_error "--key is required for a jira issue (expected PROJ-123, i.e. [A-Z][A-Z0-9]+-[0-9]+)"
    [[ "$KEY" =~ $JIRA_KEY_RE ]] || usage_error "--key is not a Jira issue key; expected [A-Z][A-Z0-9]+-[0-9]+ (e.g. PROJ-123)"
    FIELD="key"
    VALUE="$KEY"
    return 0
  fi

  [ "$HAVE_KEY" -eq 0 ] || usage_error "$SYSTEM links take --url, not --key"
  [ "$HAVE_URL" -eq 1 ] || usage_error "--url is required for $SYSTEM $KIND"
  FIELD="url"

  case "$SYSTEM:$KIND" in
    confluence:page)
      validate_url_value "https://<site>.atlassian.net/wiki/spaces/<SPACE>/pages/<numeric-id>"
      [[ "$URL_HOST" =~ $CONFLUENCE_HOST_RE ]] || usage_error "--url host must be an Atlassian Cloud site (<site>.atlassian.net); expected https://<site>.atlassian.net/wiki/spaces/<SPACE>/pages/<numeric-id>"
      [[ "$URL_PATH" =~ $CONFLUENCE_PATH_RE ]] || usage_error "--url is not a Confluence page URL; expected https://<site>.atlassian.net/wiki/spaces/<SPACE>/pages/<numeric-id>[/<title>]"
      ;;
    bitbucket:repo)
      validate_url_value "https://bitbucket.org/<workspace>/<repo>"
      [ "$URL_HOST" = "bitbucket.org" ] || usage_error "--url host must be bitbucket.org; expected https://bitbucket.org/<workspace>/<repo>"
      [[ "$URL_PATH" =~ $BITBUCKET_REPO_RE ]] || usage_error "--url is not a Bitbucket repo URL; expected https://bitbucket.org/<workspace>/<repo>"
      case "$URL_PATH" in
        *.git) usage_error "--url must not end in .git; expected https://bitbucket.org/<workspace>/<repo>" ;;
      esac
      ;;
    bitbucket:pull-request)
      validate_url_value "https://bitbucket.org/<workspace>/<repo>/pull-requests/<number>"
      [ "$URL_HOST" = "bitbucket.org" ] || usage_error "--url host must be bitbucket.org; expected https://bitbucket.org/<workspace>/<repo>/pull-requests/<number>"
      [[ "$URL_PATH" =~ $BITBUCKET_PR_RE ]] || usage_error "--url is not a Bitbucket pull-request URL; expected https://bitbucket.org/<workspace>/<repo>/pull-requests/<number>"
      ;;
  esac
}

validate_decline() {
  validate_id
  # Name the offending option only, never a value.
  [ "$HAVE_SYSTEM" -eq 0 ] || usage_error "--decline takes no --system (it records a skip, not a link)"
  [ "$HAVE_KIND" -eq 0 ] || usage_error "--decline takes no --kind (it records a skip, not a link)"
  [ "$HAVE_KEY" -eq 0 ] || usage_error "--decline takes no --key (it records a skip, not a link)"
  [ "$HAVE_URL" -eq 0 ] || usage_error "--decline takes no --url (it records a skip, not a link)"
}

case "$MODE" in
  link) validate_link ;;
  decline) validate_decline ;;
esac

# --- item resolution ---------------------------------------------------------------------------------------
BOARD_FILE=""

resolve_item() {
  local kind_key dir candidate count=0
  case "$ID" in
    *_T*) kind_key="tasks" ;;
    *_S*) kind_key="stories" ;;
    *) kind_key="epics" ;;
  esac
  dir="$(bash "$SELF_DIR/resolve-root.sh" get "$kind_key" 2>/dev/null)" || dir=""
  [ -n "$dir" ] || fail 6 "could not resolve the $kind_key board directory (scripts/resolve-root.sh get $kind_key failed)"
  [ -d "$dir" ] || fail 3 "no board item $ID: the $kind_key directory does not exist"
  for candidate in "$dir/${ID}"_*.md "$dir/${ID}.md"; do
    if [ -f "$candidate" ]; then
      BOARD_FILE="$candidate"
      count=$((count + 1))
    fi
  done
  [ "$count" -ge 1 ] || fail 3 "no board item $ID found in the $kind_key directory; nothing written"
  [ "$count" -eq 1 ] || fail 6 "board item $ID matches more than one file in the $kind_key directory; nothing written"
}

resolve_item

# --- re-exec under the lock --------------------------------------------------------------------------------
if [ "$LOCKED" -eq 0 ]; then
  bash "$SELF_DIR/with-lock.sh" "$BOARD_FILE" -- bash "$SELF" "${ORIG_ARGS[@]}" --__locked
  rc=$?
  case "$rc" in
    0|5|6|3) exit "$rc" ;;
    2) fail 4 "could not acquire the lock on the board item; nothing was written" ;;
    *) fail 6 "the locked write failed unexpectedly (exit $rc); nothing was left half-written" ;;
  esac
fi

# --- locked section ----------------------------------------------------------------------------------------
# plan_link: prints one line, the edit plan for the frontmatter of $1:
#   DUP                 the same ref is already on the item
#   ADD <n>             no external_refs field; insert after line n (the last frontmatter line)
#   APPEND <n>          existing block list; insert the entry after line n (its last line)
#   EMPTY <n>           `external_refs: []` on line n; drop the [] and insert the entry beneath it
#   BAD <reason>        a form this script will not edit
plan_link() {
  awk -v want_system="$SYSTEM" -v want_kind="$KIND" -v want_value="$VALUE" '
    function clean(v) {
      sub(/[ \t]+#.*$/, "", v)
      gsub(/^[ \t]+/, "", v)
      gsub(/[ \t]+$/, "", v)
      gsub(/^["\047]+/, "", v)
      gsub(/["\047]+$/, "", v)
      return v
    }
    NR == 1 {
      if ($0 !~ /^---[ \t]*$/) { bad = "the file has no frontmatter"; stop = 1; exit }
      next
    }
    $0 ~ /^---[ \t]*$/ { closeline = NR; stop = 1; exit }
    $0 ~ /^external_refs:/ {
      if (seen) { bad = "external_refs appears more than once"; stop = 1; exit }
      seen = 1
      refsline = NR
      rest = substr($0, length("external_refs:") + 1)
      rest = clean(rest)
      if (rest == "") { form = "block"; inrefs = 1; lastblock = NR }
      else if (rest == "[]") { form = "empty"; inrefs = 0 }
      else { bad = "external_refs is not a block list or []"; stop = 1; exit }
      next
    }
    inrefs {
      if ($0 ~ /^[ \t]*$/) next
      if ($0 ~ /^  - / || $0 ~ /^[ \t]+[^ \t]/) {
        lastblock = NR
        body = $0
        if ($0 ~ /^  - /) { ent++; body = substr($0, 5) } else { sub(/^[ \t]+/, "", body) }
        if (body ~ /^#/) next
        idx = index(body, ":")
        if (idx == 0) next
        k = substr(body, 1, idx - 1)
        v = clean(substr(body, idx + 1))
        if (k == "system") sysv[ent] = v
        else if (k == "kind") kindv[ent] = v
        else if (k == "key" || k == "url") valv[ent] = v
        next
      }
      inrefs = 0
    }
    END {
      if (bad != "") { print "BAD " bad; exit }
      if (!stop || closeline == 0) { print "BAD the frontmatter has no closing ---"; exit }
      for (i = 1; i <= ent; i++) {
        if (sysv[i] == want_system && kindv[i] == want_kind && valv[i] == want_value) { print "DUP"; exit }
      }
      if (!seen) { print "ADD " (closeline - 1); exit }
      if (form == "block") { print "APPEND " lastblock; exit }
      print "EMPTY " refsline
    }
  ' "$1"
}

# prepare_edit: back up $BOARD_FILE and create $TMP_NEW (a copy next to it) for the caller to overwrite.
prepare_edit() {
  TMP_BACKUP="$(mktemp "${TMPDIR:-/tmp}/${PROG}.backup.XXXXXX")" || fail 6 "could not create a backup file"
  cp -p "$BOARD_FILE" "$TMP_BACKUP" || fail 6 "could not back up $(basename "$BOARD_FILE")"
  TMP_NEW="$(mktemp "${BOARD_FILE}.tmp.XXXXXX")" || fail 6 "could not create a temporary file next to the board item"
  cp -p "$BOARD_FILE" "$TMP_NEW" || fail 6 "could not prepare the temporary file"
}

# finish_edit: replace the board item with $TMP_NEW, then self-check with validate-board.sh; on failure the original
# bytes come back (exit 5).
finish_edit() {
  [ -s "$TMP_NEW" ] || fail 6 "building the edited file failed; nothing written"

  mv "$TMP_NEW" "$BOARD_FILE" || fail 6 "could not replace the board item; nothing written"
  TMP_NEW=""

  # Self-check: the result must pass validate-board.sh, otherwise the original bytes come back.
  TMP_ERR="$(mktemp "${TMPDIR:-/tmp}/${PROG}.err.XXXXXX")" || TMP_ERR=""
  if ! bash "$SELF_DIR/validate-board.sh" "$BOARD_FILE" >/dev/null 2>"${TMP_ERR:-/dev/null}"; then
    cp -p "$TMP_BACKUP" "$BOARD_FILE" 2>/dev/null || cat "$TMP_BACKUP" > "$BOARD_FILE"
    if [ -n "$TMP_ERR" ] && [ -s "$TMP_ERR" ]; then cat "$TMP_ERR" >&2; fi
    fail 5 "the edited $(basename "$BOARD_FILE") failed scripts/validate-board.sh; the original file was restored"
  fi
}

apply_link() {
  local today plan verb line_no entry ref_line
  today="$(date -u +%F)"
  plan="$(plan_link "$BOARD_FILE")" || fail 6 "could not read $(basename "$BOARD_FILE")"
  verb="${plan%% *}"
  line_no=""
  case "$plan" in *" "*) line_no="${plan#* }" ;; esac

  case "$verb" in
    DUP)
      printf 'already linked: %s %s %s on %s; nothing written\n' "$SYSTEM" "$KIND" "$VALUE" "$ID"
      return 0
      ;;
    ADD|APPEND|EMPTY) ;;
    *) fail 6 "cannot edit $(basename "$BOARD_FILE"): ${line_no:-unrecognised external_refs form}; nothing written" ;;
  esac

  entry="$(printf '  - system: %s\n    kind: %s\n    %s: %s\n    linked_on: %s\n' "$SYSTEM" "$KIND" "$FIELD" "$VALUE" "$today")"

  prepare_edit

  case "$verb" in
    ADD)
      { head -n "$line_no" "$BOARD_FILE"; printf 'external_refs:\n%s\n' "$entry"; tail -n +"$((line_no + 1))" "$BOARD_FILE"; } > "$TMP_NEW"
      ;;
    APPEND)
      { head -n "$line_no" "$BOARD_FILE"; printf '%s\n' "$entry"; tail -n +"$((line_no + 1))" "$BOARD_FILE"; } > "$TMP_NEW"
      ;;
    EMPTY)
      ref_line="$(sed -n "${line_no}p" "$BOARD_FILE" | sed 's/[[:space:]]*\[\]//')"
      { head -n "$((line_no - 1))" "$BOARD_FILE"; printf '%s\n%s\n' "$ref_line" "$entry"; tail -n +"$((line_no + 1))" "$BOARD_FILE"; } > "$TMP_NEW"
      ;;
  esac
  finish_edit

  printf 'linked: %s %s %s on %s (%s)\n' "$SYSTEM" "$KIND" "$VALUE" "$ID" "$(basename "$BOARD_FILE")"
}

# plan_decline: prints one line, the edit plan for the frontmatter of $1:
#   DUP                 external_refs_declined: true and its note are already present
#   ADD <n>             neither is present; insert after line n (the last frontmatter line)
#   BAD <reason>        a form this script will not edit
plan_decline() {
  awk '
    function clean(v) {
      sub(/[ \t]+#.*$/, "", v)
      gsub(/^[ \t]+/, "", v)
      gsub(/[ \t]+$/, "", v)
      gsub(/^["\047]+/, "", v)
      gsub(/["\047]+$/, "", v)
      return v
    }
    NR == 1 {
      if ($0 !~ /^---[ \t]*$/) { bad = "the file has no frontmatter"; stop = 1; exit }
      next
    }
    $0 ~ /^---[ \t]*$/ { closeline = NR; stop = 1; exit }
    $0 ~ /^external_refs_declined:/ {
      if (dseen) { bad = "external_refs_declined appears more than once"; stop = 1; exit }
      dseen = 1
      dval = clean(substr($0, length("external_refs_declined:") + 1))
      next
    }
    $0 ~ /^external_refs_declined_note:/ {
      if (nseen) { bad = "external_refs_declined_note appears more than once"; stop = 1; exit }
      nseen = 1
      next
    }
    END {
      if (bad != "") { print "BAD " bad; exit }
      if (!stop || closeline == 0) { print "BAD the frontmatter has no closing ---"; exit }
      if (dseen && dval != "true") { print "BAD external_refs_declined is not true"; exit }
      if (dseen && !nseen) { print "BAD external_refs_declined has no external_refs_declined_note"; exit }
      if (nseen && !dseen) { print "BAD external_refs_declined_note has no external_refs_declined marker"; exit }
      if (dseen) { print "DUP"; exit }
      print "ADD " (closeline - 1)
    }
  ' "$1"
}

apply_decline() {
  local today plan verb line_no note
  today="$(date -u +%F)"
  plan="$(plan_decline "$BOARD_FILE")" || fail 6 "could not read $(basename "$BOARD_FILE")"
  verb="${plan%% *}"
  line_no=""
  case "$plan" in *" "*) line_no="${plan#* }" ;; esac

  case "$verb" in
    DUP)
      printf 'already declined: %s; nothing written\n' "$ID"
      return 0
      ;;
    ADD) ;;
    *) fail 6 "cannot edit $(basename "$BOARD_FILE"): ${line_no:-unrecognised skip marker form}; nothing written" ;;
  esac

  note="Skipped $today: user skipped the external link prompt."
  prepare_edit
  { head -n "$line_no" "$BOARD_FILE"; printf 'external_refs_declined: true\nexternal_refs_declined_note: "%s"\n' "$note"; tail -n +"$((line_no + 1))" "$BOARD_FILE"; } > "$TMP_NEW"
  finish_edit

  printf 'declined: %s (%s)\n' "$ID" "$(basename "$BOARD_FILE")"
}

case "$MODE" in
  link) apply_link ;;
  decline) apply_decline ;;
esac
exit 0
