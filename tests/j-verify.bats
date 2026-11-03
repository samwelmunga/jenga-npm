#!/usr/bin/env bats
#
# skills/j-verify/scripts/verify-context.sh — expand and context modes against a throwaway project.
# (epic E87, story E87_S07, task E87_S07_T03)
#
# Everything happens in $BATS_TEST_TMPDIR; the real repository's project/board/ is never read or
# written. Neither verify-context.sh nor close-task-context.sh honours any environment override —
# both resolve PROJECT_ROOT with `git rev-parse --show-toplevel` from the script's OWN directory — so
# the only way to point them at a fixture tree is to copy the scripts into it. That is the pattern
# tests/close-task-context.bats established and this suite follows it.
#
# The two tests that matter most are the pair named "... no EST-tagged commits ...": they cover the
# exact case that motivated j.verify and that j.close-task refuses by design.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# Run the subject with stdout and stderr captured to files OUTSIDE the fixture tree, so the no-write
# test's cleanliness check is never polluted by the harness's own scratch files.
vc() { bash "$SCRIPT" "$@" >"$BATS_TEST_TMPDIR/out" 2>"$BATS_TEST_TMPDIR/err"; }
out() { cat "$BATS_TEST_TMPDIR/out"; }
err() { cat "$BATS_TEST_TMPDIR/err"; }

setup() {
  FIX="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$FIX/skills/j-verify" "$FIX/skills/j-close-task" "$FIX/skills/j-reconcile" \
    "$FIX/project/board/tasks" "$FIX/project/board/stories" "$FIX/project/board/epics" "$FIX/project/queue"
  cp -R "$REPO_ROOT/skills/j-verify/scripts" "$FIX/skills/j-verify/scripts"
  cp -R "$REPO_ROOT/skills/j-close-task/scripts" "$FIX/skills/j-close-task/scripts"
  ln -s "$REPO_ROOT/scripts" "$FIX/scripts"
  ln -s "$REPO_ROOT/templates" "$FIX/templates"
  ln -s "$REPO_ROOT/skills/j-reconcile/scripts" "$FIX/skills/j-reconcile/scripts"
  SCRIPT="$FIX/skills/j-verify/scripts/verify-context.sh"
  CLOSE="$FIX/skills/j-close-task/scripts/close-task-context.sh"

  task_file() { # <id> <status> <title>
    printf -- '---\nid: %s\nstatus: %s\ntitle: "%s"\n---\n\n# %s\n' \
      "$1" "$2" "$3" "$1" > "$FIX/project/board/tasks/$1_x.md"
  }
  list_file() { # <dir> <id> <status> <key> <item...>
    local dir="$1" id="$2" st="$3" key="$4"; shift 4
    {
      printf -- '---\nid: %s\nstatus: %s\ntitle: "%s"\n' "$id" "$st" "$id"
      if [ "$#" -eq 0 ]; then
        printf '%s: []\n' "$key"
      else
        printf '%s:\n' "$key"
        local i
        for i in "$@"; do printf -- '  - %s\n' "$i"; done
      fi
      printf -- '---\n\n# %s\n' "$id"
    } > "$FIX/project/board/$dir/${id}_x.md"
  }

  task_file E99_S01_T01 "Pending"  "first task of story one"
  task_file E99_S01_T02 "Merged"   "second task of story one"
  task_file E99_S02_T01 "Pending"  "the task with no tagged commits"

  list_file stories E99_S01 "In Progress" tasks E99_S01_T01 E99_S01_T02
  list_file stories E99_S02 "In Progress" tasks E99_S02_T01
  list_file stories E99_S03 "Pending"     tasks                      # empty story
  list_file epics   E99     "In Progress" stories E99_S01 E99_S02 E99_S03
  list_file epics   E98     "Pending"     stories                    # empty epic
  list_file epics   E97     "Pending"     stories E99_S03            # expands to no tasks

  git -C "$FIX" init -q -b main
  git -C "$FIX" config user.email t@example.com
  git -C "$FIX" config user.name t
  git -C "$FIX" config commit.gpgsign false
  git -C "$FIX" add -A
  # This message deliberately names no EST id. commits-for-item.sh matches commit MESSAGES and
  # Jenga-Task: trailers only, never file paths, so adding E99_S02_T01's board file here does not
  # give that task a derivable commit — which is what makes the headline pair below honest.
  git -C "$FIX" commit -q -m "chore: fixture board"
  git -C "$FIX" commit -q --allow-empty -m "task(E99_S01_T01): implement the thing"
  HEAD_SHA="$(git -C "$FIX" rev-parse HEAD)"
}

