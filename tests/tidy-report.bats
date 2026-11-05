#!/usr/bin/env bats
#
# j.tidy's report-by-default rendering and its config thresholds (E56_S06_T02).
#
# ISOLATION: every case that needs a repository builds its own throwaway one under
# $BATS_TEST_TMPDIR with its own TMPDIR and the global/system git config neutralised. The subject
# of this suite reports; it has no removal path at all, and the "bare invocation mutates nothing"
# case is the standing pin for that.
#
# The threshold cases deliberately prove BEHAVIOUR rather than grep the script for numerals: a
# config with absurd values must change the report, and no resolvable config at all must disable
# the ceiling checks instead of falling back to a built-in number. That is what "read at run time,
# never hardcoded" actually means, and a text grep could not distinguish the two.
#
load helpers/assertions

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
TIDY_DIR="$REPO_ROOT/skills/j-tidy/scripts"
REPORT="$TIDY_DIR/report.sh"
SKILL="$REPO_ROOT/skills/j-tidy/SKILL.md"

setup() {
  BASE="$BATS_TEST_TMPDIR/venue"
  FIX="$BASE/repo"
  WTDIR="$BASE/wt"
  mkdir -p "$BASE/tmp" "$WTDIR"
  export TMPDIR="$BASE/tmp"
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  unset GIT_DIR
  unset GIT_WORK_TREE
  # Pin the thresholds this suite reads, so a later edit to the project's own tidy-config.json
  # cannot flip a case here. Each case that cares writes its own values into this file.
  CFG="$BASE/tidy-config.json"
  export JENGA_TIDY_CONFIG_FILE="$CFG"
  write_config 14 40 80 2048 15
}

# write_config <retention> <wt-ceiling> <br-ceiling> <disk-mb> <max-rows>
write_config() {
  cat > "$CFG" <<EOF
{
  "config_version": 1,
  "retention_age_days": $1,
  "worktree_count_ceiling": $2,
  "branch_count_ceiling": $3,
  "disk_ceiling_mb": $4,
  "report_max_rows_per_group": $5
}
EOF
}

make_repo() {
  git init -q -b main "$FIX"
  git -C "$FIX" config user.email test@example.com
  git -C "$FIX" config user.name Test
  git -C "$FIX" config commit.gpgsign false
  git -C "$FIX" config core.hooksPath /dev/null
  printf 'base\n' > "$FIX/base.txt"
  git -C "$FIX" add base.txt
  git -C "$FIX" commit -qm "base"
}

# merged_branch <name> : a branch whose work is already in main, so it is reclaimable.
merged_branch() {
  git -C "$FIX" checkout -q -b "$1" main
  printf '%s\n' "$1" > "$FIX/$1.txt"
  git -C "$FIX" add "$1.txt"
  git -C "$FIX" commit -qm "$1 work"
  git -C "$FIX" checkout -q main
  git -C "$FIX" merge -q --no-ff -m "merge $1" "$1"
}

# unmerged_branch <name> : a branch carrying content main does not have, so it is retained.
unmerged_branch() {
  git -C "$FIX" checkout -q -b "$1" main
  printf '%s\n' "$1" > "$FIX/$1.txt"
  git -C "$FIX" add "$1.txt"
  git -C "$FIX" commit -qm "$1 work"
  git -C "$FIX" checkout -q main
}

add_wt() { git -C "$FIX" worktree add -q "$WTDIR/$1" "$1"; }

report()      { run --separate-stderr bash "$REPORT" --repo "$FIX" --no-disk "$@"; }
report_disk() { run --separate-stderr bash "$REPORT" --repo "$FIX" "$@"; }

# A synthetic record stream, so rendering can be exercised without a repository at all.
# Fields: kind name path population target verdict ahead bytes age_days reason
write_records() {
  printf '%s\n' \
    "worktree	agent-aaa1	/x/agent-aaa1	agent	main	reclaimable	0	104857600	30	already merged into main (ancestor); clean; no live process" \
    "worktree	agent-aaa2	/x/agent-aaa2	agent	main	reclaimable	0	104857600	30	already merged into main (ancestor); clean; no live process" \
    "worktree	agent-aaa3	/x/agent-aaa3	agent	main	reclaimable	2	104857600	30	squash-merged into main (2 commit(s) ahead, no unique content); clean; no live process" \
    "worktree	E01_S01_T01-a	/x/E01_S01_T01-a	board-task	main	retained	1	52428800	3	carries content not in main: 2 path(s) [a.txt b.txt ]" \
    "worktree	main	/x/repo	other	main	retained	-	393216000	0	excluded: primary checkout" \
    "branch	orphan-1	-	other	main	reclaimable	0	0	99	already merged into main (ancestor); clean; no live process; no worktree" \
    > "$BASE/records.tsv"
}

