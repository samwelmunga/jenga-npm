#!/usr/bin/env bats
#
# Coverage for skills/j-break/scripts/render-execution-status.sh (E44_S03_T01).
#
# The hard part of this script is not printing, it is deciding what "the current scope of execution" means with no
# run manifest. So these cases are about scope resolution: what counts as live, what counts as stale, what is
# excluded, and — the reason the rapport exists at all — that it refuses to degrade into a dump of the board.
#
# Every test builds its own board and queue in a temp project root via JENGA_PROJECT_ROOT. The real board, queue and
# todo.md are never read or written.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RENDER="$REPO_ROOT/skills/j-break/scripts/render-execution-status.sh"

setup() {
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/project/configs" "$PROJ/project/board/epics" "$PROJ/project/board/stories" "$PROJ/project/board/tasks"
  cat > "$PROJ/project/configs/workflow.json" <<'EOF'
{
  "paths": {
    "board": "project/board",
    "epics": "project/board/epics",
    "stories": "project/board/stories",
    "tasks": "project/board/tasks",
    "queue": "project/queue",
    "configs": "project/configs"
  }
}
EOF
  printf '{"bundle_lock_ttl_minutes": 30}\n' > "$PROJ/project/configs/scope-thresholds.json"
  export JENGA_PROJECT_ROOT="$PROJ"
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  OLD="2020-01-01T00:00:00Z"
}

# --- fixture builders --------------------------------------------------------------------------------------------

epic()  { printf -- '---\nid: %s\ntitle: %s\nstatus: %s\n---\n' "$1" "$2" "${3:-In Progress}" > "$PROJ/project/board/epics/$1_x.md"; }
story() { printf -- '---\nid: %s\nepic_id: %s\ntitle: %s\nstatus: %s\n---\n' "$1" "$2" "$3" "${4:-In Progress}" > "$PROJ/project/board/stories/$1_x.md"; }
task()  { printf -- '---\nid: %s\nstory_id: %s\nepic_id: %s\ntitle: %s\nstatus: %s\n---\n' "$1" "$2" "$3" "$4" "$5" > "$PROJ/project/board/tasks/$1_x.md"; }

todo() { printf '# Todo\n' > "$PROJ/project/todo.md"; local l; for l in "$@"; do printf '%s\n' "$l" >> "$PROJ/project/todo.md"; done; }

bundle() { mkdir -p "$PROJ/project/queue"; printf '{"story_id":"%s","started_at":"%s","tasks":[%s]}\n' "$1" "$2" "$3" > "$PROJ/project/queue/bundle-$1.json"; }
lock()   { mkdir -p "$PROJ/project/queue"; printf '{"epic_id":"%s","bundle_story_id":"%s","started_at":"%s"}\n' "$1" "$2" "$3" > "$PROJ/project/queue/epic-lock-$1.json"; }

render() { run bash "$RENDER"; }

# ===================================================================================================================
# Basics
# ===================================================================================================================

@test "script is executable and passes bash -n" {
  [ -x "$RENDER" ]
  bash -n "$RENDER"
}

@test "runs without error when the queue directory has no bundle or lock files, or does not exist" {
  epic E1 "Epic one"; story E1_S1 E1 "Story one"; task E1_T1 E1_S1 E1 "Queued task" Pending
  [ ! -d "$PROJ/project/queue" ]
  todo "Queued task: E1_T1"
  render
  [ "$status" -eq 0 ]
}

# ===================================================================================================================
# Nothing in flight: the case that justifies the script's existence
# ===================================================================================================================

@test "nothing in flight prints the plain statement, the queued count and the /status pointer" {
  epic E1 "Epic one"; story E1_S1 E1 "Story one"
  task E1_T1 E1_S1 E1 "First" Pending; task E1_T2 E1_S1 E1 "Second" Pending
  todo "First: E1_T1" "Second: E1_T2"
  render
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing is currently executing."* ]]
  [[ "$output" == *"2 item(s) are queued in todo.md"* ]]
  [[ "$output" == *"/status"* ]]
}

@test "nothing in flight NEVER falls back to dumping the board" {
  epic E1 "Epic one"; story E1_S1 E1 "Story one"
  task E1_T1 E1_S1 E1 "Distinctive queued title" Pending
  todo "Distinctive queued title: E1_T1"
  render
  [[ "$output" != *"Distinctive queued title"* ]]
  [[ "$output" != *"E1_T1"* ]]
  [[ "$output" != *"Epic one"* ]]
}

# ===================================================================================================================
# In flight: scope resolution and rendering
# ===================================================================================================================

