#!/usr/bin/env bats
#
# E79_S04_T04: scripts/read-external-refs.sh prints the validated Jira key of each matching `external_refs` entry of
# one epic, story or task, one per line in file order, and is strictly read-only. It is the reader that the writer
# scripts/link-external-ref.sh (E71_S04_T01) never had; the field contract is templates/SCRUM_BOARD_SCHEMA.md
# ("External Refs Fields"), and the shapes it must read are the ones scripts/validate-board.sh accepts.
#
# Every case builds its own scratch project under $BATS_TEST_TMPDIR and points JENGA_PROJECT_ROOT at it, so the live
# board is never read or written. Network tools are stubbed on PATH with a sentinel and teardown() asserts none was
# called.
#
# Mirror safety: depends only on scripts/read-external-refs.sh, scripts/resolve-root.sh and fixtures built here.
#
# NOTE for the tester: this file was written by the developer, who does not run tests. It had not been executed when
# it was handed over.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
READER="$REPO_ROOT/scripts/read-external-refs.sh"

# item_file <path> <id> <kind> [<refs-text>] [<tail-frontmatter>]
#   Writes a board item. <refs-text> (real newlines) goes into the frontmatter after `docs: []`; <tail-frontmatter>
#   goes after it, so the block list has to end on a following top-level key. The body always carries a decoy that
#   looks like frontmatter and like an external_refs block, which must never be read.
item_file() {
  local path="$1" id="$2" kind="$3" refs="${4:-}" tail="${5:-}"
  {
    printf -- '---\n'
    printf 'id: %s\n' "$id"
    case "$kind" in
      task) printf 'story_id: E90_S01\nepic_id: E90\n' ;;
      story) printf 'epic_id: E90\n' ;;
    esac
    printf 'title: "Fixture %s"\nstatus: Pending\ndate_created: 2026-10-06\ndocs: []\n' "$kind"
    [ -z "$refs" ] || printf '%s\n' "$refs"
    [ -z "$tail" ] || printf '%s\n' "$tail"
    printf -- '---\n\n# Fixture %s\n\n## Notes\n\nkey: ASD-999\nexternal_refs:\n  - system: jira\n    kind: issue\n    key: ZZZ-999\n' "$kind"
  } > "$path"
}

jira_entry() { # jira_entry <key-text>
  printf '  - system: jira\n    kind: issue\n    key: %s\n    linked_on: 2026-10-06' "$1"
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
  TASK_FILE="$TASKS/E90_S01_T01_fixture-task.md"
  export JENGA_PROJECT_ROOT="$SCRATCH"

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
}

teardown() {
  [ ! -e "$NET_SENTINEL" ]
}

# run_read <args...>: run the reader capturing stdout in $output and stderr in $stderr.
run_read() {
  run --separate-stderr bash "$READER" "$@"
}

# snapshot: every path under the scratch project plus a checksum of every file, so a stray temp file, a lock
# directory or a changed byte all show up.
snapshot() {
  find "$SCRATCH" -print | sort
  find "$SCRATCH" -type f -exec cksum {} + | sort
}

# --- acceptance: one entry per level, several entries ---------------------------------------------------------

@test "an epic carrying one Jira entry prints exactly that key" {
  item_file "$EPICS/E90_fixture-epic.md" E90 epic "external_refs:
$(jira_entry ASD-001)" "epic_scope_approval: false"
  run_read E90
  [ "$status" -eq 0 ]
  [ "$output" = "ASD-001" ]
  [ -z "$stderr" ]
}

@test "a story carrying one Jira entry prints exactly that key" {
  item_file "$STORIES/E90_S01_fixture-story.md" E90_S01 story "external_refs:
$(jira_entry PROJ-123)" "priority: P1"
  run_read E90_S01
  [ "$status" -eq 0 ]
  [ "$output" = "PROJ-123" ]
}

@test "a task carrying one Jira entry prints exactly that key" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs:
$(jira_entry ASD-001)" "assigned_to: developer"
  run_read E90_S01_T01
  [ "$status" -eq 0 ]
  [ "$output" = "ASD-001" ]
}

@test "an item with two Jira entries prints both, in file order" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs:
$(jira_entry ZED-9)
$(jira_entry ABC-1)" "assigned_to: developer"
  run_read E90_S01_T01
  [ "$status" -eq 0 ]
  [ "$output" = "ZED-9
ABC-1" ]
}

