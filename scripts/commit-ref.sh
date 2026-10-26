#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/commit-ref.sh - the one safety gate every candidate commit ref must pass, and the extractor that finds a ref
# inside a branch name  (epic E79, story E79_S04, tasks E79_S04_T01 and E79_S04_T02)
#
# A commit ref (a tracker key such as ASD-001) can come from a board file, a story, an epic or a git branch name, so it
# is untrusted text on its way into a commit message. This script is the single place that decides whether a string may
# be used as a ref (solution assessment Problem 19, branch-derived ref injection). The resolution chain, the composer
# and every other caller route a candidate through it; nothing else re-implements the check.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   commit-ref.sh validate [--pattern <ere>] [--conventions <file>] [--]       the candidate is read from STDIN
#   commit-ref.sh extract  [--pattern <ere>] [--conventions <file>] [--]       the branch name is read from STDIN
#   commit-ref.sh -h | --help            print this usage on stdout, exit 0
#
#   validate   reads ONE candidate from stdin. When it passes, the ref is printed unchanged on stdout (followed by a
#              newline) and the exit status is 0. When it does not, nothing is printed on stdout, one reason line goes
#              to stderr and the exit status is 3. The reason never repeats the candidate: it may contain control
#              characters. One trailing line feed is tolerated so `printf '%s\n' "$ref" | commit-ref.sh validate`
#              works; nothing else outside the allowlist is.
#
#   The candidate is NEVER a positional argument and is never placed in a command string. A positional argument is a
#   usage error. This file has no dynamic-execution builtin, no shell-string invocation, no file inclusion and no unquoted
#   expansion of the value (a bats case greps for the first two).
#
# A ref passes only when ALL of these hold:
#   1. it is not empty;
#   2. it is at most the ref-length cap (64), a limit that scripts/commit-template.sh already enforces. The cap is READ
#      from that script (`derive '{ref}{summary}'` prints it as prefix_length, because the template has no literals), so
#      there is no second literal here;
#   3. every byte is one of  A-Z a-z 0-9 . _ / -  (the allowlist of Problem 19). A newline, carriage return, NUL or
#      any other control byte, a space, a quote and every shell metacharacter fail here;
#   4. it FULLY matches the ref pattern: anchored at both ends, `^(pattern)$`, in one bash `[[ =~ ]]` call with the
#      pattern held in a variable, so `ASD-001-extra` fails against the default pattern.
#
# THE PATTERN. In this order:
#   --pattern <ere>            wins when given;
#   the project's recorded     `commit-settings.sh show` (its ref_pattern, recorded value else schema default) when the
#   ref_pattern                project is opted in to the commit template;
#   the schema default         `commit-settings.sh default ref_pattern` otherwise (templates/conventions-schema.json, or
#                              JENGA_CONVENTIONS_SCHEMA). The default is never a literal in this file.
# --conventions <file> is handed to commit-settings.sh unchanged (tests, and callers that hold the path).
# A pattern is accepted only by scripts/commit-template.sh's own pattern check (non-empty, at most 100 characters, one
# line, no control character, no back-reference, compiles as a POSIX ERE, does not match the empty string); this script
# adds no second pattern validator. The allowlist in point 3 is applied whatever the pattern says, so it is an upper
# bound on what any pattern, however permissive, can let through.
#
# HOW THE CANDIDATE IS READ. Bash cannot hold a NUL byte in a variable and `$(...)` drops it silently, so stdin is read
# as bytes: `head -c` (at most cap+2 bytes, so an unbounded stream is never held) piped through `od` into a lowercase
# hex string. Every check up to point 3 runs on that hex string. Only after every byte is proven to be one of the
# allowlisted ASCII characters is the ref rebuilt, pair by pair, with printf -v from the proven pair.
#
# ---------------------------------------------------------------------------
# EXTRACT  (task E79_S04_T02; solution assessment Problem 8, Solution A)
# ---------------------------------------------------------------------------
#   extract    reads ONE branch name from stdin (for example the user's perceived branch, feature/ASD-001-foo) and prints
#              the FIRST ref found in it, then exits 0. A name with no ref (main, develop, release/2.4, HEAD, an empty
#              input) is "no key", not an error: exit 1, nothing printed. This script does not decide which branch to
#              look at (Jenga task branches, E##_S##_T##-slug, carry no key); the caller passes the name.
#
#   A branch name is untrusted data, exactly like a candidate ref. It travels on stdin only (a positional argument is a
#   usage error), is read as bytes and is never placed in a command string. Matching is bounded and is one call:
#   1. at most the subject cap commit-template.sh uses (its MAX_SUBJECT, 200) is accepted; longer input is rejected
#      (exit 3) before the pattern is applied to it. The cap is READ from commit-template.sh, not written a second time;
#   2. one trailing line feed is tolerated; any other control byte (an embedded line feed, a carriage return, NUL) is
#      rejected (exit 3): a git branch name cannot contain one, so what arrived is not a branch name;
#   3. the match is ONE bash `[[ =~ ]]` call with the pattern held in a variable and wrapped as
#      (start or a non-alphanumeric byte)(PATTERN)(a non-alphanumeric byte or end). There is no loop over candidates;
#      POSIX leftmost-longest picks the first key;
#   4. token boundary (the final choice for T02): a key must be preceded by the start of the name or a non-alphanumeric
#      character, and followed by the end or a non-alphanumeric character. So feature/ASD-001-foo, ASD-001,
#      bugfix/ASD-001 and user/jo/ASD-001_wip each yield ASD-001, while fix/xASD-001 and fix/ASD-0011x yield nothing;
#   5. several keys in one name (ASD-001-and-ASD-002): the first wins, the rest are ignored without an error;
#   6. the extracted text is then piped through `validate` with the same pattern, like any other candidate. A permissive
#      pattern that matches something outside the allowlist therefore gives exit 3 and prints nothing.
#   The pattern comes from --pattern, then the project's recorded ref_pattern, then the schema default, as for validate.
#   A success prints exactly one line.
#
# EXIT CODES
#   0  validate: the candidate passes (printed on stdout). extract: a ref was found and passed validate (printed)
#   1  extract only: the name holds no ref (nothing printed)
#   2  usage error (unknown subcommand or option, an option without its value, a positional argument)
#   3  the candidate is rejected (one reason line on stderr); extract: also an input over the cap, an input holding a
#      control byte, or an extracted value that failed validate
#   4  the pattern cannot be used: a bad --pattern, an invalid or unreadable conventions file, or no pattern available
#      (message on stderr). Never a pass. extract: also an unreadable input cap.
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile, ${var,,} or `&>>`). It writes no file and changes no
# config, board or git state.
# ---------------------------------------------------------------------------

