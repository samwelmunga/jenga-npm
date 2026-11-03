#!/usr/bin/env bats
#
# skills/j-workflow-recorder/scripts/active-recording.sh — the pointer to the live recording
# (E89, task E89_S01_T03).
#
# What this suite pins, and why each one is here rather than left to review:
#
#   1. THE POINTER IS ON DISK, NOT IN THE ENVIRONMENT. The whole reason this script exists is that
#      E89_S02 requires a recording to survive a context summarisation mid-session, which a fact held
#      in the turn does not. So the cross-invocation test is the load-bearing one: a pointer set by one
#      process must be readable by a different, later process with no shared shell state.
#   2. get IS BRANCHABLE ON ITS EXIT CODE. "Prints the path alone, exits non-zero when there is none"
#      is a contract — a caller must not have to parse prose to find out whether a recording is live.
#      Asserted with `run --separate-stderr` so a stray byte on stdout fails the test.
#   3. set REFUSES RATHER THAN REPLACING. A recorder holds one recording, so a second `set` is a
#      mistake worth stopping for, not a nesting to model. The refusal is what lets E89_S02_T02
#      implement its "handled explicitly" criterion as a decision. --force is asserted to be the only
#      way through.
#   4. AN EXPIRED ENTRY IS ABSENT EVERYWHERE. Driven through the JENGA_RECORDING_NOW seam rather than
#      by sleeping, so the expiry boundary is tested exactly and the suite stays fast.
#   5. THE TTL IS READ, NOT ASSUMED. Pointed at a fixture config whose recording_ttl_minutes is a
#      specific value, and the resulting expires_at is asserted exactly — so a script that ignored the
#      config would pass a weaker test and fails this one. The present-but-invalid case is a hard
#      error, the absent case a documented fallback, and both are pinned.
#   6. NO PATH LITERAL. The task's acceptance criterion greps the script for `project/`; that grep is
#      run here rather than by hand.
#
# Isolation: JENGA_RECORDING_STATE_DIR points every test at $BATS_TEST_TMPDIR, so no real queue state
# is read or written, and JENGA_RECORDING_SESSION_ID gives each test its own session key. The three
# ambient session variables are unset in setup so a real session's id can never leak in.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/j-workflow-recorder/scripts/active-recording.sh"

setup() {
  T="$BATS_TEST_TMPDIR"
  export JENGA_RECORDING_STATE_DIR="$T/state"
  export JENGA_RECORDING_SESSION_ID="bats-$BATS_TEST_NUMBER"
  CFG="$T/scope-thresholds.json"
  unset CLAUDE_CODE_SESSION_ID JENGA_SESSION_ID
  unset JENGA_RECORDING_NOW JENGA_RECORDING_TTL_MINUTES JENGA_SCOPE_THRESHOLDS_FILE
  REC="$T/my-process_RECORDING.md"
  : > "$REC"
}

# -----------------------------------------------------------------------------
# Shape of the script itself
# -----------------------------------------------------------------------------

@test "active-recording.sh exists, is executable and passes bash -n" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "the state path is resolved, not hardcoded: no project/ literal in the script" {
  run grep -n 'project/' "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "the header names the TTL source" {
  local header
  header="$(sed -n '1,/^set -u$/p' "$SCRIPT")"
  assert_contains "$header" "recording_ttl_minutes"
  assert_contains "$header" "scope-thresholds.json"
  assert_contains "$header" "DEFAULT_TTL_MINUTES"
}

@test "the header states how this differs from checklist-marker.sh and why" {
  local header
  header="$(sed -n '1,/^set -u$/p' "$SCRIPT")"
  assert_contains "$header" "checklist-marker.sh"
  assert_contains "$header" "STACK"
  assert_contains "$header" "SINGLE VALUE"
}

@test "the state directory is resolved under the queue directory" {
  # E89's dispatch ruling: the pointer lives under the queue directory, resolved the way
  # checklist-marker.sh resolves MARKER_DIR — not project/data/ and not a new location. Proved by
  # pointing a fixture project root's paths.queue somewhere unmistakable and reading back the file
  # the script would use.
  local proj
  proj="$T/proj"
  mkdir -p "$proj/project/configs"
  printf '%s\n' '{"paths":{"queue":"a-deliberately-unconventional/queue-root"}}' \
    > "$proj/project/configs/workflow.json"

  unset JENGA_RECORDING_STATE_DIR
  JENGA_PROJECT_ROOT="$proj" run bash "$SCRIPT" path
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "$proj/a-deliberately-unconventional/queue-root/active-recordings/"
  # path creates nothing.
  [ ! -e "$proj/a-deliberately-unconventional" ]
}

