#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# Parametrisation for j.workflow-capture (epic E103, task E103_S02_T04):
#
#   1. detect-parameters.sh proposes absolute paths, the project root, the project/repository/package name, cloud
#      regions, environment names and key-shaped values (BY NAME ONLY) for each candidate row; --apply writes them
#      into the candidates file, keeps parameters a row already has, marks a row with a redacted value uncertain
#      and redacts a raw key shape left in a row's text.
#   2. The credential rule: secret-check, and record-review.sh refusing a credential-looking literal (decide and
#      accept), so it is never written into the recording.
#   3. emit-workflow.sh turns confirmed parameters into `inputs` (no default) and substitutes every occurrence with
#      ${inputs.<name>}; the definition passes validate-workflow.sh, is byte-identical on re-emission, and carries
#      neither the literal nor a credential. Conflicts and inputs that replace nothing exit 12.
#   4. A recording without confirmed parameters emits no `inputs` key (the live recorder's emission is unchanged;
#      the existing tests/workflow-recorder-*.bats suites pin the rest).
#
# Isolation: everything is written under $BATS_TEST_TMPDIR, with synthetic candidates only. JENGA_PROJECT_ROOT
# names a throwaway project whose workflows directory is project/.workflows. Every script is called with `bash`.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DP="$REPO_ROOT/skills/j-workflow-capture/scripts/detect-parameters.sh"
WC="$REPO_ROOT/skills/j-workflow-capture/scripts/write-capture.sh"
RR="$REPO_ROOT/skills/j-workflow-capture/scripts/record-review.sh"
RT="$REPO_ROOT/skills/j-workflow-capture/scripts/render-review-table.sh"
RA="$REPO_ROOT/skills/j-workflow-recorder/scripts/record-answer.sh"
VALIDATOR="$REPO_ROOT/scripts/workflow/validate-workflow.sh"

FAKE_KEY="sk-abcdefghijklmnopqrstuvwx"

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

# propose with every project-derived value pinned, so the host's git state never matters.
propose() {
  bash "$DP" propose --project-root /opt/acme/shop --project-name shop --repo acme/shop-repo \
    --package-name '' "$@"
}

write_detect_candidates() {
  cat > "$CANDS" <<JSON
{"candidate_steps_version": 1, "steps": [
  {"n": 1, "text": "cd /opt/acme/shop and build the shop project from acme/shop-repo"},
  {"n": 2, "text": "open /etc/nginx/sites/site.conf and ~/configs/app.yml"},
  {"n": 3, "text": "set api_key=<redacted> and deploy to eu-west-1 with --env staging"},
  {"n": 4, "text": "export it as $FAKE_KEY now"},
  {"n": 5, "text": "say hello", "parameters": [{"name": "kept", "value": "hello"}]}
]}
JSON
}

# ---- 1. detection ------------------------------------------------------------------------------------------------

@test "propose: paths, project root, project and repository name, region, environment, secrets by name only" {
  write_detect_candidates
  run --separate-stderr propose "$CANDS"
  [ "$status" -eq 0 ]
  row() { printf '%s' "$output" | jq -c --argjson n "$1" '.rows[] | select(.n == $n) | .parameters'; }
  [ "$(row 1)" = '[{"name":"project_root","value":"/opt/acme/shop"},{"name":"repo_slug","value":"acme/shop-repo"},{"name":"project_name","value":"shop"}]' ]
  [ "$(row 2)" = '[{"name":"site_path","value":"/etc/nginx/sites/site.conf"},{"name":"app_path","value":"~/configs/app.yml"}]' ]
  [ "$(row 3)" = '[{"name":"api_key","secret":true},{"name":"region","value":"eu-west-1"},{"name":"environment","value":"staging"}]' ]
  [ "$(row 4)" = '[{"name":"credential","secret":true}]' ]
  # The key itself never appears in the proposals.
  [[ "$output" != *"$FAKE_KEY"* ]]
  [ "$(printf '%s' "$output" | jq -c '.rows[] | select(.n == 4) | [.redacted, .text_redacted]')" = '[1,true]' ]
  # Read-only without --apply.
  grep -q "$FAKE_KEY" "$CANDS"
}

