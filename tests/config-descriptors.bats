#!/usr/bin/env bats
#
# Coverage for the `jenga config` descriptor layer (E68_S01_T05): the descriptor schema, the loader/validator
# (lib/config/descriptors.js via scripts/validate-config-descriptors.sh) and the ranked_list renderer
# (lib/config/render.js via scripts/render-config-list.sh).
#
# Contract under test: templates/config-descriptor-schema.json, project/documentation/config-descriptors.md, and the
# header comments of the two scripts.
#
# Isolation. Every case builds its own scratch tree under $BATS_TEST_TMPDIR (setup()):
#   $PROJ   a project root with project/configs/ holding COPIES of this repo's real configs, plus a workflow.json so
#           scripts/resolve-root.sh accepts it. JENGA_PROJECT_ROOT points at it.
#   $DESC   a descriptor directory for the cases that need their own descriptors (JENGA_CONFIG_DESCRIPTORS_DIR is
#           exported only by those cases; by default the shipped descriptors are used).
# This repo's own project/configs/ is only ever READ (to make the copies); one test snapshots it around a full flow
# and proves it is untouched. Fixtures live in tests/fixtures/config-descriptors/.
#
# The ranked_list per_line pattern is read out of templates/playbook-types.json with jq, never copied.
#
# Not tested, on purpose: running under Node 14 (the package engines floor). No Node 14 is available to the suite,
# so a static check (no post-14 APIs in lib/config/) stands in for it.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
VALIDATE="$REPO_ROOT/scripts/validate-config-descriptors.sh"
RENDER="$REPO_ROOT/scripts/render-config-list.sh"
FIX="$REPO_ROOT/tests/fixtures/config-descriptors"
SHIPPED="$REPO_ROOT/templates/config-descriptors"

