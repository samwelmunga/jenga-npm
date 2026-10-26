#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/commit-template.sh - the one function that turns a commit-format template into its validation regex and
# length budget  (epic E79, story E79_S03, task E79_S03_T02)
#
# A commit-format `template` such as `{ref} {summary}` is the single source of truth for what a board commit subject
# looks like. No regex is ever stored next to it, because a stored regex can disagree with its template (solution
# assessment Problem 12). Every caller asks this script instead, so the regex and the length budget are derived
# every time, by this one code path. It changes no config, no board file and no git state; it only reads its
# arguments and prints.
#
# Compatible with macOS bash 3.2; no jq, no timeout, no bash 4 feature. Lengths are counted in bytes (LC_ALL=C is
# forced), which is the conservative direction for a non-ASCII subject.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   commit-template.sh validate <template>
#   commit-template.sh derive   <template> [--ref-pattern <ere>] [--max-length <n>] [--ref <value>]
#   commit-template.sh match    <template> <subject> [--ref-pattern <ere>] [--max-length <n>]
#   commit-template.sh -h | --help          print this usage on stdout, exit 0
#
#   validate   exits 0 when the template is valid. Otherwise exits 3 with a specific message on stderr naming the
#              problem and, where it applies, the offending character and its 1-based position.
#   derive     prints exactly three key=value lines on stdout (and nothing else):
#                regex=<anchored POSIX ERE>
#                prefix_length=<n>        length of the rendered literals plus the ref
#                max_summary_length=<n>   max_length minus prefix_length, never below 0
#              Without --ref the budget assumes the longest ref this script allows (64 characters, MAX_REF);
#              with --ref it uses that ref's real length. For `{ref} {summary}` with the defaults that is
#              prefix_length=65, max_summary_length=7 without --ref, and prefix_length=8, max_summary_length=64
#              with --ref ASD-001.
#   match      exits 0 when <subject> conforms and prints nothing. Otherwise exits 1 and prints one reason on stdout:
#                too-long             the subject is over 200 characters (MAX_SUBJECT); no regex was run
#                no-match             the subject does not fit the template, or its ref is over 64 characters
#                summary-over-budget  the subject fits the template but is longer than max_length
#
#   The template, subject and option values are positional / separated arguments (`--ref-pattern <ere>`, never
#   `--ref-pattern=<ere>`), and each option may be given once. The template is always the first argument after the
#   subcommand, so a template that starts with "-" needs no special handling.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0  success / the subject conforms
#   1  match: the subject does not conform (reason on stdout)
#   2  usage error (unknown subcommand or option, missing or extra argument)
#   3  invalid template (message on stderr)
#   4  invalid option value: --ref-pattern, --max-length or --ref (message on stderr)
#   5  internal error (a derived regex failed to compile; this is a bug in this script)
#
# ---------------------------------------------------------------------------
# THE CLOSED GRAMMAR  (the template is data, never shell)
# ---------------------------------------------------------------------------
#   A template is literals plus two placeholders: {ref} (at most once) and {summary} (exactly once).
#   Literals are limited to an allowlist: ASCII letters, digits, space and  - _ : . , / # ( ) [ ] @
#   Rejected, each with a specific message: an empty template; a template over 80 characters (MAX_TEMPLATE); any
#   other character, including $ ` ; | & < > \ ' " * ? ^ + newline, tab and every other control character; any {...}
#   other than the two placeholders; an unbalanced { or }; {summary} missing or repeated; {ref} repeated.
#
#   The template is never handed to a shell, a command substitution, a dynamic-evaluation builtin or the source
#   builtin. It is read one character at a time and the characters are only ever compared, counted and appended to a
#   string. Literals are regex-escaped by the fixed table in escape_literal; {ref} and {summary} are replaced by
#   string substitution in scan_template. That substitution exists only here (a bats case greps the repository to
#   keep it that way).
#
# ---------------------------------------------------------------------------
# THE DERIVED REGEX  (an anchored POSIX ERE, no backtracking engine)
# ---------------------------------------------------------------------------
#   ^ <escaped literals> ( <ref_pattern> ) <escaped literals> <summary class> ... $
#   {ref} becomes the capture group ( <ref_pattern> ), always group 1 (literals add no groups, and the ref pattern's
#   own groups nest inside it), so the ref length can be checked after the match. {summary} becomes a fixed class: a
#   first character that is neither a control character nor whitespace, then any run of non-control characters.
#   The regex is only ever run through bash [[ =~ ]] (the C library's regcomp/regexec, a non-backtracking engine for
#   everything that is allowed here) or grep -E by a caller.
#
#   Defaults: --ref-pattern [A-Z][A-Z0-9]+-[0-9]+ (the Jira key shape), --max-length 72.
#
# ---------------------------------------------------------------------------
# BOUNDS  (checked before and around every regex run)
# ---------------------------------------------------------------------------
#   MAX_TEMPLATE 80    template length
#   MAX_SUBJECT  200   match subject length; longer returns `too-long` without touching the regex
#   MAX_REF      64    ref length (a --ref value, or the ref captured by a match)
#   MAX_REFPAT   100   --ref-pattern length
#   --max-length is an integer from 1 to 200.
#   --ref-pattern must be non-empty, single-line (no control character), contain no back-reference (a backslash
#   followed by a digit), compile as an ERE, and not match the empty string.
#   --ref must be 1 to 64 characters of [A-Za-z0-9._/-] and fully match the ref pattern (Problem 19: a ref taken from
#   a branch name is validated before it is used; here it is also only ever passed as a quoted argument).
# ---------------------------------------------------------------------------