@test "propose: the same value keeps one name across rows, a different value never shares it" {
  cat > "$CANDS" <<'JSON'
{"candidate_steps_version": 1, "steps": [
  {"n": 1, "text": "edit /srv/a/site.conf"},
  {"n": 2, "text": "edit /srv/b/site.conf then /srv/a/site.conf"}
]}
JSON
  run --separate-stderr propose "$CANDS"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '[.rows[].parameters[] | "\(.name)=\(.value)"]')" = \
    '["site_path=/srv/a/site.conf","site_path_2=/srv/b/site.conf","site_path=/srv/a/site.conf"]' ]
}

@test "propose --apply: fills rows, keeps existing parameters, marks redacted rows uncertain, redacts raw keys" {
  write_detect_candidates
  run --separate-stderr propose --apply "$CANDS"
  [ "$status" -eq 0 ]
  [ "$output" = "$CANDS" ]
  run ! grep -q "$FAKE_KEY" "$CANDS"
  [ "$(jq -r '.steps[3].text' "$CANDS")" = "export it as <redacted> now" ]
  [ "$(jq -c '.steps[4].parameters' "$CANDS")" = '[{"name":"kept","value":"hello"}]' ]
  [ "$(jq -c '[.steps[] | .uncertain // false]' "$CANDS")" = '[false,false,true,true,false]' ]
  [[ "$(jq -r '.steps[2].reason' "$CANDS")" == *"false alarm"* ]]
  bash "$RT" --check "$CANDS"
  run bash "$RT" "$CANDS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"api_key (secret), region=eu-west-1, environment=staging"* ]]
}

@test "propose: an invalid candidates file exits 4 and is left unchanged" {
  printf '%s\n' '{"candidate_steps_version": 2, "steps": []}' > "$CANDS"
  cp "$CANDS" "$T/before.json"
  run propose --apply "$CANDS"
  [ "$status" -eq 4 ]
  cmp "$CANDS" "$T/before.json"
}

# ---- 2. the credential rule --------------------------------------------------------------------------------------

@test "secret-check: key shapes, assignments and markers are credentials; paths and numbers are not" {
  for v in "$FAKE_KEY" "ghp_abcdefghijklmnopqrstuvwxyz" "AKIAABCDEFGHIJKLMNOP" "password=hunter2" "<redacted>" \
           "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJlLXZhbHVl" \
           "https://user:pass@example.com/x"; do
    run bash "$DP" secret-check "$v"
    [ "$status" -eq 0 ] || { echo "not flagged: $v"; return 1; }
  done
  for v in 4096 /opt/acme/shop us-east-1 staging; do
    run bash "$DP" secret-check "$v"
    [ "$status" -eq 1 ] || { echo "flagged: $v"; return 1; }
  done
}

create_recording() {
  bash "$WC" create --source pasted --dir "$RECS" "$CANDS" "$1"
}

@test "record-review refuses a credential-looking literal in decide and accept; nothing is written" {
  cat > "$CANDS" <<JSON
{"candidate_steps_version": 1, "steps": [
  {"n": 1, "text": "log in", "proposal": "include", "step_type": "confirm",
   "parameters": [{"name": "tok", "value": "$FAKE_KEY"}]}
]}
JSON
  REC="$(create_recording "Secret refusal")"
  cp "$REC" "$T/before.md"
  run bash "$RR" accept "$REC" "$CANDS"
  [ "$status" -eq 2 ]
  [[ "$output" == *"looks like a credential"* ]]
  cmp "$REC" "$T/before.md"
  run bash "$RR" decide "$REC" 1 params "tok=$FAKE_KEY"
  [ "$status" -eq 2 ]
  cmp "$REC" "$T/before.md"
  # By name only it is accepted.
  bash "$RR" decide "$REC" 1 params tok >/dev/null
  run ! grep -q "$FAKE_KEY" "$REC"
}

# ---- 3. emission -------------------------------------------------------------------------------------------------

