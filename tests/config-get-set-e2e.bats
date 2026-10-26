#!/usr/bin/env bats
#
# End-to-end get/set coverage for `jenga config` across all six project/configs files (E68_S03_T01).
#
# tests/config-command.bats (E68_S02_T04) pins the command's mechanics with hand-picked keys. This file is the
# story-level matrix: it is DATA-DRIVEN over the shipped descriptors (templates/config-descriptors/*.json, read with
# jq at test time), so a newly added editable key, a new read-only key or a new config file is exercised the moment
# its descriptor lands, with no edit here.
#
# Contract under test: project/documentation/config-descriptors.md (exit codes 0/2/3/4/5/6, descriptor fields) and
# the E68_S03 acceptance criteria:
#   - get and set against a scratch copy of each of the six config files, asserting resulting file contents,
#     stdout, exit codes and version bumps
#   - a failed validation (wrong type, below min, above max, outside allowed, failing pattern) leaves EVERY config
#     file byte-identical (cmp)
#   - read-only keys are rejected by set with exit 5 and no version counter changes anywhere
#   - threshold_version / config_version move by exactly 1 per successful set, and not at all for an unchanged value
#
# Isolation. setup() builds a scratch project under $BATS_TEST_TMPDIR holding COPIES of this repo's six real config
# files and points JENGA_PROJECT_ROOT at it (the same project-root override tests/config-command.bats uses, read by
# scripts/resolve-root.sh). The repo's own project/configs/ is only ever READ; the last test checksums it around a
# set/get session to prove it. The real binary (node bin/jenga.js config ...) runs every case: no model, no network,
# no stubbed service.
#
# The shipped descriptors declare integer editable keys with no `allowed`/`pattern` rule, plus (E72_S01_T04) two
# editable string keys on test-config that carry `allowed` and `pattern` and no version counter. The boolean branch
# and the integer `allowed` branch, and the counter bump on a string key, run against a FIXTURE descriptor set (a
# scratch copy of the shipped descriptors plus extra keys, selected with JENGA_CONFIG_DESCRIPTORS_DIR). The
# data-driven integer matrices below skip the string keys; test-config's string keys have their own cases.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
JENGA="$REPO_ROOT/bin/jenga.js"
DESCRIPTORS="$REPO_ROOT/templates/config-descriptors"
CONFIG_FILES="scope-thresholds playbook-config checklists workflow test-config audit-config"