@test "a key shared by several tasks is read from each task independently (decision 7: no inheritance here)" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs:
$(jira_entry ASD-001)"
  item_file "$TASKS/E90_S01_T02_second.md" E90_S01_T02 task "external_refs:
$(jira_entry ASD-001)"
  item_file "$TASKS/E90_S01_T03_third.md" E90_S01_T03 task ""
  run_read E90_S01_T01
  [ "$output" = "ASD-001" ]
  run_read E90_S01_T02
  [ "$output" = "ASD-001" ]
  run_read E90_S01_T03
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- acceptance: nothing to print -----------------------------------------------------------------------------

@test "an item with no external_refs prints nothing and exits 0" {
  item_file "$TASK_FILE" E90_S01_T01 task ""
  run_read E90_S01_T01
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "external_refs: [] prints nothing and exits 0" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs: []"
  run_read E90_S01_T01
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "only a confluence or bitbucket entry prints nothing and exits 0" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs:
  - system: confluence
    kind: page
    url: https://example.atlassian.net/wiki/spaces/PROJ/pages/123456
    linked_on: 2026-10-06
  - system: bitbucket
    kind: repo
    url: https://bitbucket.org/ws/repo
    linked_on: 2026-10-06"
  run_read E90_S01_T01
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "a Jira entry mixed with other systems prints only the Jira key" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs:
  - system: confluence
    kind: page
    url: https://example.atlassian.net/wiki/spaces/PROJ/pages/123456
    linked_on: 2026-10-06
$(jira_entry PROJ-7)
  - system: bitbucket
    kind: pull-request
    url: https://bitbucket.org/ws/repo/pull-requests/4
    linked_on: 2026-10-06" "assigned_to: developer"
  run_read E90_S01_T01
  [ "$status" -eq 0 ]
  [ "$output" = "PROJ-7" ]
}

@test "an entry with a url and no key is skipped without a notice" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs:
  - system: jira
    kind: issue
    url: https://example.atlassian.net/browse/ASD-5
    linked_on: 2026-10-06
$(jira_entry ASD-1)"
  run_read E90_S01_T01
  [ "$status" -eq 0 ]
  [ "$output" = "ASD-1" ]
  [ -z "$stderr" ]
}

@test "malformed keys are skipped with a stderr notice and are never printed" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs:
$(jira_entry asd-1)
$(jira_entry 'ASD-001;x')
$(jira_entry 'ASD-')
$(jira_entry '-1')
$(jira_entry 'A-1')
$(jira_entry '')
$(jira_entry ASD-2)"
  run_read E90_S01_T01
  [ "$status" -eq 0 ]
  [ "$output" = "ASD-2" ]
  assert_contains "$stderr" "not a Jira issue key"
  assert_contains "$stderr" "entry 1 "
  assert_contains "$stderr" "entry 2 "
  # The offending values are untrusted: they are never echoed back.
  assert_not_contains "$stderr" "asd-1"
  assert_not_contains "$stderr" "ASD-001"
}

@test "an entry that repeats a key, or has both key and url, is skipped with a notice" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs:
  - system: jira
    kind: issue
    key: AAA-1
    key: BBB-2
    linked_on: 2026-10-06
  - system: jira
    kind: issue
    key: CCC-3
    url: https://example.atlassian.net/browse/CCC-3
    linked_on: 2026-10-06
$(jira_entry DDD-4)"
  run_read E90_S01_T01
  [ "$status" -eq 0 ]
  [ "$output" = "DDD-4" ]
  assert_contains "$stderr" "repeats a key"
  assert_contains "$stderr" "both key and url"
}

@test "quotes, trailing comments, comment lines and blank lines inside the block are handled" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs:
  # a comment inside the block

  - system: \"jira\"
    kind: 'issue'
    key: \"QQQ-11\"   # trailing comment
    linked_on: 2026-10-06
  - system: jira
    kind: issue
    key: RRR-12
    linked_on: 2026-10-06" "assigned_to: developer"
  run_read E90_S01_T01
  [ "$status" -eq 0 ]
  [ "$output" = "QQQ-11
RRR-12" ]
}

