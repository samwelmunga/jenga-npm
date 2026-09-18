#!/usr/bin/env bash
# scripts/idea_manager.sh — canonical owner of all project/ideas.md operations.
# Run from the repository root.

IDEA_FILE="project/ideas.md"
TEMPLATE="skills/idea/assets/idea_template.md"
PLANS_DIR="project/documentation/plans"

usage() {
  cat >&2 <<EOF
Usage: $0 <subcommand> [args]

Subcommands:
  add "<entry>"                          Append entry to project/ideas.md (auto-creates from
                                          template if missing)
  list                                   Print all non-comment, non-blank entries (silent if
                                          file missing/empty)
  tag "<idea-text>" <TAG>                Tag an existing idea line. <TAG> is either
                                          "PROMOTED:E##_S##[_T##]" or "REJECTED". Errors if the
                                          line is not found, is ambiguous, or is already tagged.
  get-id "<idea-text>"                   Print the embedded board ID from a PROMOTED line
                                          (errors if the line has no PROMOTED tag).
  get-rapport "<idea-text>"              Print the source-rapport path recorded on the line via
                                          a "<!-- rapport: <path> -->" comment. Prints nothing
                                          (exit 0) if the line has no such comment.
  resolve "<idea-text>" <promoted|rejected> [board_id]
                                          The full outcome-record mechanism: tags the line, then
                                          either updates the idea's source rapport (decision,
                                          date, resulting board ID, [SPIKE]-prefixed title) or,
                                          if the idea has no source rapport, creates
                                          project/documentation/plans/<slug>_PROMOTED.md or
                                          _REJECTED.md with the same content. board_id is
                                          required for "promoted" and must be omitted for
                                          "rejected".
EOF
  exit 1
}

# Filters out blank lines, lines starting with #, and HTML comments
real_entries() {
  grep -v '^\s*$' "$1" 2>/dev/null \
    | grep -v '^\s*#' \
    | grep -v '^\s*<!--'
}

# find_idea_line <idea-text>
# Prints "LINE_NUM:CONTENT" for the single line in $IDEA_FILE matching <idea-text> literally.
# Errors (exit 1) if the file is missing, no line matches, or more than one line matches.
find_idea_line() {
  local needle="$1"
  local matches
  if [ ! -f "$IDEA_FILE" ]; then
    echo "Error: $IDEA_FILE does not exist" >&2
    return 1
  fi
  matches=$(grep -Fn -- "$needle" "$IDEA_FILE")
  if [ -z "$matches" ]; then
    echo "Error: no line in $IDEA_FILE matches: $needle" >&2
    return 1
  fi
  if [ "$(printf '%s\n' "$matches" | wc -l | tr -d ' ')" -gt 1 ]; then
    echo "Error: idea text matches multiple lines (ambiguous), refine it: $needle" >&2
    return 1
  fi
  printf '%s\n' "$matches"
}

# tag_line <line-num> <tag-text>
# Appends " <!-- <tag-text> -->" to the given line number of $IDEA_FILE, in place.
# Uses awk string concatenation (not sed substitution) so arbitrary idea text/paths
# containing &, /, or other sed-special characters are never re-interpreted.
tag_line() {
  local linenum="$1"
  local tagtext="$2"
  local tmpfile
  tmpfile="${IDEA_FILE}.tmp.$$"
  awk -v n="$linenum" -v suffix=" <!-- ${tagtext} -->" \
    'NR==n { $0 = $0 suffix } { print }' "$IDEA_FILE" > "$tmpfile" && mv "$tmpfile" "$IDEA_FILE"
}

# slugify <text> — lowercase, non-alphanumeric runs collapsed to a single '-', trimmed, capped
slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-60
}

# extract_rapport_link <line-content> — prints the rapport: path, or nothing if absent
extract_rapport_link() {
  printf '%s' "$1" | grep -oE '<!-- rapport: [^>]*-->' | sed -E 's/<!-- rapport: *([^ ]+) *-->/\1/'
}

# extract_promoted_id <line-content> — prints the embedded board ID, or nothing if absent
extract_promoted_id() {
  printf '%s' "$1" | grep -oE '<!-- PROMOTED: [^>]*-->' | sed -E 's/<!-- PROMOTED: *([^ ]+) *-->/\1/'
}

