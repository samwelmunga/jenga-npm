#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-workflow-capture/scripts/resolve-source.sh - turn a session reference into one readable source
# (epic E103, task E103_S02_T01)
#
# j.workflow-capture reads a finished process from somewhere. This script takes what the user gave - nothing
# (the current session), a session id, a transcript .jsonl path, a file, or pasted text - and resolves it to ONE
# local file plus the recording provenance that file carries (source, source_ref; see recording-format.sh's
# PROVENANCE section). It never guesses: a reference it cannot resolve exits non-zero naming what it tried.
#
# USAGE
#   resolve-source.sh resolve [options]                 the current session
#   resolve-source.sh resolve [options] -               pasted text, read from stdin
#   resolve-source.sh resolve [options] <reference>     a session id, a .jsonl path, a file, or a best-effort form
#   resolve-source.sh host [options]                    is there a Claude Code transcript directory on this host?
#   resolve-source.sh list [options]                    this project's session transcripts (JSON array)
#   resolve-source.sh -h | --help                       print this usage, exit 0
#
#   --projects-dir <dir>  the Claude Code projects directory (also --projects-dir=<dir>). Precedence, exactly as
#                         scripts/task-usage.sh: the option, then JENGA_PROJECTS_DIR, then ~/.claude/projects.
#   --project-dir <path>  list only: the project whose sessions to list (passed to task-usage.sh unchanged).
#   --out-dir <dir>       where pasted text and pasted files are written (also --out-dir=<dir>). Default:
#                         JENGA_CAPTURE_OUT_DIR, else a fresh private directory from mktemp -d.
#   --                    end of options (for a reference that starts with "-").
#
# REFERENCE FORMS (resolve), tried in this order
#   (none)                  the current session: its id is the first set of JENGA_CAPTURE_SESSION_ID (a test and
#                           override seam), CLAUDE_CODE_SESSION_ID (the harness's own id), JENGA_SESSION_ID; then
#                           looked up like a session id.                          form "current"
#   -                       pasted text on stdin, normalised into a file.         form "pasted-text"
#   an existing path        "~/" is expanded. A name ending in .jsonl is a session transcript (form
#                           "transcript-path"); any other regular file is pasted content, normalised into a copy
#                           (form "pasted-file"). A directory exits 5.
#   a claude.ai/code URL    best effort only, exit 4 (a script reads local files only).
#   a local_... id          a desktop session id: best effort only, exit 4.
#   any other URL           exit 2: a link to instructions is the external source (E103_S03), not a session.
#   a session UUID          looked up as <projects-dir>/*/<uuid>.jsonl.            form "session-id"
#   path-shaped, missing    contains "/" or ends in .jsonl, .txt or .md: exit 5 (not found).
#   anything else           exit 2 (not a recognised reference; paste the text with "-" instead).
#
# SESSION LOOKUP
#   The layout is scripts/task-usage.sh's (its DISCOVERY section): a main session transcript is
#   <projects-dir>/<slug>/<session>.jsonl. The id is looked up with one glob over EVERY slug directory, so a session
#   from this project, from one of its worktrees or from another project is found alike (a process is often
#   repeated across projects). Exactly one match is used. None, or more than one, exits 5 naming what was searched
#   or found; nothing is picked. task-usage.sh --list-transcripts is not used for the lookup: it maps every
#   subagent transcript of this project (53 s for 1820 transcripts, measured 2026-11-20) and searches a subset of
#   the same glob. It is reused for "list", where enumerating is the point.
#
# VALIDATION
#   A transcript (current, session-id, transcript-path) must be a regular, readable, non-empty file whose first
#   non-blank line is a JSON object; otherwise exit 5 (missing, unreadable, empty) or 8 (not a transcript). The
#   deeper layout check belongs to the step extractor (E103_S02_T02). A transcript is never copied or modified.
#   Pasted text or a pasted file must hold no NUL byte (exit 8) and at least one non-blank character (exit 5). It
#   is normalised - every carriage return removed, a final newline ensured - into <out-dir>/pasted-<sha12>.txt,
#   where <sha12> is the first 12 hex characters of the normalised content's SHA-256. Files are created mode 600.
#   source_ref is checked with the recorder's own rec_source_ref_problem; a refused value exits 2.
#
# OUTPUT (resolve, exit 0): ONE line of JSON on stdout, nothing else:
#   {"form": "current"|"session-id"|"transcript-path"|"pasted-text"|"pasted-file",
#    "source": "session-transcript"|"pasted",
#    "source_ref": <the session id; the absolute .jsonl or file path; "sha256:<sha12>" for pasted text>,
#    "path": <absolute path of the file to read>,
#    "session_id": <the session id, or null>}
#   source and source_ref are what recording-file.sh create --source/--source-ref takes. The content of the source
#   is never printed.
# OUTPUT (host, exit 0): "claude-transcripts<TAB><projects-dir>".
# OUTPUT (list, exit 0): a JSON array, one {session_id, path, slug_dir} per session transcript of the project, from
#   task-usage.sh --list-transcripts (can take a while on a project with many subagent transcripts).
# Every message goes to stderr; on a non-zero exit stdout is empty.
#
# EXIT CODES
#   0 resolved / available
#   2 usage error, an unrecognised reference, a non-session URL, or a refused source_ref
#   3 environment: jq missing, or task-usage.sh missing or failing (list)
#   4 best-effort form (claude.ai/code URL, local_... id): export it to a file with a host tool and resolve that
#     path, or paste the text
#   5 not found, unreadable, ambiguous (several transcripts for one id), empty, or a directory
#   6 no Claude Code transcript directory: on this host only pasted text or a file is supported
#   7 the current session id could not be resolved (unset or malformed)
#   8 content rejected: not a session transcript, or not plain text
#
# Reads transcripts read-only and sends nothing anywhere. Writes only under --out-dir, and never touches the
# recorder's pointer. Transcript text is data: nothing in it is executed. bash 3.2 compatible, safe under set -u.
# ---------------------------------------------------------------------------
set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ME="resolve-source.sh"

