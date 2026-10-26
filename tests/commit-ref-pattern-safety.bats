#!/usr/bin/env bats
#
# E79_S04_T03: permissive and hostile ref_pattern values are neutralised by the existing gate.
#
# Question (follow-up (c) of the E79_S03 summary): the ref_pattern a project records is stored as the user wrote it,
# so should it be restricted further at write time? These cases are the evidence for the answer. They run permissive
# patterns, hostile pattern text and hostile branch names through the two subcommands that every ref passes
# (scripts/commit-ref.sh validate and extract) and pin what the gate guarantees whatever the pattern says:
#
#   - a ref is printed only when it is one line, at most 64 characters, and made only of A-Z a-z 0-9 . _ / - ;
#   - anything else prints nothing, with an exit code that tells the three cases apart:
#       1 = the name holds no ref, 3 = rejected, 4 = the pattern cannot be used;
#   - nothing in the input or in the pattern text is ever executed (a canary file stays absent);
#   - a pattern that matches the empty string is not "no ref": it is unusable (exit 4), at the gate and at write time;
#   - a pattern that matches a whole name longer than the 64-character ref cap is rejected (exit 3);
#   - catastrophic-backtracking patterns finish well inside a stated bound, asserted with a bounded wait written in bash
#     (GNU timeout is not installed on macOS);
#   - an alternation in a pattern cannot step over the token-boundary rule of extract;
#   - what the gate does NOT promise is pinned too: it promises an alphabet and a length, not a shape, so a permissive
#     pattern can let a leading dash or a dot-dot through (the default pattern cannot). A composer must therefore put the
#     ref in message text, never alone in an argv position.
#
# These cases only read the scripts under test and the real configs; nothing under tests/fixtures is touched. Hostile
# strings use a RELATIVE file name (pwned) so a pattern stays under its 100-character cap; every case runs inside
# $WORK, a scratch directory under $BATS_TEST_TMPDIR, so a successful injection would leave $WORK/pwned behind.
#
# The script is always run as `bash <script>`, so these cases do not depend on the file's executable bit.
# These cases were written without being executed by their author; the tester runs them.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/commit-ref.sh"
VALIDATOR="$REPO_ROOT/scripts/validate-conventions.sh"
REAL_CONFIGS="$REPO_ROOT/project/configs"

# The permissive patterns the task names, plus a printable-anything one. The ones that match the empty string
# (".*", "^") are covered separately: they never reach a ref.
PERMISSIVE_NONEMPTY=('.+' '[^ ]+' '[A-Za-z0-9._/;$ -]+' '[[:print:]]+')
PERMISSIVE_EMPTY=('.*' '^' '$' 'x*' 'x?')

setup() {
  REAL_SUM="$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)"
  export LC_ALL=C
  unset JENGA_CONVENTIONS_SCHEMA
  PROJ="$BATS_TEST_TMPDIR/proj"
  CFG="$PROJ/project/configs"
  CONV="$CFG/conventions.json"
  INPUT="$BATS_TEST_TMPDIR/input.bin"
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$CFG" "$WORK"
  printf '{}\n' > "$CFG/workflow.json"
  export JENGA_PROJECT_ROOT="$PROJ"
  cd "$WORK" || return 1
}

teardown() {
  [ "$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)" = "$REAL_SUM" ]
}

# --- helpers ---------------------------------------------------------------------------------------------------

# runsub <validate|extract> <text> [args...]: run the subcommand with exactly these bytes (no trailing newline) on stdin.
runsub() {
  local sub="$1" text="$2"
  shift 2
  printf '%s' "$text" > "$INPUT"
  run --separate-stderr bash "$SCRIPT" "$sub" "$@" < "$INPUT"
}

# runsubf <validate|extract> <printf-format> [args...]: like runsub, bytes from a printf format (control bytes, NUL).
runsubf() {
  local sub="$1" fmt="$2"
  shift 2
  printf "$fmt" > "$INPUT"
  run --separate-stderr bash "$SCRIPT" "$sub" "$@" < "$INPUT"
}