setup() {
  PROJ="$BATS_TEST_TMPDIR/proj"
  CFG="$PROJ/project/configs"
  mkdir -p "$CFG"
  cp "$REPO_ROOT"/project/configs/*.json "$CFG/"
  # audit-config is exercised from the shipped template, so this repository's own (stricter) setting never shifts the expected values
  cp "$REPO_ROOT/skills/j-init/assets/audit-config_template.json" "$CFG/audit-config.json"
  export JENGA_PROJECT_ROOT="$PROJ"
  unset JENGA_CONFIG_DESCRIPTORS_DIR
  # Safety net: nothing below may ever write to the repo's own configs.
  case "$JENGA_PROJECT_ROOT" in "$BATS_TEST_TMPDIR"/*) ;; *) echo "scratch root escaped the temp dir" >&2; return 1 ;; esac
  cd "$BATS_TEST_TMPDIR"
}

# --- helpers ----------------------------------------------------------------------------------------------------

# snap: keep a pre-copy of every scratch config, to compare against with cmp.
snap() {
  rm -rf "$BATS_TEST_TMPDIR/snap"
  mkdir -p "$BATS_TEST_TMPDIR/snap"
  cp "$CFG"/*.json "$BATS_TEST_TMPDIR/snap/"
}

# unchanged <file-id>: the scratch config is byte-identical to its snapshot.
unchanged() {
  cmp "$BATS_TEST_TMPDIR/snap/$1.json" "$CFG/$1.json"
}

# all_unchanged: every scratch config is byte-identical to its snapshot.
all_unchanged() {
  local f
  for f in "$CFG"/*.json; do
    cmp "$BATS_TEST_TMPDIR/snap/$(basename "$f")" "$f" || return 1
  done
}

# jc <args...>: run `jenga config`, keeping stdout in $output and stderr in $stderr.
jc() {
  run --separate-stderr node "$JENGA" config "$@"
}

# cfgval <file-id> <key>: the current value of a scratch config key, as raw text (compact JSON for nested values).
cfgval() {
  jq -r --arg k "$2" '.[$k] | if type == "string" then . else tojson end' "$CFG/$1.json"
}

# editable_keys <descriptors-dir>: one "<file-id> <key>" line per editable key of every descriptor.
editable_keys() {
  jq -r '(.file | sub("\\.json$"; "")) as $f | .keys[] | select(.editable) | "\($f) \(.key)"' "$1"/*.json
}

# readonly_keys <descriptors-dir>: one "<file-id> <key>" line per read-only key of every descriptor.
readonly_keys() {
  jq -r '(.file | sub("\\.json$"; "")) as $f | .keys[] | select(.editable | not) | "\($f) \(.key)"' "$1"/*.json
}

# dkey <descriptors-dir> <file-id> <key> <jq-expression>: evaluate a jq expression on one descriptor key entry.
dkey() {
  jq -r --arg k "$3" ".keys[] | select(.key == \$k) | $4" "$1/$2.json"
}

# other_value_for <file-id> <key>: a legal integer value different from the current one (min, else max).
other_value_for() {
  local cur min max
  cur=$(cfgval "$1" "$2")
  min=$(dkey "$DESCRIPTORS" "$1" "$2" '.min')
  max=$(dkey "$DESCRIPTORS" "$1" "$2" '.max')
  if [ "$cur" != "$min" ]; then echo "$min"; else echo "$max"; fi
}

# make_fixture_descriptors: a scratch descriptor dir = the shipped descriptors plus extra editable keys on
# playbook-config (an integer with `allowed`, a string with `allowed`, a string with `pattern`, a boolean), each
# bumping config_version, and the matching keys added to the scratch playbook-config.json.
make_fixture_descriptors() {
  local d="$BATS_TEST_TMPDIR/fixture-descriptors"
  mkdir -p "$d"
  cp "$DESCRIPTORS"/*.json "$d/"
  jq '.keys += [
    {"key":"tier","label":"Tier","type":"integer","description":"Fixture integer with an allowed set.","editable":true,"default":1,"min":1,"max":5,"allowed":[1,2,3],"bump_on_change":"config_version"},
    {"key":"mode","label":"Mode","type":"string","description":"Fixture string with an allowed set.","editable":true,"default":"fast","allowed":["fast","slow"],"bump_on_change":"config_version"},
    {"key":"slug","label":"Slug","type":"string","description":"Fixture string with a pattern.","editable":true,"default":"abc","pattern":"^[a-z]+$","bump_on_change":"config_version"},
    {"key":"verbose","label":"Verbose","type":"boolean","description":"Fixture boolean.","editable":true,"default":false,"bump_on_change":"config_version"}
  ]' "$DESCRIPTORS/playbook-config.json" > "$d/playbook-config.json"
  jq '. + {"tier":1,"mode":"fast","slug":"abc","verbose":false}' "$CFG/playbook-config.json" > "$CFG/playbook-config.json.new"
  mv "$CFG/playbook-config.json.new" "$CFG/playbook-config.json"
  export JENGA_CONFIG_DESCRIPTORS_DIR="$d"
}

# ================================================================================================================
# The matrix is real: the descriptors cover all five files, and the scratch copy is a copy
# ================================================================================================================

@test "the shipped descriptors cover the six config files that have an instance plus conventions, and the scratch project holds copies of the six" {
  for f in $CONFIG_FILES; do
    [ -f "$DESCRIPTORS/$f.json" ]
    if [ "$f" = audit-config ]; then
      cmp "$REPO_ROOT/skills/j-init/assets/audit-config_template.json" "$CFG/$f.json"
    else
      cmp "$REPO_ROOT/project/configs/$f.json" "$CFG/$f.json"
    fi
  done
  # conventions.json is described but has no instance in this repo, so it is not in the get/set matrix
  [ -f "$DESCRIPTORS/conventions.json" ]
  [ ! -e "$CFG/conventions.json" ]
  [ "$(ls "$DESCRIPTORS" | grep -v '^_' | wc -l | tr -d ' ')" -eq 7 ]
  [ "$(ls "$CFG" | wc -l | tr -d ' ')" -eq 6 ]
}

@test "the editable keys are audit-config's mode, severity_threshold, offline_behavior and production_only, the integer settings of scope-thresholds and playbook-config plus test-config's two commit_* and three test_run_* strings; checklists and workflow have none" {
  run editable_keys "$DESCRIPTORS"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | cut -d' ' -f1 | sort -u | tr '\n' ' ')" = "audit-config playbook-config scope-thresholds test-config " ]
  [ "$(echo "$output" | grep '^test-config ' | cut -d' ' -f2 | sort | tr '\n' ' ')" = "commit_prompt_default commit_scope_map_file test_run_epic test_run_story test_run_task " ]
  for f in checklists workflow; do
    [ "$(jq '[.keys[] | select(.editable)] | length' "$DESCRIPTORS/$f.json")" -eq 0 ]
    # and no bump rule is declared anywhere in a file with no editable key (checklist_version is pinned to 1)
    [ "$(jq '[.keys[] | select(.bump_on_change != null)] | length' "$DESCRIPTORS/$f.json")" -eq 0 ]
  done
  # test-config has editable keys but no version counter, so no bump rule (E72_S01_T04): tools is its only read-only key
  [ "$(jq '[.keys[] | select(.bump_on_change != null)] | length' "$DESCRIPTORS/test-config.json")" -eq 0 ]
  [ "$(jq -r '[.keys[] | select(.editable | not) | .key] | join(",")' "$DESCRIPTORS/test-config.json")" = "tools" ]
}

# ================================================================================================================
# get: every key of every file reads back what is in the file
# ================================================================================================================

@test "get prints the file's own value for every key of all six configs, exit 0, nothing on stderr" {
  local n=0 f key
  for f in $CONFIG_FILES; do
    for key in $(jq -r '.keys[].key' "$DESCRIPTORS/$f.json"); do
      jc get "$f.$key"
      [ "$status" -eq 0 ]
      [ "$output" = "$(cfgval "$f" "$key")" ]
      [ -z "$stderr" ]
      n=$((n + 1))
    done
  done
  # 3 + 2 + 9 + 1 + 5 + 5 keys today; a descriptor key added later raises the floor, never lowers it
  [ "$n" -ge 20 ]
}

# ================================================================================================================
# set on every editable key: value written, counter bumped by exactly 1, nothing else moves
# ================================================================================================================

@test "set on every editable key writes the value, bumps its counter by exactly 1, and changes nothing else" {
  local f key counter before new
  while read -r f key; do
    # the string keys of test-config carry no version counter; they have their own cases further down
    [ "$(dkey "$DESCRIPTORS" "$f" "$key" '.type')" = "integer" ] || continue
    snap
    counter=$(dkey "$DESCRIPTORS" "$f" "$key" '.bump_on_change // empty')
    [ -n "$counter" ]
    before=$(cfgval "$f" "$counter")
    new=$(other_value_for "$f" "$key")
    jc set "$f.$key" "$new"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    assert_contains "$output" "$f.$key = $new ($counter -> $((before + 1)))"
    [ "$(cfgval "$f" "$key")" = "$new" ]
    [ "$(cfgval "$f" "$counter")" -eq $((before + 1)) ]
    # every other key of the changed file is byte-for-byte what it was (compared as parsed JSON)
    jq -e --argjson was "$(cat "$BATS_TEST_TMPDIR/snap/$f.json")" --arg k "$key" --arg c "$counter" \
      'del(.[$k], .[$c]) == ($was | del(.[$k], .[$c]))' "$CFG/$f.json" >/dev/null
    # and the other four files were not touched
    local other
    for other in $CONFIG_FILES; do
      if [ "$other" != "$f" ]; then unchanged "$other"; fi
    done
    # get reflects it
    jc get "$f.$key"
    [ "$output" = "$new" ]
    # put the scratch file back so the next key starts from the real baseline
    cp "$BATS_TEST_TMPDIR/snap/$f.json" "$CFG/$f.json"
  done < <(editable_keys "$DESCRIPTORS")
}

@test "two successful sets bump the counter twice, once each; the same value again does not bump" {
  local before
  before=$(cfgval scope-thresholds threshold_version)
  jc set scope-thresholds.inline_max_files 6
  [ "$status" -eq 0 ]
  jc set scope-thresholds.inline_max_lines 90
  [ "$status" -eq 0 ]
  [ "$(cfgval scope-thresholds threshold_version)" -eq $((before + 2)) ]
  snap
  jc set scope-thresholds.inline_max_files 6
  [ "$status" -eq 0 ]
  assert_contains "$output" "(unchanged)"
  [ "$(cfgval scope-thresholds threshold_version)" -eq $((before + 2)) ]
  all_unchanged
}

@test "set of the current value on every editable key is a successful no-op: exit 0, (unchanged), no bump, byte-identical" {
  local f key
  snap
  while read -r f key; do
    jc set "$f.$key" "$(cfgval "$f" "$key")"
    [ "$status" -eq 0 ]
    # the confirmation shows the JSON form of the value, so a string is quoted
    assert_contains "$output" "$f.$key = $(jq -c --arg k "$key" '.[$k]' "$CFG/$f.json") (unchanged)"
  done < <(editable_keys "$DESCRIPTORS")
  all_unchanged
}

@test "the two version counters move independently: a playbook-config set leaves scope-thresholds alone and vice versa" {
  snap
  jc set playbook-config.max_composition_depth 5
  [ "$status" -eq 0 ]
  unchanged scope-thresholds
  [ "$(cfgval playbook-config config_version)" -eq $(($(jq '.config_version' "$BATS_TEST_TMPDIR/snap/playbook-config.json") + 1)) ]
  snap
  jc set scope-thresholds.max_concurrent_testers 2
  [ "$status" -eq 0 ]
  unchanged playbook-config
}

@test "a value is written with the file's own formatting: two-space JSON and a trailing newline" {
  jc set scope-thresholds.slot_ttl_minutes 50
  [ "$status" -eq 0 ]
  [ "$(tail -c 1 "$CFG/scope-thresholds.json" | od -An -c | tr -d ' ')" = '\n' ]
  run jq --indent 2 . "$CFG/scope-thresholds.json"
  [ "$output" = "$(cat "$CFG/scope-thresholds.json")" ]
}

# ================================================================================================================
# exit 4: every kind of invalid value leaves EVERY config byte-identical
# ================================================================================================================

@test "exit 4: below min, above max and a non-integer on every editable integer key leave all five files byte-identical" {
  local f key min max
  snap
  while read -r f key; do
    [ "$(dkey "$DESCRIPTORS" "$f" "$key" '.type')" = "integer" ] || continue
    min=$(dkey "$DESCRIPTORS" "$f" "$key" '.min')
    max=$(dkey "$DESCRIPTORS" "$f" "$key" '.max')
    jc set "$f.$key" "$((min - 1))"
    [ "$status" -eq 4 ]
    assert_contains "$stderr" "$key: $((min - 1)) is below the minimum of $min"
    [ -z "$output" ]
    all_unchanged
    jc set "$f.$key" "$((max + 1))"
    [ "$status" -eq 4 ]
    assert_contains "$stderr" "$key: $((max + 1)) is above the maximum of $max"
    all_unchanged
    for bad in abc 3.5 "" "1e3" "0x10" "true" "[1]"; do
      jc set "$f.$key" "$bad"
      [ "$status" -eq 4 ]
      [ -n "$stderr" ]
      all_unchanged
    done
  done < <(editable_keys "$DESCRIPTORS")
}

@test "exit 4 leaves no temp file and no counter change behind either" {
  snap
  jc set scope-thresholds.inline_max_files 0
  [ "$status" -eq 4 ]
  [ "$(find "$CFG" -name '*.tmp' -o -name '.*.tmp' | wc -l | tr -d ' ')" -eq 0 ]
  [ "$(ls -A "$CFG" | wc -l | tr -d ' ')" -eq 6 ]
  [ "$(cfgval scope-thresholds threshold_version)" = "$(jq -r '.threshold_version' "$BATS_TEST_TMPDIR/snap/scope-thresholds.json")" ]
}

@test "exit 4 for the string, boolean, allowed and pattern branches (fixture descriptors): wrong type, outside allowed, failing pattern" {
  make_fixture_descriptors
  snap
  # outside `allowed`: an integer inside min/max but not in the set, a string outside the set
  jc set playbook-config.tier 4
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "tier: 4 is not one of the allowed values 1, 2, 3"
  all_unchanged
  jc set playbook-config.mode medium
  [ "$status" -eq 4 ]
  assert_contains "$stderr" 'mode: "medium" is not one of the allowed values "fast", "slow"'
  all_unchanged
  # failing pattern
  jc set playbook-config.slug "ABC1"
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "slug:"
  assert_contains "$stderr" "does not match the required pattern ^[a-z]+\$"
  all_unchanged
  # wrong type for a boolean and for an allowed-set integer
  jc set playbook-config.verbose yes
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "is not a boolean"
  all_unchanged
  jc set playbook-config.tier two
  [ "$status" -eq 4 ]
  all_unchanged
}

@test "the string, boolean and allowed-set branches also set correctly and bump config_version once each (fixture descriptors)" {
  make_fixture_descriptors
  local v0
  v0=$(cfgval playbook-config config_version)
  jc set playbook-config.tier 3
  [ "$status" -eq 0 ]
  jc set playbook-config.mode slow
  [ "$status" -eq 0 ]
  jc set playbook-config.slug hello
  [ "$status" -eq 0 ]
  jc set playbook-config.verbose true
  [ "$status" -eq 0 ]
  [ "$(cfgval playbook-config tier)" = "3" ]
  [ "$(cfgval playbook-config mode)" = "slow" ]
  [ "$(cfgval playbook-config slug)" = "hello" ]
  [ "$(cfgval playbook-config verbose)" = "true" ]
  [ "$(jq -r '.verbose | type' "$CFG/playbook-config.json")" = "boolean" ]
  [ "$(jq -r '.tier | type' "$CFG/playbook-config.json")" = "number" ]
  [ "$(cfgval playbook-config config_version)" -eq $((v0 + 4)) ]
  # the real, shipped keys of the same file are untouched
  [ "$(cfgval playbook-config max_composition_depth)" = "$(jq -r '.max_composition_depth' "$REPO_ROOT/project/configs/playbook-config.json")" ]
}

# ================================================================================================================
# exit 5: read-only keys
# ================================================================================================================

@test "exit 5: set on every read-only key of all five files is rejected, naming the key, with no file changed anywhere" {
  local f key n=0
  snap
  while read -r f key; do
    jc set "$f.$key" 1
    [ "$status" -eq 5 ]
    assert_contains "$stderr" "$key"
    assert_contains "$stderr" "read-only"
    [ -z "$output" ]
    all_unchanged
    n=$((n + 1))
  done < <(readonly_keys "$DESCRIPTORS")
  # 3 (checklists) + 1 (playbook-config) + 1 (scope-thresholds) + 1 (test-config) + 5 (workflow)
  [ "$n" -ge 11 ]
}

@test "exit 5 names the descriptor's pointer, so the user is told where to edit instead" {
  local f key pointer
  while read -r f key; do
    pointer=$(dkey "$DESCRIPTORS" "$f" "$key" '.pointer')
    [ -n "$pointer" ]
    jc set "$f.$key" 1
    [ "$status" -eq 5 ]
    assert_contains "$stderr" "$pointer"
  done < <(readonly_keys "$DESCRIPTORS")
}

@test "exit 5 comes before the value is examined: an invalid, an empty and a valid-looking value all report 5" {
  snap
  for v in 99 notanumber "" '[]' '{"a":1}'; do
    jc set scope-thresholds.threshold_version "$v"
    [ "$status" -eq 5 ]
    jc set workflow.paths "$v"
    [ "$status" -eq 5 ]
  done
  all_unchanged
}

@test "checklists, workflow and test-config: get works on every key, set exits 5 on every read-only key (test-config's commit_* strings are editable), and no version counter changes in any file" {
  local f key
  snap
  for f in checklists workflow test-config; do
    for key in $(jq -r '.keys[].key' "$DESCRIPTORS/$f.json"); do
      jc get "$f.$key"
      [ "$status" -eq 0 ]
      [ "$output" = "$(cfgval "$f" "$key")" ]
      if [ "$(dkey "$DESCRIPTORS" "$f" "$key" '.editable')" = "false" ]; then
        jc set "$f.$key" 7
        [ "$status" -eq 5 ]
      fi
    done
  done
  all_unchanged
  [ "$(cfgval checklists checklist_version)" = "1" ]
  [ "$(cfgval scope-thresholds threshold_version)" = "$(jq -r '.threshold_version' "$BATS_TEST_TMPDIR/snap/scope-thresholds.json")" ]
  [ "$(cfgval playbook-config config_version)" = "$(jq -r '.config_version' "$BATS_TEST_TMPDIR/snap/playbook-config.json")" ]
}

# ================================================================================================================
# test-config.json's editable commit options (E72_S01_T04): two string keys, no version counter
# ================================================================================================================

@test "test-config commit options: get reads the defaults, set writes without bumping anything, tools stays untouched" {
  jc get test-config.commit_prompt_default
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  jc get test-config.commit_scope_map_file
  [ "$status" -eq 0 ]
  [ "$output" = "templates/test-scope-map.json" ]
  snap
  jc set test-config.commit_prompt_default scoped
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  # no counter, so the confirmation carries no bump suffix
  [ "$output" = 'test-config.commit_prompt_default = "scoped"' ]
  jc get test-config.commit_prompt_default
  [ "$output" = "scoped" ]
  # only that key moved: tools and the other string key are as they were, and no counter appeared
  jq -e --argjson was "$(cat "$BATS_TEST_TMPDIR/snap/test-config.json")" \
    'del(.commit_prompt_default) == ($was | del(.commit_prompt_default))' "$CFG/test-config.json" >/dev/null
  [ "$(jq -r 'keys | join(",")' "$CFG/test-config.json")" = "commit_prompt_default,commit_scope_map_file,test_run_epic,test_run_story,test_run_task,tools" ]
  local other
  for other in $CONFIG_FILES; do
    if [ "$other" != "test-config" ]; then unchanged "$other"; fi
  done
  # the empty string is a legal value (always prompt) and is stored as a string, not removed
  jc set test-config.commit_prompt_default ""
  [ "$status" -eq 0 ]
  [ "$(jq -r '.commit_prompt_default | type' "$CFG/test-config.json")" = "string" ]
  [ "$(jq -r '.commit_prompt_default' "$CFG/test-config.json")" = "" ]
  for v in skip scoped full; do
    jc set test-config.commit_prompt_default "$v"
    [ "$status" -eq 0 ]
    [ "$(cfgval test-config commit_prompt_default)" = "$v" ]
  done
}

@test "test-config commit options: values outside allowed and paths that are absolute, climb with .., or are not .json exit 4 and change nothing" {
  local v
  snap
  for v in Skip FULL "scoped " none yes 1; do
    jc set test-config.commit_prompt_default "$v"
    [ "$status" -eq 4 ]
    assert_contains "$stderr" "commit_prompt_default"
    [ -z "$output" ]
    all_unchanged
  done
  for v in "/etc/scope-map.json" "../scope-map.json" "a/../b.json" ".." "C:/map.json" 'a\b.json' "scope-map.txt" "scope-map.json.bak" "" ".json"; do
    jc set test-config.commit_scope_map_file "$v"
    [ "$status" -eq 4 ]
    assert_contains "$stderr" "commit_scope_map_file"
    [ -z "$output" ]
    all_unchanged
  done
  # a legal relative path is accepted, including one that merely contains two dots inside a name
  jc set test-config.commit_scope_map_file "config/my..map.json"
  [ "$status" -eq 0 ]
  [ "$(cfgval test-config commit_scope_map_file)" = "config/my..map.json" ]
}

@test "test-config commit options: tools is still read-only, exit 5 naming the tester's approval flow, whatever the value" {
  snap
  for v in '[]' 1 "" '{"a":1}'; do
    jc set test-config.tools "$v"
    [ "$status" -eq 5 ]
    assert_contains "$stderr" "read-only"
    assert_contains "$stderr" "agents/tester.md"
    [ -z "$output" ]
    all_unchanged
  done
}

@test "test-config commit options: a config file written before these keys existed still works, get exits 3 and set creates the key" {
  jq 'del(.commit_prompt_default, .commit_scope_map_file)' "$CFG/test-config.json" > "$CFG/test-config.json.new"
  mv "$CFG/test-config.json.new" "$CFG/test-config.json"
  jc get test-config.commit_prompt_default
  [ "$status" -eq 3 ]
  assert_contains "$stderr" "not set in"
  jc get test-config.tools
  [ "$status" -eq 0 ]
  jc set test-config.commit_prompt_default full
  [ "$status" -eq 0 ]
  [ "$(cfgval test-config commit_prompt_default)" = "full" ]
  [ "$(jq '.tools | length' "$CFG/test-config.json")" -eq "$(jq '.tools | length' "$REPO_ROOT/project/configs/test-config.json")" ]
}

# ================================================================================================================
# test-config.json's per-scope test-run policy keys (E72_S06_T01): three flat enum strings, no version counter
# ================================================================================================================

@test "test-config test_run_* keys: get reads the defaults (none, scoped, full)" {
  jc get test-config.test_run_task
  [ "$status" -eq 0 ]
  [ "$output" = "none" ]
  jc get test-config.test_run_story
  [ "$status" -eq 0 ]
  [ "$output" = "scoped" ]
  jc get test-config.test_run_epic
  [ "$status" -eq 0 ]
  [ "$output" = "full" ]
}

@test "test-config test_run_story: set full succeeds without bumping anything, reads back full, and only that key moved" {
  snap
  jc set test-config.test_run_story full
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$output" = 'test-config.test_run_story = "full"' ]
  jc get test-config.test_run_story
  [ "$status" -eq 0 ]
  [ "$output" = "full" ]
  jq -e --argjson was "$(cat "$BATS_TEST_TMPDIR/snap/test-config.json")" \
    'del(.test_run_story) == ($was | del(.test_run_story))' "$CFG/test-config.json" >/dev/null
  local other
  for other in $CONFIG_FILES; do
    if [ "$other" != "test-config" ]; then unchanged "$other"; fi
  done
}

@test "test-config test_run_*: each of the three keys accepts none, scoped and full" {
  local key v
  for key in test_run_task test_run_story test_run_epic; do
    for v in none scoped full; do
      jc set "test-config.$key" "$v"
      [ "$status" -eq 0 ]
      [ "$(cfgval test-config "$key")" = "$v" ]
    done
  done
}

@test "test-config test_run_story: banana is rejected with exit 4 and the file is left byte-identical" {
  snap
  jc set test-config.test_run_story banana
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "test_run_story"
  [ -z "$output" ]
  all_unchanged
  cmp "$CFG/test-config.json" "$BATS_TEST_TMPDIR/snap/test-config.json"
}

@test "test-config test_run_*: values outside allowed (case variants, padding, empty, skip) exit 4 on every key and change nothing" {
  local key v
  snap
  for key in test_run_task test_run_story test_run_epic; do
    for v in Scoped FULL "none " "" skip yes 1; do
      jc set "test-config.$key" "$v"
      [ "$status" -eq 4 ]
      assert_contains "$stderr" "$key"
      [ -z "$output" ]
      all_unchanged
    done
  done
}

@test "the version counters themselves are read-only: a user cannot set threshold_version or config_version, so a bump never stacks on a hand-set value" {
  snap
  jc set scope-thresholds.threshold_version 100
  [ "$status" -eq 5 ]
  jc set playbook-config.config_version 100
  [ "$status" -eq 5 ]
  jc set checklists.checklist_version 2
  [ "$status" -eq 5 ]
  all_unchanged
}

# ================================================================================================================
# audit-config (E85_S01_T01): string-enum and boolean keys, each bumping config_version
# ================================================================================================================

@test "audit-config: the shipped template holds exactly the five keys at their documented defaults" {
  [ "$(jq -c . "$REPO_ROOT/skills/j-init/assets/audit-config_template.json")" = '{"config_version":1,"mode":"ask","severity_threshold":"high","offline_behavior":"warn","production_only":false}' ]
  jc get audit-config.severity_threshold
  [ "$status" -eq 0 ]
  [ "$output" = "high" ]
}

@test "audit-config: a set of an allowed string value or the boolean writes it and bumps config_version by 1" {
  jc set audit-config.severity_threshold critical
  [ "$status" -eq 0 ]
  [ "$(cfgval audit-config severity_threshold)" = "critical" ]
  [ "$(cfgval audit-config config_version)" = "2" ]
  jc set audit-config.mode on
  [ "$status" -eq 0 ]
  [ "$(cfgval audit-config mode)" = "on" ]
  jc set audit-config.production_only true
  [ "$status" -eq 0 ]
  [ "$(cfgval audit-config production_only)" = "true" ]
  jc set audit-config.offline_behavior fail
  [ "$status" -eq 0 ]
  [ "$(cfgval audit-config offline_behavior)" = "fail" ]
  [ "$(cfgval audit-config config_version)" = "5" ]
}

@test "audit-config: a value outside the allowed list exits 4 and leaves the file byte-identical" {
  snap
  jc set audit-config.severity_threshold urgent
  [ "$status" -eq 4 ]
  jc set audit-config.mode always
  [ "$status" -eq 4 ]
  jc set audit-config.offline_behavior ignore
  [ "$status" -eq 4 ]
  jc set audit-config.production_only maybe
  [ "$status" -eq 4 ]
  all_unchanged
}

@test "audit-config: config_version is read-only, so a set exits 5 and nothing is written" {
  snap
  jc set audit-config.config_version 5
  [ "$status" -eq 5 ]
  all_unchanged
}

# ================================================================================================================
# exit 3 and exit 6
# ================================================================================================================

@test "exit 3: an unknown file and an unknown key fail get and set for every config file, nothing written" {
  local f
  snap
  jc get nosuchfile.key
  [ "$status" -eq 3 ]
  assert_contains "$stderr" 'unknown config file "nosuchfile"'
  jc set nosuchfile.key 1
  [ "$status" -eq 3 ]
  for f in $CONFIG_FILES; do
    jc get "$f.nosuchkey"
    [ "$status" -eq 3 ]
    assert_contains "$stderr" 'unknown key "nosuchkey"'
    jc set "$f.nosuchkey" 1
    [ "$status" -eq 3 ]
    assert_contains "$stderr" 'unknown key "nosuchkey"'
  done
  # a config key that exists in the descriptor's file name space but with the .json suffix is not a file id
  jc get scope-thresholds.json.inline_max_files
  [ "$status" -eq 3 ]
  all_unchanged
}

@test "exit 6: a malformed config file fails get for each of the six files, and set for each editable one, leaving it untouched" {
  local f key
  for f in $CONFIG_FILES; do
    printf '{ "broken": ' > "$CFG/$f.json"
    snap
    key=$(jq -r '.keys[0].key' "$DESCRIPTORS/$f.json")
    jc get "$f.$key"
    [ "$status" -eq 6 ]
    # workflow.json is also what scripts/resolve-root.sh reads to find the configs directory, so a malformed one is
    # reported by the resolver ("malformed JSON") rather than by the config reader ("unreadable"): same exit code
    case "$f" in
      workflow) assert_contains "$stderr" "malformed JSON" ;;
      *) assert_contains "$stderr" "unreadable" ;;
    esac
    all_unchanged
    cp "$REPO_ROOT/project/configs/$f.json" "$CFG/$f.json"
  done
  while read -r f key; do
    printf '[1, 2]' > "$CFG/$f.json"
    snap
    jc set "$f.$key" "$(other_value_for "$f" "$key" 2>/dev/null || echo 2)"
    [ "$status" -eq 6 ]
    all_unchanged
    cp "$REPO_ROOT/project/configs/$f.json" "$CFG/$f.json"
  done < <(editable_keys "$DESCRIPTORS")
}

@test "exit 6: a missing config file fails get and set, and set creates nothing" {
  rm "$CFG/scope-thresholds.json"
  jc get scope-thresholds.inline_max_files
  [ "$status" -eq 6 ]
  jc set scope-thresholds.inline_max_files 4
  [ "$status" -eq 6 ]
  [ ! -e "$CFG/scope-thresholds.json" ]
  [ "$(ls -A "$CFG" | wc -l | tr -d ' ')" -eq 5 ]
}

@test "exit 6: a config file whose version counter is missing is refused, because a bump cannot be applied" {
  jq 'del(.threshold_version)' "$CFG/scope-thresholds.json" > "$CFG/scope-thresholds.json.new"
  mv "$CFG/scope-thresholds.json.new" "$CFG/scope-thresholds.json"
  snap
  jc set scope-thresholds.inline_max_files 4
  [ "$status" -eq 6 ]
  all_unchanged
}

# ================================================================================================================
# The repo's own configs are never touched
# ================================================================================================================

@test "a get/set/rejected-set session leaves this repo's own project/configs byte-identical" {
  local before after
  before=$(cd "$REPO_ROOT/project/configs" && shasum *.json)
  jc set scope-thresholds.inline_max_files 8
  [ "$status" -eq 0 ]
  jc set playbook-config.max_composition_depth 2
  [ "$status" -eq 0 ]
  jc set scope-thresholds.inline_max_files 0
  [ "$status" -eq 4 ]
  jc set workflow.paths '{}'
  [ "$status" -eq 5 ]
  jc get checklists.items
  [ "$status" -eq 0 ]
  after=$(cd "$REPO_ROOT/project/configs" && shasum *.json)
  [ "$before" = "$after" ]
  # the scratch copy did move, so the session was real
  [ "$(cfgval scope-thresholds inline_max_files)" = "8" ]
}

@test "the scratch project root is under the test's temp dir, so no case above can resolve the repo's own configs" {
  run bash "$REPO_ROOT/scripts/resolve-root.sh" get configs
  [ "$status" -eq 0 ]
  [ "$output" = "$CFG" ]
  case "$output" in "$REPO_ROOT"/*) false ;; esac
}
