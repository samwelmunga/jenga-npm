#!/usr/bin/env bats
#
# Coverage for skills/j-break/scripts/record-execution.sh (E44_S09_T01).
# Each test uses a temp project root via JENGA_PROJECT_ROOT; the real queue is never written.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
REC="$REPO_ROOT/skills/j-break/scripts/record-execution.sh"

setup() {
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/project/configs"
  printf '{"paths":{"queue":"project/queue"}}\n' > "$PROJ/project/configs/workflow.json"
  export JENGA_PROJECT_ROOT="$PROJ"
  LEDGER="$PROJ/project/queue/execution-ledger.jsonl"
}

@test "executable and passes bash -n" {
  [ -x "$REC" ]
  bash -n "$REC"
}

@test "one call appends one valid JSON line with all five fields; the file is created" {
  run bash "$REC" E1_S1_T1 Passed --source do-bundle --session sess-a
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$LEDGER" | tr -d ' ')" = "1" ]
  run python3 -c "
import json,re,sys
d=json.loads(open('$LEDGER').read())
assert sorted(d)==['item_id','session_key','source','status','ts'], d
assert d['item_id']=='E1_S1_T1' and d['status']=='Passed' and d['source']=='do-bundle' and d['session_key']=='sess-a'
assert re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ', d['ts'])"
  [ "$status" -eq 0 ]
}

@test "two calls append two lines and never modify the first" {
  bash "$REC" E1_S1_T1 Passed --session s
  local first; first="$(head -n1 "$LEDGER")"
  bash "$REC" E1_S1_T2 Failed --session s
  [ "$(wc -l < "$LEDGER" | tr -d ' ')" = "2" ]
  [ "$(head -n1 "$LEDGER")" = "$first" ]
}

@test "a status with spaces is escaped correctly" {
  bash "$REC" E1_S1_T1 "Passed with remarks" --session s
  python3 -c "import json; assert json.loads(open('$LEDGER').read())['status']=='Passed with remarks'"
}

@test "the session key comes from checklist-marker.sh session-key when --session is absent" {
  local want; want="$(bash "$REPO_ROOT/scripts/checklist-marker.sh" session-key 2>/dev/null)" || skip "no session key resolvable in this environment"
  bash "$REC" E1_S1_T1 Passed
  python3 -c "import json; assert json.loads(open('$LEDGER').read())['session_key']=='$want'"
}

@test "invalid item id, non-terminal status, bad source and unknown flag exit 2 and write nothing" {
  run bash "$REC" bogus Passed --session s;               [ "$status" -eq 2 ]
  run bash "$REC" E1_S1_T1 "In Progress" --session s;     [ "$status" -eq 2 ]
  run bash "$REC" E1_S1_T1 Passed --source nope --session s; [ "$status" -eq 2 ]
  run bash "$REC" E1_S1_T1 Passed --wat;                  [ "$status" -eq 2 ]
  run bash "$REC";                                        [ "$status" -eq 2 ]
  [ ! -e "$LEDGER" ]
}

@test "an unwritable ledger warns on stderr and exits 0" {
  mkdir -p "$PROJ/project/queue"
  mkdir "$LEDGER"   # a directory where the ledger file should be: the append must fail
  run --separate-stderr bash "$REC" E1_S1_T1 Passed --session s
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"warning"* ]]
}

@test ".gitignore ignores the ledger" {
  run git -C "$REPO_ROOT" check-ignore -q project/queue/execution-ledger.jsonl
  [ "$status" -eq 0 ]
}

@test ".publicignore covers project/queue/" {
  grep -qx 'project/queue/' "$REPO_ROOT/.publicignore"
}

@test "wiring: /do section 5 ledgers a tester-written Failed before the success-only step 7" {
  run awk '/^### 5\. Invoke the developer agent/{f=1} /^### 5\.1\./{f=0} f' "$REPO_ROOT/skills/j-do/SKILL.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Record a tester-written"* ]]
  [[ "$output" == *"record-execution.sh"*"<task_id> Failed --source do"* ]]
}
