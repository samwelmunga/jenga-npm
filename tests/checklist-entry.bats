#!/usr/bin/env bats
#
# Coverage for the checklist management surface (E67_S10_T05): skills/j-checklist/scripts/checklist-entry.sh
# (add, edit, remove, copy, move), checklist-print.sh (the renderer) and, as extra scope, checklist-instance.sh
# (added by E67_S10_T04 outside that task's file list, with no tests of its own until now).
#
# Contract under test: the header comments of those three scripts and project/documentation/preflight-checklists.md
# ("Editing a registry (E67_S10_T02)", "Copying and moving between registries (E67_S10_T03)", "Printing a registry
# (E67_S10_T01)").
#
# The seven behaviours the task names, each a property a future change could silently break:
#   1. append, not replace        2. a failed validation leaves the original intact   3. conv- refusal
#   4. collision refusal          5. seed on first instance                           6. move atomicity per stage
#   7. rendered lines satisfy `ranked_list`, checked by the REAL verifier (scripts/workflow/verify-output.sh)
#
# Isolation (the E67_S09 lesson: a test that asserted on the live tree failed an unrelated gate run). Every registry
# here is generated at test time under $BATS_TEST_TMPDIR, which bats creates beneath its own run directory and removes
# afterwards; no fixture file exists in the repository, and no case reads or writes the live
# project/configs/checklists.json, the live templates/checklists.json, the real rapports directory or the real
# `git status`. setup() points every seam of the scripts into the temp dir:
#   JENGA_CHECKLISTS_FILE          the project instance        -> $F (never created unless a test writes it)
#   JENGA_CHECKLISTS_DEFAULT_FILE  the shipped default         -> $DEFAULT, a temp registry (seed source)
#   JENGA_CHECKLIST_STATE_DIR      the tick store              -> $STATE
#   JENGA_PROJECT_ROOT             the resolved root           -> $PROJ, a temp tree with a stub workflow.json
# Every case that writes names its registry with an explicit --registry, so a forgotten argument would hit the
# non-existent $F (exit 4) and fail loudly instead of reaching a real file. checklist-instance.sh makes scratch
# directories in $TMPDIR; those cases point TMPDIR at $T/tmp. The one write the scripts cannot be redirected from is
# the real templates/checklists.json that checklist-entry.sh reads (never writes) to recognise "the shipped default";
# no assertion depends on it.
#
# Cleanup that survives a kill. All fixtures sit under bats' run directory, never in the repo, so a killed run leaves
# nothing in the working tree. teardown() additionally kills any fixture process a test started (the three tests that
# pause a script on purpose), checking the command line first so a recycled pid is never signalled; it runs when a
# test fails, and bats runs it again after a SIGINT/SIGTERM of the suite.
#
# Streams. The scripts write results to stdout and diagnostics to stderr. Tests use `run --separate-stderr` (helpers
# `ce`, `cp_print`, `ci`), so $output is stdout only and $stderr is stderr only.
#
# Assertions must be able to fail (the E50_S07_T07 finding: 37 assertions passed while false). Each case was observed
# red once by breaking the behaviour it covers; the list is in the "Test notes" section of the task file
# project/board/tasks/E67_S10_T05_management-surface-tests.md and in the execution summary. Shape of the guard used
# throughout: every "unchanged" assertion is paired, in the same file, with a control that proves the same command
# really does change the file when nothing is injected.
#
# KNOWN LIMITS pinned as explicit tests (comment "KNOWN LIMIT" above each). They describe what the scripts do TODAY
# and are documented in the T03 summary and in skills/j-checklist/SKILL.md ("Known limits"). They are not endorsements:
# the day one is fixed, its test goes red on purpose and the fix should rewrite the test, not delete it.
#   (1) locks key on the path as given, so two spellings of one file do not exclude each other;
#   (2) SIGKILL between the two replaces of a `move` leaves a <target>.rollback.<pid> file behind;
#   (3) SIGTERM sent only to the top-level script does not stop the with-lock.sh child.
# (2) and (3) need a script paused at an exact point, and the scripts offer no pause seam (JENGA_CHECKLIST_ENTRY_FAIL_AT
# only fails). The least invasive way, with no edit to any script, is a PATH stub that stops at a rendezvous (a marker
# file plus a FIFO) and then delegates to the real binary: `mv` for (2), `python3` for (3). The test waits on the
# marker, not on a sleep, so ordering is deterministic.
#
# Not tested, on purpose: the wizard prose in SKILL.md (judgment, not code); a SIGKILL of the suite itself (no process
# can clean up after that, which is why fixtures never live in the repo).

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ENTRY="$REPO_ROOT/skills/j-checklist/scripts/checklist-entry.sh"
PRINT="$REPO_ROOT/skills/j-checklist/scripts/checklist-print.sh"
INSTANCE="$REPO_ROOT/skills/j-checklist/scripts/checklist-instance.sh"
CHECKLIST="$REPO_ROOT/scripts/checklist.sh"
VALIDATOR="$REPO_ROOT/scripts/validate-checklists.sh"
VERIFY="$REPO_ROOT/scripts/workflow/verify-output.sh"

setup() {
  T="$BATS_TEST_TMPDIR"
  F="$T/instance.json"
  DEFAULT="$T/default-checklists.json"
  STATE="$T/state"
  PROJ="$T/proj"
  SRC="$T/source.json"
  TGT="$T/target.json"
  GATE="$T/gate"
  mkdir -p "$PROJ/project/configs" "$T/tmp" "$T/snap" "$T/bin"
  echo '{}' > "$PROJ/project/configs/workflow.json"
  export JENGA_PROJECT_ROOT="$PROJ"
  export JENGA_CHECKLISTS_FILE="$F"
  export JENGA_CHECKLISTS_DEFAULT_FILE="$DEFAULT"
  export JENGA_CHECKLIST_STATE_DIR="$STATE"
  unset JENGA_CHECKLIST_ENTRY_FAIL_AT JENGA_CHECKLIST_RENDER_TEMPLATE JENGA_CHECKLIST_RUN_ID JENGA_CHECKLIST_ACTOR
  unset WITH_LOCK_TIMEOUT_SECONDS WITH_LOCK_POLL_SECONDS WITH_LOCK_STALE_SECONDS GATE_DIR GATE_PY_OP GATE_MV_DEST
}

# Kills the fixture processes the pausing tests start. The command line must name this test's own temp dir (the stubs
# live in $T/bin) so a recycled pid can never make this signal an unrelated process. Then the FIFO is written once, which
# releases any reader still blocked on it (a no-op when nothing is blocked).
teardown() {
  local f pid
  for f in "$GATE"/py.pid "$GATE"/mv.pid "$GATE"/parent.pid "$GATE"/top.pid; do
    [ -s "$f" ] || continue
    pid="$(cat "$f")"
    if ps -p "$pid" -o command= 2>/dev/null | grep -q "$T"; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  done
  if [ -p "$GATE/release" ]; then
    release_gate || true
  fi
}

# -----------------------------------------------------------------------------
# Fixture builders
# -----------------------------------------------------------------------------

