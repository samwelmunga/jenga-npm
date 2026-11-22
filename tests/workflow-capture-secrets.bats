#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# Secret handling for j.workflow-capture (epic E103, task E103_S03_T02):
#
#   1. scan-secrets.sh scan flags each literal pattern (private-key block, URL userinfo, bearer token, NAME_KEY= /
#      NAME_TOKEN= assignments, vendor key shapes) and each phrasing pattern ("copy the key from the dashboard",
#      export NAME_TOKEN, $NAME_TOKEN, NAME=<placeholder>), one fixture per pattern, and never prints a value.
#   2. scan --apply replaces every literal by ${inputs.<name>} in text and evidence, records secret_flags, marks the
#      row uncertain and is idempotent; ordinary text is left alone.
#   3. write-capture.sh create refuses a file that still holds a literal (exit 13), and end to end the fixture's key
#      value is in neither the recording nor the emitted definition.
#   4. clear records a false positive through record-review.sh / record-answer.sh, and a cleared flag stays cleared.
#   5. Nothing here touches the recorder's active-recording pointer.
#
# Isolation: everything is written under $BATS_TEST_TMPDIR, with synthetic candidates only. Every key below is an
# obviously fake fixture value, not a credential. Every script is called with `bash`.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SS="$REPO_ROOT/skills/j-workflow-capture/scripts/scan-secrets.sh"
DP="$REPO_ROOT/skills/j-workflow-capture/scripts/detect-parameters.sh"
WC="$REPO_ROOT/skills/j-workflow-capture/scripts/write-capture.sh"
RR="$REPO_ROOT/skills/j-workflow-capture/scripts/record-review.sh"
RT="$REPO_ROOT/skills/j-workflow-capture/scripts/render-review-table.sh"
RA="$REPO_ROOT/skills/j-workflow-recorder/scripts/record-answer.sh"
VALIDATOR="$REPO_ROOT/scripts/workflow/validate-workflow.sh"

FAKE_STRIPE="sk_test_FAKEFAKEFAKE00000000"
FAKE_AWS="AKIAFAKEEXAMPLE00000"
FAKE_GH="ghp_FAKEFAKEFAKEFAKEFAKE0000"

setup() {
  T="$BATS_TEST_TMPDIR"
  PROJ="$T/proj"
  mkdir -p "$PROJ/project/configs"
  printf '%s\n' '{"paths":{"workflows":"project/.workflows"}}' > "$PROJ/project/configs/workflow.json"
  RECS="$T/recs"
  CANDS="$T/candidates.json"
  unset JENGA_WORKFLOWS_TEST_ROOT JENGA_RECORDING_DIR JENGA_WORKFLOW_LOADER JENGA_RUN_STATE
  unset CLAUDE_CODE_SESSION_ID JENGA_SESSION_ID JENGA_RECORDING_SESSION_ID
  export JENGA_PROJECT_ROOT="$PROJ"
  export JENGA_RECORDER_NOW=2026-11-20T03:04:05Z
  export JENGA_RECORDING_STATE_DIR="$T/state"
}

# one_row <text>: a candidates file with that single row.
one_row() {
  jq -n --arg t "$1" '{candidate_steps_version: 1, steps: [{n: 1, text: $t}]}' > "$CANDS"
}

# flags_of <n>: row n's flags from a scan report, as "kind:pattern:name" lines, sorted.
flags_of() {
  printf '%s' "$output" | jq -r --argjson n "$1" '.rows[] | select(.n == $n) | .flags[] | "\(.kind):\(.pattern):\(.name)"' | sort
}

# ---- 1. one fixture per pattern ----------------------------------------------------------------------------------