@test "an In Progress task is resolved to its story and epic and grouped epic -> story -> task" {
  epic E1 "Epic one"; story E1_S1 E1 "Story one"
  task E1_T1 E1_S1 E1 "Running task" "In Progress"
  render
  [ "$status" -eq 0 ]
  local e s t
  e=$(printf '%s\n' "$output" | grep -n 'E1 · Epic one' | cut -d: -f1)
  s=$(printf '%s\n' "$output" | grep -n 'E1_S1 · Story one' | cut -d: -f1)
  t=$(printf '%s\n' "$output" | grep -n 'E1_T1 · Running task' | cut -d: -f1)
  [ -n "$e" ] && [ -n "$s" ] && [ -n "$t" ]
  [ "$e" -lt "$s" ] && [ "$s" -lt "$t" ]
}

@test "every item shows its id, title and status" {
  epic E1 "Epic one"; story E1_S1 E1 "Story one"
  task E1_T1 E1_S1 E1 "Running task" "In Progress"
  render
  [[ "$output" == *"E1_T1 · Running task  [In Progress]"* ]]
}

@test "in-flight items are visually distinguishable from queued items" {
  epic E1 "Epic one"; story E1_S1 E1 "Story one"
  task E1_T1 E1_S1 E1 "Running task" "In Progress"
  task E1_T2 E1_S1 E1 "Waiting task" Pending
  todo "Waiting task: E1_T2"
  render
  local running waiting
  running=$(printf '%s\n' "$output" | grep 'E1_T1 · Running')
  waiting=$(printf '%s\n' "$output" | grep 'E1_T2 · Waiting')
  [[ "$running" == *"🔄"* ]] && [[ "$running" == *"in flight"* ]]
  [[ "$waiting" == *"⏳"* ]] && [[ "$waiting" == *"queued"* ]]
  [[ "$running" != *"queued"* ]] && [[ "$waiting" != *"in flight"* ]]
}

@test "a one-line completed / in-flight / remaining summary is printed" {
  epic E1 "Epic one"; story E1_S1 E1 "Story one"
  task E1_T1 E1_S1 E1 "Done task" Passed
  task E1_T2 E1_S1 E1 "Running task" "In Progress"
  task E1_T3 E1_S1 E1 "Waiting task" Pending
  bundle E1_S1 "$NOW" '"E1_T1","E1_T2","E1_T3"'
  todo "Waiting task: E1_T3"
  render
  [[ "$output" == *"Progress: 1 completed · 1 in flight · 1 remaining"* ]]
  [ "$(printf '%s\n' "$output" | grep -c 'Progress:')" -eq 1 ]
}

@test "an item reachable through several sources appears exactly once" {
  epic E1 "Epic one"; story E1_S1 E1 "Story one"
  task E1_T1 E1_S1 E1 "Everywhere" "In Progress"
  bundle E1_S1 "$NOW" '"E1_T1"'
  lock E1 E1_S1 "$NOW"
  todo "Everywhere: E1_T1"
  render
  [ "$(printf '%s\n' "$output" | grep -c 'E1_T1 ·')" -eq 1 ]
  [[ "$output" == *"Progress: 0 completed · 1 in flight · 0 remaining"* ]]
}

# ===================================================================================================================
# Bundles and locks: live versus stale
# ===================================================================================================================

@test "every task of a live bundle is in scope, including ones already done" {
  epic E1 "Epic one"; story E1_S1 E1 "Story one"
  task E1_T1 E1_S1 E1 "Finished" Passed
  task E1_T2 E1_S1 E1 "Not started" Pending
  bundle E1_S1 "$NOW" '"E1_T1","E1_T2"'
  render
  [[ "$output" == *"E1_T1 · Finished"* ]]
  [[ "$output" == *"E1_T2 · Not started"* ]]
  [[ "$output" == *"1 completed"* ]]
}

@test "an expired epic lock is reported as stale and is NOT counted as live execution" {
  epic E1 "Epic one"; story E1_S1 E1 "Story one"; task E1_T1 E1_S1 E1 "Whatever" Pending
  lock E1 E1_S1 "$OLD"
  todo "Whatever: E1_T1"
  render
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale epic lock for E1"* ]]
  [[ "$output" == *"not live execution"* ]]
  # A stale lock alone must leave the run in the nothing-in-flight state.
  [[ "$output" == *"Nothing is currently executing."* ]]
}

@test "an unexpired epic lock puts its epic and bundle story in scope" {
  epic E1 "Epic one"; story E1_S1 E1 "Story one"; task E1_T1 E1_S1 E1 "Locked-in task" Pending
  lock E1 E1_S1 "$NOW"
  render
  [[ "$output" != *"Nothing is currently executing."* ]]
  [[ "$output" == *"E1 · Epic one"* ]]
  [[ "$output" == *"E1_T1 · Locked-in task"* ]]
}