# item <id> <kind> <enforcement> <tick_scope> [verify]  -> one registry item as compact JSON on stdout.
# SIT (a JSON array, default ["pre-commit"]) and PROV (a JSON object, default none) are optional overrides.
item() {
  local sit="${SIT:-}"
  [ -n "$sit" ] || sit='["pre-commit"]'
  jq -nc --arg id "$1" --arg kind "$2" --arg enf "$3" --arg scope "$4" --arg verify "${5:-true}" \
    --arg text "${TEXT:-Item $1.}" --arg prov "${PROV:-}" --argjson sit "$sit" \
    '{id: $id, text: $text, situations: $sit, kind: $kind, enforcement: $enf, tick_scope: $scope}
     + (if $kind == "machine" then {verify: $verify} else {} end)
     + (if $prov != "" then {provenance: ($prov | fromjson)} else {} end)'
}

# registry_to <file> <item-json>...  -> a valid registry (expanded style) that declares the extra situation
# "pre-deploy" and carries an extra top-level key, so "other top-level keys intact" is checkable.
registry_to() {
  local out="$1"
  shift
  if [ "$#" -eq 0 ]; then
    jq -n '{checklist_version: 1, _comment: "keep me", situations: ["pre-deploy"], items: []}' > "$out"
  else
    printf '%s\n' "$@" | jq -s '{checklist_version: 1, _comment: "keep me", situations: ["pre-deploy"], items: .}' > "$out"
  fi
}

# The shipped default: a temp registry of three items, the seed source for a first instance.
write_default() {
  registry_to "$DEFAULT" "$(item shipped-one judgment advisory run)" \
    "$(SIT='["pre-task"]' item shipped-two machine confirm run 'echo shipped')" \
    "$(SIT='["pre-commit", "pre-deploy"]' item shipped-three judgment confirm persistent)"
}

# add_args <id> -> the argument list of a valid `add`, in $ADD (an array).
add_args() {
  ADD=(add --id "$1" --text "Added item $1." --situation pre-task --kind judgment --enforcement confirm --tick-scope run)
}

# -----------------------------------------------------------------------------
# Runners and readers
# -----------------------------------------------------------------------------

# ce <args...>: run the entry script; $output is stdout, $stderr is stderr, $status the exit code.
ce() { run --separate-stderr bash "$ENTRY" "$@"; }
# cp_print <args...>: run the renderer.
cp_print() { run --separate-stderr bash "$PRINT" "$@"; }
# ci <args...>: run the instance helper, with its scratch directories made inside the temp dir.
ci() { run --separate-stderr env "TMPDIR=$T/tmp" bash "$INSTANCE" "$@"; }

# snap <file>: remember the file's exact bytes (and, via unchanged, its mode) under its own base name.
snap() { cp -p "$1" "$T/snap/$(basename "$1")"; }
# unchanged <file>: byte-identical to its snapshot.
unchanged() {
  if ! cmp -s "$T/snap/$(basename "$1")" "$1"; then
    echo "$1 changed; diff against its snapshot:" >&2
    diff "$T/snap/$(basename "$1")" "$1" >&2 || true
    return 1
  fi
}

# assert_pure_insertion <old> <new>: <new> is <old> with exactly one contiguous run of bytes inserted, i.e. every
# pre-existing byte is present, unchanged and in the same order. (Common prefix p; the rest of old must equal the rest of
# new after skipping the inserted length; any valid insertion point is <= p, and then p works too.)
assert_pure_insertion() {
  python3 - "$1" "$2" <<'PY'
import sys
old = open(sys.argv[1], "rb").read()
new = open(sys.argv[2], "rb").read()
m = len(new) - len(old)
if m <= 0:
    sys.exit("new file (%d bytes) is not longer than the old one (%d bytes)" % (len(new), len(old)))
p = 0
n = min(len(old), len(new))
while p < n and old[p] == new[p]:
    p += 1
if old[p:] != new[p + m:]:
    sys.exit("not a pure insertion: after byte %d the old tail differs from the new tail" % p)
PY
}

# assert_no_leftovers: no candidate, rollback or lock directory is left anywhere in the fixture tree.
assert_no_leftovers() {
  local left
  left="$(find "$T" \( -name '*.candidate.*' -o -name '*.rollback.*' -o -name '*.lock.d' \) -print)"
  if [ -n "$left" ]; then
    echo "leftover files:" >&2
    printf '%s\n' "$left" >&2
    return 1
  fi
}

# ids <file>: the item ids of a registry, one per line, in order.
ids() { jq -r '.items[].id' "$1"; }

# valid <file>: the real validator passes the file.
valid() { bash "$VALIDATOR" "$1" >/dev/null 2>&1; }

# has_id <file> <id>: the registry holds an item with that id.
has_id() { ids "$1" | grep -qx "$2"; }

# refute <command...>: the command must FAIL. (A bare `! cmd` does not fail a bats test, because errexit ignores a
# negated command, so a negative assertion written that way would be inert.)
refute() {
  if "$@"; then
    echo "expected failure, but this succeeded: $*" >&2
    return 1
  fi
}

# wait_for_file <path>: bounded poll (up to ~10 s) for a rendezvous marker a stub writes. This is not a sleep standing in
# for ordering: the marker is written only once the stub has reached the exact point the test needs.
wait_for_file() {
  local i=0
  while [ ! -e "$1" ] && [ "$i" -lt 200 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$1" ]
}

# wait_dead <pid>: bounded poll (up to ~10 s) until the process has exited. A background child of this shell that has
# exited but is not yet reaped shows up as a zombie, so a zombie counts as dead; `kill -0` would not tell. Used before
# `wait <pid>` so that a script that fails to stop turns into a test failure instead of a hang.
wait_dead() {
  local i=0 st
  while [ "$i" -lt 200 ]; do
    st="$(ps -p "$1" -o stat= 2>/dev/null | tr -d ' ')"
    case "$st" in "" | Z*) return 0 ;; esac
    sleep 0.05
    i=$((i + 1))
  done
  echo "process $1 is still running after 10 s" >&2
  return 1
}

# install_stubs: PATH stubs for the two pausing tests. Each pauses ONLY at the one call the test names (GATE_PY_OP /
# GATE_MV_DEST), writes its pids and a "reached" marker, blocks reading a FIFO, then delegates to the real binary, so
# the scripts under test run unmodified. Everywhere else the stubs are pass-through. The FIFO is opened read-write (an
# open that never blocks, and that keeps a "go" written early from being lost) and the read gives up after 30 s, so a
# stub whose test was killed cannot outlive it by more than that.
install_stubs() {
  local real_python real_mv
  real_python="$(command -v python3)"
  real_mv="$(command -v mv)"
  mkdir -p "$GATE"
  mkfifo "$GATE/release"
  cat > "$T/bin/python3" <<EOF
#!/bin/bash
# test stub $T/bin/python3: pause the engine call of one operation, then run the real python3.
if [ -n "\${GATE_DIR:-}" ] && [ "\${1:-}" = "-" ] && [ "\${2:-}" = "\${GATE_PY_OP:-}" ]; then
  echo \$\$ > "\$GATE_DIR/py.pid"
  exec 5<>"\$GATE_DIR/release"
  : > "\$GATE_DIR/reached"
  read -r -t 30 _ <&5
fi
exec "$real_python" "\$@"
EOF
  cat > "$T/bin/mv" <<EOF
#!/bin/bash
# test stub $T/bin/mv: pause the replace whose destination is GATE_MV_DEST, then run the real mv.
for last; do :; done
if [ -n "\${GATE_DIR:-}" ] && [ "\$last" = "\${GATE_MV_DEST:-}" ]; then
  echo \$PPID > "\$GATE_DIR/parent.pid"
  echo \$\$ > "\$GATE_DIR/mv.pid"
  exec 5<>"\$GATE_DIR/release"
  : > "\$GATE_DIR/reached"
  read -r -t 30 _ <&5
fi
exec "$real_mv" "\$@"
EOF
  chmod +x "$T/bin/python3" "$T/bin/mv"
}

