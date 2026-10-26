#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/workflow/check-doc-refs.sh - verify that every file and script a documentation page references exists
# (epic E80, task E80_S06_T08)
#
# Story E80_S06 requires every cross-reference in the documentation to point at an existing file or script. That
# check is deterministic, so it lives here instead of in a reading exercise. scripts/check-site-links.sh (published
# site permalinks) and scripts/check-public-references.sh (skill references from shipped scripts) cover other
# ground and are not used or modified.
#
# This script only reads. It never writes, and it does not read board files or project/.wiki unless the doc it is
# asked to check names them.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   check-doc-refs.sh <doc.md> [--root <dir>]
#   check-doc-refs.sh -h | --help       print this usage on stdout, exit 0
#
#   <doc.md>        the documentation page to check
#   --root <dir>    the directory repository-style paths resolve against. Default: the repository root, from
#                   `git rev-parse --show-toplevel` run in the doc's directory.
#
# ---------------------------------------------------------------------------
# THE TWO REFERENCE KINDS
# ---------------------------------------------------------------------------
#   (a) Markdown link targets, `[text](target)` (images included). Resolved against the doc's own directory (a target
#       starting with "/" is resolved against --root). The title part, the #fragment and the ?query are dropped
#       first. Never checked: http(s):// and any other URL scheme (mailto:, ...), pure #anchor links, and targets
#       holding glob characters or <placeholder> markers.
#   (b) Backtick-quoted tokens that look like a repo path: the token's first word starts with scripts/, skills/,
#       templates/, tests/, project/, lib/, hooks/ or agents/ and holds no glob character (* ? [ ] { }) and no
#       <...> placeholder. A command such as `scripts/foo.sh init <id>` therefore checks `scripts/foo.sh`. A trailing
#       "," ";" or ":" is dropped. Resolved against --root.
#
# ---------------------------------------------------------------------------
# OUTPUT
# ---------------------------------------------------------------------------
#   stdout, one line per problem, with the path exactly as the doc writes it and a 1-based line number:
#     MISSING <path> (line N)         the target does not exist
#     NOT-EXECUTABLE <path> (line N)  a scripts/... token that exists as a file, is not executable and is not a
#                                     .md or .json file
#   stderr, always when a doc was checked:
#     checked N references, M missing
#   N counts every reference that passed the filters above (each occurrence); M counts MISSING lines only.
#
# IGNORE MARKER
#   A line carrying the comment  <!-- check-doc-refs: ignore -->  is skipped entirely, so a doc can name a
#   deliberately not-yet-existing path (for example files a later epic will add). Use it per line, and say why.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   every reference resolves (and no NOT-EXECUTABLE line was printed)
#   1   at least one MISSING or NOT-EXECUTABLE line was printed
#   2   usage error, bad --root, or an unreadable doc. Nothing on stdout; stderr names the problem. No summary.
# ---------------------------------------------------------------------------

set -u

usage() {
  sed -n '/^# USAGE$/,/^# THE TWO REFERENCE KINDS$/p' "$0" | sed '1d;$d' | sed -e '/^# ---/d' -e 's/^# \{0,1\}//'
}

die() { printf 'check-doc-refs: %s\n' "$1" >&2; exit 2; }

doc=""
root=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --root)
      [ $# -ge 2 ] || die "--root needs a directory argument (usage: check-doc-refs.sh <doc.md> [--root <dir>])"
      root="$2"; shift 2 ;;
    --root=*) root="${1#--root=}"; shift ;;
    -*) die "unknown option: $1 (usage: check-doc-refs.sh <doc.md> [--root <dir>])" ;;
    *)
      [ -z "$doc" ] || die "more than one doc given: '$doc' and '$1' (usage: check-doc-refs.sh <doc.md> [--root <dir>])"
      doc="$1"; shift ;;
  esac
done

[ -n "$doc" ] || die "no doc given (usage: check-doc-refs.sh <doc.md> [--root <dir>])"
[ -f "$doc" ] && [ -r "$doc" ] || die "cannot read doc: $doc"

docdir="$(cd "$(dirname "$doc")" 2>/dev/null && pwd)" || die "cannot enter the directory of doc: $doc"