@test "a bundle manifest with no live lock behind it is stale (halted or abandoned), not live" {
  epic E1 "Epic one"; story E1_S1 E1 "Story one"; task E1_T1 E1_S1 E1 "Old bundle task" Passed
  bundle E1_S1 "$OLD" '"E1_T1"'
  render
  [[ "$output" == *"Nothing is currently executing."* ]]
  [[ "$output" == *"bundle manifest for E1_S1 with no live lock"* ]]
  [[ "$output" == *"halted or abandoned, not counted"* ]]
}

@test "an old manifest IS live when an unexpired lock names its story" {
  epic E1 "Epic one"; story E1_S1 E1 "Story one"; task E1_T1 E1_S1 E1 "Long runner" "In Progress"
  bundle E1_S1 "$OLD" '"E1_T1"'
  lock E1 E1_S1 "$NOW"
  render
  [[ "$output" != *"Nothing is currently executing."* ]]
  [[ "$output" != *"bundle manifest for E1_S1 with no live lock"* ]]
}

# ===================================================================================================================
# todo.md: what is excluded, and what the queued remainder is limited to
# ===================================================================================================================

@test "commented-out todo lines are excluded, including RECONCILED markers and multi-line comments" {
  epic E1 "Epic one"; story E1_S1 E1 "Story one"
  task E1_T1 E1_S1 E1 "Running" "In Progress"
  task E1_T2 E1_S1 E1 "Live queued" Pending
  task E1_T3 E1_S1 E1 "Hidden one" Pending
  task E1_T4 E1_S1 E1 "Hidden two" Pending
  task E1_T5 E1_S1 E1 "Hidden three" Pending
  todo "Live queued: E1_T2" \
       "<!-- RECONCILED: Hidden one: E1_T3 -->" \
       "<!-- Hidden two: E1_T4 -->" \
       "<!--" \
       "Hidden three: E1_T5" \
       "-->"
  render
  [[ "$output" == *"E1_T2 · Live queued"* ]]
  [[ "$output" != *"Hidden one"* ]]
  [[ "$output" != *"Hidden two"* ]]
  [[ "$output" != *"Hidden three"* ]]
}

@test "queued items outside the epics in scope are counted, not listed" {
  epic E1 "In-scope epic"; story E1_S1 E1 "Story one"; task E1_T1 E1_S1 E1 "Running" "In Progress"
  epic E2 "Other epic"; story E2_S1 E2 "Other story"; task E2_T1 E2_S1 E2 "Elsewhere task" Pending
  todo "Elsewhere task: E2_T1"
  render
  [[ "$output" != *"Elsewhere task"* ]]
  [[ "$output" != *"Other epic"* ]]
  [[ "$output" == *"1 more item(s) queued in todo.md under other epics"* ]]
}

@test "a todo entry for work that is already finished is not counted as remaining" {
  epic E1 "Epic one"; story E1_S1 E1 "Story one"
  task E1_T1 E1_S1 E1 "Running" "In Progress"
  task E1_T2 E1_S1 E1 "Stale entry" Passed
  todo "Stale entry: E1_T2"
  render
  [[ "$output" == *"0 remaining"* ]]
  [[ "$output" != *"E1_T2"* ]]
}

# ===================================================================================================================
# Read-only
# ===================================================================================================================

@test "the script writes nothing — including to the stale locks and manifests it detects" {
  epic E1 "Epic one"; story E1_S1 E1 "Story one"; task E1_T1 E1_S1 E1 "Running" "In Progress"
  lock E1 E1_S1 "$OLD"
  bundle E1_S1 "$OLD" '"E1_T1"'
  todo "Running: E1_T1"
  local before after
  before="$(cd "$PROJ" && find . -type f | sort | xargs cksum | cksum)"
  render
  [ "$status" -eq 0 ]
  after="$(cd "$PROJ" && find . -type f | sort | xargs cksum | cksum)"
  [ "$before" = "$after" ]
  [ -f "$PROJ/project/queue/epic-lock-E1.json" ]
  [ -f "$PROJ/project/queue/bundle-E1_S1.json" ]
}

@test "the script contains no write, move, delete or directory-creating construct" {
  # Comments are ignored, and benign tokens are stripped first so they cannot masquerade as a file write: the HTML-comment
  # terminator the todo parser looks for, silencing to /dev/null, and fd duplication such as >&2.
  local real
  real=$(grep -vE '^\s*#' "$RENDER" \
    | sed -e 's/-->//g' -e 's#[0-9]*>/dev/null##g' -e 's/[0-9]*>&[0-9]//g' \
    | grep -nE '>|open\([^)]*, *.(r\+|[wax])|mode *= *.(r\+|[wax])|os\.(remove|unlink|rename|replace|mkdir|makedirs|rmdir)|shutil\.|\brm\b|\bmv\b|\btee\b|\bmkdir\b|\btouch\b' || true)
  [ -z "$real" ] || { echo "write construct found: $real" >&2; return 1; }
}