# safe_result: the last run is one of the only outcomes the gate allows. Exit 0 prints exactly one line of 1 to 64
# characters from the allowlist; exit 1, 3 and 4 print nothing on stdout; any other exit status fails.
safe_result() {
  case "$status" in
    0)
      [ -n "$output" ]
      [ "${#output}" -le 64 ]
      case "$output" in
        *[!A-Za-z0-9._/-]*) return 1 ;;
      esac
      ;;
    1|3|4)
      [ -z "$output" ]
      ;;
    *)
      return 1
      ;;
  esac
}

no_canary() {
  [ ! -e "$WORK/pwned" ]
}

# base_json: an opted-in conventions.json with only the minimum recorded.
base_json() {
  cat <<'JSON'
{
  "conventions_version": 1,
  "categories": {
    "commit-format": {
      "source": "custom",
      "summary": "ref first",
      "values": { "style": "ref-first", "template": "{ref} {summary}", "apply_to_board_commits": true }
    }
  }
}
JSON
}

# write_pattern <ere>: record that ref_pattern in the scratch project's conventions.json (the text goes in as jq data).
write_pattern() {
  base_json | jq --arg p "$1" '.categories["commit-format"].values.ref_pattern = $p' > "$CONV"
}

# run_bounded <seconds> <command...>: run the command with $INPUT on stdin, outputs in $BOUT / $BERR, and set BSTATUS to
# its exit status, or to "timeout" when it was still running after <seconds> (it is then killed). A bounded wait in
# plain bash: polling a process this test itself started, every 0.1 s, never GNU timeout.
run_bounded() {
  local limit="$1" pid i=0 max
  shift
  max=$(( limit * 10 ))
  BOUT="$BATS_TEST_TMPDIR/bounded.out"
  BERR="$BATS_TEST_TMPDIR/bounded.err"
  BSTATUS=0
  "$@" < "$INPUT" > "$BOUT" 2> "$BERR" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge "$max" ]; then
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      BSTATUS="timeout"
      return 0
    fi
    sleep 0.1
    i=$(( i + 1 ))
  done
  wait "$pid" || BSTATUS=$?
  return 0
}

# bounded_safe: the last run_bounded finished in time with one of the allowed outcomes (exit 0, 1, 3 or 4), printing
# either nothing or one safe ref.
bounded_safe() {
  [ "$BSTATUS" != "timeout" ]
  case "$BSTATUS" in
    0|1|3|4) ;;
    *) return 1 ;;
  esac
  local out
  out="$(cat "$BOUT")"
  if [ "$BSTATUS" -eq 0 ]; then
    [ -n "$out" ]
    [ "${#out}" -le 64 ]
    case "$out" in
      *[!A-Za-z0-9._/-]*) return 1 ;;
    esac
  else
    [ -z "$out" ]
  fi
}

# rep <char> <n>: n copies of one character.
rep() {
  head -c "$2" /dev/zero | tr '\000' "$1"
}

# --- permissive patterns against hostile text -------------------------------------------------------------------

# One test per pattern. Every name below is hostile text (a shell metacharacter, a quote, an expansion); the result is
# either one allowlisted ref or nothing, never anything else, and nothing runs.
hostile_names() {
  printf '%s\n' \
    'a;touch pwned;b' \
    'a&&touch pwned' \
    'a|touch pwned' \
    'x$(touch pwned)y' \
    'x`touch pwned`y' \
    "a'b" \
    'a"b' \
    'a b' \
    'a>pwned' \
    'a<b' \
    'a*b' \
    'a\b' \
    'a%sb' \
    'a{b,c}' \
    'a$HOME' \
    'a!b' \
    'a#b' \
    'a~b'
}

@test "permissive pattern .+ : no hostile name yields anything outside the allowlist, and nothing runs" {
  local name
  while IFS= read -r name; do
    runsub extract "$name" --pattern '.+'
    safe_result
    no_canary
    runsub validate "$name" --pattern '.+'
    safe_result
    no_canary
  done < <(hostile_names)
}

@test "permissive pattern [^ ]+ : no hostile name yields anything outside the allowlist, and nothing runs" {
  local name
  while IFS= read -r name; do
    runsub extract "$name" --pattern '[^ ]+'
    safe_result
    no_canary
    runsub validate "$name" --pattern '[^ ]+'
    safe_result
    no_canary
  done < <(hostile_names)
}

