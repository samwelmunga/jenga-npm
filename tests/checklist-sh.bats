#!/usr/bin/env bats
#
# Coverage for scripts/checklist.sh -- list, check and tick (E67_S02_T04).
#
# Contract under test: the header comment of scripts/checklist.sh (usage, JSON shape, exit-code table, trust
# model, state layout, environment seams) and project/documentation/preflight-checklists.md (sections 6 and 7).
#
# Isolation. Every fixture registry is generated at test time into $BATS_TEST_TMPDIR (removed by bats after each
# test); no registry, invalid or otherwise, exists in the repository as a standalone data file for these tests.
# setup() points every seam of the checker into the temp dir, so the real tick-state directory
# (project/queue/checklist-ticks/) is never read or written:
#   JENGA_CHECKLISTS_FILE          the project instance        -> $F
#   JENGA_CHECKLISTS_DEFAULT_FILE  the shipped default         -> a path that does not exist (until a test writes it)
#   JENGA_CHECKLIST_STATE_DIR      the tick store              -> $STATE
#   JENGA_PROJECT_ROOT             the resolved root, which is the cwd of every verify -> $PROJ (a temp tree that
#                                  carries only a stub project/configs/workflow.json so the root resolver accepts it)
# The only repository files read are the two real registries, in ONE deliberate test that proves they parse through
# list and check without error; their content may change, so that test asserts shape and exit-code class only.
#
# Streams. The checker writes its result to stdout and every diagnostic to stderr. Tests use
# `run --separate-stderr` (helper `ck`), so $output is stdout only and $stderr is stderr only.
#
# Concurrency tests really run parallel writers: dozens of background `tick` processes against one shared state
# dir, `wait`, then every tick is asserted to have landed. They are bounded in time (see the elapsed assertions) and
# raise with-lock.sh's timeout (never lower it) so a slow machine cannot make them flaky.
#
# Exit codes pinned here: 0, 1, 2, 3, 4, 6, 7, 8, 10, 11. Not tested, on purpose:
#   5  "internal error in the check runner": a bug-only branch that no input reaches by design; there is nothing
#      deterministic to feed it.
#   8  is tested for the two causes that CAN be triggered deterministically (state dir cannot be created; the lock is
#      already held and cannot be acquired within a 1s timeout). A write failing mid-rename is not reproducible.
#      A lock timeout arising from genuine contention is not deterministic either; the held-lock test stands in for it.
#
# Tests named "(pinned judgment call)" assert behaviour the checker's authors chose rather than one the schema
# document dictates, so a later change to it is a conscious decision, not a silent one.
#
# Known imperfect behaviours deliberately NOT asserted either way (the E67_S02_T03 author left them as-is, and a
# test here would fail the day someone fixes them): (1) a corrupt RUN state file leaves a run-<digest>.json.corrupt
# leftover that pruning does not remove; (2) an empty --by or an empty JENGA_CHECKLIST_ACTOR silently falls back to
# the default actor instead of erroring; (3) a malformed record inside an otherwise-valid store reads as unticked
# with no warning. Likewise the documented limit that a verify masking its own failure (`! cmd`, `cmd || true`)
# passes is not pinned: exit status is all there is to score.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CHECKLIST="$REPO_ROOT/scripts/checklist.sh"

setup() {
  T="$BATS_TEST_TMPDIR"
  F="$T/checklists.json"
  DEFAULT="$T/default-checklists.json"
  STATE="$T/state"
  PROJ="$T/proj"
  PIDFILE="$T/bg.pid"
  mkdir -p "$PROJ/project/configs"
  echo '{}' > "$PROJ/project/configs/workflow.json"
  export JENGA_PROJECT_ROOT="$PROJ"
  export JENGA_CHECKLISTS_FILE="$F"
  export JENGA_CHECKLISTS_DEFAULT_FILE="$DEFAULT"
  export JENGA_CHECKLIST_STATE_DIR="$STATE"
  unset JENGA_CHECKLIST_RUN_ID JENGA_CHECKLIST_ACTOR JENGA_CHECKLIST_RUN_TTL_MINUTES JENGA_CHECKLIST_VERIFY_TIMEOUT
  unset WITH_LOCK_TIMEOUT_SECONDS WITH_LOCK_POLL_SECONDS WITH_LOCK_STALE_SECONDS
}

# A test that spawned a long-lived background child must never leave it behind, even when the assertion that it is
# gone fails (for example under a mutated checker that no longer kills the process group). The command line is
# checked first so a recycled pid can never make this kill an unrelated process.
teardown() {
  if [ -s "$PIDFILE" ]; then
    local pid
    pid="$(cat "$PIDFILE")"
    if ps -p "$pid" -o command= 2>/dev/null | grep -q '^sleep 4[0-9]'; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
}

# -----------------------------------------------------------------------------
# Fixture builders
# -----------------------------------------------------------------------------

# item <id> <kind> <enforcement> <tick_scope> [verify]   -> one registry item as JSON on stdout.
# situations default to ["pre-commit"] (override with SIT='["a","b"]'); text defaults to "Item <id>." (override with
# TEXT=...). A verify is only emitted for machine items, jq --arg does all the escaping.
item() {
  local sit='["pre-commit"]'
  sit="${SIT:-$sit}"
  jq -n --arg id "$1" --arg kind "$2" --arg enf "$3" --arg scope "$4" --arg verify "${5:-}" \
    --arg text "${TEXT:-Item $1.}" --argjson sit "$sit" \
    '{id: $id, text: $text, situations: $sit, kind: $kind, enforcement: $enf, tick_scope: $scope}
     + (if $kind == "machine" then {verify: $verify} else {} end)'
}

# registry_to <file> <item-json>...   -> a valid registry declaring the extra situation "pre-deploy".
registry_to() {
  local out="$1"
  shift
  if [ "$#" -eq 0 ]; then
    jq -n '{checklist_version: 1, situations: ["pre-deploy"], items: []}' > "$out"
  else
    printf '%s\n' "$@" | jq -s '{checklist_version: 1, situations: ["pre-deploy"], items: .}' > "$out"
  fi
}

write_registry() { registry_to "$F" "$@"; }
write_default() { registry_to "$DEFAULT" "$@"; }

# make_script <name>  (body on stdin) -> an executable script in the project root, run as "./<name>".
make_script() {
  cat > "$PROJ/$1"
  chmod +x "$PROJ/$1"
}

# Rewrites $F by applying a jq filter to it.
mutate_registry() {
  jq "$1" "$F" > "$F.new" && mv "$F.new" "$F"
}

# -----------------------------------------------------------------------------
# Runners and readers
# -----------------------------------------------------------------------------

# ck <args...>: run the checker; $output is stdout, $stderr is stderr, $status the exit code.
ck() { run --separate-stderr bash "$CHECKLIST" "$@"; }

# fld <id> <key>: raw value of <key> for the element with that id in the check report held in $output.
fld() { jq -r --arg id "$1" '.[] | select(.id == $id) | .'"$2" <<<"$output"; }

# state_of <id>: the tick-state column of that item's row in the list output held in $output.
state_of() { printf '%s\n' "$output" | awk -F'\t' -v id="$1" '$1 == id { print $5 }'; }

# Asserts $output is one JSON array whose every element carries exactly the documented keys with in-domain values.
assert_valid_report() {
  if ! jq -e 'type == "array" and all(.[];
        ((keys | sort) == ["action", "cause", "enforcement", "exit_status", "id", "kind", "reason", "result",
                           "text", "tick_scope", "tick_state"])
        and (.result | IN("passed", "failed", "requires_confirmation", "already_ticked"))
        and (.action | IN("proceed", "halt", "prompt", "remind")))' <<<"$output" >/dev/null; then
    echo "stdout is not a valid check report:" >&2
    printf '%s\n' "$output" >&2
    return 1
  fi
}

# Asserts stdout carries no byte above 0x7f (the report is ASCII-only so hostile output cannot corrupt it).
assert_ascii_stdout() {
  local high
  high="$(printf '%s' "$output" | LC_ALL=C tr -d '\000-\177' | wc -c | tr -d ' ')"
  [ "$high" -eq 0 ]
}

# one_check <enforcement> <verify>: one run-scoped machine item "subject" with that verify, then `check pre-commit`.
one_check() {
  write_registry "$(item subject machine "$1" run "$2")"
  ck check pre-commit
}

# tick_bg <status-file> <stderr-file> <tick args...>: one background tick that records its own exit status (a failing
# tick must not abort the subshell under errexit before the status is written). Call with `3>&- &`.
tick_bg() {
  local status_file="$1" err_file="$2" rc=0
  shift 2
  bash "$CHECKLIST" tick "$@" >/dev/null 2>"$err_file" || rc=$?
  echo "$rc" > "$status_file"
}

# run_file_name <run-id>: the documented name of that run's state file (sha256 of the id, first 24 hex characters).
run_file_name() {
  printf 'run-%s.json' "$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:24])' "$1")"
}

# backdate <path> <seconds>: set the file's mtime that many seconds into the past (portable, unlike touch -t).
backdate() {
  python3 -c 'import os,sys,time; t=time.time()-float(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" "$2"
}

