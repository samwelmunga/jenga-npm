#!/usr/bin/env bats
#
# E79_S03_T02: scripts/commit-template.sh turns a commit-format template into its regex and length budget.
#
# What this pins (one named case per acceptance criterion, plus the contract around them):
#   - validate / derive / match and their distinct exit codes (0 ok, 1 no match, 2 usage, 3 template, 4 option value);
#   - the closed grammar: every rejected form has its own specific message, with the offending character and position;
#   - the template is data: hostile templates create nothing and run nothing, and the script text contains no
#     dynamic evaluation, no sourcing and no template text in a command position (grep checks below);
#   - bounded matching: an oversized subject returns `too-long` without the regex running; a pathological ref
#     pattern on a 64-character candidate finishes well under 2 seconds;
#   - --ref-pattern and --ref validation;
#   - the derivation lives in one place only; the script is bash -n clean and uses no bash 4 feature.
#
# The script is always run as `bash <script>`, so these cases do not depend on the file's executable bit.
# Everything the cases create lives under $BATS_TEST_TMPDIR; nothing touches the board, config or git state.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/commit-template.sh"

setup() {
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK"
  cd "$WORK" || return 1
}

# ct <args...>: run the script, keeping stdout in $output and stderr in $stderr.
ct() {
  run --separate-stderr bash "$SCRIPT" "$@"
}

# has <haystack> <needle>: succeed when the needle occurs in the haystack, else print both.
has() {
  case "$1" in
    *"$2"*) return 0 ;;
  esac
  printf 'expected to find [%s] in [%s]\n' "$2" "$1" >&2
  return 1
}

# non_comment_lines: the script with comment-only lines removed (what the grep checks inspect).
non_comment_lines() {
  grep -vE '^[[:space:]]*#' "$SCRIPT"
}

# repeat <char> <n>
repeat() {
  head -c "$2" /dev/zero | tr '\0' "$1"
}

# now_ms: milliseconds since the epoch (perl ships with macOS and every CI image we use).
now_ms() {
  perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'
}

# --- validate / derive: the happy path ------------------------------------------------------------------------

@test "validate '{ref} {summary}' exits 0 and prints nothing" {
  ct validate '{ref} {summary}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "derive '{ref} {summary}' prints the anchored regex, prefix_length=65 and max_summary_length=7 (worst-case 64-char ref, 72 limit)" {
  ct derive '{ref} {summary}'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'regex=^([A-Z][A-Z0-9]+-[0-9]+) [^[:cntrl:][:space:]][^[:cntrl:]]*$' ]
  [ "${lines[1]}" = 'prefix_length=65' ]
  [ "${lines[2]}" = 'max_summary_length=7' ]
  [ "${#lines[@]}" -eq 3 ]
  [ -z "$stderr" ]
}

@test "derive with --ref ASD-001 uses the ref's real length: prefix_length=8, max_summary_length=64" {
  ct derive '{ref} {summary}' --ref ASD-001
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = 'prefix_length=8' ]
  [ "${lines[2]}" = 'max_summary_length=64' ]
}

@test "derive honours --max-length and --ref-pattern" {
  ct derive '{ref} {summary}' --ref ASD-001 --max-length 50
  [ "$status" -eq 0 ]
  [ "${lines[2]}" = 'max_summary_length=42' ]
  ct derive '{ref}: {summary}' --ref-pattern '[A-Z]+-[0-9]+' --ref AB-12
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'regex=^([A-Z]+-[0-9]+): [^[:cntrl:][:space:]][^[:cntrl:]]*$' ]
  [ "${lines[1]}" = 'prefix_length=7' ]
}

@test "derive without a {ref} counts only the literals" {
  ct derive 'fix: {summary}'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'regex=^fix: [^[:cntrl:][:space:]][^[:cntrl:]]*$' ]
  [ "${lines[1]}" = 'prefix_length=5' ]
  [ "${lines[2]}" = 'max_summary_length=67' ]
}

@test "derive clamps max_summary_length at 0 when the worst-case prefix leaves no room" {
  ct derive '{ref} {summary}' --max-length 40
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = 'prefix_length=65' ]
  [ "${lines[2]}" = 'max_summary_length=0' ]
}