@test "permissive pattern with a semicolon, a dollar sign and a space in its class: no hostile name yields anything outside the allowlist" {
  local name
  while IFS= read -r name; do
    runsub extract "$name" --pattern '[A-Za-z0-9._/;$ -]+'
    safe_result
    no_canary
    runsub validate "$name" --pattern '[A-Za-z0-9._/;$ -]+'
    safe_result
    no_canary
  done < <(hostile_names)
}

@test "permissive pattern [[:print:]]+ : no hostile name yields anything outside the allowlist" {
  local name
  while IFS= read -r name; do
    runsub extract "$name" --pattern '[[:print:]]+'
    safe_result
    no_canary
    runsub validate "$name" --pattern '[[:print:]]+'
    safe_result
    no_canary
  done < <(hostile_names)
}

@test "validate: a candidate holding any unsafe character is rejected with exit 3 whatever the permissive pattern, and prints nothing" {
  local p name
  for p in "${PERMISSIVE_NONEMPTY[@]}"; do
    for name in 'a;b' 'a b' 'a$b' 'a`b`' "a'b" 'a|b' 'a>b'; do
      runsub validate "$name" --pattern "$p"
      [ "$status" -eq 3 ]
      [ -z "$output" ]
      [ -n "$stderr" ]
    done
  done
}

@test "a permissive pattern prints an ordinary branch name as it is, when every character is allowlisted" {
  runsub extract 'feature/ASD-001-foo' --pattern '.+'
  [ "$status" -eq 0 ]
  [ "$output" = 'feature/ASD-001-foo' ]
  runsub extract 'feature/ASD-001-foo' --pattern '[^ ]+'
  [ "$status" -eq 0 ]
  [ "$output" = 'feature/ASD-001-foo' ]
  runsub validate 'feature/ASD-001-foo' --pattern '.+'
  [ "$status" -eq 0 ]
  [ "$output" = 'feature/ASD-001-foo' ]
}

@test "a permissive pattern cannot turn the unsafe tail of a name into part of the ref: [^ ]+ stops at the space" {
  runsub extract 'foo bar' --pattern '[^ ]+'
  [ "$status" -eq 0 ]
  [ "$output" = 'foo' ]
  runsub extract 'a/b c/d' --pattern '[^ ]+'
  [ "$status" -eq 0 ]
  [ "$output" = 'a/b' ]
}

@test "control bytes in a name are rejected with exit 3 and nothing printed, whatever the permissive pattern" {
  local p fmt
  for p in '.+' '[^ ]+' '[A-Za-z0-9._/;$ -]+' '[[:print:]]+'; do
    for fmt in 'a\nb' 'a\rb' 'a\000b' 'a\tb' 'a\033[31mb' 'a\177b' 'a\nb;touch pwned'; do
      runsubf extract "$fmt" --pattern "$p"
      [ "$status" -eq 3 ]
      [ -z "$output" ]
      runsubf validate "$fmt" --pattern "$p"
      [ "$status" -eq 3 ]
      [ -z "$output" ]
      no_canary
    done
  done
}

# --- the three outcomes have three exit codes -------------------------------------------------------------------

@test "exit codes tell the cases apart: no ref is 1, rejected is 3, an unusable pattern is 4" {
  # no ref: nothing for the pattern to match
  runsub extract '' --pattern '.+'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  runsub extract '   ' --pattern '[^ ]+'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  # rejected: a match was found but is not a safe ref
  runsub extract 'a;b' --pattern '.+'
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
  # unusable: the pattern itself
  runsub extract 'a;b' --pattern '.*'
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
}

# --- patterns that match the empty string -----------------------------------------------------------------------