# release_gate: let every stub blocked on the FIFO continue. The FIFO is opened read-write, so this never blocks.
release_gate() {
  exec 4<>"$GATE/release"
  echo go >&4
  exec 4>&-
}

# =============================================================================
# 1. Append, not replace
# =============================================================================

@test "add (expanded file): the result is the old file plus one inserted item, nothing else moved" {
  registry_to "$SRC" "$(item first machine block run 'echo "[a, b]" | grep -q "{"; true')" \
    "$(TEXT='Text with [brackets], {braces}, a comma, and "quotes".' item second judgment confirm persistent)" \
    "$(SIT='["pre-commit", "pre-deploy"]' item third judgment advisory run)"
  snap "$SRC"
  add_args new-item
  ce --registry "$SRC" "${ADD[@]}"
  [ "$status" -eq 0 ]
  assert_output_contains '"action":"add"'
  assert_output_contains '"changed":true'
  assert_pure_insertion "$T/snap/source.json" "$SRC"
  # same facts through the parsed document: originals deep-equal and unreordered, the new item last, other keys intact
  [ "$(jq -c '.items[:3]' "$SRC")" = "$(jq -c '.items' "$T/snap/source.json")" ]
  [ "$(ids "$SRC" | tail -n 1)" = "new-item" ]
  [ "$(jq -c 'del(.items)' "$SRC")" = "$(jq -c 'del(.items)' "$T/snap/source.json")" ]
  [ "$(jq -r '.items | length' "$SRC")" = "4" ]
  [ "$(jq -r '.items[3].provenance.source' "$SRC")" = "authored" ]
  valid "$SRC"
  assert_no_leftovers
}

@test "add (inline-array file written by hand): old bytes stay, the file keeps its style" {
  cat > "$SRC" <<'EOF'
{
  "checklist_version": 1,
  "situations": ["pre-deploy"],
  "note":   "odd   spacing is kept",
  "items": [
    {"id": "first", "text": "First.", "situations": ["pre-commit"], "kind": "judgment", "enforcement": "advisory", "tick_scope": "run"}
  ]
}
EOF
  snap "$SRC"
  add_args new-item
  ce --registry "$SRC" "${ADD[@]}"
  [ "$status" -eq 0 ]
  assert_pure_insertion "$T/snap/source.json" "$SRC"
  assert_contains "$(cat "$SRC")" '"situations": ["pre-task"]'
  [ "$(ids "$SRC" | tr '\n' ' ')" = "first new-item " ]
  valid "$SRC"
}

@test "add (CRLF file): the old bytes survive and the inserted text uses CRLF too" {
  registry_to "$SRC" "$(item first judgment advisory run)"
  sed 's/$/\r/' "$T/source.json" > "$T/crlf.json" && mv "$T/crlf.json" "$SRC"
  snap "$SRC"
  add_args new-item
  ce --registry "$SRC" "${ADD[@]}"
  [ "$status" -eq 0 ]
  assert_pure_insertion "$T/snap/source.json" "$SRC"
  # no bare LF anywhere: every line (counted by its line feed) ends in a carriage return
  [ "$(LC_ALL=C grep -c $'\r$' "$SRC")" -eq "$(wc -l < "$SRC" | tr -d ' ')" ]
  valid "$SRC"
}

@test "add into an empty items array appends the first item and keeps every other key" {
  registry_to "$SRC"
  snap "$SRC"
  add_args only-item
  ce --registry "$SRC" "${ADD[@]}"
  [ "$status" -eq 0 ]
  [ "$(ids "$SRC")" = "only-item" ]
  [ "$(jq -c 'del(.items)' "$SRC")" = "$(jq -c 'del(.items)' "$T/snap/source.json")" ]
  valid "$SRC"
}

@test "remove of the last item deletes only that item's bytes (the mirror image of append)" {
  registry_to "$SRC" "$(item first judgment advisory run)" "$(item second judgment advisory run)" "$(item third judgment advisory run)"
  snap "$SRC"
  ce --registry "$SRC" remove third
  [ "$status" -eq 0 ]
  # old = new + one contiguous deletion
  assert_pure_insertion "$SRC" "$T/snap/source.json"
  [ "$(ids "$SRC" | tr '\n' ' ')" = "first second " ]
  valid "$SRC"
}

@test "edit changes only the target item; the other items stay byte-identical in the file" {
  registry_to "$SRC" "$(item first judgment advisory run)" "$(item second judgment advisory run)" "$(item third judgment advisory run)"
  snap "$SRC"
  ce --registry "$SRC" edit second --enforcement block --text "Second, reworded."
  [ "$status" -eq 0 ]
  assert_output_contains '"changed":true'
  [ "$(jq -c '.items[0]' "$SRC")" = "$(jq -c '.items[0]' "$T/snap/source.json")" ]
  [ "$(jq -c '.items[2]' "$SRC")" = "$(jq -c '.items[2]' "$T/snap/source.json")" ]
  [ "$(jq -r '.items[1].enforcement' "$SRC")" = "block" ]
  # the text before the edited item and the text from the next item on are byte-for-byte what they were
  cmp -s <(sed -n '1,/"id": "second"/p' "$T/snap/source.json") <(sed -n '1,/"id": "second"/p' "$SRC")
  cmp -s <(sed -n '/"id": "third"/,$p' "$T/snap/source.json") <(sed -n '/"id": "third"/,$p' "$SRC")
  valid "$SRC"
}

@test "append control: add really changes the file (a no-op would make the assertions above vacuous)" {
  registry_to "$SRC" "$(item first judgment advisory run)"
  snap "$SRC"
  add_args new-item
  ce --registry "$SRC" "${ADD[@]}"
  [ "$status" -eq 0 ]
  refute cmp -s "$T/snap/source.json" "$SRC"
}

# =============================================================================
# 2. A failed validation leaves the original intact
# =============================================================================
# The registry is given an item with an invalid kind the script itself did not write, so every candidate built from it
# fails scripts/validate-checklists.sh while the script's own input rules (which check the NEW item) pass.

# bad_registry <file> -> a registry whose first item has kind "bogus" (invalid), second is fine.
bad_registry() {
  registry_to "$1" "$(item broken judgment advisory run | jq -c '.kind = "bogus"')" "$(item fine judgment advisory run)"
}

@test "failed validation, add: exit 11, registry byte-identical, validator lines on stderr, no candidate left" {
  bad_registry "$SRC"
  snap "$SRC"
  add_args new-item
  ce --registry "$SRC" "${ADD[@]}"
  [ "$status" -eq 11 ]
  [ -z "$output" ]
  assert_contains "$stderr" "failed validation"
  assert_contains "$stderr" "unknown kind"
  # the candidate path is rewritten to the registry the user named
  assert_not_contains "$stderr" ".candidate."
  unchanged "$SRC"
  assert_no_leftovers
}

@test "failed validation, edit: exit 11, registry byte-identical" {
  bad_registry "$SRC"
  snap "$SRC"
  ce --registry "$SRC" edit fine --text "Reworded."
  [ "$status" -eq 11 ]
  unchanged "$SRC"
  assert_no_leftovers
}

@test "failed validation, remove: exit 11, registry byte-identical" {
  bad_registry "$SRC"
  snap "$SRC"
  ce --registry "$SRC" remove fine
  [ "$status" -eq 11 ]
  unchanged "$SRC"
  assert_no_leftovers
}

@test "failed validation, copy: exit 11, existing target byte-identical, source untouched" {
  registry_to "$SRC" "$(item mover judgment advisory run)"
  bad_registry "$TGT"
  snap "$SRC"
  snap "$TGT"
  ce --registry "$SRC" copy mover --to "$TGT"
  [ "$status" -eq 11 ]
  unchanged "$TGT"
  unchanged "$SRC"
  assert_no_leftovers
}

@test "failed validation, move: exit 11, both files byte-identical" {
  registry_to "$SRC" "$(item mover judgment advisory run)"
  bad_registry "$TGT"
  snap "$SRC"
  snap "$TGT"
  ce --registry "$SRC" move mover --to "$TGT"
  [ "$status" -eq 11 ]
  unchanged "$TGT"
  unchanged "$SRC"
  assert_no_leftovers
}

@test "failed validation control: the same add on a valid registry does change it" {
  registry_to "$SRC" "$(item fine judgment advisory run)"
  snap "$SRC"
  add_args new-item
  ce --registry "$SRC" "${ADD[@]}"
  [ "$status" -eq 0 ]
  refute cmp -s "$T/snap/source.json" "$SRC"
}

@test "input-rule failure (exit 7) leaves the registry byte-identical, one stderr line per violation" {
  registry_to "$SRC" "$(item fine judgment advisory run)"
  snap "$SRC"
  ce --registry "$SRC" add --id "Not Kebab" --text "x" --situation pre-task --kind machine --enforcement loud --tick-scope run
  [ "$status" -eq 7 ]
  [ "$(printf '%s\n' "$stderr" | grep -c '^checklist-entry.sh: invalid ')" -ge 3 ]
  unchanged "$SRC"
  assert_no_leftovers
}

# =============================================================================
# 3. conv- refusal
# =============================================================================
# Managed means BOTH: the id starts with "conv-" AND provenance.source is "convention".

managed_fixture() {
  registry_to "$SRC" \
    "$(PROV='{"source": "convention", "category": "naming"}' item conv-naming judgment advisory run)" \
    "$(PROV='{"source": "authored"}' item conv-handmade judgment advisory run)" \
    "$(item conv-bare judgment advisory run)" \
    "$(PROV='{"source": "convention", "category": "naming"}' item not-prefixed judgment advisory run)"
  registry_to "$TGT" "$(item target-one judgment advisory run)"
  snap "$SRC"
  snap "$TGT"
}

@test "conv- refusal, edit: exit 10, names j.conventions, registry byte-identical" {
  managed_fixture
  ce --registry "$SRC" edit conv-naming --text "Hand edit."
  [ "$status" -eq 10 ]
  assert_contains "$stderr" "j.conventions"
  unchanged "$SRC"
  assert_no_leftovers
}

@test "conv- refusal, remove: exit 10, names j.conventions, registry byte-identical" {
  managed_fixture
  ce --registry "$SRC" remove conv-naming
  [ "$status" -eq 10 ]
  assert_contains "$stderr" "j.conventions"
  unchanged "$SRC"
  assert_no_leftovers
}

@test "conv- refusal, copy: exit 10, neither file changed" {
  managed_fixture
  ce --registry "$SRC" copy conv-naming --to "$TGT"
  [ "$status" -eq 10 ]
  assert_contains "$stderr" "j.conventions"
  unchanged "$SRC"
  unchanged "$TGT"
  assert_no_leftovers
}

@test "conv- refusal, move: exit 10, neither file changed" {
  managed_fixture
  ce --registry "$SRC" move conv-naming --to "$TGT"
  [ "$status" -eq 10 ]
  assert_contains "$stderr" "j.conventions"
  unchanged "$SRC"
  unchanged "$TGT"
  assert_no_leftovers
}

@test "conv- refusal into a target that does not exist yet creates nothing" {
  managed_fixture
  ce --registry "$SRC" copy conv-naming --to "$T/brand-new.json"
  [ "$status" -eq 10 ]
  [ ! -e "$T/brand-new.json" ]
}

@test "not managed: a conv- id with authored provenance is edited, copied, moved and removed like any item" {
  managed_fixture
  ce --registry "$SRC" edit conv-handmade --text "Hand edit is allowed."
  [ "$status" -eq 0 ]
  [ "$(jq -r '.items[] | select(.id == "conv-handmade") | .text' "$SRC")" = "Hand edit is allowed." ]
  ce --registry "$SRC" copy conv-handmade --to "$TGT"
  [ "$status" -eq 0 ]
  [ "$(ids "$TGT" | tr '\n' ' ')" = "target-one conv-handmade " ]
  registry_to "$T/other-target.json" "$(item target-two judgment advisory run)"
  ce --registry "$SRC" move conv-handmade --to "$T/other-target.json"
  [ "$status" -eq 0 ]
  refute has_id "$SRC" conv-handmade
  ce --registry "$TGT" remove conv-handmade
  [ "$status" -eq 0 ]
}

@test "not managed: a conv- id with no provenance at all is an ordinary item" {
  managed_fixture
  ce --registry "$SRC" remove conv-bare
  [ "$status" -eq 0 ]
  refute has_id "$SRC" conv-bare
}

@test "not managed: convention provenance without the conv- id prefix is an ordinary item" {
  managed_fixture
  ce --registry "$SRC" edit not-prefixed --text "Not generated, so editable."
  [ "$status" -eq 0 ]
  [ "$(jq -r '.items[] | select(.id == "not-prefixed") | .text' "$SRC")" = "Not generated, so editable." ]
}

# =============================================================================
# 4. Collision refusal
# =============================================================================

@test "collision, copy: a target already holding the id is refused (exit 8) and left byte-identical" {
  registry_to "$SRC" "$(TEXT='From the source.' item dup judgment advisory run)"
  registry_to "$TGT" "$(TEXT='Already in the target.' item dup judgment confirm persistent)" "$(item other judgment advisory run)"
  snap "$SRC"
  snap "$TGT"
  ce --registry "$SRC" copy dup --to "$TGT"
  [ "$status" -eq 8 ]
  assert_contains "$stderr" "id collision"
  # not overwritten, not renamed
  unchanged "$TGT"
  unchanged "$SRC"
  assert_no_leftovers
}

@test "collision, move: refused (exit 8), the item stays in the source, both files byte-identical" {
  registry_to "$SRC" "$(item dup judgment advisory run)"
  registry_to "$TGT" "$(item dup judgment confirm persistent)"
  snap "$SRC"
  snap "$TGT"
  ce --registry "$SRC" move dup --to "$TGT"
  [ "$status" -eq 8 ]
  unchanged "$TGT"
  unchanged "$SRC"
}

@test "collision, add: an existing id is refused (exit 8) and the registry is byte-identical" {
  registry_to "$SRC" "$(item dup judgment advisory run)"
  snap "$SRC"
  add_args dup
  ce --registry "$SRC" "${ADD[@]}"
  [ "$status" -eq 8 ]
  unchanged "$SRC"
}

@test "collision while seeding: an id that is one of the shipped items is refused and the target is never created" {
  write_default
  registry_to "$SRC" "$(item shipped-two judgment advisory run)"
  snap "$SRC"
  ce --registry "$SRC" copy shipped-two --to "$TGT"
  [ "$status" -eq 8 ]
  assert_contains "$stderr" "shipped items"
  [ ! -e "$TGT" ]
  unchanged "$SRC"
}

@test "collision control: the same copy with a free id lands" {
  registry_to "$SRC" "$(item dup judgment advisory run)"
  registry_to "$TGT" "$(item other judgment advisory run)"
  ce --registry "$SRC" copy dup --to "$TGT"
  [ "$status" -eq 0 ]
  [ "$(ids "$TGT" | tr '\n' ' ')" = "other dup " ]
}

@test "a situation the target does not declare is refused (exit 12) and nothing is written" {
  registry_to "$SRC" "$(SIT='["pre-deploy"]' item deployer judgment advisory run)"
  jq '.situations = [] | .items = []' "$SRC" > "$TGT"
  snap "$SRC"
  snap "$TGT"
  ce --registry "$SRC" copy deployer --to "$TGT"
  [ "$status" -eq 12 ]
  unchanged "$TGT"
  unchanged "$SRC"
}

# =============================================================================
# 5. Seed on first instance
# =============================================================================

@test "seed, copy: a target with no instance ends up with the shipped items plus the incoming one, and says so" {
  write_default
  registry_to "$SRC" "$(PROV='{"source": "authored"}' item incoming machine confirm persistent 'echo incoming')"
  snap "$SRC"
  [ ! -e "$TGT" ]
  ce --registry "$SRC" copy incoming --to "$TGT"
  [ "$status" -eq 0 ]
  # the seed is reported, on stdout, before the result line
  [ "$(printf '%s\n' "$output" | head -n 1 | cut -c1-7)" = "SEEDED:" ]
  [ "$(printf '%s\n' "$output" | tail -n 1 | jq -r '.seeded')" = "true" ]
  [ "$(printf '%s\n' "$output" | tail -n 1 | jq -r '.seeded_items')" = "3" ]
  [ "$(printf '%s\n' "$output" | tail -n 1 | jq -r '.seed_source')" = "$DEFAULT" ]
  # every shipped item present, byte-for-byte the seed plus one inserted item, the incoming one last
  [ "$(ids "$TGT" | tr '\n' ' ')" = "shipped-one shipped-two shipped-three incoming " ]
  [ "$(jq -c '.items[:3]' "$TGT")" = "$(jq -c '.items' "$DEFAULT")" ]
  assert_pure_insertion "$DEFAULT" "$TGT"
  # provenance travels verbatim with the item; the source keeps it
  [ "$(jq -c '.items[3]' "$TGT")" = "$(jq -c '.items[0]' "$SRC")" ]
  valid "$TGT"
  unchanged "$SRC"
  assert_no_leftovers
}

@test "seed, move: the same seeding, and the item leaves the source" {
  write_default
  registry_to "$SRC" "$(item incoming judgment advisory run)" "$(item stays judgment advisory run)"
  ce --registry "$SRC" move incoming --to "$TGT"
  [ "$status" -eq 0 ]
  assert_output_contains "SEEDED:"
  [ "$(ids "$TGT" | tr '\n' ' ')" = "shipped-one shipped-two shipped-three incoming " ]
  [ "$(ids "$SRC" | tr '\n' ' ')" = "stays " ]
  valid "$TGT"
  valid "$SRC"
  assert_no_leftovers
}

@test "seed control: a target that already exists is appended to, not seeded, and nothing is reported" {
  write_default
  registry_to "$SRC" "$(item incoming judgment advisory run)"
  registry_to "$TGT" "$(item existing judgment advisory run)"
  ce --registry "$SRC" copy incoming --to "$TGT"
  [ "$status" -eq 0 ]
  assert_output_not_contains "SEEDED:"
  [ "$(printf '%s\n' "$output" | tail -n 1 | jq -r '.seeded')" = "false" ]
  [ "$(ids "$TGT" | tr '\n' ' ')" = "existing incoming " ]
}

@test "seed: a missing shipped default is refused (exit 14) and no target is created" {
  # $DEFAULT is not written, so the seed source does not exist
  registry_to "$SRC" "$(item incoming judgment advisory run)"
  ce --registry "$SRC" copy incoming --to "$TGT"
  [ "$status" -eq 14 ]
  [ ! -e "$TGT" ]
}

@test "seed: add never creates a registry (exit 4); the first instance comes from copy/move only" {
  write_default
  add_args new-item
  ce --registry "$T/does-not-exist.json" "${ADD[@]}"
  [ "$status" -eq 4 ]
  [ ! -e "$T/does-not-exist.json" ]
}

# =============================================================================
# 6. move atomicity at each stage
# =============================================================================
# JENGA_CHECKLIST_ENTRY_FAIL_AT=<stage> is the script's own injection seam: the run rolls back exactly as for a real
# failure and reports the exit code that failure would give. Every stage, against an existing target and against a
# target that does not exist yet (which is seeded, so a rollback must delete it again).

# move_fixture <existing|new>: source with the moving item plus a bystander; an existing target or none.
move_fixture() {
  write_default
  registry_to "$SRC" "$(item mover judgment advisory run)" "$(item bystander judgment advisory run)"
  snap "$SRC"
  if [ "$1" = "existing" ]; then
    registry_to "$TGT" "$(item target-one judgment advisory run)"
    snap "$TGT"
  else
    [ ! -e "$TGT" ]
  fi
}

# assert_move_rolled_back <existing|new> <stage> <expected exit>
assert_move_rolled_back() {
  [ "$status" -eq "$3" ]
  assert_contains "$stderr" "injected failure at stage $2"
  [ -z "$output" ]
  unchanged "$SRC"
  if [ "$1" = "existing" ]; then
    unchanged "$TGT"
  else
    [ ! -e "$TGT" ]
  fi
  assert_no_leftovers
}

# stage_move <existing|new> <stage>: a move with the failure injected at <stage>.
stage_move() {
  move_fixture "$1"
  run --separate-stderr env "JENGA_CHECKLIST_ENTRY_FAIL_AT=$2" bash "$ENTRY" --registry "$SRC" move mover --to "$TGT"
}

@test "move control: with no injection the item leaves the source and lands in the target (rollback tests are not vacuous)" {
  move_fixture existing
  ce --registry "$SRC" move mover --to "$TGT"
  [ "$status" -eq 0 ]
  [ "$(ids "$SRC" | tr '\n' ' ')" = "bystander " ]
  [ "$(ids "$TGT" | tr '\n' ' ')" = "target-one mover " ]
  valid "$SRC"
  valid "$TGT"
  assert_no_leftovers
}

@test "move atomicity, existing target: target-candidate stage leaves both files byte-identical (exit 1)" {
  stage_move existing target-candidate
  assert_move_rolled_back existing target-candidate 1
}

@test "move atomicity, existing target: source-candidate stage leaves both files byte-identical (exit 1)" {
  stage_move existing source-candidate
  assert_move_rolled_back existing source-candidate 1
}

@test "move atomicity, existing target: target-validate stage leaves both files byte-identical (exit 11)" {
  stage_move existing target-validate
  assert_move_rolled_back existing target-validate 11
}

@test "move atomicity, existing target: source-validate stage leaves both files byte-identical (exit 11)" {
  stage_move existing source-validate
  assert_move_rolled_back existing source-validate 11
}

@test "move atomicity, existing target: target-replace stage leaves both files byte-identical (exit 1)" {
  stage_move existing target-replace
  assert_move_rolled_back existing target-replace 1
}

@test "move atomicity, existing target: source-replace stage (target already replaced) restores the target (exit 1)" {
  stage_move existing source-replace
  assert_move_rolled_back existing source-replace 1
}

@test "move atomicity, existing target: seed-read is not on the path, so the move succeeds" {
  # the seed-read stage is reached only when the target does not exist; with an existing target the injection is inert
  move_fixture existing
  run --separate-stderr env JENGA_CHECKLIST_ENTRY_FAIL_AT=seed-read bash "$ENTRY" --registry "$SRC" move mover --to "$TGT"
  [ "$status" -eq 0 ]
  [ "$(ids "$SRC" | tr '\n' ' ')" = "bystander " ]
}

@test "move atomicity, new target: seed-read stage creates nothing and leaves the source byte-identical (exit 14)" {
  stage_move new seed-read
  assert_move_rolled_back new seed-read 14
}

@test "move atomicity, new target: target-candidate stage creates nothing (exit 1)" {
  stage_move new target-candidate
  assert_move_rolled_back new target-candidate 1
}

@test "move atomicity, new target: source-candidate stage creates nothing (exit 1)" {
  stage_move new source-candidate
  assert_move_rolled_back new source-candidate 1
}

@test "move atomicity, new target: target-validate stage creates nothing (exit 11)" {
  stage_move new target-validate
  assert_move_rolled_back new target-validate 11
}

@test "move atomicity, new target: source-validate stage creates nothing (exit 11)" {
  stage_move new source-validate
  assert_move_rolled_back new source-validate 11
}

@test "move atomicity, new target: target-replace stage creates nothing (exit 1)" {
  stage_move new target-replace
  assert_move_rolled_back new target-replace 1
}

@test "move atomicity, new target: source-replace stage deletes the target this run created (exit 1)" {
  stage_move new source-replace
  assert_move_rolled_back new source-replace 1
}

@test "move atomicity: an unknown injection stage is a usage error (exit 2) and nothing changes" {
  move_fixture existing
  run --separate-stderr env JENGA_CHECKLIST_ENTRY_FAIL_AT=no-such-stage bash "$ENTRY" --registry "$SRC" move mover --to "$TGT"
  [ "$status" -eq 2 ]
  unchanged "$SRC"
  unchanged "$TGT"
}

@test "copy atomicity: a failure at each target stage leaves the target and the source byte-identical" {
  local stage
  for stage in target-candidate target-validate target-replace; do
    move_fixture existing
    run --separate-stderr env "JENGA_CHECKLIST_ENTRY_FAIL_AT=$stage" bash "$ENTRY" --registry "$SRC" copy mover --to "$TGT"
    [ "$status" -ne 0 ] || { echo "copy at $stage did not fail" >&2; return 1; }
    assert_contains "$stderr" "injected failure at stage $stage"
    unchanged "$SRC"
    unchanged "$TGT"
    assert_no_leftovers
  done
}

@test "copy: source-side stages are not on a copy's path, so the copy succeeds and the source keeps the item" {
  local stage
  for stage in source-candidate source-validate source-replace; do
    move_fixture existing
    run --separate-stderr env "JENGA_CHECKLIST_ENTRY_FAIL_AT=$stage" bash "$ENTRY" --registry "$SRC" copy mover --to "$TGT"
    [ "$status" -eq 0 ] || { echo "copy at $stage failed: $stderr" >&2; return 1; }
    unchanged "$SRC"
    [ "$(ids "$TGT" | tr '\n' ' ')" = "target-one mover " ]
  done
}

@test "move: same file as source and target is refused (exit 13), the registry is byte-identical" {
  move_fixture existing
  ce --registry "$SRC" move mover --to "$SRC"
  [ "$status" -eq 13 ]
  unchanged "$SRC"
}

@test "move: the shipped default can be a copy source but never a move source (exit 13)" {
  move_fixture existing
  snap "$DEFAULT"
  ce --registry "$DEFAULT" move shipped-one --to "$TGT"
  [ "$status" -eq 13 ]
  unchanged "$DEFAULT"
  unchanged "$TGT"
  ce --registry "$DEFAULT" copy shipped-one --to "$TGT"
  [ "$status" -eq 0 ]
  unchanged "$DEFAULT"
}

# =============================================================================
# KNOWN LIMITS of the T03 cross-file write path, pinned as they are today
# =============================================================================

# KNOWN LIMIT (1): the lock is keyed on the path AS GIVEN. with-lock.sh makes "<path>.lock.d", so a symlink spelling of
# one registry takes a different lock than the real path and the two writers do not exclude each other. (The canonical
# path is used only to order the two locks of a move.) The test holds the real path's lock itself by creating its lock
# directory, so there is no timing: the same spelling is refused (exit 6), the alias spelling goes straight through.
@test "KNOWN LIMIT: locks key on the path as given, so two spellings of one file do not exclude each other" {
  registry_to "$SRC" "$(item first judgment advisory run)"
  ln -s "$SRC" "$T/alias.json"
  mkdir "$SRC.lock.d"
  add_args via-same-spelling
  run --separate-stderr env WITH_LOCK_TIMEOUT_SECONDS=0 bash "$ENTRY" --registry "$SRC" "${ADD[@]}"
  [ "$status" -eq 6 ]
  [ "$(ids "$SRC" | tr '\n' ' ')" = "first " ]
  # a different spelling of the same file is not excluded: the write goes through while the real path's lock is held
  add_args via-alias
  run --separate-stderr env WITH_LOCK_TIMEOUT_SECONDS=0 bash "$ENTRY" --registry "$T/alias.json" "${ADD[@]}"
  [ "$status" -eq 0 ]
  [ "$(ids "$T/alias.json" | tr '\n' ' ')" = "first via-alias " ]
  # the held lock was never touched by that second writer
  [ -d "$SRC.lock.d" ]
  rmdir "$SRC.lock.d"
}

# A held lock on a move's source or target refuses it before anything is written (exit 6), for either file.
@test "lock held on the target or on the source: move is refused (exit 6) with both files byte-identical" {
  move_fixture existing
  mkdir "$TGT.lock.d"
  run --separate-stderr env WITH_LOCK_TIMEOUT_SECONDS=0 bash "$ENTRY" --registry "$SRC" move mover --to "$TGT"
  [ "$status" -eq 6 ]
  unchanged "$SRC"
  unchanged "$TGT"
  rmdir "$TGT.lock.d"
  mkdir "$SRC.lock.d"
  run --separate-stderr env WITH_LOCK_TIMEOUT_SECONDS=0 bash "$ENTRY" --registry "$SRC" move mover --to "$TGT"
  [ "$status" -eq 6 ]
  unchanged "$SRC"
  unchanged "$TGT"
  rmdir "$SRC.lock.d"
}

# KNOWN LIMIT (2): SIGKILL between the two replaces of a `move` is not recoverable by the script (a trap cannot run).
# The target is already replaced, the source not yet, and "<target>.rollback.<pid>" (the backup the trap would have
# restored from) is left behind. The stub `mv` stops the run exactly at the source replace and records the parent (the
# `_transfer` shell) so the test can SIGKILL it there; every rollback test above covers the failures a trap CAN handle.
@test "KNOWN LIMIT: SIGKILL between the two replaces of a move leaves a .rollback file and a half-applied move" {
  move_fixture existing
  install_stubs
  export GATE_DIR="$GATE" GATE_MV_DEST="$SRC"
  PATH="$T/bin:$PATH" bash "$ENTRY" --registry "$SRC" move mover --to "$TGT" >"$T/out.txt" 2>"$T/err.txt" 3>&- &
  local top=$!
  echo "$top" > "$GATE/top.pid"
  wait_for_file "$GATE/reached"
  # at this instant the target holds the moved item and the source has not been replaced
  [ "$(ids "$TGT" | tr '\n' ' ')" = "target-one mover " ]
  [ "$(ids "$SRC" | tr '\n' ' ')" = "mover bystander " ]
  kill -9 "$(cat "$GATE/parent.pid")"
  kill -9 "$(cat "$GATE/mv.pid")"
  wait_dead "$top"
  wait "$top" || true
  # the half-applied state: target replaced, source untouched, the backup left behind
  unchanged "$SRC"
  [ "$(ids "$TGT" | tr '\n' ' ')" = "target-one mover " ]
  [ "$(find "$T" -name 'target.json.rollback.*' | wc -l | tr -d ' ')" = "1" ]
  # the leftover backup is exactly the target as it was before the move
  cmp -s "$T/snap/target.json" "$(find "$T" -name 'target.json.rollback.*')"
}

# KNOWN LIMIT (3): a SIGTERM sent only to the top-level script does not stop the with-lock.sh child. The top-level shell
# has no TERM trap while it waits for the wrapper, so it dies at once, and the wrapper (with the engine under it) keeps
# running: the lock stays held and the write still lands. (with-lock.sh forwards signals it receives itself; the
# top-level script does not forward its own.) The stub `python3` pauses the engine call of `add` while the lock is held;
# the test sends the signal, checks the lock is still held, lets the engine go on and sees the write complete.
@test "KNOWN LIMIT: SIGTERM sent only to the top-level script does not stop the with-lock.sh child" {
  registry_to "$SRC" "$(item first judgment advisory run)"
  install_stubs
  export GATE_DIR="$GATE" GATE_PY_OP=add
  add_args late-item
  PATH="$T/bin:$PATH" bash "$ENTRY" --registry "$SRC" "${ADD[@]}" >"$T/out.txt" 2>"$T/err.txt" 3>&- &
  local top=$!
  echo "$top" > "$GATE/top.pid"
  wait_for_file "$GATE/reached"
  [ -d "$SRC.lock.d" ]
  kill -TERM "$top"
  wait_dead "$top"
  local rc=0
  wait "$top" || rc=$?
  [ "$rc" -eq 143 ]
  # the top-level script is gone, yet the lock is still held by the child, which is still alive and paused
  [ -d "$SRC.lock.d" ]
  ps -p "$(cat "$GATE/py.pid")" >/dev/null
  # let the child continue: the write completes although its caller was terminated
  release_gate
  local i=0
  while [ -d "$SRC.lock.d" ] && [ "$i" -lt 200 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ ! -d "$SRC.lock.d" ]
  [ "$(ids "$SRC" | tr '\n' ' ')" = "first late-item " ]
  valid "$SRC"
}

# =============================================================================
# 7. Rendered lines satisfy ranked_list (the real verifier)
# =============================================================================

# print_fixture: items spread over every situation, with text that stresses the line form (a brace placeholder, an
# em dash, a colon, runs of spaces, a long sentence). Every situation has an item, so no group is the empty-group line.
print_fixture() {
  registry_to "$F" \
    "$(TEXT='Plain first item.' item commit-one judgment advisory persistent)" \
    "$(TEXT='Mentions {id} and {n} placeholders literally, plus an em dash — and: a colon.' item commit-two machine block run 'echo ok')" \
    "$(TEXT='Spaced     out     text' SIT='["pre-task"]' item task-one judgment confirm persistent)" \
    "$(TEXT='A long sentence that goes on and on to make sure a wide line is still one line and still a ranked list entry, with no wrapping and nothing clever.' SIT='["pre-release"]' item release-one judgment advisory run)" \
    "$(SIT='["pre-reconcile"]' item reconcile-one judgment advisory run)" \
    "$(SIT='["pre-commit", "pre-deploy"]' item deploy-one judgment advisory run)"
}

# verify_ranked_list <text>: the REAL verifier; fails the test (with its reason) when the text is not a ranked_list.
verify_ranked_list() {
  local rc=0 err
  err="$(bash "$VERIFY" ranked_list "$1" 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "verify-output.sh ranked_list exited $rc: $err" >&2
    echo "--- value:" >&2
    printf '%s\n' "$1" >&2
    return 1
  fi
}

@test "render: one situation's output is a valid ranked_list, checked by the real verifier" {
  print_fixture
  local sit
  for sit in pre-commit pre-task pre-release pre-reconcile pre-deploy; do
    cp_print "$sit"
    [ "$status" -eq 0 ] || { echo "print $sit exited $status: $stderr" >&2; return 1; }
    [ -n "$output" ]
    verify_ranked_list "$output"
  done
}

@test "render: the line form is <n>. <id> — <checkbox> <text> (<kind>, <enforcement>, <tick_scope>), numbered from 1" {
  print_fixture
  cp_print pre-commit
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "1. commit-one — [ ] Plain first item. (judgment, advisory, persistent)" ]
  [ "$(printf '%s\n' "$output" | sed -n 3p)" = "3. deploy-one — [ ] Item deploy-one. (judgment, advisory, run)" ]
  # a placeholder-looking text is printed as written, and the line is still one line
  assert_contains "$output" "2. commit-two — [ ] Mentions {id} and {n} placeholders literally, plus an em dash — and: a colon. (machine, block, run)"
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "3" ]
}

