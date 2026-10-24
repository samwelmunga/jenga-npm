#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/never-public-refs.sh - the one never-public-skill rule (E28_S19_T01)
#
# SOURCED, not executed. A "never-public" skill is one whose canonical directory .publicignore blocks, so it is
# absent from every consumer install. A shipped file must not point at one. This script is the single place that
# knows (a) which skills those are, (b) how to recognise a reference to one, and (c) how serious a given hit is.
# Two consumers share it so they cannot disagree:
#   - the catalog smoke test, check 6 (skills/j-smoke-test/scripts/smoke-test-skills.sh)
#   - the mirror-time reference guard (skills/j-mirror-public/scripts/mirror.sh, added by E28_S19_T02)
#
# USAGE
#   source scripts/never-public-refs.sh
#   never_public_load [<publicignore-file>] [<exemptions-file>]
#                                             # default: <repo root>/.publicignore (root = this script's parent dir)
#                                             # and scripts/never-public-exemptions.conf next to this script
#   never_public_skill <name>                 # exit 0 when <name> / j-<name> is never-public
#   never_public_severity <path|name> <text> [own-skill-md] [strict]
#   never_public_path_exempt <file> <text>    # exit 0 when a PATH hit on this line of this file is declared exempt
#
# Outputs of never_public_load (globals): NEVER_PUBLIC_NAMES ("a|b|c", empty when none or no file),
# NEVER_PUBLIC_PATH_RE, NEVER_PUBLIC_NAME_RE, NEVER_PUBLIC_BARE_RE (all ERE for grep -E). With no names, every consumer must treat the
# set as empty and report nothing. The set is read from .publicignore (lines of the form ^skills/j-<name>/$);
# bare-name entries are ignored because the bare form is not a shipped skill.
#
# WHAT IS RECOGNISED
#   path   skills/<name>/ or skills/j-<name>/ (followed by a non-name character or end of line)
#   name   /<name>, /j-<name>, j.<name> and j.j-<name>, when not preceded by a name/path character
#          (NEVER_PUBLIC_NAME_RE). This is exactly what check 6 matched before extraction.
#   bare   a bare j-<name> token such as a quoted playbook step id "j-mirror-public" (NEVER_PUBLIC_BARE_RE).
#          Check 6 did NOT match these. Adding them to check 6 changes its findings on the real repo (two new
#          minor hits in skills/jenga/scripts/{match-playbook,load-playbooks}.sh), which the task forbids, so
#          check 6 does not use this regex. The mirror guard (T02) must scan NEVER_PUBLIC_NAME_RE and
#          NEVER_PUBLIC_BARE_RE together, since the story requires j-<name> references to be covered.
#
# CLASSIFICATION RULE (the decision recorded by E28_S19_T01)
#   path hit, non-comment line ........ critical  (the path does not exist in a consumer install)
#   path hit, comment line ............ minor     (comments do not run; stale documentation)
#   name hit .......................... see below
#   A "comment line" begins (after blanks) with #, //, /* or *. That last form also covers */ and is the
#   continuation line of a C-style or JSDoc block comment (" * text"). E28_S21_T01 added it, which is a
#   recorded, measured amendment to the check 6 findings freeze described under "name hits" below (see
#   project/documentation/public-mirror-content-parity.md).
#   Only a LEADING marker counts: a * anywhere else on the line, such as the glob in skills/*/SKILL.md, does not
#   make it a comment. The test is lexical (it does not track whether a /* block is open), so a line of
#   executable code that happens to begin with * (a shell case arm such as "*.md)") is read as a comment too.
#   A SKILL.md is markdown, where # is a heading and * is a bullet, so callers pass own-skill-md=1 for a
#   markdown file and no line of it counts as a comment.
#
#   name hits have two modes, because the story wording and check 6's behaviour differ:
#     default (check 6) ... every name hit is minor. This is what check 6 did before extraction and its findings
#                           were held byte-identical by E28_S19_T01 (E28_S21_T01 amended that freeze for the
#                           comment rule only; name-hit severity is unchanged). A name mention cannot be told from prose by a regex.
#     strict (mirror guard) a name hit in a non-comment line is critical (a consumer would follow an
#                           invocation); in a comment line it is minor. T02 passes strict=1, which is the story's
#                           "invocations fail, prose and comments are reported" wording. Pre-existing prose
#                           mentions therefore surface as failures under strict; T02 must decide whether to
#                           narrow the shipped-file scan or fix them.
#
# EXEMPTIONS (E28_S21_T03)
#   A few shipped files legitimately name a blocked skill's path as their purpose (a registry of paths that shipped
#   in earlier npm versions, a spent migration tool, a maintainer-only permission rule). They are declared, one entry
#   per file with a mandatory reason, in scripts/never-public-exemptions.conf, whose format and the bar for an entry
#   are documented in that file and in project/documentation/public-mirror-content-parity.md. Every consumer calls
#   never_public_path_exempt for a PATH hit and skips it when it returns 0. The rule lives here so the three consumers
#   (check 6, the mirror guard, scripts/check-public-references.sh) cannot disagree.
#     - Per file, keyed on the root path; a leading .claude/ or .agents/ is folded off, so one entry covers a file
#       and both generated copies of it. Optional literal-substring narrowing ("match"). No globs, no directories.
#     - Path hits only: a line that still carries a name or bare hit once its path hits are blanked is NOT exempt.
#     - Fail closed: a malformed file (missing reason, empty match, duplicate, unparseable line, ...) loads nothing
#       and sets NEVER_PUBLIC_EXEMPT_ERROR, a message naming the entry. never_public_path_exempt then returns 1 for
#       everything, and every consumer is required to stop on a non-empty NEVER_PUBLIC_EXEMPT_ERROR.
#     - An absent file means no exemptions, which is the stricter reading.
#
# Portable: bash 3.2, POSIX sed/grep -E, no GNU-only flags.
# ---------------------------------------------------------------------------