set -u
export LC_ALL=C

PROG="commit-ref"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_SCRIPT="$here/commit-template.sh"
SETTINGS_SCRIPT="$here/commit-settings.sh"

usage() {
  cat <<'EOF'
Usage:
  commit-ref.sh validate [--pattern <ere>] [--conventions <file>] [--]     (the candidate is read from stdin)
  commit-ref.sh extract  [--pattern <ere>] [--conventions <file>] [--]     (the branch name is read from stdin)
  commit-ref.sh -h | --help

Exit codes: 0 passes / found (the ref is printed), 1 extract found no ref, 2 usage error, 3 candidate or input rejected
(reason on stderr), 4 the pattern cannot be used. See the header of this script for the full contract.
EOF
}

die_usage() {
  printf '%s: usage error: %s\n' "$PROG" "$1" >&2
  printf "Try '%s --help'.\n" "$PROG" >&2
  exit 2
}

reject() {
  printf '%s: rejected: %s\n' "$PROG" "$1" >&2
  exit 3
}

bad_pattern() {
  printf '%s: %s\n' "$PROG" "$1" >&2
  exit 4
}

[ "$#" -ge 1 ] || die_usage "a subcommand is required (validate or extract)"
SUB=""
case "$1" in
  -h|--help|help) usage; exit 0 ;;
  validate|extract) SUB="$1"; shift ;;
  *) die_usage "unknown subcommand '$1' (expected validate or extract)" ;;
esac

