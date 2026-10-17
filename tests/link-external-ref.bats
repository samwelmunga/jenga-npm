#!/usr/bin/env bats
#
# E71_S04_T01: scripts/link-external-ref.sh validates a Jira key / Confluence page URL / Bitbucket repo or
# pull-request URL offline and records it as an `external_refs` entry on an epic, story or task file, under
# scripts/with-lock.sh, idempotently, without disturbing any other frontmatter byte, and with the result passing
# scripts/validate-board.sh.
#
# Every case builds its own scratch project under $BATS_TEST_TMPDIR and points JENGA_PROJECT_ROOT at it, so the
# live board is never read or written. Network tools are stubbed on PATH with a sentinel and teardown() asserts none
# was called.
#
# E71_S04_T02 adds the `--decline` mode (the cases at the end of this file): it records `external_refs_declined: true`
# and a dated `external_refs_declined_note` under the same lock, edit and self-check, takes no link arguments and is
# idempotent.
#
# Mirror safety: depends only on scripts/link-external-ref.sh, scripts/resolve-root.sh, scripts/with-lock.sh,
# scripts/validate-board.sh and fixtures built here.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LINKER="$REPO_ROOT/scripts/link-external-ref.sh"
VALIDATOR="$REPO_ROOT/scripts/validate-board.sh"

EPIC_ID="E90"
STORY_ID="E90_S01"
TASK_ID="E90_S01_T01"

write_fixtures() {
  cat > "$EPIC_FILE" <<'EOF'
---
id: E90
title: Fixture epic   # a trailing comment that must survive
status: Pending
date_created: 2026-10-06
date_started:
date_completed:
dates_previously_completed:
reopened_on:
reopened_reason:
stories:
  - E90_S01
docs: ["project/documentation/example.md"]
epic_scope_approval: false
---

# Epic: fixture

Body text that must never change.
EOF
  cat > "$STORY_FILE" <<'EOF'
---
id: E90_S01
epic_id: E90
title: "Fixture story"
status: Pending
date_created: 2026-10-06
date_started:
date_completed:
dates_previously_completed:
reopened_on:
reopened_reason:
docs: []
priority: P1
depends_on: E90_S00   # kept as written
tasks:
  - E90_S01_T01
---

# Story: fixture
EOF
  cat > "$TASK_FILE" <<'EOF'
---
id: E90_S01_T01
story_id: E90_S01
epic_id: E90
title: Fixture task
status: Pending
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

setup() {
  SCRATCH="$BATS_TEST_TMPDIR/proj"
  EPICS="$SCRATCH/project/board/epics"
  STORIES="$SCRATCH/project/board/stories"
  TASKS="$SCRATCH/project/board/tasks"
  mkdir -p "$EPICS" "$STORIES" "$TASKS" "$SCRATCH/project/configs"
  cat > "$SCRATCH/project/configs/workflow.json" <<'EOF'
{"paths":{"epics":"project/board/epics","stories":"project/board/stories","tasks":"project/board/tasks"}}
EOF
  EPIC_FILE="$EPICS/E90_fixture-epic.md"
  STORY_FILE="$STORIES/E90_S01_fixture-story.md"
  TASK_FILE="$TASKS/E90_S01_T01_fixture-task.md"
  write_fixtures
  export JENGA_PROJECT_ROOT="$SCRATCH"
  unset WITH_LOCK_TIMEOUT_SECONDS

  NET_SENTINEL="$BATS_TEST_TMPDIR/network-was-called"
  NETBIN="$BATS_TEST_TMPDIR/netbin"
  mkdir -p "$NETBIN"
  local t
  for t in curl wget nc ncat telnet ssh scp ftp dig nslookup host ping; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 1\n' "$t" "$NET_SENTINEL" > "$NETBIN/$t"
    chmod +x "$NETBIN/$t"
  done
  PATH="$NETBIN:$PATH"
  export PATH

  TODAY_BEFORE="$(date -u +%F)"
}

teardown() {
  [ ! -e "$NET_SENTINEL" ]
}

# run_link <args...>: run the linker capturing stdout in $output and stderr in $stderr.
run_link() {
  run --separate-stderr bash "$LINKER" "$@"
}

# snapshot: every path under the scratch project plus a checksum of every file, so a stray temp file, a left-over
# lock directory or a changed byte all show up.
snapshot() {
  find "$SCRATCH" -print | sort
  find "$SCRATCH" -type f -exec cksum {} + | sort
}

# inject_at_docs <file> before|after <text>: put <text> (awk-style \n escapes allowed) next to the `docs: []` line.
# awk rather than sed because BSD sed does not expand \n in a replacement.
inject_at_docs() {
  awk -v where="$2" -v add="$3" '
    /^docs: \[\]$/ && !done {
      if (where == "before") print add
      print
      if (where == "after") print add
      done = 1
      next
    }
    { print }
  ' "$1" > "$1.new"
  mv "$1.new" "$1"
}

file_for() {
  case "$1" in
    "$EPIC_ID") printf '%s' "$EPIC_FILE" ;;
    "$STORY_ID") printf '%s' "$STORY_FILE" ;;
    "$TASK_ID") printf '%s' "$TASK_FILE" ;;
  esac
}

# assert_valid <file>: the file passes scripts/validate-board.sh.
assert_valid() {
  run --separate-stderr bash "$VALIDATOR" "$1"
  [ "$status" -eq 0 ]
}

