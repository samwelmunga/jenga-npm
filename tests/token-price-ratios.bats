#!/usr/bin/env bats
# bats file_tags=tier:unit
#
# E90_S01_T02: scripts/token-price-ratios.sh answers "ratios, version and date for a model id" from
# project/configs/token-price-ratios.json (or $JENGA_PRICE_RATIOS_FILE), and never guesses.
# Exit codes: 0 ok, 2 usage, 4 no ratios for the model, 5 config missing, 6 config malformed.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/token-price-ratios.sh"

setup() {
  CFG="$BATS_TEST_TMPDIR/ratios.json"
  cat > "$CFG" <<'EOF'
{"config_version": 7, "date": "2026-01-02",
 "models": {
   "model-a": {"input": 1, "cache_write_5m": 1.25, "cache_write_1h": 2, "cache_read": 0.1, "output": 5},
   "model-a-lite": {"input": 1, "cache_write_5m": 1.5, "cache_write_1h": 3, "cache_read": 0.2, "output": 4}
 }}
EOF
  export JENGA_PRICE_RATIOS_FILE="$CFG"
}

@test "known model prints ratios, version and date, exit 0" {
  run --separate-stderr bash "$SCRIPT" model-a
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.version == 7 and .date == "2026-01-02" and .matched == "model-a"
    and .ratios == {"input":1,"cache_write_5m":1.25,"cache_write_1h":2,"cache_read":0.1,"output":5}' >/dev/null
}

@test "date-suffixed id matches its base model exactly (suffix stripped once)" {
  run --separate-stderr bash "$SCRIPT" model-a-20261119
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.model == "model-a-20261119" and .matched == "model-a" and .ratios.output == 5' >/dev/null
}

@test "a date suffix does not cross to a longer or family model" {
  run --separate-stderr bash "$SCRIPT" model-a-lite-20261119
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.matched == "model-a-lite" and .ratios.output == 4' >/dev/null
}

@test "unknown model: exit 4, message on stderr, nothing on stdout, no fallback" {
  run --separate-stderr bash "$SCRIPT" model-b
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  [[ "$stderr" == *"no ratios for model-b"* ]]
}

@test "a bare prefix or a non-date suffix is not matched" {
  run --separate-stderr bash "$SCRIPT" model
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  run --separate-stderr bash "$SCRIPT" model-a-2026111
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  run --separate-stderr bash "$SCRIPT" model-a-x
  [ "$status" -eq 4 ]
}

@test "missing config: exit 5, nothing on stdout" {
  export JENGA_PRICE_RATIOS_FILE="$BATS_TEST_TMPDIR/absent.json"
  run --separate-stderr bash "$SCRIPT" model-a
  [ "$status" -eq 5 ]
  [ -z "$output" ]
  [[ "$stderr" == *"missing"* ]]
}

@test "malformed config (invalid JSON): exit 6, nothing on stdout" {
  echo '{ not json' > "$CFG"
  run --separate-stderr bash "$SCRIPT" model-a
  [ "$status" -eq 6 ]
  [ -z "$output" ]
}

@test "malformed config (entry lacks a ratio): exit 6" {
  echo '{"config_version":1,"date":"2026-01-02","models":{"model-a":{"input":1}}}' > "$CFG"
  run --separate-stderr bash "$SCRIPT" model-a
  [ "$status" -eq 6 ]
  [ -z "$output" ]
}

@test "malformed config (more than two decimals, or no version): exit 6" {
  echo '{"config_version":1,"date":"d","models":{"model-a":{"input":1,"cache_write_5m":1.255,"cache_write_1h":2,"cache_read":0.1,"output":5}}}' > "$CFG"
  run --separate-stderr bash "$SCRIPT" model-a
  [ "$status" -eq 6 ]
  echo '{"date":"d","models":{}}' > "$CFG"
  run --separate-stderr bash "$SCRIPT" model-a
  [ "$status" -eq 6 ]
}

@test "usage error: no argument or an option: exit 2" {
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" --help
  [ "$status" -eq 2 ]
}

@test "shipped config is valid and prices the story's initial ratios" {
  unset JENGA_PRICE_RATIOS_FILE
  run --separate-stderr bash "$SCRIPT" claude-sonnet-5-5-20261119
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ratios == {"input":1,"cache_write_5m":1.25,"cache_write_1h":2,"cache_read":0.1,"output":5}
    and (.version | type == "number") and (.date | length > 0)' >/dev/null
  jq -e '.notes.cache_write_1h | (.source | length > 0) and .retrieved == "2026-11-19"' \
    "$REPO_ROOT/project/configs/token-price-ratios.json" >/dev/null
}

@test "script passes bash -n" {
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}