usage() { sed -n '3,/^# ----*$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }
die() { local code="$1"; shift; printf '%s: %s\n' "$ME" "$*" >&2; exit "$code"; }

UUID_RE='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
KEY_RE='^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'
CLOUD_RE='^(https?://)?([A-Za-z0-9-]+\.)*claude\.ai/code([/?#]|$)'
LOCAL_RE='^local_[A-Za-z0-9_-]+$'
URL_RE='^[A-Za-z][A-Za-z0-9+.-]*://'

# --- arguments ----------------------------------------------------------------------------------------------------
CMD=""
REF=""
REF_SET=0
PROJECTS_DIR_OPT=""
PROJECTS_DIR_OPT_SET=0
PROJECT_DIR_OPT=""
OUT_DIR_OPT=""
ENDOPTS=0

take_positional() {
  if [ -z "$CMD" ]; then CMD="$1"
  elif [ "$REF_SET" -eq 0 ]; then REF="$1"; REF_SET=1
  else die 2 "unexpected argument: $1 (one reference at most)"
  fi
}

while [ $# -gt 0 ]; do
  if [ "$ENDOPTS" -eq 1 ]; then take_positional "$1"; shift; continue; fi
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --) ENDOPTS=1 ;;
    --projects-dir) [ $# -ge 2 ] || die 2 "--projects-dir requires a value"; PROJECTS_DIR_OPT="$2"; PROJECTS_DIR_OPT_SET=1; shift ;;
    --projects-dir=*) PROJECTS_DIR_OPT="${1#--projects-dir=}"; PROJECTS_DIR_OPT_SET=1 ;;
    --project-dir) [ $# -ge 2 ] || die 2 "--project-dir requires a value"; PROJECT_DIR_OPT="$2"; shift ;;
    --project-dir=*) PROJECT_DIR_OPT="${1#--project-dir=}" ;;
    --out-dir) [ $# -ge 2 ] || die 2 "--out-dir requires a value"; OUT_DIR_OPT="$2"; shift ;;
    --out-dir=*) OUT_DIR_OPT="${1#--out-dir=}" ;;
    -) take_positional "$1" ;;
    -*) die 2 "unknown option: $1 (see --help)" ;;
    *) take_positional "$1" ;;
  esac
  shift
done

case "$CMD" in
  resolve|host|list) ;;
  "") die 2 "no sub-command given (expected resolve, host or list; see --help)" ;;
  *) die 2 "unknown sub-command: $CMD (expected resolve, host or list)" ;;