@test "regex-special literals go through the fixed escape table and still match literally" {
  ct derive '[{ref}] ({summary}).'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'regex=^[[]([A-Z][A-Z0-9]+-[0-9]+)[]] [(][^[:cntrl:][:space:]][^[:cntrl:]]*[)][.]$' ]
  ct match '[{ref}] ({summary}).' '[ABC-12] (hello).'
  [ "$status" -eq 0 ]
  ct match '[{ref}] ({summary}).' '[ABC-12] hello.'
  [ "$status" -eq 1 ]
  [ "$output" = 'no-match' ]
  # '.' must be a literal dot, not "any character".
  ct match '[{ref}] ({summary}).' '[ABC-12] (hello)x'
  [ "$status" -eq 1 ]
}

@test "the {summary} may come before the {ref}, and a ref after the summary is still length-checked" {
  ct match '{summary} ({ref})' 'fix it (ABC-12)'
  [ "$status" -eq 0 ]
  ct match '{summary} ({ref})' 'fix it (abc-12)'
  [ "$status" -eq 1 ]
  [ "$output" = 'no-match' ]
}

@test "-h and --help print the usage on stdout and exit 0" {
  ct -h
  [ "$status" -eq 0 ]
  has "$output" 'commit-template.sh validate <template>'
  ct --help
  [ "$status" -eq 0 ]
  has "$output" 'commit-template.sh match'
}

# --- validate: rejections -------------------------------------------------------------------------------------

# reject <template> <expected stderr fragment>: validate exits 3 with that message and nothing on stdout.
reject() {
  ct validate "$1"
  [ "$status" -eq 3 ] || { printf 'status %s for [%s]\n' "$status" "$1" >&2; return 1; }
  [ -z "$output" ]
  has "$stderr" 'invalid template'
  has "$stderr" "$2"
}

@test "validate rejects a template with no {summary}" {
  reject '{ref}' '{summary} is missing'
  reject 'just words' '{summary} is missing'
}

@test "validate rejects {summary} twice and {ref} twice, naming the second position" {
  reject '{summary} {summary}' '{summary} appears twice (position 11)'
  reject '{ref} {ref} {summary}' '{ref} appears twice (position 7)'
}

@test "validate rejects a newline in the template, naming the character and its position" {
  reject $'{ref}\n{summary}' 'character 0x0a (a control or non-ASCII character) at position 6'
}

@test "validate rejects a tab and a non-ASCII character" {
  reject $'{ref}\t{summary}' 'character 0x09'
  reject '{ref} é {summary}' 'at position 7'
}

@test "validate rejects an unknown placeholder {foo}, an empty {} and an unbalanced brace" {
  reject '{foo} {summary}' "unknown placeholder '{foo}' at position 1"
  reject '{} {summary}' "unknown placeholder '{}' at position 1"
  reject '{ref {summary}' "unbalanced '{' at position 1"
  reject '{summary}}' "unbalanced '}' at position 10"
  reject '{{ref}} {summary}' "unbalanced '{' at position 1"
  reject '{summary' "unbalanced '{' at position 1"
}

@test "validate rejects the empty string" {
  reject '' 'the template is empty'
}

@test "validate rejects 81 characters and accepts exactly 80" {
  # {summary} is 9 characters, so 71 literals + {summary} = 80, and 72 + 9 = 81.
  ct validate "$(repeat a 71){summary}"
  [ "$status" -eq 0 ]
  reject "$(repeat a 72){summary}" 'the template is 81 characters; the maximum is 80'
}

@test "validate rejects each shell or regex metacharacter used as a literal, naming it and its position" {
  local c
  for c in '$' '`' ';' '|' '&' '<' '>' '\' '*' '?' "'" '"' '^' '+' '!' '%' '=' '~'; do
    reject "{ref} ${c} {summary}" "character '${c}' at position 7"
  done
}

@test "validate accepts every allowlisted literal character" {
  ct validate 'Az09 -_:.,/#()[]@{ref}{summary}'
  [ "$status" -eq 0 ]
}

# --- the template is data, never shell ---------------------------------------------------------------------------

@test "the hostile template '{ref} \$(touch PWNED) {summary}' is rejected and PWNED is never created" {
  local sub
  for sub in validate derive; do
    ct "$sub" '{ref} $(touch PWNED) {summary}'
    [ "$status" -eq 3 ]
    has "$stderr" "character '\$' at position 7"
  done
  ct match '{ref} $(touch PWNED) {summary}' 'ASD-001 add retry'
  [ "$status" -eq 3 ]
  [ ! -e PWNED ]
  [ ! -e "$WORK/PWNED" ]
  [ -z "$(ls -A "$WORK")" ]
}

