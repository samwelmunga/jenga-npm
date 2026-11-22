#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# lib/inject-settings.js (E89_S06_T13). Direction chosen: RETIRE, not carry. E89_S06_T07 retired the
# prompt_router hook and stopped `jenga init` registering it, so the injector must not write a
# UserPromptSubmit prompt_router entry into any settings.json, and no permission-level template may
# carry one (a template carrying it would re-register the retired hook on every level switch).

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

@test "injectSettings writes no settings file and registers no prompt_router hook" {
  proj="$BATS_TEST_TMPDIR/proj"; mkdir -p "$proj"
  run node --input-type=module -e "
    import { injectSettings } from '$REPO_ROOT/lib/inject-settings.js';
    await injectSettings('$proj', false);"
  [ "$status" -eq 0 ]
  [ ! -e "$proj/.claude/settings.json" ]
}

@test "injectSettings leaves an existing settings.json byte-identical" {
  proj="$BATS_TEST_TMPDIR/proj"; mkdir -p "$proj/.claude"
  printf '{"hooks":{}}\n' > "$proj/.claude/settings.json"
  before="$(cat "$proj/.claude/settings.json")"
  run node --input-type=module -e "
    import { injectSettings } from '$REPO_ROOT/lib/inject-settings.js';
    await injectSettings('$proj', false);"
  [ "$status" -eq 0 ]
  [ "$(cat "$proj/.claude/settings.json")" = "$before" ]
}

@test "jenga init does not import or call the injector" {
  ! grep -Eq 'inject-settings|injectSettings\(' "$REPO_ROOT/lib/commands/init.js" || \
    ! grep -E 'inject-settings|injectSettings\(' "$REPO_ROOT/lib/commands/init.js" | grep -v '^ *//' | grep -q .
}

@test "no permission-level template, root settings.json or hook fragment registers prompt_router" {
  # E100_S04_T05: the registration now lives in root settings.json and the fragments; the templates are still scanned.
  for f in "$REPO_ROOT"/templates/permission-levels/level-*.json "$REPO_ROOT/settings.json" \
    "$REPO_ROOT"/hooks/*.fragment.json "$REPO_ROOT/skills/j-workflow-recorder/settings-fragment.json"; do
    run grep -c 'prompt_router' "$f"
    [ "$output" = "0" ] || { echo "$f"; return 1; }
  done
}