set -u
export LC_ALL=C

readonly MAX_TEMPLATE=80
readonly MAX_SUBJECT=200
readonly MAX_REF=64
readonly MAX_REFPAT=100
readonly MAX_LENGTH_CAP=200
readonly DEFAULT_MAX_LENGTH=72
readonly DEFAULT_REF_PATTERN='[A-Z][A-Z0-9]+-[0-9]+'
readonly SUMMARY_CLASS='[^[:cntrl:][:space:]][^[:cntrl:]]*'

PROG="commit-template"

usage() {
  cat <<'EOF'
Usage:
  commit-template.sh validate <template>
  commit-template.sh derive   <template> [--ref-pattern <ere>] [--max-length <n>] [--ref <value>]
  commit-template.sh match    <template> <subject> [--ref-pattern <ere>] [--max-length <n>]
  commit-template.sh -h | --help

A template is literals plus {ref} (at most once) and {summary} (exactly once). Literals: letters, digits, space and
- _ : . , / # ( ) [ ] @   Defaults: --ref-pattern [A-Z][A-Z0-9]+-[0-9]+, --max-length 72.

Exit codes: 0 ok / conforms, 1 no match (reason on stdout: no-match, too-long, summary-over-budget), 2 usage error,
3 invalid template, 4 invalid option value, 5 internal error. See the header of this script for the full contract.
EOF
}

die_usage() {
  printf '%s: usage error: %s\n' "$PROG" "$1" >&2
  printf "Try '%s --help'.\n" "$PROG" >&2
  exit 2
}

fail_template() {
  printf '%s: invalid template: %s\n' "$PROG" "$1" >&2
  exit 3
}

fail_option() {
  printf '%s: invalid option value: %s\n' "$PROG" "$1" >&2
  exit 4
}

# describe_char <one byte> -> DESC: a printable form that is safe to put in a message.
describe_char() {
  local c="$1" code
  case "$c" in
    [[:print:]]) DESC="'$c'" ;;
    *)
      code=$(( $(printf '%d' "'$c") & 255 ))
      DESC="$(printf '0x%02x (a control or non-ASCII character)' "$code")"
      ;;
  esac
}

# escape_literal <one allowlisted character> -> ESC: the fixed escape table. Only the four characters of the
# allowlist that are special in an ERE need an entry; each becomes a one-character bracket expression, which is
# unambiguous in every regcomp. Anything else the grammar admits is an ordinary ERE character.
escape_literal() {
  case "$1" in
    '.') ESC='[.]' ;;
    '(') ESC='[(]' ;;
    ')') ESC='[)]' ;;
    '[') ESC='[[]' ;;
    ']') ESC='[]]' ;;
    [A-Za-z0-9]|' '|'-'|'_'|':'|','|'/'|'#'|'@') ESC="$1" ;;
    *) printf '%s: internal error: no escape for a character the grammar admitted\n' "$PROG" >&2; exit 5 ;;
  esac
}

