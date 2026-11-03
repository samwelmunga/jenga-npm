#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-workflow-recorder/scripts/recording-path.sh - where a recording goes (epic E89, task E89_S01_T01)
#
# The first script of the session workflow recorder. Given a descriptive name taken from the user's opening
# interaction, it prints the absolute path the recording document should be written to - ONE line on stdout and
# nothing else - so every other script in the epic can consume it with a plain command substitution.
#
# Three jobs, all deterministic, which is why this is a script and not instructions in a SKILL.md
# (CLAUDE.md, "Skill Implementation Principle - Scripts Over Inline Logic"):
#
#   1. Slug derivation. Lowercase; every run of non-alphanumeric characters collapsed to a single hyphen; no
#      leading or trailing hyphen. The same shape the board's own filename slugs use.
#   2. Truncation. The epic settles the 100-character limit as a WHOLE-FILENAME limit, confirmed by the user on
#      2026-11-01: slug + "_RECORDING" + ".md" is at most 100 characters in total. The slug budget is therefore
#      100 minus the length of the suffix - 87 characters - and that number is COMPUTED from the two constants
#      below, never written as a literal, so changing either constant cannot leave a stale 87 behind.
#      The cut is taken mid-word rather than by dropping the whole final word: the existing task filenames on
#      this project's board are the precedent for that. Any hyphen the cut leaves at the end is stripped.
#   3. Destination. The documentation root comes from "resolve-root.sh get documentation". There is no path
#      literal for it anywhere in this file, and scripts/check-staged-hardcoded-paths.sh is run against this
#      work.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   recording-path.sh [--dir <directory>] [--slug-only] [--max <n>] <descriptive name...>
#   recording-path.sh -h | --help | help          print this usage on stdout, exit 0
#
#   <descriptive name...>  one or more arguments, joined with single spaces, so an unquoted phrase works:
#                            recording-path.sh Set up the release pipeline
#                          is the same as
#                            recording-path.sh "Set up the release pipeline"
#   --dir <directory>      write the recording here instead of the resolved documentation root. Also the
#                          JENGA_RECORDING_DIR environment seam (see ENVIRONMENT). A relative directory is
#                          made absolute against $PWD, because the contract is an ABSOLUTE path on stdout.
#   --slug-only            print the derived, truncated, collision-resolved slug instead of the full path.
#                          For a caller that wants the recording's identity without its location (and for
#                          this task's own tests). Still one line, still nothing else.
#   --max <n>              override the whole-filename limit, for a caller with a stricter filesystem. The
#                          slug budget is recomputed from it. Must be greater than the suffix length.
#
# ---------------------------------------------------------------------------
# COLLISION HANDLING
# ---------------------------------------------------------------------------
# If the target filename already exists, the path is NOT returned (never overwrite) and the script does NOT
# fail (a name clash is ordinary, not an error). A deterministic numeric discriminator is appended INSIDE the
# slug budget: for n = 2, 3, ... the slug is re-truncated to budget - len("-n"), a trailing hyphen is stripped,
# "-n" is appended, and the result is tested again. Because the discriminator is paid for out of the budget
# rather than added on top of it, the 100-character ceiling still holds after it is added - which is the whole
# reason the re-truncation happens per candidate instead of once up front.
#
# The scan is capped at MAX_DISCRIMINATOR. Exhausting it exits 5 rather than looping forever or silently
# returning an occupied path; at that point the caller has hundreds of recordings sharing one name and wants to
# hear about it.
#
# WHAT THIS SCRIPT DELIBERATELY DOES NOT DO: it creates nothing. No directory, no file, no reservation. It is a
# PURE FUNCTION of (name, directory contents), so two back-to-back calls with the same name return the same
# path - the second call cannot know the caller never created the first. That is the correct split: creating the
# file is recording-file.sh's job (E89_S01_T02), and it refuses to clobber, so the two together cannot lose a
# recording. What this script guarantees is the property that matters: the path it returns is never the path of
# a file that already exists, so an existing recording is never the thing you are told to write to. A caller
# that wants two distinct paths creates the first one before asking for the second.
#
# ---------------------------------------------------------------------------
# ENVIRONMENT
# ---------------------------------------------------------------------------
#   JENGA_RECORDING_DIR   use this directory instead of the resolved documentation root. Lower priority than
#                         --dir. Primarily a test seam, in the style of JENGA_CHECKLIST_MARKER_DIR in
#                         scripts/checklist-marker.sh, so a test suite never reads or writes a real
#                         documentation directory.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   success. One line on stdout: the absolute path (or the slug, under --slug-only).
#   2   usage error: no name given, an unknown option, a missing option argument, a bad --max, or a name with
#       no alphanumeric character at all (nothing can be derived from it, so there is nothing to truncate).
#   3   the documentation root could not be resolved through resolve-root.sh.
#   5   the collision scan was exhausted (more than MAX_DISCRIMINATOR recordings share this name).
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions) and safe under
# `set -u`.
# ---------------------------------------------------------------------------

set -u
export LC_ALL=C

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The recording suffix and the whole-filename ceiling. The slug budget is derived from these two and is never
# hardcoded anywhere below.
RECORDING_SUFFIX="_RECORDING.md"
MAX_FILENAME=100
MAX_DISCRIMINATOR=999

err() {
  printf '%s: %s\n' "$SELF" "$*" >&2
}

die() {
  local code="$1"; shift
  err "$*"
  exit "$code"
}

