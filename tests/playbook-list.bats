#!/usr/bin/env bats
#
# Coverage for skills/j-playbook/scripts/playbook-list.sh (E53_S06_T07): the ranked_list rendering of
# bare `j.playbook` and the number-to-id resolution of `j.playbook <n>`.
#
# Every test points JENGA_PLAYBOOK_LOADER at a fixture loader that prints a fixed catalog, so the
# assertions describe the script's behaviour and not whatever playbooks this repository ships today.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/j-playbook/scripts/playbook-list.sh"
PER_LINE='^[0-9]+\. [^[:space:]]+ — .+$'

setup() {
  FIXTURE_LOADER="$BATS_TEST_TMPDIR/loader.sh"
  cat > "$FIXTURE_LOADER" <<'LOADER'
#!/usr/bin/env bash
cat <<'JSON'
[
  {"id":"alpha-flow","name":"Alpha Flow","source":"builtin","steps":["j-brainstorm","j-todo"]},
  {"id":"beta-flow","name":"Beta Flow","source":"project","steps":["j-uncharted",{"skill":"j-do","instruction":"x"},{"playbook":"alpha-flow"}]},
  {"id":"gamma-flow","name":"Gamma Flow","source":"builtin","steps":["j-commit"]}
]
JSON
LOADER
  export JENGA_PLAYBOOK_LOADER="$FIXTURE_LOADER"
}

@test "render prints one 1-indexed line per playbook and nothing else" {
  run bash "$SCRIPT" render
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  assert_starts_with "${lines[0]}" "1. alpha-flow — "
  assert_starts_with "${lines[1]}" "2. beta-flow — "
  assert_starts_with "${lines[2]}" "3. gamma-flow — "
}

@test "render: every line passes the ranked_list per_line verify pattern of templates/playbook-types.json" {
  pattern="$(jq -r '.types.ranked_list.verify.per_line' "$REPO_ROOT/templates/playbook-types.json")"
  [ "$pattern" = "$PER_LINE" ]
  run bash "$SCRIPT" render
  [ "$status" -eq 0 ]
  for line in "${lines[@]}"; do
    printf '%s\n' "$line" | grep -Eq "$pattern"
  done
}

@test "render keeps each playbook's source and steps in the line text" {
  run bash "$SCRIPT" render
  [ "$status" -eq 0 ]
  assert_contains "${lines[0]}" "Alpha Flow (built-in)"
  assert_contains "${lines[0]}" "steps: j-brainstorm -> j-todo"
  assert_contains "${lines[1]}" "Beta Flow (project)"
  assert_contains "${lines[1]}" "steps: j-uncharted -> j-do -> alpha-flow"
}

@test "render on an empty catalog prints nothing and exits 0" {
  printf '#!/usr/bin/env bash\necho "[]"\n' > "$FIXTURE_LOADER"
  run bash "$SCRIPT" render
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "resolve maps a number to the id of the same position render prints" {
  run bash "$SCRIPT" resolve 2
  [ "$status" -eq 0 ]
  [ "$output" = "beta-flow" ]
  run bash "$SCRIPT" render
  [ "$status" -eq 0 ]
  second_id="$(printf '%s' "${lines[1]}" | sed -E 's/^[0-9]+\. ([^ ]+) — .*/\1/')"
  [ "$second_id" = "beta-flow" ]
}

@test "resolve accepts the first and last positions" {
  run bash "$SCRIPT" resolve 1
  [ "$status" -eq 0 ]
  [ "$output" = "alpha-flow" ]
  run bash "$SCRIPT" resolve 3
  [ "$status" -eq 0 ]
  [ "$output" = "gamma-flow" ]
}

@test "resolve out of range exits 1 and reports the valid range" {
  run bash "$SCRIPT" resolve 4
  [ "$status" -eq 1 ]
  assert_contains "$output" "valid range is 1-3"
  run bash "$SCRIPT" resolve 0
  [ "$status" -eq 1 ]
  assert_contains "$output" "valid range is 1-3"
}

@test "resolve rejects a non-numeric argument with exit 1" {
  run bash "$SCRIPT" resolve alpha-flow
  [ "$status" -eq 1 ]
  assert_contains "$output" "valid range is 1-3"
}

@test "resolve on an empty catalog says the catalog is empty" {
  printf '#!/usr/bin/env bash\necho "[]"\n' > "$FIXTURE_LOADER"
  run bash "$SCRIPT" resolve 1
  [ "$status" -eq 1 ]
  assert_contains "$output" "the catalog is empty"
}

@test "a failing catalog loader exits 2 rather than printing a partial listing" {
  printf '#!/usr/bin/env bash\nexit 7\n' > "$FIXTURE_LOADER"
  run bash "$SCRIPT" render
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" resolve 1
  [ "$status" -eq 2 ]
}

@test "usage errors exit 2" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" resolve
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" bogus
  [ "$status" -eq 2 ]
}

@test "against the real catalog, resolve N and render line N agree for every N" {
  unset JENGA_PLAYBOOK_LOADER
  run bash "$SCRIPT" render
  [ "$status" -eq 0 ]
  total="${#lines[@]}"
  [ "$total" -ge 1 ]
  listing=("${lines[@]}")
  for ((i = 1; i <= total; i++)); do
    id_from_line="$(printf '%s' "${listing[$((i - 1))]}" | sed -E 's/^[0-9]+\. ([^ ]+) — .*/\1/')"
    run bash "$SCRIPT" resolve "$i"
    [ "$status" -eq 0 ]
    [ "$output" = "$id_from_line" ]
  done
}
