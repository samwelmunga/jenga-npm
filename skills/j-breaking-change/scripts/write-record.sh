#!/usr/bin/env bash
################################################################################
# write-record.sh - write one breaking-change record (E91_S01_T01)
#
# The only writer of a breaking-change record: the file that says why a release
# is major and which epics carry the breaking changes. Everything that reads the
# record afterwards (the BREAKING CHANGE footer commit, the changelog entry, a
# reader) parses this file with plain shell; no agent is needed to read it.
#
# USAGE
#   write-record.sh --version vX.Y.Z --reason <text> --epics E12,E34
#                   [--baseline <tag>] [--details <text>] [--replace]
#   write-record.sh -h | --help
#
#   --version   the tag the release will carry: v, three numeric parts, and an
#               optional pre-release suffix (v6.0.0, v6.0.0-rc.1). Required.
#   --reason    the user's reason the release is major, written verbatim:
#               colons, quotes, backslashes and newlines are kept as given.
#               Required, and not empty or whitespace only.
#   --epics     comma-separated epic ids (E12,E34). Required, at least one. Each
#               id must have a file <epics dir>/<id>_*.md on the board; the id is
#               matched with its trailing underscore, so E1 never matches
#               E10_x.md. Duplicates are written once.
#   --baseline  the tag the release was measured against. Optional; empty for a
#               manual run with no baseline.
#   --details   optional free text for the Details section.
#   --replace   overwrite an existing record for this version. Without it an
#               existing record is never touched (exit 5).
#
# WHERE THE RECORD LIVES
#   <documentation>/breaking-changes/<version>.md
# <documentation> is `scripts/resolve-root.sh get documentation` (paths.documentation
# in project/configs/workflow.json, conventional default project/documentation),
# resolved from the current directory. This script has no resolver of its own, and
# never defaults to docs/. The epics directory comes from `resolve-root.sh get epics`.
# breaking-changes/ is created when absent, and only after every input validated.
#
# RECORD SHAPE (rendered from ../assets/record-template.md; the two must agree)
#   ---                              header block, first line of the file
#   version: v6.0.0                  the version argument
#   date: 2026-11-12                 UTC, YYYY-MM-DD, taken at write time
#   baseline: v5.0.1                 the baseline argument, or nothing after the colon
#   epics: E12, E34                  epic ids, in the order given, ", " separated
#   ---                              header block ends
#   (blank line)
#   ## Reason                        heading line, exactly this text
#   (blank line)
#   <reason, verbatim, any number of lines>
#   (blank line)
#   ## Affected epics                heading line, exactly this text
#   (blank line)
#   E12 - <title of E12>             one line per epic: <id> - <title from the board>
#   E34 - <title of E34>
#   (blank line)
#   ## Details                       heading line, exactly this text
#   (blank line)
#   <details, verbatim, or nothing>
#
# PARSING IT WITH SHELL (documented in project/documentation/breaking-change-capture.md)
#   header value   awk -v k=version 'NR==1{next} /^---$/{exit} index($0,k":")==1{sub("^"k": *","");print;exit}' FILE
#                  (k = version, date, baseline or epics). The header is the lines
#                  between the first two "---" lines; each is "key: value".
#                  baseline may be empty.
#   epic ids       the "epics" header value with commas turned into spaces
#   reason         lines after "## Reason" up to the line "## Affected epics",
#                  without the blank line on each side
#   one-line reason  the reason with every whitespace run collapsed to one space
#   affected epics lines matching ^E[0-9]+ - between "## Affected epics" and "## Details"
# The three headings are reserved: a line that is exactly "## Reason",
# "## Affected epics" or "## Details" inside --reason or --details would make the
# sections ambiguous, so such input is refused (exit 2) rather than rewritten.
#
# STDOUT / STDERR
#   Success: the absolute path of the written record, one line, nothing else.
#   Every message, warning and error goes to stderr.
#
# EXIT CODES
#   0  written
#   2  usage or input error: unknown or missing flag/value, malformed version,
#      empty reason, malformed epic list or baseline, reserved heading in
#      --reason/--details. Nothing was created.
#   3  environment: scripts/resolve-root.sh or the record template could not be
#      located, or the documentation/epics path could not be resolved.
#   4  an epic id is not on the board (no <id>_*.md), or its file has no title.
#   5  a record for this version already exists and --replace was not given. The
#      existing file is untouched. Dedicated so a caller can branch on it.
#   6  the record could not be written (directory, temp file or move failed).
#
# Compatible with macOS bash 3.2 (no mapfile, associative arrays or case-modifying
# expansions). No network. No git commands. Writes one file, atomically: a temp
# file in the destination directory, then link (no --replace, so an existing file
# is never clobbered even by a racing writer) or mv (--replace).
################################################################################

set -o nounset