# =============================================================================
# Usage and the exit-code table
# =============================================================================

@test "help: -h, --help and help print the usage on stdout and exit 0" {
  local flag
  for flag in -h --help help; do
    ck "$flag"
    [ "$status" -eq 0 ] || { echo "$flag exited $status" >&2; return 1; }
    assert_output_contains "usage:"
    assert_output_contains "checklist.sh tick  <id>"
    [ -z "$stderr" ]
  done
}

@test "usage errors: exit 2 with a message on stderr and nothing on stdout" {
  write_registry "$(item some-item judgment confirm persistent)"
  local -a args
  local case_
  for case_ in "" "frobnicate" "list" "list a b" "check" "check pre-commit extra" "tick" "tick a-item b-item" \
               "list pre-commit --run" "check pre-commit --run=" "tick some-item --note" "tick some-item --by"; do
    # shellcheck disable=SC2206
    args=($case_)
    ck "${args[@]}"
    [ "$status" -eq 2 ] || { echo "'$case_' exited $status, expected 2" >&2; return 1; }
    [ -z "$output" ] || { echo "'$case_' wrote to stdout: $output" >&2; return 1; }
    [ -n "$stderr" ] || { echo "'$case_' wrote no diagnostic" >&2; return 1; }
  done
}

@test "exit 4: python3 missing is reported with a distinct code and no traceback" {
  # A PATH holding only the two utilities the script's own preamble needs (basename, dirname) and no python3.
  mkdir "$T/bin"
  ln -s "$(command -v basename)" "$T/bin/basename"
  ln -s "$(command -v dirname)" "$T/bin/dirname"
  write_registry "$(item some-item judgment confirm persistent)"
  run --separate-stderr /usr/bin/env PATH="$T/bin" /bin/bash "$CHECKLIST" list pre-commit
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "python3 is required"
  [ -z "$output" ]
}

@test "exit 1: an unresolvable configs directory is reported, not listed (no instance seam, root without a registry)" {
  mkdir "$T/no-registry"
  run --separate-stderr env -u JENGA_CHECKLISTS_FILE JENGA_PROJECT_ROOT="$T/no-registry" bash "$CHECKLIST" list pre-commit
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "could not resolve the project configs directory"
  [ -z "$output" ]
  run --separate-stderr env -u JENGA_CHECKLISTS_FILE JENGA_PROJECT_ROOT="$T/no-registry" bash "$CHECKLIST" check pre-commit
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# =============================================================================
# list
# =============================================================================

@test "list: prints only the items tagged with the situation, in registry order, one tab-separated row each" {
  write_registry \
    "$(SIT='["pre-commit"]' item first-item machine block run true)" \
    "$(SIT='["pre-task"]' item other-phase judgment advisory run)" \
    "$(SIT='["pre-task", "pre-commit"]' item second-item judgment confirm persistent)"
  ck list pre-commit
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "$(printf 'first-item\tItem first-item.\tmachine\tblock\tunticked')" ]
  [ "${lines[1]}" = "$(printf 'second-item\tItem second-item.\tjudgment\tconfirm\tunticked')" ]
  assert_output_not_contains "other-phase"
  [ -z "$stderr" ]
  ck list pre-task
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  assert_output_contains "other-phase"
  assert_output_not_contains "first-item"
}

@test "list: shows kind, enforcement and tick state for every combination" {
  write_registry \
    "$(item m-block machine block run true)" \
    "$(item m-confirm machine confirm run true)" \
    "$(item m-advisory machine advisory run true)" \
    "$(item j-block judgment block persistent)" \
    "$(item j-confirm judgment confirm persistent)" \
    "$(item j-advisory judgment advisory persistent)"
  ck list pre-commit
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 6 ]
  local id want
  for want in "m-block:machine:block" "m-confirm:machine:confirm" "m-advisory:machine:advisory" \
              "j-block:judgment:block" "j-confirm:judgment:confirm" "j-advisory:judgment:advisory"; do
    id="${want%%:*}"
    [ "$(printf '%s\n' "$output" | awk -F'\t' -v id="$id" '$1 == id { print $1 ":" $3 ":" $4 ":" $5 }')" = "$want:unticked" ] \
      || { echo "wrong row for $id: $output" >&2; return 1; }
  done
}

@test "list: tabs and newlines inside an item's text are flattened so one item is exactly one line" {
  write_registry "$(TEXT=$'two\twords\nand a second   line' item flat-item judgment confirm run)"
  ck list pre-commit
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$(printf '%s' "$output" | awk -F'\t' '{print NF}')" -eq 5 ]
  [ "$(printf '%s' "$output" | cut -f2)" = "two words and a second line" ]
}

@test "list: an unknown situation exits 3, naming the situation and the known ones, with nothing on stdout" {
  write_registry "$(item some-item judgment confirm persistent)"
  ck list pre-comit
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  assert_contains "$stderr" 'unknown situation "pre-comit"'
  assert_contains "$stderr" "pre-commit, pre-task, pre-release, pre-reconcile, pre-deploy"
}

