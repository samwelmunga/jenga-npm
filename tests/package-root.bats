#!/usr/bin/env bats
#
# E98_S01: skills/index/scripts/package-root.sh - the shared resolver a mirrored skill script uses to find the
# package (scripts/, templates/, lib/). In a consumer, `.claude/skills/<skill>/scripts/../../..` is `.claude/`, which
# has none of them; the package is node_modules/@jenga-ai/agent. Also pins the 5.0.1 regression end to end: the
# wizard scripts that crashed there must work from the mirrored layout.

bats_require_minimum_version 1.5.0

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  RESOLVER="$REPO/skills/index/scripts/package-root.sh"
  # a bare consumer: the package is in node_modules, the mirror has only skills/ (copied from the repo)
  C="$BATS_TEST_TMPDIR/consumer"
  PKG="$C/node_modules/@jenga-ai/agent"
  mkdir -p "$PKG/scripts" "$PKG/templates" "$C/.claude/skills/j-x/scripts/lib" "$C/.claude/skills/index"
  : > "$PKG/scripts/resolve-root.sh"
  cp -R "$REPO/skills/index/." "$C/.claude/skills/index/"
  C="$(cd "$C" && pwd -P)"; PKG="$C/node_modules/@jenga-ai/agent"
  unset CLAUDE_PROJECT_DIR JENGA_PROJECT_ROOT
}

@test "monorepo layout: a script under skills/<skill>/scripts resolves to the repo root" {
  run bash "$RESOLVER" "$REPO/skills/j-conventions/scripts"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO" ]
}

@test "consumer mirror layout: .claude/skills/<skill>/scripts resolves to node_modules/@jenga-ai/agent" {
  run bash "$RESOLVER" "$C/.claude/skills/j-x/scripts"
  [ "$status" -eq 0 ]
  [ "$output" = "$PKG" ]
}

@test "a script nested deeper (scripts/lib) resolves like one in scripts/" {
  run bash "$RESOLVER" "$C/.claude/skills/j-x/scripts/lib"
  [ "$status" -eq 0 ]
  [ "$output" = "$PKG" ]
}

@test "the cwd is enough when the script directory gives no hint, and CLAUDE_PROJECT_DIR beats it" {
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere/skills/j-y/scripts"
  cd "$C"
  run bash "$RESOLVER" "$BATS_TEST_TMPDIR/elsewhere/skills/j-y/scripts"
  [ "$status" -eq 0 ]
  [ "$output" = "$PKG" ]
  cd "$BATS_TEST_TMPDIR"
  CLAUDE_PROJECT_DIR="$C" run bash "$RESOLVER" "$BATS_TEST_TMPDIR/elsewhere/skills/j-y/scripts"
  [ "$status" -eq 0 ]
  [ "$output" = "$PKG" ]
}

@test "nothing qualifies: prints the old three-levels-up candidate on stdout, one message on stderr, and returns 1" {
  mkdir -p "$BATS_TEST_TMPDIR/bare/skills/j-z/scripts"
  cd "$BATS_TEST_TMPDIR/bare"
  run --separate-stderr bash "$RESOLVER" "$BATS_TEST_TMPDIR/bare/skills/j-z/scripts"
  [ "$status" -eq 1 ]
  [ "$output" = "$(cd "$BATS_TEST_TMPDIR/bare" && pwd -P)" ]
  [ "${#lines[@]}" -eq 1 ]
  # one line, and it says what was missing and what to do about it
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ]
  [[ "$stderr" == *"no Jenga package found for"* ]]
  [[ "$stderr" == *"scripts/resolve-root.sh and templates/"* ]]
  [[ "$stderr" == *"node_modules/@jenga-ai/agent"* ]]
  [[ "$stderr" == *"is @jenga-ai/agent installed?"* ]]
}

@test "a caller that ignores the status (|| true) still gets the stdout path and sees the message on stderr" {
  mkdir -p "$BATS_TEST_TMPDIR/bare/skills/j-z/scripts"
  cd "$BATS_TEST_TMPDIR/bare"
  run --separate-stderr bash -c '. "$1"; r="$(jenga_package_root "$2")" || true; printf "root=%s\n" "$r"' _ "$RESOLVER" "$BATS_TEST_TMPDIR/bare/skills/j-z/scripts"
  [ "$status" -eq 0 ]
  [ "$output" = "root=$(cd "$BATS_TEST_TMPDIR/bare" && pwd -P)" ]
  [[ "$stderr" == *"no Jenga package found for"* ]]
}

@test "success is silent on stderr: a qualifying package prints no message" {
  run --separate-stderr bash "$RESOLVER" "$C/.claude/skills/j-x/scripts"
  [ "$status" -eq 0 ]
  [ "$output" = "$PKG" ]
  [ -z "$stderr" ]
}