NEVER_PUBLIC_NAMES=""
NEVER_PUBLIC_PATH_RE=""
NEVER_PUBLIC_NAME_RE=""
NEVER_PUBLIC_BARE_RE=""

# Exemption state (see EXEMPTIONS above). Parallel indexed arrays: bash 3.2 has no associative arrays.
NEVER_PUBLIC_EXEMPT_FILE=""
NEVER_PUBLIC_EXEMPT_ERROR=""
NEVER_PUBLIC_EXEMPT_REASON=""
NEVER_PUBLIC_EXEMPT_COUNT=0
NEVER_PUBLIC_EXEMPT_PATHS=()
NEVER_PUBLIC_EXEMPT_MATCHES=()
NEVER_PUBLIC_EXEMPT_REASONS=()

never_public_load() {
  local pi="${1:-}" ex="${2:-}"
  if [ -z "$pi" ]; then
    pi="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.publicignore"
  fi
  if [ -z "$ex" ]; then
    ex="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/never-public-exemptions.conf"
  fi
  never_public_load_exemptions "$ex" || true
  NEVER_PUBLIC_NAMES=""
  if [ -f "$pi" ]; then
    NEVER_PUBLIC_NAMES="$(sed -n 's#^skills/j-\([^/]*\)/$#\1#p' "$pi" | paste -sd '|' -)"
  fi
  NEVER_PUBLIC_PATH_RE="skills/(j-)?($NEVER_PUBLIC_NAMES)([^A-Za-z0-9_-]|\$)"
  NEVER_PUBLIC_NAME_RE="(^|[^A-Za-z0-9_./-])(/|j\\.)(j-)?($NEVER_PUBLIC_NAMES)([^A-Za-z0-9_-]|\$)"
  NEVER_PUBLIC_BARE_RE="(^|[^A-Za-z0-9_./-])j-($NEVER_PUBLIC_NAMES)([^A-Za-z0-9_-]|\$)"
}

never_public_skill() {
  [ -n "$NEVER_PUBLIC_NAMES" ] || return 1
  printf '%s\n' "$1" | grep -qxE "(j-)?($NEVER_PUBLIC_NAMES)"
}