if [ -z "$root" ]; then
  root="$(git -C "$docdir" rev-parse --show-toplevel 2>/dev/null)" \
    || die "no --root given and no git repository found for $doc"
fi
[ -d "$root" ] || die "--root is not a directory: $root"
root="$(cd "$root" && pwd)"

# The working-file tree name (the conventional tree or its dot-prefixed variant) comes from scripts/resolve-root.sh,
# read from --root with JENGA_PROJECT_ROOT cleared, the way lib.sh reads it for a fixture root. If it cannot be
# read, the resolver's documented default is used, so classification never depends on the caller's directory.
resolve_root_sh="$(cd "$(dirname "$0")/.." && pwd)/resolve-root.sh"
tree="$(cd "$root" && env -u JENGA_PROJECT_ROOT bash "$resolve_root_sh" tree 2>/dev/null)" || tree=""
[ -n "$tree" ] || tree="project"

MARKER='<!-- check-doc-refs: ignore -->'
checked=0
missing=0
problems=0

# Glob characters and <placeholder> markers: such a token names a pattern, not a file.
is_pattern() {
  case "$1" in
    *'*'*|*'?'*|*'['*|*']'*|*'{'*|*'}'*|*'<'*|*'>'*) return 0 ;;
  esac
  return 1
}

# check_ref <kind: link|token> <path as written> <resolved path> <line number>
check_ref() {
  local kind="$1" written="$2" resolved="$3" lineno="$4"
  checked=$((checked + 1))
  if [ ! -e "$resolved" ]; then
    printf 'MISSING %s (line %s)\n' "$written" "$lineno"
    missing=$((missing + 1))
    problems=$((problems + 1))
    return
  fi
  if [ "$kind" = token ] && [ -f "$resolved" ]; then
    case "$written" in
      *.md|*.json) ;;
      scripts/*)
        if [ ! -x "$resolved" ]; then
          printf 'NOT-EXECUTABLE %s (line %s)\n' "$written" "$lineno"
          problems=$((problems + 1))
        fi ;;
    esac
  fi
}

lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  case "$line" in *"$MARKER"*) continue ;; esac

  # (a) markdown link targets
  links="$(printf '%s\n' "$line" | grep -oE '\]\([^)]*\)')"
  if [ -n "$links" ]; then
    while IFS= read -r raw; do
      t="${raw#\](}"; t="${t%)}"
      t="${t#"${t%%[![:space:]]*}"}"       # leading whitespace
      t="${t%%[[:space:]]*}"                # drop a "title" part
      t="${t%%#*}"; t="${t%%\?*}"           # fragment, query
      [ -n "$t" ] || continue               # pure #anchor (or empty) link
      case "$t" in
        [A-Za-z]*:*)                        # URL scheme: http(s)://, mailto:, ...
          case "${t%%:*}" in *[!A-Za-z0-9+.-]*) ;; *) continue ;; esac ;;
      esac
      is_pattern "$t" && continue
      case "$t" in
        /*) resolved="$root$t" ;;
        *)  resolved="$docdir/$t" ;;
      esac
      check_ref link "$t" "$resolved" "$lineno"
    done <<EOF_LINKS
$links
EOF_LINKS
  fi

  # (b) backtick-quoted repo paths
  ticks="$(printf '%s\n' "$line" | grep -oE '`[^`]+`')"
  if [ -n "$ticks" ]; then
    while IFS= read -r raw; do
      t="${raw#\`}"; t="${t%\`}"
      t="${t#"${t%%[![:space:]]*}"}"
      t="${t%%[[:space:]]*}"                # first word only
      t="${t%[,;:]}"
      case "$t" in
        scripts/*|skills/*|templates/*|tests/*|"$tree"/*|lib/*|hooks/*|agents/*) ;;
        *) continue ;;
      esac
      is_pattern "$t" && continue
      check_ref token "$t" "$root/$t" "$lineno"
    done <<EOF_TICKS
$ticks
EOF_TICKS
  fi
done < "$doc"

printf 'checked %s references, %s missing\n' "$checked" "$missing" >&2
[ "$problems" -eq 0 ]