@test "--help prints usage on stdout and exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  assert_output_contains "set <path>"
  assert_output_contains "get"
}

# -----------------------------------------------------------------------------
# get / set / clear
# -----------------------------------------------------------------------------

@test "get with no active recording exits non-zero and prints nothing on stdout" {
  run --separate-stderr bash "$SCRIPT" get
  [ "$status" -ne 0 ]
  [ "$status" -eq 3 ]
  [ "$output" = "" ]
}

@test "after set, get prints exactly the path and exits 0" {
  run bash "$SCRIPT" set "$REC"
  [ "$status" -eq 0 ]

  run --separate-stderr bash "$SCRIPT" get
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$output" = "$REC" ]
  [ "$stderr" = "" ]
}

@test "set prints a token on stdout and nothing else" {
  run --separate-stderr bash "$SCRIPT" set "$REC"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$stderr" = "" ]
  assert_starts_with "$output" "rec-"
}

@test "after clear, get exits non-zero again" {
  bash "$SCRIPT" set "$REC" >/dev/null
  run bash "$SCRIPT" get
  [ "$status" -eq 0 ]

  run bash "$SCRIPT" clear
  [ "$status" -eq 0 ]

  run --separate-stderr bash "$SCRIPT" get
  [ "$status" -eq 3 ]
  [ "$output" = "" ]
}

@test "clear is idempotent and never an error" {
  # Called before anything was ever set — no state directory at all.
  run bash "$SCRIPT" clear
  [ "$status" -eq 0 ]

  bash "$SCRIPT" set "$REC" >/dev/null
  run bash "$SCRIPT" clear
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" clear
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" clear
  [ "$status" -eq 0 ]
}

@test "clear --token clears only the pointer that token set" {
  local token
  token="$(bash "$SCRIPT" set "$REC")"

  # Someone else's token: the live pointer is left alone, but clearing still succeeds, because the
  # caller's own entry is gone either way and clear must stay safe on an error path.
  run bash "$SCRIPT" clear --token "rec-0000000000000000"
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" get
  [ "$status" -eq 0 ]
  [ "$output" = "$REC" ]

  run bash "$SCRIPT" clear --token "$token"
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" get
  [ "$status" -eq 3 ]
}

@test "the path is stored verbatim, so get returns exactly what was set" {
  # Deliberately NOT absolutised: the criterion is that get prints exactly <path>.
  local odd
  odd="some/relative/path with spaces_RECORDING.md"
  bash "$SCRIPT" set "$odd" >/dev/null
  run bash "$SCRIPT" get
  [ "$status" -eq 0 ]
  [ "$output" = "$odd" ]
}

# -----------------------------------------------------------------------------
# The already-active refusal
# -----------------------------------------------------------------------------

@test "set while a recording is active exits non-zero, names the active path on stderr, stdout unchanged" {
  bash "$SCRIPT" set "$REC" >/dev/null

  run --separate-stderr bash "$SCRIPT" set "$T/other_RECORDING.md"
  [ "$status" -ne 0 ]
  [ "$status" -eq 6 ]
  [ "$output" = "" ]
  assert_contains "$stderr" "$REC"
  assert_contains "$stderr" "already active"

  # Nothing changed.
  run bash "$SCRIPT" get
  [ "$output" = "$REC" ]
}

@test "--force is the documented way to replace a live pointer, and it works" {
  local first second
  first="$(bash "$SCRIPT" set "$REC")"
  second="$(bash "$SCRIPT" set "$T/other_RECORDING.md" --force)"
  [ "$first" != "$second" ]

  run bash "$SCRIPT" get
  [ "$status" -eq 0 ]
  [ "$output" = "$T/other_RECORDING.md" ]
}

@test "--force is the ONLY way: a second set without it never replaces, however many times it is tried" {
  bash "$SCRIPT" set "$REC" >/dev/null
  local i
  i=0
  while [ "$i" -lt 3 ]; do
    run bash "$SCRIPT" set "$T/other_RECORDING.md"
    [ "$status" -eq 6 ]
    i=$(( i + 1 ))
  done
  run bash "$SCRIPT" get
  [ "$output" = "$REC" ]
}

