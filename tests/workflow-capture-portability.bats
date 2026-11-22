#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# tests/workflow-capture-portability.bats - j.workflow-capture's portability check at emission (E103_S05_T01)
#
# Pins:
#   1. check-portability.sh check reports each of the three finding kinds (unshipped-skill, absolute-path,
#      project-name) with the step id and the offending text, and is silent with exit 0 on a clean definition.
#   2. The shipped-skill set is derived from the repository's own sources: the skill catalog on disk, and, in this
#      framework's own repository, .publicignore through scripts/check-publicignore-match.sh. No list is hard-coded.
#   3. accept records the user's acceptance through record-answer.sh (kind portability), and check then reports the
#      finding as accepted; record-answer.sh refuses a malformed portability body.
#   4. Nothing here reads or writes the active-recording pointer.
# All state lives under $BATS_TEST_TMPDIR.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CP="$REPO_ROOT/skills/j-workflow-capture/scripts/check-portability.sh"
RECORDER="$REPO_ROOT/skills/j-workflow-recorder/scripts"
RF="$RECORDER/recording-file.sh"
RA="$RECORDER/record-answer.sh"

setup() {
  T="$BATS_TEST_TMPDIR"
  FW="$T/fw"
  for d in j-status j-commit jenga; do
    mkdir -p "$FW/skills/$d"
    printf -- '---\nname: x\n---\n' > "$FW/skills/$d/SKILL.md"
  done
  DEF="$T/def.json"
  REC="$T/acme-flow_RECORDING.md"
  export JENGA_RECORDER_NOW=2026-11-20T01:02:03Z
  export JENGA_RECORDING_STATE_DIR="$T/pointer-state"
  export JENGA_RECORDING_SESSION_ID="capture-portability-$BATS_TEST_NUMBER"
}

# check against the fixture catalog, with fixed project names (no git lookups).
check() { bash "$CP" check --framework-root "$FW" --project-root /srv/acme-site --repo octo/acme-site "$@"; }

write_def() { printf '%s\n' "$1" > "$DEF"; }

write_recording() {
  bash "$RF" create --source pasted "$REC" "acme flow" >/dev/null
  local i
  for i in 1 2 3; do bash "$RF" append "$REC" "step $i" >/dev/null; done
}

TAB="$(printf '\t')"

@test "the script passes bash -n and --help exits 0 with usage" {
  run bash -n "$CP"
  [ "$status" -eq 0 ]
  run bash "$CP" --help
  [ "$status" -eq 0 ]
  assert_output_contains "usage:"
}

@test "a clean definition: no output, exit 0" {
  write_def '{"id":"x","name":"x","steps":[
    {"id":"step_001","type":"skill","skill":"j.status","description":"j.status then /j-commit"},
    {"id":"step_002","type":"compute","command":"scripts/build.sh","args":["${inputs.site_dir}"],"description":"see https://example.com/a/b"},
    {"id":"step_003","type":"skill","skill":"jenga","description":"run jenga"}]}'
  run check "$DEF"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unshipped-skill: the skill field, j.x and /j-x tokens and skills/<dir>/ references, with step id and text" {
  write_def '{"id":"x","name":"x","steps":[
    {"id":"step_001","type":"skill","skill":"j.status","description":"fine"},
    {"id":"step_002","type":"skill","skill":"j.mirror-public","description":"then /j-self-sync and j.no-such-skill"},
    {"id":"step_003","type":"compute","command":"skills/j-train/scripts/t.sh","description":"x"}]}'
  run check "$DEF"
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "step_002${TAB}unshipped-skill${TAB}j.mirror-public${TAB}open" ]
  [ "${lines[1]}" = "step_002${TAB}unshipped-skill${TAB}/j-self-sync${TAB}open" ]
  [ "${lines[2]}" = "step_002${TAB}unshipped-skill${TAB}j.no-such-skill${TAB}open" ]
  [ "${lines[3]}" = "step_003${TAB}unshipped-skill${TAB}skills/j-train/${TAB}open" ]
  [ "${#lines[@]}" -eq 4 ]
}

