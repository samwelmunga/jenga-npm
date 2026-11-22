#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# E92_S01_T02: the status-to-bucket table of scripts/board-progress.sh (contract: project/documentation/
# progress-visualisation.md sections 3-5). Every test runs against the throwaway fixture board built by
# tests/helpers/progress-fixture.bash and never reads the live project/board/.
#
# The fixture's epic E06 holds one story per status, each with exactly one task carrying that status, so
# `--story E06_S<nn>` isolates the nn-th status of PF_STATUSES (the 14 of the schema, then "Not Started").

bats_require_minimum_version 1.5.0

load helpers/assertions
load helpers/progress-fixture

setup() { pf_setup; }

# bucket_of <status-number>: runs the script for the isolated status and prints "<bucket>" when exactly one bucket
# holds exactly one item and the denominator agrees; prints the totals object otherwise.
isolate() { # <n> -> sets PF_RC, $PF_OUT
  pf_run --story "E06_S$(printf '%02d' "$1")"
}

# assert_bucket <n> <bucket> <expected-denominator>
assert_bucket() {
  local n="$1" bucket="$2" denom="$3" b got
  isolate "$n"
  [ "$PF_RC" -eq 0 ]
  for b in done in_progress failed pending rejected unknown; do
    got="$(pf_py "d['levels']['tasks']['totals']['$b']")"
    if [ "$b" = "$bucket" ]; then
      [ "$got" = "1" ] || { echo "status #$n ($(pf_status_at "$n")): bucket $b is $got, want 1"; return 1; }
    else
      [ "$got" = "0" ] || { echo "status #$n ($(pf_status_at "$n")): bucket $b is $got, want 0"; return 1; }
    fi
  done
  got="$(pf_py "d['levels']['tasks']['totals']['denominator']")"
  [ "$got" = "$denom" ] || { echo "status #$n: denominator $got, want $denom"; return 1; }
}

@test "the fixture has one task for each of the 14 statuses plus one unknown" {
  pf_run --story E01_S01 --items
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "len(d['levels']['tasks']['items'])")" = "15" ]
  [ "$(pf_py "d['levels']['tasks']['totals']['unknown']")" = "1" ]
}

@test "bucket pending: Pending and Backlog" {
  assert_bucket 1 pending 1   # Pending
  assert_bucket 8 pending 1   # Backlog
}

@test "bucket in_progress: In Progress" {
  assert_bucket 2 in_progress 1
}

@test "bucket done: Passed, Passed with remarks, Done and the five lifecycle statuses" {
  assert_bucket 3 done 1    # Passed
  assert_bucket 4 done 1    # Passed with remarks
  assert_bucket 9 done 1    # Done
  assert_bucket 10 done 1   # Merged
  assert_bucket 11 done 1   # Publicized
  assert_bucket 12 done 1   # Privatized
  assert_bucket 13 done 1   # Deployed to Stage
  assert_bucket 14 done 1   # Deployed to Prod
}

@test "bucket failed: Failed and Blocked" {
  assert_bucket 5 failed 1
  assert_bucket 7 failed 1
}

@test "bucket rejected: Rejected is in no numerator and no denominator" {
  assert_bucket 6 rejected 0
}

@test "unknown status is counted, warned about, and kept out of the denominator" {
  assert_bucket 15 unknown 0
  [ "$(pf_py "d['levels']['tasks']['counts']")" = '{"Not Started":1}' ]
  [ "$(pf_py "d['warnings']")" = '[{"kind":"unknown_status","id":"E06_S15_T01","detail":"status \"Not Started\" is not in the status table"}]' ]
  [ ! -s "$PF_ERR" ]
}