@test "backtick and newline hostile forms are rejected and execute nothing" {
  ct validate '{ref} `touch PWNED` {summary}'
  [ "$status" -eq 3 ]
  has "$stderr" "character '\`' at position 7"
  ct validate $'{ref}\ntouch PWNED\n{summary}'
  [ "$status" -eq 3 ]
  ct validate $'{ref} {summary}\ntouch PWNED'
  [ "$status" -eq 3 ]
  ct validate '{ref} ; touch PWNED ; {summary}'
  [ "$status" -eq 3 ]
  [ -z "$(ls -A "$WORK")" ]
}

@test "hostile subject, ref and ref-pattern values are inert data too" {
  ct match '{ref} {summary}' '$(touch PWNED)'
  [ "$status" -eq 1 ]
  [ "$output" = 'no-match' ]
  ct match '{ref} {summary}' 'ASD-001 `touch PWNED`'
  [ "$status" -eq 0 ]
  ct derive '{ref} {summary}' --ref '$(touch PWNED)'
  [ "$status" -eq 4 ]
  ct derive '{ref} {summary}' --ref-pattern '$(touch PWNED)'
  [ "$status" -eq 0 ]
  ct derive '{ref} {summary}' --ref-pattern '`touch PWNED`'
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$WORK")" ]
}

@test "the script text has no dynamic evaluation, no sourcing, no backticks and no shell -c" {
  local hits
  hits="$(grep -nE '(^|[^A-Za-z_])eval([^A-Za-z_]|$)' "$SCRIPT" || true)"
  [ -z "$hits" ] || { printf 'eval found:\n%s\n' "$hits" >&2; return 1; }
  hits="$(non_comment_lines | grep -nE '(^|[;&|[:space:]])(source|\.)[[:space:]]+["$/~.]' || true)"
  [ -z "$hits" ] || { printf 'source found:\n%s\n' "$hits" >&2; return 1; }
  hits="$(non_comment_lines | grep -nE '(bash|sh|zsh)[[:space:]]+-c' || true)"
  [ -z "$hits" ] || { printf 'shell -c found:\n%s\n' "$hits" >&2; return 1; }
  hits="$(non_comment_lines | grep -n '`' || true)"
  [ -z "$hits" ] || { printf 'backtick found:\n%s\n' "$hits" >&2; return 1; }
}

@test "the only command substitution in the script is the fixed printf in describe_char" {
  local subs
  subs="$(non_comment_lines | grep -F '$(' | grep -vF '$((' || true)"
  [ "$(printf '%s\n' "$subs" | grep -c .)" -eq 1 ]
  has "$subs" "printf '0x%02x (a control or non-ASCII character)'"
}