setup() {
  PROJ="$BATS_TEST_TMPDIR/proj"
  DESC="$BATS_TEST_TMPDIR/descriptors"
  mkdir -p "$PROJ/project/configs" "$DESC"
  cp "$REPO_ROOT"/project/configs/*.json "$PROJ/project/configs/"
  export JENGA_PROJECT_ROOT="$PROJ"
  unset JENGA_CONFIG_DESCRIPTORS_DIR
  PER_LINE="$(jq -r '.types.ranked_list.verify.per_line' "$REPO_ROOT/templates/playbook-types.json")"
}

# --- helpers ----------------------------------------------------------------------------------------------------

# demo_setup: install the demo descriptor (as $DESC/demo.json) and its config (as $PROJ/project/configs/demo.json).
demo_setup() {
  cp "$FIX/demo.json" "$DESC/demo.json"
  cp "${1:-$FIX/demo-config.json}" "$PROJ/project/configs/demo.json"
}

# mutate <jq filter>: write the demo descriptor with the filter applied to $DESC/demo.json, and the demo config.
mutate() {
  jq "$1" "$FIX/demo.json" > "$DESC/demo.json"
  cp "$FIX/demo-config.json" "$PROJ/project/configs/demo.json"
}

# rejects <jq filter> <message fragment>: the mutated descriptor must FAIL, naming the problem.
rejects() {
  mutate "$1"
  run bash "$VALIDATE" "$DESC/demo.json"
  [ "$status" -eq 1 ]
  assert_output_contains "FAIL $DESC/demo.json"
  assert_output_contains "$2"
}

# assert_ranked_list <expected line count>: every line of $output is `<n>. <id> — <text>` per the registry pattern,
# numbered 1..N in order, with exactly N lines (so no trailing menu or prompt line).
assert_ranked_list() {
  local expected="$1" n=0 line
  while IFS= read -r line; do
    n=$((n + 1))
    printf '%s\n' "$line" | grep -Eq -- "$PER_LINE" || { echo "line $n does not match $PER_LINE: $line" >&2; return 1; }
    case "$line" in "$n. "*) ;; *) echo "line $n is not numbered $n: $line" >&2; return 1 ;; esac
  done <<EOF
$output
EOF
  [ "$n" -eq "$expected" ] || { echo "expected $expected lines, got $n" >&2; return 1; }
}

# ================================================================================================================
# Schema and guide
# ================================================================================================================

@test "schema parses, enumerates the five types and the fields the guide documents" {
  run jq -r '.types | join(",")' "$REPO_ROOT/templates/config-descriptor-schema.json"
  [ "$status" -eq 0 ]
  [ "$output" = "integer,string,boolean,array,object" ]
  run jq -r '[.top_level | keys[]] | join(",")' "$REPO_ROOT/templates/config-descriptor-schema.json"
  [ "$output" = "description,descriptor_version,file,keys" ]
  run jq -r '[.key_fields | keys[]] | sort | join(",")' "$REPO_ROOT/templates/config-descriptor-schema.json"
  [ "$output" = "allowed,bump_on_change,default,description,editable,key,label,max,min,pattern,pointer,type" ]
}

@test "the guide's exit-code table lists every code the schema defines" {
  local code
  for code in $(jq -r '.exit_codes | .[] | tostring' "$REPO_ROOT/templates/config-descriptor-schema.json"); do
    run grep -F "| \`$code\` |" "$REPO_ROOT/project/documentation/config-descriptors.md"
    [ "$status" -eq 0 ]
  done
}

# ================================================================================================================
# Validator: shipped descriptors
# ================================================================================================================

@test "the six shipped descriptors validate against scratch copies of the real configs" {
  run bash "$VALIDATE" --all
  [ "$status" -eq 0 ]
  assert_output_not_contains "FAIL"
  [ "$(printf '%s\n' "$output" | grep -c '^PASS ')" -eq 6 ]
  for f in workflow scope-thresholds test-config playbook-config checklists conventions; do
    assert_output_contains "PASS $SHIPPED/$f.json"
  done
}

@test "every key of every real config file is covered by exactly one editable-or-read-only entry" {
  local f key n
  for f in workflow scope-thresholds test-config playbook-config checklists; do
    for key in $(jq -r 'keys[]' "$REPO_ROOT/project/configs/$f.json"); do
      n="$(jq --arg k "$key" '[.keys[] | select(.key == $k)] | length' "$SHIPPED/$f.json")"
      [ "$n" -eq 1 ] || { echo "$f.json key $key has $n descriptor entries" >&2; return 1; }
    done
  done
}

@test "only scalar keys are editable in the shipped descriptors" {
  run jq -s '[.[].keys[] | select(.editable == true) | .type] | unique' "$SHIPPED"/*.json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c .)" = '["integer"]' ]
  run jq -s '[.[].keys[] | select(.type == "array" or .type == "object") | .editable] | unique' "$SHIPPED"/*.json
  [ "$(printf '%s' "$output" | jq -c .)" = '[false]' ]
}

@test "bump rules: eight scope-thresholds keys and max_composition_depth bump; checklists, workflow, test-config never" {
  run jq -r '[.keys[] | select(.editable == true) | .bump_on_change] | unique | join(",")' "$SHIPPED/scope-thresholds.json"
  [ "$output" = "threshold_version" ]
  run jq '[.keys[] | select(.editable == true)] | length' "$SHIPPED/scope-thresholds.json"
  [ "$output" -eq 8 ]
  run jq -r '.keys[] | select(.key == "max_composition_depth") | .bump_on_change' "$SHIPPED/playbook-config.json"
  [ "$output" = "config_version" ]
  local f
  for f in checklists workflow test-config; do
    run jq '[.keys[] | select(has("bump_on_change"))] | length' "$SHIPPED/$f.json"
    [ "$output" -eq 0 ]
  done
  run jq '[.keys[] | select(.editable == true)] | length' "$SHIPPED/checklists.json"
  [ "$output" -eq 0 ]
}

@test "the version counters are read-only and each editable default equals the value the configs hold" {
  run jq -r '.keys[] | select(.key == "threshold_version" or .key == "config_version" or .key == "checklist_version") | .editable' \
    "$SHIPPED/scope-thresholds.json" "$SHIPPED/playbook-config.json" "$SHIPPED/checklists.json"
  [ "$output" = "$(printf 'false\nfalse\nfalse')" ]
  local f key
  for f in scope-thresholds playbook-config; do
    for key in $(jq -r '.keys[] | select(.editable == true) | .key' "$SHIPPED/$f.json"); do
      [ "$(jq --arg k "$key" '.keys[] | select(.key == $k) | .default' "$SHIPPED/$f.json")" = \
        "$(jq --arg k "$key" '.[$k]' "$REPO_ROOT/project/configs/$f.json")" ] \
        || { echo "$f.json $key default differs from the config value" >&2; return 1; }
    done
  done
}

@test "every shipped pointer names something that exists (a repo path or a j.<skill>)" {
  local ptr tok found resolved
  while IFS= read -r ptr; do
    found=0
    for tok in $(printf '%s\n' "$ptr" | grep -oE '[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+|j\.[a-z-]+' || true); do
      case "$tok" in
        j.*) resolved="$REPO_ROOT/skills/j-${tok#j.}/SKILL.md" ;;
        *) resolved="$REPO_ROOT/$tok" ;;
      esac
      [ -e "$resolved" ] || { echo "pointer token '$tok' (in: $ptr) does not resolve to $resolved" >&2; return 1; }
      found=$((found + 1))
    done
    [ "$found" -ge 1 ] || { echo "pointer has no resolvable path or skill: $ptr" >&2; return 1; }
  done <<EOF
$(jq -r '.keys[] | select(.editable == false) | .pointer' "$SHIPPED"/*.json)
EOF
}

# ================================================================================================================
# Validator: malformed descriptors (one case per rule class)
# ================================================================================================================

@test "the demo fixture descriptor is valid against its config" {
  demo_setup
  run bash "$VALIDATE" "$DESC/demo.json"
  [ "$status" -eq 0 ]
  assert_output_contains "PASS $DESC/demo.json"
}

@test "rejects a malformed (unparsable) descriptor file" {
  cp "$FIX/malformed.json" "$DESC/demo.json"
  run bash "$VALIDATE" "$DESC/demo.json"
  [ "$status" -eq 1 ]
  assert_output_contains "FAIL $DESC/demo.json"
  assert_output_contains "malformed JSON"
}

@test "rejects a missing descriptor file" {
  run bash "$VALIDATE" "$DESC/does-not-exist.json"
  [ "$status" -eq 1 ]
  assert_output_contains "cannot read descriptor"
}

@test "rejects a missing required top-level field" {
  rejects 'del(.description)' 'missing required field "description"'
  rejects 'del(.keys)' 'missing required field "keys"'
  rejects 'del(.file)' 'missing required field "file"'
}

@test "rejects a wrong descriptor_version" {
  rejects '.descriptor_version = 2' 'field "descriptor_version" must be 1'
}

@test "rejects an unknown top-level field and an unknown key field" {
  rejects '.bogus = 1' 'unknown top-level field "bogus"'
  rejects '.keys[1].bogus = 1' 'unknown field "bogus"'
}

@test "rejects a descriptor whose file field disagrees with its file name" {
  rejects '.file = "other.json"' 'is named demo.json'
}

@test "rejects a missing required key field" {
  rejects 'del(.keys[1].label)' 'missing required field "label"'
  rejects 'del(.keys[1].editable)' 'missing required field "editable"'
}

@test "rejects an unknown type" {
  rejects '.keys[1].type = "float"' 'field "type" must be one of integer, string, boolean, array, object'
}

@test "rejects editable: true on an array key and on an object key" {
  rejects '.keys[4].editable = true' 'editable: true is only legal for scalar types'
  rejects '.keys[5].editable = true' 'editable: true is only legal for scalar types'
}

@test "rejects an editable key with no default" {
  rejects 'del(.keys[1].default)' 'missing required field "default"'
}

@test "rejects a default that violates its own type, bounds or allowed set" {
  rejects '.keys[1].default = 99' 'default 99 is outside the declared min/max'
  rejects '.keys[1].default = "3"' "must be of the key's type (integer)"
  rejects '.keys[2].default = "medium"' 'is not in the allowed set'
}

@test "rejects min greater than max" {
  rejects '.keys[1].min = 20' 'min (20) is greater than max (10)'
}

@test "rejects a field that does not apply to the key's type or editability" {
  rejects '.keys[2].min = 1' 'field "min" does not apply to type string'
  rejects '.keys[1].pointer = "scripts/resolve-root.sh"' 'field "pointer" is only legal on read-only keys'
  rejects '.keys[4].default = 1' 'field "default" is only legal on editable keys'
}

@test "rejects a read-only key with no pointer or an empty pointer" {
  rejects 'del(.keys[4].pointer)' 'missing required field "pointer"'
  rejects '.keys[4].pointer = "  "' 'field "pointer" must not be empty'
}

@test "rejects a bump_on_change naming a missing key, a non-integer key, the key itself, or an editable key" {
  rejects '.keys[1].bump_on_change = "nope"' 'which is not a key in this descriptor'
  rejects '.keys[1].bump_on_change = "tags"' 'must have type integer'
  rejects '.keys[1].bump_on_change = "size"' 'names the key itself'
  rejects '.keys[2].bump_on_change = "size"' 'must be a read-only version counter'
}

@test "rejects a duplicate key entry" {
  rejects '.keys += [.keys[1]]' 'duplicate key entry'
}

@test "rejects a label, description or pointer containing a newline" {
  rejects '.keys[1].label = "two\nlines"' 'field "label" must be a single line'
  rejects '.keys[1].description = "two\nlines"' 'field "description" must be a single line'
  rejects '.keys[4].pointer = "two\nlines"' 'field "pointer" must be a single line'
  rejects '.description = "two\nlines"' 'field "description" must be a single line'
}

@test "rejects an uncompilable pattern" {
  rejects '.keys[2].pattern = "("' 'is not a valid regular expression'
}

@test "reports one message per problem, not just the first" {
  mutate '.keys[1].default = 99 | del(.keys[0].pointer) | del(.keys[4].pointer)'
  run --separate-stderr bash "$VALIDATE" "$DESC/demo.json"
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$stderr" | grep -c "demo.json: key ")" -eq 3 ]
}

# ================================================================================================================
# Validator: key mismatch against the real config
# ================================================================================================================

@test "rejects a descriptor naming a key that is absent from the config file" {
  demo_setup "$FIX/demo-config-missing-flag.json"
  run bash "$VALIDATE" "$DESC/demo.json"
  [ "$status" -eq 1 ]
  assert_output_contains 'key "flag": named by the descriptor but absent from demo.json'
}

@test "reports a config key that no descriptor entry covers" {
  demo_setup "$FIX/demo-config-extra-key.json"
  run bash "$VALIDATE" "$DESC/demo.json"
  [ "$status" -eq 1 ]
  assert_output_contains 'config key "surprise" in demo.json has no descriptor entry'
}

@test "rejects a key whose current value does not match its declared type" {
  demo_setup "$FIX/demo-config-wrong-type.json"
  run bash "$VALIDATE" "$DESC/demo.json"
  [ "$status" -eq 1 ]
  assert_output_contains 'key "size": declared type integer but the value in demo.json is string'
}

@test "an unreadable config file is a problem and a missing one is a skipped cross-check" {
  demo_setup
  printf '{bad' > "$PROJ/project/configs/demo.json"
  run bash "$VALIDATE" "$DESC/demo.json"
  [ "$status" -eq 1 ]
  assert_output_contains 'is unreadable'
  rm "$PROJ/project/configs/demo.json"
  run bash "$VALIDATE" "$DESC/demo.json"
  [ "$status" -eq 0 ]
  assert_output_contains 'cross-check skipped'
}

@test "a shipped config key added without a descriptor entry is caught (scratch copy)" {
  jq '. + {"brand_new_key": 1}' "$REPO_ROOT/project/configs/scope-thresholds.json" > "$PROJ/project/configs/scope-thresholds.json"
  run bash "$VALIDATE" --all
  [ "$status" -eq 1 ]
  assert_output_contains 'config key "brand_new_key" in scope-thresholds.json has no descriptor entry'
}

# ================================================================================================================
# Loader
# ================================================================================================================

@test "--all with no descriptors present fails loudly instead of passing" {
  JENGA_CONFIG_DESCRIPTORS_DIR="$DESC" run bash "$VALIDATE" --all
  [ "$status" -eq 1 ]
  assert_output_contains "no descriptors found"
  assert_output_contains "nothing was validated"
}

@test "--all reports an unreadable descriptor directory" {
  JENGA_CONFIG_DESCRIPTORS_DIR="$BATS_TEST_TMPDIR/nope" run bash "$VALIDATE" --all
  [ "$status" -eq 1 ]
  assert_output_contains "cannot read descriptor directory"
}

@test "the loader honours JENGA_CONFIG_DESCRIPTORS_DIR and ignores files starting with an underscore" {
  demo_setup
  cp "$FIX/_ignored.json" "$DESC/_ignored.json"
  JENGA_CONFIG_DESCRIPTORS_DIR="$DESC" run bash "$VALIDATE" --all
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^PASS ')" -eq 1 ]
  assert_output_contains "PASS $DESC/demo.json"
  assert_output_not_contains "_ignored"
}

@test "a directory holding only underscore files counts as no descriptors" {
  cp "$FIX/_ignored.json" "$DESC/_ignored.json"
  JENGA_CONFIG_DESCRIPTORS_DIR="$DESC" run bash "$VALIDATE" --all
  [ "$status" -eq 1 ]
  assert_output_contains "no descriptors found"
}

@test "usage errors exit 2" {
  run bash "$VALIDATE"
  [ "$status" -eq 2 ]
  run bash "$VALIDATE" --bogus
  [ "$status" -eq 2 ]
  run bash "$VALIDATE" --all "$DESC/demo.json"
  [ "$status" -eq 2 ]
}

@test "descriptors are found relative to the package root, from a simulated node_modules install" {
  local pkg="$BATS_TEST_TMPDIR/consumer/node_modules/@jenga-ai/agent"
  mkdir -p "$pkg/scripts" "$pkg/templates"
  cp -R "$REPO_ROOT/lib" "$pkg/lib"
  cp "$REPO_ROOT/package.json" "$pkg/package.json"
  cp "$REPO_ROOT/scripts/resolve-root.sh" "$VALIDATE" "$RENDER" "$pkg/scripts/"
  cp "$REPO_ROOT/templates/config-descriptor-schema.json" "$pkg/templates/"
  cp -R "$SHIPPED" "$pkg/templates/config-descriptors"
  cd "$PROJ"
  run bash "$pkg/scripts/validate-config-descriptors.sh" --all
  [ "$status" -eq 0 ]
  assert_output_contains "node_modules/@jenga-ai/agent/templates/config-descriptors/scope-thresholds.json"
  run --separate-stderr bash "$pkg/scripts/render-config-list.sh"
  [ "$status" -eq 0 ]
  assert_ranked_list 6
}

@test "lib/config has no project/ path literal outside comments, no post-Node-14 API and no non-built-in import" {
  run bash -c "grep -hvE '^[[:space:]]*(\\*|/\\*|//)' '$REPO_ROOT'/lib/config/*.js | grep 'project/'"
  [ "$status" -eq 1 ]
  run grep -nE 'Object\.hasOwn|\.at\(|replaceAll|structuredClone|\?\?=|\|\|=' "$REPO_ROOT"/lib/config/*.js
  [ "$status" -eq 1 ]
  run bash -c "grep -hoE 'from \"[^\"]+\"' '$REPO_ROOT'/lib/config/*.js | sort -u"
  [ "$status" -eq 0 ]
  local spec
  while IFS= read -r spec; do
    case "$spec" in
      'from "fs"' | 'from "path"' | 'from "url"' | 'from "child_process"' | 'from "readline"' | 'from "./'*) ;;
      *) echo "unexpected import: $spec" >&2; return 1 ;;
    esac
  done <<EOF
$output
EOF
}

@test "both wrappers are shellcheck clean" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  run shellcheck "$VALIDATE" "$RENDER"
  [ "$status" -eq 0 ]
}

# ================================================================================================================
# Renderer
# ================================================================================================================

@test "the file list is a ranked_list: one line per config file, 1-indexed, no trailing menu line" {
  run --separate-stderr bash "$RENDER"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  assert_ranked_list 6
  assert_starts_with "$output" "1. checklists — "
  assert_starts_with "$(printf '%s\n' "$output" | sed -n 2p)" "2. conventions — "
  assert_output_contains "4. scope-thresholds — "
  assert_output_contains "(8 editable keys)"
  assert_output_contains "(1 editable key)"
  assert_output_contains "(0 editable keys)"
}

@test "each file's key list is a ranked_list with one line per descriptor key, in descriptor order" {
  local f n
  for f in workflow scope-thresholds test-config playbook-config checklists; do
    n="$(jq '.keys | length' "$SHIPPED/$f.json")"
    run --separate-stderr bash "$RENDER" "$f"
    [ "$status" -eq 0 ]
    assert_ranked_list "$n"
    local i=0 key
    for key in $(jq -r '.keys[].key' "$SHIPPED/$f.json"); do
      i=$((i + 1))
      assert_output_contains "$i. $key — "
    done
  done
}

@test "no emitted line contains a newline inside its text, even for a multi-line string value" {
  demo_setup
  jq '.mode = "line1\nline2"' "$FIX/demo-config.json" > "$PROJ/project/configs/demo.json"
  export JENGA_CONFIG_DESCRIPTORS_DIR="$DESC"
  run --separate-stderr bash "$RENDER" demo
  [ "$status" -eq 0 ]
  assert_ranked_list 6
  assert_output_contains '"line1\nline2"'
}

@test "nested keys render read-only with their pointer and a summarised value; editable keys show the current value" {
  local f key ptr editable
  for f in workflow scope-thresholds test-config playbook-config checklists; do
    run --separate-stderr bash "$RENDER" "$f"
    [ "$status" -eq 0 ]
    for key in $(jq -r '.keys[].key' "$SHIPPED/$f.json"); do
      editable="$(jq -r --arg k "$key" '.keys[] | select(.key == $k) | .editable' "$SHIPPED/$f.json")"
      if [ "$editable" = "false" ]; then
        ptr="$(jq -r --arg k "$key" '.keys[] | select(.key == $k) | .pointer' "$SHIPPED/$f.json")"
        assert_output_contains "$key — "
        assert_output_contains "[read-only; see $ptr]"
      fi
    done
  done
  run --separate-stderr bash "$RENDER" workflow
  assert_output_contains "Statuses: 14 items [read-only; see "
  assert_output_contains "Paths: 18 keys [read-only; see scripts/resolve-root.sh]"
  run --separate-stderr bash "$RENDER" scope-thresholds
  assert_output_contains "inline_max_files — Inline max files: 3 (integer, 1 to 50)"
  assert_output_contains "Threshold version: $(jq .threshold_version "$REPO_ROOT/project/configs/scope-thresholds.json") [read-only"
}

@test "the renderer reads values from the resolved project root, not from this repo" {
  jq '.inline_max_files = 7' "$REPO_ROOT/project/configs/scope-thresholds.json" > "$PROJ/project/configs/scope-thresholds.json"
  run --separate-stderr bash "$RENDER" scope-thresholds
  assert_output_contains "Inline max files: 7 (integer"
}

@test "the configs directory resolves through resolve-root.sh: .project trees and the upward search both work" {
  # A registry that does not list paths.configs in a relocated tree falls back to the .project default.
  mv "$PROJ/project" "$PROJ/.project"
  printf '{}' > "$PROJ/.project/configs/workflow.json"
  run --separate-stderr bash "$RENDER" playbook-config
  [ "$status" -eq 0 ]
  assert_output_contains "Config version: 1 [read-only"
  unset JENGA_PROJECT_ROOT
  mkdir -p "$PROJ/deep/er"
  cd "$PROJ/deep/er"
  run --separate-stderr bash "$RENDER" playbook-config
  [ "$status" -eq 0 ]
  assert_output_contains "Max composition depth: 3 (integer, 1 to 10)"
}

@test "an unresolvable project root is reported with the resolver's message and exit 6" {
  JENGA_PROJECT_ROOT="$BATS_TEST_TMPDIR/no-such-root" run --separate-stderr bash "$RENDER"
  [ "$status" -eq 6 ]
  [ -z "$output" ]
  assert_contains "$stderr" "has no registry"
}

@test "a missing config file is listed [not present] and a malformed one [unreadable], without aborting the listing" {
  rm "$PROJ/project/configs/test-config.json"
  printf '{bad' > "$PROJ/project/configs/playbook-config.json"
  run --separate-stderr bash "$RENDER"
  [ "$status" -eq 0 ]
  assert_ranked_list 6
  # test-config (removed here) and conventions (no instance in this repo) are both not present
  [ "$(printf '%s\n' "$output" | grep -c '\[not present\]$')" -eq 2 ]
  [ "$(printf '%s\n' "$output" | grep -c '\[unreadable\]$')" -eq 1 ]
  assert_contains "$(printf '%s\n' "$output" | grep '^5\. ')" "[not present]"
  assert_contains "$(printf '%s\n' "$output" | grep '^3\. ')" "[unreadable]"
}

@test "conventions.json is listed read-only with both keys non-editable, no bump rule, and [not present] when the project has no instance" {
  [ ! -e "$PROJ/project/configs/conventions.json" ]
  run --separate-stderr bash "$RENDER"
  [ "$status" -eq 0 ]
  assert_contains "$(printf '%s\n' "$output" | grep '^2\. ')" "conventions — "
  assert_contains "$(printf '%s\n' "$output" | grep '^2\. ')" "(0 editable keys) [not present]"
  [ "$(jq '[.keys[].key] | sort | join(",")' "$SHIPPED/conventions.json")" = '"categories,conventions_version"' ]
  [ "$(jq '[.keys[] | select(.editable == true)] | length' "$SHIPPED/conventions.json")" -eq 0 ]
  [ "$(jq '[.keys[] | select(has("bump_on_change"))] | length' "$SHIPPED/conventions.json")" -eq 0 ]
  [ "$(jq -r '[.keys[].pointer] | unique | join(",")' "$SHIPPED/conventions.json")" = "scripts/validate-conventions.sh" ]
  [ -f "$REPO_ROOT/scripts/validate-conventions.sh" ]
}

@test "listing the keys of a missing or malformed config file is refused with exit 6" {
  rm "$PROJ/project/configs/test-config.json"
  run --separate-stderr bash "$RENDER" test-config
  [ "$status" -eq 6 ]
  [ -z "$output" ]
  assert_contains "$stderr" "is not present"
  printf '[]' > "$PROJ/project/configs/playbook-config.json"
  run --separate-stderr bash "$RENDER" playbook-config
  [ "$status" -eq 6 ]
  assert_contains "$stderr" "is unreadable"
}

@test "an unknown file id exits 3 and names the known ids; surplus arguments or flags exit 2" {
  run --separate-stderr bash "$RENDER" nope
  [ "$status" -eq 3 ]
  assert_contains "$stderr" 'unknown config file "nope"; known: checklists, conventions, playbook-config, scope-thresholds, test-config, workflow'
  run --separate-stderr bash "$RENDER" a b
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$RENDER" --bogus
  [ "$status" -eq 2 ]
}

@test "the renderer refuses to list from invalid descriptors (exit 1)" {
  demo_setup
  jq 'del(.description)' "$FIX/demo.json" > "$DESC/demo.json"
  JENGA_CONFIG_DESCRIPTORS_DIR="$DESC" run --separate-stderr bash "$RENDER"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "invalid descriptors"
}

@test "the demo descriptor renders every field kind" {
  demo_setup
  export JENGA_CONFIG_DESCRIPTORS_DIR="$DESC"
  run --separate-stderr bash "$RENDER"
  [ "$status" -eq 0 ]
  assert_ranked_list 1
  run --separate-stderr bash "$RENDER" demo
  [ "$status" -eq 0 ]
  assert_ranked_list 6
  assert_output_contains '3. mode — Mode: "fast" (string, one of "fast", "slow")'
  assert_output_contains "4. flag — Flag: true (boolean)"
  assert_output_contains "5. tags — Tags: 2 items [read-only; see scripts/resolve-root.sh]"
  assert_output_contains "6. nested — Nested: 1 key [read-only; see j.tools]"
}

@test "this repo's own project/configs/ is never touched by a full validate and render flow" {
  local before after
  before="$(cd "$REPO_ROOT/project/configs" && find . -type f | sort | xargs shasum)"
  bash "$VALIDATE" --all > /dev/null
  bash "$RENDER" > /dev/null
  bash "$RENDER" scope-thresholds > /dev/null
  after="$(cd "$REPO_ROOT/project/configs" && find . -type f | sort | xargs shasum)"
  [ "$before" = "$after" ]
}