SCRIPT_NAME="write-record.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Package root (scripts/, templates/, lib/): resolved by the shared helper so it also works from a consumer's .claude/skills mirror.
# shellcheck source=/dev/null
if [ -f "$SCRIPT_DIR/../../index/scripts/package-root.sh" ]; then . "$SCRIPT_DIR/../../index/scripts/package-root.sh"; else jenga_package_root() { (cd "$1/../../.." && pwd); }; fi
REPO_ROOT="$(jenga_package_root "$SCRIPT_DIR")" || true
TEMPLATE="$SCRIPT_DIR/../assets/record-template.md"

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }
usage() {
  printf 'Usage: %s --version vX.Y.Z --reason <text> --epics E12,E34 [--baseline <tag>] [--details <text>] [--replace]\n' "$SCRIPT_NAME" >&2
}

resolve_helper() {
  local rel="$1" candidate
  for candidate in "$REPO_ROOT/$rel" "$REPO_ROOT/node_modules/@jenga-ai/agent/$rel"; do
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

VERSION=""
REASON=""
EPICS_ARG=""
BASELINE=""
DETAILS=""
REPLACE="false"
HAVE_REASON="false"
HAVE_EPICS="false"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version|--reason|--epics|--baseline|--details)
      if [ "$#" -lt 2 ]; then
        err "$1 needs a value"; usage; exit 2
      fi
      case "$1" in
        --version)  VERSION="$2" ;;
        --reason)   REASON="$2"; HAVE_REASON="true" ;;
        --epics)    EPICS_ARG="$2"; HAVE_EPICS="true" ;;
        --baseline) BASELINE="$2" ;;
        --details)  DETAILS="$2" ;;
      esac
      shift 2
      ;;
    --replace) REPLACE="true"; shift ;;
    -h|--help|help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage; exit 2 ;;
  esac
done

# ---- validate inputs (nothing is created until all of these pass) -------------

# grep matches line by line, so a value with a good first line and extra lines would pass the
# shape checks below; version and baseline are single-line header values, so refuse any line break.
has_line_break() {
  case "$1" in
    *$'\n'*|*$'\r'*) return 0 ;;
  esac
  return 1
}

if [ -z "$VERSION" ]; then
  err "--version is required"; usage; exit 2
fi
if has_line_break "$VERSION"; then
  err "malformed version (contains a line break)"; exit 2
fi
if has_line_break "$BASELINE"; then
  err "malformed baseline (contains a line break)"; exit 2
fi
if ! printf '%s' "$VERSION" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$'; then
  err "malformed version '$VERSION' (expected vX.Y.Z, optionally with a pre-release suffix such as -rc.1)"
  exit 2
fi

if [ "$HAVE_REASON" != "true" ] || [ -z "$(printf '%s' "$REASON" | tr -d '[:space:]')" ]; then
  err "the reason must not be empty"; exit 2
fi

if [ -n "$BASELINE" ] && ! printf '%s' "$BASELINE" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._/-]*$'; then
  err "malformed baseline '$BASELINE' (expected a tag name without spaces)"; exit 2
fi

reserved_heading() {
  # $1 = text; succeeds when any line of it is exactly a reserved heading
  printf '%s\n' "$1" | grep -Eq '^(## Reason|## Affected epics|## Details)[[:space:]]*$'
}
if reserved_heading "$REASON"; then
  err "--reason contains a line that is a reserved record heading (## Reason, ## Affected epics, ## Details)"; exit 2
fi
if reserved_heading "$DETAILS"; then
  err "--details contains a line that is a reserved record heading (## Reason, ## Affected epics, ## Details)"; exit 2
fi

if [ "$HAVE_EPICS" != "true" ] || [ -z "$(printf '%s' "$EPICS_ARG" | tr -d '[:space:],')" ]; then
  err "--epics is required (comma-separated epic ids, for example E12,E34)"; usage; exit 2
fi

# Split the epic list (comma separated, blanks around ids ignored), dedupe in order.
EPIC_IDS=""
_old_ifs="$IFS"
IFS=','
set -f
for raw in $EPICS_ARG; do
  id="$(printf '%s' "$raw" | tr -d '[:space:]')"
  if ! printf '%s' "$id" | grep -Eq '^E[0-9]+$'; then
    IFS="$_old_ifs"; set +f
    err "malformed epic id '$raw' (expected E followed by digits, for example E12)"; exit 2
  fi
  case " $EPIC_IDS " in
    *" $id "*) ;;
    *) EPIC_IDS="${EPIC_IDS:+$EPIC_IDS }$id" ;;
  esac
done
IFS="$_old_ifs"
set +f

# ---- resolve paths (the one shared resolver) ---------------------------------

RESOLVE_ROOT="$(resolve_helper scripts/resolve-root.sh)" || {
  err "could not locate scripts/resolve-root.sh"; exit 3
}
if [ ! -f "$TEMPLATE" ]; then
  err "record template missing: $TEMPLATE"; exit 3