@test "list: a known situation no item names is silent and exits 0, distinct from an unknown one" {
  write_registry "$(item some-item judgment confirm persistent)"
  ck list pre-release
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  # the situation a registry declares itself is known too, and equally silent when empty
  ck list pre-deploy
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "list: no registry at all is a silent exit 0 (a project that authored nothing sees nothing)" {
  [ ! -e "$F" ]
  [ ! -e "$DEFAULT" ]
  ck list pre-commit
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  # with no registry file there is nothing that could declare an extension, so any well-formed name is silent
  ck list some-unheard-of-phase
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "list: a registry with an empty items array is a silent exit 0" {
  write_registry
  ck list pre-commit
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "list: an invalid registry exits 1 with the validator's own message and no traceback" {
  write_registry "$(item some-item judgment confirm persistent)"
  mutate_registry '.items[0].kind = "automatic"'
  ck list pre-commit
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" 'unknown kind "automatic" in item "some-item"'
  assert_contains "$stderr" "invalid registry"
  assert_not_contains "$stderr" "Traceback"
}

@test "list: a registry that is not JSON exits 1 without a traceback" {
  printf '{ this is not json' > "$F"
  ck list pre-commit
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "invalid registry"
  assert_not_contains "$stderr" "Traceback"
}

@test "check, tick and list all refuse an invalid registry the same way (exit 1, nothing on stdout)" {
  write_registry "$(item some-item machine block run true)"
  mutate_registry 'del(.items[0].verify)'
  local cmd
  for cmd in "list pre-commit" "check pre-commit" "tick some-item --run r1"; do
    # shellcheck disable=SC2086
    ck $cmd
    [ "$status" -eq 1 ] || { echo "'$cmd' exited $status, expected 1" >&2; return 1; }
    [ -z "$output" ] || { echo "'$cmd' wrote to stdout" >&2; return 1; }
    assert_contains "$stderr" "missing verify"
    assert_not_contains "$stderr" "Traceback"
  done
}

@test "list: bad run id is a usage error (exit 2) and so is a bad TTL override" {
  write_registry "$(item some-item judgment confirm persistent)"
  local bad
  for bad in "-leading-hyphen" "has space" "with/slash" "$(printf 'x%.0s' $(seq 1 129))"; do
    ck list pre-commit --run "$bad"
    [ "$status" -eq 2 ] || { echo "run id '$bad' exited $status" >&2; return 1; }
    assert_contains "$stderr" "bad run id"
    [ -z "$output" ]
  done
  for bad in 0 abc -1; do
    JENGA_CHECKLIST_RUN_TTL_MINUTES="$bad" ck list pre-commit
    [ "$status" -eq 2 ] || { echo "TTL '$bad' exited $status" >&2; return 1; }
    assert_contains "$stderr" "bad run TTL"
  done
}

@test "list and check only read: no verify runs, no state dir is created" {
  write_registry "$(item touchy machine block run "touch '$T/marker'; exit 1")" \
    "$(item judge judgment confirm persistent)"
  ck list pre-commit
  [ "$status" -eq 0 ]
  [ ! -e "$T/marker" ]
  [ ! -e "$STATE" ]
  JENGA_CHECKLIST_VERIFY_TIMEOUT=10 ck check pre-commit
  [ "$status" -eq 10 ]
  [ -e "$T/marker" ]
  [ ! -e "$STATE" ]
}

# --- which registry file is read ----------------------------------------------------------------------------------

@test "precedence: the project instance wins and the shipped default is not read at all" {
  write_registry "$(item instance-item judgment confirm run)"
  write_default "$(item default-item judgment confirm run)"
  ck list pre-commit
  [ "$status" -eq 0 ]
  assert_output_contains "instance-item"
  assert_output_not_contains "default-item"
  # not read at all: even a garbage default cannot affect a run that has an instance
  printf 'garbage, not json' > "$DEFAULT"
  ck list pre-commit
  [ "$status" -eq 0 ]
  assert_output_contains "instance-item"
  [ -z "$stderr" ]
}

@test "precedence: an existing but empty instance does NOT fall back to the shipped default" {
  write_registry
  write_default "$(item default-item judgment confirm run)"
  ck list pre-commit
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  ck check pre-commit
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "precedence: an absent instance falls back to the shipped default, whole file, for list, check and tick" {
  write_default "$(item default-item judgment confirm persistent)"
  [ ! -e "$F" ]
  ck list pre-commit
  [ "$status" -eq 0 ]
  assert_output_contains "default-item"
  ck check pre-commit
  [ "$status" -eq 11 ]
  [ "$(fld default-item result)" = "requires_confirmation" ]
  ck tick default-item --by agent:test
  [ "$status" -eq 0 ]
  assert_output_contains "ticked default-item (persistent) by agent:test"
}

@test "precedence: with neither file there is no registry, so list is silent, check prints [] and tick has no id to find" {
  ck list pre-commit
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  ck check pre-commit
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  [ -z "$stderr" ]
  ck tick anything --by agent:test
  [ "$status" -eq 6 ]
  assert_contains "$stderr" "no checklist registry"
}

@test "precedence: an invalid default is rejected only when it is the file actually selected" {
  printf '{ broken' > "$DEFAULT"
  ck list pre-commit
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "invalid registry"
  assert_not_contains "$stderr" "Traceback"
}

@test "precedence: an item only in the default is unknown to tick once an instance exists (no merging)" {
  write_registry "$(item instance-item judgment confirm persistent)"
  write_default "$(item default-item judgment confirm persistent)"
  ck tick default-item --by agent:test
  [ "$status" -eq 6 ]
  assert_contains "$stderr" 'unknown checklist item id "default-item"'
  assert_contains "$stderr" "instance-item"
}

# =============================================================================
# check: exit-code matrix and output
# =============================================================================

@test "check: a passing block item exits 0 and is reported passed/proceed with the documented fields" {
  write_registry "$(item good machine block run true)"
  ck check pre-commit
  [ "$status" -eq 0 ]
  assert_valid_report
  [ "$(fld good result)" = "passed" ]
  [ "$(fld good action)" = "proceed" ]
  [ "$(fld good cause)" = "null" ]
  [ "$(fld good exit_status)" = "0" ]
  [ "$(fld good tick_state)" = "unticked" ]
  [ "$(fld good enforcement)" = "block" ]
  [ "$(fld good text)" = "Item good." ]
  [ -z "$stderr" ]
}

@test "check: a failing block item exits 10 and is reported failed/halt" {
  write_registry "$(item bad machine block run false)"
  ck check pre-commit
  [ "$status" -eq 10 ]
  assert_valid_report
  [ "$(fld bad result)" = "failed" ]
  [ "$(fld bad action)" = "halt" ]
  [ "$(fld bad cause)" = "nonzero_exit" ]
  [ "$(fld bad exit_status)" = "1" ]
}

@test "check: a failing confirm item with no block failure exits 11 and is reported failed/prompt" {
  write_registry "$(item bad machine confirm run false)" "$(item good machine block run true)"
  ck check pre-commit
  [ "$status" -eq 11 ]
  assert_valid_report
  [ "$(fld bad result)" = "failed" ]
  [ "$(fld bad action)" = "prompt" ]
  [ "$(fld good result)" = "passed" ]
}

@test "check: a block failure takes precedence over a confirm failure (exit 10, not 11)" {
  write_registry "$(item confirm-bad machine confirm run false)" "$(item block-bad machine block run false)"
  ck check pre-commit
  [ "$status" -eq 10 ]
  assert_valid_report
  [ "$(fld confirm-bad action)" = "prompt" ]
  [ "$(fld block-bad action)" = "halt" ]
  # the order the items are listed in does not matter
  write_registry "$(item block-bad machine block run false)" "$(item confirm-bad machine confirm run false)"
  ck check pre-commit
  [ "$status" -eq 10 ]
}

@test "check: an advisory-only failure exits 0 and is reported failed/remind" {
  write_registry "$(item nag machine advisory run false)"
  ck check pre-commit
  [ "$status" -eq 0 ]
  assert_valid_report
  [ "$(fld nag result)" = "failed" ]
  [ "$(fld nag action)" = "remind" ]
  [ "$(fld nag cause)" = "nonzero_exit" ]
}

@test "check: an advisory failure beside a passing block item still exits 0" {
  write_registry "$(item nag machine advisory run false)" "$(item good machine block run true)"
  ck check pre-commit
  [ "$status" -eq 0 ]
  [ "$(fld nag result)" = "failed" ]
  [ "$(fld good result)" = "passed" ]
}

@test "check: judgment items are reported requires_confirmation per enforcement and never passed" {
  local enf expect_status expect_action
  for row in "block:10:halt" "confirm:11:prompt" "advisory:0:remind"; do
    enf="${row%%:*}"
    expect_status="$(echo "$row" | cut -d: -f2)"
    expect_action="${row##*:}"
    write_registry "$(item judged judgment "$enf" run)"
    ck check pre-commit
    [ "$status" -eq "$expect_status" ] || { echo "$enf judgment exited $status, expected $expect_status" >&2; return 1; }
    assert_valid_report
    [ "$(fld judged result)" = "requires_confirmation" ] || { echo "$enf judgment result: $(fld judged result)" >&2; return 1; }
    [ "$(fld judged action)" = "$expect_action" ] || { echo "$enf judgment action: $(fld judged action)" >&2; return 1; }
    [ "$(fld judged cause)" = "null" ]
    [ "$(fld judged exit_status)" = "null" ]
    [ "$(jq '[.[] | select(.result == "passed")] | length' <<<"$output")" -eq 0 ]
  done
}

@test "check: a judgment confirm item beside passing machine items still exits 11" {
  write_registry "$(item good machine block run true)" "$(item judged judgment confirm run)"
  ck check pre-commit
  [ "$status" -eq 11 ]
  [ "$(fld good result)" = "passed" ]
  [ "$(fld judged result)" = "requires_confirmation" ]
}

@test "check: an unconfirmed advisory judgment item alone does not affect the exit code" {
  write_registry "$(item good machine block run true)" "$(item reminder judgment advisory run)"
  ck check pre-commit
  [ "$status" -eq 0 ]
  [ "$(fld reminder result)" = "requires_confirmation" ]
}

@test "check: the report holds every applicable item once, in registry order, and no other item" {
  write_registry \
    "$(item zeta machine advisory run true)" \
    "$(SIT='["pre-task"]' item elsewhere machine block run false)" \
    "$(item alpha judgment confirm persistent)" \
    "$(item mid machine block run true)"
  ck check pre-commit
  [ "$status" -eq 11 ]
  assert_valid_report
  [ "$(jq -r 'map(.id) | join(",")' <<<"$output")" = "zeta,alpha,mid" ]
}

@test "check: stdout is exactly one JSON document in every outcome" {
  local verify
  for verify in "true" "false" "exit 7" "sleep 30"; do
    export JENGA_CHECKLIST_VERIFY_TIMEOUT=1
    one_check block "$verify"
    assert_valid_report
    [ "$(printf '%s' "$output" | jq -s 'length')" -eq 1 ] || { echo "'$verify': more than one JSON document" >&2; return 1; }
    [ "$(printf '%s\n' "$output" | head -c 1)" = "[" ]
  done
}

@test "check: nothing applicable prints [] and exits 0 silently (empty items, known-but-empty situation, no registry)" {
  write_registry
  ck check pre-commit
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  [ -z "$stderr" ]
  write_registry "$(item some-item machine block run false)"
  ck check pre-release
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  [ -z "$stderr" ]
  assert_valid_report
  [ ! -e "$F" ] || rm "$F"
  ck check pre-commit
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  [ -z "$stderr" ]
}

@test "check: an unknown situation exits 3 with empty stdout; an invalid registry exits 1 with empty stdout" {
  write_registry "$(item some-item machine block run true)"
  ck check pre-comit
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  assert_contains "$stderr" 'unknown situation "pre-comit"'
  mutate_registry '.items[0].enforcement = "mandatory"'
  ck check pre-commit
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" 'bad enforcement "mandatory"'
}

@test "check: a bad JENGA_CHECKLIST_VERIFY_TIMEOUT is a usage error (exit 2) with empty stdout" {
  write_registry "$(item some-item machine block run true)"
  local bad
  for bad in abc 0 -5; do
    JENGA_CHECKLIST_VERIFY_TIMEOUT="$bad" ck check pre-commit
    [ "$status" -eq 2 ] || { echo "timeout '$bad' exited $status" >&2; return 1; }
    [ -z "$output" ]
    assert_contains "$stderr" "bad verify timeout"
  done
}

@test "check: a verify runs from the resolved project root, not from the caller's directory" {
  write_registry "$(item where machine block run 'pwd -P > cwd-seen.txt')"
  mkdir "$T/elsewhere"
  cd "$T/elsewhere"
  ck check pre-commit
  [ "$status" -eq 0 ]
  [ "$(cat "$PROJ/cwd-seen.txt")" = "$(cd "$PROJ" && pwd -P)" ]
  [ ! -e "$T/elsewhere/cwd-seen.txt" ]
}

@test "check: a verify that reads stdin does not hang (stdin is /dev/null even when the caller's never closes)" {
  mkfifo "$T/fifo"
  write_registry "$(item reader machine block run 'cat > /dev/null')"
  export JENGA_CHECKLIST_VERIFY_TIMEOUT=10
  local start=$SECONDS
  run --separate-stderr bash -c 'exec bash "$1" check pre-commit <>"$2"' _ "$CHECKLIST" "$T/fifo"
  [ "$status" -eq 0 ]
  [ "$(fld reader result)" = "passed" ]
  [ "$(fld reader cause)" = "null" ]
  [ $((SECONDS - start)) -lt 8 ]
}

# --- already_ticked: an item that is ticked is satisfied and never re-evaluated -----------------------------------

@test "check: an already_ticked item is not re-verified (its verify would fail and would write a marker)" {
  write_registry \
    "$(item ticked-fail machine block persistent "touch '$T/marker-ticked'; exit 1")" \
    "$(item ticked-judged judgment block persistent)" \
    "$(item live-fail machine advisory persistent "touch '$T/marker-live'; exit 1")"
  ck tick ticked-fail --by agent:test
  [ "$status" -eq 0 ]
  ck tick ticked-judged --by agent:test
  [ "$status" -eq 0 ]
  ck check pre-commit
  [ "$status" -eq 0 ]
  assert_valid_report
  [ "$(fld ticked-fail result)" = "already_ticked" ]
  [ "$(fld ticked-fail action)" = "proceed" ]
  [ "$(fld ticked-fail cause)" = "null" ]
  [ "$(fld ticked-fail exit_status)" = "null" ]
  [ "$(fld ticked-judged result)" = "already_ticked" ]
  case "$(fld ticked-fail tick_state)" in "ticked(persistent) by agent:test at "*) ;; *) return 1 ;; esac
  # the verify of the ticked item never ran, while the unticked sibling's did (so the marker mechanism is live)
  [ ! -e "$T/marker-ticked" ]
  [ -e "$T/marker-live" ]
  [ "$(fld live-fail result)" = "failed" ]
  [ "$(fld live-fail action)" = "remind" ]
}

@test "check: a block item that is ticked no longer halts, while an unticked failing block item still does" {
  write_registry "$(item ticked-fail machine block persistent false)" "$(item open-fail machine block persistent false)"
  ck tick ticked-fail --by agent:test
  [ "$status" -eq 0 ]
  ck check pre-commit
  [ "$status" -eq 10 ]
  [ "$(fld ticked-fail result)" = "already_ticked" ]
  [ "$(fld open-fail result)" = "failed" ]
  ck tick open-fail --by agent:test
  ck check pre-commit
  [ "$status" -eq 0 ]
}

# =============================================================================
# check: a verify that is broken is a failure with its own cause, never a pass
# =============================================================================

@test "broken verify, missing command (path form): failed, cause not_found, names the missing path" {
  one_check block "./no-such-tool.sh --flag"
  [ "$status" -eq 10 ]
  assert_valid_report
  [ "$(fld subject result)" = "failed" ]
  [ "$(fld subject cause)" = "not_found" ]
  [ "$(fld subject exit_status)" = "null" ]
  [ "$(fld subject action)" = "halt" ]
  assert_contains "$(fld subject reason)" "verify command not found: ./no-such-tool.sh does not exist"
}

@test "broken verify, missing command (bare name): failed, cause not_found, shell status 127" {
  one_check block "jenga-no-such-command-xyz --flag"
  [ "$status" -eq 10 ]
  [ "$(fld subject result)" = "failed" ]
  [ "$(fld subject cause)" = "not_found" ]
  [ "$(fld subject exit_status)" = "127" ]
  assert_contains "$(fld subject reason)" "exit status 127"
}

@test "broken verify, non-executable file: failed, cause not_executable, even though the script body would pass" {
  printf '#!/bin/bash\nexit 0\n' > "$PROJ/tool.sh"
  chmod 644 "$PROJ/tool.sh"
  one_check block "./tool.sh"
  [ "$status" -eq 10 ]
  assert_valid_report
  [ "$(fld subject result)" = "failed" ]
  [ "$(fld subject cause)" = "not_executable" ]
  [ "$(fld subject exit_status)" = "null" ]
  assert_contains "$(fld subject reason)" "lacks the execute permission"
  [ "$(jq '[.[] | select(.result == "passed")] | length' <<<"$output")" -eq 0 ]
}

@test "broken verify, a directory used as the command: failed, cause not_executable, says it is a directory" {
  mkdir "$PROJ/a-directory"
  one_check block "./a-directory"
  [ "$status" -eq 10 ]
  [ "$(fld subject result)" = "failed" ]
  [ "$(fld subject cause)" = "not_executable" ]
  assert_contains "$(fld subject reason)" "is a directory"
}

@test "broken verify, timeout: failed, cause timeout, reason names the limit, returns promptly" {
  export JENGA_CHECKLIST_VERIFY_TIMEOUT=1
  local start=$SECONDS
  one_check block "sleep 30"
  [ "$status" -eq 10 ]
  assert_valid_report
  [ "$(fld subject result)" = "failed" ]
  [ "$(fld subject cause)" = "timeout" ]
  [ "$(fld subject exit_status)" = "null" ]
  [ "$(fld subject action)" = "halt" ]
  assert_contains "$(fld subject reason)" "timed out after 1s"
  [ $((SECONDS - start)) -lt 15 ]
}

@test "broken verify, timeout: a verify that spawned a background child leaves no orphan behind" {
  export JENGA_CHECKLIST_VERIFY_TIMEOUT=1
  # The foreground command (3s) must outlive the 1s limit but end long BEFORE the background child (44s): if the
  # checker only killed the foreground command, or merely waited for it, the child would still be running afterwards.
  # (A foreground that outlasts the child would make "the child is gone" true for the wrong reason.)
  write_registry "$(item subject machine block run "sleep 44 & echo \$! > '$PIDFILE'; sleep 3")"
  ck check pre-commit 3>&-
  [ "$status" -eq 10 ]
  [ "$(fld subject cause)" = "timeout" ]
  # the child really was started (otherwise "no orphan" would be vacuous) ...
  [ -s "$PIDFILE" ]
  local pid i alive=1
  pid="$(cat "$PIDFILE")"
  case "$pid" in *[!0-9]*|"") return 1 ;; esac
  # ... and is gone: the whole process group was killed (allow a moment for the kernel to reap it)
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if ! kill -0 "$pid" 2>/dev/null; then alive=0; break; fi
    sleep 0.1
  done
  [ "$alive" -eq 0 ]
}

@test "broken verify, a background process left behind by a verify that exited 0 is reaped too" {
  write_registry "$(item subject machine block run "sleep 43 & echo \$! > '$PIDFILE'; exit 0")"
  ck check pre-commit 3>&-
  [ "$status" -eq 0 ]
  [ "$(fld subject result)" = "passed" ]
  [ -s "$PIDFILE" ]
  local pid i alive=1
  pid="$(cat "$PIDFILE")"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if ! kill -0 "$pid" 2>/dev/null; then alive=0; break; fi
    sleep 0.1
  done
  [ "$alive" -eq 0 ]
}

@test "broken verify, non-zero exit: failed, cause nonzero_exit, reason carries the status and a stderr excerpt" {
  one_check block 'echo "out-text"; echo "boom-from-stderr" >&2; exit 3'
  [ "$status" -eq 10 ]
  assert_valid_report
  [ "$(fld subject result)" = "failed" ]
  [ "$(fld subject cause)" = "nonzero_exit" ]
  [ "$(fld subject exit_status)" = "3" ]
  assert_contains "$(fld subject reason)" "status 3"
  assert_contains "$(fld subject reason)" "boom-from-stderr"
  # stderr is preferred; stdout is quoted only when stderr is empty
  assert_not_contains "$(fld subject reason)" "out-text"
}

@test "broken verify, non-zero exit: with nothing on stderr the reason quotes stdout instead" {
  one_check block 'echo "only-on-stdout"; exit 4'
  [ "$status" -eq 10 ]
  [ "$(fld subject exit_status)" = "4" ]
  assert_contains "$(fld subject reason)" "only-on-stdout"
}

@test "broken verify, non-zero exit: the quoted excerpt is bounded however much the verify prints" {
  make_script chatty.sh <<'EOF'
#!/bin/bash
i=0
while [ "$i" -lt 2000 ]; do printf 'line-%d some words to pad the output\n' "$i" >&2; i=$((i + 1)); done
exit 2
EOF
  one_check block "./chatty.sh"
  [ "$status" -eq 10 ]
  [ "$(fld subject exit_status)" = "2" ]
  local reason
  reason="$(fld subject reason)"
  assert_contains "$reason" "line-0 some words"
  assert_contains "$reason" "..."
  [ "${#reason}" -lt 400 ]
}

@test "broken verify, killed by a signal: failed, cause signal, no exit status" {
  one_check block 'kill -9 $$'
  [ "$status" -eq 10 ]
  [ "$(fld subject result)" = "failed" ]
  [ "$(fld subject cause)" = "signal" ]
  [ "$(fld subject exit_status)" = "null" ]
  assert_contains "$(fld subject reason)" "signal 9"
}

@test "broken verify on an advisory item is still reported failed (never passed), and exits 0" {
  export JENGA_CHECKLIST_VERIFY_TIMEOUT=1
  write_registry \
    "$(item missing machine advisory run ./nope.sh)" \
    "$(item slow machine advisory run 'sleep 30')" \
    "$(item exit-two machine advisory run 'exit 2')"
  ck check pre-commit
  [ "$status" -eq 0 ]
  assert_valid_report
  [ "$(fld missing result):$(fld missing cause)" = "failed:not_found" ]
  [ "$(fld slow result):$(fld slow cause)" = "failed:timeout" ]
  [ "$(fld exit-two result):$(fld exit-two cause)" = "failed:nonzero_exit" ]
}

# --- hostile verify output ----------------------------------------------------------------------------------------

@test "hostile output: quotes, backslashes, newlines and tabs still yield valid JSON and a one-line reason" {
  make_script quotes.sh <<'EOF'
#!/bin/bash
printf 'say "hi" and back\\slash and '"'"'single'"'"'\nsecond line\tTAB\n{"json": [1, 2]}\n' >&2
exit 1
EOF
  one_check block "./quotes.sh"
  [ "$status" -eq 10 ]
  assert_valid_report
  [ "$(fld subject result)" = "failed" ]
  assert_contains "$(fld subject reason)" 'say "hi" and back\slash'
  assert_contains "$(fld subject reason)" 'second line'
  case "$(fld subject reason)" in *$'\n'*|*$'\t'*) echo "reason is not one line" >&2; return 1 ;; esac
}

