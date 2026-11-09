#!/usr/bin/env bats
#
# Groups 4 and 6b of the E86_S05 audit (E86_S05_T05): events, rapports and the lifecycle-status scripts with three- and
# four-digit board IDs.
#
# Subject: tickets E1001_S100_T100 (wide), E100_S10_T10 and E10_S1_T1 (neighbours that share leading characters with it).
#   - skills/j-self-sync/scripts/mark-merged.sh, skills/j-mirror-public/scripts/mark-publicized.sh and
#     scripts/mark-deployed.sh (with the SHA read from a `Source-Commit:` trailer, as compute-deploy-reconcile.sh does)
#     change the wide task's status and leave both neighbours byte-identical
#   - scripts/events-append.sh writes an event with a wide task_id and it reads back unchanged
#   - scripts/generate-rapport-manifest.sh lists a rapport named for a wide task
#   - scripts/link-external-ref.sh writes external_refs only into the exact ID's file
#
# Isolation: the lifecycle scripts find their repo root from their own location, so they run as copies inside a throwaway
# git repo under $BATS_TEST_TMPDIR. The linker runs from this repository against a scratch project (JENGA_PROJECT_ROOT).
# This repository's board, history, tags and event log are never read or written. Assertions use `[ ... ]`, never `[[ ]]`.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
WIDE="E1001_S100_T100"
MID="E100_S10_T10"
NARROW="E10_S1_T1"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq is not installed"
  command -v python3 >/dev/null 2>&1 || skip "python3 is not installed"
  unset JENGA_PROJECT_DIR CLAUDE_PROJECT_DIR COPILOT_WORKSPACE_FOLDER JENGA_PROJECT_ROOT
  PROJ="$BATS_TEST_TMPDIR/proj"
  git init -q -b main "$PROJ"
  git -C "$PROJ" config user.email test@example.com
  git -C "$PROJ" config user.name Test
  git -C "$PROJ" config commit.gpgsign false
  git -C "$PROJ" config core.hooksPath /dev/null
  mkdir -p "$PROJ/scripts" "$PROJ/lib" "$PROJ/skills/j-self-sync/scripts" "$PROJ/skills/j-close-story/scripts" \
           "$PROJ/skills/j-mirror-public/scripts" "$PROJ/project/board/tasks" "$PROJ/project/logs"
  cp "$REPO_ROOT"/scripts/{with-lock,commits-for-item,events-append,mark-deployed,generate-rapport-manifest}.sh "$PROJ/scripts/"
  cp "$REPO_ROOT/lib/resolve-project-dir.sh" "$PROJ/lib/"
  cp "$REPO_ROOT/skills/j-close-story/scripts/update-task-frontmatter.sh" "$PROJ/skills/j-close-story/scripts/"
  cp "$REPO_ROOT/skills/j-self-sync/scripts/mark-merged.sh" "$PROJ/skills/j-self-sync/scripts/"
  cp "$REPO_ROOT/skills/j-mirror-public/scripts/mark-publicized.sh" "$PROJ/skills/j-mirror-public/scripts/"
  printf "const COPY_SET = [\n  'payload',\n];\n" > "$PROJ/skills/j-self-sync/scripts/run.js"
}

# write_task <dir> <id> <status>: a complete task file (valid for validate-board.sh) named <id>_fixture-task.md.
write_task() {
  local id="$2" story epic
  story="${id%_T*}"
  epic="${story%_S*}"
  mkdir -p "$1"
  cat > "$1/${id}_fixture-task.md" <<EOF
---
id: $id
story_id: $story
epic_id: $epic
title: Fixture task
status: $3
date_created: 2026-10-06
date_started:
date_completed:
dates_previously_completed:
reopened_on:
reopened_reason:
assigned_to: developer
docs: []
depends_on: []
execution_scope: task
needs_docs: true
scope_rationale: "fixture"
jenga_assigned: true
override_justification: ""
epic_scope_approval: false
---

# Task: fixture
EOF
}

tfile() { printf '%s/project/board/tasks/%s_fixture-task.md' "$PROJ" "$1"; }
status_of() { awk '/^status:/ { sub(/^status:[ \t]*/, ""); print; exit }' "$(tfile "$1")"; }
sum_of() { cksum "$1" | cut -d' ' -f1,2; }