# -----------------------------------------------------------------------------
# The state is on disk, not in the environment
# -----------------------------------------------------------------------------

@test "a pointer set in one shell invocation is readable by a separate later invocation" {
  # The load-bearing test: two separate processes, no shared shell state, nothing passed between them
  # but the session key. This is what E89_S02's survive-a-summarisation criterion rests on.
  run bash -c 'bash "$1" set "$2" >/dev/null' _ "$SCRIPT" "$REC"
  [ "$status" -eq 0 ]

  run bash -c 'bash "$1" get' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "$REC" ]

  # And it is really a file.
  run bash "$SCRIPT" path
  [ "$status" -eq 0 ]
  [ -f "$output" ]
}

@test "two session keys do not see each other's pointer" {
  JENGA_RECORDING_SESSION_ID="session-one" bash "$SCRIPT" set "$REC" >/dev/null

  JENGA_RECORDING_SESSION_ID="session-two" run bash "$SCRIPT" get
  [ "$status" -eq 3 ]

  JENGA_RECORDING_SESSION_ID="session-one" run bash "$SCRIPT" get
  [ "$status" -eq 0 ]
  [ "$output" = "$REC" ]

  # And session two may start its own recording without --force, because session one's is invisible.
  JENGA_RECORDING_SESSION_ID="session-two" run bash "$SCRIPT" set "$T/two_RECORDING.md"
  [ "$status" -eq 0 ]
}

@test "--session names the key explicitly" {
  unset JENGA_RECORDING_SESSION_ID
  run bash "$SCRIPT" set "$REC" --session "explicit-key"
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" get --session "explicit-key"
  [ "$status" -eq 0 ]
  [ "$output" = "$REC" ]
  run bash "$SCRIPT" get --session "a-different-key"
  [ "$status" -eq 3 ]
}

@test "no resolvable session key exits 7" {
  unset JENGA_RECORDING_SESSION_ID
  run bash "$SCRIPT" get
  [ "$status" -eq 7 ]
}

# -----------------------------------------------------------------------------
# Expiry
# -----------------------------------------------------------------------------

@test "an expired entry is treated as absent by get" {
  JENGA_RECORDING_NOW="2026-11-01T12:00:00Z" JENGA_RECORDING_TTL_MINUTES=1 \
    bash "$SCRIPT" set "$REC" >/dev/null

  # Still inside the TTL.
  JENGA_RECORDING_NOW="2026-11-01T12:00:30Z" run bash "$SCRIPT" get
  [ "$status" -eq 0 ]
  [ "$output" = "$REC" ]

  # Past it.
  JENGA_RECORDING_NOW="2026-11-01T12:02:00Z" run --separate-stderr bash "$SCRIPT" get
  [ "$status" -eq 3 ]
  [ "$output" = "" ]
}

@test "an expired entry does not block a new set, so a dead session cannot wedge a later one" {
  JENGA_RECORDING_NOW="2026-11-01T12:00:00Z" JENGA_RECORDING_TTL_MINUTES=1 \
    bash "$SCRIPT" set "$REC" >/dev/null

  JENGA_RECORDING_NOW="2026-11-01T12:05:00Z" JENGA_RECORDING_TTL_MINUTES=60 \
    run bash "$SCRIPT" set "$T/later_RECORDING.md"
  [ "$status" -eq 0 ]

  JENGA_RECORDING_NOW="2026-11-01T12:05:10Z" run bash "$SCRIPT" get
  [ "$status" -eq 0 ]
  [ "$output" = "$T/later_RECORDING.md" ]
}