@test "hostile output: control characters are stripped from the reason and the JSON stays valid" {
  make_script ctrl.sh <<'EOF'
#!/bin/bash
printf '\001\002\033[31mred\033[0m\r\n\a\f\177end\n' >&2
exit 1
EOF
  one_check block "./ctrl.sh"
  [ "$status" -eq 10 ]
  assert_valid_report
  assert_contains "$(fld subject reason)" "red"
  assert_contains "$(fld subject reason)" "end"
  if printf '%s' "$(fld subject reason)" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    echo "reason still holds a control character" >&2
    return 1
  fi
}

@test "hostile output: invalid UTF-8 yields valid, ASCII-only JSON" {
  make_script badutf.sh <<'EOF'
#!/bin/bash
printf '\377\376broken\200\300\n' >&2
printf '\377\376also-on-stdout\n'
exit 1
EOF
  one_check block "./badutf.sh"
  [ "$status" -eq 10 ]
  assert_valid_report
  assert_ascii_stdout
  assert_contains "$(fld subject reason)" "broken"
  [ "$(fld subject cause)" = "nonzero_exit" ]
}

@test "hostile output: invalid UTF-8 on stdout alone (stderr empty) is also safe" {
  make_script badout.sh <<'EOF'
#!/bin/bash
printf '\377\376\200only-stdout\n'
exit 1
EOF
  one_check block "./badout.sh"
  [ "$status" -eq 10 ]
  assert_valid_report
  assert_ascii_stdout
  assert_contains "$(fld subject reason)" "only-stdout"
}

