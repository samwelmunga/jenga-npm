#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-workflow-capture/scripts/snapshot-external.sh - external instructions as an untrusted snapshot
# (epic E103, task E103_S03_T01)
#
# j.workflow-capture's external source: a vendor's setup guide, given as a link or as pasted text. The agent fetches
# a link with the host's own fetch tool (a script cannot) and pipes what it got here; with no fetch tool it asks the
# user to paste the text. This script stores that content as a SNAPSHOT plus the provenance a recording carries
# (source, source_ref; recording-format.sh's PROVENANCE section), so the rest of the capture flow - extract-steps.sh,
# render-review-table.sh, write-capture.sh - is exactly the flow of any other source.
#
# THE CONTENT IS DATA. It is read with cat/tr/hash tools only: never evaluated, sourced, executed, expanded or passed
# on a command line. Nothing in it changes what this script does, and its content is never printed.
#
# USAGE
#   snapshot-external.sh url [options] <url>      the content fetched from <url>, on stdin (or --content-file)
#   snapshot-external.sh paste [options]          pasted text, on stdin (or --content-file)
#   snapshot-external.sh -h | --help              print this usage, exit 0
#
#   --content-file <f>   read the content from this file instead of stdin (also --content-file=<f>).
#   --fetched-at <t>     url: when it was fetched; paste: when it was pasted. UTC, YYYY-MM-DDTHH:MM:SSZ. Default:
#                        JENGA_CAPTURE_NOW, else the current UTC time.
#   --out-dir <dir>      where the snapshot goes (also --out-dir=<dir>). Default: JENGA_CAPTURE_OUT_DIR, else a fresh
#                        private directory from mktemp -d (the same rule as resolve-source.sh).
#   --                   end of options.
#
# URL RULES (url)
#   http:// or https:// only, a host, no whitespace, at most 2048 characters. A URL that carries a credential - URL
#   user information or a credential-named query parameter - is refused by the recorder's own rec_source_ref_problem
#   (exit 2): strip the secret and fetch again. The URL is recorded, never visited, by this script.
#
# CONTENT RULES
#   No NUL byte (exit 8: not text). At least one non-blank character (exit 5). Every carriage return is removed and a
#   final newline ensured; the hash is of the normalised bytes, so the same guide always gives the same snapshot.
#
# FILES (mode 600, in <out-dir>; an existing snapshot with the same hash is replaced by identical bytes)
#   url:   external-<sha12>.txt  and  external-<sha12>.meta.json
#   paste: pasted-<sha12>.txt    and  pasted-<sha12>.meta.json
#   <sha12> is the first 12 hex characters of the content's SHA-256. The .meta.json holds the JSON printed below.
#
# OUTPUT (exit 0): ONE line of JSON on stdout, nothing else:
#   {"form": "external-url"|"pasted-text",
#    "source": "external-url"|"pasted",
#    "source_ref": "<url> fetched_at=<UTC> sha256=<64 hex>"  |  "pasted captured_at=<UTC> sha256=<64 hex>",
#    "path": <absolute path of the snapshot>, "url": <the url, or null>, "fetched_at": <UTC>, "sha256": <64 hex>,
#    "bytes": <size of the snapshot>}
#   form/source/source_ref/path have resolve-source.sh's meaning: pass source and source_ref to
#   write-capture.sh create --source/--source-ref, and read path with extract-steps.sh --kind pasted.
#
# EXIT CODES
#   0 snapshot written     2 usage error, a refused URL or a refused source_ref     3 environment (jq or a SHA-256
#   tool missing, the output directory or the snapshot could not be written, stdin is a terminal, --content-file
#   unreadable)     5 the content is empty     8 the content is not text (NUL bytes)
# Every message goes to stderr; on a non-zero exit stdout is empty and no snapshot is left behind.
#
# Writes only under --out-dir, sends nothing anywhere, and never reads or writes the recorder's pointer.
# bash 3.2 compatible, safe under set -u.
# ---------------------------------------------------------------------------
set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ME="snapshot-external.sh"