esac
[ "$CMD" = "resolve" ] || [ "$REF_SET" -eq 0 ] || die 2 "$CMD takes no reference"
[ "$CMD" = "list" ] || [ -z "$PROJECT_DIR_OPT" ] || die 2 "--project-dir is only valid with list"
[ "$PROJECTS_DIR_OPT_SET" -eq 0 ] || [ -n "$PROJECTS_DIR_OPT" ] || die 2 "--projects-dir must not be empty"

command -v jq >/dev/null 2>&1 || die 3 "jq is required but was not found on PATH"

if [ "$PROJECTS_DIR_OPT_SET" -eq 1 ]; then
  PROJECTS_DIR="$PROJECTS_DIR_OPT"
elif [ -n "${JENGA_PROJECTS_DIR:-}" ]; then
  PROJECTS_DIR="$JENGA_PROJECTS_DIR"
else
  PROJECTS_DIR="${HOME:-}/.claude/projects"
fi

# --- helpers ------------------------------------------------------------------------------------------------------

# Exits 6 unless the Claude Code projects directory exists.
require_transcript_dir() {
  [ -d "$PROJECTS_DIR" ] && return 0
  die 6 "no Claude Code transcript directory at $PROJECTS_DIR: on this host only pasted text or a file is supported (resolve - with the text on stdin, or resolve <file>)"
}

# Prints the absolute, symlink-resolved directory form of an existing file's path.
abs_path() {
  local d b
  d="$(cd "$(dirname -- "$1")" && pwd -P)" || return 1
  b="$(basename -- "$1")"
  printf '%s/%s' "$d" "$b"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | cut -c1-64
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 < "$1" | cut -c1-64
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 < "$1" | sed 's/^.*= *//' | cut -c1-64
  else return 1
  fi
}

# The recorder's own source_ref rule, sourced rather than restated.
check_source_ref() {
  local fmt="$SCRIPT_DIR/../../j-workflow-recorder/scripts/recording-format.sh" problem
  [ -f "$fmt" ] || die 3 "missing $fmt (the recording format contract)"
  # shellcheck source=../../j-workflow-recorder/scripts/recording-format.sh
  . "$fmt"
  if problem="$(rec_source_ref_problem "$1")"; then
    die 2 "this reference cannot be recorded as a source_ref: $problem"
  fi
}

emit() {
  # $1 form, $2 source, $3 source_ref, $4 path, $5 session id ("" for none)
  check_source_ref "$3"
  jq -cn --arg form "$1" --arg source "$2" --arg ref "$3" --arg path "$4" --arg sid "$5" \
    '{form: $form, source: $source, source_ref: $ref, path: $path, session_id: (if $sid == "" then null else $sid end)}'
  exit 0
}

# Validates a transcript file; exits 5 or 8 with a message, returns 0 when it is usable. $2 says how it was found.
validate_transcript() {
  local f="$1" how="$2" first
  [ -e "$f" ] || die 5 "transcript not found: $f ($how)"
  [ -d "$f" ] && die 5 "$f is a directory, not a transcript file ($how)"
  [ -f "$f" ] || die 5 "$f is not a regular file ($how)"
  [ -r "$f" ] || die 5 "transcript found but not readable: $f ($how)"
  [ -s "$f" ] || die 5 "transcript is empty: $f ($how)"
  first="$(awk 'NF { print; exit }' "$f")"
  if [ -z "$first" ] || ! printf '%s\n' "$first" | jq -e 'type == "object"' >/dev/null 2>&1; then
    die 8 "$f is not a Claude Code session transcript: its first non-blank line is not a JSON object ($how)"
  fi
  return 0
}

# Looks a session id up under every slug directory; resolves it or exits 5. $2 is the form, $3 how the id was given.
lookup_session() {
  local id="$1" form="$2" how="$3" f matches="" count=0 dirs=0 d
  require_transcript_dir
  for d in "$PROJECTS_DIR"/*/; do [ -d "$d" ] && dirs=$((dirs + 1)); done
  for f in "$PROJECTS_DIR"/*/"$id".jsonl; do
    [ -e "$f" ] || continue
    matches="${matches}${f}
"
    count=$((count + 1))
  done
  if [ "$count" -eq 0 ]; then
    die 5 "no transcript for session $id ($how): searched $PROJECTS_DIR/*/$id.jsonl across $dirs project directories. Give the transcript's .jsonl path, or paste the text."
  fi
  if [ "$count" -gt 1 ]; then
    die 5 "session $id has $count transcripts, none is picked: $(printf '%s' "$matches" | tr '\n' ' ')- give the .jsonl path of the one you mean."
  fi
  f="${matches%
}"
  validate_transcript "$f" "$how"
  emit "$form" "session-transcript" "$id" "$(abs_path "$f")" "$id"
}