# ===========================================================================
# the script itself
# ===========================================================================

@test "report.sh exists, is executable, passes bash -n and is shellcheck clean" {
  [ -f "$REPORT" ]
  [ -x "$REPORT" ]
  run bash -n "$REPORT"
  [ "$status" -eq 0 ]
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  run shellcheck "$REPORT"
  [ "$status" -eq 0 ]
  run shellcheck -S warning "$REPORT"
  [ "$status" -eq 0 ]
}

@test "the skill follows the Canonical Naming Contract: directory j-tidy, frontmatter name j.tidy" {
  [ -f "$SKILL" ]
  run grep -c '^name: j\.tidy$' "$SKILL"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run grep -q '^name: j\.j-tidy' "$SKILL"
  [ "$status" -ne 0 ]
  run grep -cE '^description: .{20,}' "$SKILL"
  [ "$output" = "1" ]
}

@test "SKILL.md delegates the deterministic work to the scripts rather than restating it" {
  # The Skill Implementation Principle, as an explicit acceptance criterion on E56_S06_T02: the
  # judgment steps stay here, the mechanics do not. The pin is that SKILL.md invokes report.sh and
  # contains no git plumbing of its own.
  run grep -q 'report\.sh' "$SKILL"
  [ "$status" -eq 0 ]
  # The pin is on what SKILL.md tells the agent to RUN, i.e. its fenced code blocks: not one of
  # them may contain a git plumbing command, because every git operation belongs to a script.
  # Prose that explains what the scripts do (`git branch -d`, never `-D`) is the point of the file
  # and is deliberately not matched.
  run bash -c "awk '/^\`\`\`/ { inblock = !inblock; next } inblock' '$SKILL' | grep -nE '^[[:space:]]*git '"
  [ "$status" -ne 0 ]
}

@test "the skill is registered in the CLAUDE.md, AGENTS.md and README.md tables" {
  run grep -q '^| `j\.tidy` |' "$REPO_ROOT/CLAUDE.md"
  [ "$status" -eq 0 ]
  run grep -q '^| `/j-tidy` |' "$REPO_ROOT/AGENTS.md"
  [ "$status" -eq 0 ]
  run grep -q '^| `j\.tidy` |' "$REPO_ROOT/README.md"
  [ "$status" -eq 0 ]
}