# scan_template <template> <ref_pattern>
# Validates the template against the closed grammar and, in the same single pass, builds the derived regex.
# Sets REGEX, LITERAL_LEN (characters of literal text), HAS_REF (0 or 1). Exits 3 on the first problem found.
scan_template() {
  local t="$1" refpat="$2"
  local n=${#t} i=0 c rest after name body="" lit=0 refs=0 sums=0

  [ "$n" -gt 0 ] || fail_template "the template is empty"
  [ "$n" -le "$MAX_TEMPLATE" ] || fail_template "the template is $n characters; the maximum is $MAX_TEMPLATE"

  while [ "$i" -lt "$n" ]; do
    c="${t:$i:1}"
    case "$c" in
      '{')
        rest="${t:$i}"
        case "$rest" in
          '{ref}'*)
            refs=$(( refs + 1 ))
            [ "$refs" -le 1 ] || fail_template "{ref} appears twice (position $(( i + 1 ))); it may appear at most once"
            body="${body}(${refpat})"
            i=$(( i + 5 ))
            continue
            ;;
          '{summary}'*)
            sums=$(( sums + 1 ))
            [ "$sums" -le 1 ] || fail_template "{summary} appears twice (position $(( i + 1 ))); it must appear exactly once"
            body="${body}${SUMMARY_CLASS}"
            i=$(( i + 9 ))
            continue
            ;;
        esac
        after="${rest#?}"
        name="${after%%\}*}"
        if [ "$name" != "$after" ] && [ "${#name}" -le 20 ]; then
          case "$name" in
            *[!A-Za-z0-9_]*) ;;
            *) fail_template "unknown placeholder '{$name}' at position $(( i + 1 )); only {ref} and {summary} are allowed" ;;
          esac
        fi
        fail_template "unbalanced '{' at position $(( i + 1 )); a brace must open {ref} or {summary}"
        ;;
      '}')
        fail_template "unbalanced '}' at position $(( i + 1 ))"
        ;;
      [A-Za-z0-9]|' '|'-'|'_'|':'|'.'|','|'/'|'#'|'('|')'|'['|']'|'@')
        escape_literal "$c"
        body="${body}${ESC}"
        lit=$(( lit + 1 ))
        ;;
      *)
        describe_char "$c"
        fail_template "character $DESC at position $(( i + 1 )) is not allowed in a template literal (allowed: letters, digits, space and - _ : . , / # ( ) [ ] @)"
        ;;
    esac
    i=$(( i + 1 ))
  done

  [ "$sums" -ge 1 ] || fail_template "{summary} is missing; it must appear exactly once"

  REGEX="^${body}\$"
  LITERAL_LEN="$lit"
  HAS_REF="$refs"
}

# check_ref_pattern <ere>  (exits 4 on the first problem)
check_ref_pattern() {
  local p="$1" rc
  [ -n "$p" ] || fail_option "--ref-pattern is empty"
  [ "${#p}" -le "$MAX_REFPAT" ] || fail_option "--ref-pattern is ${#p} characters; the maximum is $MAX_REFPAT"
  case "$p" in
    *$'\n'*|*$'\r'*) fail_option "--ref-pattern must be a single line (it contains a newline)" ;;
    *[[:cntrl:]]*)   fail_option "--ref-pattern must not contain a control character" ;;
  esac
  case "$p" in
    *\\[0-9]*) fail_option "--ref-pattern must not contain a back-reference (a backslash followed by a digit)" ;;
  esac
  # An invalid ERE makes [[ =~ ]] return 2 (a plain non-match returns 1).
  { [[ "" =~ $p ]]; } 2>/dev/null
  rc=$?
  [ "$rc" -ne 2 ] || fail_option "--ref-pattern does not compile as a POSIX extended regular expression"
  local wrapped="^(${p})\$"
  { [[ "" =~ $wrapped ]]; } 2>/dev/null
  rc=$?
  [ "$rc" -ne 2 ] || fail_option "--ref-pattern does not compile as a POSIX extended regular expression once anchored"
  [ "$rc" -ne 0 ] || fail_option "--ref-pattern must not match the empty string"
}

# check_max_length <n>
check_max_length() {
  case "$1" in
    ''|*[!0-9]*|0*) fail_option "--max-length must be a whole number from 1 to $MAX_LENGTH_CAP (got '$1' as a non-number or a leading zero)" ;;
  esac
  [ "$1" -le "$MAX_LENGTH_CAP" ] || fail_option "--max-length is $1; the maximum is $MAX_LENGTH_CAP"
}

# check_ref <value> <ref_pattern>
check_ref() {
  local v="$1" pat="$2" wrapped rc
  [ -n "$v" ] || fail_option "--ref is empty"
  [ "${#v}" -le "$MAX_REF" ] || fail_option "--ref is ${#v} characters; the maximum is $MAX_REF"
  case "$v" in
    *[!A-Za-z0-9._/-]*) fail_option "--ref may contain only letters, digits and . _ / -" ;;
  esac
  wrapped="^(${pat})\$"
  { [[ "$v" =~ $wrapped ]]; } 2>/dev/null
  rc=$?
  [ "$rc" -eq 0 ] || fail_option "--ref '$v' does not match the ref pattern"
}

