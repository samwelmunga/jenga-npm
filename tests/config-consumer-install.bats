#!/usr/bin/env bats
#
# Packaging and consumer-install verification for `jenga config` (E68_S03_T02).
#
# Story criterion under test: "The command ships in the package (descriptors included in published files) and works
# from a consumer install, not only this checkout." Proved mechanically, not by reading package.json:
#
#   1. a REAL `npm pack` of this checkout produces a tarball containing everything the command reads at run time:
#      every templates/config-descriptors/*.json, templates/config-descriptor-schema.json, lib/commands/config.js,
#      every lib/config/*.js, scripts/resolve-root.sh, scripts/validate-config-descriptors.sh and
#      scripts/render-config-list.sh;
#   2. that tarball, extracted into <consumer>/node_modules/@jenga-ai/agent/, runs `jenga config get|set` and the
#      interactive flow FROM THE CONSUMER PROJECT: descriptors come from the package (lib/config/paths.js locates them
#      from its own import.meta.url), configs come from the consumer's project/configs/ through
#      scripts/resolve-root.sh's upward search;
#   3. `jenga --help` from that install lists `config` with a one-line description;
#   4. the command and lib/config/*.js import no HTTP, network or model SDK module.
#
# The consumer layout is deliberately the real one (tests/init.bats and tests/consumer-path-fallback.bats history):
# the package under node_modules/@jenga-ai/agent/, and NO templates/, lib/, scripts/ or skills/ at the consumer root.
# The package is installed by extracting the tarball, not by `npm install`: that keeps the test offline, and it is
# stricter, because the command must work with none of the package's third-party dependencies installed (it uses
# Node built-ins only) and without postinstall's .claude/ mirror. `--ignore-scripts` keeps `prepack` (a dashboard UI
# build, irrelevant here) out of the pack.
#
# Isolation. The tarball is built once per file into $BATS_FILE_TMPDIR; every case gets its own consumer under
# $BATS_TEST_TMPDIR. The consumer's config values differ from this repo's (inline_max_files 11, threshold_version 40,
# max_composition_depth 6, config_version 20), so a read that leaked from the checkout is visible. JENGA_PROJECT_ROOT
# and JENGA_CONFIG_DESCRIPTORS_DIR are unset: resolution is the real upward search. This repo's project/configs/ is
# only ever read, and one case checksums it around a get/set session.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
PKG_REL="node_modules/@jenga-ai/agent"

setup_file() {
  local out
  mkdir -p "$BATS_FILE_TMPDIR/pack" "$BATS_FILE_TMPDIR/pkg"
  out=$(cd "$REPO_ROOT" && npm pack --ignore-scripts --json --pack-destination "$BATS_FILE_TMPDIR/pack" 2>/dev/null) || {
    echo "npm pack failed" >&2
    return 1
  }
  TARBALL="$BATS_FILE_TMPDIR/pack/$(printf '%s' "$out" | jq -r '.[0].filename')"
  [ -f "$TARBALL" ]
  tar -tzf "$TARBALL" | sed 's#^package/##' | sort > "$BATS_FILE_TMPDIR/tarball-files.txt"
  tar -xzf "$TARBALL" -C "$BATS_FILE_TMPDIR/pkg" --strip-components=1
}

setup() {
  unset JENGA_PROJECT_ROOT JENGA_CONFIG_DESCRIPTORS_DIR JENGA_PROJECT_DIR CLAUDE_PROJECT_DIR
  CONSUMER="$BATS_TEST_TMPDIR/consumer"
  CFG="$CONSUMER/project/configs"
  PKG="$CONSUMER/$PKG_REL"
  JENGA="$PKG/bin/jenga.js"
  mkdir -p "$CFG" "$PKG"
  cp -R "$BATS_FILE_TMPDIR/pkg/." "$PKG/"
  # The consumer project: only the three files the story names, with values unlike this repo's.
  cp "$REPO_ROOT/project/configs/workflow.json" "$CFG/workflow.json"
  jq '.inline_max_files = 11 | .threshold_version = 40' "$REPO_ROOT/project/configs/scope-thresholds.json" > "$CFG/scope-thresholds.json"
  jq '.max_composition_depth = 6 | .config_version = 20' "$REPO_ROOT/project/configs/playbook-config.json" > "$CFG/playbook-config.json"
  cd "$CONSUMER"
}