# Three included steps and one excluded; parameters confirmed through record-review.sh (record-answer.sh).
build_param_recording() {
  cat > "$CANDS" <<'JSON'
{"candidate_steps_version": 1, "steps": [
  {"n": 1, "text": "cd /opt/acme/shop and list /opt/acme/shop/src"},
  {"n": 2, "text": "j.connect stripe with api_key=<redacted> for /opt/acme/shop"},
  {"n": 3, "text": "scripts/deploy.sh /opt/acme/shop us-east-1"},
  {"n": 4, "text": "what is the weather in us-east-1"}
]}
JSON
  REC="$(create_recording "Shop setup")"
  bash "$RR" decide "$REC" 1 include >/dev/null
  bash "$RR" decide "$REC" 1 type confirm >/dev/null
  bash "$RR" decide "$REC" 1 params project_root=/opt/acme/shop >/dev/null
  bash "$RR" decide "$REC" 2 include >/dev/null
  bash "$RR" decide "$REC" 2 type skill >/dev/null
  bash "$RR" decide "$REC" 2 params api_key project_root=/opt/acme/shop >/dev/null
  bash "$RR" decide "$REC" 3 include >/dev/null
  bash "$RR" decide "$REC" 3 type compute >/dev/null
  bash "$RR" decide "$REC" 3 params project_root=/opt/acme/shop region=us-east-1 >/dev/null
  bash "$RR" decide "$REC" 4 exclude >/dev/null
  bash "$RR" decide "$REC" 4 params unused=weather >/dev/null
  bash "$WC" seal "$REC" "$CANDS" >/dev/null
}

@test "emit: confirmed parameters become inputs and every occurrence becomes \${inputs.<name>}" {
  build_param_recording
  run --separate-stderr bash "$WC" emit "$REC"
  [ "$status" -eq 0 ]
  DEF="$output"
  [ "$(jq -c '[.inputs[] | .name]' "$DEF")" = '["project_root","api_key","region"]' ]
  [ "$(jq -c '[.inputs[] | has("default")] | unique' "$DEF")" = '[false]' ]
  [ "$(jq -r '.steps[0].prompt' "$DEF")" = 'cd ${inputs.project_root} and list ${inputs.project_root}/src' ]
  [ "$(jq -r '.steps[1].skill' "$DEF")" = 'j.connect' ]
  [ "$(jq -r '.steps[1].args.input' "$DEF")" = 'stripe with api_key=${inputs.api_key} for ${inputs.project_root}' ]
  [ "$(jq -r '.steps[2].command' "$DEF")" = 'scripts/deploy.sh' ]
  [ "$(jq -c '.steps[2].args' "$DEF")" = '["${inputs.project_root}","${inputs.region}"]' ]
  [ "$(jq -r '.steps[2].description' "$DEF")" = 'scripts/deploy.sh ${inputs.project_root} ${inputs.region}' ]
  # The excluded step contributes nothing (no "unused" input), and neither literal nor marker is left.
  [ "$(jq '.steps | length' "$DEF")" -eq 3 ]
  run ! grep -q -e '/opt/acme' -e 'us-east-1' -e '<redacted>' -e 'unused' "$DEF"
  run bash "$VALIDATOR" "$DEF"
  [ "$status" -eq 0 ]
  # Key order: inputs sits between provenance and steps.
  [ "$(jq -c 'keys_unsorted' "$DEF")" = '["id","name","description","source_recording","provenance","inputs","steps"]' ]
}

@test "emit: re-emission with parameters is byte-identical" {
  build_param_recording
  DEF="$(bash "$WC" emit "$REC")"
  cp "$DEF" "$T/first.json"
  cp "$REC" "$T/first.md"
  run --separate-stderr bash "$WC" emit "$REC"
  [ "$status" -eq 0 ]
  cmp "$DEF" "$T/first.json"
  cmp "$REC" "$T/first.md"
}

@test "emit: a longer literal wins over a literal it contains, and nothing is rescanned" {
  cat > "$CANDS" <<'JSON'
{"candidate_steps_version": 1, "steps": [
  {"n": 1, "text": "cd /opt/shop then name the build shop"}
]}
JSON
  REC="$(create_recording "Overlap")"
  bash "$RR" decide "$REC" 1 include >/dev/null
  bash "$RR" decide "$REC" 1 type confirm >/dev/null
  bash "$RR" decide "$REC" 1 params name=shop root=/opt/shop >/dev/null
  bash "$WC" seal "$REC" "$CANDS" >/dev/null
  DEF="$(bash "$WC" emit "$REC")"
  [ "$(jq -r '.steps[0].prompt' "$DEF")" = 'cd ${inputs.root} then name the build ${inputs.name}' ]
  bash "$VALIDATOR" "$DEF"
}