@test "j.smoke-test reports no critical finding for j-tidy" {
  run bash "$REPO_ROOT/skills/j-smoke-test/scripts/smoke-test-skills.sh" --root "$REPO_ROOT"
  assert_output_contains "Result: PASS"
  run bash -c "bash '$REPO_ROOT/skills/j-smoke-test/scripts/smoke-test-skills.sh' --root '$REPO_ROOT' | grep '\"skill\":\"j-tidy\"' | grep '\"severity\":\"critical\"'"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# report-only
# ===========================================================================

@test "a bare invocation says REPORT ONLY and mutates nothing" {
  make_repo
  merged_branch wt-merged
  unmerged_branch wt-unmerged
  add_wt wt-merged
  add_wt wt-unmerged
  printf 'junk\n' > "$WTDIR/wt-unmerged/junk.txt"

  local before_wt before_refs
  before_wt="$(git -C "$FIX" worktree list --porcelain)"
  before_refs="$(git -C "$FIX" for-each-ref --format='%(refname) %(objectname)')"

  report_disk
  [ "$status" -eq 0 ]
  assert_output_contains "REPORT ONLY - nothing was changed"
  assert_output_contains "Nothing above has been deleted."

  [ "$(git -C "$FIX" worktree list --porcelain)" = "$before_wt" ]
  [ "$(git -C "$FIX" for-each-ref --format='%(refname) %(objectname)')" = "$before_refs" ]
  [ -d "$WTDIR/wt-merged" ]
  [ -f "$WTDIR/wt-unmerged/junk.txt" ]
}

@test "report.sh has no removal code at all - not a guarded path, no path" {
  run grep -nE 'git worktree remove|git branch -d|git branch -D|worktree-remove-guard' "$REPORT"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# the report itself
# ===========================================================================

@test "the report groups by population and states counts, disk and the retention reason" {
  write_records
  run --separate-stderr bash "$REPORT" --records "$BASE/records.tsv"
  [ "$status" -eq 0 ]
  assert_output_contains "RECLAIMABLE"
  assert_output_contains "RETAINED"
  assert_output_contains "NOT ELIGIBLE"
  assert_output_contains "agent (3 entries"
  assert_output_contains "board-task (1 entry"
  assert_output_contains "carries content not in main"
  assert_output_contains "excluded: primary checkout"
}

@test "totals are stated so the headline number needs no arithmetic" {
  write_records
  run --separate-stderr bash "$REPORT" --records "$BASE/records.tsv"
  assert_output_contains "entries           6 (5 worktrees, 1 branch with no worktree)"
  assert_output_contains "reclaimable       4 entries, 300.0 MB"
  assert_output_contains "retained          1 entry, 50.0 MB"
  assert_output_contains "not eligible      1 entry, 375.0 MB"
}

@test "a truncated group states how many entries were NOT shown" {
  write_records
  run --separate-stderr bash "$REPORT" --records "$BASE/records.tsv" --max-rows 1
  [ "$status" -eq 0 ]
  assert_output_contains "and 2 more reclaimable agent entries NOT SHOWN"
  assert_output_contains "report_max_rows_per_group = 1"
  # the count itself is still complete - only the listing was capped
  assert_output_contains "agent (3 entries"
}

@test "nothing is reported as omitted when nothing was held back" {
  write_records
  run --separate-stderr bash "$REPORT" --records "$BASE/records.tsv" --max-rows 0
  assert_output_not_contains "NOT SHOWN"
  assert_output_contains "agent-aaa3"
}

@test "an empty record stream is reported as such, not as an empty success" {
  : > "$BASE/empty.tsv"
  run --separate-stderr bash "$REPORT" --records "$BASE/empty.tsv"
  [ "$status" -eq 0 ]
  assert_output_contains "No worktrees and no branches to assess."
}

@test "--no-disk is reported as not measured rather than as zero disk" {
  make_repo
  merged_branch wt-merged
  add_wt wt-merged
  report
  assert_output_contains "disk NOT measured"
  assert_output_contains "not measured"
}

# ===========================================================================
# thresholds come from the config file, at run time
# ===========================================================================

@test "--print-thresholds names the resolved file and its values" {
  write_config 7 3 5 1 2
  run --separate-stderr bash "$REPORT" --print-thresholds
  [ "$status" -eq 0 ]
  assert_output_contains "config_file=$CFG"
  assert_output_contains "retention_age_days=7"
  assert_output_contains "worktree_count_ceiling=3"
  assert_output_contains "branch_count_ceiling=5"
  assert_output_contains "disk_ceiling_mb=1"
  assert_output_contains "report_max_rows_per_group=2"
}

@test "a crossed ceiling is surfaced prominently, and the same run passes under a raised ceiling" {
  write_records

  write_config 14 2 0 1 15
  run --separate-stderr bash "$REPORT" --records "$BASE/records.tsv"
  assert_output_contains "CEILING CROSSED"
  assert_output_contains "!! worktrees        5 > ceiling 2"
  assert_output_contains "!! branches         1 > ceiling 0"
  assert_output_contains "!! disk"
  assert_output_contains "ceilings crossed. This sweep is overdue."

  write_config 14 999 999 999999 15
  run --separate-stderr bash "$REPORT" --records "$BASE/records.tsv"
  assert_output_not_contains "CEILING CROSSED"
  assert_output_contains "worktrees        5 (ceiling 999)"
}

@test "the retention age comes from the config: the stale count follows it" {
  write_records
  write_config 1000 999 999 999999 15
  run --separate-stderr bash "$REPORT" --records "$BASE/records.tsv"
  assert_output_contains "stale            0 entries older than 1000 days"
  write_config 2 999 999 999999 15
  run --separate-stderr bash "$REPORT" --records "$BASE/records.tsv"
  assert_output_contains "stale            5 entries older than 2 days"
}

@test "report_max_rows_per_group is read from the config, not from a flag or a built-in" {
  write_records
  write_config 14 999 999 999999 2
  run --separate-stderr bash "$REPORT" --records "$BASE/records.tsv"
  assert_output_contains "and 1 more reclaimable agent entry NOT SHOWN"
  assert_output_contains "report_max_rows_per_group = 2"
}

@test "with no config resolvable the ceiling checks are skipped, never replaced by a default" {
  write_records
  export JENGA_TIDY_CONFIG_FILE="$BASE/does-not-exist.json"
  run --separate-stderr bash "$REPORT" --records "$BASE/records.tsv"
  [ "$status" -eq 0 ]
  assert_output_contains "UNAVAILABLE"
  assert_output_contains "No default was substituted"
  assert_output_not_contains "CEILING CROSSED"
  # and nothing was truncated, because there is no row cap to apply
  assert_output_not_contains "NOT SHOWN"
  assert_output_contains "agent-aaa3"

  run --separate-stderr bash "$REPORT" --print-thresholds
  assert_output_contains "config_source=none"
}

@test "the shipped template is used when a project has no instance" {
  write_records
  unset JENGA_TIDY_CONFIG_FILE
  # Resolve against a staged package root that has the template but no project configs directory.
  local stage="$BASE/stage"
  mkdir -p "$stage/skills/j-tidy/scripts" "$stage/templates" "$stage/scripts"
  cp "$TIDY_DIR"/*.sh "$stage/skills/j-tidy/scripts/"
  cp "$REPO_ROOT/templates/tidy-config.json" "$stage/templates/"
  run --separate-stderr bash "$stage/skills/j-tidy/scripts/report.sh" --print-thresholds
  [ "$status" -eq 0 ]
  assert_output_contains "config_source=shipped default"
  assert_output_contains "tidy-config.json"
}

@test "the shipped template and the project instance carry the same keys" {
  local k
  for k in config_version retention_age_days worktree_count_ceiling branch_count_ceiling disk_ceiling_mb report_max_rows_per_group; do
    run jq -e --arg k "$k" '(.[$k] | type) == "number"' "$REPO_ROOT/templates/tidy-config.json"
    [ "$status" -eq 0 ]
    run jq -e --arg k "$k" '(.[$k] | type) == "number"' "$REPO_ROOT/project/configs/tidy-config.json"
    [ "$status" -eq 0 ]
  done
}

# ===========================================================================
# failure handling
# ===========================================================================

@test "a classifier failure is propagated, not reported as an empty sweep" {
  make_repo
  local stage="$BASE/stage2"
  mkdir -p "$stage/skills/j-tidy/scripts" "$stage/scripts" "$stage/templates"
  cp "$TIDY_DIR"/*.sh "$stage/skills/j-tidy/scripts/"
  cp "$REPO_ROOT/templates/tidy-config.json" "$stage/templates/"
  run --separate-stderr bash "$stage/skills/j-tidy/scripts/report.sh" --repo "$FIX" --no-disk
  [ "$status" -eq 3 ]
  assert_contains "$stderr" "classification failed"
}

@test "usage errors exit 2" {
  run --separate-stderr bash "$REPORT" --nonsense
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$REPORT" --records "$BASE/nope.tsv"
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$REPORT" --max-rows abc
  [ "$status" -eq 2 ]
}

@test "this suite leaves the real repository's worktrees and branches alone" {
  local before_wt before_br
  before_wt="$(git -C "$REPO_ROOT" worktree list --porcelain)"
  before_br="$(git -C "$REPO_ROOT" for-each-ref --format='%(refname)' refs/heads)"
  make_repo
  merged_branch wt-merged
  add_wt wt-merged
  report_disk
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPO_ROOT" worktree list --porcelain)" = "$before_wt" ]
  [ "$(git -C "$REPO_ROOT" for-each-ref --format='%(refname)' refs/heads)" = "$before_br" ]
}
