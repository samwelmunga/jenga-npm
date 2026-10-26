#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/scan-credential-patterns.sh - enumerate credential-access patterns (epic E85, task E85_S02_T01)
#
# Lists every line in the bundled skills and scripts that matches one of the patterns a third-party scanner
# flags as "reads credentials or secrets". It ENUMERATES; it does not judge. A match is data, not an error:
# whether a line really obtains a credential value (a "true read") or merely mentions one (a "benign mention")
# is decided by reading the surrounding code, and recorded in project/documentation/credential-access-audit.md
# and project/data/credential-findings.json. This script exists so that audit is repeatable and so the later
# guard (E85_S02_T05) and the mirror re-check (E85_S02_T07) reuse one set of patterns instead of re-deriving it.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   scan-credential-patterns.sh [--root <dir>] [--format tsv|json] [<path>...]
#   scan-credential-patterns.sh -h | --help       print this usage on stdout, exit 0
#
#   --root <dir>      the tree to scan; every <path> and every reported file is relative to it.
#                     Default: the repository root (the parent of this script's directory).
#   --format <fmt>    tsv (default) or json. See OUTPUT.
#   <path>...         files or directories, relative to --root (an absolute path inside --root is also accepted).
#                     Default when none is given: skills and scripts (a missing default directory is skipped).
#                     A given path that does not exist is a usage error.
#
# Never scanned: .git/ and node_modules/ directories, binary files, and this script's own source (its pattern
# definitions would match themselves). Everything else under the given paths is scanned, whatever its extension.
#
# ---------------------------------------------------------------------------
# PATTERN CLASSES (the five stable ids)
# ---------------------------------------------------------------------------
#   gh-auth          "gh auth" followed by anything (gh auth login, status, token, setup-git, ...)
#   aws-env          AWS_ environment references: $AWS_X, ${AWS_X}, or a bare AWS_X name
#   dotfile-path     "~/." or "$HOME/." or "${HOME}/." dotfile paths (~/.ssh/id_deploy, $HOME/.config/x)
#   home-ref         a bare $HOME, ${HOME} or "~/" reference NOT followed by "." (the dotfile case is the
#                    class above, so a dotfile path is not also reported as a bare home reference)
#   credential-file  well-known credential file names: .aws/credentials, .ssh/, .npmrc, .netrc, id_rsa,
#                    id_deploy, .env (".env" and the id_* names must not be the tail of a longer word, so
#                    process.env and valid_deployment are not hit)
#
# A line matching several classes is reported ONCE PER CLASS, so "gh secret set X < ~/.ssh/id_deploy" yields a
# dotfile-path row and a credential-file row. Rows are ordered by file, then line, then class in the order the
# classes are listed above, which makes the ordering total and the output deterministic.
#
# ---------------------------------------------------------------------------
# OUTPUT
# ---------------------------------------------------------------------------
#   tsv   one row per match, no header: file<TAB>line<TAB>class<TAB>text. text is the matched line with
#         leading/trailing whitespace trimmed, tabs turned into single spaces and carriage returns dropped.
#   json  one object, the same rows in the same order:
#           {"schema_version":1,"root":"<absolute root>","matches":[{"file","line","class","text"}]}
#         line is a number; text is the same trimmed text as in tsv, JSON-escaped, other control characters
#         turned into spaces.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   the scan ran (with or without matches - matches are data)
#   2   bad usage: unknown option, missing or invalid option value, --root not a directory, a path that does
#       not exist or lies outside --root
#
# Portability: macOS bash 3.2 and BSD userland; grep -E only (no -P). Read-only: writes nothing but stdout.
# ---------------------------------------------------------------------------

set -u

usage() {
  awk 'NR==1{next} /^set -u/{exit} {sub(/^# ?/,""); print}' "$0"
}

die_usage() {
  printf 'scan-credential-patterns.sh: %s\n' "$1" >&2
  printf 'try: scan-credential-patterns.sh --help\n' >&2
  exit 2
}

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd -P)"
SELF_NAME="$(basename "$SCRIPT_PATH")"

root=""
format="tsv"
paths=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --root)
      [ $# -ge 2 ] || die_usage "--root needs a directory"
      root="$2"
      shift 2
      ;;
    --root=*)
      root="${1#--root=}"
      shift
      ;;
    --format)
      [ $# -ge 2 ] || die_usage "--format needs tsv or json"
      format="$2"
      shift 2
      ;;
    --format=*)
      format="${1#--format=}"
      shift
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do
        paths+=("$1")
        shift
      done
      ;;
    -*)
      die_usage "unknown option: $1"
      ;;
    *)
      paths+=("$1")
      shift
      ;;
  esac
done

case "$format" in
  tsv | json) ;;
  *) die_usage "invalid --format '$format' (expected tsv or json)" ;;
esac

if [ -z "$root" ]; then
  root="$SCRIPT_DIR/.."
fi
[ -d "$root" ] || die_usage "--root is not a directory: $root"
root="$(cd "$root" && pwd -P)"