@test "hostile output: multi-megabyte stdout and stderr stay bounded, valid and quick" {
  make_script flood.sh <<'EOF'
#!/bin/bash
head -c 6000000 /dev/zero | tr '\0' 'x' >&2
head -c 6000000 /dev/zero | tr '\0' 'y'
exit 1
EOF
  export JENGA_CHECKLIST_VERIFY_TIMEOUT=20
  local start=$SECONDS reason
  one_check block "./flood.sh"
  [ "$status" -eq 10 ]
  assert_valid_report
  [ "$(fld subject cause)" = "nonzero_exit" ]
  reason="$(fld subject reason)"
  [ "${#reason}" -lt 400 ]
  assert_contains "$reason" "xxxx"
  [ "${#output}" -lt 4000 ]
  [ $((SECONDS - start)) -lt 20 ]
}

@test "hostile output: multi-megabyte output on a verify that passes does not break the report" {
  make_script flood-ok.sh <<'EOF'
#!/bin/bash
head -c 5000000 /dev/zero | tr '\0' 'z'
head -c 5000000 /dev/zero | tr '\0' 'w' >&2
exit 0
EOF
  export JENGA_CHECKLIST_VERIFY_TIMEOUT=20
  one_check block "./flood-ok.sh"
  [ "$status" -eq 0 ]
  assert_valid_report
  [ "$(fld subject result)" = "passed" ]
  [ "${#output}" -lt 4000 ]
}

# =============================================================================
# tick
# =============================================================================

@test "tick: records who, when and the note, prints one confirmation line and exits 0" {
  write_registry "$(item some-item judgment confirm persistent)"
  ck tick some-item --by agent:developer --note 'he said "ok" \ done'
  [ "$status" -eq 0 ]
  [ "$output" = "ticked some-item (persistent) by agent:developer" ]
  [ -z "$stderr" ]
  [ "$(jq -r '.ticks["some-item"].ticked_by' "$STATE/persistent.json")" = "agent:developer" ]
  [ "$(jq -r '.ticks["some-item"].note' "$STATE/persistent.json")" = 'he said "ok" \ done' ]
  [ "$(jq -r '.ticks["some-item"].tick_scope' "$STATE/persistent.json")" = "persistent" ]
  local ts
  ts="$(jq -r '.ticks["some-item"].ticked_at' "$STATE/persistent.json")"
  if ! [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    echo "ticked_at is not a UTC ISO timestamp: $ts" >&2
    return 1
  fi
  # list and check both reflect it
  ck list pre-commit
  [ "$status" -eq 0 ]
  [ "$(state_of some-item)" = "ticked(persistent) by agent:developer at $ts" ]
  ck check pre-commit
  [ "$status" -eq 0 ]
  [ "$(fld some-item result)" = "already_ticked" ]
  [ "$(fld some-item tick_state)" = "ticked(persistent) by agent:developer at $ts" ]
}

@test "tick: without a note the stored note is null; ticking again refreshes actor and note" {
  write_registry "$(item some-item judgment confirm persistent)"
  ck tick some-item --by agent:first
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ticks["some-item"].note' "$STATE/persistent.json")" = "null" ]
  ck tick some-item --by agent:second --note "second time"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ticks["some-item"].ticked_by' "$STATE/persistent.json")" = "agent:second" ]
  [ "$(jq -r '.ticks["some-item"].note' "$STATE/persistent.json")" = "second time" ]
  [ "$(jq '.ticks | length' "$STATE/persistent.json")" -eq 1 ]
}

@test "tick actor: --by wins over JENGA_CHECKLIST_ACTOR, which wins over the OS-user default" {
  write_registry "$(item some-item judgment confirm persistent)"
  JENGA_CHECKLIST_ACTOR="env:actor" ck tick some-item --by "cli:actor"
  [ "$status" -eq 0 ]
  [ "$output" = "ticked some-item (persistent) by cli:actor" ]
  [ "$(jq -r '.ticks["some-item"].ticked_by' "$STATE/persistent.json")" = "cli:actor" ]

  JENGA_CHECKLIST_ACTOR="env:actor" ck tick some-item
  [ "$status" -eq 0 ]
  [ "$output" = "ticked some-item (persistent) by env:actor" ]
  [ "$(jq -r '.ticks["some-item"].ticked_by' "$STATE/persistent.json")" = "env:actor" ]

  ck tick some-item
  [ "$status" -eq 0 ]
  [ "$output" = "ticked some-item (persistent) by os-user:$(id -un)" ]
  [ "$(jq -r '.ticks["some-item"].ticked_by' "$STATE/persistent.json")" = "os-user:$(id -un)" ]
}

@test "tick actor: a malformed actor (--by or the environment) is a usage error and nothing is recorded" {
  write_registry "$(item some-item judgment confirm persistent)"
  local bad
  for bad in "has space" "semi;colon" "$(printf 'a%.0s' $(seq 1 129))"; do
    ck tick some-item --by "$bad"
    [ "$status" -eq 2 ] || { echo "--by '$bad' exited $status" >&2; return 1; }
    assert_contains "$stderr" "bad actor"
    JENGA_CHECKLIST_ACTOR="$bad" ck tick some-item
    [ "$status" -eq 2 ] || { echo "env actor '$bad' exited $status" >&2; return 1; }
  done
  [ ! -e "$STATE" ]
}

@test "tick: malformed inputs are usage errors (exit 2): bad item id, over-long note, --clear with --note or --by" {
  write_registry "$(item some-item judgment confirm persistent)"
  ck tick Bad_ID
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "not a valid checklist item id"
  ck tick some-item --note "$(printf 'n%.0s' $(seq 1 2001))"
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "--note is too long"
  ck tick --clear some-item --note why
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "--clear cannot be combined"
  ck tick --clear some-item --by agent:x
  [ "$status" -eq 2 ]
  [ ! -e "$STATE" ]
  # exactly at the limit is accepted
  ck tick some-item --note "$(printf 'n%.0s' $(seq 1 2000))"
  [ "$status" -eq 0 ]
}

@test "tick: an unknown item id exits 6 naming the id and the known ones, and records nothing" {
  write_registry "$(item real-item judgment confirm persistent)" "$(item other-item judgment confirm run)"
  ck tick no-such-item --by agent:test
  [ "$status" -eq 6 ]
  [ -z "$output" ]
  assert_contains "$stderr" 'unknown checklist item id "no-such-item"'
  assert_contains "$stderr" "real-item"
  assert_contains "$stderr" "other-item"
  [ ! -e "$STATE" ]
}

@test "tick: a run-scoped item with no run id exits 7 and records nothing" {
  write_registry "$(item run-item judgment confirm run)"
  ck tick run-item --by agent:test
  [ "$status" -eq 7 ]
  [ -z "$output" ]
  assert_contains "$stderr" "needs a run id"
  [ ! -e "$STATE" ]
}

@test "tick run id: --run and JENGA_CHECKLIST_RUN_ID both name the run, and --run wins over the environment" {
  write_registry "$(item run-item judgment confirm run)"
  JENGA_CHECKLIST_RUN_ID="env-run" ck tick run-item --by agent:test
  [ "$status" -eq 0 ]
  [ "$output" = "ticked run-item (run env-run) by agent:test" ]
  JENGA_CHECKLIST_RUN_ID="env-run" ck tick run-item --run cli-run --by agent:test
  [ "$status" -eq 0 ]
  [ "$output" = "ticked run-item (run cli-run) by agent:test" ]
  [ -f "$STATE/$(run_file_name env-run)" ]
  [ -f "$STATE/$(run_file_name cli-run)" ]
  [ "$(jq -r '.run_id' "$STATE/$(run_file_name cli-run)")" = "cli-run" ]
  # list reads through the environment variable as well
  JENGA_CHECKLIST_RUN_ID="env-run" ck list pre-commit
  case "$(state_of run-item)" in "ticked(run) by agent:test at "*) ;; *) return 1 ;; esac
}