@test "render: every group of the all-situations print is a valid ranked_list under its heading" {
  print_fixture
  cp_print
  [ "$status" -eq 0 ]
  local printed="$output" n=0 body g
  # split on blank lines, drop each group's heading line, verify what is left
  mkdir -p "$T/groups"
  printf '%s\n' "$printed" | awk -v dir="$T/groups" 'BEGIN { RS = ""; FS = "\n" }
    { f = sprintf("%s/g%02d.txt", dir, NR); for (i = 2; i <= NF; i++) print $i > f; close(f) }'
  for g in "$T"/groups/g*.txt; do
    body="$(cat "$g")"
    verify_ranked_list "$body"
    n=$((n + 1))
  done
  # five situations: the four base ones and pre-deploy, each in its own group
  [ "$n" -eq 5 ]
  # the whole print is NOT a ranked_list (it carries headings), which is why the groups are checked one by one
  run bash "$VERIFY" ranked_list "$printed"
  [ "$status" -ne 0 ]
}

@test "render: a ticked item keeps the line form (still ranked_list) and shows the ticked checkbox" {
  print_fixture
  run --separate-stderr bash "$CHECKLIST" tick commit-one --by tester
  [ "$status" -eq 0 ]
  cp_print pre-commit
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "1. commit-one — [x] Plain first item. (judgment, advisory, persistent)" ]
  printf '%s\n' "$output" | sed -n 2p | grep -qF '— [ ] Mentions'

  verify_ranked_list "$output"
}

