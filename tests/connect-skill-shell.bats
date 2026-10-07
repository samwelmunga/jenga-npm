#!/usr/bin/env bats
#
# Fixture-driven verification of the j.connect skill shell (E65_S02_T05):
# SKILL.md conformance and router discoverability, registration, and the four
# scripts it sequences (list-services -> detect-platform -> run-descriptor ->
# summarize-run) exercised against throwaway fixtures.
#
# Descriptors are copied from tests/fixtures/connect/ into per-test temp dirs
# (never into skills/j-connect/descriptors/); the project is a throwaway git
# repo; the CLI and package manager are stub executables on a throwaway PATH.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SKILL="$REPO_ROOT/skills/j-connect/SKILL.md"
SCRIPTS="$REPO_ROOT/skills/j-connect/scripts"
FX="$REPO_ROOT/tests/fixtures/connect"
SENTINEL="SENTINEL-SHELL-TOKEN-a41c7e09"

setup() {
  STUB="$BATS_TEST_TMPDIR/stub"; FAKE_BIN="$BATS_TEST_TMPDIR/bin"; PROJ="$BATS_TEST_TMPDIR/proj"
  DESC="$BATS_TEST_TMPDIR/descriptors"
  mkdir -p "$STUB" "$FAKE_BIN" "$PROJ" "$DESC"
  git -C "$PROJ" init -q .
  cp "$FX/e2e/fakeservice.json" "$DESC/fakeservice.json"
  cp "$FX/e2e/fake-prereq.json" "$DESC/fake-prereq.json"
  jq '.id = "nomcp-svc"' "$FX/descriptors/valid-no-mcp.json" > "$DESC/nomcp-svc.json"

  cat > "$FAKE_BIN/fakecli" <<EOS
#!/bin/sh
[ -e "$STUB/installed" ] || exit 127
case "\$1" in
  --version) echo "fakecli 0.0.0" ;;
  whoami) [ -e "$STUB/authed" ] && { echo "signed in with \$FAKESERVICE_TOKEN"; exit 0; }; exit 1 ;;