@test "tick: a run tick is visible under the same run id and NOT under a different one, nor with none" {
  write_registry "$(item run-item machine block run "touch '$T/marker-run'; exit 0")"
  ck tick run-item --run run-A --by agent:test
  [ "$status" -eq 0 ]

  ck list pre-commit --run run-A
  case "$(state_of run-item)" in "ticked(run) by agent:test at "*) ;; *) echo "not ticked under run-A: $output" >&2; return 1 ;; esac
  ck list pre-commit --run run-B
  [ "$(state_of run-item)" = "unticked" ]
  ck list pre-commit
  [ "$(state_of run-item)" = "unticked" ]
  # run ids are case-sensitive: "run-a" is a different run than "run-A" even on a case-insensitive filesystem
  ck list pre-commit --run run-a
  [ "$(state_of run-item)" = "unticked" ]

  # check: the same run skips the verify; another run evaluates it
  ck check pre-commit --run run-A
  [ "$status" -eq 0 ]
  [ "$(fld run-item result)" = "already_ticked" ]
  [ ! -e "$T/marker-run" ]
  ck check pre-commit --run run-B
  [ "$status" -eq 0 ]
  [ "$(fld run-item result)" = "passed" ]
  [ -e "$T/marker-run" ]
}

@test "tick: a run tick does not leak into the next run even when the next run ticks a sibling item" {
  write_registry "$(item first-item judgment confirm run)" "$(item second-item judgment confirm run)"
  ck tick first-item --run run-1 --by agent:test
  [ "$status" -eq 0 ]
  ck tick second-item --run run-2 --by agent:test
  [ "$status" -eq 0 ]
  ck list pre-commit --run run-2
  [ "$(state_of first-item)" = "unticked" ]
  case "$(state_of second-item)" in "ticked(run)"*) ;; *) return 1 ;; esac
  ck list pre-commit --run run-1
  case "$(state_of first-item)" in "ticked(run)"*) ;; *) return 1 ;; esac
  [ "$(state_of second-item)" = "unticked" ]
  # one state file per run id
  [ "$(ls "$STATE"/run-*.json | wc -l | tr -d ' ')" -eq 2 ]
}

@test "tick: a persistent tick is visible from a fresh process, whatever run id that process names" {
  write_registry "$(item keep-item machine block persistent "touch '$T/marker-keep'; exit 1")"
  ck tick keep-item --by agent:test
  [ "$status" -eq 0 ]
  local args
  for args in "" "--run some-other-run"; do
    # shellcheck disable=SC2086
    ck list pre-commit $args
    case "$(state_of keep-item)" in "ticked(persistent) by agent:test at "*) ;; *) echo "not ticked ($args): $output" >&2; return 1 ;; esac
    # shellcheck disable=SC2086
    ck check pre-commit $args
    [ "$status" -eq 0 ]
    [ "$(fld keep-item result)" = "already_ticked" ]
  done
  [ ! -e "$T/marker-keep" ]
}

@test "tick: a persistent item ignores a run id (it lands in persistent.json and creates no run file)" {
  write_registry "$(item keep-item judgment confirm persistent)"
  ck tick keep-item --run some-run --by agent:test
  [ "$status" -eq 0 ]
  [ "$output" = "ticked keep-item (persistent) by agent:test" ]
  [ -f "$STATE/persistent.json" ]
  if compgen -G "$STATE/run-*.json" >/dev/null; then
    echo "a run file was created for a persistent item" >&2
    return 1
  fi
}

@test "tick: the tick is looked up in the same registry list and check use (a tick for one item leaves the others unticked)" {
  write_registry "$(item first-item judgment confirm persistent)" "$(item second-item judgment confirm persistent)"
  ck tick first-item --by agent:test
  [ "$status" -eq 0 ]
  ck list pre-commit
  case "$(state_of first-item)" in "ticked(persistent)"*) ;; *) return 1 ;; esac
  [ "$(state_of second-item)" = "unticked" ]
  ck check pre-commit
  [ "$status" -eq 11 ]
  [ "$(fld first-item result)" = "already_ticked" ]
  [ "$(fld second-item result)" = "requires_confirmation" ]
}

@test "tick state location: without the test seam it lives under <queue>/checklist-ticks of the resolved root" {
  unset JENGA_CHECKLIST_STATE_DIR
  write_registry "$(item keep-item judgment confirm persistent)" "$(item run-item judgment confirm run)"
  ck tick keep-item --by agent:test
  [ "$status" -eq 0 ]
  ck tick run-item --run r1 --by agent:test
  [ "$status" -eq 0 ]
  [ -f "$PROJ/project/queue/checklist-ticks/persistent.json" ]
  [ -f "$PROJ/project/queue/checklist-ticks/$(run_file_name r1)" ]
}

# --- a tick is bound to the item's definition ---------------------------------------------------------------------

@test "tick binding: editing an item's text, verify or kind invalidates its persistent tick, with a warning" {
  local edit
  for edit in 'text:.items[0].text = "Reworded rule."' \
              'verify:.items[0].verify = "false"' \
              'kind:.items[0].kind = "judgment" | del(.items[0].verify)'; do
    export JENGA_CHECKLIST_STATE_DIR="$T/state-${edit%%:*}"
    write_registry "$(item edited-item machine block persistent true)"
    ck tick edited-item --by agent:test
    [ "$status" -eq 0 ]
    ck list pre-commit
    case "$(state_of edited-item)" in "ticked(persistent)"*) ;; *) echo "${edit%%:*}: not ticked before the edit" >&2; return 1 ;; esac

    mutate_registry "${edit#*:}"
    ck list pre-commit
    [ "$status" -eq 0 ]
    [ "$(state_of edited-item)" = "unticked" ] || { echo "${edit%%:*}: tick survived the edit: $output" >&2; return 1; }
    assert_contains "$stderr" "edited after it was ticked"
    ck check pre-commit
    [ "$(fld edited-item tick_state)" = "unticked" ]
    [ "$(fld edited-item result)" != "already_ticked" ]
  done
}

@test "tick binding: a tightened verify command is actually evaluated again after an edit" {
  write_registry "$(item edited-item machine block persistent true)"
  ck tick edited-item --by agent:test
  mutate_registry '.items[0].verify = "false"'
  ck check pre-commit
  [ "$status" -eq 10 ]
  [ "$(fld edited-item result)" = "failed" ]
}

@test "tick binding: the invalidation applies to run-scoped ticks too, and ticking again after the edit takes effect" {
  write_registry "$(item edited-item judgment confirm run)"
  ck tick edited-item --run r1 --by agent:test
  mutate_registry '.items[0].text = "Reworded rule."'
  ck list pre-commit --run r1
  [ "$(state_of edited-item)" = "unticked" ]
  assert_contains "$stderr" "edited after it was ticked"
  ck tick edited-item --run r1 --by agent:test
  [ "$status" -eq 0 ]
  ck list pre-commit --run r1
  case "$(state_of edited-item)" in "ticked(run) by agent:test at "*) ;; *) return 1 ;; esac
  [ -z "$stderr" ]
}