@test "reads are confined to the board, todo.md, the execution ledger and the queue directory" {
  run grep -nE "open\(" "$RENDER"
  # Every open() in the script must be a read of a path built from the resolved board, queue, configs, todo or ledger inputs.
  [[ "$output" == *"scope-thresholds.json"* ]]
  [[ "$output" == *"todo_file"* ]]
  [[ "$output" == *"ledger_file"* ]]
  [[ "$output" != *"/etc/"* ]]
  # Exactly the known set of open() sites, and no other: any new read must be added here deliberately.
  local allowed bad
  allowed='path, encoding|scope-thresholds\.json|todo_file|ledger_file'
  bad=$(printf '%s\n' "$output" | grep -vE "$allowed" || true)
  [ -z "$bad" ] || { echo "unexpected open(): $bad" >&2; return 1; }
  # And no reference to any other .md file than the board's and todo.md.
  run bash -c "grep -vE '^\s*#' '$RENDER' | grep -oE '[A-Za-z_./*-]+\.md' | sort -u | grep -vxE '\*\.md|/?todo\.md' || true"
  [ -z "$output" ]
}

# ===================================================================================================================
# Per-session execution ledger (E44_S09)
# ===================================================================================================================

ledger() { mkdir -p "$PROJ/project/queue"; printf '%s\n' "$@" >> "$PROJ/project/queue/execution-ledger.jsonl"; }
entry() { printf '{"ts":"%s","session_key":"%s","item_id":"%s","status":"Passed","source":"do-bundle"}' "$NOW" "$1" "$2"; }
ledger_scope() {
  epic E1 "Epic one"; story E1_S1 E1 "Story one"
  task E1_T1 E1_S1 E1 "Finished here" Passed
  task E1_T2 E1_S1 E1 "Finished before" Passed
  task E1_T3 E1_S1 E1 "Running" "In Progress"
  bundle E1_S1 "$NOW" '"E1_T1","E1_T2","E1_T3"'
}
render_as() { run bash "$RENDER" --session "$1"; }

@test "ledger: an item with an entry under the current session key renders 'ran this session'" {
  ledger_scope; ledger "$(entry sess-a E1_T1)"
  render_as sess-a
  [ "$status" -eq 0 ]
  [[ "$(printf '%s\n' "$output" | grep 'E1_T1 · ')" == *"ran this session"* ]]
  [[ "$output" == *"1 ran this session, 1 done earlier"* ]]
}

@test "ledger: terminal items without an entry for this session render 'done earlier', not 'done'" {
  ledger_scope; ledger "$(entry sess-a E1_T1)"
  render_as sess-a
  local l; l=$(printf '%s\n' "$output" | grep 'E1_T2 · ')
  [[ "$l" == *"done earlier"* ]]
  [[ "$l" != *"◀ done"$'\n'* ]]
  [[ "$output" == *"Progress: 2 completed"* ]]
}

@test "ledger: the same item seen from another session key renders 'done earlier'" {
  ledger_scope; ledger "$(entry sess-a E1_T1)"
  render_as sess-b
  [[ "$(printf '%s\n' "$output" | grep 'E1_T1 · ')" == *"done earlier"* ]]
  [[ "$output" == *"0 ran this session, 2 done earlier"* ]]
}

@test "ledger: no ledger file renders board status only and says no per-session record exists" {
  ledger_scope
  render_as sess-a
  [ "$status" -eq 0 ]
  [[ "$(printf '%s\n' "$output" | grep 'E1_T1 · ')" == *"◀ done"* ]]
  [[ "$output" != *"ran this session"* ]]
  [[ "$output" != *"done earlier"* ]]
  [[ "$output" == *"No per-session record exists"* ]]
}

@test "ledger: malformed lines are skipped without failing the render, and counted" {
  ledger_scope; ledger "not json" "$(entry sess-a E1_T1)" "[1,2]" ""
  render_as sess-a
  [ "$status" -eq 0 ]
  [[ "$(printf '%s\n' "$output" | grep 'E1_T1 · ')" == *"ran this session"* ]]
  [[ "$output" == *"2 malformed ledger line(s) were skipped"* ]]
}

@test "ledger: reading it writes nothing" {
  ledger_scope; ledger "$(entry sess-a E1_T1)"
  local before after
  before="$(cd "$PROJ" && find . -type f | sort | xargs cksum | cksum)"
  render_as sess-a
  after="$(cd "$PROJ" && find . -type f | sort | xargs cksum | cksum)"
  [ "$before" = "$after" ]
}

@test "ledger: --session needs a value" {
  run bash "$RENDER" --session
  [ "$status" -eq 2 ]
}