@test "an expired entry is treated as absent by status too" {
  JENGA_RECORDING_NOW="2026-11-01T12:00:00Z" JENGA_RECORDING_TTL_MINUTES=1 \
    bash "$SCRIPT" set "$REC" >/dev/null
  JENGA_RECORDING_NOW="2026-11-01T12:02:00Z" run bash "$SCRIPT" status --field active
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "refresh extends a live entry in place and keeps its token and path" {
  local token
  token="$(JENGA_RECORDING_NOW="2026-11-01T12:00:00Z" JENGA_RECORDING_TTL_MINUTES=1 \
    bash "$SCRIPT" set "$REC")"

  JENGA_RECORDING_NOW="2026-11-01T12:00:30Z" JENGA_RECORDING_TTL_MINUTES=60 \
    run bash "$SCRIPT" refresh --token "$token"
  [ "$status" -eq 0 ]
  [ "$output" = "$token" ]

  # Well past the ORIGINAL expiry, still live.
  JENGA_RECORDING_NOW="2026-11-01T12:30:00Z" run bash "$SCRIPT" get
  [ "$status" -eq 0 ]
  [ "$output" = "$REC" ]
}

@test "refresh with a token that names no live entry exits 3 and changes nothing" {
  run bash "$SCRIPT" refresh --token "rec-0000000000000000"
  [ "$status" -eq 3 ]

  bash "$SCRIPT" set "$REC" >/dev/null
  run bash "$SCRIPT" refresh --token "rec-0000000000000000"
  [ "$status" -eq 3 ]
  run bash "$SCRIPT" get
  [ "$output" = "$REC" ]
}

@test "an expired entry is never resurrected by refresh" {
  local token
  token="$(JENGA_RECORDING_NOW="2026-11-01T12:00:00Z" JENGA_RECORDING_TTL_MINUTES=1 \
    bash "$SCRIPT" set "$REC")"
  JENGA_RECORDING_NOW="2026-11-01T12:05:00Z" run bash "$SCRIPT" refresh --token "$token"
  [ "$status" -eq 3 ]
}

# -----------------------------------------------------------------------------
# The TTL is read from configuration
# -----------------------------------------------------------------------------

@test "recording_ttl_minutes is read from the configuration file" {
  printf '%s\n' '{"recording_ttl_minutes": 5}' > "$CFG"
  JENGA_SCOPE_THRESHOLDS_FILE="$CFG" JENGA_RECORDING_NOW="2026-11-01T12:00:00Z" \
    bash "$SCRIPT" set "$REC" >/dev/null

  JENGA_RECORDING_NOW="2026-11-01T12:00:10Z" run bash "$SCRIPT" status --field expires_at
  [ "$status" -eq 0 ]
  [ "$output" = "2026-11-01T12:05:00Z" ]
}

@test "an absent recording_ttl_minutes falls back to the documented default rather than failing" {
  # The key is not in the shipped configuration yet, so its absence must not break the feature.
  printf '%s\n' '{"marker_ttl_minutes": 60}' > "$CFG"
  local default_minutes expected
  default_minutes="$(sed -n 's/^DEFAULT_TTL_MINUTES=\([0-9]*\)$/\1/p' "$SCRIPT")"
  [ -n "$default_minutes" ]

  JENGA_SCOPE_THRESHOLDS_FILE="$CFG" JENGA_RECORDING_NOW="2026-11-01T12:00:00Z" \
    run bash "$SCRIPT" set "$REC"
  [ "$status" -eq 0 ]

  expected="$(python3 -c 'import calendar,sys,time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(calendar.timegm((2026,11,1,12,0,0,0,0,0)) + int(sys.argv[1])*60)))' "$default_minutes")"
  JENGA_RECORDING_NOW="2026-11-01T12:00:10Z" run bash "$SCRIPT" status --field expires_at
  [ "$output" = "$expected" ]
}

@test "a missing configuration file falls back to the default rather than failing" {
  JENGA_SCOPE_THRESHOLDS_FILE="$T/no-such-config.json" run bash "$SCRIPT" set "$REC"
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" get
  [ "$output" = "$REC" ]
}

@test "a present-but-invalid recording_ttl_minutes is a hard error, not a silent fallback" {
  printf '%s\n' '{"recording_ttl_minutes": "soon"}' > "$CFG"
  JENGA_SCOPE_THRESHOLDS_FILE="$CFG" run bash "$SCRIPT" set "$REC"
  [ "$status" -eq 5 ]
  assert_output_contains "recording_ttl_minutes"

  printf '%s\n' '{"recording_ttl_minutes": 0}' > "$CFG"
  JENGA_SCOPE_THRESHOLDS_FILE="$CFG" run bash "$SCRIPT" set "$REC"
  [ "$status" -eq 5 ]
}

@test "a bad JENGA_RECORDING_NOW or TTL override is rejected with exit 2, distinct from a lock failure" {
  JENGA_RECORDING_NOW="yesterday" run bash "$SCRIPT" set "$REC"
  [ "$status" -eq 2 ]
  JENGA_RECORDING_TTL_MINUTES="soon" run bash "$SCRIPT" set "$REC"
  [ "$status" -eq 2 ]
  JENGA_RECORDING_TTL_MINUTES="-5" run bash "$SCRIPT" set "$REC"
  [ "$status" -eq 2 ]
}

# -----------------------------------------------------------------------------
# status, and the state file's shape
# -----------------------------------------------------------------------------

@test "status prints one JSON object and exits 0 whether or not a recording is active" {
  run bash "$SCRIPT" status
  [ "$status" -eq 0 ]
  run bash -c 'bash "$1" status | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[\"active\"])"' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "None" ]

  bash "$SCRIPT" set "$REC" >/dev/null
  run bash -c 'bash "$1" status | python3 -c "import json,sys; print(json.load(sys.stdin)[\"active\"][\"path\"])"' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "$REC" ]
}