usage() { sed -n '3,/^# ----*$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }
die() { local code="$1"; shift; printf '%s: %s\n' "$ME" "$*" >&2; exit "$code"; }

TIME_RE='^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$'
URL_OK_RE='^[Hh][Tt][Tt][Pp][Ss]?://[^/?#[:space:]]+([/?#][^[:space:]]*)?$'

CMD=""
URL=""
URL_SET=0
CONTENT_FILE=""
CONTENT_FILE_SET=0
FETCHED_AT=""
OUT_DIR_OPT=""
ENDOPTS=0

take_positional() {
  if [ -z "$CMD" ]; then CMD="$1"
  elif [ "$CMD" = "url" ] && [ "$URL_SET" -eq 0 ]; then URL="$1"; URL_SET=1
  else die 2 "unexpected argument (see --help)"
  fi
}

while [ $# -gt 0 ]; do
  if [ "$ENDOPTS" -eq 1 ]; then take_positional "$1"; shift; continue; fi
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --) ENDOPTS=1 ;;
    --content-file) [ $# -ge 2 ] || die 2 "--content-file requires a value"; CONTENT_FILE="$2"; CONTENT_FILE_SET=1; shift ;;
    --content-file=*) CONTENT_FILE="${1#--content-file=}"; CONTENT_FILE_SET=1 ;;
    --fetched-at) [ $# -ge 2 ] || die 2 "--fetched-at requires a value"; FETCHED_AT="$2"; shift ;;
    --fetched-at=*) FETCHED_AT="${1#--fetched-at=}" ;;
    --out-dir) [ $# -ge 2 ] || die 2 "--out-dir requires a value"; OUT_DIR_OPT="$2"; shift ;;
    --out-dir=*) OUT_DIR_OPT="${1#--out-dir=}" ;;
    -*) die 2 "unknown option: $1 (see --help)" ;;
    *) take_positional "$1" ;;
  esac
  shift
done

case "$CMD" in
  url) [ "$URL_SET" -eq 1 ] && [ -n "$URL" ] || die 2 "url needs the URL the content was fetched from" ;;
  paste) ;;
  "") die 2 "no sub-command given (expected url or paste; see --help)" ;;
  *) die 2 "unknown sub-command: $CMD (expected url or paste)" ;;
esac
[ "$CONTENT_FILE_SET" -eq 0 ] || [ -n "$CONTENT_FILE" ] || die 2 "--content-file must not be empty"

# --- the URL and the time, before anything is read or written ------------------------------------------------------
FMT="$SCRIPT_DIR/../../j-workflow-recorder/scripts/recording-format.sh"
[ -f "$FMT" ] || die 3 "missing $FMT (the recording format contract)"
# shellcheck source=../../j-workflow-recorder/scripts/recording-format.sh
. "$FMT"

if [ "$CMD" = "url" ]; then
  [ "${#URL}" -le 2048 ] || die 2 "the URL is longer than 2048 characters"
  printf '%s' "$URL" | grep -Eq "$URL_OK_RE" && [ "$(printf '%s' "$URL" | wc -l | tr -d ' ')" -eq 0 ] \
    || die 2 "not an http(s) URL with a host and no whitespace: give the link the instructions were fetched from"
  if problem="$(rec_source_ref_problem "$URL")"; then
    die 2 "this URL cannot be recorded: $problem, then fetch it again"
  fi
fi

if [ -z "$FETCHED_AT" ]; then FETCHED_AT="${JENGA_CAPTURE_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"; fi
printf '%s' "$FETCHED_AT" | grep -Eq "$TIME_RE" || die 2 "the fetch time must be UTC, YYYY-MM-DDTHH:MM:SSZ (got '$FETCHED_AT')"

command -v jq >/dev/null 2>&1 || die 3 "jq is required but was not found on PATH"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | cut -c1-64
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 < "$1" | cut -c1-64
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 < "$1" | sed 's/^.*= *//' | cut -c1-64
  else return 1
  fi
}

if [ "$CONTENT_FILE_SET" -eq 1 ]; then
  [ -f "$CONTENT_FILE" ] && [ -r "$CONTENT_FILE" ] || die 3 "--content-file is not a readable file: $CONTENT_FILE"