@test "render control: the real verifier rejects a malformed line, so a green verifier run says something" {
  # a template whose line form drops the em dash and the number's period: the renderer prints it faithfully and the
  # verifier must refuse it
  jq '.item = "{n} {id} {text}"' "$REPO_ROOT/templates/checklist-render.json" > "$T/bad-render.json"
  print_fixture
  run --separate-stderr env "JENGA_CHECKLIST_RENDER_TEMPLATE=$T/bad-render.json" bash "$PRINT" pre-commit
  [ "$status" -eq 0 ]
  local printed="$output"
  run bash "$VERIFY" ranked_list "$printed"
  [ "$status" -eq 1 ]
}

@test "render: printing is read-only (the registry and its tick store are not written)" {
  print_fixture
  snap "$F"
  cp_print
  [ "$status" -eq 0 ]
  cp_print pre-task
  unchanged "$F"
  [ ! -e "$STATE" ] || [ -z "$(find "$STATE" -type f)" ]
}

@test "render: an unknown situation is exit 3 with empty stdout, a known one that no item names is silent exit 0" {
  registry_to "$F" "$(item commit-one judgment advisory run)"
  cp_print no-such-situation
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  cp_print pre-release
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "render: an invalid registry prints nothing (exit 1) and the validator's lines are on stderr" {
  bad_registry "$F"
  cp_print pre-commit
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "unknown kind"
}

# =============================================================================
# Extra scope: checklist-instance.sh (no tests before this task)
# =============================================================================

@test "instance status: reports the instance when the project has one" {
  registry_to "$F" "$(item commit-one judgment advisory run)"
  ci status
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'instance\t%s' "$F")" ]
}

