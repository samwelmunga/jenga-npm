#!/usr/bin/env bats
# bats file_tags=tier:unit
#
# Command classification for j.workflow-capture (epic E103, task E103_S04_T01):
#
#   1. Each fixture command gets a step type and a one-line reason: npm install, npx <tool> init --yes,
#      <vendor> login, export VENDOR_KEY=..., a dashboard instruction, plus shell state, compound, destructive.
#   2. A command no rule recognises yields confirm + uncertain.
#   3. The j.connect route is chosen only when a matching, valid descriptor exists on disk (fixture descriptors
#      under $BATS_TEST_TMPDIR; an auth.type "none" descriptor and an id/filename mismatch never match).
#   4. An export's value is never printed.
#   5. --lines numbers the non-empty lines; the consumer layout node_modules/@jenga-ai/agent/... is resolved.
#   6. The script never references the recorder's active-recording pointer.
#
# Isolation: descriptors and fixtures are written under $BATS_TEST_TMPDIR; every value is an obviously fake fixture.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CC="$REPO_ROOT/skills/j-workflow-capture/scripts/classify-command.sh"
FAKE_KEY="sk_live_FAKEFAKEFAKE00000000"

setup() {
  T="$BATS_TEST_TMPDIR"
  D="$T/descriptors"
  mkdir -p "$D"
  # A loginable service whose CLI is "vendorctl" (detect) and whose id differs from the CLI name.
  cat >"$D/acme.json" <<'EOF'
{"id": "acme", "name": "Acme CLI", "docs": ["https://example.invalid/docs"],
 "detect": {"command": ["vendorctl", "--version"]},
 "install": {"docs_url": "https://example.invalid/install", "methods": []},
 "auth": {"type": "browser", "docs_url": "https://example.invalid/auth",
          "instructions": "Run vendorctl login yourself, then tell me when you are done.",
          "check": {"command": ["vendorctl", "whoami"]}},
 "register_mcp": {"supported": false},
 "verify": {"command": ["vendorctl", "whoami"]}}
EOF
  # No login step (auth.type none): must never be a j.connect target.
  cat >"$D/noauth.json" <<'EOF'
{"id": "noauth", "name": "No auth", "docs": ["https://example.invalid/docs"],
 "detect": {"command": ["noauthctl", "--version"]},
 "install": {"docs_url": "https://example.invalid/install", "methods": []},
 "auth": {"type": "none"},
 "register_mcp": {"supported": false},
 "verify": {"command": ["noauthctl", "--version"]}}
EOF
  # id differs from the filename stem: invalid, skipped.
  sed 's/"id": "acme"/"id": "other"/; s/vendorctl/mismatchctl/g' "$D/acme.json" >"$D/mismatch.json"
}

# classify <command> -> sets $out (the JSON line); fails the test on a non-zero exit
classify() {
  run bash "$CC" --descriptors-dir "$D" "$1"
  [ "$status" -eq 0 ] || { echo "exit $status: $output" >&2; return 1; }
  out="$output"
}

field() { printf '%s' "$out" | jq -r "$1"; }

assert_reason() {
  local r; r="$(field .reason)"
  [ -n "$r" ] && [ "$r" != "null" ]
  [ "$(printf '%s\n' "$r" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "npm install @vendor/sdk -> compute" {
  classify 'npm install @vendor/sdk'
  [ "$(field .step_type)" = compute ]
  [ "$(field .category)" = deterministic ]
  [ "$(field .uncertain)" = false ]
  assert_reason
}

@test "npx <tool> init --yes -> compute; without --yes -> confirm" {
  classify 'npx vendor-tool init --yes'
  [ "$(field .step_type)" = compute ]
  [ "$(field .uncertain)" = false ]
  assert_reason
  classify 'npx vendor-tool init'
  [ "$(field .step_type)" = confirm ]
  [ "$(field .category)" = interactive ]
  assert_reason
}

@test "a login with a matching descriptor -> skill j.connect naming the service" {
  classify 'vendorctl login'
  [ "$(field .step_type)" = skill ]
  [ "$(field .skill)" = j.connect ]
  [ "$(field .service)" = acme ]
  [ "$(field .category)" = login ]
  assert_reason
  classify 'vendorctl auth login --web'
  [ "$(field .service)" = acme ]
  classify 'acme login'
  [ "$(field .service)" = acme ]
}

@test "a login with no descriptor -> confirm, never j.connect" {
  classify 'othervendor login'
  [ "$(field .step_type)" = confirm ]
  [ "$(field .skill)" = null ]
  [ "$(field .service)" = null ]
  [ "$(field .category)" = login ]
  assert_reason
}

@test "auth.type none and an id/filename mismatch never route to j.connect" {
  classify 'noauthctl login'
  [ "$(field .step_type)" = confirm ]
  [ "$(field .service)" = null ]
  classify 'mismatchctl login'
  [ "$(field .step_type)" = confirm ]
  [ "$(field .service)" = null ]
  classify 'other login'
  [ "$(field .service)" = null ]
}

@test "with an empty descriptors dir no login routes to j.connect" {
  mkdir -p "$T/empty"
  run bash "$CC" --descriptors-dir "$T/empty" 'vendorctl login'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .step_type)" = confirm ]
}