else
  [ -t 0 ] && die 3 "the content is read from stdin, and stdin is a terminal: pipe it in, or use --content-file"
fi

# --- output directory ------------------------------------------------------------------------------------------------
DIR="${OUT_DIR_OPT:-${JENGA_CAPTURE_OUT_DIR:-}}"
if [ -z "$DIR" ]; then
  DIR="$(mktemp -d "${TMPDIR:-/tmp}/jenga-capture.XXXXXX")" || die 3 "could not create a private directory for the snapshot"
else
  mkdir -p -- "$DIR" 2>/dev/null || die 3 "could not create the output directory: $DIR"
fi
[ -d "$DIR" ] && [ -w "$DIR" ] || die 3 "the output directory is not a writable directory: $DIR"
DIR="$(cd "$DIR" && pwd -P)"

RAW="$DIR/.snapshot-raw.$$"
TMP="$DIR/.snapshot.$$"
cleanup() { rm -f -- "$RAW" "$TMP" "$TMP.meta"; }
trap cleanup EXIT

# Copy the content byte for byte; it is never interpreted.
if [ "$CONTENT_FILE_SET" -eq 1 ]; then
  cat -- "$CONTENT_FILE" > "$RAW" || die 3 "could not read $CONTENT_FILE"
else
  cat > "$RAW" || die 3 "could not read stdin"
fi

if [ "$(env LC_ALL=C tr -d '\000' < "$RAW" | wc -c)" -ne "$(wc -c < "$RAW")" ]; then
  die 8 "the content holds NUL bytes: it is not text (fetch the page as text, or paste it)"
fi
env LC_ALL=C tr -d '\r' < "$RAW" > "$TMP" || die 3 "could not write $TMP"
env LC_ALL=C grep -q '[^[:space:]]' "$TMP" || die 5 "the content is empty: there is nothing to capture"
if [ "$(tail -c 1 "$TMP" | wc -l | tr -d ' ')" -eq 0 ]; then printf '\n' >> "$TMP"; fi

DIGEST="$(sha256_of "$TMP")" || die 3 "no SHA-256 tool found (sha256sum, shasum or openssl)"
printf '%s' "$DIGEST" | grep -Eq '^[0-9a-f]{64}$' || die 3 "the SHA-256 tool printed something unexpected"
SHA12="$(printf '%s' "$DIGEST" | cut -c1-12)"
BYTES="$(wc -c < "$TMP" | tr -d ' ')"

if [ "$CMD" = "url" ]; then
  FORM="external-url"; SOURCE="external-url"; PREFIX="external"
  REF="$URL fetched_at=$FETCHED_AT sha256=$DIGEST"
else
  FORM="pasted-text"; SOURCE="pasted"; PREFIX="pasted"
  REF="pasted captured_at=$FETCHED_AT sha256=$DIGEST"
fi
rec_is_source_value "$SOURCE" || die 3 "the recording format does not know the source $SOURCE"
if problem="$(rec_source_ref_problem "$REF")"; then die 2 "the source_ref was refused: $problem"; fi

FINAL="$DIR/$PREFIX-$SHA12.txt"
META="$DIR/$PREFIX-$SHA12.meta.json"
JSON="$(jq -cn --arg form "$FORM" --arg source "$SOURCE" --arg ref "$REF" --arg path "$FINAL" \
  --arg url "$URL" --arg at "$FETCHED_AT" --arg sha "$DIGEST" --argjson bytes "$BYTES" \
  '{form: $form, source: $source, source_ref: $ref, path: $path,
    url: (if $url == "" then null else $url end), fetched_at: $at, sha256: $sha, bytes: $bytes}')" \
  || die 3 "could not build the snapshot record"
printf '%s\n' "$JSON" > "$TMP.meta" || die 3 "could not write the snapshot record"

mv -f -- "$TMP" "$FINAL" || die 3 "could not write $FINAL"
if ! mv -f -- "$TMP.meta" "$META"; then rm -f -- "$FINAL"; die 3 "could not write $META"; fi
printf '%s\n' "$JSON"