# --------------------------------------------------------------------------- expand

@test "expand on a task id prints that one task with its status and title" {
  run vc expand E99_S01_T01
  [ "$status" -eq 0 ]
  [ "$(out | wc -l | tr -d ' ')" = "1" ]
  [ "$(out | cut -f1)" = "E99_S01_T01" ]
  [ "$(out | cut -f2)" = "Pending" ]
  [ "$(out | cut -f3)" = "first task of story one" ]
}

@test "expand on a story id prints its tasks in frontmatter order" {
  run vc expand E99_S01
  [ "$status" -eq 0 ]
  [ "$(out | cut -f1 | paste -sd, -)" = "E99_S01_T01,E99_S01_T02" ]
  [ "$(out | sed -n 2p | cut -f2)" = "Merged" ]
}

@test "expand on an epic id prints the tasks of every story in its stories list" {
  run vc expand E99
  [ "$status" -eq 0 ]
  [ "$(out | cut -f1 | paste -sd, -)" = "E99_S01_T01,E99_S01_T02,E99_S02_T01" ]
  # E99_S03 is empty: warned about on stderr, and skipped rather than fatal.
  [ "$(out | wc -l | tr -d ' ')" = "3" ]
  err | grep -q "E99_S03"
}

@test "expand on a story with an empty tasks list exits 5 naming the story" {
  run vc expand E99_S03
  [ "$status" -eq 5 ]
  [ -z "$(out)" ]
  err | grep -q "E99_S03"
  err | grep -q "no tasks"
}

@test "expand on an epic with an empty stories list exits 5 naming the epic" {
  run vc expand E98
  [ "$status" -eq 5 ]
  err | grep -q "E98"
  err | grep -q "no stories"
}

@test "expand on an epic whose only story has no tasks exits 5 rather than printing nothing" {
  run vc expand E97
  [ "$status" -eq 5 ]
  [ -z "$(out)" ]
  err | grep -q "E97"
}

@test "expand reports a listed task id that has no board file instead of silently dropping it" {
  list_file stories E99_S04 "Pending" tasks E99_S04_T01   # the task file is never created
  run vc expand E99_S04
  [ "$status" -eq 0 ]
  [ "$(out | cut -f1)" = "E99_S04_T01" ]
  [ "$(out | cut -f2)" = "missing" ]
  err | grep -q "E99_S04_T01"
}

@test "expand rejects a malformed id with 2 and an unknown task with 1" {
  run vc expand nope
  [ "$status" -eq 2 ]
  run vc expand E99_S01_T99
  [ "$status" -eq 1 ]
}

# --------------------------------------------------------------------------- the headline pair
#
# This is the case j.verify exists for. j.close-task refuses it, because it derives SHAs from
# EST-tagged commit messages and E99_S02_T01 has none.

@test "a task with no EST-tagged commits is REFUSED when no evidence is supplied" {
  run vc context E99_S02_T01
  [ "$status" -eq 3 ]
  # The derivation genuinely found nothing — that is the premise of this suite's fixture.
  [ "$(jq -r '.commits | length' "$BATS_TEST_TMPDIR/out")" = "0" ]
  [ "$(jq -r '.other_branch_commits | length' "$BATS_TEST_TMPDIR/out")" = "0" ]
  # The JSON is still printed on a refusal, so the caller can report the specifics.
  [ "$(jq -r .task_id "$BATS_TEST_TMPDIR/out")" = "E99_S02_T01" ]
  [ "$(jq -r '.evidence | length' "$BATS_TEST_TMPDIR/out")" = "0" ]
  [ "$(jq -r .evidence_source "$BATS_TEST_TMPDIR/out")" = "none" ]
  [ "$(jq -r '.sender.paths | length' "$BATS_TEST_TMPDIR/out")" = "0" ]
  err | grep -q "no evidence"
}