@test "instance status: reports default, the instance path that does not exist, and the shipped default when there is none" {
  write_default
  ci status
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'default\t%s\t%s' "$F" "$DEFAULT")" ]
  [ ! -e "$F" ]
}

@test "instance status: no shipped default anywhere is exit 4 (and an unresolvable instance path is exit 5)" {
  # $DEFAULT is not written; JENGA_CHECKLISTS_DEFAULT_FILE is honoured exclusively, with no fall-through
  ci status
  [ "$status" -eq 4 ]
  mkdir -p "$T/noproj"
  run --separate-stderr env JENGA_CHECKLISTS_FILE= "JENGA_PROJECT_ROOT=$T/noproj" bash "$INSTANCE" status
  [ "$status" -eq 5 ]
}

@test "instance target: classifies shipped-default, new and exists" {
  write_default
  registry_to "$TGT" "$(item commit-one judgment advisory run)"
  ci target "$DEFAULT"
  [ "$status" -eq 0 ]
  [ "$output" = "shipped-default" ]
  ci target "$T/not-there.json"
  [ "$output" = "new" ]
  ci target "$TGT"
  [ "$output" = "exists" ]
}

# A directory-symlink spelling of the shipped default is recognised (target canonicalises the directory). A symlink to the
# FILE itself is not: checklist-instance.sh's canon() resolves only the directory, whereas checklist-entry.sh resolves
# the file too (realpath), so the two scripts disagree about that spelling. That gap is reported in the rapport
# project/rapports/problems/E67_S10_T05-instance-target-file-symlink.md and deliberately not pinned here either way.
@test "instance target: a symlinked directory spelling of the shipped default is still the shipped default" {
  write_default
  ln -s "$T" "$T/linkdir"
  cp "$DEFAULT" "$T/copy.json"
  ci target "$T/linkdir/default-checklists.json"
  [ "$output" = "shipped-default" ]
  # a mere copy of it, however spelled, is an ordinary registry
  ci target "$T/linkdir/copy.json"
  [ "$output" = "exists" ]
}

