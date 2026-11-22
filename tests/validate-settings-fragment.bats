#!/usr/bin/env bats
# bats file_tags=tier:fast
#
# E100_S02_T04: scripts/validate-settings-fragment.sh (E100_S02_T02) and the j.workflow-recorder fragment
# skills/j-workflow-recorder/settings-fragment.json (E100_S02_T03).
#
# Every fixture lives under $BATS_TEST_TMPDIR; no settings file of the repository is written. The script is always run as
# `bash <script>`, so the cases do not depend on its executable bit. Written without being executed by its author; the
# tester runs it.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/validate-settings-fragment.sh"
REAL_FRAGMENT="$REPO_ROOT/skills/j-workflow-recorder/settings-fragment.json"

# write_fragment <name> <json>: writes $BATS_TEST_TMPDIR/<name>.json and prints its path.
write_fragment() {
  printf '%s\n' "$2" > "$BATS_TEST_TMPDIR/$1.json"
  printf '%s' "$BATS_TEST_TMPDIR/$1.json"
}

HOOK='"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"true"}]}]}'

@test "a valid fragment is accepted with exit 0" {
  f="$(write_fragment good "{\"id\":\"good-one\",\"version\":1,$HOOK}")"
  run -0 bash "$SCRIPT" "$f"
  assert_output_contains "ok: $f (good-one)"
}

@test "defaultMode is rejected, naming the fragment and the key" {
  f="$(write_fragment bad-mode '{"id":"bad-mode","version":1,"defaultMode":"bypassPermissions"}')"
  run ! bash "$SCRIPT" "$f"
  assert_output_contains "$f"
  assert_output_contains "defaultMode"
}

@test "permissions.deny is rejected, naming the fragment and the key" {
  f="$(write_fragment bad-deny '{"id":"bad-deny","version":1,"permissions":{"deny":["Bash(rm *)"]}}')"
  run ! bash "$SCRIPT" "$f"
  assert_output_contains "$f"
  assert_output_contains "permissions.deny"
}

@test "permissions.ask is rejected, naming the fragment and the key" {
  f="$(write_fragment bad-ask '{"id":"bad-ask","version":1,"permissions":{"ask":["Bash(git push *)"]}}')"
  run ! bash "$SCRIPT" "$f"
  assert_output_contains "$f"
  assert_output_contains "permissions.ask"
}

@test "a model setting is rejected, naming the fragment and the key" {
  f="$(write_fragment bad-model '{"id":"bad-model","version":1,"model":"some-model"}')"
  run ! bash "$SCRIPT" "$f"
  assert_output_contains "$f"
  assert_output_contains "model"
}

@test "an unknown top-level key is rejected, naming the fragment and the key" {
  f="$(write_fragment bad-unknown '{"id":"bad-unknown","version":1,"statusLine":{"type":"command"}}')"
  run ! bash "$SCRIPT" "$f"
  assert_output_contains "$f"
  assert_output_contains "statusLine"
}

@test "an allow rule not marked opt-in is rejected" {
  f="$(write_fragment bad-allow '{"id":"bad-allow","version":1,"permissions":{"allow":[{"rule":"Bash(ls *)"}]}}')"
  run ! bash "$SCRIPT" "$f"
  assert_output_contains "$f"
  assert_output_contains "permissions.allow[0].optIn"
}

@test "an env key that looks like a secret is rejected" {
  f="$(write_fragment bad-secret '{"id":"bad-secret","version":1,"env":{"MY_API_TOKEN":"x"}}')"
  run ! bash "$SCRIPT" "$f"
  assert_output_contains "$f"
  assert_output_contains "env.MY_API_TOKEN"
}

@test "a non-string env value is rejected" {
  f="$(write_fragment bad-envval '{"id":"bad-envval","version":1,"env":{"FLAG":1}}')"
  run ! bash "$SCRIPT" "$f"
  assert_output_contains "$f"
  assert_output_contains "env.FLAG"
  assert_output_contains "value must be a string"
}

@test "a missing id is rejected" {
  f="$(write_fragment bad-noid "{\"version\":1,$HOOK}")"
  run ! bash "$SCRIPT" "$f"
  assert_output_contains "$f"
  assert_output_contains "id: missing required key"
}

@test "an unparseable file is reported and exits non-zero" {
  printf '%s\n' '{ not json' > "$BATS_TEST_TMPDIR/broken.json"
  run ! bash "$SCRIPT" "$BATS_TEST_TMPDIR/broken.json"
  assert_output_contains "$BATS_TEST_TMPDIR/broken.json"
  assert_output_contains "not valid JSON"
}

@test "a multi-fragment run reports every problem before exiting non-zero" {
  a="$(write_fragment multi-a '{"id":"multi-a","version":1,"defaultMode":"x","env":{"DB_PASSWORD":"x"}}')"
  b="$(write_fragment multi-b "{\"id\":\"multi-b\",\"version\":1,$HOOK}")"
  c="$(write_fragment multi-c '{"id":"multi-c","version":1,"permissions":{"deny":["x"]}}')"
  run ! bash "$SCRIPT" "$a" "$b" "$c"
  assert_output_contains "$a: defaultMode"
  assert_output_contains "$a: env.DB_PASSWORD"
  assert_output_contains "ok: $b (multi-b)"
  assert_output_contains "$c: permissions.deny"
}

@test "the shipped recorder fragment validates" {
  run -0 bash "$SCRIPT" "$REAL_FRAGMENT"
  assert_output_contains "(workflow-recorder)"
}

@test "the recorder fragment equals the settings.json recorder entry after normalisation" {
  command -v jq >/dev/null
  frag="$(jq -S '.hooks.UserPromptSubmit' "$REAL_FRAGMENT")"
  entry="$(jq -S '[.hooks.UserPromptSubmit[] | select(.hooks[].command | contains("on_recording_step.sh"))]' "$REPO_ROOT/settings.json")"
  [ -n "$frag" ]
  [ "$frag" = "$entry" ]
}

@test "the validator works in a consumer layout (node_modules/@jenga-ai/agent), not only from the repository root" {
  pkg="$BATS_TEST_TMPDIR/consumer/node_modules/@jenga-ai/agent"
  mkdir -p "$pkg/scripts" "$pkg/templates" "$pkg/skills/index/scripts" "$pkg/skills/j-workflow-recorder"
  cp "$SCRIPT" "$pkg/scripts/validate-settings-fragment.sh"
  cp "$REPO_ROOT/skills/index/scripts/package-root.sh" "$pkg/skills/index/scripts/package-root.sh"
  : > "$pkg/scripts/resolve-root.sh"
  cp "$REAL_FRAGMENT" "$pkg/skills/j-workflow-recorder/settings-fragment.json"
  cd "$BATS_TEST_TMPDIR/consumer"
  pkg="$(cd "$pkg" && pwd -P)"   # macOS: BATS_TEST_TMPDIR is under the /var -> /private/var symlink
  run -0 bash "$pkg/scripts/validate-settings-fragment.sh"
  assert_output_contains "ok: $pkg/skills/j-workflow-recorder/settings-fragment.json (workflow-recorder)"
}