PATTERN=""
GOT_PATTERN=0
CONV=""
GOT_CONV=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pattern)
      [ "$#" -ge 2 ] || die_usage "--pattern needs a value"
      [ "$GOT_PATTERN" -eq 0 ] || die_usage "--pattern given twice"
      GOT_PATTERN=1
      PATTERN="$2"
      shift 2
      ;;
    --conventions)
      [ "$#" -ge 2 ] || die_usage "--conventions needs a file"
      [ "$GOT_CONV" -eq 0 ] || die_usage "--conventions given twice"
      GOT_CONV=1
      CONV="$2"
      shift 2
      ;;
    --)
      shift
      [ "$#" -eq 0 ] || die_usage "the candidate is read from stdin; a positional argument is not accepted"
      ;;
    -*)
      die_usage "unknown option '$1'"
      ;;
    *)
      die_usage "the candidate is read from stdin; a positional argument is not accepted"
      ;;
  esac
done

# --- the pattern -----------------------------------------------------------------------------------------------
if [ "$GOT_PATTERN" -eq 0 ]; then
  settings_args=()
  if [ "$GOT_CONV" -eq 1 ]; then
    settings_args=(--conventions "$CONV")
  fi
  shown="$(bash "$SETTINGS_SCRIPT" ${settings_args[@]+"${settings_args[@]}"} show 2>&1)"
  src=$?
  if [ "$src" -ne 0 ]; then
    printf '%s\n' "$shown" >&2
    bad_pattern "cannot read the project's commit settings, so no ref pattern is available"
  fi
  if [ -n "$shown" ]; then
    # `show` prints key=value lines; the value is data, taken after the FIRST "=" and never run.
    while IFS= read -r line; do
      case "$line" in
        ref_pattern=*) PATTERN="${line#ref_pattern=}"; GOT_PATTERN=1 ;;
      esac
    done <<< "$shown"
  fi
  if [ "$GOT_PATTERN" -eq 0 ]; then
    PATTERN="$(bash "$SETTINGS_SCRIPT" default ref_pattern 2>/dev/null)" || bad_pattern "no ref pattern is available: the schema supplies no default"
    GOT_PATTERN=1
  fi
fi

# The pattern check, and the ref-length cap, both come from commit-template.sh: derive with no --ref and a template
# with no literals prints prefix_length = the longest ref it allows.
derived="$(bash "$TEMPLATE_SCRIPT" derive '{ref}{summary}' --ref-pattern "$PATTERN" 2>&1)"
drc=$?
if [ "$drc" -ne 0 ]; then
  printf '%s\n' "$derived" >&2
  bad_pattern "the ref pattern cannot be used"
fi
MAX_REF=""
while IFS= read -r line; do
  case "$line" in
    prefix_length=*) MAX_REF="${line#prefix_length=}" ;;
  esac
done <<< "$derived"
case "$MAX_REF" in
  ''|*[!0-9]*|0*) bad_pattern "cannot read the ref length cap from commit-template.sh" ;;
esac