usage() {
  cat <<'USAGE'
usage:
  recording-path.sh [--dir <directory>] [--slug-only] [--max <n>] <descriptive name...>
  recording-path.sh -h | --help | help

Prints the absolute path a session recording should be written to - one line on stdout, nothing else.
The name is lowercased and hyphenated, then truncated so the WHOLE filename (slug + _RECORDING.md) stays
within 100 characters. The destination comes from the resolved documentation root, never a path literal.
If the filename is taken, a numeric discriminator (-2, -3, ...) is spent out of the slug budget so the
100-character limit still holds; an existing file is never returned and never modified. Creates nothing.
Full contract: the header of this script.
USAGE
}

# Prints the directory the recording belongs in, absolute, with no trailing slash.
# $1 is an explicit --dir value ("" for none). Returns 3 when the documentation root cannot be resolved.
resolve_target_dir() {
  local explicit="${1:-}" dir=""

  if [ -n "$explicit" ]; then
    dir="$explicit"
  elif [ -n "${JENGA_RECORDING_DIR:-}" ]; then
    dir="$JENGA_RECORDING_DIR"
  else
    # The resolver lives at the repository's scripts/ directory; this script is two levels below it under
    # skills/<skill>/scripts/, so climb rather than name any path from the project root.
    local resolver="$SCRIPT_DIR/../../../scripts/resolve-root.sh"
    if [ ! -f "$resolver" ]; then
      err "could not find resolve-root.sh (looked for $resolver)"
      return 3
    fi
    if ! dir="$(bash "$resolver" get documentation)" || [ -z "$dir" ]; then
      err "could not resolve the documentation root via resolve-root.sh"
      return 3
    fi
  fi

  # Absolutise: the contract is an absolute path, and --dir / the env seam may be relative. An existing
  # directory is canonicalised with cd/pwd; a not-yet-created one is joined onto $PWD textually, because this
  # script creates nothing and must not mkdir just to learn a name.
  case "$dir" in
    /*) : ;;
    *) dir="$PWD/$dir" ;;
  esac
  if [ -d "$dir" ]; then
    dir="$(cd "$dir" && pwd)"
  fi
  while [ "$dir" != "/" ] && [ "${dir%/}" != "$dir" ]; do
    dir="${dir%/}"
  done
  printf '%s' "$dir"
}

# Prints the bare slug for $1: lowercase, runs of non-alphanumerics collapsed to one hyphen, no outer hyphens.
derive_slug() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9][^a-z0-9]*/-/g' -e 's/^-*//' -e 's/-*$//'
}

# Prints $1 cut to at most $2 characters with any trailing hyphen the cut left removed.
truncate_slug() {
  local s="$1" budget="$2"
  if [ "${#s}" -gt "$budget" ]; then
    s="${s:0:$budget}"
  fi
  while [ -n "$s" ] && [ "${s%-}" != "$s" ]; do
    s="${s%-}"
  done
  printf '%s' "$s"
}

main() {
  local dir_opt="" slug_only=0 max_opt="" name="" a

  while [ "$#" -gt 0 ]; do
    a="$1"
    case "$a" in
      -h|--help|help) usage; return 0 ;;
      --dir)
        [ "$#" -ge 2 ] || die 2 "--dir needs a directory"
        dir_opt="$2"; shift 2; continue
        ;;
      --dir=*) dir_opt="${a#--dir=}"; shift; continue ;;
      --slug-only) slug_only=1; shift; continue ;;
      --max)
        [ "$#" -ge 2 ] || die 2 "--max needs a number"
        max_opt="$2"; shift 2; continue
        ;;
      --max=*) max_opt="${a#--max=}"; shift; continue ;;
      --) shift; break ;;
      -*) usage >&2; die 2 "unknown option \"$a\"" ;;
      *) break ;;
    esac
  done

  # Everything left is the descriptive name, joined with single spaces.
  if [ "$#" -gt 0 ]; then
    name="$*"
  fi
  if [ -z "$name" ]; then
    usage >&2
    die 2 "no descriptive name given"
  fi

  local max="$MAX_FILENAME"
  if [ -n "$max_opt" ]; then
    case "$max_opt" in
      ''|*[!0-9]*) die 2 "bad --max \"$max_opt\" (expected a positive whole number of characters)" ;;
    esac
    max="$max_opt"
    if [ "$max" -le "${#RECORDING_SUFFIX}" ]; then
      die 2 "bad --max $max (must be greater than ${#RECORDING_SUFFIX}, the length of \"$RECORDING_SUFFIX\")"
    fi
  fi
  local budget=$(( max - ${#RECORDING_SUFFIX} ))

  local slug
  slug="$(derive_slug "$name")"
  if [ -z "$slug" ]; then
    die 2 "the name \"$name\" has no alphanumeric character, so no slug can be derived from it"
  fi
  slug="$(truncate_slug "$slug" "$budget")"
  if [ -z "$slug" ]; then
    # Only reachable with a --max so small that the budget cannot hold one character.
    die 2 "the name \"$name\" leaves no room for a slug within a ${max}-character filename"
  fi

  local dir
  dir="$(resolve_target_dir "$dir_opt")" || return 3

  local candidate="$slug" n=2 base
  while [ -e "$dir/$candidate$RECORDING_SUFFIX" ]; do
    if [ "$n" -gt "$MAX_DISCRIMINATOR" ]; then
      err "every name from \"$slug\" to \"$slug-$MAX_DISCRIMINATOR\" is taken in $dir; nothing was written"
      return 5
    fi
    base="$(truncate_slug "$slug" $(( budget - ${#n} - 1 )))"
    if [ -z "$base" ]; then
      err "the discriminator -$n does not fit within a ${max}-character filename for \"$slug\""
      return 5
    fi
    candidate="$base-$n"
    n=$(( n + 1 ))
  done

  if [ "$slug_only" = "1" ]; then
    printf '%s\n' "$candidate"
  else
    printf '%s\n' "$dir/$candidate$RECORDING_SUFFIX"
  fi
  return 0
}

main "$@"
exit $?