@test "a pattern that can match the empty string is unusable (exit 4), never a pass and never 'no ref', for validate and extract" {
  local p
  for p in "${PERMISSIVE_EMPTY[@]}"; do
    runsub extract 'feature/ASD-001-foo' --pattern "$p"
    [ "$status" -eq 4 ]
    [ -z "$output" ]
    [ -n "$stderr" ]
    runsub extract 'a;touch pwned' --pattern "$p"
    [ "$status" -eq 4 ]
    [ -z "$output" ]
    runsub validate 'ASD-001' --pattern "$p"
    [ "$status" -eq 4 ]
    [ -z "$output" ]
    runsub validate 'a;b' --pattern "$p"
    [ "$status" -eq 4 ]
    [ -z "$output" ]
    no_canary
  done
}

@test "an empty input is never a ref: extract reports no ref (exit 1), validate rejects (exit 3)" {
  runsub extract '' --pattern '[A-Z]+'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  runsub validate '' --pattern '.+'
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "write time already refuses a recorded pattern that matches the empty string, so .* and ^ never reach a commit" {
  command -v python3 >/dev/null 2>&1 || skip "python3 is not installed (validate-conventions.sh needs it)"
  local p
  for p in '.*' '^' '$'; do
    write_pattern "$p"
    run --separate-stderr bash "$VALIDATOR" "$CONV"
    [ "$status" -eq 1 ]
    case "$output" in
      FAIL*) ;;
      *) false ;;
    esac
    case "$stderr" in
      *"empty string"*) ;;
      *) false ;;
    esac
    # and the gate refuses it too: the project's settings are unreadable, so no pattern is available (exit 4, not a pass)
    runsub validate 'ASD-001' --conventions "$CONV"
    [ "$status" -eq 4 ]
    [ -z "$output" ]
  done
}

# --- a recorded permissive pattern -------------------------------------------------------------------------------

@test "a recorded permissive pattern (.+) is accepted at write time and neutralised at use" {
  command -v python3 >/dev/null 2>&1 || skip "python3 is not installed (validate-conventions.sh needs it)"
  write_pattern '.+'
  run --separate-stderr bash "$VALIDATOR" "$CONV"
  [ "$status" -eq 0 ]
  runsub validate 'ABC-1' --conventions "$CONV"
  [ "$status" -eq 0 ]
  [ "$output" = 'ABC-1' ]
  runsub validate 'a;touch pwned' --conventions "$CONV"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  runsub extract 'a;touch pwned' --conventions "$CONV"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  no_canary
}

@test "a recorded pattern containing shell syntax is data: nothing runs, and any outcome is still safe" {
  local p
  for p in 'A-[0-9]+|$(touch pwned)' 'A-[0-9]+|`touch pwned`' "A-[0-9]+|'; touch pwned; echo '" 'A-[0-9]+;touch pwned'; do
    write_pattern "$p"
    runsub extract 'feature/A-1' --conventions "$CONV"
    case "$status" in
      0|1|3|4) ;;
      *) false ;;
    esac
    safe_result
    runsub validate 'A-1' --conventions "$CONV"
    safe_result
    no_canary
  done
}

@test "a pattern given with --pattern that contains shell syntax is data: nothing runs, and any outcome is still safe" {
  local p
  for p in 'A$(touch pwned)' 'A`touch pwned`' 'A;touch pwned' 'A-[0-9]+|$(touch pwned)' "A'; touch pwned; echo '"; do
    runsub extract 'feature/A-1' --pattern "$p"
    safe_result
    runsub validate 'A-1' --pattern "$p"
    safe_result
    no_canary
  done
}

# --- the 64-character cap ---------------------------------------------------------------------------------------