# --- extract: find the first ref inside a branch name ----------------------------------------------------------
if [ "$SUB" = "extract" ]; then
  # The input cap is the subject cap commit-template.sh enforces, READ from that script (never written a second time).
  # Anything unreadable fails closed.
  MAX_NAME="$(sed -n 's/^readonly MAX_SUBJECT=\([0-9][0-9]*\)$/\1/p' "$TEMPLATE_SCRIPT" 2>/dev/null)"
  case "$MAX_NAME" in
    ''|*[!0-9]*|0*) bad_pattern "cannot read the branch name length cap from commit-template.sh" ;;
  esac

  # Bytes, bounded: at most cap+2 (the cap, one trailing line feed, one byte more to prove it is over the cap).
  hex="$(head -c $(( MAX_NAME + 2 )) | od -An -v -tx1 | tr -d ' \n')"
  case "$hex" in
    *0a) hex="${hex%0a}" ;;
  esac
  case "$(( ${#hex} % 2 ))" in
    0) ;;
    *) reject "the input could not be read as whole bytes" ;;
  esac
  nbytes=$(( ${#hex} / 2 ))
  # No branch name at all (an empty input) holds no key: not an error.
  [ "$nbytes" -gt 0 ] || exit 1
  # The cap comes first: an oversized name never reaches the pattern.
  [ "$nbytes" -le "$MAX_NAME" ] || reject "the branch name is longer than $MAX_NAME characters"

  # Rebuild the name pair by pair. A control byte (00-1f, 7f) cannot be in a branch name: reject it, so a newline or a
  # NUL can never turn one input into two lines or hide in the text. $pair is two hex digits from od, so the printf
  # format below is fixed text.
  name=""
  rest="$hex"
  while [ -n "$rest" ]; do
    pair="${rest%"${rest#??}"}"
    rest="${rest#??}"
    case "$pair" in
      0[0-9a-f]|1[0-9a-f]|7f) reject "the input contains a control character, so it is not a branch name" ;;
    esac
    printf -v ch "\\x$pair"
    name="$name$ch"
  done

  # ONE match, the pattern in a variable. Group 2 is the user's pattern wrapped in its own group, so it is the key
  # whatever groups the pattern holds. Token boundary: start or a non-alphanumeric byte before, a non-alphanumeric
  # byte or the end after.
  re="(^|[^A-Za-z0-9])(${PATTERN})([^A-Za-z0-9]|\$)"
  [[ "$name" =~ $re ]]
  mrc=$?
  if [ "$mrc" -eq 2 ]; then
    bad_pattern "the ref pattern did not compile once wrapped for extraction"
  fi
  [ "$mrc" -eq 0 ] || exit 1
  found="${BASH_REMATCH[2]}"

  # The found text is a candidate like any other: it goes through validate, with the same pattern, by stdin.
  checked="$(printf '%s\n' "$found" | bash "${BASH_SOURCE[0]}" validate --pattern "$PATTERN" 2>/dev/null)"
  vrc=$?
  case "$vrc" in
    0) ;;
    3) reject "the ref found in the branch name failed the ref safety gate" ;;
    *) bad_pattern "the ref safety gate could not be applied to the ref found in the branch name" ;;
  esac
  printf '%s\n' "$checked"
  exit 0
fi

# --- the candidate ---------------------------------------------------------------------------------------------
# At most cap+2 bytes: room for the cap, one trailing line feed, and one byte more to prove it is over the cap.
hex="$(head -c $(( MAX_REF + 2 )) | od -An -v -tx1 | tr -d ' \n')"

# One trailing line feed is tolerated.
case "$hex" in
  *0a) hex="${hex%0a}" ;;
esac
# od prints whole bytes, so the length is even; refuse anything else rather than guess.
case "$(( ${#hex} % 2 ))" in
  0) ;;
  *) reject "the input could not be read as whole bytes" ;;
esac

nbytes=$(( ${#hex} / 2 ))
[ "$nbytes" -gt 0 ] || reject "the ref is empty"
[ "$nbytes" -le "$MAX_REF" ] || reject "the ref is longer than $MAX_REF characters"

# Every byte must be one of A-Z a-z 0-9 . _ / -  (hex 2d 2e 2f 30-39 41-5a 5f 61-7a). Anything else, including NUL (00),
# line feed (0a) and carriage return (0d), fails here.
ref=""
rest="$hex"
while [ -n "$rest" ]; do
  pair="${rest%"${rest#??}"}"
  rest="${rest#??}"
  case "$pair" in
    2d|2e|2f|3[0-9]|4[1-9a-f]|5[0-9a]|5f|6[1-9a-f]|7[0-9a]) ;;
    *) reject "the ref contains a character outside A-Z a-z 0-9 . _ / -" ;;
  esac
  # $pair is now one of the allowlisted pairs, so this format string is fixed ASCII text.
  printf -v ch "\\x$pair"
  ref="$ref$ch"
done

# Full match: anchored at both ends, one call, the pattern in a variable (never in a command string).
re="^(${PATTERN})\$"
[[ "$ref" =~ $re ]]
mrc=$?
if [ "$mrc" -eq 2 ]; then
  bad_pattern "the ref pattern did not compile once anchored"
fi
[ "$mrc" -eq 0 ] || reject "the ref does not fully match the ref pattern"

printf '%s\n' "$ref"
exit 0