fi
DOC_DIR="$(bash "$RESOLVE_ROOT" get documentation 2>/dev/null)" || DOC_DIR=""
[ -n "$DOC_DIR" ] || { err "could not resolve the documentation directory"; exit 3; }
EPICS_DIR="$(bash "$RESOLVE_ROOT" get epics 2>/dev/null)" || EPICS_DIR=""
[ -n "$EPICS_DIR" ] || { err "could not resolve the epics directory"; exit 3; }

# ---- board lookup: id + trailing underscore, title from frontmatter ----------

epic_file() {
  # first file named <id>_*.md in the epics directory, or nothing
  local f
  for f in "$EPICS_DIR/$1"_*.md; do
    if [ -f "$f" ]; then printf '%s' "$f"; return 0; fi
  done
  return 1
}

epic_title() {
  # title of the first "title:" line inside the leading --- block, quotes stripped
  awk '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    /^title:/ {
      t = $0
      sub(/^title:[ \t]*/, "", t)
      sub(/[ \t\r]+$/, "", t)
      if (t ~ /^".*"$/) { t = substr(t, 2, length(t) - 2); gsub(/\\"/, "\"", t) }
      else if (t ~ /^'"'"'.*'"'"'$/) { t = substr(t, 2, length(t) - 2) }
      print t
      exit
    }
  ' "$1"
}

AFFECTED=""
EPICS_HEADER=""
for id in $EPIC_IDS; do
  f="$(epic_file "$id")" || { err "unknown epic id $id (no $EPICS_DIR/${id}_*.md)"; exit 4; }
  title="$(epic_title "$f")"
  if [ -z "$title" ]; then
    err "epic $id has no title in $f"; exit 4
  fi
  AFFECTED="${AFFECTED:+$AFFECTED
}$id - $title"
  EPICS_HEADER="${EPICS_HEADER:+$EPICS_HEADER, }$id"
done

# ---- destination -------------------------------------------------------------

OUT_DIR="$DOC_DIR/breaking-changes"
OUT="$OUT_DIR/$VERSION.md"

if [ -e "$OUT" ] && [ "$REPLACE" != "true" ]; then
  err "a record for $VERSION already exists: $OUT (use --replace to overwrite it)"
  exit 5
fi

mkdir -p "$OUT_DIR" 2>/dev/null || { err "could not create $OUT_DIR"; exit 6; }
TMP="$(mktemp "$OUT_DIR/.$VERSION.XXXXXX" 2>/dev/null)" || { err "could not create a temp file in $OUT_DIR"; exit 6; }
trap 'rm -f "$TMP"' EXIT

# Render the template: whole-line placeholders for the free-text parts (so the
# text is copied verbatim, never re-interpreted), inline placeholders for the
# header values. ENVIRON keeps backslashes and newlines exactly as given.
WR_VERSION="$VERSION" WR_DATE="$(date -u +%Y-%m-%d)" WR_BASELINE="$BASELINE" \
WR_EPICS="$EPICS_HEADER" WR_REASON="$REASON" WR_AFFECTED="$AFFECTED" WR_DETAILS="$DETAILS" \
awk '
  function replace(line, key, val,    i) {
    i = index(line, key)
    while (i > 0) {
      line = substr(line, 1, i - 1) val substr(line, i + length(key))
      i = index(line, key)
    }
    return line
  }
  $0 == "{{reason}}"         { print ENVIRON["WR_REASON"]; next }
  $0 == "{{affected_epics}}" { print ENVIRON["WR_AFFECTED"]; next }
  $0 == "{{details}}"        { if (ENVIRON["WR_DETAILS"] != "") print ENVIRON["WR_DETAILS"]; next }
  {
    line = $0
    line = replace(line, "{{version}}",  ENVIRON["WR_VERSION"])
    line = replace(line, "{{date}}",     ENVIRON["WR_DATE"])
    line = replace(line, "{{baseline}}", ENVIRON["WR_BASELINE"])
    line = replace(line, "{{epics}}",    ENVIRON["WR_EPICS"])
    sub(/[ \t]+$/, "", line)
    print line
  }
' "$TEMPLATE" > "$TMP" || { err "could not render the record"; exit 6; }

# mktemp creates the file 0600; a record is a documentation file, so give it the usual mode.
chmod 644 "$TMP" 2>/dev/null || true

if [ "$REPLACE" = "true" ]; then
  mv -f "$TMP" "$OUT" 2>/dev/null || { err "could not write $OUT"; exit 6; }
else
  # ln fails when the target exists, so a record written by a racing caller is never clobbered.
  if ! ln "$TMP" "$OUT" 2>/dev/null; then
    if [ -e "$OUT" ]; then
      err "a record for $VERSION already exists: $OUT (use --replace to overwrite it)"
      exit 5
    fi
    err "could not write $OUT"; exit 6
  fi
fi

printf '%s\n' "$OUT"
exit 0
