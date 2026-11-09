#!/usr/bin/env bats
#
# E76_S02_T02: smoke test that scripts/task-usage.sh --check-layout detects transcript layout drift.
#
# Part 1 (always runs): copy the frozen fixtures to a temp dir, check the intact copy passes, then break the copy one
# way at a time and assert the documented exit code (4 root/slug missing, 5 no subagent transcripts, 6 sidecar meta
# missing/unparseable/incomplete, 7 usage missing/incomplete), a stderr message naming the problem, and that no result
# object with zero sums is printed. tests/fixtures/task-usage/ itself is never modified (teardown checks it).
#
# Part 2 (runs when it can): run --check-layout against a handful of the most recent real subagent transcripts of this
# repository, selected read-only and exposed through a temp directory of symlinks. This is the part that notices when
# Claude Code has changed its format after the fixtures were frozen. With no real transcripts it skips, loudly.
# Nothing from a real transcript is copied into the repository or printed.
#
# E76 ships publicly (decided 2026-11-07), so this file ships and must not depend on anything private.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/task-usage.sh"
FIX="$REPO_ROOT/tests/fixtures/task-usage"

# the fixture project (README: --project-dir /fixture/proj yields the slug directory below)
PROJ="/fixture/proj"
SLUG="-fixture-proj"

REAL_SAMPLE_SIZE=8

# fixture_sum: one checksum line per file of the fixture tree, so teardown can prove nothing was touched
fixture_sum() { (cd "$FIX" && find . -type f | LC_ALL=C sort | xargs cksum); }

setup() {
  unset JENGA_PROJECTS_DIR
  FIX_BEFORE="$(fixture_sum)"
  COPY="$BATS_TEST_TMPDIR/fixture-copy"
  PROJECTS="$COPY/projects"
  mkdir -p "$COPY"
  cp -R "$FIX/projects" "$PROJECTS"
  SUBS="$PROJECTS/$SLUG/sess-0001/subagents"
}

teardown() {
  [ "$(fixture_sum)" = "$FIX_BEFORE" ] || { echo "tests/fixtures/task-usage was modified by this test"; return 1; }
}

checklayout() { bash "$SCRIPT" --check-layout --projects-dir "$PROJECTS" --project-dir "$PROJ"; }

# expect_drift <exit code> <stderr fragment>: --check-layout on the mutated copy fails with that code and a message
# containing the fragment, its stdout is a failed verdict holding no result and no sums, and --report on the same tree
# exits with the same code and prints nothing to stdout.
expect_drift() {
  local want="$1" fragment="$2"
  run --separate-stderr checklayout
  [ "$status" -eq "$want" ] || { echo "--check-layout: expected exit $want, got $status; stderr: $stderr"; return 1; }
  [[ "$stderr" == *"$fragment"* ]] || { echo "stderr does not name the problem ('$fragment'): $stderr"; return 1; }
  printf '%s' "$output" | jq -e --argjson want "$want" '.ok == false and .exit_code == $want' >/dev/null
  [ "$(printf '%s' "$output" | jq 'has("tasks") or has("overhead") or has("unmapped")')" = "false" ]
  [ "$(printf '%s' "$output" | jq '[.. | objects | keys[] | select(test("^(input|output|cache_write|cache_read|usage_total_tokens)$"))] | length')" = "0" ]
  run --separate-stderr bash "$SCRIPT" --report --projects-dir "$PROJECTS" --project-dir "$PROJ"
  [ "$status" -eq "$want" ] || { echo "--report: expected exit $want, got $status"; return 1; }
  [ -z "$output" ] || { echo "--report printed on stdout despite the failure: $output"; return 1; }
}

# ---------------------------------------------------------------------------------------------------------------
# Part 1 - frozen fixture sample
# ---------------------------------------------------------------------------------------------------------------

@test "part 1: the intact copy of the fixtures passes --check-layout" {
  run --separate-stderr checklayout
  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; return 1; }
  printf '%s' "$output" | jq -e '.ok == true and .exit_code == 0 and .transcripts > 0 and ([.checks[].status] == ["ok","ok","ok","ok"])' >/dev/null
  [[ "$stderr" == *"layout check passed"* ]]
}

@test "part 1: subagents/ renamed to agents/ exits 5 (no subagent transcripts)" {
  local d
  for d in "$PROJECTS"/*/*/subagents; do mv "$d" "$(dirname "$d")/agents"; done
  [ ! -d "$SUBS" ]
  [ -d "$PROJECTS/$SLUG/sess-0001/agents" ]
  expect_drift 5 "no subagents/ directory"
}