@test "scan: each literal pattern is flagged with its input name, and the value is never printed" {
  local case text want value
  while IFS='|' read -r text want value; do
    one_row "$text"
    run --separate-stderr bash "$SS" scan "$CANDS"
    [ "$status" -eq 0 ]
    assert_contains "$(flags_of 1)" "$want"
    [[ "$output$stderr" != *"$value"* ]]
  done <<EOF
export STRIPE_SECRET_KEY=$FAKE_STRIPE|literal:assignment:stripe_secret_key|$FAKE_STRIPE
set GITHUB_TOKEN="fakefakefaketoken0" in the shell|literal:assignment:github_token|fakefakefaketoken0
aws configure set aws_access_key_id $FAKE_AWS|literal:key-shape:aws_access_key_id|$FAKE_AWS
gh auth login with $FAKE_GH|literal:key-shape:github_token|$FAKE_GH
curl -H 'Authorization: Bearer FAKEbearerFAKE1234' https://x.test|literal:bearer-token:bearer_token|FAKEbearerFAKE1234
git clone https://fakeuser:fakepass99@git.example.test/r.git|literal:url-credentials:url_credentials|fakepass99
api_key: fake0000fake0000|literal:assignment:api_key|fake0000fake0000
mysql -u root --password=Hunter2Fake99 db|literal:cli-option:password|Hunter2Fake99
deploy --api-key FAKEabcdef123456 --region eu|literal:cli-option:api_key|FAKEabcdef123456
curl -H "Authorization: token FAKEabc123def456ghi" https://x.test|literal:auth-scheme:auth_token|FAKEabc123def456ghi
curl -H "Authorization: Basic ZmFrZTpmYWtlcGFzcw==" https://x.test|literal:auth-scheme:basic_auth|ZmFrZTpmYWtlcGFzcw==
curl -u admin:FakePass123 https://x.test|literal:user-credentials:user_credentials|FakePass123
EOF
}

@test "scan: credential options, -u with a variable password and unrelated flags are not literals (E103_S03_T02 rapport)" {
  local text
  while IFS= read -r text; do
    one_row "$text"
    run --separate-stderr bash "$SS" scan "$CANDS"
    [ "$status" -eq 0 ]
    [ -z "$(flags_of 1 | grep '^literal:')" ]
  done <<'EOF'
curl -u "$USER:$PASS" https://x.test
curl -u admin:$PASS https://x.test
tool --token-file ./path --verbose
tool --password --other
tool --password=<your-password>
mysql -u root -p mydb
npm install --save-dev jest
EOF
}

@test "scan --apply: the three rapport forms become placeholders and check passes" {
  local text
  for text in 'mysql -u root --password=Hunter2Fake99 db' \
              'curl -H "Authorization: token FAKEabc123def456ghi" https://x.test' \
              'curl -u admin:FakePass123 https://x.test'; do
    one_row "$text"
    run bash "$SS" scan --apply "$CANDS"
    [ "$status" -eq 0 ]
    run bash "$SS" check "$CANDS"
    [ "$status" -eq 0 ]
    run jq -r '.steps[0].text' "$CANDS"
    [[ "$output" == *'${inputs.'* ]]
    [[ "$output" != *Hunter2Fake99* && "$output" != *FAKEabc123def456ghi* && "$output" != *FakePass123* ]]
  done
}

@test "scan: a private-key block is one literal named private_key" {
  printf '%s\n' '{"candidate_steps_version": 1, "steps": [{"n": 1, "text": "save -----BEGIN RSA PRIVATE KEY-----\nFAKEFAKEFAKEKEYBODY\n-----END RSA PRIVATE KEY----- to disk"}]}' > "$CANDS"
  run --separate-stderr bash "$SS" scan "$CANDS"
  [ "$status" -eq 0 ]
  [ "$(flags_of 1)" = "literal:private-key-block:private_key" ]
  [[ "$output" != *FAKEFAKEFAKEKEYBODY* ]]
}

@test "scan: each phrasing pattern is flagged with the variable it names" {
  local text want
  while IFS='|' read -r text want; do
    one_row "$text"
    run --separate-stderr bash "$SS" scan "$CANDS"
    [ "$status" -eq 0 ]
    assert_contains "$(flags_of 1)" "$want"
  done <<'EOF'
Copy the key from the dashboard|phrasing:copy-key:api_key
Create a new access token in the settings page|phrasing:copy-key:access_token
paste your secret key into STRIPE_SECRET_KEY|phrasing:copy-key:stripe_secret_key
export SLACK_TOKEN|phrasing:export-name:slack_token
gh auth login --with-token $GITHUB_TOKEN|phrasing:variable-reference:github_token
set PASSWORD=<your-password> first|phrasing:assignment-placeholder:password
EOF
}