@test "all 15 statuses of one story: counts in table order, totals add up, one unknown warning" {
  pf_run --story E01_S01
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "list(d['levels']['tasks']['counts'])")" = '["Pending","In Progress","Passed","Passed with remarks","Failed","Rejected","Blocked","Backlog","Done","Merged","Publicized","Privatized","Deployed to Stage","Deployed to Prod","Not Started"]' ]
  [ "$(pf_py "d['levels']['tasks']['totals']")" = '{"done":8,"in_progress":1,"failed":2,"pending":2,"rejected":1,"unknown":1,"denominator":13}' ]
  [ "$(pf_py "[w['kind'] for w in d['warnings']]")" = '["unknown_status"]' ]
}

@test "the Rejected rule: 3 Passed, 1 Rejected, 1 Pending gives done 3, pending 1, rejected 1, denominator 4" {
  pf_run --story E01_S02
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "d['levels']['tasks']['totals']")" = '{"done":3,"in_progress":0,"failed":0,"pending":1,"rejected":1,"unknown":0,"denominator":4}' ]
}

@test "the table is level-independent: stories use the same buckets as tasks" {
  pf_run --epic E06
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "d['levels']['stories']['totals']")" = '{"done":8,"in_progress":1,"failed":2,"pending":2,"rejected":1,"unknown":1,"denominator":13}' ]
  [ "$(pf_py "d['levels']['tasks']['totals']")" = '{"done":8,"in_progress":1,"failed":2,"pending":2,"rejected":1,"unknown":1,"denominator":13}' ]
  [ "$(pf_py "[w['id'] for w in d['warnings']]")" = '["E06_S15","E06_S15_T01"]' ]
}

@test "frontmatter quirks: quoted status, CRLF file, status line in the body, id taken from the file name" {
  pf_run --story E05_S01 --items
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "[[i['id'], i['status']] for i in d['levels']['tasks']['items']]")" = '[["E05_S01_T01","Passed"],["E05_S01_T02","Pending"],["E05_S01_T03","Passed"],["E05_S01_T04","Merged"]]' ]
}

@test "the status table is one delimited block that matches the schema's Status Values" {
  local script="$BATS_TEST_DIRNAME/../scripts/board-progress.sh" schema="$BATS_TEST_DIRNAME/../templates/SCRUM_BOARD_SCHEMA.md"
  [ "$(grep -c 'STATUS TABLE BEGIN' "$script")" -eq 1 ]
  [ "$(grep -c 'STATUS TABLE END' "$script")" -eq 1 ]
  # Every "<status>|<bucket>" row of the script (the first row carries the STATUS_TABLE=' prefix, the last a closing
  # quote) must lie between the banners: as many rows in the block as in the whole file, and exactly 14.
  awk -v q="'" '
    { line = $0; sub("^STATUS_TABLE=" q, "", line); sub(q "$", "", line) }
    /STATUS TABLE BEGIN/ { inside = 1; next }
    /STATUS TABLE END/ { inside = 0; next }
    line ~ /^[A-Z][A-Za-z ]*\|(done|pending|in_progress|failed|rejected)$/ { all++; if (inside) blk++; split(line, a, "|"); print a[1] > "'"$BATS_TEST_TMPDIR"'/script.txt" }
    END { print all + 0, blk + 0 }
  ' "$script" > "$BATS_TEST_TMPDIR/rows.txt"
  [ "$(cat "$BATS_TEST_TMPDIR/rows.txt")" = "14 14" ]
  # a status name is mapped nowhere else in the script
  [ "$(grep -c 'Deployed to Prod' "$script")" -eq 1 ]
  # the 14 statuses are exactly the schema's, in the schema's order
  if [ -f "$schema" ]; then
    awk '/^## Status Values/{f=1;next} f&&/^### /{exit} f&&/^\| `/{ s=$0; sub(/^\| `/,"",s); sub(/`.*/,"",s); print s }' "$schema" > "$BATS_TEST_TMPDIR/schema.txt"
    diff "$BATS_TEST_TMPDIR/schema.txt" "$BATS_TEST_TMPDIR/script.txt"
  fi
}