# Resolves the output directory for pasted content, creating it when needed.
out_dir() {
  local d="${OUT_DIR_OPT:-${JENGA_CAPTURE_OUT_DIR:-}}"
  if [ -z "$d" ]; then
    d="$(mktemp -d "${TMPDIR:-/tmp}/jenga-capture.XXXXXX")" || die 3 "could not create a private directory for the pasted content"
  else
    mkdir -p -- "$d" 2>/dev/null || die 3 "could not create the output directory: $d"
  fi
  [ -d "$d" ] && [ -w "$d" ] || die 3 "the output directory is not a writable directory: $d"
  (cd "$d" && pwd -P)
}

# Normalises pasted content from file $1 into the output directory; prints the absolute result path, or exits.
# $2 says what the content was (for messages).
normalise_paste() {
  local src="$1" what="$2" dir tmp digest final
  if [ "$(env LC_ALL=C tr -d '\000' < "$src" | wc -c)" -ne "$(wc -c < "$src")" ]; then
    die 8 "$what holds NUL bytes: it is not plain text (paste the text, or give a text file)"
  fi
  dir="$(out_dir)" || exit $?
  tmp="$dir/.pasted.$$"
  env LC_ALL=C tr -d '\r' < "$src" > "$tmp" || { rm -f -- "$tmp"; die 3 "could not write $tmp"; }
  if ! env LC_ALL=C grep -q '[^[:space:]]' "$tmp"; then
    rm -f -- "$tmp"
    die 5 "$what is empty: there is nothing to capture"
  fi
  if [ "$(tail -c 1 "$tmp" | wc -l | tr -d ' ')" -eq 0 ]; then printf '\n' >> "$tmp"; fi
  digest="$(sha256_of "$tmp")" || { rm -f -- "$tmp"; die 3 "no SHA-256 tool found (sha256sum, shasum or openssl)"; }
  digest="$(printf '%s' "$digest" | cut -c1-12)"
  final="$dir/pasted-$digest.txt"
  mv -f -- "$tmp" "$final" || { rm -f -- "$tmp"; die 3 "could not write $final"; }
  printf '%s' "$final"
}

# --- sub-commands ---------------------------------------------------------------------------------------------------

cmd_host() {
  require_transcript_dir
  printf 'claude-transcripts\t%s\n' "$(cd "$PROJECTS_DIR" && pwd -P)"
}

cmd_list() {
  local root tu out rc
  require_transcript_dir
  # shellcheck source=/dev/null
  if [ -f "$SCRIPT_DIR/../../index/scripts/package-root.sh" ]; then . "$SCRIPT_DIR/../../index/scripts/package-root.sh"; else jenga_package_root() { (cd "$1/../../.." && pwd); }; fi
  root="$(jenga_package_root "$SCRIPT_DIR" 2>/dev/null)"
  tu="$root/scripts/task-usage.sh"
  [ -n "$root" ] && [ -f "$tu" ] || die 3 "missing scripts/task-usage.sh (the transcript discovery this sub-command reuses)"
  if [ -n "$PROJECT_DIR_OPT" ]; then
    out="$(bash "$tu" --list-transcripts --projects-dir "$PROJECTS_DIR" --project-dir "$PROJECT_DIR_OPT")"; rc=$?
  else
    out="$(bash "$tu" --list-transcripts --projects-dir "$PROJECTS_DIR")"; rc=$?
  fi
  [ "$rc" -eq 0 ] || die 3 "task-usage.sh --list-transcripts failed (exit $rc); its message is above"
  printf '%s\n' "$out" | jq -c '[.[] | select(.kind == "session") | {session_id, path, slug_dir}]' \
    || die 3 "task-usage.sh --list-transcripts printed something that is not its documented JSON array"
}