@test "scan: ordinary steps and look-alikes are not flagged" {
  local text
  while IFS= read -r text; do
    one_row "$text"
    run --separate-stderr bash "$SS" scan "$CANDS"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq '.rows | length')" -eq 0 ]
  done <<'EOF'
run npm test and commit
call the model with max_tokens=4096
the monkey: banana
password: see below
cd /opt/acme/shop
EOF
}

# ---- 2. apply ----------------------------------------------------------------------------------------------------

write_mixed() {
  cat > "$CANDS" <<JSON
{"candidate_steps_version": 1, "steps": [
  {"n": 1, "text": "export STRIPE_SECRET_KEY=$FAKE_STRIPE", "evidence": ["tool Bash: echo $FAKE_STRIPE"]},
  {"n": 2, "text": "Copy the API key from the dashboard", "proposal": "include"},
  {"n": 3, "text": "use $FAKE_STRIPE again", "parameters": [{"name": "project_root", "value": "/opt/acme"}]},
  {"n": 4, "text": "run npm test", "proposal": "include", "step_type": "compute", "uncertain": false}
]}
JSON
}

@test "scan --apply: literals become \${inputs.<name>} in text and evidence, rows are flagged and uncertain" {
  write_mixed
  run --separate-stderr bash "$SS" scan --apply "$CANDS"
  [ "$status" -eq 0 ]
  [ "$output" = "$CANDS" ]
  run ! grep -qF "$FAKE_STRIPE" "$CANDS"
  [ "$(jq -r '.steps[0].text' "$CANDS")" = 'export STRIPE_SECRET_KEY=${inputs.stripe_secret_key}' ]
  [ "$(jq -r '.steps[0].evidence[0]' "$CANDS")" = 'tool Bash: echo ${inputs.stripe_secret_key}' ]
  # The same value gets the same name in another row.
  [ "$(jq -r '.steps[2].text' "$CANDS")" = 'use ${inputs.stripe_secret_key} again' ]
  [ "$(jq -r '.steps[0].uncertain' "$CANDS")" = "true" ]
  assert_contains "$(jq -r '.steps[0].reason' "$CANDS")" "secret: stripe_secret_key (literal)"
  # A copy-key row is proposed as a confirm step naming the variable.
  [ "$(jq -r '.steps[1].step_type' "$CANDS")" = "confirm" ]
  [ "$(jq -c '[.steps[1].secret_flags[] | .name]' "$CANDS")" = '["api_key"]' ]
  # Existing parameters get the secret appended; unset parameters stay unset.
  [ "$(jq -c '.steps[2].parameters' "$CANDS")" = '[{"name":"project_root","value":"/opt/acme"},{"name":"stripe_secret_key","secret":true}]' ]
  [ "$(jq -r '.steps[0].parameters' "$CANDS")" = "null" ]
  # An unflagged row is untouched.
  [ "$(jq -c '.steps[3]' "$CANDS")" = '{"n":4,"text":"run npm test","proposal":"include","step_type":"compute","uncertain":false}' ]
  bash "$RT" --check "$CANDS"
}

@test "scan --apply is idempotent, and check passes after it" {
  write_mixed
  run bash "$SS" check "$CANDS"
  [ "$status" -eq 1 ]
  assert_contains "$output" "$(printf '1\tassignment')"
  [[ "$output" != *"$FAKE_STRIPE"* ]]
  bash "$SS" scan --apply "$CANDS" >/dev/null
  cp "$CANDS" "$T/once.json"
  bash "$SS" scan --apply "$CANDS" >/dev/null
  cmp "$CANDS" "$T/once.json"
  run bash "$SS" check "$CANDS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "detect-parameters --apply declares the secret names scan-secrets left in a row" {
  write_mixed
  bash "$SS" scan --apply "$CANDS" >/dev/null
  bash "$DP" propose --project-root /nonexistent --project-name '' --repo '' --package-name '' --apply "$CANDS" >/dev/null
  [ "$(jq -c '.steps[0].parameters' "$CANDS")" = '[{"name":"stripe_secret_key","secret":true}]' ]
  [ "$(jq -c '.steps[1].parameters' "$CANDS")" = '[{"name":"api_key","secret":true}]' ]
}