@test "a task with no EST-tagged commits RESOLVES when --evidence is supplied" {
  run vc context E99_S02_T01 --evidence "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [ "$(jq -r .evidence_source "$BATS_TEST_TMPDIR/out")" = "supplied" ]
  [ "$(jq -r '.evidence | length' "$BATS_TEST_TMPDIR/out")" = "1" ]
  [ "$(jq -r '.evidence[0]' "$BATS_TEST_TMPDIR/out")" = "$HEAD_SHA" ]
  # The sender object is ready to hand to the Tester, with the evidence as its paths.
  [ "$(jq -c .sender.paths "$BATS_TEST_TMPDIR/out")" = "$(jq -c .evidence "$BATS_TEST_TMPDIR/out")" ]
  [ "$(jq -r .sender.task_id "$BATS_TEST_TMPDIR/out")" = "E99_S02_T01" ]
  # The derivation is still reported as empty, so the Tester can see why evidence was needed.
  [ "$(jq -r '.commits | length' "$BATS_TEST_TMPDIR/out")" = "0" ]
}

# --------------------------------------------------------------------------- context

@test "without --evidence a task that has an EST-tagged commit falls back to the derivation" {
  run vc context E99_S01_T01
  [ "$status" -eq 0 ]
  [ "$(jq -r .evidence_source "$BATS_TEST_TMPDIR/out")" = "derived" ]
  [ "$(jq -r '.commits | length' "$BATS_TEST_TMPDIR/out")" = "1" ]
  [ "$(jq -c .evidence "$BATS_TEST_TMPDIR/out")" = "$(jq -c .commits "$BATS_TEST_TMPDIR/out")" ]
  [ "$(jq -r '.evidence_paths | length' "$BATS_TEST_TMPDIR/out")" = "0" ]
}

@test "--evidence accepts a commit sha and normalises a short one to 40 characters" {
  run vc context E99_S02_T01 --evidence "$(printf '%s' "$HEAD_SHA" | cut -c1-7)"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.evidence_shas[0]' "$BATS_TEST_TMPDIR/out")" = "$HEAD_SHA" ]
  [ "$(jq -r '.evidence_shas[0] | length' "$BATS_TEST_TMPDIR/out")" = "40" ]
}

@test "--evidence accepts a repo-relative path" {
  run vc context E99_S02_T01 --evidence "project/board/tasks/E99_S02_T01_x.md"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.evidence_paths[0]' "$BATS_TEST_TMPDIR/out")" = "project/board/tasks/E99_S02_T01_x.md" ]
  [ "$(jq -r '.evidence_shas | length' "$BATS_TEST_TMPDIR/out")" = "0" ]
}

@test "--evidence accepts shas and paths together and splits them" {
  run vc context E99_S02_T01 --evidence "$HEAD_SHA,project/board/tasks/E99_S02_T01_x.md"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.evidence_shas | length' "$BATS_TEST_TMPDIR/out")" = "1" ]
  [ "$(jq -r '.evidence_paths | length' "$BATS_TEST_TMPDIR/out")" = "1" ]
  [ "$(jq -r '.evidence | length' "$BATS_TEST_TMPDIR/out")" = "2" ]
}

@test "a repeated --evidence flag concatenates rather than overwriting" {
  run vc context E99_S02_T01 --evidence "$HEAD_SHA" --evidence "project/board/tasks/E99_S02_T01_x.md"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.evidence | length' "$BATS_TEST_TMPDIR/out")" = "2" ]
}

@test "an --evidence path that does not exist exits 4 naming it, rather than passing it on" {
  run vc context E99_S02_T01 --evidence "project/board/tasks/does-not-exist.md"
  [ "$status" -eq 4 ]
  [ -z "$(out)" ]
  err | grep -q "does-not-exist.md"
  err | grep -q "does not exist"
}

@test "an --evidence sha that resolves to no commit exits 4 naming it" {
  run vc context E99_S02_T01 --evidence "deadbeef"
  [ "$status" -eq 4 ]
  err | grep -q "deadbeef"
}

@test "an --evidence list with no items is a usage error" {
  run vc context E99_S02_T01 --evidence "  ,  "
  [ "$status" -eq 2 ]
}