# assert_rejected <expected-exit> <args...>: run the linker, expect the given exit code and an error on stderr only,
# and prove the scratch project is byte-identical and free of leftovers (no temp file, no lock directory).
assert_rejected() { # assert_rejected <expected-exit> <args...>
  local expected="$1"
  shift
  local before after
  before="$(snapshot)"
  run_link "$@"
  [ "$status" -eq "$expected" ]
  [ -n "$stderr" ]
  [ -z "$output" ]
  after="$(snapshot)"
  [ "$before" = "$after" ]
}

today_matches() { # today_matches <file>: linked_on is today's UTC date (tolerates a midnight rollover)
  local today_after
  today_after="$(date -u +%F)"
  grep -q "linked_on: $TODAY_BEFORE\$" "$1" || grep -q "linked_on: $today_after\$" "$1"
}

# --- the script itself --------------------------------------------------------------------------------------

@test "the script exists, is executable (or committed 100755), and has no hardcoded project/ path in code" {
  [ -f "$LINKER" ]
  if [ ! -x "$LINKER" ]; then
    # A worktree checkout can lose the bit; the committed mode is what ships.
    [ "$(git -C "$REPO_ROOT" ls-files -s -- scripts/link-external-ref.sh | cut -d' ' -f1)" = "100755" ]
  fi
  run grep -v '^[[:space:]]*#' "$LINKER"
  assert_output_not_contains "project/"
  assert_output_contains "resolve-root.sh"
  assert_output_contains "with-lock.sh"
}

# --- valid shapes on an epic, a story and a task ------------------------------------------------------------

@test "a Jira key is recorded on an epic, a story and a task with today's UTC date and validates" {
  local id f
  for id in "$EPIC_ID" "$STORY_ID" "$TASK_ID"; do
    f="$(file_for "$id")"
    run_link "$id" --system jira --kind issue --key PROJ-123
    [ "$status" -eq 0 ]
    assert_contains "$output" "linked:"
    grep -q '^external_refs:$' "$f"
    grep -q '^  - system: jira$' "$f"
    grep -q '^    kind: issue$' "$f"
    grep -q '^    key: PROJ-123$' "$f"
    today_matches "$f"
    assert_valid "$f"
  done
}

@test "a Confluence page URL is recorded on an epic, a story and a task and validates" {
  local id f
  for id in "$EPIC_ID" "$STORY_ID" "$TASK_ID"; do
    f="$(file_for "$id")"
    run_link "$id" --system confluence --kind page --url https://example.atlassian.net/wiki/spaces/PROJ/pages/123456/Some+Title
    [ "$status" -eq 0 ]
    grep -q '^  - system: confluence$' "$f"
    grep -q '^    kind: page$' "$f"
    grep -q '^    url: https://example.atlassian.net/wiki/spaces/PROJ/pages/123456/Some+Title$' "$f"
    today_matches "$f"
    assert_valid "$f"
  done
}

@test "a Bitbucket repo URL is recorded on an epic, a story and a task and validates" {
  local id f
  for id in "$EPIC_ID" "$STORY_ID" "$TASK_ID"; do
    f="$(file_for "$id")"
    run_link "$id" --system bitbucket --kind repo --url https://bitbucket.org/my-workspace/my.repo_1
    [ "$status" -eq 0 ]
    grep -q '^  - system: bitbucket$' "$f"
    grep -q '^    kind: repo$' "$f"
    grep -q '^    url: https://bitbucket.org/my-workspace/my.repo_1$' "$f"
    today_matches "$f"
    assert_valid "$f"
  done
}

@test "a Bitbucket pull-request URL is recorded on an epic, a story and a task and validates" {
  local id f
  for id in "$EPIC_ID" "$STORY_ID" "$TASK_ID"; do
    f="$(file_for "$id")"
    run_link "$id" --system bitbucket --kind pull-request --url https://bitbucket.org/ws/repo/pull-requests/42
    [ "$status" -eq 0 ]
    grep -q '^    kind: pull-request$' "$f"
    grep -q '^    url: https://bitbucket.org/ws/repo/pull-requests/42$' "$f"
    today_matches "$f"
    assert_valid "$f"
  done
}

@test "works with no Atlassian marker or configuration present" {
  [ ! -e "$SCRATCH/project/configs/atlassian.json" ]
  run_link "$TASK_ID" --system jira --kind issue --key ABC-1
  [ "$status" -eq 0 ]
  [ ! -e "$SCRATCH/project/configs/atlassian.json" ]
}

@test "the URL host is lowercased and trailing slashes are stripped before storing" {
  run_link "$STORY_ID" --system bitbucket --kind repo --url "https://BitBucket.ORG/ws/repo//"
  [ "$status" -eq 0 ]
  grep -q '^    url: https://bitbucket.org/ws/repo$' "$STORY_FILE"
  assert_valid "$STORY_FILE"
}

# --- rejections write nothing -------------------------------------------------------------------------------

@test "bad Jira keys are rejected naming the expected shape, and nothing is written" {
  local bad
  for bad in proj-123 PROJ123 PROJ-abc P-1 1PROJ-1 "PROJ-1 " "PROJ-1;x" "PROJ_1"; do
    assert_rejected 2 "$TASK_ID" --system jira --kind issue --key "$bad"
    assert_contains "$stderr" "[A-Z][A-Z0-9]+-[0-9]+"
  done
}

@test "a Jira link needs a key and takes no URL; the wrong kind is rejected" {
  assert_rejected 2 "$TASK_ID" --system jira --kind issue
  assert_rejected 2 "$TASK_ID" --system jira --kind issue --url https://example.atlassian.net/browse/PROJ-1
  assert_rejected 2 "$TASK_ID" --system jira --kind page --key PROJ-1
  assert_rejected 2 "$TASK_ID" --system jira --kind issue --key PROJ-1 --url https://example.atlassian.net/browse/PROJ-1
}