# Resolve the scan targets, relative to the root.
targets=()
if [ "${#paths[@]}" -eq 0 ]; then
  for d in skills scripts; do
    [ -e "$root/$d" ] && targets+=("$d")
  done
else
  for p in "${paths[@]}"; do
    case "$p" in
      "$root"/*) p="${p#"$root"/}" ;;
      /*) die_usage "path is outside --root: $p" ;;
    esac
    p="${p#./}"
    while [ "${p%/}" != "$p" ]; do p="${p%/}"; done
    [ -n "$p" ] || die_usage "empty path"
    [ -e "$root/$p" ] || die_usage "no such path under --root: $p"
    targets+=("$p")
  done
fi

# Pattern classes: id|ordinal|ERE. Kept in one place so the header, the code and the docs cannot drift.
# shellcheck disable=SC2016  # the $ and ~ are literal pattern text, never meant to expand
PAT_GH_AUTH='(^|[^A-Za-z0-9_])gh[[:space:]]+auth([^A-Za-z0-9_-]|$)'
# shellcheck disable=SC2016
PAT_AWS_ENV='(^|[^A-Za-z0-9])AWS_'
# shellcheck disable=SC2016
PAT_DOTFILE='(~|\$HOME|\$\{HOME(:[^}]*)?\})/\.'
# shellcheck disable=SC2016
PAT_HOME='\$HOME(/?$|[^A-Za-z0-9_/]|/[^.])|\$\{HOME(:[^}]*)?\}(/?$|[^/]|/[^.])|~/([^.]|$)'
# shellcheck disable=SC2016
PAT_CRED='\.aws/credentials|\.ssh/|\.npmrc|\.netrc|(^|[^A-Za-z0-9])(id_rsa|id_deploy)|(^|[^A-Za-z0-9_])\.env([^A-Za-z0-9_]|$)'

# Enumerate the files, sorted, skipping .git, node_modules and this script's own source.
filelist="$(mktemp "${TMPDIR:-/tmp}/scp-files.XXXXXX")"
records="$(mktemp "${TMPDIR:-/tmp}/scp-recs.XXXXXX")"
trap 'rm -f "$filelist" "$records"' EXIT

if [ "${#targets[@]}" -gt 0 ]; then
  (
    cd "$root" || exit 2
    find "${targets[@]}" \( -name .git -o -name node_modules \) -prune -o -type f ! -name "$SELF_NAME" -print
  ) | LC_ALL=C sort -u >"$filelist"
fi

scan_class() {
  # $1 class id, $2 ordinal, $3 pattern; reads the file list in batches so the argument list stays short
  local cls="$1" ord="$2" pat="$3" batch=() f
  while IFS= read -r f; do
    batch+=("$f")
    if [ "${#batch[@]}" -ge 150 ]; then
      scan_batch "$cls" "$ord" "$pat" "${batch[@]}"
      batch=()
    fi
  done <"$filelist"
  if [ "${#batch[@]}" -gt 0 ]; then
    scan_batch "$cls" "$ord" "$pat" "${batch[@]}"
  fi
}

scan_batch() {
  local cls="$1" ord="$2" pat="$3"
  shift 3
  (cd "$root" && LC_ALL=C grep -HnIE -e "$pat" -- "$@" 2>/dev/null) |
    awk -v cls="$cls" -v ord="$ord" '
      {
        # grep -Hn prints file:line:text; the file name never contains a colon in this tree
        i = index($0, ":"); file = substr($0, 1, i - 1); rest = substr($0, i + 1)
        j = index(rest, ":"); line = substr(rest, 1, j - 1); text = substr(rest, j + 1)
        gsub(/\r/, "", text); gsub(/\t/, " ", text)
        gsub(/[[:cntrl:]]/, " ", text)
        sub(/^[ ]+/, "", text); sub(/[ ]+$/, "", text)
        printf "%s\t%s\t%s\t%s\t%s\n", file, line, ord, cls, text
      }' >>"$records"
}

if [ -s "$filelist" ]; then
  scan_class gh-auth 1 "$PAT_GH_AUTH"
  scan_class aws-env 2 "$PAT_AWS_ENV"
  scan_class dotfile-path 3 "$PAT_DOTFILE"
  scan_class home-ref 4 "$PAT_HOME"
  scan_class credential-file 5 "$PAT_CRED"
fi

sorted() {
  LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2n -k3,3n -u "$records"
}

if [ "$format" = "tsv" ]; then
  sorted | awk -F'\t' '{ printf "%s\t%s\t%s\t", $1, $2, $4; t = $5; for (k = 6; k <= NF; k++) t = t "\t" $k; print t }'
else
  sorted | awk -F'\t' -v root="$root" '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    BEGIN { printf "{\"schema_version\":1,\"root\":\"%s\",\"matches\":[", esc(root) }
    {
      t = $5; for (k = 6; k <= NF; k++) t = t "\t" $k
      printf "%s{\"file\":\"%s\",\"line\":%d,\"class\":\"%s\",\"text\":\"%s\"}", (NR > 1 ? "," : ""), esc($1), $2 + 0, $4, esc(t)
    }
    END { print "]}" }'
fi

exit 0
