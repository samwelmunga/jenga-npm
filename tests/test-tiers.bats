#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# Coverage for scripts/test-tiers.sh (E95_S02_T01): the tier rule and the check.
#
# Fixture only. A throwaway root under $BATS_TEST_TMPDIR holds a synthetic tests/ of
# tiny .bats files that are never executed (two already tagged tier:fast) and a
# synthetic project/logs/test-timings.jsonl. The script is pointed at it with --root.
# No case runs bats, a suite or the real timing log.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
TIERS="$REPO_ROOT/scripts/test-tiers.sh"

@test "E95_S02_T01: propose applies the tier rule, check names an untagged file, apply makes check pass" {
  local root="$BATS_TEST_TMPDIR/root"
  mkdir -p "$root/tests" "$root/project/logs" "$root/project/configs"
  printf '%s\n' '#!/usr/bin/env bats' '# bats file_tags=tier:fast' '@test "x" { true; }' > "$root/tests/a-fast.bats"
  printf '%s\n' '#!/usr/bin/env bats' '@test "x" { true; }' > "$root/tests/b-slow.bats"
  printf '%s\n' '#!/usr/bin/env bats' '@test "x" { true; }' > "$root/tests/c-untimed.bats"
  printf '%s\n' '#!/usr/bin/env bats' '# jenga:manual-only: takes hours' '@test "x" { true; }' > "$root/tests/d-manual.bats"
  printf '%s\n' '#!/usr/bin/env bats' '# bats file_tags=tier:fast' '@test "x" { true; }' > "$root/tests/pages-workflow.bats"
  printf '%s\n' '{"manual_only_threshold_seconds": 600}' > "$root/project/configs/test-config.json"
  {
    printf '%s\n' '{"date":"2026-10-01T00:00:00Z","suite":"tests/a-fast.bats","duration_ms":1000,"scope":"file"}'
    printf '%s\n' '{"date":"2026-10-01T00:00:00Z","suite":"tests/b-slow.bats","duration_ms":5000,"scope":"file"}'
    printf '%s\n' '{"date":"2026-10-02T00:00:00Z","suite":"tests/b-slow.bats","duration_ms":400000,"scope":"file"}'
    printf '%s\n' '{"date":"2026-10-01T00:00:00Z","suite":"tests/d-manual.bats","duration_ms":2000,"scope":"file"}'
    printf '%s\n' '{"date":"2026-10-01T00:00:00Z","suite":"tests/pages-workflow.bats","duration_ms":4000,"scope":"file"}'
  } > "$root/project/logs/test-timings.jsonl"

  run bash "$TIERS" propose --root "$root"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 5 ]
  [[ "${lines[0]}" == "tests/a-fast.bats"$'\t'"tier:fast"$'\t'* ]]
  [[ "${lines[1]}" == "tests/b-slow.bats"$'\t'"tier:slow"$'\t'*"duration_ms=400000"* ]]
  [[ "${lines[2]}" == "tests/c-untimed.bats"$'\t'"tier:integration"$'\t'"untimed" ]]
  [[ "${lines[3]}" == "tests/d-manual.bats"$'\t'"tier:manual"$'\t'"legacy-marker"* ]]
  [[ "${lines[4]}" == "tests/pages-workflow.bats"$'\t'"tier:unit"$'\t'"fast-tag-excluded"* ]]

  run bash "$TIERS" check --root "$root"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tests/c-untimed.bats"$'\t'"no-tier"* ]]

  run bash "$TIERS" apply --root "$root"
  [ "$status" -eq 0 ]
  [ "$(sed -n 2p "$root/tests/a-fast.bats")" = "# bats file_tags=tier:fast" ]
  run bash "$TIERS" check --root "$root"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
