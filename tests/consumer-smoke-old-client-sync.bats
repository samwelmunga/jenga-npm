#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# E100_S06_T03: the old-client phase of scripts/consumer-smoke-after-sync.sh. Self-contained: it uses
# --old-client-only, which needs neither ../st-test nor npm pack, only the offline old-client fixture.

bats_require_minimum_version 1.5.0

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  S="$REPO/scripts/consumer-smoke-after-sync.sh"
  FIX="$BATS_TEST_TMPDIR/old-client"
  unset JENGA_ST_TEST
  bash "$REPO/scripts/consumer-old-client-fixture.sh" "$FIX" "$REPO" >/dev/null
  PKG="$FIX/node_modules/@jenga-ai/agent"
}

@test "sync on the old fixture: every declared requirement is reported active, one line each, using the doctor" {
  run bash "$S" --old-client-only --old-client-fixture "$FIX"
  [ "$status" -eq 0 ]
  [[ "$output" == *"using scripts/settings-doctor.sh"* ]]
  [[ "$output" == *"PASS  old client requirement workflow-recorder: hooks.UserPromptSubmit[0]"* ]]
  want="$(bash "$PKG/scripts/settings-doctor.sh" --json --project-dir "$FIX" --home "$BATS_TEST_TMPDIR/h" 2>/dev/null | grep -c .)"
  have="$(printf '%s\n' "$output" | grep -c '^PASS  old client requirement [^ ]*: ')"
  [ "$want" -ge 1 ]
  [ "$have" -eq "$want" ]
}

@test "the recorder UserPromptSubmit hook is asserted in both settings files" {
  run bash "$S" --old-client-only --old-client-fixture "$FIX"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS  old client: j.workflow-recorder UserPromptSubmit hook in .claude/settings.json"* ]]
  [[ "$output" == *"PASS  old client: j.workflow-recorder UserPromptSubmit hook in .agents/settings.json"* ]]
  grep -q on_recording_step.sh "$FIX/.claude/settings.json"
  grep -q on_recording_step.sh "$FIX/.agents/settings.json"
}

@test "a hook requirement that is absent after the sync is a FAIL line naming it, exit 1" {
  rm "$PKG/scripts/merge-settings.sh"
  run bash "$S" --old-client-only --old-client-fixture "$FIX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  old client requirement workflow-recorder: hooks.UserPromptSubmit[0]"* ]]
  [[ "$output" == *"FAIL  old client: j.workflow-recorder UserPromptSubmit hook in .claude/settings.json"* ]]
  [[ "$output" == *"VERDICT: FAIL"* ]]
}