@test "non-Atlassian and non-https URLs are rejected, and nothing is written" {
  assert_rejected 2 "$STORY_ID" --system confluence --kind page --url https://evil.example.com/wiki/spaces/PROJ/pages/123
  assert_rejected 2 "$STORY_ID" --system confluence --kind page --url https://example.atlassian.net.evil.com/wiki/spaces/PROJ/pages/123
  assert_rejected 2 "$STORY_ID" --system confluence --kind page --url http://example.atlassian.net/wiki/spaces/PROJ/pages/123
  assert_rejected 2 "$STORY_ID" --system bitbucket --kind repo --url https://github.com/ws/repo
  assert_rejected 2 "$STORY_ID" --system bitbucket --kind repo --url https://notbitbucket.org/ws/repo
  assert_rejected 2 "$STORY_ID" --system bitbucket --kind repo --url ftp://bitbucket.org/ws/repo
}

@test "credential-bearing URLs are rejected and no secret value is printed or written" {
  local before after
  before="$(snapshot)"
  run_link "$STORY_ID" --system bitbucket --kind repo --url https://user:s3cr3t-token@bitbucket.org/ws/repo
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "credentials"
  assert_not_contains "$stderr" "s3cr3t-token"
  assert_not_contains "$output" "s3cr3t-token"
  run_link "$STORY_ID" --system confluence --kind page --url https://tok3n@example.atlassian.net/wiki/spaces/P/pages/1
  [ "$status" -eq 2 ]
  assert_not_contains "$stderr" "tok3n"
  run_link "$STORY_ID" --system confluence --kind page "--url=https://u:t0ken@example.atlassian.net/wiki/spaces/P/pages/1"
  [ "$status" -eq 2 ]
  assert_not_contains "$stderr" "t0ken"
  after="$(snapshot)"
  [ "$before" = "$after" ]
  run grep -r "s3cr3t-token\|tok3n\|t0ken" "$SCRATCH"
  [ "$status" -ne 0 ]
}

@test "query strings, fragments, ports and whitespace in a URL are rejected without echoing the value" {
  assert_rejected 2 "$STORY_ID" --system confluence --kind page --url "https://example.atlassian.net/wiki/spaces/P/pages/1?token=abc123"
  assert_not_contains "$stderr" "abc123"
  assert_rejected 2 "$STORY_ID" --system confluence --kind page --url "https://example.atlassian.net/wiki/spaces/P/pages/1#frag"
  assert_rejected 2 "$STORY_ID" --system bitbucket --kind repo --url "https://bitbucket.org:8443/ws/repo"
  assert_rejected 2 "$STORY_ID" --system bitbucket --kind repo --url "https://bitbucket.org/ws/repo name"
  assert_rejected 2 "$STORY_ID" --system bitbucket --kind repo --url 'https://bitbucket.org/ws/repo"x'
}

@test "shape and kind mismatches are rejected, and nothing is written" {
  # Confluence space overview, not a page
  assert_rejected 2 "$STORY_ID" --system confluence --kind page --url https://example.atlassian.net/wiki/spaces/PROJ
  # non-numeric page id
  assert_rejected 2 "$STORY_ID" --system confluence --kind page --url https://example.atlassian.net/wiki/spaces/PROJ/pages/abc
  # PR URL claimed as a repo, repo URL claimed as a PR
  assert_rejected 2 "$STORY_ID" --system bitbucket --kind repo --url https://bitbucket.org/ws/repo/pull-requests/42
  assert_rejected 2 "$STORY_ID" --system bitbucket --kind pull-request --url https://bitbucket.org/ws/repo
  # non-numeric PR number
  assert_rejected 2 "$STORY_ID" --system bitbucket --kind pull-request --url https://bitbucket.org/ws/repo/pull-requests/abc
  # .git clone URL
  assert_rejected 2 "$STORY_ID" --system bitbucket --kind repo --url https://bitbucket.org/ws/repo.git
  # a key given for a URL system, a URL given for a key system, wrong kind for the system, unknown system
  assert_rejected 2 "$STORY_ID" --system bitbucket --kind repo --key PROJ-1
  assert_rejected 2 "$STORY_ID" --system confluence --kind issue --url https://example.atlassian.net/wiki/spaces/P/pages/1
  assert_rejected 2 "$STORY_ID" --system github --kind repo --url https://github.com/ws/repo
  assert_rejected 2 "$STORY_ID" --kind repo --url https://bitbucket.org/ws/repo
  assert_rejected 2 "$STORY_ID" --system bitbucket --kind repo
}

@test "an unknown item id exits 3 with a clear message and writes nothing" {
  assert_rejected 3 E99 --system jira --kind issue --key PROJ-1
  assert_contains "$stderr" "E99"
  assert_rejected 3 E90_S99 --system jira --kind issue --key PROJ-1
  assert_rejected 3 E90_S01_T99 --system jira --kind issue --key PROJ-1
}

@test "a malformed item id, no arguments, an unknown flag and a dangling flag are usage errors that write nothing" {
  assert_rejected 2 e90 --system jira --kind issue --key PROJ-1
  assert_rejected 2 E90_T01 --system jira --kind issue --key PROJ-1
  assert_rejected 2 "../E90" --system jira --kind issue --key PROJ-1
  assert_rejected 2
  assert_rejected 2 "$TASK_ID" --system jira --kind issue --key PROJ-1 --token secretvalue99
  assert_not_contains "$stderr" "secretvalue99"
  assert_rejected 2 "$TASK_ID" --system jira --kind issue --key
  assert_rejected 2 --system jira "$TASK_ID"
}