@test "tick binding (pinned judgment call): editing enforcement or situations does not invalidate a tick" {
  write_registry "$(item steady-item machine block persistent true)"
  ck tick steady-item --by agent:test
  mutate_registry '.items[0].enforcement = "advisory" | .items[0].situations = ["pre-commit", "pre-task"]'
  ck list pre-commit
  case "$(state_of steady-item)" in "ticked(persistent) by agent:test at "*) ;; *) echo "$output" >&2; return 1 ;; esac
  [ -z "$stderr" ]
}

# --- tick --clear -------------------------------------------------------------------------------------------------

@test "tick --clear: removes a persistent tick; list and check see it unticked again" {
  write_registry "$(item some-item judgment confirm persistent)" "$(item other-item judgment confirm persistent)"
  ck tick some-item --by agent:test
  ck tick other-item --by agent:test
  ck tick --clear some-item
  [ "$status" -eq 0 ]
  [ "$output" = "cleared tick for some-item" ]
  [ "$(jq -r '.ticks | has("some-item")' "$STATE/persistent.json")" = "false" ]
  ck list pre-commit
  [ "$(state_of some-item)" = "unticked" ]
  case "$(state_of other-item)" in "ticked(persistent)"*) ;; *) return 1 ;; esac
  ck check pre-commit
  [ "$(fld some-item result)" = "requires_confirmation" ]
  [ "$(fld other-item result)" = "already_ticked" ]
}

@test "tick --clear: is idempotent (nothing to remove still exits 0 and says so)" {
  write_registry "$(item some-item judgment confirm persistent)"
  ck tick some-item --by agent:test
  ck tick --clear some-item
  [ "$status" -eq 0 ]
  ck tick --clear some-item
  [ "$status" -eq 0 ]
  [ "$output" = "no tick recorded for some-item" ]
  [ -z "$stderr" ]
}

@test "tick --clear: with no state at all exits 0 and creates nothing" {
  write_registry "$(item some-item judgment confirm persistent)"
  ck tick --clear some-item
  [ "$status" -eq 0 ]
  [ "$output" = "no tick recorded for some-item" ]
  [ ! -e "$STATE" ]
}

@test "tick --clear: works for an item that was deleted from the registry, and when the registry is broken or absent" {
  write_registry "$(item doomed-item judgment confirm persistent)" "$(item staying-item judgment confirm persistent)"
  ck tick doomed-item --by agent:test
  ck tick staying-item --by agent:test
  # the item leaves the registry; a tick for it can still be removed
  mutate_registry 'del(.items[0])'
  ck tick --clear doomed-item
  [ "$status" -eq 0 ]
  [ "$output" = "cleared tick for doomed-item" ]
  [ "$(jq -r '.ticks | keys | join(",")' "$STATE/persistent.json")" = "staying-item" ]
  # a broken registry cannot prevent un-ticking
  printf '{ not json' > "$F"
  ck tick --clear staying-item
  [ "$status" -eq 0 ]
  [ "$output" = "cleared tick for staying-item" ]
  # and a repeat is still a harmless no-op
  ck tick --clear staying-item
  [ "$status" -eq 0 ]
  [ "$output" = "no tick recorded for staying-item" ]
}

@test "tick --clear --run: removes only that run's tick; another run's tick for the same item stays" {
  write_registry "$(item run-item judgment confirm run)"
  ck tick run-item --run run-1 --by agent:test
  ck tick run-item --run run-2 --by agent:test
  ck tick --clear run-item --run run-1
  [ "$status" -eq 0 ]
  [ "$output" = "cleared tick for run-item" ]
  ck list pre-commit --run run-1
  [ "$(state_of run-item)" = "unticked" ]
  ck list pre-commit --run run-2
  case "$(state_of run-item)" in "ticked(run) by agent:test at "*) ;; *) return 1 ;; esac
}

# --- exit 8: the tick was not recorded ----------------------------------------------------------------------------

@test "exit 8: a state directory that cannot be created is reported and nothing is recorded" {
  write_registry "$(item some-item judgment confirm persistent)"
  : > "$T/a-file"
  JENGA_CHECKLIST_STATE_DIR="$T/a-file/sub" ck tick some-item --by agent:test
  [ "$status" -eq 8 ]
  [ -z "$output" ]
  assert_contains "$stderr" "cannot create the tick state directory"
}

@test "exit 8: a lock that cannot be acquired means the tick is NOT recorded (never written unlocked)" {
  write_registry "$(item some-item judgment confirm persistent)"
  mkdir -p "$STATE/persistent.json.lock.d"
  export WITH_LOCK_TIMEOUT_SECONDS=1
  local start=$SECONDS
  ck tick some-item --by agent:test
  [ "$status" -eq 8 ]
  [ -z "$output" ]
  assert_contains "$stderr" "NOT recorded"
  [ ! -e "$STATE/persistent.json" ]
  [ $((SECONDS - start)) -lt 15 ]
}

# =============================================================================
# Concurrency: real parallel writers
# =============================================================================