# build_history <status>: the three tasks at <status>; one commit for the wide task, then (after PRIV_SHA is taken) one
# for E10_S1_T1. E100_S10_T10 has no commit at all.
build_history() {
  local id p
  for id in "$WIDE" "$MID" "$NARROW"; do write_task "$PROJ/project/board/tasks" "$id" "$1"; done
  git -C "$PROJ" add -A
  git -C "$PROJ" commit -q -m "fixture: scripts and tickets"
  mkdir -p "$PROJ/payload"
  for p in wide.txt wide2.txt; do echo "$p" > "$PROJ/payload/$p"; done
  git -C "$PROJ" add -A
  git -C "$PROJ" commit -q -m "task($WIDE): add the wide payload"
  PRIV_SHA="$(git -C "$PROJ" rev-parse HEAD)"
  echo narrow > "$PROJ/payload/narrow.txt"
  git -C "$PROJ" add -A
  git -C "$PROJ" commit -q -m "task($NARROW): add the narrow payload"
  MID_SUM="$(sum_of "$(tfile "$MID")")"
  NARROW_SUM="$(sum_of "$(tfile "$NARROW")")"
}

assert_neighbours_untouched() {
  [ "$(sum_of "$(tfile "$MID")")" = "$MID_SUM" ]
  [ "$(sum_of "$(tfile "$NARROW")")" = "$NARROW_SUM" ]
}

@test "mark-merged.sh marks only the wide task Merged" {
  build_history Done
  printf 'payload/wide.txt\npayload/wide2.txt\n' > "$BATS_TEST_TMPDIR/diff.txt"
  run bash "$PROJ/skills/j-self-sync/scripts/mark-merged.sh" --diff-file "$BATS_TEST_TMPDIR/diff.txt"
  [ "$status" -eq 0 ]
  [ "$(status_of "$WIDE")" = "Merged" ]
  [ "$(status_of "$MID")" = "Done" ]
  [ "$(status_of "$NARROW")" = "Done" ]
  assert_neighbours_untouched
}

@test "mark-publicized.sh marks only the wide task Publicized" {
  build_history Done
  printf 'payload/wide.txt\npayload/wide2.txt\n' > "$BATS_TEST_TMPDIR/diff.txt"
  run bash "$PROJ/skills/j-mirror-public/scripts/mark-publicized.sh" --diff-file "$BATS_TEST_TMPDIR/diff.txt"
  [ "$status" -eq 0 ]
  [ "$(status_of "$WIDE")" = "Publicized" ]
  assert_neighbours_untouched
}

@test "mark-deployed.sh resolves the Source-Commit trailer and moves only the wide task to Stage then Prod" {
  build_history Publicized
  local pub="$BATS_TEST_TMPDIR/public" sha
  git init -q -b main "$pub"
  git -C "$pub" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false commit -q --allow-empty \
    -m "chore(mirror): sync" -m "Source-Commit: $PRIV_SHA"
  # The extraction compute-deploy-reconcile.sh applies to a public tag's commit message.
  sha="$(git -C "$pub" log -1 --format=%B | grep -E '^Source-Commit: [0-9a-f]{40}$' | head -1 | sed 's/^Source-Commit: //')"
  [ "$sha" = "$PRIV_SHA" ]

  printf 'stage\t1.2.3\tv1.2.3-stage\t%s\n' "$sha" > "$BATS_TEST_TMPDIR/stage.tsv"
  run bash "$PROJ/scripts/mark-deployed.sh" --diff-file "$BATS_TEST_TMPDIR/stage.tsv"
  [ "$status" -eq 0 ]
  [ "$(status_of "$WIDE")" = "Deployed to Stage" ]
  [ "$(status_of "$MID")" = "Publicized" ]
  [ "$(status_of "$NARROW")" = "Publicized" ]
  assert_neighbours_untouched

  printf 'prod\t1.2.3\tv1.2.3\t%s\n' "$sha" > "$BATS_TEST_TMPDIR/prod.tsv"
  run bash "$PROJ/scripts/mark-deployed.sh" --diff-file "$BATS_TEST_TMPDIR/prod.tsv"
  [ "$status" -eq 0 ]
  [ "$(status_of "$WIDE")" = "Deployed to Prod" ]
  [ "$(grep -c '^date_deployed_prod:' "$(tfile "$WIDE")")" = 1 ]
  assert_neighbours_untouched
  run jq -e '.reconciled_tags == ["v1.2.3-stage","v1.2.3"]' "$PROJ/project/data/deploy-reconcile-marker.json"
  [ "$status" -eq 0 ]
}