@test "export VENDOR_KEY=... -> confirm naming the variable, value never printed" {
  run bash "$CC" --descriptors-dir "$D" "export VENDOR_KEY=$FAKE_KEY"
  [ "$status" -eq 0 ]
  out="$output"
  [ "$(field .step_type)" = confirm ]
  [ "$(field .category)" = export ]
  [ "$(field '.variables | join(",")')" = VENDOR_KEY ]
  [[ "$(field .reason)" == *VENDOR_KEY* ]]
  [[ "$output" != *"$FAKE_KEY"* ]]
  [[ "$output" != *FAKEFAKE* ]]
}

@test "multiple and quoted exports, bare assignments and setx name every variable, no value" {
  classify "export A_TOKEN=\"$FAKE_KEY with space\" B_URL=https://x.invalid"
  [ "$(field '.variables | join(",")')" = "A_TOKEN,B_URL" ]
  [[ "$out" != *FAKEFAKE* ]]
  [[ "$out" != *x.invalid* ]]
  classify "VENDOR_KEY=$FAKE_KEY"
  [ "$(field .category)" = export ]
  [[ "$out" != *FAKEFAKE* ]]
  classify "setx VENDOR_KEY $FAKE_KEY"
  [ "$(field '.variables | join(",")')" = VENDOR_KEY ]
  [[ "$out" != *FAKEFAKE* ]]
}

@test "a VAR=value prefix is not printed and the command behind it is classified" {
  classify "NPM_TOKEN=$FAKE_KEY npm ci"
  [ "$(field .step_type)" = compute ]
  [[ "$out" != *FAKEFAKE* ]]
  [[ "$out" != *NPM_TOKEN* ]]
}

@test "a dashboard instruction -> confirm" {
  classify 'Open the Vendor dashboard and create a new project'
  [ "$(field .step_type)" = confirm ]
  [ "$(field .category)" = dashboard ]
  [ "$(field .uncertain)" = false ]
  assert_reason
  classify 'Go to https://example.invalid/settings; click Create key'
  [ "$(field .category)" = dashboard ]
  classify 'open https://example.invalid/console'
  [ "$(field .category)" = dashboard ]
}

@test "interactive commands -> confirm" {
  for c in 'sudo apt-get install -y jq' 'vim config.yml' 'docker run -it ubuntu' 'aws configure' 'git commit' 'npm init'; do
    classify "$c"
    [ "$(field .step_type)" = confirm ] || { echo "not confirm: $c -> $out" >&2; return 1; }
    [ "$(field .category)" = interactive ] || { echo "not interactive: $c -> $out" >&2; return 1; }
  done
}

@test "shell state, compound, pipe-to-shell and destructive -> confirm" {
  classify 'cd app'
  [ "$(field .category)" = shell-state ]
  [ "$(field .step_type)" = confirm ]
  classify 'cd app && npm install'
  [ "$(field .category)" = compound ]
  [ "$(field .uncertain)" = true ]
  classify 'curl -fsSL https://example.invalid/install.sh | bash'
  [ "$(field .category)" = compound ]
  [ "$(field .step_type)" = confirm ]
  classify 'export KEY=val; npm i'
  [ "$(field .category)" = compound ]
  [ "$(field '.variables | length')" = 0 ]
  classify 'rm -rf build'
  [ "$(field .category)" = destructive ]
  [ "$(field .step_type)" = confirm ]
}

