#!/usr/bin/env bats
#
# Coverage for the `jenga config` command (E68_S02_T04): its registration in bin/jenga.js, the non-interactive
# get/set path and its exit codes, the interactive flow, and the store behind both (lib/config/store.js).
#
# Contract under test: project/documentation/config-descriptors.md (exit codes), the header comments of
# lib/commands/config.js, lib/config/interactive.js and lib/config/store.js, and the E68_S02 acceptance criteria.
#
# Isolation. Every case builds its own scratch project under $BATS_TEST_TMPDIR (setup()): $PROJ/project/configs/
# holds COPIES of this repo's five real config files, plus the registry scripts/resolve-root.sh needs;
# JENGA_PROJECT_ROOT points at it. This repo's own project/configs/ is only ever READ (to make the copies), and one
# test checksums it around a full get/set/interactive session to prove it stays untouched.
#
# Interactive cases pipe stdin into `node bin/jenga.js config`; the flow reads lines as they arrive, so a piped
# script of selections is deterministic. No model, network or mocked service is involved anywhere.
#
# Not tested, on purpose: running under Node 14 (the package engines floor); no Node 14 is available to the suite,
# so a static check (no post-14 APIs in the new files) stands in for it.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
JENGA="$REPO_ROOT/bin/jenga.js"
STORE="$REPO_ROOT/lib/config/store.js"