@test "status --field prints one bare value, and nothing for an absent field" {
  bash "$SCRIPT" set "$REC" --title "A recorded process" >/dev/null
  run bash "$SCRIPT" status --field path
  [ "$output" = "$REC" ]
  run bash "$SCRIPT" status --field title
  [ "$output" = "A recorded process" ]
  run bash "$SCRIPT" status --field active
  [ "$output" = "true" ]

  bash "$SCRIPT" clear
  run bash "$SCRIPT" status --field path
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "the state file is valid JSON carrying the session key and one active entry" {
  bash "$SCRIPT" set "$REC" >/dev/null
  local file
  file="$(bash "$SCRIPT" path)"
  [ -f "$file" ]
  run python3 - "$file" "$JENGA_RECORDING_SESSION_ID" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["version"] == 1, doc
assert doc["session_id"] == sys.argv[2], doc
a = doc["active"]
for key in ("token", "path", "set_at", "expires_at", "writer_pid"):
    assert key in a, (key, a)
print("OK")
PY
  [ "$status" -eq 0 ]
  assert_output_contains "OK"
}

@test "clearing removes the state file rather than leaving an empty husk" {
  bash "$SCRIPT" set "$REC" >/dev/null
  local file
  file="$(bash "$SCRIPT" path)"
  [ -f "$file" ]
  bash "$SCRIPT" clear
  [ ! -e "$file" ]
}

@test "a write leaves no temporary file or lock directory behind" {
  bash "$SCRIPT" set "$REC" >/dev/null
  bash "$SCRIPT" clear
  run bash -c 'ls -A "$1" 2>/dev/null | grep -cE "^(\.tmp-|.*\.lock\.d$)" || true' _ "$JENGA_RECORDING_STATE_DIR"
  [ "$output" = "0" ]
}

@test "a state file belonging to another session key reads as absent, not as that session's recording" {
  bash "$SCRIPT" set "$REC" >/dev/null
  local file
  file="$(bash "$SCRIPT" path)"
  python3 - "$file" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["session_id"] = "somebody-else"
json.dump(doc, open(sys.argv[1], "w"))
PY
  run --separate-stderr bash "$SCRIPT" get
  [ "$status" -eq 3 ]
  [ "$output" = "" ]
  assert_contains "$stderr" "belongs to session"
}

@test "a corrupt state file reads as absent rather than failing the caller's lookup" {
  bash "$SCRIPT" set "$REC" >/dev/null
  printf 'not json at all\n' > "$(bash "$SCRIPT" path)"
  run --separate-stderr bash "$SCRIPT" get
  [ "$status" -eq 3 ]
  [ "$output" = "" ]
  assert_contains "$stderr" "not valid JSON"
}

# -----------------------------------------------------------------------------
# Usage errors
# -----------------------------------------------------------------------------

@test "no sub-command exits 2" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "an unknown sub-command exits 2" {
  run bash "$SCRIPT" frobnicate
  [ "$status" -eq 2 ]
}

@test "set with no path exits 2" {
  run bash "$SCRIPT" set
  [ "$status" -eq 2 ]
}

@test "refresh with no token exits 2" {
  run bash "$SCRIPT" refresh
  [ "$status" -eq 2 ]
}

@test "an unknown option exits 2" {
  run bash "$SCRIPT" get --no-such-option
  [ "$status" -eq 2 ]
}

@test "a malformed session key exits 2" {
  run bash "$SCRIPT" get --session 'has spaces and / slashes'
  [ "$status" -eq 2 ]
}