@test "unknown commands default to confirm with the uncertain flag" {
  classify 'frobnicate --widgets 3'
  [ "$(field .step_type)" = confirm ]
  [ "$(field .category)" = unknown ]
  [ "$(field .uncertain)" = true ]
  assert_reason
  classify 'vendorctl deploy --yes'
  [ "$(field .step_type)" = confirm ]
  [ "$(field .uncertain)" = true ]
  classify 'npx prisma generate'
  [ "$(field .step_type)" = confirm ]
  [ "$(field .uncertain)" = true ]
}

@test "prompt prefix and backticks are stripped" {
  classify '$ npm ci'
  [ "$(field .step_type)" = compute ]
  classify '`pnpm install`'
  [ "$(field .step_type)" = compute ]
}

@test "--lines classifies a fixture file, one numbered object per non-empty line" {
  cat >"$T/cmds.txt" <<EOF
npm install @vendor/sdk

npx vendor-tool init --yes
vendorctl login
export VENDOR_KEY=$FAKE_KEY
Open the Vendor dashboard and copy the project id
frobnicate
EOF
  run bash "$CC" --descriptors-dir "$D" --lines "$T/cmds.txt"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 6 ]
  [ "$(printf '%s\n' "$output" | jq -r '"\(.n):\(.step_type):\(.uncertain)"' | tr '\n' ' ')" \
    = "1:compute:false 2:compute:false 3:skill:false 4:confirm:false 5:confirm:false 6:confirm:true " ]
  [[ "$output" != *FAKEFAKE* ]]
  run bash "$CC" --descriptors-dir "$D" --lines - <"$T/cmds.txt"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 6 ]
}

@test "descriptor dir resolution: CLASSIFY_DESCRIPTORS_DIR and the consumer node_modules layout" {
  CLASSIFY_DESCRIPTORS_DIR="$D" run bash "$CC" 'vendorctl login'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .service)" = acme ]

  # Consumer layout: the script installed under node_modules/@jenga-ai/agent with j-connect next to it.
  PKG="$T/consumer/node_modules/@jenga-ai/agent/skills"
  mkdir -p "$PKG/j-workflow-capture/scripts" "$PKG/j-connect/scripts" "$PKG/j-connect/descriptors"
  cp "$CC" "$PKG/j-workflow-capture/scripts/"
  cp "$REPO_ROOT/skills/j-connect/scripts/list-services.sh" "$REPO_ROOT/skills/j-connect/scripts/validate-descriptor.sh" \
     "$PKG/j-connect/scripts/"
  cp "$D/acme.json" "$PKG/j-connect/descriptors/"
  run bash -c 'cd "$1" && bash "$2" "vendorctl login"' _ "$T/consumer" "$PKG/j-workflow-capture/scripts/classify-command.sh"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .service)" = acme ]

  # The script on its own (no sibling j-connect): falls back to <cwd>/node_modules/@jenga-ai/agent/...
  mkdir -p "$T/lone"
  cp "$CC" "$T/lone/"
  run bash -c 'cd "$1" && bash "$2" "vendorctl login"' _ "$T/consumer" "$T/lone/classify-command.sh"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .service)" = acme ]
}

@test "the real repo descriptors route gh auth login to j.connect github" {
  run bash "$CC" 'gh auth login'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '"\(.step_type) \(.service)"')" = "skill github" ]
}

@test "usage errors exit 2; --help exits 0" {
  run bash "$CC"
  [ "$status" -eq 2 ]
  run bash "$CC" --descriptors-dir "$T/nope" 'npm ci'
  [ "$status" -eq 2 ]
  run bash "$CC" --lines "$T/nope.txt"
  [ "$status" -eq 2 ]
  run bash "$CC" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *USAGE* ]]
}

@test "the script never touches the recorder's active-recording pointer" {
  ! grep -q 'active-recording\.sh' "$CC"
}