@test "two files matching one id is a failure (exit 6) that writes nothing" {
  cp "$STORY_FILE" "$STORIES/E90_S01_duplicate.md"
  assert_rejected 6 "$STORY_ID" --system jira --kind issue --key PROJ-1
}

# --- idempotence and appending ------------------------------------------------------------------------------

@test "linking the same ref twice leaves one entry, exits 0 and says already linked" {
  run_link "$TASK_ID" --system jira --kind issue --key PROJ-123
  [ "$status" -eq 0 ]
  local once
  once="$(cat "$TASK_FILE")"
  run_link "$TASK_ID" --system jira --kind issue --key PROJ-123
  [ "$status" -eq 0 ]
  assert_contains "$output" "already linked"
  [ "$(cat "$TASK_FILE")" = "$once" ]
  [ "$(grep -c '^  - system:' "$TASK_FILE")" -eq 1 ]
}

@test "the same URL spelled with a different host case or a trailing slash is the same link" {
  run_link "$STORY_ID" --system bitbucket --kind repo --url https://bitbucket.org/ws/repo
  [ "$status" -eq 0 ]
  run_link "$STORY_ID" --system bitbucket --kind repo --url https://BITBUCKET.org/ws/repo/
  [ "$status" -eq 0 ]
  assert_contains "$output" "already linked"
  [ "$(grep -c '^  - system:' "$STORY_FILE")" -eq 1 ]
}

@test "a different ref is appended after the existing entries and the file still validates" {
  run_link "$TASK_ID" --system jira --kind issue --key PROJ-123
  [ "$status" -eq 0 ]
  run_link "$TASK_ID" --system jira --kind issue --key PROJ-124
  [ "$status" -eq 0 ]
  run_link "$TASK_ID" --system bitbucket --kind pull-request --url https://bitbucket.org/ws/repo/pull-requests/7
  [ "$status" -eq 0 ]
  [ "$(grep -c '^external_refs:' "$TASK_FILE")" -eq 1 ]
  [ "$(grep -c '^  - system:' "$TASK_FILE")" -eq 3 ]
  [ "$(grep -n '^    key: ' "$TASK_FILE" | head -1 | cut -d: -f3 | tr -d ' ')" = "PROJ-123" ]
  [ "$(grep '^    key: ' "$TASK_FILE" | tail -1 | tr -d ' ')" = "key:PROJ-124" ]
  assert_valid "$TASK_FILE"
}

@test "same key on a different kind or system is a different ref, not a duplicate" {
  run_link "$STORY_ID" --system bitbucket --kind repo --url https://bitbucket.org/ws/repo
  [ "$status" -eq 0 ]
  run_link "$STORY_ID" --system bitbucket --kind pull-request --url https://bitbucket.org/ws/repo/pull-requests/1
  [ "$status" -eq 0 ]
  [ "$(grep -c '^  - system:' "$STORY_FILE")" -eq 2 ]
}

# --- frontmatter preservation -------------------------------------------------------------------------------

@test "the diff against the original shows only the external_refs lines, added before the closing ---" {
  local f orig id
  for id in "$EPIC_ID" "$STORY_ID" "$TASK_ID"; do
    f="$(file_for "$id")"
    orig="$BATS_TEST_TMPDIR/orig-$id.md"
    cp "$f" "$orig"
    run_link "$id" --system jira --kind issue --key PROJ-123
    [ "$status" -eq 0 ]
    run diff "$orig" "$f"
    [ "$status" -eq 1 ]
    # additions only: no changed or removed line
    run grep -c '^<' <<< "$output"
    [ "$output" = "0" ]
    run grep '^>' <(diff "$orig" "$f")
    [ "${#lines[@]}" -eq 5 ]
    [ "${lines[0]}" = "> external_refs:" ]
    [ "${lines[1]}" = ">   - system: jira" ]
    [ "${lines[2]}" = ">     kind: issue" ]
    [ "${lines[3]}" = ">     key: PROJ-123" ]
    assert_starts_with "${lines[4]}" ">     linked_on: "
    # defined position: the new field is the last thing in the frontmatter
    [ "$(grep -n '^    linked_on: ' "$f" | cut -d: -f1)" -eq "$(( $(grep -n '^---$' "$f" | sed -n 2p | cut -d: -f1) - 1 ))" ]
  done
}

@test "trailing comments, quoting and body text are preserved byte for byte" {
  run_link "$EPIC_ID" --system jira --kind issue --key PROJ-9
  [ "$status" -eq 0 ]
  grep -q '^title: Fixture epic   # a trailing comment that must survive$' "$EPIC_FILE"
  grep -q '^docs: \["project/documentation/example.md"\]$' "$EPIC_FILE"
  grep -q '^Body text that must never change.$' "$EPIC_FILE"
  run_link "$STORY_ID" --system jira --kind issue --key PROJ-9
  [ "$status" -eq 0 ]
  grep -q '^title: "Fixture story"$' "$STORY_FILE"
  grep -q '^depends_on: E90_S00   # kept as written$' "$STORY_FILE"
}