# already_tagged <line-content> — returns 0 (true) if the line already has a terminal tag
already_tagged() {
  case "$1" in
    *"<!-- PROMOTED"*|*"<!-- REJECTED"*) return 0 ;;
    *) return 1 ;;
  esac
}

# validate_board_id <id> — loose shape check: E<digits> optionally _S<digits> optionally _T<digits>
validate_board_id() {
  case "$1" in
    E[0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

# update_rapport_outcome <rapport-path> <decision-label> <date> <board-id> <idea-text>
# Prefixes the rapport's "# Rapport: ..." title with "[SPIKE] " if not already present, then
# appends an "## Idea Outcome Record" section with the decision.
update_rapport_outcome() {
  local rapport_path="$1" decision_label="$2" today="$3" board_id="$4" idea_text="$5"
  local tmpfile
  tmpfile="${rapport_path}.tmp.$$"

  awk '
    /^# Rapport:/ && $0 !~ /\[SPIKE\]/ {
      sub(/^# Rapport: /, "# Rapport: [SPIKE] ")
    }
    { print }
  ' "$rapport_path" > "$tmpfile" && mv "$tmpfile" "$rapport_path"

  {
    echo ""
    echo "---"
    echo ""
    echo "## Idea Outcome Record"
    echo ""
    echo "**Decision:** ${decision_label}"
    echo "**Date:** ${today} (UTC)"
    if [ "$decision_label" = "Promoted" ]; then
      echo "**Resulting Board ID:** ${board_id}"
    fi
    echo "**Idea:** ${idea_text}"
  } >> "$rapport_path"
}

# write_fallback_outcome <idea-text> <decision-label> <date> <board-id> <file-suffix>
# Creates project/documentation/plans/<slug><file-suffix> and prints its path.
write_fallback_outcome() {
  local idea_text="$1" decision_label="$2" today="$3" board_id="$4" suffix="$5"
  local slug outfile
  slug=$(slugify "$idea_text")
  mkdir -p "$PLANS_DIR"
  outfile="${PLANS_DIR}/${slug}${suffix}"
  {
    echo "# Idea Outcome: ${idea_text}"
    echo ""
    echo "**Decision:** ${decision_label}"
    echo "**Date:** ${today} (UTC)"
    if [ "$decision_label" = "Promoted" ]; then
      echo "**Resulting Board ID:** ${board_id}"
    fi
    echo ""
    echo "## Idea"
    echo ""
    echo "${idea_text}"
  } > "$outfile"
  printf '%s' "$outfile"
}

case "${1:-}" in
  add)
    [ -z "${2:-}" ] && { echo "Error: add requires an entry argument" >&2; exit 1; }
    if [ ! -f "$IDEA_FILE" ]; then
      if [ ! -f "$TEMPLATE" ]; then
        echo "Error: template not found at $TEMPLATE" >&2; exit 1
      fi
      cp "$TEMPLATE" "$IDEA_FILE"
    fi
    printf '%s\n' "$2" >> "$IDEA_FILE"
    ;;

  list)
    [ ! -f "$IDEA_FILE" ] && exit 0
    real_entries "$IDEA_FILE"
    exit 0
    ;;

  tag)
    [ -z "${2:-}" ] && { echo "Error: tag requires an idea-text argument" >&2; exit 1; }
    [ -z "${3:-}" ] && { echo "Error: tag requires a TAG argument (PROMOTED:E##_S##[_T##] or REJECTED)" >&2; exit 1; }
    MATCH=$(find_idea_line "$2") || exit 1
    LINENUM=$(printf '%s' "$MATCH" | cut -d: -f1)
    CONTENT=$(printf '%s' "$MATCH" | cut -d: -f2-)
    if already_tagged "$CONTENT"; then
      echo "Error: idea line is already tagged; refusing to double-tag: $CONTENT" >&2
      exit 1
    fi
    RAW_TAG="$3"
    case "$RAW_TAG" in
      PROMOTED:*)
        BOARD_ID="${RAW_TAG#PROMOTED:}"
        if ! validate_board_id "$BOARD_ID"; then
          echo "Error: invalid board ID format in PROMOTED tag: $BOARD_ID (expected E##_S##[_T##] or E##)" >&2
          exit 1
        fi
        TAG_TEXT="PROMOTED: $BOARD_ID"
        ;;
      REJECTED)
        TAG_TEXT="REJECTED"
        ;;
      *)
        echo "Error: TAG must be PROMOTED:E##_S##[_T##] or REJECTED, got: $RAW_TAG" >&2
        exit 1
        ;;
    esac
    tag_line "$LINENUM" "$TAG_TEXT"
    echo "Tagged line $LINENUM: <!-- $TAG_TEXT -->"
    ;;

  get-id)
    [ -z "${2:-}" ] && { echo "Error: get-id requires an idea-text argument" >&2; exit 1; }
    MATCH=$(find_idea_line "$2") || exit 1
    CONTENT=$(printf '%s' "$MATCH" | cut -d: -f2-)
    ID=$(extract_promoted_id "$CONTENT")
    if [ -z "$ID" ]; then
      echo "Error: no PROMOTED tag found on matching line" >&2
      exit 1
    fi
    echo "$ID"
    ;;

  get-rapport)
    [ -z "${2:-}" ] && { echo "Error: get-rapport requires an idea-text argument" >&2; exit 1; }
    MATCH=$(find_idea_line "$2") || exit 1
    CONTENT=$(printf '%s' "$MATCH" | cut -d: -f2-)
    extract_rapport_link "$CONTENT"
    exit 0
    ;;

  resolve)
    [ -z "${2:-}" ] && { echo "Error: resolve requires an idea-text argument" >&2; exit 1; }
    [ -z "${3:-}" ] && { echo "Error: resolve requires a decision argument: promoted|rejected" >&2; exit 1; }
    IDEA_TEXT="$2"
    DECISION="$3"
    BOARD_ID="${4:-}"

    case "$DECISION" in
      promoted|rejected) : ;;
      *) echo "Error: decision must be 'promoted' or 'rejected', got: $DECISION" >&2; exit 1 ;;
    esac

    if [ "$DECISION" = "promoted" ]; then
      [ -z "$BOARD_ID" ] && { echo "Error: promoted decision requires a board_id argument (E##_S##[_T##] or E##)" >&2; exit 1; }
      if ! validate_board_id "$BOARD_ID"; then
        echo "Error: invalid board ID format: $BOARD_ID" >&2
        exit 1
      fi
    else
      [ -n "$BOARD_ID" ] && { echo "Error: rejected decision does not take a board_id argument" >&2; exit 1; }
    fi

    MATCH=$(find_idea_line "$IDEA_TEXT") || exit 1
    LINENUM=$(printf '%s' "$MATCH" | cut -d: -f1)
    CONTENT=$(printf '%s' "$MATCH" | cut -d: -f2-)

    if already_tagged "$CONTENT"; then
      echo "Error: idea line is already tagged; refusing to re-resolve: $CONTENT" >&2
      exit 1
    fi

    RAPPORT_PATH=$(extract_rapport_link "$CONTENT")

    if [ "$DECISION" = "promoted" ]; then
      TAG_TEXT="PROMOTED: $BOARD_ID"
      DECISION_LABEL="Promoted"
      FILE_SUFFIX="_PROMOTED.md"
    else
      TAG_TEXT="REJECTED"
      DECISION_LABEL="Rejected"
      FILE_SUFFIX="_REJECTED.md"
    fi

    TODAY=$(date -u +%Y-%m-%d)

    tag_line "$LINENUM" "$TAG_TEXT"

    if [ -n "$RAPPORT_PATH" ]; then
      if [ ! -f "$RAPPORT_PATH" ]; then
        echo "Error: source rapport not found at $RAPPORT_PATH; idea line was tagged but outcome record was not written" >&2
        exit 1
      fi
      update_rapport_outcome "$RAPPORT_PATH" "$DECISION_LABEL" "$TODAY" "$BOARD_ID" "$IDEA_TEXT"
      echo "Idea line $LINENUM tagged <!-- $TAG_TEXT -->; rapport updated: $RAPPORT_PATH"
    else
      OUTFILE=$(write_fallback_outcome "$IDEA_TEXT" "$DECISION_LABEL" "$TODAY" "$BOARD_ID" "$FILE_SUFFIX")
      echo "Idea line $LINENUM tagged <!-- $TAG_TEXT -->; outcome record created: $OUTFILE"
    fi
    ;;

  *)
    usage
    ;;
esac