@test "absolute-path: two-segment and ~/ paths, not URLs and not one-segment tokens" {
  write_def '{"id":"x","name":"x","steps":[
    {"id":"step_004","type":"compute","command":"scripts/x.sh","args":["/opt/build/out","~/notes/a.md"],
     "description":"fetch https://example.com/a/b and run /j-commit"}]}'
  run check "$DEF"
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "step_004${TAB}absolute-path${TAB}/opt/build/out${TAB}open" ]
  [ "${lines[1]}" = "step_004${TAB}absolute-path${TAB}~/notes/a.md${TAB}open" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "project-name: repo slug, repo or project name as a whole word, case-insensitive; a path is not reported twice" {
  write_def '{"id":"x","name":"x","steps":[
    {"id":"step_001","type":"confirm","prompt":"Is Acme-Site ready in octo/acme-site?","options":["Yes","No"]},
    {"id":"step_002","type":"compute","command":"scripts/x.sh","args":["/srv/acme-site/dist"],"description":"acme-sites is another word"}]}'
  run check "$DEF"
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "step_001${TAB}project-name${TAB}octo/acme-site${TAB}open" ]
  [ "${lines[1]}" = "step_001${TAB}project-name${TAB}Acme-Site${TAB}open" ]
  [ "${lines[2]}" = "step_002${TAB}absolute-path${TAB}/srv/acme-site/dist${TAB}open" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "an empty --project-name and --repo switch the name check off" {
  write_def '{"id":"x","name":"x","steps":[{"id":"step_001","type":"confirm","prompt":"acme-site?","options":["Yes","No"]}]}'
  run bash "$CP" check --framework-root "$FW" --project-name "" --repo "" "$DEF"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the shipped set follows the catalog on disk: adding a skill directory makes it shipped" {
  write_def '{"id":"x","name":"x","steps":[{"id":"step_001","type":"skill","skill":"j.deploy","description":"x"}]}'
  run check "$DEF"
  [ "$status" -eq 1 ]
  mkdir -p "$FW/skills/j-deploy"; printf 'x\n' > "$FW/skills/j-deploy/SKILL.md"
  run check "$DEF"
  [ "$status" -eq 0 ]
  run bash "$CP" shipped-skills --framework-root "$FW"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'j-commit\nj-deploy\nj-status\njenga')" ]
}

@test "in the framework's own repository the shipped set honours .publicignore (via check-publicignore-match.sh)" {
  run bash "$CP" shipped-skills
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fxq j-status
  printf '%s\n' "$output" | grep -Fxq j-workflow-capture
  if [ -f "$REPO_ROOT/.publicignore" ] && [ -d "$REPO_ROOT/skills/j-mirror-public" ]; then
    # On disk, but blocklisted: not shipped.
    [ -z "$(printf '%s\n' "$output" | grep -Fx j-mirror-public)" ]
  fi
}

@test "accept records the finding with record-answer.sh and check reports it as accepted" {
  write_recording
  write_def '{"id":"x","name":"x","steps":[
    {"id":"step_002","type":"compute","command":"scripts/x.sh","args":["/opt/build/out"],"description":"acme-site"}]}'
  run bash "$CP" accept --recording "$REC" step_002 absolute-path /opt/build/out
  [ "$status" -eq 0 ]
  run bash "$RA" --value "$REC" step-002 portability
  [ "$status" -eq 0 ]
  [ "$output" = "accepted" ]
  run check --recording "$REC" "$DEF"
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "step_002${TAB}absolute-path${TAB}/opt/build/out${TAB}accepted" ]
  [ "${lines[1]}" = "step_002${TAB}project-name${TAB}acme-site${TAB}open" ]
  # A second finding on the same step is added, and accepting it twice changes nothing.
  bash "$CP" accept --recording "$REC" step-002 project-name acme-site
  bash "$CP" accept --recording "$REC" step_002 project-name acme-site
  run bash "$RA" --text "$REC" step-002 portability
  [ "$output" = "$(printf 'absolute-path /opt/build/out\nproject-name acme-site')" ]
  run check --recording "$REC" "$DEF"
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "step_002${TAB}project-name${TAB}acme-site${TAB}accepted" ]
}

@test "accept refuses an unknown kind, an empty text, a missing recording and an unknown step" {
  write_recording
  run bash "$CP" accept --recording "$REC" step_001 bogus x
  [ "$status" -eq 2 ]
  run bash "$CP" accept --recording "$REC" step_001 project-name ""
  [ "$status" -eq 2 ]
  run bash "$CP" accept step_001 project-name x
  [ "$status" -eq 2 ]
  run bash "$CP" accept --recording "$T/none_RECORDING.md" step_001 project-name x
  [ "$status" -eq 3 ]
  run bash "$CP" accept --recording "$REC" step_009 project-name x
  [ "$status" -eq 5 ]
}

@test "record-answer.sh's portability kind refuses a body outside its shape" {
  write_recording
  run bash "$RA" "$REC" step-001 portability "not a finding"
  [ "$status" -ne 0 ]
  run bash "$RA" "$REC" step-001 portability "project-name acme"
  [ "$status" -eq 0 ]
}

@test "check refuses a missing or non-workflow definition" {
  run check "$T/none.json"
  [ "$status" -eq 3 ]
  printf 'not json\n' > "$DEF"
  run check "$DEF"
  [ "$status" -eq 4 ]
}

@test "nothing touches the active-recording pointer" {
  run grep -c 'active-recording[.]sh' "$CP"
  [ "$output" = "0" ]
  write_recording
  write_def '{"id":"x","name":"x","steps":[{"id":"step_001","type":"confirm","prompt":"acme-site","options":["Yes","No"]}]}'
  check --recording "$REC" "$DEF" || true
  bash "$CP" accept --recording "$REC" step_001 project-name acme-site
  [ ! -e "$JENGA_RECORDING_STATE_DIR" ]
}