# ---------------------------------------------------------------------------
# argument handling
# ---------------------------------------------------------------------------
[ "$#" -ge 1 ] || die_usage "a subcommand is required (validate, derive or match)"

case "$1" in
  -h|--help|help) usage; exit 0 ;;
esac

SUB="$1"
shift
case "$SUB" in
  validate|derive|match) ;;
  *) die_usage "unknown subcommand '$SUB' (expected validate, derive or match)" ;;
esac

[ "$#" -ge 1 ] || die_usage "$SUB needs a <template> argument"
TEMPLATE="$1"
shift

SUBJECT=""
if [ "$SUB" = "match" ]; then
  [ "$#" -ge 1 ] || die_usage "match needs a <subject> argument after the template"
  SUBJECT="$1"
  shift
fi

REF_PATTERN="$DEFAULT_REF_PATTERN"
MAX_LENGTH="$DEFAULT_MAX_LENGTH"
REF_VALUE=""
GOT_REFPAT=0
GOT_MAXLEN=0
GOT_REF=0

while [ "$#" -gt 0 ]; do
  opt="$1"
  case "$opt" in
    --ref-pattern|--max-length|--ref)
      [ "$SUB" != "validate" ] || die_usage "validate takes no options (got $opt)"
      if [ "$opt" = "--ref" ] && [ "$SUB" != "derive" ]; then
        die_usage "--ref is only valid with derive"
      fi
      [ "$#" -ge 2 ] || die_usage "$opt needs a value"
      case "$opt" in
        --ref-pattern) [ "$GOT_REFPAT" -eq 0 ] || die_usage "--ref-pattern given twice"; GOT_REFPAT=1; REF_PATTERN="$2" ;;
        --max-length)  [ "$GOT_MAXLEN" -eq 0 ] || die_usage "--max-length given twice"; GOT_MAXLEN=1; MAX_LENGTH="$2" ;;
        --ref)         [ "$GOT_REF" -eq 0 ] || die_usage "--ref given twice"; GOT_REF=1; REF_VALUE="$2" ;;
      esac
      shift 2
      ;;
    *) die_usage "unknown or unexpected argument '$opt'" ;;
  esac
done

# Option values first (exit 4), then the template (exit 3), so each failure names the thing that is wrong.
check_ref_pattern "$REF_PATTERN"
check_max_length "$MAX_LENGTH"
if [ "$GOT_REF" -eq 1 ]; then
  check_ref "$REF_VALUE" "$REF_PATTERN"
fi

REGEX=""
LITERAL_LEN=0
HAS_REF=0
scan_template "$TEMPLATE" "$REF_PATTERN"

case "$SUB" in
  validate)
    exit 0
    ;;

  derive)
    if [ "$HAS_REF" -eq 1 ]; then
      if [ "$GOT_REF" -eq 1 ]; then
        ref_len="${#REF_VALUE}"
      else
        ref_len="$MAX_REF"
      fi
    else
      ref_len=0
    fi
    prefix=$(( LITERAL_LEN + ref_len ))
    budget=$(( MAX_LENGTH - prefix ))
    [ "$budget" -ge 0 ] || budget=0
    printf 'regex=%s\n' "$REGEX"
    printf 'prefix_length=%d\n' "$prefix"
    printf 'max_summary_length=%d\n' "$budget"
    exit 0
    ;;

  match)
    # The cap comes first: an oversized subject never reaches the regex.
    if [ "${#SUBJECT}" -gt "$MAX_SUBJECT" ]; then
      printf 'too-long\n'
      exit 1
    fi
    [[ "$SUBJECT" =~ $REGEX ]]
    rc=$?
    if [ "$rc" -eq 2 ]; then
      printf '%s: internal error: the derived regex did not compile\n' "$PROG" >&2
      exit 5
    fi
    if [ "$rc" -ne 0 ]; then
      printf 'no-match\n'
      exit 1
    fi
    if [ "$HAS_REF" -eq 1 ] && [ "${#BASH_REMATCH[1]}" -gt "$MAX_REF" ]; then
      printf 'no-match\n'
      exit 1
    fi
    if [ "${#SUBJECT}" -gt "$MAX_LENGTH" ]; then
      printf 'summary-over-budget\n'
      exit 1
    fi
    exit 0
    ;;
esac