@test "instance target: needs exactly one path (exit 2)" {
  write_default
  ci target
  [ "$status" -eq 2 ]
  ci target a b
  [ "$status" -eq 2 ]
}

@test "instance scratch: makes a private copy of the shipped default inside TMPDIR and prints only its path" {
  write_default
  ci scratch
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "1" ]
  [ "$(basename "$output")" = "checklists.json" ]
  [ "$(dirname "$(dirname "$output")")" = "$T/tmp" ]
  case "$(basename "$(dirname "$output")")" in jenga-checklist-scratch.*) ;; *) return 1 ;; esac
  cmp -s "$DEFAULT" "$output"
  # editing the scratch copy never touches the shipped default
  snap "$DEFAULT"
  add_args scratch-only
  ce --registry "$output" "${ADD[@]}"
  [ "$status" -eq 0 ]
  unchanged "$DEFAULT"
}

@test "instance scratch: no shipped default means exit 4 and no directory is left behind" {
  ci scratch
  [ "$status" -eq 4 ]
  [ -z "$(find "$T/tmp" -mindepth 1)" ]
}

@test "instance discard: removes the scratch directory scratch made, and a second discard is not an error" {
  write_default
  ci scratch
  local path="$output"
  [ -f "$path" ]
  ci discard "$path"
  [ "$status" -eq 0 ]
  [ ! -e "$(dirname "$path")" ]
  ci discard "$path"
  [ "$status" -eq 0 ]
}