@test "an entry whose first line is the key (not system) is still read" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs:
  - key: LLL-5
    system: jira
    kind: issue
    linked_on: 2026-10-06"
  run_read E90_S01_T01
  [ "$output" = "LLL-5" ]
}

@test "a CRLF file is read and prints the bare key" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs:
$(jira_entry CRL-7)" "assigned_to: developer"
  awk '{ printf "%s\r\n", $0 }' "$TASK_FILE" > "$TASK_FILE.crlf"
  mv "$TASK_FILE.crlf" "$TASK_FILE"
  run_read E90_S01_T01
  [ "$status" -eq 0 ]
  [ "$output" = "CRL-7" ]
}

@test "an inline (non-block) external_refs value is skipped with a notice" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs: [ASD-1, ASD-2]"
  run_read E90_S01_T01
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  assert_contains "$stderr" "not a block list"
  assert_not_contains "$stderr" "ASD-1"
}

# --- acceptance: declined markers -----------------------------------------------------------------------------

@test "external_refs_declined: true prints nothing and exits 0" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs_declined: true
external_refs_declined_note: \"Skipped 2026-10-06: user skipped the external link prompt.\""
  run_read E90_S01_T01
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "a declined marker and an empty list together print nothing" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs: []
external_refs_declined: true
external_refs_declined_note: \"Skipped 2026-10-06: user skipped the external link prompt.\""
  run_read E90_S01_T01
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the declined marker is not an entry; entries linked after a skip are still printed" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs:
$(jira_entry LAT-3)
external_refs_declined: true
external_refs_declined_note: \"Skipped 2026-10-06: user skipped the external link prompt.\""
  run_read E90_S01_T01
  [ "$status" -eq 0 ]
  [ "$output" = "LAT-3" ]
}

# --- acceptance: missing and ambiguous items ------------------------------------------------------------------

@test "a nonexistent id exits 3 with empty stdout (never reads as no refs)" {
  item_file "$TASK_FILE" E90_S01_T01 task ""
  run_read E90_S01_T09
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
}

@test "an id matching two files exits 3 with empty stdout" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs:
$(jira_entry ASD-1)"
  item_file "$TASKS/E90_S01_T01_duplicate.md" E90_S01_T01 task "external_refs:
$(jira_entry ASD-2)"
  run_read E90_S01_T01
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  assert_contains "$stderr" "more than one file"
}

@test "an id file plus the bare <id>.md form is also ambiguous" {
  item_file "$EPICS/E90_fixture-epic.md" E90 epic "external_refs:
$(jira_entry ASD-1)"
  item_file "$EPICS/E90.md" E90 epic ""
  run_read E90
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "the bare <id>.md form alone is found" {
  item_file "$EPICS/E90.md" E90 epic "external_refs:
$(jira_entry BAR-1)"
  run_read E90
  [ "$status" -eq 0 ]
  [ "$output" = "BAR-1" ]
}

@test "an id is never prefix-matched against a longer id" {
  item_file "$EPICS/E901_other-epic.md" E901 epic "external_refs:
$(jira_entry ASD-1)"
  run_read E90
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "a scratch root without a registry exits 3 with empty stdout" {
  export JENGA_PROJECT_ROOT="$BATS_TEST_TMPDIR/not-a-project"
  mkdir -p "$JENGA_PROJECT_ROOT"
  run_read E90_S01_T01
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "an item whose board directory is missing exits 3" {
  rm -rf "$TASKS"
  run_read E90_S01_T01
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

# --- acceptance: read-only, scratch board ---------------------------------------------------------------------

@test "the board file and the whole scratch tree are byte-identical after every kind of run" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs:
$(jira_entry ASD-1)
$(jira_entry 'bad key')"
  item_file "$EPICS/E90_fixture-epic.md" E90 epic "external_refs: []"
  before="$(snapshot)"
  run_read E90_S01_T01
  run_read E90_S01_T01 --system jira --kind issue
  run_read E90_S01_T01 --system confluence
  run_read E90
  run_read E90_S01_T09
  run_read nonsense
  run_read
  after="$(snapshot)"
  [ "$before" = "$after" ]
}

@test "no lock file, temp file or lock directory appears next to the board file" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs:
$(jira_entry ASD-1)"
  run_read E90_S01_T01
  [ "$status" -eq 0 ]
  run find "$TASKS" -mindepth 1
  [ "$output" = "$TASK_FILE" ]
}

@test "a read-only board file can be read (the script never needs write access)" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs:
$(jira_entry ASD-1)"
  chmod 444 "$TASK_FILE"
  chmod 555 "$TASKS"
  run_read E90_S01_T01
  chmod 755 "$TASKS"
  [ "$status" -eq 0 ]
  [ "$output" = "ASD-1" ]
}

@test "JENGA_PROJECT_ROOT redirects the lookup and the script runs from any working directory" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs:
$(jira_entry SCR-42)"
  cd "$BATS_TEST_TMPDIR"
  run_read E90_S01_T01
  [ "$status" -eq 0 ]
  [ "$output" = "SCR-42" ]
}