cmd_resolve_current() {
  local key="" var
  require_transcript_dir
  for var in JENGA_CAPTURE_SESSION_ID CLAUDE_CODE_SESSION_ID JENGA_SESSION_ID; do
    eval "key=\"\${$var:-}\""
    [ -n "$key" ] && break
  done
  if [ -z "$key" ]; then
    die 7 "could not resolve the current session id (JENGA_CAPTURE_SESSION_ID, CLAUDE_CODE_SESSION_ID and JENGA_SESSION_ID are all unset): give the session UUID or its transcript .jsonl path, or paste the text"
  fi
  [[ $key =~ $KEY_RE ]] || die 7 "the current session id from $var is malformed (1 to 128 letters, digits, dot, colon, underscore or hyphen): give the session UUID or its transcript .jsonl path instead"
  lookup_session "$key" "current" "the current session, id from $var"
}

cmd_resolve_paste() {
  local dir tmp final rc
  [ -t 0 ] && die 2 "resolve - reads the pasted text from stdin, and stdin is a terminal: pipe the text in"
  dir="$(out_dir)" || exit $?
  tmp="$dir/.stdin.$$"
  cat > "$tmp" || { rm -f -- "$tmp"; die 3 "could not read stdin into $tmp"; }
  OUT_DIR_OPT="$dir"
  final="$(normalise_paste "$tmp" "the pasted text")"; rc=$?
  rm -f -- "$tmp"
  [ "$rc" -eq 0 ] || exit "$rc"
  emit "pasted-text" "pasted" "sha256:$(basename "$final" .txt | sed 's/^pasted-//')" "$final" ""
}

cmd_resolve_ref() {
  local ref="$1" final abs
  case "$ref" in "~/"*) ref="${HOME:-}/${ref#\~/}" ;; esac

  if [ -e "$ref" ]; then
    [ -d "$ref" ] && die 5 "$ref is a directory: give a transcript .jsonl file or a text file"
    case "$ref" in
      *.jsonl)
        validate_transcript "$ref" "the transcript path given"
        abs="$(abs_path "$ref")"
        emit "transcript-path" "session-transcript" "$abs" "$abs" "$(basename "$abs" .jsonl | grep -E "$UUID_RE" || true)"
        ;;
    esac
    [ -f "$ref" ] || die 5 "$ref is not a regular file"
    [ -r "$ref" ] || die 5 "$ref exists but is not readable"
    abs="$(abs_path "$ref")"
    check_source_ref "$abs"   # before anything is written
    final="$(normalise_paste "$ref" "$abs")" || exit $?
    emit "pasted-file" "pasted" "$abs" "$final" ""
  fi

  if printf '%s\n' "$ref" | grep -Eiq "$CLOUD_RE"; then
    die 4 "a claude.ai/code session URL is best effort only: a script reads local files only. If this host has a tool that exports that session's transcript to a file, export it and run resolve again with that file's path; otherwise paste the session's text (resolve -) or give a file holding it."
  fi
  if printf '%s\n' "$ref" | grep -Eq "$LOCAL_RE"; then
    die 4 "a desktop session id ($ref) is best effort only: a script reads local files only. If this host has a tool that exports that session's transcript to a file, export it and run resolve again with that file's path; otherwise paste the session's text (resolve -) or give a file holding it."
  fi
  if printf '%s\n' "$ref" | grep -Eq "$URL_RE"; then
    die 2 "$ref is a link, not a session reference: a link to instructions is the external source of j.workflow-capture, not a session"
  fi
  if [[ $ref =~ $UUID_RE ]]; then
    lookup_session "$ref" "session-id" "the session id given"
  fi
  case "$ref" in
    */*|*.jsonl|*.txt|*.md) die 5 "file not found: $ref (tried it as a path; nothing else is guessed)" ;;
  esac
  die 2 "not a recognised session reference: '$ref' (expected nothing for the current session, a session UUID, a transcript .jsonl path, a file, or - with pasted text on stdin)"
}

case "$CMD" in
  host) cmd_host ;;
  list) cmd_list ;;
  resolve)
    if [ "$REF_SET" -eq 0 ]; then cmd_resolve_current
    elif [ "$REF" = "-" ]; then cmd_resolve_paste
    elif [ -z "$REF" ]; then die 2 "the reference is empty (give nothing at all for the current session)"
    else cmd_resolve_ref "$REF"
    fi
    ;;
esac