@test "a file with no final newline keeps that property and its body bytes" {
  printf '%s' "$(cat "$STORY_FILE")" > "$STORY_FILE"
  local orig="$BATS_TEST_TMPDIR/orig-nonl.md"
  cp "$STORY_FILE" "$orig"
  [ "$(tail -c1 "$orig" | od -An -c | tr -d ' ')" != '\n' ]
  run_link "$STORY_ID" --system jira --kind issue --key PROJ-5
  [ "$status" -eq 0 ]
  [ "$(tail -c 14 "$STORY_FILE")" = "$(tail -c 14 "$orig")" ]
  [ "$(tail -c1 "$STORY_FILE" | od -An -c | tr -d ' ')" = "$(tail -c1 "$orig" | od -An -c | tr -d ' ')" ]
  assert_valid "$STORY_FILE"
}

@test "an empty external_refs: [] is replaced by a block list, keeping its trailing comment" {
  inject_at_docs "$STORY_FILE" after 'external_refs: []   # none yet'
  grep -q '^external_refs: \[\]   # none yet$' "$STORY_FILE"
  local orig="$BATS_TEST_TMPDIR/orig-empty.md"
  cp "$STORY_FILE" "$orig"
  run_link "$STORY_ID" --system jira --kind issue --key PROJ-6
  [ "$status" -eq 0 ]
  [ "$(grep -c '^external_refs:' "$STORY_FILE")" -eq 1 ]
  grep -q '^external_refs:   # none yet$' "$STORY_FILE"
  grep -q '^    key: PROJ-6$' "$STORY_FILE"
  run diff "$orig" "$STORY_FILE"
  run grep -c '^<' <<< "$output"
  [ "$output" = "1" ]
  assert_valid "$STORY_FILE"
}

@test "an external_refs block in the middle of the frontmatter is appended to in place" {
  inject_at_docs "$STORY_FILE" before 'external_refs:\n  - system: jira\n    kind: issue\n    key: PROJ-1\n    linked_on: 2026-10-01'
  assert_valid "$STORY_FILE"
  run_link "$STORY_ID" --system jira --kind issue --key PROJ-2
  [ "$status" -eq 0 ]
  # the new entry sits directly above the field that followed the block
  [ "$(grep -c '^docs: \[\]$' "$STORY_FILE")" -eq 1 ]
  local last_linked docs_line
  last_linked="$(grep -n '^    linked_on: ' "$STORY_FILE" | tail -1 | cut -d: -f1)"
  docs_line="$(grep -n '^docs: \[\]$' "$STORY_FILE" | cut -d: -f1)"
  [ "$docs_line" -eq "$((last_linked + 1))" ]
  assert_valid "$STORY_FILE"
}

@test "an external_refs form the script does not recognise is refused untouched (exit 6)" {
  inject_at_docs "$STORY_FILE" after 'external_refs: [a, b]'
  assert_rejected 6 "$STORY_ID" --system jira --kind issue --key PROJ-1
}

# --- lock -----------------------------------------------------------------------------------------------------

@test "when the board file's lock is held the script aborts with exit 4 and writes nothing" {
  mkdir "$TASK_FILE.lock.d"
  local before after
  before="$(snapshot)"
  export WITH_LOCK_TIMEOUT_SECONDS=1 WITH_LOCK_POLL_SECONDS=0.1
  run_link "$TASK_ID" --system jira --kind issue --key PROJ-1
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "lock"
  after="$(snapshot)"
  [ "$before" = "$after" ]
  # the lock someone else holds is never cleared or bypassed
  [ -d "$TASK_FILE.lock.d" ]
  grep -q '^status: Pending$' "$TASK_FILE"
  run grep -c 'external_refs' "$TASK_FILE"
  [ "$output" = "0" ]
}

@test "the lock is released after a successful write and after an already-linked no-op" {
  run_link "$TASK_ID" --system jira --kind issue --key PROJ-1
  [ "$status" -eq 0 ]
  [ ! -e "$TASK_FILE.lock.d" ]
  run_link "$TASK_ID" --system jira --kind issue --key PROJ-1
  [ "$status" -eq 0 ]
  [ ! -e "$TASK_FILE.lock.d" ]
}

@test "the write happens under with-lock.sh" {
  local spy="$BATS_TEST_TMPDIR/spy"
  mkdir -p "$spy"
  # A fake scripts dir whose with-lock.sh records that it was used, then delegates to the real one.
  mkdir -p "$spy/scripts"
  cp "$LINKER" "$REPO_ROOT/scripts/resolve-root.sh" "$REPO_ROOT/scripts/validate-board.sh" "$spy/scripts/"
  printf '#!/usr/bin/env bash\necho "$1" >> "%s/lock-used"\nexec bash "%s/scripts/with-lock.sh" "$@"\n' "$spy" "$REPO_ROOT" > "$spy/scripts/with-lock.sh"
  run --separate-stderr bash "$spy/scripts/link-external-ref.sh" "$TASK_ID" --system jira --kind issue --key PROJ-1
  [ "$status" -eq 0 ]
  [ "$(basename "$(cat "$spy/lock-used")")" = "E90_S01_T01_fixture-task.md" ]
}

# --- self-check restores on a validation failure --------------------------------------------------------------

@test "if the edited file would fail validate-board.sh the original bytes are restored and exit is 5" {
  # An unknown frontmatter key makes validate-board.sh reject the file regardless of external_refs.
  inject_at_docs "$STORY_FILE" after 'bogus_unknown_key: 1'
  local before after
  before="$(snapshot)"
  run_link "$STORY_ID" --system jira --kind issue --key PROJ-1
  [ "$status" -eq 5 ]
  assert_contains "$stderr" "restored"
  [ -z "$output" ]
  after="$(snapshot)"
  [ "$before" = "$after" ]
}