@test "concurrency: 24 parallel ticks of different persistent items against one state dir all land (3 rounds)" {
  local n=24 round i id start=$SECONDS
  local -a items=() ids=()
  for i in $(seq -w 1 "$n"); do
    ids+=("item-$i")
    items+=("$(item "item-$i" judgment confirm persistent)")
  done
  write_registry "${items[@]}"
  export WITH_LOCK_TIMEOUT_SECONDS=45 WITH_LOCK_POLL_SECONDS=0.05

  for round in 1 2 3; do
    local sd="$T/state-round-$round" st="$T/status-round-$round"
    mkdir -p "$st"
    export JENGA_CHECKLIST_STATE_DIR="$sd"
    for id in "${ids[@]}"; do
      tick_bg "$st/$id.status" "$st/$id.err" "$id" --by "agent:round$round" 3>&- &
    done
    wait

    # every writer reported success ...
    [ "$(ls "$st"/*.status | wc -l | tr -d ' ')" -eq "$n" ]
    [ "$(cat "$st"/*.status | sort -u)" = "0" ] || { echo "round $round: a tick exited non-zero" >&2; cat "$st"/*.err >&2; return 1; }
    # ... and not one tick was lost to a racing writer
    [ "$(jq '.ticks | length' "$sd/persistent.json")" -eq "$n" ] || { echo "round $round: lost ticks: $(jq '.ticks | length' "$sd/persistent.json") of $n" >&2; return 1; }
    [ "$(jq -r '[.ticks[].ticked_by] | unique | join(",")' "$sd/persistent.json")" = "agent:round$round" ]
    ck list pre-commit
    [ "$(printf '%s\n' "$output" | grep -c "ticked(persistent) by agent:round$round at ")" -eq "$n" ]
    # no temp file or lock directory is left behind
    [ "$(ls -A "$sd")" = "persistent.json" ] || { echo "round $round: leftovers: $(ls -A "$sd")" >&2; return 1; }
  done
  [ $((SECONDS - start)) -lt 90 ]
}

@test "concurrency: two parallel ticks of a run-scoped item pair under the same run id both land (10 rounds)" {
  write_registry "$(item pair-a judgment confirm run)" "$(item pair-b judgment confirm run)"
  export WITH_LOCK_TIMEOUT_SECONDS=45 WITH_LOCK_POLL_SECONDS=0.05
  local round run_id start=$SECONDS
  for round in 1 2 3 4 5 6 7 8 9 10; do
    run_id="conc-run-$round"
    tick_bg "$T/a.status" "$T/a.err" pair-a --run "$run_id" --by agent:a 3>&- &
    tick_bg "$T/b.status" "$T/b.err" pair-b --run "$run_id" --by agent:b 3>&- &
    wait
    [ "$(cat "$T/a.status")" = "0" ] || { cat "$T/a.err" >&2; return 1; }
    [ "$(cat "$T/b.status")" = "0" ] || { cat "$T/b.err" >&2; return 1; }
    ck list pre-commit --run "$run_id"
    case "$(state_of pair-a)" in "ticked(run) by agent:a at "*) ;; *) echo "round $round: pair-a lost: $output" >&2; return 1 ;; esac
    case "$(state_of pair-b)" in "ticked(run) by agent:b at "*) ;; *) echo "round $round: pair-b lost: $output" >&2; return 1 ;; esac
  done
  # one shared file per run id, never one per writer
  [ "$(ls "$STATE"/run-*.json | wc -l | tr -d ' ')" -eq 10 ]
  [ $((SECONDS - start)) -lt 60 ]
}

@test "concurrency: many parallel ticks of run-scoped items under one run id all land in that run's file" {
  local n=12 i id start=$SECONDS
  local -a items=() ids=()
  for i in $(seq -w 1 "$n"); do
    ids+=("run-item-$i")
    items+=("$(item "run-item-$i" judgment confirm run)")
  done
  write_registry "${items[@]}"
  export WITH_LOCK_TIMEOUT_SECONDS=45 WITH_LOCK_POLL_SECONDS=0.05
  mkdir -p "$T/status"
  for id in "${ids[@]}"; do
    tick_bg "$T/status/$id.status" "$T/status/$id.err" "$id" --run shared-run --by agent:w 3>&- &
  done
  wait
  [ "$(cat "$T/status"/*.status | sort -u)" = "0" ] || { cat "$T/status"/*.err >&2; return 1; }
  [ "$(jq '.ticks | length' "$STATE/$(run_file_name shared-run)")" -eq "$n" ]
  ck list pre-commit --run shared-run
  [ "$(printf '%s\n' "$output" | grep -c 'ticked(run) by agent:w at ')" -eq "$n" ]
  [ $((SECONDS - start)) -lt 60 ]
}

# =============================================================================
# Stale-run pruning
# =============================================================================

@test "pruning: a stale run file is pruned by a later tick; a younger run's file and persistent.json are untouched" {
  write_registry "$(item run-item judgment confirm run)" "$(item keep-item judgment confirm persistent)"
  export JENGA_CHECKLIST_RUN_TTL_MINUTES=5
  ck tick run-item --run old-run --by agent:test
  ck tick run-item --run young-run --by agent:test
  ck tick keep-item --by agent:test
  local old="$STATE/$(run_file_name old-run)" young="$STATE/$(run_file_name young-run)"
  [ -f "$old" ]
  [ -f "$young" ]

  # one hour idle against a five-minute TTL; persistent.json is aged as well, to prove its age is irrelevant
  backdate "$old" 3600
  backdate "$STATE/persistent.json" 3600
  : > "$STATE/.tmp-run-dead.json.99999"
  backdate "$STATE/.tmp-run-dead.json.99999" 3600
  : > "$STATE/.tmp-run-live.json.99998"

  # before any pruning has happened the expired run already reads as unticked, persistent does not expire
  ck list pre-commit --run old-run
  [ "$(state_of run-item)" = "unticked" ]
  case "$(state_of keep-item)" in "ticked(persistent)"*) ;; *) return 1 ;; esac
  [ -f "$old" ]

  local before
  before="$(cksum < "$STATE/persistent.json")"
  ck tick run-item --run new-run --by agent:test
  [ "$status" -eq 0 ]
  [ ! -e "$old" ]
  [ -f "$young" ]
  [ -f "$STATE/$(run_file_name new-run)" ]
  [ -f "$STATE/persistent.json" ]
  [ "$(cksum < "$STATE/persistent.json")" = "$before" ]
  [ ! -e "$STATE/.tmp-run-dead.json.99999" ]
  [ -e "$STATE/.tmp-run-live.json.99998" ]

  ck list pre-commit --run young-run
  case "$(state_of run-item)" in "ticked(run) by agent:test at "*) ;; *) return 1 ;; esac
  case "$(state_of keep-item)" in "ticked(persistent) by agent:test at "*) ;; *) return 1 ;; esac
}

@test "pruning: with no stale file nothing is deleted" {
  write_registry "$(item run-item judgment confirm run)"
  export JENGA_CHECKLIST_RUN_TTL_MINUTES=5
  ck tick run-item --run run-1 --by agent:test
  ck tick run-item --run run-2 --by agent:test
  ck tick run-item --run run-3 --by agent:test
  [ "$(ls "$STATE"/run-*.json | wc -l | tr -d ' ')" -eq 3 ]
}

@test "pruning: persistent.json is never pruned however old, even by a tick that prunes other files" {
  write_registry "$(item run-item judgment confirm run)" "$(item keep-item judgment confirm persistent)"
  export JENGA_CHECKLIST_RUN_TTL_MINUTES=1
  ck tick keep-item --by agent:test
  backdate "$STATE/persistent.json" 86400
  ck tick run-item --run run-1 --by agent:test
  [ "$status" -eq 0 ]
  [ -f "$STATE/persistent.json" ]
  ck list pre-commit
  case "$(state_of keep-item)" in "ticked(persistent)"*) ;; *) return 1 ;; esac
}

# =============================================================================
# Corrupt state degrades to unticked, never to a pass
# =============================================================================

@test "corrupt persistent store: reads as unticked with a stderr warning (no traceback), check never passes it, next tick recovers" {
  write_registry "$(item keep-item machine block persistent false)"
  mkdir -p "$STATE"
  printf '{bad' > "$STATE/persistent.json"

  ck list pre-commit
  [ "$status" -eq 0 ]
  [ "$(state_of keep-item)" = "unticked" ]
  assert_contains "$stderr" "warning"
  assert_contains "$stderr" "is not valid JSON"
  assert_not_contains "$stderr" "Traceback"

  # the failing block item is evaluated, not skipped and not passed
  ck check pre-commit
  [ "$status" -eq 10 ]
  [ "$(fld keep-item result)" = "failed" ]
  [ "$(fld keep-item tick_state)" = "unticked" ]
  assert_not_contains "$stderr" "Traceback"

  # the next tick moves the unusable file aside and starts a fresh store
  ck tick keep-item --by agent:test
  [ "$status" -eq 0 ]
  assert_contains "$stderr" "starting a fresh one"
  assert_not_contains "$stderr" "Traceback"
  [ "$(jq -r '.ticks["keep-item"].ticked_by' "$STATE/persistent.json")" = "agent:test" ]
  [ "$(cat "$STATE/persistent.json.corrupt")" = "{bad" ]
  ck check pre-commit
  [ "$status" -eq 0 ]
  [ "$(fld keep-item result)" = "already_ticked" ]
}

@test "corrupt persistent store: a store that is not UTF-8, or has the wrong shape, also reads as unticked with a warning" {
  write_registry "$(item keep-item judgment confirm persistent)"
  mkdir -p "$STATE"
  printf '\377\376' > "$STATE/persistent.json"
  ck list pre-commit
  [ "$status" -eq 0 ]
  [ "$(state_of keep-item)" = "unticked" ]
  assert_contains "$stderr" "warning"
  assert_not_contains "$stderr" "Traceback"

  printf '{"version": 1, "ticks": []}' > "$STATE/persistent.json"
  ck list pre-commit
  [ "$status" -eq 0 ]
  [ "$(state_of keep-item)" = "unticked" ]
  assert_contains "$stderr" "does not have the expected structure"
  assert_not_contains "$stderr" "Traceback"
}

@test "corrupt run store: reads as unticked with a warning, is evaluated by check, and the next tick of that run recovers" {
  write_registry "$(item run-item machine block run false)"
  ck tick run-item --run r1 --by agent:test
  [ "$status" -eq 0 ]
  printf '{bad' > "$STATE/$(run_file_name r1)"

  ck list pre-commit --run r1
  [ "$status" -eq 0 ]
  [ "$(state_of run-item)" = "unticked" ]
  assert_contains "$stderr" "warning"
  assert_not_contains "$stderr" "Traceback"
  ck check pre-commit --run r1
  [ "$status" -eq 10 ]
  [ "$(fld run-item result)" = "failed" ]

  ck tick run-item --run r1 --by agent:test
  [ "$status" -eq 0 ]
  assert_not_contains "$stderr" "Traceback"
  ck check pre-commit --run r1
  [ "$status" -eq 0 ]
  [ "$(fld run-item result)" = "already_ticked" ]
}

# =============================================================================
# The real registries
# =============================================================================

@test "the shipped default and this project's instance both parse through list and check without error" {
  # Content may change; only the shape of the answer and the exit-code class are asserted. Verify commands run from
  # the real repository root here (they are read-only git queries); tick state still goes to the temp dir.
  export JENGA_PROJECT_ROOT="$REPO_ROOT"
  export JENGA_CHECKLIST_VERIFY_TIMEOUT=30
  local which sit
  for which in default instance; do
    if [ "$which" = "default" ]; then
      export JENGA_CHECKLISTS_FILE="$T/no-such-instance.json"
      export JENGA_CHECKLISTS_DEFAULT_FILE="$REPO_ROOT/templates/checklists.json"
    else
      export JENGA_CHECKLISTS_FILE="$REPO_ROOT/project/configs/checklists.json"
      export JENGA_CHECKLISTS_DEFAULT_FILE="$T/no-such-default.json"
    fi
    for sit in pre-commit pre-task pre-release pre-reconcile; do
      ck list "$sit"
      [ "$status" -eq 0 ] || { echo "$which: list $sit exited $status: $stderr" >&2; return 1; }
      assert_not_contains "$stderr" "Traceback"
    done
    # Only situations whose verify commands are cheap are run for real (the default's pre-release `git status` is slow
    # on a large working tree); list above already covers every situation of both files.
    for sit in $([ "$which" = "default" ] && echo "pre-commit pre-reconcile" || echo "pre-commit pre-release"); do
      ck check "$sit"
      case "$status" in 0|10|11) ;; *) echo "$which: check $sit exited $status: $stderr" >&2; return 1 ;; esac
      assert_valid_report
    done
  done
  [ ! -e "$STATE" ]
}