esac
exit 0
EOS
  printf '#!/bin/sh\necho "brew $*" >> "%s/brew.log"\nexit 0\n' "$STUB" > "$FAKE_BIN/brew"
  printf '#!/bin/sh\nexit 0\n' > "$FAKE_BIN/prereqcli"
  chmod +x "$FAKE_BIN"/*
  export PATH="$FAKE_BIN:$PATH"
  export JENGA_CONNECT_PLATFORM=darwin
  export FAKESERVICE_TOKEN="$SENTINEL"
}

# frontmatter <file>: the YAML block between the first two --- lines
frontmatter() { awk 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { exit } inside { print }' "$1"; }
# list_items <key>: "  - item" lines under a top-level key of the frontmatter
list_items() { frontmatter "$SKILL" | awk -v k="$1:" '$0 == k { on = 1; next } on && /^  - / { print; next } on { exit }'; }

pipeline() { # run the real runner then summarize its stdout
  bash "$SCRIPTS/run-descriptor.sh" "$DESC/fakeservice.json" --project-root "$PROJ" "$@" > "$BATS_TEST_TMPDIR/results.jsonl" 2>/dev/null || true
  run --separate-stderr bash "$SCRIPTS/summarize-run.sh" "$BATS_TEST_TMPDIR/results.jsonl"
}
last_line() { printf '%s\n' "$output" | tail -n1; }

# ---- SKILL.md conformance and router discoverability ---------------------------

@test "SKILL.md satisfies the naming contract: directory j-connect, frontmatter name j.connect" {
  [ -f "$REPO_ROOT/skills/j-connect/SKILL.md" ]
  [ "$(frontmatter "$SKILL" | grep -c '^name: j\.connect$')" -eq 1 ]
  [ -z "$(frontmatter "$SKILL" | grep -E '^name: j\.j-')" ]
  [ ! -e "$REPO_ROOT/skills/connect" ]
}

@test "frontmatter has a non-empty description and non-empty keywords and examples (router discoverability)" {
  run grep -E '^description: .{10,}' <<<"$(frontmatter "$SKILL")"
  [ "$status" -eq 0 ]
  [ "$(list_items keywords | wc -l | tr -d ' ')" -ge 3 ]
  [ "$(list_items examples | wc -l | tr -d ' ')" -ge 3 ]
  # keywords are short phrases (1-3 words per project/documentation/skill-authoring.md); examples include the bare invocation
  [ "$(list_items keywords | sed 's/^  - //' | awk 'NF > 3' | wc -l | tr -d ' ')" -eq 0 ]
  list_items examples | grep -q 'j\.connect'
}

@test "SKILL.md does not set minimum_permission_level" {
  [ -z "$(frontmatter "$SKILL" | grep minimum_permission_level)" ]
}

@test "SKILL.md references all four scripts by the sibling-skill path form" {
  local s
  for s in list-services detect-platform run-descriptor summarize-run; do
    grep -q "bash skills/j-connect/scripts/$s.sh" "$SKILL"
  done
}

@test "SKILL.md contains no inline jq, brew or npm install, and no hardcoded service or vendor names" {
  run grep -n -i -E '\bjq\b|\bbrew\b|npm install' "$SKILL"
  [ "$status" -ne 0 ]
  run grep -n -i -E 'supabase|digitalocean|digital ocean|github|figma|expo|vercel|stripe|aws|fakeservice|fake-prereq' "$SKILL"
  [ "$status" -ne 0 ]
}

@test "SKILL.md states the interaction, secrets and report rules and the no-session-end and Out of Scope sections" {
  grep -q 'Other (type a service id)' "$SKILL"
  grep -q -- '--allow-install' "$SKILL"
  grep -q 'VERIFIED:' "$SKILL"
  grep -q -i 'name only' "$SKILL"
  grep -q -i 'never guess' "$SKILL"
  grep -q '^## Out of Scope' "$SKILL"
  grep -q -i 'no session-end' "$SKILL"
}

@test "j.connect is registered in CLAUDE.md, docs/skills.md and the generated allow-list" {
  grep -q '^| `j\.connect` |' "$REPO_ROOT/CLAUDE.md"
  grep -q '^#### `/j-connect`$' "$REPO_ROOT/docs/skills.md"
  [ "$(jq -r '.skills | index("connect") != null' "$REPO_ROOT/lib/skill-allow-list.json")" = "true" ]
}

# ---- the shell against fixtures --------------------------------------------------

@test "picker is dynamic: N descriptors list as N, and one more file makes N+1 with no other change" {
  run --separate-stderr bash "$SCRIPTS/list-services.sh" --descriptors-dir "$DESC"
  [ "$status" -eq 0 ]
  [ "$(jq '.services | length' <<<"$output")" -eq 3 ]
  [ "$(jq -r '.services | map(.id) | join(",")' <<<"$output")" = "fake-prereq,fakeservice,nomcp-svc" ]
  sum_before="$(shasum "$SKILL" "$SCRIPTS"/*.sh | shasum | cut -d' ' -f1)"
  jq '.id = "added-svc"' "$FX/descriptors/valid.json" > "$DESC/added-svc.json"
  run --separate-stderr bash "$SCRIPTS/list-services.sh" --descriptors-dir "$DESC"
  [ "$status" -eq 0 ]
  [ "$(jq '.services | length' <<<"$output")" -eq 4 ]
  [ "$(jq -r '.services | map(.id) | join(",")' <<<"$output")" = "added-svc,fake-prereq,fakeservice,nomcp-svc" ]
  [ "$(shasum "$SKILL" "$SCRIPTS"/*.sh | shasum | cut -d' ' -f1)" = "$sum_before" ]
}

@test "skip path: CLI installed and authenticated -> install and auth reported skipped, VERIFIED" {
  touch "$STUB/installed" "$STUB/authed"
  pipeline
  [ "$status" -eq 0 ]
  case "$output" in *"install - already installed"*) ;; *) false ;; esac
  case "$output" in *"auth - already authenticated"*) ;; *) false ;; esac
  case "$output" in *"Skipped (nothing to do):"*) ;; *) false ;; esac
  case "$(last_line)" in "VERIFIED: fakeservice") ;; *) false ;; esac
  [ ! -e "$STUB/brew.log" ]
}

@test "not installed: the install action is reported, VERIFIED is never printed, nothing is installed" {
  pipeline
  [ "$status" -eq 3 ]
  case "$output" in *"[ACTION] install - "*) ;; *) false ;; esac
  case "$output" in *"VERIFIED: fakeservice"*) false ;; *) ;; esac
  case "$(last_line)" in "NOT VERIFIED: "*) ;; *) false ;; esac
  [ ! -e "$STUB/brew.log" ]
}

@test "installed but not authenticated: install skipped, auth is a user action, no VERIFIED" {
  touch "$STUB/installed"
  pipeline
  [ "$status" -eq 3 ]
  case "$output" in *"install - already installed"*) ;; *) false ;; esac
  case "$output" in *"[ACTION] auth - "*) ;; *) false ;; esac
  case "$(last_line)" in "NOT VERIFIED: verification did not run (stopped at auth)") ;; *) false ;; esac
}

@test "the user's say-so is not evidence: a re-run after 'done' without the fix is still NOT VERIFIED" {
  touch "$STUB/installed"
  pipeline
  pipeline
  [ "$status" -eq 3 ]
  case "$(last_line)" in "NOT VERIFIED: "*) ;; *) false ;; esac
  touch "$STUB/authed"
  pipeline
  [ "$status" -eq 0 ]
  case "$(last_line)" in "VERIFIED: fakeservice") ;; *) false ;; esac
}

@test "unknown platform: status unknown with the descriptor's docs URL and no install command" {
  export JENGA_CONNECT_PLATFORM=plan9
  run --separate-stderr bash "$SCRIPTS/detect-platform.sh" --descriptor "$DESC/fakeservice.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r .status <<<"$output")" = "unknown" ]
  [ "$(jq -r .method <<<"$output")" = "null" ]
  [ "$(jq -r .fallback_docs_url <<<"$output")" = "https://example.invalid/fakeservice/install" ]
  run grep -E -i -e 'brew install|npm install' <<<"$output$stderr"
  [ "$status" -ne 0 ]
  [ ! -e "$STUB/brew.log" ]
}

@test "the four scripts compose: list -> detect -> run -> summarize, with no secret value anywhere" {
  touch "$STUB/installed" "$STUB/authed"
  run --separate-stderr bash "$SCRIPTS/list-services.sh" --descriptors-dir "$DESC"
  file="$(jq -r '.services[] | select(.id == "fakeservice") | .file' <<<"$output")"
  [ -f "$file" ]
  run --separate-stderr bash "$SCRIPTS/detect-platform.sh" --descriptor "$file"
  [ "$(jq -r .status <<<"$output")" = "ok" ]
  pipeline
  [ "$status" -eq 0 ]
  case "$(last_line)" in "VERIFIED: fakeservice") ;; *) false ;; esac
  case "$output$stderr" in *"$SENTINEL"*) false ;; *) ;; esac
  run grep -r -l -e "$SENTINEL" "$PROJ"
  [ "$status" -ne 0 ]
}
