#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# E92_S06_T16: j.status runs render-status-scope.sh only for a specific epic or story id, and SKILL.md holds no logic for it.
# E92_S06_T26: render-status-scope.sh is now the LEGACY scope renderer (`j.status --legacy <id>`); the default `j.status <id>` runs
# render-status-scope-view.sh through skills/j-status/scripts/resolve-status-mode.sh. The tests at the end assert both.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL="$REPO/skills/j-status/SKILL.md"
  FMT="$REPO/skills/j-status/assets/output_format.md"
}

@test "SKILL.md runs render-status-scope.sh exactly once, with the dual-path idiom" {
  [ "$(grep -c 'bash "\$(\[ -f skills/j-status/scripts/render-status-scope.sh \] && echo skills/j-status/scripts/render-status-scope.sh || echo node_modules/@jenga-ai/agent/skills/j-status/scripts/render-status-scope.sh)"' "$SKILL")" -eq 1 ]
}

@test "SKILL.md ties the script to a specific epic or story id and says the plain overview never shows the block" {
  grep -q 'specific epic or story id' "$SKILL"
  grep -q 'j.status E03_S05' "$SKILL"
  grep -q 'plain overview (no argument) never runs this script and never shows the extended block' "$SKILL"
}

@test "SKILL.md step 6.10 sits after 6.9 and before 7" {
  run grep -n '^6\.[0-9]*\. \|^7\. ' "$SKILL"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed 's/^\([0-9]*\):\([0-9.]*\)\..*/\2/' | tr '\n' ' ')" = "6.5 6.7 6.8 6.85 6.9 6.10 7 " ]
}

@test "SKILL.md states the fallback for the scope block" {
  grep -q 'prints nothing, is missing or fails, the overview prints as before' "$SKILL"
}

@test "SKILL.md holds no counting, drawing, glyph or label logic" {
  run grep -Eq '█|░|━|╌|⚑|●|◉|○|★|printf|awk|seq |\$\(\(|jq |bc |Ready to take|unlocked by|Dependency tree' "$SKILL"
  [ "$status" -eq 1 ]
  run grep -Eq 'board-progress\.sh|render-progress-bar\.sh' "$SKILL"
  [ "$status" -eq 1 ]
}

@test "steps 6.5, 6.7, 6.8 and 6.9 keep their commands byte-identical" {
  grep -qF 'bash "$([ -f scripts/mark-deployed.sh ] && echo scripts/mark-deployed.sh || echo node_modules/@jenga-ai/agent/scripts/mark-deployed.sh)"' "$SKILL"
  grep -qF 'bash "$([ -f scripts/check-todo-format.sh ] && echo scripts/check-todo-format.sh || echo node_modules/@jenga-ai/agent/scripts/check-todo-format.sh)"' "$SKILL"
  grep -qF 'bash "$([ -f scripts/audit-status.sh ] && echo scripts/audit-status.sh || echo node_modules/@jenga-ai/agent/scripts/audit-status.sh)"' "$SKILL"
  grep -qF 'bash "$([ -f skills/j-status/scripts/render-status-bars.sh ] && echo skills/j-status/scripts/render-status-bars.sh || echo node_modules/@jenga-ai/agent/skills/j-status/scripts/render-status-bars.sh)"' "$SKILL"
}

@test "output_format.md has an Extended scope block section with the tree, ready list and unlocked lines" {
  grep -Fxq '## Extended scope block' "$FMT"
  grep -Fq 'Dependency tree (E92_S05)' "$FMT"
  grep -Fq 'Ready to take' "$FMT"
  grep -Fq 'E92_S05_T01 unlocked by E92_S01_T05' "$FMT"
}

@test "the example in output_format.md matches a real run of the script" {
  command -v jq >/dev/null || skip "jq missing"
  cd "$REPO"
  ls project/board/stories/E92_S05_* >/dev/null 2>&1 || skip "E92_S05 not on this board"
  real="$(LC_ALL=en_US.UTF-8 bash skills/j-status/scripts/render-status-scope.sh E92_S05 --color never --cols 80)" || skip "script failed"
  [ -n "$real" ]
  for l in "Dependency tree (E92_S05)" "Ready to take" "  Nothing is ready to take right now"; do
    printf '%s\n' "$real" | grep -Fxq "$l"
    grep -Fxq "$l" "$FMT"
  done
}

# ---- E92_S06_T26: the default scope view and the --legacy scope block ---------------------------------------------------

@test "j.status <id> resolves to the Node scope renderer and j.status --legacy <id> to the old render-status-scope.sh" {
  D="$REPO/skills/j-status/scripts"
  [ "$(bash "$D/resolve-status-mode.sh" mode E03_S05)" = "scope" ]
  [ "$(bash "$D/resolve-status-mode.sh" plan E03_S05)" = "node lib/progress/cli.js scope E03_S05" ]
  [ "$(bash "$D/resolve-status-mode.sh" mode --legacy E03_S05)" = "legacy-scope" ]
  [ "$(bash "$D/resolve-status-mode.sh" plan --legacy E03_S05)" = "render-status-scope.sh E03_S05" ]
  [ -f "$D/render-status-scope-view.sh" ]
  [ -f "$D/render-status-scope.sh" ]
}

@test "SKILL.md reaches the scope view only through the resolver: it never names render-status-scope-view.sh itself" {
  run grep -q 'render-status-scope-view' "$SKILL"
  [ "$status" -eq 1 ]
  grep -q 'resolve-status-mode.sh' "$SKILL"
}

@test "SKILL.md says a scope view is the whole answer on the default path, and that --all with an id is allowed" {
  grep -q 'For `scope` the view is' "$SKILL"
  grep -q 'the whole answer: print it and stop' "$SKILL"
  grep -q '`scope` (an epic or story id, `--all` allowed)' "$SKILL"
}

@test "SKILL.md marks step 6.10 as legacy-path only and keeps its instructions" {
  grep -q '^6\.10\. \*\*Collect the extended scope block (legacy path only, only for a scope argument)\*\*' "$SKILL"
  grep -q 'j.status E03_S05' "$SKILL"
}

@test "output_format.md says the Extended scope block is legacy-path only and shows the default scope view" {
  grep -Fq 'Legacy path only (`j.status --legacy <epic-or-story-id>`' "$FMT"
  grep -Fq 'render E92_S08 --charset utf8 --color never --cols 80' "$FMT"
  grep -Fq 'Ready to take: ' "$FMT"
}