@test "an allow requirement is inactive without a yes: a SKIP line, not PASS, not FAIL" {
  mkdir -p "$PKG/skills/j-zz-allow-probe"
  cat > "$PKG/skills/j-zz-allow-probe/settings-fragment.json" <<'JSON'
{ "id": "zz-allow-probe", "version": 1,
  "permissions": { "allow": [ { "rule": "Bash(zz-allow-probe *)", "optIn": true } ] } }
JSON
  run bash "$S" --old-client-only --old-client-fixture "$FIX"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP  old client requirement zz-allow-probe: permissions.allow: Bash(zz-allow-probe *) — inactive (expected"* ]]
  [[ "$output" != *"PASS  old client requirement zz-allow-probe"* ]]
  [[ "$output" != *"FAIL  old client requirement zz-allow-probe"* ]]
  ! grep -q 'zz-allow-probe' "$FIX/.claude/settings.json"
}

@test "without the doctor in the package the direct check runs, says so, and still asserts" {
  rm "$PKG/scripts/settings-doctor.sh"
  run bash "$S" --old-client-only --old-client-fixture "$FIX"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP  old client: settings-doctor.sh — not shipped"* ]]
  [[ "$output" == *"PASS  old client requirement workflow-recorder: hooks.UserPromptSubmit[0] — active (direct)"* ]]
}

@test "existing exit codes are unchanged and the new flags are validated" {
  run bash "$S" --st-test "$BATS_TEST_TMPDIR/none"
  [ "$status" -eq 3 ]
  run bash "$S" --old-client-fixture "$FIX"
  [ "$status" -eq 2 ]
  run bash "$S" --bogus
  [ "$status" -eq 2 ]
  run bash "$S" --old-client-only --old-client-fixture "$BATS_TEST_TMPDIR/not-a-fixture"
  [ "$status" -eq 2 ]
}

# ---- E100_S06_T04: the level switch and the client's own entries --------------------------------------------

@test "after the switch every requirement active after the sync is still active, one line each" {
  run bash "$S" --old-client-only --old-client-fixture "$FIX"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS  old client: permission level switch to 3 (from 0)"* ]]
  [[ "$output" == *"PASS  old client requirement after switch workflow-recorder: hooks.UserPromptSubmit[0] — still active"* ]]
  [[ "$output" == *"PASS  old client after switch: j.workflow-recorder UserPromptSubmit hook in .claude/settings.json"* ]]
  [[ "$output" == *"PASS  old client after switch: j.workflow-recorder UserPromptSubmit hook in .agents/settings.json"* ]]
  want="$(printf '%s\n' "$output" | grep -c '^PASS  old client requirement workflow-recorder\|^PASS  old client requirement [a-z-]*: ')"
  have="$(printf '%s\n' "$output" | grep -c '^PASS  old client requirement after switch ')"
  [ "$have" -ge 1 ]
  [ "$have" -le "$want" ]
}

@test "the client's own hook, allow rule and env key are unchanged in both files after the sync and after the switch" {
  run bash "$S" --old-client-only --old-client-fixture "$FIX"
  [ "$status" -eq 0 ]
  for phase in "after sync" "after switch"; do
    for f in .claude/settings.json .agents/settings.json; do
      [[ "$output" == *"PASS  old client own entry hooks.UserPromptSubmit in $f ($phase)"* ]]
      [[ "$output" == *"PASS  old client own entry permissions.allow in $f ($phase)"* ]]
      [[ "$output" == *"PASS  old client own entry env.CLIENT_OWN_FLAG in $f ($phase)"* ]]
    done
  done
  # the real switch changed level policy only
  [ "$(jq -r '.env.CLIENT_OWN_FLAG' "$FIX/.claude/settings.json")" = "keep-me" ]
  [ "$(jq -r '.session_level' "$FIX/.jenga-permission-level.json")" = "3" ]
}

@test "keys the switch owns are asserted after the sync only, and the script says why" {
  run bash "$S" --old-client-only --old-client-fixture "$FIX"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS  old client own entry defaultMode in .claude/settings.json (after sync)"* ]]
  [[ "$output" == *"PASS  old client own entry permissions.deny in .agents/settings.json (after sync)"* ]]
  [[ "$output" == *"SKIP  old client own entry defaultMode (after switch) — owned by the permission-level switch (client-settings-requirements.md section 1)"* ]]
  [[ "$output" == *"SKIP  old client own entry permissions.deny (after switch) — owned by the permission-level switch"* ]]
  if printf '%s\n' "$output" | grep -qE '^(PASS|FAIL)  old client own entry (defaultMode|permissions\.deny|permissions\.ask|autoMode) in .*\(after switch\)'; then false; fi
  grep -q 'client-settings-requirements.md' "$S"
}

@test "an own entry removed by the switch is a FAIL naming the file, the key path and what differed" {
  cat > "$PKG/scripts/jenga-permission-level-switch.sh" <<'SH'
#!/usr/bin/env bash
printf '{"session_level": %s}\n' "$1" > .jenga-permission-level.json
jq 'del(.env.CLIENT_OWN_FLAG)' .claude/settings.json > .t && mv .t .claude/settings.json
SH
  run bash "$S" --old-client-only --old-client-fixture "$FIX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  old client own entry env.CLIENT_OWN_FLAG in .claude/settings.json (after switch)"* ]]
  [[ "$output" == *".claude/settings.json: env.CLIENT_OWN_FLAG differs: expected \"keep-me\" to be kept, found null"* ]]
  [[ "$output" == *"PASS  old client own entry env.CLIENT_OWN_FLAG in .agents/settings.json (after switch)"* ]]
  [[ "$output" == *"PASS  old client own entry env.CLIENT_OWN_FLAG in .claude/settings.json (after sync)"* ]]
}

@test "a requirement lost by the switch is a FAIL naming it" {
  cat > "$PKG/scripts/jenga-permission-level-switch.sh" <<'SH'
#!/usr/bin/env bash
printf '{"session_level": %s}\n' "$1" > .jenga-permission-level.json
for f in .claude/settings.json .agents/settings.json; do
  jq '.hooks.UserPromptSubmit |= map(select((tostring | contains("on_recording_step")) | not))' "$f" > .t && mv .t "$f"
done
SH
  run bash "$S" --old-client-only --old-client-fixture "$FIX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  old client requirement after switch workflow-recorder: hooks.UserPromptSubmit[0]"* ]]
  [[ "$output" == *"FAIL  old client after switch: j.workflow-recorder UserPromptSubmit hook in .agents/settings.json"* ]]
  [[ "$output" == *"PASS  old client own entry hooks.UserPromptSubmit in .claude/settings.json (after switch)"* ]]
}

@test "a switch script that fails is a FAIL line, exit 1" {
  printf '#!/usr/bin/env bash\nexit 4\n' > "$PKG/scripts/jenga-permission-level-switch.sh"
  run bash "$S" --old-client-only --old-client-fixture "$FIX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  old client: permission level switch to 3 (from 0) — exit 4"* ]]
}