# --- helpers ----------------------------------------------------------------------------------------------------

# jc <args...>: run the INSTALLED `jenga config` from the consumer project directory (stderr in $stderr).
jc() {
  run --separate-stderr node "node_modules/@jenga-ai/agent/bin/jenga.js" config "$@"
}

# cfgval <file-id> <key>: current value of a key in the consumer's config.
cfgval() {
  jq -r --arg k "$2" '.[$k]' "$CFG/$1.json"
}

# shipped_paths: every file that must ship, derived from the working tree so a later addition is covered too.
shipped_paths() {
  (
    cd "$REPO_ROOT"
    ls templates/config-descriptors/*.json lib/config/*.js
    echo templates/config-descriptor-schema.json
    echo lib/commands/config.js
    echo bin/jenga.js
    echo scripts/resolve-root.sh
    echo scripts/validate-config-descriptors.sh
    echo scripts/render-config-list.sh
  )
}

# ================================================================================================================
# 1. The tarball ships what the command reads
# ================================================================================================================

@test "the packed tarball contains every descriptor, the schema, the command, lib/config/*.js and the scripts it calls" {
  local p missing=""
  while read -r p; do
    grep -qx -- "$p" "$BATS_FILE_TMPDIR/tarball-files.txt" || missing="$missing $p"
  done < <(shipped_paths)
  [ -z "$missing" ] || { echo "missing from the tarball:$missing"; false; }
}

@test "the tarball holds all six descriptors, and as many lib/config modules as the checkout has" {
  [ "$(grep -c '^templates/config-descriptors/.*\.json$' "$BATS_FILE_TMPDIR/tarball-files.txt")" -eq 6 ]
  [ "$(grep -c '^lib/config/.*\.js$' "$BATS_FILE_TMPDIR/tarball-files.txt")" -eq "$(ls "$REPO_ROOT"/lib/config/*.js | wc -l | tr -d ' ')" ]
}

@test "every descriptor in the tarball is byte-identical to the checkout's, so what ships is what was validated" {
  local f
  for f in "$REPO_ROOT"/templates/config-descriptors/*.json "$REPO_ROOT/templates/config-descriptor-schema.json"; do
    cmp "$f" "$BATS_FILE_TMPDIR/pkg/${f#"$REPO_ROOT"/}"
  done
}

@test "the shipped package.json declares the bin entry and a files list that covers bin, lib, scripts and templates" {
  [ "$(jq -r '.bin.jenga' "$PKG/package.json")" = "bin/jenga.js" ]
  for dir in "bin/" "lib/" "scripts/" "templates/"; do
    jq -e --arg d "$dir" '.files | index($d) != null' "$PKG/package.json" >/dev/null
  done
}

# ================================================================================================================
# 2. The consumer layout is real, and the command works from it
# ================================================================================================================

@test "the consumer layout is the real one: the package under node_modules, nothing framework-shaped at the consumer root" {
  [ -f "$PKG/lib/commands/config.js" ]
  for d in templates lib scripts skills agents bin; do
    [ ! -e "$CONSUMER/$d" ]
  done
  [ "$(ls "$CFG" | tr '\n' ' ')" = "playbook-config.json scope-thresholds.json workflow.json " ]
  [ "$(ls -A "$CONSUMER" | tr '\n' ' ')" = "node_modules project " ]
  # no dependencies installed: the package's own node_modules does not exist, and nothing else is next to it
  [ ! -e "$PKG/node_modules" ]
  [ "$(ls "$CONSUMER/node_modules" | tr '\n' ' ')" = "@jenga-ai " ]
}

@test "get from the consumer project reads the CONSUMER's config, not this checkout's" {
  jc get scope-thresholds.inline_max_files
  [ "$status" -eq 0 ]
  [ "$output" = "11" ]
  [ -z "$stderr" ]
  [ "$(jq -r '.inline_max_files' "$REPO_ROOT/project/configs/scope-thresholds.json")" != "11" ]
  jc get playbook-config.max_composition_depth
  [ "$status" -eq 0 ]
  [ "$output" = "6" ]
  jc get scope-thresholds.threshold_version
  [ "$output" = "40" ]
}

@test "get resolves the configs through scripts/resolve-root.sh's upward search, from a nested directory of the consumer" {
  mkdir -p "$CONSUMER/src/deep/er"
  cd "$CONSUMER/src/deep/er"
  run --separate-stderr node "$JENGA" config get scope-thresholds.inline_max_files
  [ "$status" -eq 0 ]
  [ "$output" = "11" ]
}

@test "set from the consumer writes the consumer's config, bumps threshold_version by 1, and touches nothing else" {
  local before_pkg before_repo
  before_pkg=$(cd "$PKG" && find templates lib scripts bin -type f -exec shasum {} + | sort)
  before_repo=$(cd "$REPO_ROOT/project/configs" && shasum *.json)
  cp "$CFG/playbook-config.json" "$BATS_TEST_TMPDIR/pb-before.json"
  cp "$CFG/workflow.json" "$BATS_TEST_TMPDIR/wf-before.json"
  jc set scope-thresholds.inline_max_files 15
  [ "$status" -eq 0 ]
  assert_contains "$output" "scope-thresholds.inline_max_files = 15 (threshold_version -> 41)"
  [ "$(cfgval scope-thresholds inline_max_files)" = "15" ]
  [ "$(cfgval scope-thresholds threshold_version)" = "41" ]
  # the other editable keys of that file kept their values
  [ "$(cfgval scope-thresholds inline_max_lines)" = "$(jq -r '.inline_max_lines' "$REPO_ROOT/project/configs/scope-thresholds.json")" ]
  cmp "$CFG/playbook-config.json" "$BATS_TEST_TMPDIR/pb-before.json"
  cmp "$CFG/workflow.json" "$BATS_TEST_TMPDIR/wf-before.json"
  # the installed package and this repo's own configs are untouched
  [ "$(cd "$PKG" && find templates lib scripts bin -type f -exec shasum {} + | sort)" = "$before_pkg" ]
  [ "$(cd "$REPO_ROOT/project/configs" && shasum *.json)" = "$before_repo" ]
  # no temp file left in the consumer's configs directory
  [ "$(ls -A "$CFG" | wc -l | tr -d ' ')" -eq 3 ]
}

@test "set on playbook-config from the consumer bumps config_version, and a repeated set of the same value does not" {
  jc set playbook-config.max_composition_depth 4
  [ "$status" -eq 0 ]
  [ "$(cfgval playbook-config max_composition_depth)" = "4" ]
  [ "$(cfgval playbook-config config_version)" = "21" ]
  jc set playbook-config.max_composition_depth 4
  [ "$status" -eq 0 ]
  assert_contains "$output" "(unchanged)"
  [ "$(cfgval playbook-config config_version)" = "21" ]
}

@test "the exit codes hold from the install: 3 unknown, 4 invalid (file byte-identical), 5 read-only, 6 missing config file, 2 usage" {
  cp "$CFG/scope-thresholds.json" "$BATS_TEST_TMPDIR/before.json"
  jc get nosuchfile.key
  [ "$status" -eq 3 ]
  jc set scope-thresholds.nosuchkey 1
  [ "$status" -eq 3 ]
  jc set scope-thresholds.inline_max_files 0
  [ "$status" -eq 4 ]
  jc set scope-thresholds.inline_max_files 51
  [ "$status" -eq 4 ]
  jc set scope-thresholds.inline_max_files many
  [ "$status" -eq 4 ]
  cmp "$CFG/scope-thresholds.json" "$BATS_TEST_TMPDIR/before.json"
  jc set scope-thresholds.threshold_version 99
  [ "$status" -eq 5 ]
  jc set workflow.paths '{}'
  [ "$status" -eq 5 ]
  cmp "$CFG/scope-thresholds.json" "$BATS_TEST_TMPDIR/before.json"
  # the consumer has no checklists.json: the descriptor ships, the file is absent -> exit 6
  jc get checklists.items
  [ "$status" -eq 6 ]
  jc get
  [ "$status" -eq 2 ]
}

@test "JENGA_PROJECT_ROOT still overrides the upward search when the command runs from the install" {
  mkdir -p "$BATS_TEST_TMPDIR/other/project/configs" "$BATS_TEST_TMPDIR/elsewhere"
  cp "$REPO_ROOT/project/configs/workflow.json" "$BATS_TEST_TMPDIR/other/project/configs/"
  jq '.inline_max_files = 22' "$REPO_ROOT/project/configs/scope-thresholds.json" > "$BATS_TEST_TMPDIR/other/project/configs/scope-thresholds.json"
  cd "$BATS_TEST_TMPDIR/elsewhere"
  JENGA_PROJECT_ROOT="$BATS_TEST_TMPDIR/other" run --separate-stderr node "$JENGA" config get scope-thresholds.inline_max_files
  [ "$status" -eq 0 ]
  [ "$output" = "22" ]
}

@test "the interactive flow runs from the install: the file list shows the consumer's files, q exits 0" {
  run --separate-stderr node "$JENGA" config <<<"q"
  [ "$status" -eq 0 ]
  assert_output_contains "scope-thresholds"
  assert_output_contains "playbook-config"
  assert_output_contains "1. "
}

@test "the interactive flow edits the consumer's config from the install, with the same bump as set" {
  run --separate-stderr node "$JENGA" config <<<$'scope-thresholds\ninline_max_lines\n90\nq\nq\n'
  [ "$status" -eq 0 ]
  [ "$(cfgval scope-thresholds inline_max_lines)" = "90" ]
  [ "$(cfgval scope-thresholds threshold_version)" = "41" ]
}

@test "the helper scripts named in the docs run from the install: list the files, list one file's keys, validate the descriptors" {
  run --separate-stderr bash "$PKG/scripts/render-config-list.sh"
  [ "$status" -eq 0 ]
  assert_output_contains "scope-thresholds"
  run --separate-stderr bash "$PKG/scripts/render-config-list.sh" scope-thresholds
  [ "$status" -eq 0 ]
  assert_output_contains "inline_max_files"
  assert_output_contains "11"
  run --separate-stderr bash "$PKG/scripts/validate-config-descriptors.sh" "$PKG/templates/config-descriptors/scope-thresholds.json"
  [ "$status" -eq 0 ]
}

# ================================================================================================================
# 3. --help from the install
# ================================================================================================================

@test "jenga --help from the consumer install lists config with a one-line description" {
  run node "$JENGA" --help
  [ "$status" -eq 0 ]
  assert_output_contains "jenga config"
  assert_output_contains "List and edit Jenga settings"
  # one line: the entry and its description are on the same output line
  [ "$(printf '%s\n' "$output" | grep -c 'jenga config.*List and edit Jenga settings')" -eq 1 ]
}

@test "jenga config --help from the install prints the usage and the exit-code table" {
  jc --help
  [ "$status" -eq 0 ]
  assert_output_contains "jenga config get <file-id>.<key>"
  assert_output_contains "Exit codes: 0 ok, 2 usage, 3 unknown file or key, 4 invalid value, 5 read-only key,"
}

# ================================================================================================================
# 4. No network, no model SDK
# ================================================================================================================

# code_only <file>: the file's lines with whole-line comments removed, so prose about "no network" never trips a scan.
code_only() {
  grep -vE '^[[:space:]]*(\*|//|/\*)' "$1" || true
}

# Scan patterns. Q is a single quote, so a specifier can be written between either kind of quote.
Q=$'\x27'
NET_IMPORT="(from|import|require)[[:space:]]*\(?[[:space:]]*[\"$Q](node:)?(https?|http2|net|tls|dgram|dns|dns/promises|worker_threads|cluster|inspector|repl|vm|wasi)[\"$Q]"
SDK_IMPORT="(from|import|require)[[:space:]]*\(?[[:space:]]*[\"$Q](@anthropic-ai|anthropic|openai|@openai|@google|@azure|@aws-sdk|cohere|mistral|langchain|axios|node-fetch|undici|got|superagent|request|ws|socket\.io|express|cors|gray-matter)"
NET_GLOBAL="(^|[^.[:alnum:]_])(fetch[[:space:]]*\(|new[[:space:]]+(WebSocket|XMLHttpRequest|EventSource)|XMLHttpRequest)"

@test "static: lib/commands/config.js and lib/config/*.js import no HTTP, network or model SDK module" {
  local f src="$BATS_TEST_TMPDIR/code.js"
  for f in "$REPO_ROOT/lib/commands/config.js" "$REPO_ROOT"/lib/config/*.js; do
    code_only "$f" > "$src"
    # a network-capable built-in
    run grep -nE "$NET_IMPORT" "$src"
    [ "$status" -ne 0 ] || { echo "network-capable built-in in $f: $output"; false; }
    # an SDK or HTTP package
    run grep -niE "$SDK_IMPORT" "$src"
    [ "$status" -ne 0 ] || { echo "SDK or HTTP package in $f: $output"; false; }
    # a global network API
    run grep -nE "$NET_GLOBAL" "$src"
    [ "$status" -ne 0 ] || { echo "global network API in $f: $output"; false; }
  done
}

@test "static: the scan is live, because it does flag a real network import, SDK import and fetch call" {
  printf 'import https from "https";\nconst r = fetch("x");\nimport axios from "axios";\nconst n = require(%shttp%s);\n' "$Q" "$Q" > "$BATS_TEST_TMPDIR/bad.js"
  run grep -cE "$NET_IMPORT" "$BATS_TEST_TMPDIR/bad.js"
  [ "$output" -eq 2 ]
  run grep -cE "$NET_GLOBAL" "$BATS_TEST_TMPDIR/bad.js"
  [ "$output" -eq 1 ]
  run grep -ciE "$SDK_IMPORT" "$BATS_TEST_TMPDIR/bad.js"
  [ "$output" -eq 1 ]
  # and prose in a comment is not flagged
  printf '// no network: never import https or call fetch(\n * from "https"\n' > "$BATS_TEST_TMPDIR/prose.js"
  code_only "$BATS_TEST_TMPDIR/prose.js" > "$BATS_TEST_TMPDIR/prose-code.js"
  run grep -cE "$NET_IMPORT|$NET_GLOBAL" "$BATS_TEST_TMPDIR/prose-code.js"
  [ "$output" -eq 0 ]
}

@test "static: the only imports under lib/config and lib/commands/config.js are Node built-ins and relative modules" {
  local f spec n=0
  for f in "$REPO_ROOT/lib/commands/config.js" "$REPO_ROOT"/lib/config/*.js; do
    code_only "$f" > "$BATS_TEST_TMPDIR/code.js"
    while read -r spec; do
      case "$spec" in
        ./*|../*|fs|path|url|child_process|readline) n=$((n + 1)) ;;
        *) echo "unexpected import \"$spec\" in $f"; false ;;
      esac
    done < <(sed -nE "s/^[[:space:]]*import[^\"$Q]*from[[:space:]]*[\"$Q]([^\"$Q]+)[\"$Q].*\$/\1/p" "$BATS_TEST_TMPDIR/code.js")
  done
  # the scan found imports at all (an empty result would pass vacuously)
  [ "$n" -ge 10 ]
}
