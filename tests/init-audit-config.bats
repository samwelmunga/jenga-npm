#!/usr/bin/env bats
#
# E85_S01_T10: /j-init scaffolds project/configs/audit-config.json in its safe
# default (mode: ask), copied from skills/j-init/assets/audit-config_template.json.
#
# Re-run behaviour (documented, not changed here): init.sh's config copies are
# unconditional `cp`s, exactly like workflow.json, test-config.json and
# scope-thresholds.json. What stops a re-run from clobbering an edited config is
# the /j-init SKILL.md hard-stop on the `already-scaffolded` verdict of
# detect-existing-codebase.sh, which the last test asserts.
#
# Every test runs in a throwaway $BATS_TEST_TMPDIR, never in this repository.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
TEMPLATE="$REPO_ROOT/skills/j-init/assets/audit-config_template.json"
LIVE="$REPO_ROOT/project/configs/audit-config.json"

setup() {
  CONSUMER_DIR="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$CONSUMER_DIR"
  # init.sh commits; supply an identity so a bare runner does not abort.
  export GIT_AUTHOR_NAME="Jenga Test" GIT_AUTHOR_EMAIL="test@example.com"
  export GIT_COMMITTER_NAME="Jenga Test" GIT_COMMITTER_EMAIL="test@example.com"
}

scaffold() {
  run bash -c "cd '$CONSUMER_DIR' && bash '$REPO_ROOT/skills/j-init/scripts/init.sh' --visibility visible"
  [ "$status" -eq 0 ]
}

@test "a fresh scaffold produces audit-config.json with mode ask and the four other defaults" {
  scaffold
  local cfg="$CONSUMER_DIR/project/configs/audit-config.json"
  [ -f "$cfg" ]
  run jq -c '.' "$cfg"
  [ "$output" = '{"config_version":1,"mode":"ask","severity_threshold":"high","offline_behavior":"warn","production_only":false}' ]
}

@test "the init template carries the descriptor defaults and the same keys as the live project config" {
  # the live config may be stricter than the shipped default (this repository sets offline_behavior to fail), so
  # values are compared with the descriptor defaults, and only the key set with the live file
  run jq -n -e --slurpfile t "$TEMPLATE" --slurpfile l "$LIVE" --slurpfile d "$BATS_TEST_DIRNAME/../templates/config-descriptors/audit-config.json" \
    '([$d[0].keys[] | select(.editable == true) | {(.key): .default}] | add) as $def
     | (($t[0] | keys) == ($l[0] | keys))
       and ($t[0].config_version == 1)
       and all($def | keys[]; . as $k | $t[0][$k] == $def[$k])'
  [ "$status" -eq 0 ]
}

@test "the scaffolded audit-config.json is the template, byte for byte" {
  scaffold
  cmp "$TEMPLATE" "$CONSUMER_DIR/project/configs/audit-config.json"
}

@test "jenga config get audit-config.mode works in the scaffolded project" {
  scaffold
  run --separate-stderr env JENGA_PROJECT_ROOT="$CONSUMER_DIR" node "$REPO_ROOT/bin/jenga.js" config get audit-config.mode
  [ "$status" -eq 0 ]
  assert_output_contains "ask"
}

@test "validate-config-descriptors.sh --all passes on a freshly scaffolded root including audit-config" {
  scaffold
  run env JENGA_PROJECT_ROOT="$CONSUMER_DIR" bash "$REPO_ROOT/scripts/validate-config-descriptors.sh" --all
  [ "$status" -eq 0 ]
  assert_output_not_contains "FAIL"
  assert_output_contains "audit-config"
}

@test "an edited audit-config.json is protected on re-run by the already-scaffolded stop" {
  scaffold
  jq '.mode = "on"' "$CONSUMER_DIR/project/configs/audit-config.json" > "$BATS_TEST_TMPDIR/edited.json"
  cp "$BATS_TEST_TMPDIR/edited.json" "$CONSUMER_DIR/project/configs/audit-config.json"
  run bash "$REPO_ROOT/skills/j-init/scripts/detect-existing-codebase.sh" "$CONSUMER_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "already-scaffolded" ]
  [ "$(jq -r '.mode' "$CONSUMER_DIR/project/configs/audit-config.json")" = "on" ]
}

# ---------------------------------------------------------------------------
# E85_S04_T03: init.sh calls scripts/audit-notice.sh show --context init right after it writes
# audit-config.json. init.sh's config copy is unconditional, so a config that is already in mode on or off cannot
# be pre-seeded in the consumer dir; the cases below instead build a throwaway package root whose
# audit-config template carries that mode (the file init.sh copies), which exercises the same wiring.
# ---------------------------------------------------------------------------

NOTICE_HEAD="Dependency audits are not running yet."

# Builds $BATS_TEST_TMPDIR/pkg: a copy of skills/j-init and scripts/ (so assets and the notice script can be
# altered) with templates/ and lib/ symlinked. Sets FIX_INIT to the copied init.sh.
make_pkg() {
  local pkg="$BATS_TEST_TMPDIR/pkg"
  mkdir -p "$pkg/skills"
  cp -R "$REPO_ROOT/skills/j-init" "$pkg/skills/j-init"
  cp -R "$REPO_ROOT/scripts" "$pkg/scripts"
  ln -s "$REPO_ROOT/templates" "$pkg/templates"
  ln -s "$REPO_ROOT/lib" "$pkg/lib"
  FIX_PKG="$pkg"
  FIX_INIT="$pkg/skills/j-init/scripts/init.sh"
}