@test "this repository's own board is not touched by a scratch-board run" {
  live="$(ls "$REPO_ROOT"/project/board/tasks/E79_S04_T04_*.md 2>/dev/null | head -n 1)"
  [ -n "$live" ] || skip "live task file not present in this checkout"
  before="$(cksum "$live")"
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs:
$(jira_entry ASD-1)"
  run_read E90_S01_T01
  [ "$status" -eq 0 ]
  [ "$(cksum "$live")" = "$before" ]
}

# --- acceptance: body and structure ---------------------------------------------------------------------------

@test "a body line shaped like frontmatter, and a body external_refs block, are never read" {
  item_file "$TASK_FILE" E90_S01_T01 task ""
  # The fixture's body already carries `key: ASD-999` and a ZZZ-999 block.
  grep -q '^key: ASD-999$' "$TASK_FILE"
  grep -q 'key: ZZZ-999' "$TASK_FILE"
  run_read E90_S01_T01
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run_read E90_S01_T01 --system jira --kind issue
  [ -z "$output" ]
}

@test "a frontmatter entry is printed and the body decoy beside it is not" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs:
$(jira_entry REA-1)"
  run_read E90_S01_T01
  [ "$output" = "REA-1" ]
}

@test "a file with no closing --- exits 4 with empty stdout and does not read the body" {
  printf -- '---\nid: E90_S01_T01\nexternal_refs:\n  - system: jira\n    kind: issue\n    key: OPN-1\n' > "$TASK_FILE"
  run_read E90_S01_T01
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  assert_contains "$stderr" "no closing"
}

@test "a file with no opening --- exits 4 with empty stdout" {
  printf 'id: E90_S01_T01\nexternal_refs:\n  - system: jira\n    kind: issue\n    key: NOF-1\n---\n' > "$TASK_FILE"
  run_read E90_S01_T01
  [ "$status" -eq 4 ]
  [ -z "$output" ]
}

@test "a repeated external_refs key exits 4 with empty stdout" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs:
$(jira_entry ASD-1)
external_refs:
$(jira_entry ASD-2)"
  run_read E90_S01_T01
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  assert_contains "$stderr" "more than once"
}

@test "an empty file exits 4 with empty stdout" {
  : > "$TASK_FILE"
  run_read E90_S01_T01
  [ "$status" -eq 4 ]
  [ -z "$output" ]
}

# --- filters --------------------------------------------------------------------------------------------------

@test "--system jira --kind issue behaves like the defaults for a Jira issue entry" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs:
$(jira_entry ASD-1)"
  run_read E90_S01_T01 --system jira --kind issue
  [ "$status" -eq 0 ]
  [ "$output" = "ASD-1" ]
}

@test "--kind filters on the entry's kind" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs:
$(jira_entry ASD-1)"
  run_read E90_S01_T01 --kind page
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--system confluence prints nothing because confluence entries carry a url, not a key" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs:
  - system: confluence
    kind: page
    url: https://example.atlassian.net/wiki/spaces/PROJ/pages/123456
    linked_on: 2026-10-06
$(jira_entry ASD-1)"
  run_read E90_S01_T01 --system confluence
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "options may come in either order and --system=value style is refused" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs:
$(jira_entry ASD-1)"
  run_read E90_S01_T01 --kind issue --system jira
  [ "$output" = "ASD-1" ]
  run_read E90_S01_T01 --system=jira
  [ "$status" -eq 2 ]
}