# --- board directory resolution --------------------------------------------------------------------------------

@test "board directories come from resolve-root.sh, so a relocated board is found and the live board is untouched" {
  local alt="$BATS_TEST_TMPDIR/alt"
  mkdir -p "$alt/project/configs" "$alt/work/e" "$alt/work/s" "$alt/work/t"
  cat > "$alt/project/configs/workflow.json" <<'EOF'
{"paths":{"epics":"work/e","stories":"work/s","tasks":"work/t"}}
EOF
  cp "$EPIC_FILE" "$alt/work/e/E90_moved.md"
  cp "$STORY_FILE" "$alt/work/s/E90_S01_moved.md"
  cp "$TASK_FILE" "$alt/work/t/E90_S01_T01_moved.md"
  local live_before
  live_before="$(snapshot)"
  export JENGA_PROJECT_ROOT="$alt"
  run_link "$TASK_ID" --system jira --kind issue --key PROJ-1
  [ "$status" -eq 0 ]
  grep -q '^    key: PROJ-1$' "$alt/work/t/E90_S01_T01_moved.md"
  [ "$live_before" = "$(snapshot)" ]
}

@test "an unresolvable board directory is a failure that writes nothing (exit 6)" {
  export JENGA_PROJECT_ROOT="$BATS_TEST_TMPDIR/does-not-exist"
  run_link "$TASK_ID" --system jira --kind issue --key PROJ-1
  [ "$status" -eq 6 ]
  [ -n "$stderr" ]
}

# --- offline ---------------------------------------------------------------------------------------------------

@test "every outcome is reachable with network tools failing, and none of them is called" {
  run_link "$TASK_ID" --system jira --kind issue --key PROJ-1
  [ "$status" -eq 0 ]
  run_link "$TASK_ID" --system confluence --kind page --url https://example.atlassian.net/wiki/spaces/P/pages/1
  [ "$status" -eq 0 ]
  run_link "$TASK_ID" --system bitbucket --kind repo --url https://evil.example.com/ws/repo
  [ "$status" -eq 2 ]
  [ ! -e "$NET_SENTINEL" ]
}

@test "the script text invokes no network tool" {
  local t
  for t in curl wget nc ncat telnet ssh scp ftp dig nslookup ping; do
    run grep -E "(^|[^A-Za-z0-9_-])$t( |\$)" <(grep -v '^[[:space:]]*#' "$LINKER")
    [ "$status" -ne 0 ]
  done
}

# =====================================================================================================================
# E71_S04_T02: --decline mode
# =====================================================================================================================

# decline_note_matches <file>: the note is non-empty, names today's UTC date (tolerating a midnight rollover) and says
# the user skipped the link prompt.
decline_note_matches() {
  local today_after
  today_after="$(date -u +%F)"
  grep -q "^external_refs_declined_note: \"Skipped $TODAY_BEFORE: user skipped the external link prompt\.\"\$" "$1" ||
    grep -q "^external_refs_declined_note: \"Skipped $today_after: user skipped the external link prompt\.\"\$" "$1"
}

@test "decline writes external_refs_declined: true and a dated note on an epic, a story and a task, and validates" {
  local id f
  for id in "$EPIC_ID" "$STORY_ID" "$TASK_ID"; do
    f="$(file_for "$id")"
    run_link "$id" --decline
    [ "$status" -eq 0 ]
    assert_starts_with "$output" "declined: $id"
    [ "$(grep -c '^external_refs_declined: true$' "$f")" -eq 1 ]
    [ "$(grep -c '^external_refs_declined_note: ' "$f")" -eq 1 ]
    decline_note_matches "$f"
    assert_valid "$f"
    [ ! -e "$f.lock.d" ]
  done
}

@test "decline works with no Atlassian marker or configuration present" {
  [ ! -e "$SCRATCH/project/configs/atlassian.json" ]
  run_link "$TASK_ID" --decline
  [ "$status" -eq 0 ]
}

@test "decline adds exactly two lines, as the last lines of the frontmatter before the closing ---" {
  local f orig id
  for id in "$EPIC_ID" "$STORY_ID" "$TASK_ID"; do
    f="$(file_for "$id")"
    orig="$BATS_TEST_TMPDIR/orig-decl-$id.md"
    cp "$f" "$orig"
    run_link "$id" --decline
    [ "$status" -eq 0 ]
    run diff "$orig" "$f"
    [ "$status" -eq 1 ]
    run grep -c '^<' <<< "$output"
    [ "$output" = "0" ]
    run grep '^>' <(diff "$orig" "$f")
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "> external_refs_declined: true" ]
    assert_starts_with "${lines[1]}" "> external_refs_declined_note: \"Skipped "
    [ "$(grep -n '^external_refs_declined_note: ' "$f" | cut -d: -f1)" -eq "$(( $(grep -n '^---$' "$f" | sed -n 2p | cut -d: -f1) - 1 ))" ]
  done
}

@test "declining twice leaves one pair of skip fields, exits 0, says already declined and changes no byte" {
  run_link "$TASK_ID" --decline
  [ "$status" -eq 0 ]
  local before after
  before="$(snapshot)"
  run_link "$TASK_ID" --decline
  [ "$status" -eq 0 ]
  assert_contains "$output" "already declined"
  after="$(snapshot)"
  [ "$before" = "$after" ]
  [ "$(grep -c '^external_refs_declined: true$' "$TASK_FILE")" -eq 1 ]
  [ "$(grep -c '^external_refs_declined_note: ' "$TASK_FILE")" -eq 1 ]
  [ ! -e "$TASK_FILE.lock.d" ]
}