@test "the template, subject and option values appear only as quoted data, never as a command" {
  local line hits
  # TEMPLATE is assigned from $1 and passed to scan_template as an argument; nothing else touches it.
  while IFS= read -r line; do
    case "$line" in
      'scan_template "$TEMPLATE" "$REF_PATTERN"') ;;
      *) printf 'unexpected use of TEMPLATE: %s\n' "$line" >&2; return 1 ;;
    esac
  done < <(non_comment_lines | grep -F '$TEMPLATE' | sed 's/^[[:space:]]*//')
  # No line starts a command with a variable expansion (which would execute its value).
  hits="$(non_comment_lines | grep -nE '^[[:space:]]*"?\$[A-Za-z_{(]' || true)"
  [ -z "$hits" ] || { printf 'expansion in command position:\n%s\n' "$hits" >&2; return 1; }
}

# --- match -------------------------------------------------------------------------------------------------------

@test "match accepts 'ASD-001 add retry' against '{ref} {summary}'" {
  ct match '{ref} {summary}' 'ASD-001 add retry'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "match rejects 'add retry' with no-match" {
  ct match '{ref} {summary}' 'add retry'
  [ "$status" -eq 1 ]
  [ "$output" = 'no-match' ]
}

@test "match rejects a lower-case ref 'asd-001 add retry' with no-match" {
  ct match '{ref} {summary}' 'asd-001 add retry'
  [ "$status" -eq 1 ]
  [ "$output" = 'no-match' ]
}

@test "match rejects a subject whose summary overruns the budget with summary-over-budget" {
  # ASD-001 + space = 8 characters, 72 - 8 = 64 allowed, so a 65-character summary overruns.
  ct match '{ref} {summary}' "ASD-001 $(repeat b 64)"
  [ "$status" -eq 0 ]
  ct match '{ref} {summary}' "ASD-001 $(repeat b 65)"
  [ "$status" -eq 1 ]
  [ "$output" = 'summary-over-budget' ]
  ct match '{ref} {summary}' "ASD-001 $(repeat b 40)" --max-length 30
  [ "$status" -eq 1 ]
  [ "$output" = 'summary-over-budget' ]
}

@test "match rejects a subject with a trailing newline or an embedded control character as no-match" {
  ct match '{ref} {summary}' $'ASD-001 add\nretry'
  [ "$status" -eq 1 ]
  [ "$output" = 'no-match' ]
  ct match '{ref} {summary}' $'ASD-001 add\tretry'
  [ "$status" -eq 1 ]
  [ "$output" = 'no-match' ]
}

@test "match rejects an empty summary and a leading-space summary as no-match" {
  ct match '{ref} {summary}' 'ASD-001 '
  [ "$status" -eq 1 ]
  ct match '{ref} {summary}' 'ASD-001  add'
  [ "$status" -eq 1 ]
  ct match '{ref} {summary}' 'ASD-001'
  [ "$status" -eq 1 ]
}

@test "match rejects a ref over 64 characters as no-match" {
  local ref
  ref="A$(repeat B 70)-1"
  ct match '{ref} {summary}' "$ref x" --max-length 200
  [ "$status" -eq 1 ]
  [ "$output" = 'no-match' ]
}

@test "match honours a custom --ref-pattern" {
  ct match '{ref} {summary}' '#123 add retry' --ref-pattern '#[0-9]+'
  [ "$status" -eq 0 ]
  ct match '{ref} {summary}' 'ASD-001 add retry' --ref-pattern '#[0-9]+'
  [ "$status" -eq 1 ]
}

@test "match with an invalid template reports exit 3 before looking at the subject" {
  ct match '{ref}' 'ASD-001 add retry'
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

# --- bounded matching ---------------------------------------------------------------------------------------------

@test "a 100000-character subject returns too-long in under 2 seconds" {
  local subject start end
  subject="$(repeat a 100000)"
  start="$(now_ms)"
  ct match '{ref} {summary}' "$subject"
  end="$(now_ms)"
  [ "$status" -eq 1 ]
  [ "$output" = 'too-long' ]
  [ $(( end - start )) -lt 2000 ]
}

@test "an oversized subject never reaches the regex (shown by the execution trace)" {
  local subject
  # A control: a 150-character subject IS matched, and the trace shows it in a [[ =~ ]] test.
  subject="$(repeat a 150)"
  run --separate-stderr bash -x "$SCRIPT" match '{ref} {summary}' "$subject"
  [ "$status" -eq 1 ]
  [ "$output" = 'no-match' ]
  [ "$(printf '%s\n' "$stderr" | grep -Ec '\[\[ a{150} =~ ')" -eq 1 ]
  # 201 characters (one over the cap): the subject appears in no regex test at all.
  subject="$(repeat a 201)"
  run --separate-stderr bash -x "$SCRIPT" match '{ref} {summary}' "$subject"
  [ "$status" -eq 1 ]
  [ "$output" = 'too-long' ]
  [ "$(printf '%s\n' "$stderr" | grep -Ec '\[\[ a{201} =~ ')" -eq 0 ]
  # Exactly 200 is still matched.
  subject="$(repeat a 200)"
  ct match '{ref} {summary}' "$subject"
  [ "$status" -eq 1 ]
  [ "$output" = 'no-match' ]
}

@test "a 64-character candidate against the ref pattern '(a+)+\$' completes in under 2 seconds" {
  local cand start end
  cand="$(repeat a 64)"
  start="$(now_ms)"
  ct match '{ref} {summary}' "$cand x" --ref-pattern '(a+)+$'
  [ "$status" -eq 1 ]
  [ "$output" = 'no-match' ]
  ct match '{summary} {ref}' "x $cand" --ref-pattern '(a+)+$'
  [ "$status" -eq 0 ]
  ct derive '{ref} {summary}' --ref "$cand" --ref-pattern '(a+)+$'
  [ "$status" -eq 0 ]
  ct derive '{ref} {summary}' --ref "${cand}b" --ref-pattern '(a+)+$'
  [ "$status" -eq 4 ]
  end="$(now_ms)"
  [ $(( end - start )) -lt 2000 ]
}

# --- --ref-pattern, --max-length and --ref validation ----------------------------------------------------------------

# reject_opt <expected stderr fragment> <args...>: exit 4 with that message and nothing on stdout.
reject_opt() {
  local frag="$1"
  shift
  ct "$@"
  [ "$status" -eq 4 ] || { printf 'status %s for [%s]\n' "$status" "$*" >&2; return 1; }
  [ -z "$output" ]
  has "$stderr" 'invalid option value'
  has "$stderr" "$frag"
}

@test "--ref-pattern is rejected when it does not compile as an ERE" {
  reject_opt 'does not compile' derive '{ref} {summary}' --ref-pattern '('
  reject_opt 'does not compile' derive '{ref} {summary}' --ref-pattern '['
  reject_opt 'does not compile' derive '{ref} {summary}' --ref-pattern '(a'
  reject_opt 'does not compile' match '{ref} {summary}' 'ASD-001 x' --ref-pattern '('
}

@test "--ref-pattern is rejected over 100 characters and accepted at exactly 100" {
  reject_opt 'is 101 characters' derive '{ref} {summary}' --ref-pattern "$(repeat a 101)"
  ct derive '{ref} {summary}' --ref-pattern "$(repeat a 100)"
  [ "$status" -eq 0 ]
}

@test "--ref-pattern is rejected when it contains a newline or another control character" {
  reject_opt 'single line' derive '{ref} {summary}' --ref-pattern $'a\nb'
  reject_opt 'single line' derive '{ref} {summary}' --ref-pattern $'a\rb'
  reject_opt 'control character' derive '{ref} {summary}' --ref-pattern $'a\tb'
}

@test "--ref-pattern is rejected when it contains a back-reference" {
  reject_opt 'back-reference' derive '{ref} {summary}' --ref-pattern '\1'
  reject_opt 'back-reference' derive '{ref} {summary}' --ref-pattern '(a)\1'
  reject_opt 'back-reference' match '{ref} {summary}' 'ASD-001 x' --ref-pattern '([A-Z]+)-\1'
}

@test "--ref-pattern is rejected when empty or when it can match the empty string" {
  reject_opt 'is empty' derive '{ref} {summary}' --ref-pattern ''
  reject_opt 'empty string' derive '{ref} {summary}' --ref-pattern 'a*'
  reject_opt 'empty string' derive '{ref} {summary}' --ref-pattern 'a?|b'
}

@test "--max-length must be a whole number from 1 to 200" {
  reject_opt '--max-length' derive '{ref} {summary}' --max-length 0
  reject_opt '--max-length' derive '{ref} {summary}' --max-length abc
  reject_opt '--max-length' derive '{ref} {summary}' --max-length 072
  reject_opt '--max-length' derive '{ref} {summary}' --max-length ''
  reject_opt '--max-length' derive '{ref} {summary}' --max-length -5
  reject_opt 'is 201' derive '{ref} {summary}' --max-length 201
  ct derive '{ref} {summary}' --max-length 200
  [ "$status" -eq 0 ]
  ct derive '{ref} {summary}' --max-length 1
  [ "$status" -eq 0 ]
}

@test "--ref is validated: characters, length and a full match of the ref pattern" {
  reject_opt '--ref may contain only' derive '{ref} {summary}' --ref 'ASD 001'
  reject_opt '--ref may contain only' derive '{ref} {summary}' --ref 'ASD-001;x'
  reject_opt "does not match the ref pattern" derive '{ref} {summary}' --ref 'asd-001'
  reject_opt "does not match the ref pattern" derive '{ref} {summary}' --ref 'ASD-001x'
  reject_opt 'is empty' derive '{ref} {summary}' --ref ''
  reject_opt 'is 65 characters' derive '{ref} {summary}' --ref "$(repeat A 65)" --ref-pattern 'A+'
  ct derive '{ref} {summary}' --ref "$(repeat A 64)" --ref-pattern 'A+'
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = 'prefix_length=65' ]
}

@test "an option value is checked even when the template has no {ref}" {
  reject_opt 'does not compile' derive 'fix: {summary}' --ref-pattern '('
}

# --- usage errors -----------------------------------------------------------------------------------------------------

@test "usage errors exit 2: no arguments, unknown subcommand, missing template, missing subject, bad options" {
  ct
  [ "$status" -eq 2 ]
  has "$stderr" 'usage error'
  ct frobnicate '{summary}'
  [ "$status" -eq 2 ]
  ct validate
  [ "$status" -eq 2 ]
  ct match '{summary}'
  [ "$status" -eq 2 ]
  ct validate '{summary}' --max-length 10
  [ "$status" -eq 2 ]
  ct derive '{summary}' --bogus
  [ "$status" -eq 2 ]
  ct derive '{summary}' --ref-pattern
  [ "$status" -eq 2 ]
  ct derive '{summary}' --max-length 5 --max-length 6
  [ "$status" -eq 2 ]
  ct match '{ref} {summary}' 'ASD-001 x' --ref ASD-001
  [ "$status" -eq 2 ]
  ct match '{summary}' 'x' extra
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "a template that starts with '-' is data, not an option" {
  ct validate '- {summary}'
  [ "$status" -eq 0 ]
  ct validate '--help {summary}'
  [ "$status" -eq 0 ]
  ct match '--help {summary}' '--help x'
  [ "$status" -eq 0 ]
}

# --- one implementation only ------------------------------------------------------------------------------------------

@test "no second implementation of the placeholder substitution exists in the repository" {
  local hits pat
  pat='(//?|s[/|#,]|replace\(|gsub\()[^ ]*\\?\{(ref|summary)\\?\}'
  # Canary: the pattern does detect the forms it is meant to forbid.
  printf '%s\n' 'x="${t//\{ref\}/ASD-1}"' > "$BATS_TEST_TMPDIR/canary1.sh"
  printf '%s\n' "sed 's/{summary}/add/'" > "$BATS_TEST_TMPDIR/canary2.sh"
  printf '%s\n' 'tpl.replace("{ref}", ref)' > "$BATS_TEST_TMPDIR/canary3.js"
  [ "$(grep -Ec "$pat" "$BATS_TEST_TMPDIR"/canary1.sh "$BATS_TEST_TMPDIR"/canary2.sh "$BATS_TEST_TMPDIR"/canary3.js | grep -c ':1$')" -eq 3 ]
  hits="$(grep -rEn --exclude-dir=node_modules --exclude=commit-template.sh "$pat" \
    "$REPO_ROOT/scripts" "$REPO_ROOT/skills" "$REPO_ROOT/hooks" "$REPO_ROOT/lib" "$REPO_ROOT/mcp" 2>/dev/null || true)"
  [ -z "$hits" ] || { printf 'second substitution found:\n%s\n' "$hits" >&2; return 1; }
}

# --- portability ------------------------------------------------------------------------------------------------------------

@test "the script passes bash -n" {
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the script uses no bash 4 feature" {
  local hits
  hits="$(non_comment_lines | grep -nE 'declare +-[A-Za-z]*A|mapfile|readarray|coproc|\$\{[A-Za-z_0-9]+(\^\^|,,)|&>>|\|&|;;?&|EPOCHREALTIME|BASHPID|\[\[ +-v ' || true)"
  [ -z "$hits" ] || { printf 'bash 4 feature found:\n%s\n' "$hits" >&2; return 1; }
}

@test "the script runs under /bin/bash (3.2 on macOS) and gives the same answers" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  run --separate-stderr /bin/bash "$SCRIPT" derive '{ref} {summary}' --ref ASD-001
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = 'prefix_length=8' ]
  run --separate-stderr /bin/bash "$SCRIPT" match '{ref} {summary}' 'ASD-001 add retry'
  [ "$status" -eq 0 ]
  run --separate-stderr /bin/bash "$SCRIPT" match '{ref} {summary}' 'add retry'
  [ "$status" -eq 1 ]
  [ "$output" = 'no-match' ]
}

@test "the script forces the C locale, so a UTF-8 caller locale gives the same answers" {
  LC_ALL=en_US.UTF-8 run --separate-stderr bash "$SCRIPT" match '{ref} {summary}' 'ASD-001 add retry'
  [ "$status" -eq 0 ]
  LC_ALL=en_US.UTF-8 run --separate-stderr bash "$SCRIPT" match '{ref} {summary}' 'asd-001 add retry'
  [ "$status" -eq 1 ]
}