# Same as scaffold(), but against the fixture package and with stderr kept separate.
scaffold_fixture() {
  run --separate-stderr bash -c "cd '$CONSUMER_DIR' && bash '$FIX_INIT' --visibility visible"
}

count_notice() { # <text>
  printf '%s\n' "$1" | grep -c -F "$NOTICE_HEAD" || true
}

@test "a fresh scaffold prints the audit opt-in notice exactly once, after audit-config.json is written" {
  scaffold
  [ "$(count_notice "$output")" -eq 1 ]
  local copy_line notice_line next_line
  copy_line="$(printf '%s\n' "$output" | grep -n -F 'Copying audit-config.json' | head -1 | cut -d: -f1)"
  notice_line="$(printf '%s\n' "$output" | grep -n -F "$NOTICE_HEAD" | head -1 | cut -d: -f1)"
  next_line="$(printf '%s\n' "$output" | grep -n -F 'Creating baselines.json' | head -1 | cut -d: -f1)"
  [ "$copy_line" -lt "$notice_line" ]
  [ "$notice_line" -lt "$next_line" ]
}

@test "the scaffold notice tells the user how to enable audits" {
  scaffold
  assert_output_contains "jenga config set audit-config.mode on"
}

@test "the scaffold notice leaves a git-ignored marker and does not enter the initial commit" {
  scaffold
  [ -f "$CONSUMER_DIR/project/data/audit-notice-shown" ]
  run git -C "$CONSUMER_DIR" ls-files --error-unmatch project/data/audit-notice-shown
  [ "$status" -ne 0 ]
}

@test "no notice is printed when the scaffolded audit-config mode is on" {
  make_pkg
  jq '.mode = "on"' "$FIX_PKG/skills/j-init/assets/audit-config_template.json" > "$BATS_TEST_TMPDIR/on.json"
  cp "$BATS_TEST_TMPDIR/on.json" "$FIX_PKG/skills/j-init/assets/audit-config_template.json"
  scaffold_fixture
  [ "$status" -eq 0 ]
  [ "$(jq -r '.mode' "$CONSUMER_DIR/project/configs/audit-config.json")" = "on" ]
  [ "$(count_notice "$output")" -eq 0 ]
  [ ! -e "$CONSUMER_DIR/project/data/audit-notice-shown" ]
}

@test "no notice is printed when the scaffolded audit-config mode is off" {
  make_pkg
  jq '.mode = "off"' "$FIX_PKG/skills/j-init/assets/audit-config_template.json" > "$BATS_TEST_TMPDIR/off.json"
  cp "$BATS_TEST_TMPDIR/off.json" "$FIX_PKG/skills/j-init/assets/audit-config_template.json"
  scaffold_fixture
  [ "$status" -eq 0 ]
  [ "$(count_notice "$output")" -eq 0 ]
  [ ! -e "$CONSUMER_DIR/project/data/audit-notice-shown" ]
}

@test "the fixture package prints the notice once in mode ask (control for the on and off cases)" {
  make_pkg
  scaffold_fixture
  [ "$status" -eq 0 ]
  [ "$(count_notice "$output")" -eq 1 ]
}

@test "the scaffold still succeeds, with a stderr note, when audit-notice.sh is absent" {
  make_pkg
  rm "$FIX_PKG/scripts/audit-notice.sh"
  scaffold_fixture
  [ "$status" -eq 0 ]
  [ "$(count_notice "$output")" -eq 0 ]
  [[ "$stderr" == *"audit-notice.sh not found"* ]]
  [ -f "$CONSUMER_DIR/project/configs/audit-config.json" ]
  [ -f "$CONSUMER_DIR/project/data/baselines.json" ]
}

@test "the scaffold still succeeds when audit-notice.sh fails with a non-2 exit" {
  make_pkg
  printf '#!/usr/bin/env bash\necho boom >&2\nexit 3\n' > "$FIX_PKG/scripts/audit-notice.sh"
  scaffold_fixture
  [ "$status" -eq 0 ]
  [ "$(count_notice "$output")" -eq 0 ]
  [ -f "$CONSUMER_DIR/project/data/baselines.json" ]
}

@test "exit 2 from audit-notice.sh is shown as a warning on stderr and the scaffold still succeeds" {
  make_pkg
  printf '#!/usr/bin/env bash\necho bad config >&2\nexit 2\n' > "$FIX_PKG/scripts/audit-notice.sh"
  scaffold_fixture
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"Warning: audit-notice.sh reported a malformed audit-config.json"* ]]
  [ -f "$CONSUMER_DIR/project/data/baselines.json" ]
}

@test "the notice is shown for a scaffold nested under a project whose audit mode is on" {
  make_pkg
  # a parent project in mode on must not suppress the notice for the nested scaffold
  mkdir -p "$BATS_TEST_TMPDIR/outer/project/configs"
  printf '{"paths":{}}\n' > "$BATS_TEST_TMPDIR/outer/project/configs/workflow.json"
  printf '{"config_version":1,"mode":"on"}\n' > "$BATS_TEST_TMPDIR/outer/project/configs/audit-config.json"
  CONSUMER_DIR="$BATS_TEST_TMPDIR/outer/inner"
  mkdir -p "$CONSUMER_DIR"
  scaffold_fixture
  [ "$status" -eq 0 ]
  [ "$(count_notice "$output")" -eq 1 ]
}