never_public_severity() {
  local kind="$1" text="$2" own_md="${3:-0}" strict="${4:-0}" comment=0
  if [ "$own_md" != 1 ] && [[ "$text" =~ ^[[:space:]]*(#|//|/\*|\*) ]]; then comment=1; fi
  if [ "$comment" = 1 ]; then echo minor; return 0; fi
  if [ "$kind" = path ]; then echo critical; return 0; fi
  if [ "$strict" = 1 ]; then echo critical; else echo minor; fi
}

# never_public_load_exemptions <file>
# Parses the exemption file. Returns 0 with the entries loaded (or none, when the file is absent), or 1 with
# NEVER_PUBLIC_EXEMPT_ERROR set and NO entry loaded. Format: see scripts/never-public-exemptions.conf.
never_public_load_exemptions() {
  local file="$1" line lineno=0 key="" have_entry=0 reason="" match="" has_reason=0 has_match=0
  local name value i
  NEVER_PUBLIC_EXEMPT_FILE="$file"
  NEVER_PUBLIC_EXEMPT_ERROR=""
  NEVER_PUBLIC_EXEMPT_REASON=""
  NEVER_PUBLIC_EXEMPT_COUNT=0
  NEVER_PUBLIC_EXEMPT_PATHS=()
  NEVER_PUBLIC_EXEMPT_MATCHES=()
  NEVER_PUBLIC_EXEMPT_REASONS=()
  [ -f "$file" ] || return 0
  if [ ! -r "$file" ]; then
    NEVER_PUBLIC_EXEMPT_ERROR="never-public exemptions: cannot read $file"
    return 1
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    # trim
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
      "" | "#"*) continue ;;
    esac

    if [[ "$line" =~ ^\[(.*)\]$ ]]; then
      if ! _never_public_exempt_commit; then return 1; fi
      key="${BASH_REMATCH[1]}"
      have_entry=1; reason=""; match=""; has_reason=0; has_match=0
      case "$key" in
        "") NEVER_PUBLIC_EXEMPT_ERROR="never-public exemptions ($file:$lineno): entry has an empty path"; _never_public_exempt_reset; return 1 ;;
        /* | ../* | */../* | */.. | .. | */ )
           NEVER_PUBLIC_EXEMPT_ERROR="never-public exemptions ($file:$lineno): entry '$key' must be a file path relative to the repo root (no leading slash, no .., no directory)"; _never_public_exempt_reset; return 1 ;;
        .claude/* | .agents/* )
           NEVER_PUBLIC_EXEMPT_ERROR="never-public exemptions ($file:$lineno): entry '$key' must be the root path; the .claude/ and .agents/ copies are covered by the root key"; _never_public_exempt_reset; return 1 ;;
        *[\*\?\[\]]* | *[[:space:]]* )
           NEVER_PUBLIC_EXEMPT_ERROR="never-public exemptions ($file:$lineno): entry '$key' contains a glob character or whitespace; only literal file paths are allowed"; _never_public_exempt_reset; return 1 ;;
      esac
      i=0
      while [ "$i" -lt "$NEVER_PUBLIC_EXEMPT_COUNT" ]; do
        if [ "${NEVER_PUBLIC_EXEMPT_PATHS[$i]}" = "$key" ]; then
          NEVER_PUBLIC_EXEMPT_ERROR="never-public exemptions ($file:$lineno): duplicate entry '$key'"; _never_public_exempt_reset; return 1
        fi
        i=$((i + 1))
      done
      continue
    fi

    if [[ "$line" =~ ^([a-z]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      name="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
      if [ "$have_entry" != 1 ]; then
        NEVER_PUBLIC_EXEMPT_ERROR="never-public exemptions ($file:$lineno): '$name' appears before any [path] entry"; _never_public_exempt_reset; return 1
      fi
      case "$name" in
        reason)
          if [ "$has_reason" = 1 ]; then NEVER_PUBLIC_EXEMPT_ERROR="never-public exemptions ($file:$lineno): entry '$key' has two reasons"; _never_public_exempt_reset; return 1; fi
          has_reason=1; reason="$value" ;;
        match)
          if [ "$has_match" = 1 ]; then NEVER_PUBLIC_EXEMPT_ERROR="never-public exemptions ($file:$lineno): entry '$key' has two match lines"; _never_public_exempt_reset; return 1; fi
          has_match=1; match="$value" ;;
        *)
          NEVER_PUBLIC_EXEMPT_ERROR="never-public exemptions ($file:$lineno): entry '$key' has unknown field '$name' (allowed: reason, match)"; _never_public_exempt_reset; return 1 ;;
      esac
      continue
    fi

    NEVER_PUBLIC_EXEMPT_ERROR="never-public exemptions ($file:$lineno): unparseable line (expected [path], reason = ..., match = ..., a # comment or a blank line)"
    _never_public_exempt_reset
    return 1
  done < "$file"

  if ! _never_public_exempt_commit; then return 1; fi
  return 0
}

# Resets the loaded entries (used on every error path so a malformed file loads nothing).
_never_public_exempt_reset() {
  NEVER_PUBLIC_EXEMPT_COUNT=0
  NEVER_PUBLIC_EXEMPT_PATHS=()
  NEVER_PUBLIC_EXEMPT_MATCHES=()
  NEVER_PUBLIC_EXEMPT_REASONS=()
}

# Commits the entry being parsed by never_public_load_exemptions (it reads that function's locals: key, have_entry,
# reason, match, has_reason, has_match, file by bash dynamic scoping). A no-op before the first entry.
_never_public_exempt_commit() {
  [ "$have_entry" = 1 ] || return 0
  if [ "$has_reason" != 1 ] || [ -z "$reason" ]; then
    NEVER_PUBLIC_EXEMPT_ERROR="never-public exemptions ($file): entry '$key' has no reason; every entry must say why it is legitimate"
    _never_public_exempt_reset
    return 1
  fi
  if [ "$has_match" = 1 ] && [ -z "$match" ]; then
    NEVER_PUBLIC_EXEMPT_ERROR="never-public exemptions ($file): entry '$key' has an empty match, which would exempt every line; remove it or give a literal substring"
    _never_public_exempt_reset
    return 1
  fi
  NEVER_PUBLIC_EXEMPT_PATHS[$NEVER_PUBLIC_EXEMPT_COUNT]="$key"
  NEVER_PUBLIC_EXEMPT_MATCHES[$NEVER_PUBLIC_EXEMPT_COUNT]="$match"
  NEVER_PUBLIC_EXEMPT_REASONS[$NEVER_PUBLIC_EXEMPT_COUNT]="$reason"
  NEVER_PUBLIC_EXEMPT_COUNT=$((NEVER_PUBLIC_EXEMPT_COUNT + 1))
  return 0
}

# never_public_path_exempt <file-rel-to-repo-root> <line-text>
# Exit 0 when a PATH hit on this line of this file is declared exempt (and sets NEVER_PUBLIC_EXEMPT_REASON);
# exit 1 otherwise, including whenever the exemption file failed to load. Call it for path hits only.
never_public_path_exempt() {
  local rel="$1" text="$2" key i stripped
  NEVER_PUBLIC_EXEMPT_REASON=""
  [ -z "$NEVER_PUBLIC_EXEMPT_ERROR" ] || return 1
  [ "$NEVER_PUBLIC_EXEMPT_COUNT" -gt 0 ] || return 1
  key="${rel#./}"
  key="${key#.claude/}"
  key="${key#.agents/}"
  i=0
  while [ "$i" -lt "$NEVER_PUBLIC_EXEMPT_COUNT" ]; do
    if [ "${NEVER_PUBLIC_EXEMPT_PATHS[$i]}" = "$key" ]; then
      if [ -n "${NEVER_PUBLIC_EXEMPT_MATCHES[$i]}" ] && [[ "$text" != *"${NEVER_PUBLIC_EXEMPT_MATCHES[$i]}"* ]]; then
        return 1
      fi
      # An exemption never silences a name hit: blank the path hits and see whether a name or bare hit remains.
      stripped="$(printf '%s\n' "$text" | sed -E "s#$NEVER_PUBLIC_PATH_RE# #g")"
      if printf '%s\n' "$stripped" | grep -qE "$NEVER_PUBLIC_NAME_RE|$NEVER_PUBLIC_BARE_RE"; then
        return 1
      fi
      NEVER_PUBLIC_EXEMPT_REASON="${NEVER_PUBLIC_EXEMPT_REASONS[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}