@test "an item whose frontmatter already carries a hand-written skip pair is a no-op" {
  inject_at_docs "$STORY_FILE" after 'external_refs_declined: true'
  inject_at_docs "$STORY_FILE" after 'external_refs_declined_note: "Skipped 2026-01-01: user skipped the external link prompt."'
  local before after
  before="$(snapshot)"
  run_link "$STORY_ID" --decline
  [ "$status" -eq 0 ]
  assert_contains "$output" "already declined"
  after="$(snapshot)"
  [ "$before" = "$after" ]
}

@test "declining an item that already has external_refs leaves those entries and every other byte untouched" {
  local id f orig
  for id in "$EPIC_ID" "$STORY_ID" "$TASK_ID"; do
    f="$(file_for "$id")"
    run_link "$id" --system jira --kind issue --key PROJ-1
    [ "$status" -eq 0 ]
    run_link "$id" --system bitbucket --kind repo --url https://bitbucket.org/ws/repo
    [ "$status" -eq 0 ]
    orig="$BATS_TEST_TMPDIR/orig-refs-$id.md"
    cp "$f" "$orig"
    run_link "$id" --decline
    [ "$status" -eq 0 ]
    run diff "$orig" "$f"
    [ "$status" -eq 1 ]
    run grep -c '^<' <<< "$output"
    [ "$output" = "0" ]
    run grep -c '^>' <(diff "$orig" "$f")
    [ "$output" = "2" ]
    # the external_refs block (from its key to the next top-level line) is byte-identical to before
    [ "$(awk '/^external_refs:/{p=1;print;next} p && /^[^ \t]/{p=0} p' "$f")" = "$(awk '/^external_refs:/{p=1;print;next} p && /^[^ \t]/{p=0} p' "$orig")" ]
    grep -q '^    key: PROJ-1$' "$f"
    grep -q '^    url: https://bitbucket.org/ws/repo$' "$f"
    assert_valid "$f"
  done
}

@test "an empty external_refs: [] is left as written when declining" {
  inject_at_docs "$TASK_FILE" after 'external_refs: []'
  local orig="$BATS_TEST_TMPDIR/orig-empty.md"
  cp "$TASK_FILE" "$orig"
  run_link "$TASK_ID" --decline
  [ "$status" -eq 0 ]
  grep -q '^external_refs: \[\]$' "$TASK_FILE"
  run grep -c '^<' <(diff "$orig" "$TASK_FILE")
  [ "$output" = "0" ]
  assert_valid "$TASK_FILE"
}

@test "linking an item that carries a recorded skip is still allowed and keeps the skip fields" {
  run_link "$TASK_ID" --decline
  [ "$status" -eq 0 ]
  run_link "$TASK_ID" --system jira --kind issue --key PROJ-7
  [ "$status" -eq 0 ]
  grep -q '^external_refs_declined: true$' "$TASK_FILE"
  grep -q '^    key: PROJ-7$' "$TASK_FILE"
  assert_valid "$TASK_FILE"
}

@test "decline with any link argument is a usage error that writes nothing and echoes no value" {
  assert_rejected 2 "$TASK_ID" --decline --system jira
  assert_rejected 2 "$TASK_ID" --decline --kind issue
  assert_rejected 2 "$TASK_ID" --decline --key PROJ-1
  assert_rejected 2 "$TASK_ID" --decline --url https://bitbucket.org/ws/repo
  assert_rejected 2 "$TASK_ID" --system jira --kind issue --key PROJ-1 --decline
  assert_rejected 2 "$TASK_ID" --key secretvalue99 --decline
  assert_not_contains "$stderr" "secretvalue99"
  assert_rejected 2 "$TASK_ID" --decline --system ""
  assert_rejected 2 "$TASK_ID" --decline extra
  assert_rejected 2 "$TASK_ID" --decline --token secretvalue99
  assert_not_contains "$stderr" "secretvalue99"
}

@test "decline needs the item id first, and a malformed id is rejected" {
  assert_rejected 2 --decline "$TASK_ID"
  assert_rejected 2 --decline
  assert_rejected 2 e90_s01 --decline
  assert_rejected 2 "../E90" --decline
}

@test "decline on an unknown item id exits 3 with a clear message and writes nothing" {
  assert_rejected 3 E99 --decline
  assert_contains "$stderr" "E99"
  assert_rejected 3 E90_S99 --decline
  assert_rejected 3 E90_S01_T99 --decline
}

@test "decline on an id matching two files is a failure (exit 6) that writes nothing" {
  cp "$STORY_FILE" "$STORIES/E90_S01_duplicate.md"
  assert_rejected 6 "$STORY_ID" --decline
}

@test "there is no link-removal option: --remove and --undecline are rejected, and the script defines none" {
  assert_rejected 2 "$TASK_ID" --remove
  assert_rejected 2 "$TASK_ID" --decline --remove
  assert_rejected 2 "$TASK_ID" --undecline
  run grep -E -- '--(remove|unlink|undecline|delete)' <(grep -v '^[[:space:]]*#' "$LINKER")
  [ "$status" -ne 0 ]
}