@test "events-append.sh round-trips a wide task_id unchanged and an exact select finds only that task" {
  local f="$BATS_TEST_TMPDIR/events.json" narrow mid wide
  narrow="{\"event\":\"advisory_checkpoint\",\"agent\":\"developer\",\"task_id\":\"$NARROW\",\"story_id\":\"E10_S1\",\"epic_id\":\"E10\"}"
  mid="{\"event\":\"advisory_checkpoint\",\"agent\":\"developer\",\"task_id\":\"$MID\",\"story_id\":\"E100_S10\",\"epic_id\":\"E100\"}"
  wide="{\"event\":\"advisory_checkpoint\",\"agent\":\"developer\",\"task_id\":\"$WIDE\",\"story_id\":\"E1001_S100\",\"epic_id\":\"E1001\"}"
  run bash "$REPO_ROOT/scripts/events-append.sh" --file "$f" "$narrow"
  [ "$status" -eq 0 ]
  run bash "$REPO_ROOT/scripts/events-append.sh" --file "$f" "$mid"
  [ "$status" -eq 0 ]
  run bash -c "printf '%s' '$wide' | bash '$REPO_ROOT/scripts/events-append.sh' --file '$f'"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$f" | tr -d ' ')" = 3 ]
  [ "$(sed -n 1p "$f")" = "$narrow" ]
  [ "$(sed -n 3p "$f")" = "$wide" ]
  [ "$(jq -s -r --arg i "$WIDE" '[.[] | select(.task_id == $i)] | length' "$f")" = 1 ]
  [ "$(jq -s -r '[.[] | select(.epic_id == "E1001")] | length' "$f")" = 1 ]
  [ "$(jq -s -r --arg i "$MID" '[.[] | select(.task_id == $i)] | length' "$f")" = 1 ]
  [ "$(jq -s -r --arg i "$NARROW" '[.[] | select(.task_id == $i)] | length' "$f")" = 1 ]
}

@test "the rapport manifest generator lists a rapport named for a wide task and skips an IGNORE one" {
  local dir="$PROJ/project/rapports/problems" out="$BATS_TEST_TMPDIR/manifest.json"
  mkdir -p "$dir"
  printf '# Rapport\n\n**Related Task:** %s\n' "$WIDE" > "$dir/${WIDE}-wide-id-example.md"
  printf '# Rapport\n\n**Related Task:** %s\n' "$NARROW" > "$dir/${NARROW}-narrow-example.md"
  printf '# Resolved\n' > "$dir/${WIDE}-resolved.IGNORE.md"
  cd "$PROJ"
  JENGA_PROJECT_DIR="$PROJ" run bash scripts/generate-rapport-manifest.sh "$out"
  [ "$status" -eq 0 ]
  run jq -e 'length == 2
    and any(.[]; . == "project/rapports/problems/E1001_S100_T100-wide-id-example.md")
    and any(.[]; . == "project/rapports/problems/E10_S1_T1-narrow-example.md")' "$out"
  [ "$status" -eq 0 ]
}

@test "link-external-ref.sh writes external_refs only into the exact ID's file" {
  local lp="$BATS_TEST_TMPDIR/lproj" id
  mkdir -p "$lp/project/configs"
  printf '%s\n' '{"paths":{"epics":"project/board/epics","stories":"project/board/stories","tasks":"project/board/tasks"}}' \
    > "$lp/project/configs/workflow.json"
  for id in "$WIDE" "$MID" "$NARROW"; do write_task "$lp/project/board/tasks" "$id" Pending; done
  PROJ="$lp"
  MID_SUM="$(sum_of "$(tfile "$MID")")"
  export JENGA_PROJECT_ROOT="$lp"

  run --separate-stderr bash "$REPO_ROOT/scripts/link-external-ref.sh" "$WIDE" --system jira --kind issue --key WIDE-1
  [ "$status" -eq 0 ]
  [ "$(grep -c '^external_refs:' "$(tfile "$WIDE")")" = 1 ]
  [ "$(grep -c 'WIDE-1' "$(tfile "$WIDE")")" -ge 1 ]
  [ "$(grep -c 'external_refs' "$(tfile "$MID")")" = 0 ]
  [ "$(grep -c 'external_refs' "$(tfile "$NARROW")")" = 0 ]

  run --separate-stderr bash "$REPO_ROOT/scripts/link-external-ref.sh" "$NARROW" --system jira --kind issue --key NARROW-1
  [ "$status" -eq 0 ]
  [ "$(grep -c 'NARROW-1' "$(tfile "$NARROW")")" -ge 1 ]
  [ "$(grep -c 'WIDE-1' "$(tfile "$NARROW")")" = 0 ]
  [ "$(grep -c 'NARROW-1' "$(tfile "$WIDE")")" = 0 ]
  [ "$(sum_of "$(tfile "$MID")")" = "$MID_SUM" ]
}