@test "render-review-table shows the flags in the table's uncertain column and in --row" {
  write_mixed
  bash "$SS" scan --apply "$CANDS" >/dev/null
  run --separate-stderr bash "$RT" "$CANDS"
  [ "$status" -eq 0 ]
  assert_contains "$output" "secret: api_key (phrasing)"
  run --separate-stderr bash "$RT" --row 1 "$CANDS"
  [ "$status" -eq 0 ]
  assert_contains "$output" "secret flags: stripe_secret_key (literal: assignment)"
}

# ---- 3. the writer and end to end --------------------------------------------------------------------------------

@test "write-capture create refuses a literal (exit 13) without echoing it and writes nothing" {
  write_mixed
  run --separate-stderr bash "$WC" create --source pasted --dir "$RECS" "$CANDS" "Leaky"
  [ "$status" -eq 13 ]
  [[ "$stderr$output" != *"$FAKE_STRIPE"* ]]
  [ ! -e "$RECS/leaky_RECORDING.md" ]
}

@test "end to end: the fixture key is in neither the recording nor the emitted definition" {
  write_mixed
  bash "$SS" scan --apply "$CANDS" >/dev/null
  REC="$(bash "$WC" create --source pasted --dir "$RECS" "$CANDS" "Pay setup")"
  bash "$DP" propose --project-root /nonexistent --project-name '' --repo '' --package-name '' --apply "$CANDS" >/dev/null
  local n
  for n in 1 2 3 4; do
    bash "$RR" decide "$REC" "$n" include >/dev/null
    bash "$RR" decide "$REC" "$n" type confirm >/dev/null
  done
  bash "$RR" decide "$REC" 1 params stripe_secret_key >/dev/null
  bash "$RR" decide "$REC" 2 params api_key >/dev/null
  bash "$RR" decide "$REC" 3 params stripe_secret_key >/dev/null
  bash "$RR" decide "$REC" 4 params none >/dev/null
  bash "$WC" seal "$REC" "$CANDS" >/dev/null
  run --separate-stderr bash "$WC" emit "$REC"
  [ "$status" -eq 0 ]
  DEF="$output"
  bash "$VALIDATOR" "$DEF" >/dev/null
  run ! grep -qF "$FAKE_STRIPE" "$REC"
  run ! grep -qF "$FAKE_STRIPE" "$DEF"
  [ "$(jq -c '[.inputs[] | .name]' "$DEF")" = '["stripe_secret_key","api_key"]' ]
  [ "$(jq -c '[.inputs[] | has("default")] | unique' "$DEF")" = '[false]' ]
  [ "$(jq -r '.steps[0].prompt' "$DEF")" = 'export STRIPE_SECRET_KEY=${inputs.stripe_secret_key}' ]
}

# ---- 4. clearing a false positive --------------------------------------------------------------------------------

clear_setup() {
  cat > "$CANDS" <<'JSON'
{"candidate_steps_version": 1, "steps": [
  {"n": 1, "text": "export SORT_KEY=name1234", "proposal": "include"},
  {"n": 2, "text": "Copy the API key from the dashboard", "proposal": "include"}
]}
JSON
  bash "$SS" scan --apply "$CANDS" >/dev/null
  REC="$(bash "$WC" create --source pasted --dir "$RECS" "$CANDS" "Sorting")"
}