# --- untrusted data -------------------------------------------------------------------------------------------

@test "shell metacharacters in a key are never executed, never printed" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs:
$(jira_entry '"$(touch '"$BATS_TEST_TMPDIR"'/pwned)"')
$(jira_entry '`touch '"$BATS_TEST_TMPDIR"'/pwned2`')
$(jira_entry 'ASD-1$(id)')
$(jira_entry 'ASD-1`id`')
$(jira_entry 'ASD-1 && id')
$(jira_entry 'ASD-1|id')
$(jira_entry 'ASD-1;id')
$(jira_entry 'ASD-1\\nASD-2')
$(jira_entry ASD-3)"
  run_read E90_S01_T01
  [ "$status" -eq 0 ]
  [ "$output" = "ASD-3" ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned2" ]
  assert_not_contains "$stderr" 'touch'
  assert_not_contains "$stderr" '$(id)'
}

@test "a key with trailing junk or an embedded space is not a key" {
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs:
  - system: jira
    kind: issue
    key: \"ASD-1 x\"
    linked_on: 2026-10-06
  - system: jira
    kind: issue
    key: ASD-0123456789012345678901234567890-1x
    linked_on: 2026-10-06"
  run_read E90_S01_T01
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an item id with shell metacharacters or path parts is a usage error, not a lookup" {
  run_read 'E90;touch pwned'
  [ "$status" -eq 2 ]
  run_read '../E90'
  [ "$status" -eq 2 ]
  run_read 'E90_S01_T01*'
  [ "$status" -eq 2 ]
  run_read 'e90'
  [ "$status" -eq 2 ]
  run_read 'E90_T01'
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ ! -e pwned ]
}

# --- usage errors ---------------------------------------------------------------------------------------------

@test "usage errors exit 2 with empty stdout" {
  run_read
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run_read --system jira E90_S01_T01
  [ "$status" -eq 2 ]
  run_read E90_S01_T01 --system
  [ "$status" -eq 2 ]
  run_read E90_S01_T01 --kind
  [ "$status" -eq 2 ]
  run_read E90_S01_T01 --system bogus
  [ "$status" -eq 2 ]
  run_read E90_S01_T01 --kind 'Issue;x'
  [ "$status" -eq 2 ]
  run_read E90_S01_T01 --frobnicate
  [ "$status" -eq 2 ]
  run_read E90_S01_T01 extra
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "an unknown option is named in the error but a value is never echoed" {
  run_read E90_S01_T01 --token=sekrit-value
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "--token"
  assert_not_contains "$stderr" "sekrit-value"
}

@test "-h and --help print the usage and exit 0" {
  run_read -h
  [ "$status" -eq 0 ]
  assert_output_contains "read-external-refs.sh <item-id>"
  run_read --help
  [ "$status" -eq 0 ]
  assert_output_contains "Exit codes"
}

# --- static properties ----------------------------------------------------------------------------------------

@test "the script passes bash -n" {
  run bash -n "$READER"
  [ "$status" -eq 0 ]
}

@test "the script uses no bash 4 feature and no yq, jq, eval, network or write command" {
  code="$(grep -v '^[[:space:]]*#' "$READER")"
  run grep -nE 'mapfile|readarray|declare -A|local -A|\$\{[A-Za-z_]+(,,|\^\^|,|\^)\}|;;&|;&|&>>|\|&|coproc' <<<"$code"
  [ "$status" -eq 1 ]
  run grep -nE '(^|[^A-Za-z_-])(yq|jq|eval|curl|wget|mktemp|touch|tee|rm|mv|cp|chmod|mkdir|rmdir|ln)[[:space:]]' <<<"$code"
  [ "$status" -eq 1 ]
  run grep -nE 'with-lock|flock|git[[:space:]]' <<<"$code"
  [ "$status" -eq 1 ]
}

@test "the script runs under the system bash (3.2 on macOS)" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  item_file "$TASK_FILE" E90_S01_T01 task "external_refs:
$(jira_entry ASD-1)
$(jira_entry ASD-2)"
  run --separate-stderr /bin/bash "$READER" E90_S01_T01
  [ "$status" -eq 0 ]
  [ "$output" = "ASD-1
ASD-2" ]
}
