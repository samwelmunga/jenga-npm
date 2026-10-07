#!/usr/bin/env bats
#
# E34_S06_T03: scripts/strategy_path_resolver.sh is the single source /init and /strategy both
# use for where STRATEGY.md lives. Every test runs in a throwaway $BATS_TEST_TMPDIR project.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RESOLVER="$REPO_ROOT/scripts/strategy_path_resolver.sh"

setup() {
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/project/configs" "$PROJ/docs"
}

write_config() {
  printf '%s\n' "$1" > "$PROJ/project/configs/workflow.json"
}

resolve() {
  cd "$PROJ" || return 1
  bash "$RESOLVER"
}

@test "no workflow.json: defaults to project/documentation/STRATEGY.md" {
  run resolve
  [ "$status" -eq 0 ]
  [ "$output" = "project/documentation/STRATEGY.md" ]
}

@test "workflow.json without paths.strategy: defaults to project/documentation/STRATEGY.md" {
  write_config '{"paths": {"board": "project/board"}}'
  run resolve
  [ "$status" -eq 0 ]
  [ "$output" = "project/documentation/STRATEGY.md" ]
}

@test "default config, no file at the new path, existing legacy docs/STRATEGY.md: resolves to the legacy file" {
  write_config '{"paths": {"board": "project/board"}}'
  echo old > "$PROJ/docs/STRATEGY.md"
  run resolve
  [ "$status" -eq 0 ]
  [ "$output" = "docs/STRATEGY.md" ]
}

@test "no workflow.json, existing legacy docs/STRATEGY.md: resolves to the legacy file" {
  rm -rf "$PROJ/project"
  echo old > "$PROJ/docs/STRATEGY.md"
  run resolve
  [ "$status" -eq 0 ]
  [ "$output" = "docs/STRATEGY.md" ]
}

@test "default config with files at both locations: the new path wins" {
  write_config '{"paths": {"board": "project/board"}}'
  mkdir -p "$PROJ/project/documentation"
  echo new > "$PROJ/project/documentation/STRATEGY.md"
  echo old > "$PROJ/docs/STRATEGY.md"
  run resolve
  [ "$status" -eq 0 ]
  [ "$output" = "project/documentation/STRATEGY.md" ]
}

@test "the resolver creates, moves, copies and deletes nothing (directory listing and content unchanged)" {
  write_config '{"paths": {"board": "project/board"}}'
  echo old > "$PROJ/docs/STRATEGY.md"
  local before after sum_before sum_after
  before=$(cd "$PROJ" && find . | sort)
  sum_before=$(cd "$PROJ" && find . -type f -exec cksum {} + | sort)
  run resolve
  [ "$status" -eq 0 ]
  after=$(cd "$PROJ" && find . | sort)
  sum_after=$(cd "$PROJ" && find . -type f -exec cksum {} + | sort)
  [ "$before" = "$after" ]
  [ "$sum_before" = "$sum_after" ]
}

@test "legacy docs/STRATEGY.md is kept as the documented intentional fallback literal" {
  run grep -n '^LEGACY="docs/STRATEGY.md"' "$RESOLVER"
  [ "$status" -eq 0 ]
  run grep -c 'Deliberate legacy fallback' "$RESOLVER"
  [ "$output" -ge 1 ]
}

@test "paths.strategy is honoured when no file exists yet (where a new file is created)" {
  write_config '{"paths": {"strategy": "project/documentation/STRATEGY.md"}}'
  run resolve
  [ "$status" -eq 0 ]
  [ "$output" = "project/documentation/STRATEGY.md" ]
}

@test "existing file at the configured path wins over the legacy docs/STRATEGY.md" {
  write_config '{"paths": {"strategy": "project/documentation/STRATEGY.md"}}'
  mkdir -p "$PROJ/project/documentation"
  echo new > "$PROJ/project/documentation/STRATEGY.md"
  echo old > "$PROJ/docs/STRATEGY.md"
  run resolve
  [ "$status" -eq 0 ]
  [ "$output" = "project/documentation/STRATEGY.md" ]
}

@test "existing project: legacy docs/STRATEGY.md is found, not duplicated, when paths.strategy points elsewhere" {
  write_config '{"paths": {"strategy": "project/documentation/STRATEGY.md"}}'
  echo old > "$PROJ/docs/STRATEGY.md"
  run resolve
  [ "$status" -eq 0 ]
  [ "$output" = "docs/STRATEGY.md" ]
}

