#!/usr/bin/env bats
# bats file_tags=tier:fast
#
# E100_S03_T02: the shipped hook fragments under hooks/*.fragment.json equal the entries of root settings.json
# (after JSON normalisation), validate in one run together with the recorder fragment, have unique ids, and the
# guarded permission-level template carries no hooks (E100_S04_T05).

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
VALIDATOR="$REPO_ROOT/scripts/validate-settings-fragment.sh"
GUARDED="$REPO_ROOT/templates/permission-levels/level-2-guarded.json"

fragments() {
  printf '%s\n' "$REPO_ROOT"/hooks/on_preflight_check.fragment.json "$REPO_ROOT"/hooks/on_session_end.fragment.json \
    "$REPO_ROOT"/hooks/worktree.fragment.json "$REPO_ROOT"/skills/j-workflow-recorder/settings-fragment.json
}

@test "the validator accepts all four shipped fragments in one run" {
  run -0 bash "$VALIDATOR" $(fragments)
}

@test "the four fragment ids are unique" {
  run -0 bash -c "cd '$REPO_ROOT' && jq -r .id $(fragments | tr '\n' ' ') | sort | uniq -d"
  [ -z "$output" ]
}

@test "each hook event entry equals the root settings.json entry, and the guarded template carries no hooks" {
  for ev in PreToolUse SessionEnd WorktreeCreate WorktreeRemove; do
    frag="$(jq -S -c --arg e "$ev" '.hooks[$e] // empty' "$REPO_ROOT"/hooks/*.fragment.json)"
    root="$(jq -S -c --arg e "$ev" '.hooks[$e]' "$REPO_ROOT/settings.json")"
    [ -n "$frag" ]
    [ "$(printf '%s\n' "$frag" | wc -l | tr -d ' ')" = 1 ]
    [ "$frag" = "$root" ]
  done
  [ "$(jq 'has("hooks")' "$GUARDED")" = "false" ]
}

@test "hooks/ ships in the package files list" {
  run -0 jq -e '.files | index("hooks/")' "$REPO_ROOT/package.json"
}