@test "emit: a name for two values, or an input that replaces nothing, exits 12 and emits nothing" {
  cat > "$CANDS" <<'JSON'
{"candidate_steps_version": 1, "steps": [
  {"n": 1, "text": "cd /opt/a and run"},
  {"n": 2, "text": "cd /opt/b now"}
]}
JSON
  REC="$(create_recording "Conflict")"
  for n in 1 2; do
    bash "$RR" decide "$REC" "$n" include >/dev/null
    bash "$RR" decide "$REC" "$n" type confirm >/dev/null
  done
  bash "$RR" decide "$REC" 1 params root=/opt/a >/dev/null
  bash "$RR" decide "$REC" 2 params root=/opt/b >/dev/null
  bash "$WC" seal "$REC" "$CANDS" >/dev/null
  run bash "$WC" emit "$REC"
  [ "$status" -eq 12 ]
  [[ "$output" == *"root stands for different values"* ]]
  [ ! -e "$PROJ/project/.workflows/conflict.json" ]

  bash "$RR" decide "$REC" 2 params other=/opt/zzz --replace >/dev/null
  run bash "$WC" emit "$REC"
  [ "$status" -eq 12 ]
  [[ "$output" == *"occurs in no included step"* ]]
  [[ "$output" == *"other"* ]]
  [ ! -e "$PROJ/project/.workflows/conflict.json" ]

  bash "$RR" decide "$REC" 2 params none --replace >/dev/null
  run --separate-stderr bash "$WC" emit "$REC"
  [ "$status" -eq 0 ]
  bash "$VALIDATOR" "$output"
}

@test "emit: one value under two names exits 12" {
  cat > "$CANDS" <<'JSON'
{"candidate_steps_version": 1, "steps": [
  {"n": 1, "text": "cd /opt/a"},
  {"n": 2, "text": "ls /opt/a"}
]}
JSON
  REC="$(create_recording "Two names")"
  for n in 1 2; do
    bash "$RR" decide "$REC" "$n" include >/dev/null
    bash "$RR" decide "$REC" "$n" type confirm >/dev/null
  done
  bash "$RR" decide "$REC" 1 params one=/opt/a >/dev/null
  bash "$RR" decide "$REC" 2 params two=/opt/a >/dev/null
  bash "$WC" seal "$REC" "$CANDS" >/dev/null
  run bash "$WC" emit "$REC"
  [ "$status" -eq 12 ]
  [[ "$output" == *"more than one name"* ]]
}

@test "emit: a credential name with no redaction marker is declared and substitutes nothing" {
  cat > "$CANDS" <<'JSON'
{"candidate_steps_version": 1, "steps": [
  {"n": 1, "text": "log in to the deploy service"}
]}
JSON
  REC="$(create_recording "Bare only")"
  bash "$RR" decide "$REC" 1 include >/dev/null
  bash "$RR" decide "$REC" 1 type confirm >/dev/null
  bash "$RR" decide "$REC" 1 params deploy_token >/dev/null
  bash "$WC" seal "$REC" "$CANDS" >/dev/null
  run --separate-stderr bash "$WC" emit "$REC"
  [ "$status" -eq 0 ]
  DEF="$output"
  [ "$(jq -c '[.inputs[] | .name]' "$DEF")" = '["deploy_token"]' ]
  [ "$(jq -r '.steps[0].prompt' "$DEF")" = 'log in to the deploy service' ]
  bash "$VALIDATOR" "$DEF"
}

# ---- 4. no parameters: unchanged ---------------------------------------------------------------------------------

@test "emit: without confirmed parameters the definition has no inputs key" {
  cat > "$CANDS" <<'JSON'
{"candidate_steps_version": 1, "steps": [
  {"n": 1, "text": "cd /opt/a and look"},
  {"n": 2, "text": "check again"}
]}
JSON
  REC="$(create_recording "Plain")"
  for n in 1 2; do
    bash "$RR" decide "$REC" "$n" include >/dev/null
    bash "$RR" decide "$REC" "$n" type confirm >/dev/null
  done
  bash "$RR" decide "$REC" 1 params none >/dev/null
  bash "$WC" seal "$REC" "$CANDS" >/dev/null
  DEF="$(bash "$WC" emit "$REC")"
  [ "$(jq -c 'keys_unsorted' "$DEF")" = '["id","name","description","source_recording","provenance","steps"]' ]
  [ "$(jq -r '.steps[0].prompt' "$DEF")" = 'cd /opt/a and look' ]
}

@test "the new script never names the active-recording pointer script and answers --help" {
  run ! grep -n 'active-recording\.sh' "$DP"
  run bash "$DP" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage:"* ]]
}