@test "existing docs/STRATEGY.md with the default config resolves to that same file" {
  write_config '{"paths": {"strategy": "docs/STRATEGY.md"}}'
  echo old > "$PROJ/docs/STRATEGY.md"
  run resolve
  [ "$status" -eq 0 ]
  [ "$output" = "docs/STRATEGY.md" ]
}

@test "malformed workflow.json fails loudly instead of guessing a path" {
  write_config 'not json'
  run resolve
  [ "$status" -ne 0 ]
}

@test "the workflow.json templates /init scaffolds and this repo ships both declare paths.strategy" {
  run jq -r '.paths.strategy' "$REPO_ROOT/skills/j-init/assets/workflow_template.json"
  [ "$status" -eq 0 ]
  [ "$output" = "project/documentation/STRATEGY.md" ]
  run jq -r '.paths.strategy' "$REPO_ROOT/project/configs/workflow.json"
  [ "$status" -eq 0 ]
  [ "$output" = "project/documentation/STRATEGY.md" ]
}

@test "/init resolves the strategy path through the resolver and does not hardcode the literal path" {
  run grep -c 'strategy_path_resolver.sh' "$REPO_ROOT/skills/j-init/scripts/init.sh"
  [ "$output" -ge 1 ]
  run grep -E '^[^#]*cp .*docs/STRATEGY\.md' "$REPO_ROOT/skills/j-init/scripts/init.sh"
  [ "$status" -ne 0 ]
}

# skills/j-strategy/ is fully private (blocklisted in .publicignore), so this file does not exist in
# the public mirror. Visible skip rather than fail: option 2 of
# project/documentation/public-mirror-content-parity.md, keeping the cases above public.
@test "/strategy resolves the strategy path through the resolver instead of hardcoding it" {
  if [ ! -f "$REPO_ROOT/skills/j-strategy/SKILL.md" ]; then
    skip "SKIPPED (no coverage): skills/j-strategy/SKILL.md is private and absent from the public mirror"
  fi
  run grep -c 'strategy_path_resolver.sh' "$REPO_ROOT/skills/j-strategy/SKILL.md"
  [ "$output" -ge 1 ]
}

# --- E34_S01_T05: the resolver now delegates to scripts/resolve-root.sh -------------------------

@test "resolves correctly from a nested subdirectory of the project" {
  write_config '{"paths": {"strategy": "project/documentation/STRATEGY.md"}}'
  mkdir -p "$PROJ/project/documentation" "$PROJ/sub/deep"
  echo new > "$PROJ/project/documentation/STRATEGY.md"
  cd "$PROJ/sub/deep"
  run bash "$RESOLVER"
  [ "$status" -eq 0 ]
  [ "$output" = "project/documentation/STRATEGY.md" ]
  # Legacy fallback also checks the anchor, not the nested working directory.
  echo old > "$PROJ/docs/STRATEGY.md"
  write_config '{"paths": {"strategy": "project/elsewhere/STRATEGY.md"}}'
  run bash "$RESOLVER"
  [ "$status" -eq 0 ]
  [ "$output" = "docs/STRATEGY.md" ]
}

@test "resolves against a relocated .project/ registry with no project/ directory" {
  local rel="$BATS_TEST_TMPDIR/relocated"
  mkdir -p "$rel/.project/configs" "$rel/.project/documentation" "$rel/sub"
  printf '%s\n' '{"paths": {"strategy": ".project/documentation/STRATEGY.md"}}' > "$rel/.project/configs/workflow.json"
  cd "$rel/sub"
  run bash "$RESOLVER"
  [ "$status" -eq 0 ]
  [ "$output" = ".project/documentation/STRATEGY.md" ]
  [ ! -e "$rel/project" ]
}

@test "finds its sibling resolve-root.sh from the script's own directory, not the working directory or repo" {
  local copied="$BATS_TEST_TMPDIR/pkg/scripts"
  mkdir -p "$copied"
  cp "$REPO_ROOT/scripts/strategy_path_resolver.sh" "$REPO_ROOT/scripts/resolve-root.sh" "$copied/"
  write_config '{"paths": {"strategy": "project/documentation/STRATEGY.md"}}'
  cd "$PROJ"
  run bash "$copied/strategy_path_resolver.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "project/documentation/STRATEGY.md" ]
}

@test "the resolver keeps no second registry parser: no jq call, grep/sed JSON parsing, or hardcoded registry path" {
  run grep -E 'jq|grep -o|project/configs' "$RESOLVER"
  [ "$status" -ne 0 ]
  run grep -c 'resolve-root.sh' "$RESOLVER"
  [ "$output" -ge 1 ]
}