@test "decline aborts with exit 4 and writes nothing when the board file's lock is held" {
  mkdir "$TASK_FILE.lock.d"
  local before after
  before="$(snapshot)"
  export WITH_LOCK_TIMEOUT_SECONDS=1 WITH_LOCK_POLL_SECONDS=0.1
  run_link "$TASK_ID" --decline
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "lock"
  after="$(snapshot)"
  [ "$before" = "$after" ]
  [ -d "$TASK_FILE.lock.d" ]
  run grep -c 'external_refs_declined' "$TASK_FILE"
  [ "$output" = "0" ]
}

@test "the decline write happens under with-lock.sh, and the lock is released afterwards" {
  local spy="$BATS_TEST_TMPDIR/spy-decline"
  mkdir -p "$spy/scripts"
  cp "$LINKER" "$REPO_ROOT/scripts/resolve-root.sh" "$REPO_ROOT/scripts/validate-board.sh" "$spy/scripts/"
  printf '#!/usr/bin/env bash\necho "$1" >> "%s/lock-used"\nexec bash "%s/scripts/with-lock.sh" "$@"\n' "$spy" "$REPO_ROOT" > "$spy/scripts/with-lock.sh"
  run --separate-stderr bash "$spy/scripts/link-external-ref.sh" "$TASK_ID" --decline
  [ "$status" -eq 0 ]
  [ "$(basename "$(cat "$spy/lock-used")")" = "E90_S01_T01_fixture-task.md" ]
  [ ! -e "$TASK_FILE.lock.d" ]
  grep -q '^external_refs_declined: true$' "$TASK_FILE"
}

@test "decline preserves trailing comments, quoting and body text byte for byte" {
  run_link "$EPIC_ID" --decline
  [ "$status" -eq 0 ]
  grep -q '^title: Fixture epic   # a trailing comment that must survive$' "$EPIC_FILE"
  grep -q '^docs: \["project/documentation/example.md"\]$' "$EPIC_FILE"
  grep -q '^Body text that must never change.$' "$EPIC_FILE"
  run_link "$STORY_ID" --decline
  [ "$status" -eq 0 ]
  grep -q '^title: "Fixture story"$' "$STORY_FILE"
  grep -q '^depends_on: E90_S00   # kept as written$' "$STORY_FILE"
}

@test "decline on a file with no final newline keeps that property and its body bytes" {
  printf '%s' "$(cat "$STORY_FILE")" > "$STORY_FILE"
  local orig="$BATS_TEST_TMPDIR/orig-decl-nonl.md"
  cp "$STORY_FILE" "$orig"
  [ "$(tail -c1 "$orig" | od -An -c | tr -d ' ')" != '\n' ]
  run_link "$STORY_ID" --decline
  [ "$status" -eq 0 ]
  [ "$(tail -c 14 "$STORY_FILE")" = "$(tail -c 14 "$orig")" ]
  [ "$(tail -c1 "$STORY_FILE" | od -An -c | tr -d ' ')" = "$(tail -c1 "$orig" | od -An -c | tr -d ' ')" ]
  assert_valid "$STORY_FILE"
}

@test "skip markers in a form the script does not recognise are refused untouched (exit 6)" {
  # a value other than true
  inject_at_docs "$TASK_FILE" after 'external_refs_declined: false'
  assert_rejected 6 "$TASK_ID" --decline
  # marker without its note
  write_fixtures
  inject_at_docs "$TASK_FILE" after 'external_refs_declined: true'
  assert_rejected 6 "$TASK_ID" --decline
  # note without its marker
  write_fixtures
  inject_at_docs "$TASK_FILE" after 'external_refs_declined_note: "Skipped 2026-01-01: user skipped the external link prompt."'
  assert_rejected 6 "$TASK_ID" --decline
  # a duplicated marker
  write_fixtures
  inject_at_docs "$TASK_FILE" after 'external_refs_declined: true\nexternal_refs_declined: true\nexternal_refs_declined_note: "Skipped 2026-01-01: x"'
  assert_rejected 6 "$TASK_ID" --decline
}

@test "if the edited file would fail validate-board.sh the decline is restored byte for byte (exit 5)" {
  inject_at_docs "$STORY_FILE" after 'bogus_unknown_key: 1'
  local before after
  before="$(snapshot)"
  run_link "$STORY_ID" --decline
  [ "$status" -eq 5 ]
  assert_contains "$stderr" "restored"
  [ -z "$output" ]
  after="$(snapshot)"
  [ "$before" = "$after" ]
}

@test "decline resolves the board through resolve-root.sh, so a relocated board is found and the live board is untouched" {
  local alt="$BATS_TEST_TMPDIR/alt-decline"
  mkdir -p "$alt/project/configs" "$alt/work/e" "$alt/work/s" "$alt/work/t"
  cat > "$alt/project/configs/workflow.json" <<'EOF'
{"paths":{"epics":"work/e","stories":"work/s","tasks":"work/t"}}
EOF
  cp "$TASK_FILE" "$alt/work/t/E90_S01_T01_moved.md"
  local live_before
  live_before="$(snapshot)"
  export JENGA_PROJECT_ROOT="$alt"
  run_link "$TASK_ID" --decline
  [ "$status" -eq 0 ]
  grep -q '^external_refs_declined: true$' "$alt/work/t/E90_S01_T01_moved.md"
  [ "$live_before" = "$(snapshot)" ]
}

@test "decline is reachable offline: no network tool is called on any decline outcome" {
  run_link "$TASK_ID" --decline
  [ "$status" -eq 0 ]
  run_link "$TASK_ID" --decline
  [ "$status" -eq 0 ]
  run_link "$TASK_ID" --decline --system jira
  [ "$status" -eq 2 ]
  [ ! -e "$NET_SENTINEL" ]
}