@test "a pattern that matches the whole name is rejected (exit 3) when the name is longer than the 64-character ref cap" {
  local n64 n65 n70
  n64="$(rep x 64)"
  n65="$(rep x 65)"
  n70="$(rep x 70)"
  runsub extract "$n64" --pattern '.+'
  [ "$status" -eq 0 ]
  [ "$output" = "$n64" ]
  runsub extract "$n65" --pattern '.+'
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  runsub extract "$n70" --pattern '.+'
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  runsub extract "feature/$n70" --pattern '.+'
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  runsub extract "$n70" --pattern '[a-z]+'
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  runsub extract "$n70" --pattern '[^ ]+'
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "validate holds the same cap under a permissive pattern: 64 passes, 65 is rejected" {
  local n64 n65
  n64="$(rep x 64)"
  n65="$(rep x 65)"
  runsub validate "$n64" --pattern '.+'
  [ "$status" -eq 0 ]
  [ "$output" = "$n64" ]
  runsub validate "$n65" --pattern '.+'
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "a long name with no key-shaped text holds no key even when it is far over the cap" {
  runsub extract "feature/$(rep x 70)" --pattern '[A-Z]+-[0-9]+'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# --- catastrophic backtracking -----------------------------------------------------------------------------------

# Names at the 200-character cap for extract: 199 letters plus a last character that makes a match fail late (b, !),
# and 200 letters. validate cannot be fed more than 66 bytes, so for it the cap rejects first and the pattern is not
# applied; both are checked.
@test "backtracking-family patterns against 200-character names finish within 5 seconds and print nothing unsafe" {
  local a199 name p start elapsed
  a199="$(rep a 199)"
  start="$SECONDS"
  for p in '(a|aa)+$' '(a+)+$' '(a*)*b' '([a-z]+)*[0-9]' '(.*)*x' '(.+)+!'; do
    for name in "${a199}b" "${a199}!" "${a199}a"; do
      printf '%s' "$name" > "$INPUT"
      run_bounded 5 bash "$SCRIPT" extract --pattern "$p"
      bounded_safe
      no_canary
    done
  done
  elapsed=$(( SECONDS - start ))
  # 18 runs, each bounded to 5 seconds above; the whole sweep is bounded too, so a slow-but-finishing engine is noticed.
  [ "$elapsed" -lt 90 ]
}

@test "the bounded wait itself works: a process that outlives the bound is reported as a timeout and killed" {
  printf '' > "$INPUT"
  run_bounded 1 sleep 3
  [ "$BSTATUS" = "timeout" ]
  run_bounded 2 true
  [ "$BSTATUS" = "0" ]
  run_bounded 2 false
  [ "$BSTATUS" = "1" ]
}

@test "the textbook (a|aa)+ backtracking pattern against a 200-character name finishes inside the bound, by itself, with the elapsed time asserted" {
  local name start elapsed
  name="$(rep a 199)!"
  printf '%s' "$name" > "$INPUT"
  start="$SECONDS"
  run_bounded 5 bash "$SCRIPT" extract --pattern '(a|aa)+$'
  elapsed=$(( SECONDS - start ))
  [ "$BSTATUS" != "timeout" ]
  [ "$elapsed" -lt 5 ]
  # nothing matches a name that ends in !, so this is "no ref"
  [ "$BSTATUS" = "1" ]
  [ ! -s "$BOUT" ]
}

@test "a backtracking pattern against an over-cap name is rejected before the pattern runs, fast" {
  printf '%s' "$(rep a 201)" > "$INPUT"
  run_bounded 5 bash "$SCRIPT" extract --pattern '(a|aa)+$'
  [ "$BSTATUS" = "3" ]
  [ ! -s "$BOUT" ]
  printf '%s' "$(rep a 400)b" > "$INPUT"
  run_bounded 5 bash "$SCRIPT" validate --pattern '(a|aa)+$'
  [ "$BSTATUS" = "3" ]
  [ ! -s "$BOUT" ]
}

@test "a backtracking pattern against a 64-character candidate to validate finishes inside the bound" {
  printf '%s' "$(rep a 63)b" > "$INPUT"
  run_bounded 5 bash "$SCRIPT" validate --pattern '(a|aa)+$'
  [ "$BSTATUS" = "3" ]
  [ ! -s "$BOUT" ]
  printf '%s' "$(rep a 64)" > "$INPUT"
  run_bounded 5 bash "$SCRIPT" validate --pattern '(a|aa)+$'
  [ "$BSTATUS" = "0" ]
  [ "$(cat "$BOUT")" = "$(rep a 64)" ]
}

# --- alternation and the token-boundary rule ---------------------------------------------------------------------

@test "an alternation cannot find a key that breaks the boundary rule: A|AB in ABC holds no key" {
  runsub extract 'ABC' --pattern 'A|AB'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  runsub extract 'xAB' --pattern 'A|AB'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "an alternation whose short branch fails the trailing boundary falls to the branch that satisfies it" {
  runsub extract 'AB' --pattern 'A|AB'
  [ "$status" -eq 0 ]
  [ "$output" = 'AB' ]
  runsub extract 'AB-x' --pattern 'A|AB'
  [ "$status" -eq 0 ]
  [ "$output" = 'AB' ]
  runsub extract 'ASD-12' --pattern 'ASD-[0-9]|ASD-[0-9]+'
  [ "$status" -eq 0 ]
  [ "$output" = 'ASD-12' ]
}

@test "a top-level alternation does not escape the wrapper: foo is not a key inside xfoo, ASD-1 still is" {
  runsub extract 'xfoo/ASD-1' --pattern 'foo|ASD-1'
  [ "$status" -eq 0 ]
  [ "$output" = 'ASD-1' ]
  runsub extract 'xfoo' --pattern 'foo|ASD-1'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  runsub extract 'foox' --pattern 'foo|ASD-1'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "an anchor inside one branch of an alternation is honoured: a caret only at the start of the name, a dollar only at its end" {
  runsub extract 'feature/ASD-1' --pattern '^ASD-[0-9]+|BRN-[0-9]+'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  runsub extract 'feature/BRN-2' --pattern '^ASD-[0-9]+|BRN-[0-9]+'
  [ "$status" -eq 0 ]
  [ "$output" = 'BRN-2' ]
  runsub extract 'ASD-1/x' --pattern '^ASD-[0-9]+|BRN-[0-9]+'
  [ "$status" -eq 0 ]
  [ "$output" = 'ASD-1' ]
  runsub extract 'ASD-1/x' --pattern 'ASD-1$|ASD-2'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  runsub extract 'ASD-1' --pattern 'ASD-1$|ASD-2'
  [ "$status" -eq 0 ]
  [ "$output" = 'ASD-1' ]
}

@test "validate fully matches an alternation: A|AB accepts AB and rejects ABC, ASD|ASD-001 rejects ASD-0" {
  runsub validate 'AB' --pattern 'A|AB'
  [ "$status" -eq 0 ]
  [ "$output" = 'AB' ]
  runsub validate 'ABC' --pattern 'A|AB'
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  runsub validate 'ASD-001' --pattern 'ASD|ASD-001'
  [ "$status" -eq 0 ]
  [ "$output" = 'ASD-001' ]
  runsub validate 'ASD-0' --pattern 'ASD|ASD-001'
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "an alternation that includes an unsafe branch still cannot print it: the allowlist applies to the winner" {
  runsub extract 'a;b' --pattern 'a;b|ASD-1'
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  runsub validate 'a;b' --pattern 'a;b|ASD-1'
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  runsub validate 'ASD-1' --pattern 'a;b|ASD-1'
  [ "$status" -eq 0 ]
  [ "$output" = 'ASD-1' ]
}

# --- what the gate does not promise ------------------------------------------------------------------------------

@test "residual: the gate promises an alphabet and a length, not a shape; a permissive pattern lets a leading dash or a dot-dot through, the default does not" {
  local s
  for s in '--amend' '-' '../../etc/passwd' '.'; do
    runsub validate "$s" --pattern '.+'
    [ "$status" -eq 0 ]
    [ "$output" = "$s" ]
    # the same text under the schema default (no --pattern, project not opted in)
    runsub validate "$s"
    [ "$status" -eq 3 ]
    [ -z "$output" ]
  done
}

@test "extract under a permissive pattern may drop a leading non-alphanumeric character into the boundary, but never prints anything unsafe" {
  local s
  for s in '--amend' '..' '-x' '.hidden'; do
    runsub extract "$s" --pattern '.+'
    safe_result
  done
}

# --- the default pattern is not loosened by any of this ---------------------------------------------------------

@test "the schema default still decides when no pattern is recorded: ordinary keys pass, hostile text does not" {
  runsub extract 'feature/ASD-001-foo'
  [ "$status" -eq 0 ]
  [ "$output" = 'ASD-001' ]
  runsub extract 'feature/ASD-001;touch pwned'
  [ "$status" -eq 0 ]
  [ "$output" = 'ASD-001' ]
  runsub validate 'ASD-001;touch pwned'
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  no_canary
}