@test "clear: a phrasing false positive drops its secret input and confirm type, recorded through record-answer.sh" {
  clear_setup
  run bash "$SS" clear "$REC" "$CANDS" 2
  [ "$status" -eq 9 ]
  bash "$DP" propose --project-root /nonexistent --project-name '' --repo '' --package-name '' --apply "$CANDS" >/dev/null
  run --separate-stderr bash "$SS" clear "$REC" "$CANDS" 2 --note "it is a public key, not a secret"
  [ "$status" -eq 0 ]
  [ "$(bash "$RA" --value "$REC" step-002 parameters)" = "none" ]
  assert_contains "$(bash "$RA" --text "$REC" step-002 parameters)" "secret flag cleared by the user as a false positive: api_key (phrasing: copy-key)"
  assert_contains "$(bash "$RA" --text "$REC" step-002 parameters)" "User: it is a public key, not a secret"
  [ "$(jq -c '.steps[1].parameters' "$CANDS")" = '[]' ]
  [ "$(jq -r '.steps[1].step_type' "$CANDS")" = "null" ]
  [ "$(jq -r '.steps[1].secret_flags[0].cleared' "$CANDS")" = "true" ]
  [ "$(jq -r '.steps[1].reason' "$CANDS")" = "null" ]
  # A re-scan never re-raises a cleared flag; clearing it again is refused.
  bash "$SS" scan --apply "$CANDS" >/dev/null
  [ "$(jq -r '.steps[1].uncertain' "$CANDS")" = "null" ]
  run bash "$SS" clear "$REC" "$CANDS" 2
  [ "$status" -eq 5 ]
}

@test "clear: a literal false positive keeps its input (the value was never kept) and emits cleanly" {
  clear_setup
  bash "$DP" propose --project-root /nonexistent --project-name '' --repo '' --package-name '' --apply "$CANDS" >/dev/null
  bash "$SS" clear "$REC" "$CANDS" 1 >/dev/null
  [ "$(bash "$RA" --value "$REC" step-001 parameters)" = "confirmed" ]
  [ "$(bash "$RA" --text "$REC" step-001 parameters | head -n 1)" = "sort_key" ]
  bash "$SS" clear "$REC" "$CANDS" 2 >/dev/null
  local n
  for n in 1 2; do
    bash "$RR" decide "$REC" "$n" include >/dev/null
    bash "$RR" decide "$REC" "$n" type confirm >/dev/null
  done
  bash "$WC" seal "$REC" "$CANDS" >/dev/null
  run --separate-stderr bash "$WC" emit "$REC"
  [ "$status" -eq 0 ]
  # The note after the parameters body is never read as a parameter name.
  [ "$(jq -c '[.inputs[] | .name]' "$output")" = '["sort_key"]' ]
  run ! grep -qF name1234 "$REC"
}

@test "clear: a credential-looking note is refused and nothing is written" {
  clear_setup
  bash "$DP" propose --project-root /nonexistent --project-name '' --repo '' --package-name '' --apply "$CANDS" >/dev/null
  cp "$REC" "$T/rec.before"; cp "$CANDS" "$T/cands.before"
  run --separate-stderr bash "$SS" clear "$REC" "$CANDS" 1 --note "the value is $FAKE_STRIPE"
  [ "$status" -eq 2 ]
  cmp "$REC" "$T/rec.before"
  cmp "$CANDS" "$T/cands.before"
}

@test "clear: usage errors and a missing row" {
  clear_setup
  run bash "$SS" clear "$REC" "$CANDS" 0
  [ "$status" -eq 2 ]
  run bash "$SS" clear "$REC" "$CANDS" 9
  [ "$status" -eq 5 ]
  run bash "$SS" clear "$T/nope.md" "$CANDS" 1
  [ "$status" -eq 3 ]
  run bash "$SS" bogus
  [ "$status" -eq 2 ]
  run bash "$SS" --help
  [ "$status" -eq 0 ]
}

# ---- 5. the pointer ----------------------------------------------------------------------------------------------

@test "scan-secrets never names the active-recording pointer and leaves the state directory untouched" {
  run grep -cE 'active-recording\.sh|active-recording["'"'"']?[[:space:]]+(set|clear|refresh)([[:space:]]|$)' "$SS"
  [ "$output" = "0" ]
  clear_setup
  bash "$DP" propose --project-root /nonexistent --project-name '' --repo '' --package-name '' --apply "$CANDS" >/dev/null
  bash "$SS" clear "$REC" "$CANDS" 2 >/dev/null
  [ ! -e "$T/state" ] || [ -z "$(ls -A "$T/state")" ]
}