setup() {
  PROJ="$BATS_TEST_TMPDIR/proj"
  CFG="$PROJ/project/configs"
  mkdir -p "$CFG"
  cp "$REPO_ROOT"/project/configs/*.json "$CFG/"
  export JENGA_PROJECT_ROOT="$PROJ"
  unset JENGA_CONFIG_DESCRIPTORS_DIR
  cd "$BATS_TEST_TMPDIR"
}

# --- helpers ----------------------------------------------------------------------------------------------------

# snap <name>: keep a pre-copy of every scratch config, to compare against with cmp.
snap() {
  rm -rf "$BATS_TEST_TMPDIR/snap"
  mkdir -p "$BATS_TEST_TMPDIR/snap"
  cp "$CFG"/*.json "$BATS_TEST_TMPDIR/snap/"
}

# unchanged <file>: the scratch config is byte-identical to its snapshot.
unchanged() {
  cmp "$BATS_TEST_TMPDIR/snap/$1" "$CFG/$1"
}

# jc <args...>: run `jenga config`, keeping stdout in $output and stderr in $stderr.
jc() {
  run --separate-stderr node "$JENGA" config "$@"
}

# interactive <script>: run the bare interactive flow with the given lines (newline separated) on stdin.
interactive() {
  run --separate-stderr node "$JENGA" config <<<"$1"
}

# value <file> <key>: the current value of a scratch config key.
value() {
  jq -r --arg k "$2" '.[$k]' "$CFG/$1"
}

# ================================================================================================================
# Registration
# ================================================================================================================

@test "jenga --help lists config with a one-line description" {
  run node "$JENGA" --help
  [ "$status" -eq 0 ]
  assert_output_contains "jenga config"
  assert_output_contains "List and edit Jenga settings"
}

@test "bin/jenga.js routes the config case to lib/commands/config.js" {
  run grep -n 'case "config"' "$JENGA"
  [ "$status" -eq 0 ]
  run grep -n 'lib/commands/config.js' "$JENGA"
  [ "$status" -eq 0 ]
}

@test "jenga config --help prints its usage and exit codes, exit 0" {
  jc --help
  [ "$status" -eq 0 ]
  assert_output_contains "jenga config get <file-id>.<key>"
  assert_output_contains "jenga config set <file-id>.<key> <value>"
}

@test "everything the command needs ships: the package files list covers bin, lib, scripts and templates" {
  for dir in "bin/" "lib/" "scripts/" "templates/"; do
    run jq -e --arg d "$dir" '.files | index($d) != null' "$REPO_ROOT/package.json"
    [ "$status" -eq 0 ]
  done
}

# ================================================================================================================
# get
# ================================================================================================================

@test "get prints a scalar bare and exits 0" {
  jc get scope-thresholds.inline_max_files
  [ "$status" -eq 0 ]
  [ "$output" = "$(jq -r '.inline_max_files' "$REPO_ROOT/project/configs/scope-thresholds.json")" ]
}

@test "get on a read-only key is allowed: a counter prints bare, a nested value prints as compact JSON" {
  jc get scope-thresholds.threshold_version
  [ "$status" -eq 0 ]
  [ "$output" = "$(value scope-thresholds.json threshold_version)" ]
  jc get checklists.items
  [ "$status" -eq 0 ]
  [ "$output" = "$(jq -c '.items' "$CFG/checklists.json")" ]
}

@test "the address splits on the first dot only: a key containing a dot is an unknown key, exit 3" {
  jc get scope-thresholds.inline.max
  [ "$status" -eq 3 ]
  assert_contains "$stderr" 'unknown key "inline.max"'
}

# ================================================================================================================
# set and the shared exit codes
# ================================================================================================================

@test "exit 0: a valid set writes the value and bumps threshold_version by exactly 1" {
  snap
  before=$(value scope-thresholds.json threshold_version)
  jc set scope-thresholds.inline_max_files 7
  [ "$status" -eq 0 ]
  assert_contains "$output" "scope-thresholds.inline_max_files = 7 (threshold_version -> $((before + 1)))"
  [ "$(value scope-thresholds.json inline_max_files)" -eq 7 ]
  [ "$(value scope-thresholds.json threshold_version)" -eq $((before + 1)) ]
}

@test "a set bumps config_version for playbook-config.json, and only that counter" {
  before=$(value playbook-config.json config_version)
  jc set playbook-config.max_composition_depth 5
  [ "$status" -eq 0 ]
  assert_contains "$output" "(config_version -> $((before + 1)))"
  [ "$(value playbook-config.json max_composition_depth)" -eq 5 ]
  [ "$(value playbook-config.json config_version)" -eq $((before + 1)) ]
}

@test "a set of an unchanged value succeeds without a bump and without rewriting the file" {
  snap
  current=$(value scope-thresholds.json inline_max_lines)
  touch -t 202001010000 "$CFG/scope-thresholds.json"
  jc set scope-thresholds.inline_max_lines "$current"
  [ "$status" -eq 0 ]
  assert_contains "$output" "(unchanged)"
  unchanged scope-thresholds.json
  # an untouched file keeps its (old) modification time: it was not rewritten
  [ "$(find "$CFG/scope-thresholds.json" -newer "$BATS_TEST_TMPDIR/snap/scope-thresholds.json" | wc -l | tr -d ' ')" -eq 0 ]
}

@test "a set produces a minimal diff: only the value and the counter line change" {
  snap
  jc set scope-thresholds.story_max_files 9
  [ "$status" -eq 0 ]
  run bash -c 'diff "$1" "$2" | grep -c "^[<>]"' _ "$BATS_TEST_TMPDIR/snap/scope-thresholds.json" "$CFG/scope-thresholds.json"
  [ "$output" -eq 4 ]
}

@test "exit 2: missing or surplus arguments, a malformed address, an unknown sub-command" {
  snap
  jc set scope-thresholds.inline_max_files
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "exactly two arguments"
  jc set scope-thresholds.inline_max_files 4 5
  [ "$status" -eq 2 ]
  jc get
  [ "$status" -eq 2 ]
  jc get nodot
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "<file-id>.<key>"
  jc get .inline_max_files
  [ "$status" -eq 2 ]
  jc frobnicate
  [ "$status" -eq 2 ]
  assert_contains "$stderr" 'unknown config sub-command "frobnicate"'
  unchanged scope-thresholds.json
}

@test "exit 3: an unknown file and an unknown key, for both get and set, file untouched" {
  snap
  jc set nosuchfile.key 1
  [ "$status" -eq 3 ]
  assert_contains "$stderr" 'unknown config file "nosuchfile"'
  jc set scope-thresholds.nosuchkey 1
  [ "$status" -eq 3 ]
  assert_contains "$stderr" 'unknown key "nosuchkey"'
  jc get nosuchfile.key
  [ "$status" -eq 3 ]
  jc get scope-thresholds.nosuchkey
  [ "$status" -eq 3 ]
  unchanged scope-thresholds.json
}

@test "exit 4: an invalid value is rejected with a message and the file is byte-identical" {
  snap
  jc set scope-thresholds.inline_max_files 0
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "inline_max_files: 0 is below the minimum of 1"
  unchanged scope-thresholds.json
  jc set scope-thresholds.inline_max_files 51
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "above the maximum of 50"
  unchanged scope-thresholds.json
  jc set scope-thresholds.inline_max_files three
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "is not an integer"
  unchanged scope-thresholds.json
  jc set scope-thresholds.inline_max_files 3.5
  [ "$status" -eq 4 ]
  jc set scope-thresholds.inline_max_files ""
  [ "$status" -eq 4 ]
  unchanged scope-thresholds.json
  jc set playbook-config.max_composition_depth 11
  [ "$status" -eq 4 ]
  unchanged playbook-config.json
}

@test "exit 5: read-only keys (a counter, a nested list, a nested object) cannot be set, file untouched" {
  snap
  jc set scope-thresholds.threshold_version 99
  [ "$status" -eq 5 ]
  assert_contains "$stderr" "read-only"
  jc set playbook-config.config_version 99
  [ "$status" -eq 5 ]
  jc set checklists.items '[]'
  [ "$status" -eq 5 ]
  assert_contains "$stderr" "scripts/validate-checklists.sh"
  jc set workflow.paths '{}'
  [ "$status" -eq 5 ]
  jc set test-config.tools '[]'
  [ "$status" -eq 5 ]
  # the read-only check comes before the value is looked at, so even an invalid value reports 5
  jc set scope-thresholds.threshold_version notanumber
  [ "$status" -eq 5 ]
  for f in scope-thresholds playbook-config checklists workflow test-config; do unchanged "$f.json"; done
}

@test "exit 6: a missing config file, a malformed one, and an unresolvable project root" {
  rm "$CFG/scope-thresholds.json"
  jc set scope-thresholds.inline_max_files 4
  [ "$status" -eq 6 ]
  assert_contains "$stderr" "is not present"
  jc get scope-thresholds.inline_max_files
  [ "$status" -eq 6 ]
  printf '{ not json' > "$CFG/playbook-config.json"
  snap
  jc set playbook-config.max_composition_depth 4
  [ "$status" -eq 6 ]
  assert_contains "$stderr" "unreadable"
  unchanged playbook-config.json
  JENGA_PROJECT_ROOT="$BATS_TEST_TMPDIR/nowhere" jc get scope-thresholds.inline_max_files
  [ "$status" -eq 6 ]
  assert_contains "$stderr" "cannot resolve the configs directory"
}

@test "a missing version counter is a malformed file: exit 6, and nothing is written" {
  jq 'del(.threshold_version)' "$CFG/scope-thresholds.json" > "$BATS_TEST_TMPDIR/x.json" && mv "$BATS_TEST_TMPDIR/x.json" "$CFG/scope-thresholds.json"
  snap
  jc set scope-thresholds.inline_max_files 4
  [ "$status" -eq 6 ]
  assert_contains "$stderr" "version counter"
  unchanged scope-thresholds.json
}

@test "a write that cannot complete exits 6, leaves the target byte-identical and no temp file behind" {
  if [ "$(id -u)" -eq 0 ]; then skip "directory permissions do not bind root"; fi
  snap
  chmod a-w "$CFG"
  jc set scope-thresholds.inline_max_files 4
  rc=$status
  chmod u+w "$CFG"
  [ "$rc" -eq 6 ]
  assert_contains "$stderr" "could not write"
  unchanged scope-thresholds.json
  [ -z "$(find "$CFG" -name '*.tmp')" ]
}

@test "a successful set leaves no temp file behind and keeps the file mode" {
  chmod 640 "$CFG/scope-thresholds.json"
  jc set scope-thresholds.slot_ttl_minutes 50
  [ "$status" -eq 0 ]
  [ -z "$(find "$CFG" -name '*.tmp')" ]
  [ "$(find "$CFG/scope-thresholds.json" -perm 640 | wc -l | tr -d ' ')" -eq 1 ]
}

@test "the scratch files that have editable keys round-trip byte-identically through JSON.stringify(obj, null, 2) + newline" {
  for f in scope-thresholds playbook-config; do
    run node --input-type=module -e '
      import { readFileSync } from "fs";
      const text = readFileSync(process.argv[1], "utf8");
      process.exit(JSON.stringify(JSON.parse(text), null, 2) + "\n" === text ? 0 : 1);
    ' "$REPO_ROOT/project/configs/$f.json"
    [ "$status" -eq 0 ]
  done
}

# ================================================================================================================
# The interactive flow
# ================================================================================================================

@test "interactive: files list, pick a file by number, then a key by number, then back out with q at every level" {
  snap
  interactive $'4\n2\nq\nq\nq'
  [ "$status" -eq 0 ]
  assert_contains "$output" "4. scope-thresholds — "
  assert_contains "$output" "2. inline_max_files — Inline max files: "
  assert_contains "$output" "Select a key in scope-thresholds"
  assert_contains "$output" "New value for inline_max_files"
  [ -z "$stderr" ]
  unchanged scope-thresholds.json
}

@test "interactive: selection by exact name works at both levels" {
  interactive $'playbook-config\nmax_composition_depth\nq\nq\nq'
  [ "$status" -eq 0 ]
  assert_contains "$output" "Select a key in playbook-config"
  assert_contains "$output" "Max composition depth (playbook-config.max_composition_depth)"
}

@test "interactive: q goes back exactly one level (file list is shown again, then the key list of another file)" {
  interactive $'scope-thresholds\nq\nplaybook-config\nq\nq'
  [ "$status" -eq 0 ]
  # three visits to level 1 (start, after the first q, after the second q), one to each file's key list
  [ "$(printf '%s\n' "$output" | grep -c 'Select a config file')" -eq 3 ]
  [ "$(printf '%s\n' "$output" | grep -c 'Select a key in scope-thresholds')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c 'Select a key in playbook-config')" -eq 1 ]
}

@test "interactive: q at the top exits 0 without ever showing a key list" {
  interactive 'q'
  [ "$status" -eq 0 ]
  assert_output_not_contains "Select a key"
  [ -z "$stderr" ]
}

@test "interactive: end of input at each level exits 0 cleanly" {
  interactive ''
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  interactive 'scope-thresholds'
  [ "$status" -eq 0 ]
  assert_contains "$output" "Select a key in scope-thresholds"
  [ -z "$stderr" ]
  interactive $'scope-thresholds\ninline_max_files'
  [ "$status" -eq 0 ]
  assert_contains "$output" "New value for inline_max_files"
  [ -z "$stderr" ]
  run --separate-stderr node "$JENGA" config </dev/null
  [ "$status" -eq 0 ]
}

@test "interactive: an invalid selection or value re-prompts, and the file is byte-identical" {
  snap
  interactive $'99\nnosuch\nscope-thresholds\n42\nnosuchkey\ninline_max_files\n0\n51\nabc\n2.5\nq\nq\nq'
  [ "$status" -eq 0 ]
  assert_contains "$output" "Not a valid selection: 99"
  assert_contains "$output" "Not a valid selection: nosuch"
  assert_contains "$output" "Not a valid selection: 42"
  assert_contains "$output" "Rejected: inline_max_files: 0 is below the minimum of 1"
  assert_contains "$output" "Rejected: inline_max_files: 51 is above the maximum of 50"
  assert_contains "$output" 'is not an integer'
  assert_output_not_contains "inline_max_files = "
  unchanged scope-thresholds.json
}

@test "interactive: a valid value is written via the store with the same bump as set, and the list shows it" {
  before=$(value scope-thresholds.json threshold_version)
  interactive $'scope-thresholds\ninline_max_files\n7\nq\nq'
  [ "$status" -eq 0 ]
  assert_contains "$output" "scope-thresholds.inline_max_files = 7 (threshold_version -> $((before + 1)))"
  [ "$(value scope-thresholds.json inline_max_files)" -eq 7 ]
  [ "$(value scope-thresholds.json threshold_version)" -eq $((before + 1)) ]
  assert_contains "$output" "Inline max files: 7 (integer"
}

@test "interactive: a valid value for playbook-config bumps config_version" {
  before=$(value playbook-config.json config_version)
  interactive $'playbook-config\nmax_composition_depth\n4\nq\nq'
  [ "$status" -eq 0 ]
  [ "$(value playbook-config.json max_composition_depth)" -eq 4 ]
  [ "$(value playbook-config.json config_version)" -eq $((before + 1)) ]
}

@test "interactive: a rejected value followed by a valid one writes only the valid one, bumping once" {
  before=$(value scope-thresholds.json threshold_version)
  interactive $'scope-thresholds\ninline_max_files\n0\n8\nq\nq'
  [ "$status" -eq 0 ]
  [ "$(value scope-thresholds.json inline_max_files)" -eq 8 ]
  [ "$(value scope-thresholds.json threshold_version)" -eq $((before + 1)) ]
}

@test "interactive: selecting a read-only key shows its pointer and never prompts for a value or writes" {
  snap
  interactive $'scope-thresholds\nthreshold_version\n1\nq\nq'
  [ "$status" -eq 0 ]
  assert_contains "$output" "Read-only; see project/configs/README.md"
  assert_output_not_contains "New value for"
  unchanged scope-thresholds.json
  interactive $'checklists\nitems\nq\nq'
  [ "$status" -eq 0 ]
  assert_contains "$output" "Read-only; see scripts/validate-checklists.sh"
  assert_output_not_contains "New value for"
  interactive $'workflow\npipeline\nq\nq'
  [ "$status" -eq 0 ]
  assert_contains "$output" "Read-only; see "
  for f in scope-thresholds checklists workflow; do unchanged "$f.json"; done
}

@test "interactive: a config file that is not present can be selected but only shows its status" {
  rm "$CFG/test-config.json"
  interactive $'test-config\nq'
  [ "$status" -eq 0 ]
  assert_contains "$output" "[not present]"
  assert_contains "$output" "is not present"
  assert_output_not_contains "Select a key"
}

@test "interactive: an unresolvable project root is reported with exit 6" {
  JENGA_PROJECT_ROOT="$BATS_TEST_TMPDIR/nowhere" interactive 'q'
  [ "$status" -eq 6 ]
  assert_contains "$stderr" "cannot resolve the configs directory"
}

@test "interactive: the file list and key list are the renderer's own ranked_list output" {
  interactive $'scope-thresholds\nq\nq'
  [ "$status" -eq 0 ]
  files=$(bash "$REPO_ROOT/scripts/render-config-list.sh")
  keys=$(bash "$REPO_ROOT/scripts/render-config-list.sh" scope-thresholds)
  assert_contains "$output" "$files"
  assert_contains "$output" "$keys"
}

# ================================================================================================================
# The store, unit-style
# ================================================================================================================

# store_eval <js expression>: evaluate the expression with the store's exports in scope and print it as JSON.
store_eval() {
  run node --input-type=module -e "
    import * as s from '$STORE';
    console.log(JSON.stringify($1));
  "
}

@test "store: validateValue enforces type, min, max, allowed and pattern, naming the key and the bound" {
  store_eval "s.validateValue({ key: 'n', type: 'integer', min: 2, max: 9 }, 1)"
  [ "$status" -eq 0 ]
  assert_contains "$output" '"ok":false'
  assert_contains "$output" "n: 1 is below the minimum of 2"
  store_eval "s.validateValue({ key: 'n', type: 'integer', min: 2, max: 9 }, 10)"
  assert_contains "$output" "n: 10 is above the maximum of 9"
  store_eval "s.validateValue({ key: 'n', type: 'integer', min: 2, max: 9 }, 2)"
  assert_contains "$output" '"ok":true'
  store_eval "s.validateValue({ key: 'n', type: 'integer', min: 2, max: 9 }, 9)"
  assert_contains "$output" '"ok":true'
  store_eval "s.validateValue({ key: 'n', type: 'integer' }, 1.5)"
  assert_contains "$output" "n: expected integer, got 1.5"
  store_eval "s.validateValue({ key: 'n', type: 'integer' }, '3')"
  assert_contains "$output" "n: expected integer"
  store_eval "s.validateValue({ key: 'mode', type: 'string', allowed: ['a', 'b'] }, 'c')"
  assert_contains "$output" "mode: \\\"c\\\" is not one of the allowed values"
  store_eval "s.validateValue({ key: 'mode', type: 'string', allowed: ['a', 'b'] }, 'b')"
  assert_contains "$output" '"ok":true'
  store_eval "s.validateValue({ key: 'name', type: 'string', pattern: '^[a-z]+\$' }, 'ABC')"
  assert_contains "$output" "name: \\\"ABC\\\" does not match the required pattern ^[a-z]+\$"
  store_eval "s.validateValue({ key: 'name', type: 'string', pattern: '^[a-z]+\$' }, 'abc')"
  assert_contains "$output" '"ok":true'
  store_eval "s.validateValue({ key: 'flag', type: 'boolean' }, 'true')"
  assert_contains "$output" "flag: expected boolean"
}

@test "store: parseValue turns CLI strings into typed values and refuses everything else" {
  store_eval "[s.parseValue({ key: 'n', type: 'integer' }, '42'), s.parseValue({ key: 'n', type: 'integer' }, '-7')]"
  assert_contains "$output" '"value":42'
  assert_contains "$output" '"value":-7'
  for bad in "4.0" "1e3" " 4" "" "0x10" "+4" "99999999999999999999"; do
    store_eval "s.parseValue({ key: 'n', type: 'integer' }, '$bad').ok"
    [ "$output" = "false" ]
  done
  store_eval "[s.parseValue({ key: 'b', type: 'boolean' }, 'true').value, s.parseValue({ key: 'b', type: 'boolean' }, 'false').value]"
  [ "$output" = "[true,false]" ]
  for bad in "yes" "1" "True" ""; do
    store_eval "s.parseValue({ key: 'b', type: 'boolean' }, '$bad').ok"
    [ "$output" = "false" ]
  done
  store_eval "s.parseValue({ key: 's', type: 'string' }, '  keep as is  ').value"
  [ "$output" = '"  keep as is  "' ]
}

@test "store: setValue returns the table's codes and refuses a read-only key before it parses the value" {
  snap
  store_eval "[s.setValue('scope-thresholds', 'threshold_version', 'junk').code, s.setValue('scope-thresholds', 'nope', '1').code, s.setValue('nope', 'x', '1').code, s.setValue('scope-thresholds', 'inline_max_files', '0').code, s.setValue('scope-thresholds', 'inline_max_files', '4').code]"
  [ "$status" -eq 0 ]
  [ "$output" = "[5,3,3,4,0]" ]
  # only the final, valid call wrote anything: exactly one bump
  [ "$(value scope-thresholds.json threshold_version)" -eq $(jq '.threshold_version + 1' "$BATS_TEST_TMPDIR/snap/scope-thresholds.json") ]
}

@test "store: exit codes are read from the schema table, not copied" {
  run node --input-type=module -e "
    import { EXIT } from '$REPO_ROOT/lib/config/exit-codes.js';
    import { readFileSync } from 'fs';
    const table = JSON.parse(readFileSync('$REPO_ROOT/templates/config-descriptor-schema.json', 'utf8')).exit_codes;
    process.exit(JSON.stringify(EXIT) === JSON.stringify(table) ? 0 : 1);
  "
  [ "$status" -eq 0 ]
}

# ================================================================================================================
# Hygiene
# ================================================================================================================

@test "the new files make no model or network call and import nothing beyond Node built-ins and lib/config" {
  for f in lib/commands/config.js lib/config/store.js lib/config/interactive.js lib/config/exit-codes.js; do
    run grep -nE "from \"(https?|net|tls|dgram|dns|http2)\"|fetch\(|XMLHttpRequest|anthropic|openai|claude" "$REPO_ROOT/$f"
    [ "$status" -eq 1 ]
    # every import is a Node built-in or a sibling in lib/
    run bash -c 'grep -E "^import .* from " "$1" | grep -vE "from \"(fs|path|url|readline|child_process)\"|from \"\.\.?/"' _ "$REPO_ROOT/$f"
    [ "$status" -eq 1 ]
  done
}

@test "the new files carry no hardcoded project/configs path (resolved through resolve-root.sh) and no post-Node-14 API" {
  for f in lib/commands/config.js lib/config/store.js lib/config/interactive.js lib/config/exit-codes.js; do
    run bash -c 'grep -vE "^\s*(\*|//|/\*)" "$1" | grep -nE "project/configs"' _ "$REPO_ROOT/$f"
    [ "$status" -eq 1 ]
    run bash -c 'grep -vE "^\s*(\*|//|/\*)" "$1" | grep -nE "\.replaceAll\(|\.at\(|Object\.hasOwn\(|structuredClone|\?\?=|\|\|=|&&=|fs/promises|node:|readFileSync\(.*\{ *flag|\.findLast\("' _ "$REPO_ROOT/$f"
    [ "$status" -eq 1 ]
  done
}

@test "a full get/set/interactive session leaves this repo's own project/configs untouched" {
  before=$(cksum "$REPO_ROOT"/project/configs/*.json)
  jc set scope-thresholds.inline_max_files 6
  [ "$status" -eq 0 ]
  jc get scope-thresholds.inline_max_files
  interactive $'scope-thresholds\ninline_max_files\n9\nq\nq'
  [ "$status" -eq 0 ]
  after=$(cksum "$REPO_ROOT"/project/configs/*.json)
  [ "$before" = "$after" ]
}