@test "part 1: one deleted .meta.json exits 6 and names the missing sidecar" {
  rm "$SUBS/agent-a0001.meta.json"
  expect_drift 6 "agent-a0001.meta.json"
  [[ "$stderr" == *"no sibling .meta.json"* ]]
}

@test "part 1: one corrupted .meta.json exits 6 and says it is not parseable" {
  printf '%s\n' 'this is { not json' > "$SUBS/agent-a0001.meta.json"
  expect_drift 6 "agent-a0001.meta.json"
  [[ "$stderr" == *"not parseable"* ]]
}

@test "part 1: the usage objects removed from a transcript exit 7 and name the transcript" {
  local f="$SUBS/agent-a0001.jsonl"
  jq -c 'del(.message.usage)' "$f" > "$f.new" && mv "$f.new" "$f"
  expect_drift 7 "agent-a0001.jsonl"
  [[ "$stderr" == *"none carries a message.usage object"* ]]
}

@test "part 1: one usage field removed (cache_read_input_tokens) exits 7 and names the field" {
  local f="$SUBS/agent-a0001.jsonl"
  jq -c 'del(.message.usage.cache_read_input_tokens)' "$f" > "$f.new" && mv "$f.new" "$f"
  expect_drift 7 "cache_read_input_tokens"
}

@test "part 1: the whole project slug directory deleted exits 4 and names the slug" {
  # the project's slug directory AND its "<slug>--claude-worktrees-*" siblings: the script counts a worktree sibling as
  # the project's own slug directory (task-usage.sh tu_check_1_2), so it would stand in for the deleted main one
  rm -rf "$PROJECTS/$SLUG" "$PROJECTS/$SLUG"--claude-worktrees-*
  # the decoy ("<slug>-public", not a worktree sibling) is still there and must not stand in for the project's own
  [ -d "$PROJECTS/$SLUG-public" ]
  expect_drift 4 "no directory for project slug $SLUG"
}

# ---------------------------------------------------------------------------------------------------------------
# Part 2 - a small read-only sample of real transcripts
# ---------------------------------------------------------------------------------------------------------------

# real_main_repo: the main checkout's path (not this worktree's), from which the real transcript slug is derived;
# prints nothing when it cannot be resolved
real_main_repo() {
  local common
  common="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null)" || return 0
  case "$common" in /*) ;; *) common="$REPO_ROOT/$common" ;; esac
  (cd "$common/.." 2>/dev/null && pwd -P)
}

@test "part 2: --check-layout passes on a sample of this machine's real subagent transcripts" {
  local root="${JENGA_PROJECTS_DIR:-$HOME/.claude/projects}" main slug real
  main="$(real_main_repo)"
  [ -n "$main" ] || skip "no real subagent transcripts on this machine"
  slug="$(printf '%s' "$main" | sed 's#[/._ ]#-#g')"
  real="$root/$slug"
  [ -d "$real" ] || skip "no real subagent transcripts on this machine"

  # the most recent subagent transcripts, selected read-only
  local sample
  sample="$(ls -t -- "$real"/*/subagents/agent-*.jsonl 2>/dev/null | head -n "$REAL_SAMPLE_SIZE" || true)"
  [ -n "$sample" ] || skip "no real subagent transcripts on this machine"

  # a temp projects dir of symlinks: same slug and session layout, nothing copied
  local linked="$BATS_TEST_TMPDIR/real-sample" t sess base n=0
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    sess="$(basename "$(dirname "$(dirname "$t")")")"
    base="${t%.jsonl}"
    mkdir -p "$linked/$slug/$sess/subagents"
    ln -s "$t" "$linked/$slug/$sess/subagents/$(basename "$t")"
    [ -f "$base.meta.json" ] && ln -s "$base.meta.json" "$linked/$slug/$sess/subagents/$(basename "$base").meta.json"
    n=$((n + 1))
  done <<< "$sample"
  [ "$n" -ge 1 ]

  run --separate-stderr bash "$SCRIPT" --check-layout --projects-dir "$linked" --project-dir "$main"
  # on failure show only the script's own diagnostic (paths and field names), never transcript content
  [ "$status" -eq 0 ] || { echo "real transcripts failed --check-layout (exit $status); possible Claude Code format drift. stderr: $stderr"; return 1; }
  # it must have examined every transcript of the sample, so a pass is never vacuous
  printf '%s' "$output" | jq -e --argjson n "$n" '.ok == true and .transcripts == $n' >/dev/null \
    || { echo "expected the check to examine exactly $n transcript(s)"; return 1; }
}
