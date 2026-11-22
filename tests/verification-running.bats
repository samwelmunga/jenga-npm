#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# Coverage for "a board status is not merge authorisation" (E89_S06_T16).
#
# Contract under test:
#   - scripts/verification-running.sh                  header comment: exit 0 clear, 1 still verifying
#   - scripts/merge-task-into-perceived-branch.sh      exit 8 while a Tester holds a fresh slot, --allow-verifying override
#
# Isolation. Every test builds a throwaway git repository ($PROJ under $BATS_TEST_TMPDIR) holding its own
# project/queue/concurrency-slots-*.json; the scripts are copied into $BIN outside it. The real repository is only
# read. The reproduced sequence: hold a tester slot for a task, attempt the merge and see it refused; release the slot,
# retry and see the merge proceed with no extra step.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$BATS_TEST_TMPDIR/bin"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$BIN" "$PROJ/project/queue" "$PROJ/project/configs"
  for s in verification-running.sh merge-task-into-perceived-branch.sh perceived-branch.sh; do
    [ -f "$REPO_ROOT/scripts/$s" ] || skip "scripts/$s is absent from this tree"
    cp "$REPO_ROOT/scripts/$s" "$BIN/$s"
  done
  unset CLAUDE_CODE_SESSION_ID JENGA_SESSION_ID CLAUDE_SESSION_ID JENGA_CHECKLIST_SESSION_ID JENGA_MERGE_TASK_ID
  export JENGA_PROJECT_ROOT="$PROJ"
  export JENGA_PROJECT_DIR="$PROJ"
  cd "$PROJ"
  git init -q -b main .
  git config user.email t@example.com
  git config user.name t
  echo x > f
  git add f
  git commit -q -m init
  git branch E89_S06_T90-demo
}

# slot <holder> <iso timestamp>
slot() {
  printf '{"developer":{"cap":8,"holders":{}},"tester":{"cap":8,"holders":{"%s":"%s"}}}\n' "$1" "$2" \
    > "$PROJ/project/queue/concurrency-slots-sess.json"
}

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

@test "no slot file: verification is not running" {
  run bash "$BIN/verification-running.sh" E89_S06_T90
  [ "$status" -eq 0 ]
}

@test "a fresh tester slot for the task means verification is still running" {
  slot E89_S06_T90 "$(now)"
  run bash "$BIN/verification-running.sh" E89_S06_T90
  [ "$status" -eq 1 ]
  case "$output" in *"E89_S06_T90"*) ;; *) false ;; esac
}

@test "a task branch name is reduced to its task id" {
  slot E89_S06_T90 "$(now)"
  run bash "$BIN/verification-running.sh" E89_S06_T90-demo
  [ "$status" -eq 1 ]
}

@test "a bundle slot held under the story id covers its tasks" {
  slot E89_S06 "$(now)"
  run bash "$BIN/verification-running.sh" E89_S06_T90
  [ "$status" -eq 1 ]
}

@test "a slot held for a different task does not match" {
  slot E89_S06_T91 "$(now)"
  run bash "$BIN/verification-running.sh" E89_S06_T90
  [ "$status" -eq 0 ]
}

@test "a stale slot is ignored, so a crashed Tester cannot wedge merging" {
  slot E89_S06_T90 "2020-01-01T00:00:00Z"
  run bash "$BIN/verification-running.sh" E89_S06_T90
  [ "$status" -eq 0 ]
}

@test "with no argument any fresh tester slot counts (the checklist form)" {
  slot E89_S06_T91 "$(now)"
  run bash "$BIN/verification-running.sh" --quiet
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "JENGA_MERGE_TASK_ID narrows the no-argument form to one task" {
  slot E89_S06_T91 "$(now)"
  JENGA_MERGE_TASK_ID=E89_S06_T90 run bash "$BIN/verification-running.sh"
  [ "$status" -eq 0 ]
}

@test "the sequence: held slot refuses the merge, release lets the retry proceed" {
  git checkout -q -b E89_S06_T90-demo2
  echo y > g
  git add g
  git commit -q -m work
  git checkout -q main
  slot E89_S06_T90 "$(now)"
  run bash "$BIN/merge-task-into-perceived-branch.sh" E89_S06_T90-demo2
  [ "$status" -eq 8 ]
  # released: the Tester's session ended (slot holder removed)
  printf '{"developer":{"cap":8,"holders":{}},"tester":{"cap":8,"holders":{}}}\n' > "$PROJ/project/queue/concurrency-slots-sess.json"
  run bash "$BIN/merge-task-into-perceived-branch.sh" E89_S06_T90-demo2
  # no perceived branch is set in the fixture, so the script reports "not applicable" (3): it got past the gate
  [ "$status" -eq 3 ]
}

@test "--allow-verifying overrides the refusal" {
  slot E89_S06_T90 "$(now)"
  run bash "$BIN/merge-task-into-perceived-branch.sh" E89_S06_T90-demo --allow-verifying
  [ "$status" -eq 3 ]
}