@test "decoy: a node_modules/@jenga-ai/agent without templates/ is not chosen" {
  D="$BATS_TEST_TMPDIR/decoy"
  mkdir -p "$D/node_modules/@jenga-ai/agent/scripts" "$D/.claude/skills/j-x/scripts"
  : > "$D/node_modules/@jenga-ai/agent/scripts/resolve-root.sh"      # scripts/resolve-root.sh but NO templates/
  D="$(cd "$D" && pwd -P)"
  cd "$D"
  run --separate-stderr bash "$RESOLVER" "$D/.claude/skills/j-x/scripts"
  [ "$status" -eq 1 ]
  [ "$output" != "$D/node_modules/@jenga-ai/agent" ]
  [[ "$stderr" == *"no Jenga package found for"* ]]
}

@test "decoy: a node_modules/@jenga-ai/agent without scripts/resolve-root.sh is not chosen" {
  D="$BATS_TEST_TMPDIR/decoy2"
  mkdir -p "$D/node_modules/@jenga-ai/agent/templates" "$D/.claude/skills/j-x/scripts"   # templates/ but NO resolve-root.sh
  D="$(cd "$D" && pwd -P)"
  cd "$D"
  run --separate-stderr bash "$RESOLVER" "$D/.claude/skills/j-x/scripts"
  [ "$status" -eq 1 ]
  [ "$output" != "$D/node_modules/@jenga-ai/agent" ]
}

@test "decoy beside a valid package: the half-installed copy nearer the script loses to the valid one further up" {
  # <C>/node_modules/@jenga-ai/agent is valid (from setup); a decoy sits in a nested project that is closer to the script
  N="$C/packages/web"
  mkdir -p "$N/node_modules/@jenga-ai/agent/scripts" "$N/.claude/skills/j-x/scripts"
  : > "$N/node_modules/@jenga-ai/agent/scripts/resolve-root.sh"      # no templates/
  cd "$N"
  run --separate-stderr bash "$RESOLVER" "$N/.claude/skills/j-x/scripts"
  [ "$status" -eq 0 ]
  [ "$output" = "$PKG" ]
  [ -z "$stderr" ]
}

@test "sourcing defines the function and prints nothing" {
  run bash -c '. "$1" && declare -F jenga_package_root' _ "$RESOLVER"
  [ "$status" -eq 0 ]
  [ "$output" = "jenga_package_root" ]
}

@test "5.0.1 regression: wizard scripts run from the mirrored layout find the package" {
  command -v rsync >/dev/null || skip "rsync not installed"
  F="$(bash "$REPO/scripts/consumer-layout-fixture.sh" "$BATS_TEST_TMPDIR/fx")"
  cd "$F"
  run bash .claude/skills/j-conventions/scripts/conventions-entry.sh categories
  [ "$status" -eq 0 ]
  [[ "$output" != *"/.claude/templates/"* ]]
  run bash .claude/skills/j-tidy/scripts/report.sh
  [[ "$output" != *"cannot find an executable scripts/check-worktree-liveness.sh"* ]]
  [[ "$output" != *"/.claude/scripts/"* ]]
  run bash .claude/skills/j-tools/scripts/tools-entry.sh show --layer project
  [[ "$output" != *"/.claude/scripts/"* ]]
}

# ---------------------------------------------------------------------------------------------------------------------
# E98_S01_T03: scripts the audit found failing in the consumer layout. Each case runs the MIRRORED copy
# (`.claude/skills/...`) of a script that used to look for a package asset three directories up or beside the cwd.

# consumer_fixture <dir> [<subdir>]: a consumer at <dir>[/<subdir>]; with a subdir the git repository is ABOVE the
# project (a monorepo-style checkout), so `git rev-parse --show-toplevel` is not the directory holding node_modules.
consumer_fixture() {
  local top="$1" sub="${2:-}" proj
  mkdir -p "$top"
  if [ -n "$sub" ]; then proj="$top/$sub"; git -C "$top" init -q; else proj="$top"; fi
  bash "$REPO/scripts/consumer-layout-fixture.sh" "$proj" >/dev/null
  [ -z "$sub" ] || rm -rf "$proj/.git"
  proj="$(cd "$proj" && pwd -P)"
  mkdir -p "$proj/project/board/tasks" "$proj/src/deep"
  printf -- '---\nid: E1_S01_T01\ntitle: a thing\nstatus: Passed\ndate_completed: 2026-11-01\n---\n' > "$proj/project/board/tasks/E1_S01_T01_x.md"
  printf '{"name":"consumer","version":"1.0.0","private":true}\n' > "$proj/package.json"
  # run_gates.sh audits the git toplevel (its project-root convention), which in the nested layout is $top
  [ -z "$sub" ] || cp "$proj/package.json" "$top/package.json"
  printf '{"targets":{"t":{"type":"npm","checks":{"pre":[]}}}}\n' > "$proj/project/configs/publish.json"
  git -C "$proj" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  CONSUMER="$proj"
}