@test "context output carries close-task-context.sh's field shape plus the evidence fields" {
  run vc context E99_S01_T01
  [ "$status" -eq 0 ]
  base="$(bash "$CLOSE" context E99_S01_T01)"
  # Every base field survives, with identical values (the sender's session id and date are minted).
  missing="$(jq -n --argjson a "$base" --slurpfile b "$BATS_TEST_TMPDIR/out" '($a|keys)-($b[0]|keys)|length')"
  [ "$missing" = "0" ]
  same="$(jq -n --argjson a "$base" --slurpfile b "$BATS_TEST_TMPDIR/out" \
    '($a|del(.sender)) == ($b[0]|del(.sender,.evidence,.evidence_shas,.evidence_paths,.evidence_source))')"
  [ "$same" = "true" ]
  added="$(jq -n -r --argjson a "$base" --slurpfile b "$BATS_TEST_TMPDIR/out" '(($b[0]|keys)-($a|keys))|sort|join(",")')"
  [ "$added" = "evidence,evidence_paths,evidence_shas,evidence_source" ]
  # The sender object's own shape is unchanged.
  [ "$(jq -n --argjson a "$base" --slurpfile b "$BATS_TEST_TMPDIR/out" '($a.sender|keys) == ($b[0].sender|keys)')" = "true" ]
}

@test "context carries the task file path and the story and epic ids" {
  run vc context E99_S01_T01
  [ "$status" -eq 0 ]
  [ "$(jq -r .task_file "$BATS_TEST_TMPDIR/out")" = "project/board/tasks/E99_S01_T01_x.md" ]
  [ "$(jq -r .story_id "$BATS_TEST_TMPDIR/out")" = "E99_S01" ]
  [ "$(jq -r .epic_id "$BATS_TEST_TMPDIR/out")" = "E99" ]
  [ "$(jq -r .task_status "$BATS_TEST_TMPDIR/out")" = "Pending" ]
}

@test "--session is used verbatim in the sender object" {
  run vc context E99_S02_T01 --evidence "$HEAD_SHA" --session sess-42
  [ "$status" -eq 0 ]
  [ "$(jq -r .sender.session_id "$BATS_TEST_TMPDIR/out")" = "sess-42" ]
}

@test "context rejects a story or epic id, pointing at expand" {
  run vc context E99_S01
  [ "$status" -eq 2 ]
  err | grep -q "expand"
  run vc context E99
  [ "$status" -eq 2 ]
}

@test "--evidence is rejected for expand, and an unknown mode is a usage error" {
  run vc expand E99_S01 --evidence "$HEAD_SHA"
  [ "$status" -eq 2 ]
  run vc bogus E99_S01_T01
  [ "$status" -eq 2 ]
}

@test "--help exits 0 and prints the usage" {
  run vc --help
  [ "$status" -eq 0 ]
  out | grep -q "verify-context.sh expand"
  out | grep -q "verify-context.sh context"
}

# --------------------------------------------------------------------------- the no-write contract

@test "neither mode writes a board file, a trigger or a status" {
  before="$(cd "$FIX" && find . -path ./.git -prune -o -type f -newer "$SCRIPT" -print | sort)"
  bash "$SCRIPT" expand E99 >/dev/null 2>&1
  bash "$SCRIPT" expand E99_S01 >/dev/null 2>&1
  bash "$SCRIPT" expand E99_S01_T01 >/dev/null 2>&1
  bash "$SCRIPT" expand E98 >/dev/null 2>&1 || true
  bash "$SCRIPT" context E99_S01_T01 >/dev/null 2>&1
  bash "$SCRIPT" context E99_S02_T01 >/dev/null 2>&1 || true
  bash "$SCRIPT" context E99_S02_T01 --evidence "$HEAD_SHA" >/dev/null 2>&1
  bash "$SCRIPT" context E99_S02_T01 --evidence "nope.md" >/dev/null 2>&1 || true
  after="$(cd "$FIX" && find . -path ./.git -prune -o -type f -newer "$SCRIPT" -print | sort)"
  [ "$before" = "$after" ]
  # The fixture tree is a committed git repo: an edited board file, a new trigger or a status
  # rewrite would all show up here.
  [ -z "$(git -C "$FIX" status --porcelain)" ]
  [ ! -e "$FIX/project/queue/scrum_triggers.jsonl" ]
}