@test "instance discard: refuses a path it did not make (exit 2) and leaves it in place" {
  write_default
  mkdir "$T/other"
  registry_to "$T/other/checklists.json" "$(item commit-one judgment advisory run)"
  snap "$T/other/checklists.json"
  ci discard "$T/other/checklists.json"
  [ "$status" -eq 2 ]
  unchanged "$T/other/checklists.json"
  # right directory name, wrong file name: also refused, and the scratch directory survives
  ci scratch
  local path="$output"
  ci discard "$(dirname "$path")/something-else.json"
  [ "$status" -eq 2 ]
  [ -f "$path" ]
  ci discard
  [ "$status" -eq 2 ]
}

@test "instance: unknown subcommand and bare invocation are exit 2; --help prints the usage and exits 0" {
  ci frobnicate
  [ "$status" -eq 2 ]
  ci
  [ "$status" -eq 2 ]
  ci --help
  [ "$status" -eq 0 ]
  assert_output_contains "checklist-instance.sh status"
}

@test "first-instance route end to end: scratch, author the item there, copy it to the instance path (seeded)" {
  write_default
  unset JENGA_CHECKLISTS_FILE
  local inst="$PROJ/project/configs/checklists.json"
  [ ! -e "$inst" ]
  ci status
  [ "$(printf '%s' "$output" | cut -f1)" = "default" ]
  # add refuses to create the instance
  add_args routed
  ce add --id routed --text "Routed." --situation pre-task --kind judgment --enforcement confirm --tick-scope run
  [ "$status" -eq 4 ]
  [ ! -e "$inst" ]
  ci scratch
  local scratch="$output"
  ce --registry "$scratch" "${ADD[@]}"
  [ "$status" -eq 0 ]
  ce --registry "$scratch" copy routed --to "$inst"
  [ "$status" -eq 0 ]
  assert_output_contains "SEEDED:"
  [ "$(ids "$inst" | tr '\n' ' ')" = "shipped-one shipped-two shipped-three routed " ]
  valid "$inst"
  ci discard "$scratch"
  [ ! -e "$scratch" ]
  ci status
  [ "$(printf '%s' "$output" | cut -f1)" = "instance" ]
  # the shipped default itself was never written
  [ "$(ids "$DEFAULT" | tr '\n' ' ')" = "shipped-one shipped-two shipped-three " ]
}