@test "audit: index/board-index runs from the mirror (board_index.py found the shared board_ids module)" {
  command -v rsync >/dev/null || skip "rsync not installed"
  consumer_fixture "$BATS_TEST_TMPDIR/ix"
  cd "$CONSUMER/src/deep"
  run --separate-stderr bash "$CONSUMER/.claude/skills/index/scripts/board-index" graph::nodes
  [ "$status" -eq 0 ]
  [[ "$output" == "["* ]]
  [[ "$stderr" != *"Traceback"* ]]
}

@test "audit: board_index.py without any package says what is missing instead of a traceback" {
  mkdir -p "$BATS_TEST_TMPDIR/lonely/.claude/skills/index/scripts"
  cp "$REPO/skills/index/scripts/board_index.py" "$BATS_TEST_TMPDIR/lonely/.claude/skills/index/scripts/"
  cd "$BATS_TEST_TMPDIR/lonely"
  run --separate-stderr python3 .claude/skills/index/scripts/board_index.py graph::nodes
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"board_ids.py not found"* ]]
  [[ "$stderr" != *"Traceback"* ]]
}

@test "audit: generate_release_notes.sh in a consumer finds board-ids.sh and the changelog template" {
  command -v rsync >/dev/null || skip "rsync not installed"
  consumer_fixture "$BATS_TEST_TMPDIR/rn"
  cd "$CONSUMER/src/deep"
  run --separate-stderr bash "$CONSUMER/.claude/skills/j-publish/scripts/generate_release_notes.sh" --output "$BATS_TEST_TMPDIR/notes.md" "$CONSUMER/project/configs/publish.json"
  [ "$status" -eq 0 ]
  grep -q -- '- E1_S01_T01 — a thing' "$BATS_TEST_TMPDIR/notes.md"
  run --separate-stderr bash "$CONSUMER/.claude/skills/j-publish/scripts/generate_release_notes.sh" "$CONSUMER/project/configs/publish.json"
  [ "$status" -eq 0 ]
  [ -f "$CONSUMER/CHANGELOG.md" ]
  grep -q '## \[Unreleased\]' "$CONSUMER/CHANGELOG.md"
  grep -q 'E1_S01_T01' "$CONSUMER/CHANGELOG.md"
}

@test "audit: run_gates.sh finds audit-deps.sh in a consumer, also when the git root is above the project" {
  command -v rsync >/dev/null || skip "rsync not installed"
  unset CI GITHUB_ACTIONS
  local layout
  for layout in flat nested; do
    if [ "$layout" = nested ]; then consumer_fixture "$BATS_TEST_TMPDIR/rg-$layout" app; else consumer_fixture "$BATS_TEST_TMPDIR/rg-$layout"; fi
    cd "$CONSUMER/src/deep"
    run --separate-stderr bash "$CONSUMER/.claude/skills/j-publish/scripts/run_gates.sh" pre t "$CONSUMER/project/configs/publish.json" --non-interactive
    [ "$status" -eq 0 ]
    [[ "$output" != *"audit-deps.sh not found"* ]]
    [[ "$output" == *"audit:skipped (no consent)"* ]]
  done
}

@test "audit: audit_notice_hook.sh finds audit-notice.sh in a consumer, also when the git root is above the project" {
  command -v rsync >/dev/null || skip "rsync not installed"
  unset JENGA_PROJECT_ROOT
  local layout
  for layout in flat nested; do
    if [ "$layout" = nested ]; then consumer_fixture "$BATS_TEST_TMPDIR/an-$layout" app; else consumer_fixture "$BATS_TEST_TMPDIR/an-$layout"; fi
    cd "$CONSUMER/src/deep"
    run --separate-stderr bash "$CONSUMER/.claude/skills/j-publish/scripts/audit_notice_hook.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Dependency audits are not running yet"* ]]
  done
}

@test "audit: persist-task-usage.sh and write-story-usage.sh measure from a subdirectory of the project, not only its root" {
  command -v rsync >/dev/null || skip "rsync not installed"
  consumer_fixture "$BATS_TEST_TMPDIR/tu"
  cd "$CONSUMER/src/deep"
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  run --separate-stderr bash "$CONSUMER/.claude/skills/j-close-story/scripts/persist-task-usage.sh" E1_S01
  [ "$status" -eq 0 ]
  [[ "$output" == "Usage"* ]]
  run --separate-stderr bash "$CONSUMER/.claude/skills/j-close-story/scripts/write-story-usage.sh" E1_S01
  [ "$status" -eq 0 ]
  [[ "$output" == "Story usage"* ]]
}
