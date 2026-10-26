#!/usr/bin/env bats
#
# Coverage for the dependency-audit pre-flight checklist items (E85_S01_T06).
#
# Contract under test:
#   - templates/checklists.json and project/configs/checklists.json   the two items, kept in step
#       dependency-audit-before-release   machine, pre-release + pre-publish, confirm, run
#       dependency-audit-reviewed         judgment, pre-commit, advisory, run
#   - project/documentation/preflight-checklists.md   sections 2-6 (schema, kind/verify coupling, enforcement)
#   - scripts/audit-deps.sh   its exit codes: 0 clean, 1 findings, 3 unavailable-under-fail, 4 not permitted
#   - hooks/on_preflight_check.sh   a confirm item never refuses a tool call by itself
#
# Isolation. The behavioural tests run in a temp project root ($PROJ) reached through JENGA_PROJECT_ROOT, with its
# own workflow.json, audit-config.json, package.json and package-lock.json. $PROJ/scripts is a symlink to the real
# scripts directory so the item's `verify` (which runs from the root) finds scripts/audit-deps.sh. npm is a stub
# earlier on PATH that prints a canned `npm audit --json` document and records each call, so no test touches the
# network, and the real project/configs/audit-config.json, tick store and marker directory are never read or
# written. The two real registries are only read (by path), never modified.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CHECKLIST="$REPO_ROOT/scripts/checklist.sh"
VALIDATE="$REPO_ROOT/scripts/validate-checklists.sh"
MARKER="$REPO_ROOT/scripts/checklist-marker.sh"
HOOK="$REPO_ROOT/hooks/on_preflight_check.sh"
SHIPPED="$REPO_ROOT/templates/checklists.json"
INSTANCE="$REPO_ROOT/project/configs/checklists.json"
RELEASE_ID="dependency-audit-before-release"
REVIEWED_ID="dependency-audit-reviewed"

setup() {
  T="$BATS_TEST_TMPDIR"
  PROJ="$T/proj"
  STATE="$T/state"
  BIN="$T/bin"
  NPM_CALLS="$T/npm-calls.log"
  mkdir -p "$PROJ/project/configs" "$BIN"
  # Pretty-printed on purpose: the hook's pure-bash probe of paths.queue reads one key per line.
  cat > "$PROJ/project/configs/workflow.json" <<'EOF'
{
  "paths": {
    "queue": "project/queue",
    "configs": "project/configs"
  }
}
EOF
  cat > "$PROJ/project/configs/scope-thresholds.json" <<'EOF'
{
  "marker_ttl_minutes": 60
}
EOF
  echo '{"name":"fixture","version":"1.0.0"}' > "$PROJ/package.json"
  echo '{"lockfileVersion":3}' > "$PROJ/package-lock.json"
  ln -s "$REPO_ROOT/scripts" "$PROJ/scripts"
  write_config ask

  # Default npm stub: a clean audit. Tests replace the canned document by rewriting $T/npm-audit.json.
  clean_audit
  cat > "$BIN/npm" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$NPM_CALLS"
cat "$T/npm-audit.json"
exit 0
EOF
  chmod +x "$BIN/npm"
  export PATH="$BIN:$PATH"

  export JENGA_PROJECT_ROOT="$PROJ"
  export JENGA_CHECKLISTS_DEFAULT_FILE="$T/no-default-checklists.json"
  export JENGA_CHECKLIST_STATE_DIR="$STATE"
  export JENGA_CHECKLIST_VERIFY_TIMEOUT=30
  export CLAUDE_CODE_SESSION_ID="sess-audit-items"
  unset JENGA_CHECKLIST_SESSION_ID JENGA_SESSION_ID JENGA_CHECKLIST_MARKER_DIR JENGA_CHECKLIST_MARKER_TTL_MINUTES
  unset JENGA_SCOPE_THRESHOLDS_FILE JENGA_CHECKLIST_NOW JENGA_PREFLIGHT_HOOK_SCRIPT_DIR JENGA_PREFLIGHT_HOOK_DEBUG
  unset JENGA_CHECKLIST_RUN_ID JENGA_CHECKLIST_ACTOR JENGA_CHECKLIST_RUN_TTL_MINUTES
}

write_config() { # <mode>
  printf '{"config_version":1,"mode":"%s","severity_threshold":"high","offline_behavior":"warn","production_only":false}\n' \
    "$1" > "$PROJ/project/configs/audit-config.json"
}

clean_audit() {
  echo '{"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":0,"critical":0,"total":0}},"vulnerabilities":{}}' \
    > "$T/npm-audit.json"
}

high_audit() {
  echo '{"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":1,"critical":0,"total":1}},"vulnerabilities":{"leftpad":{"name":"leftpad","severity":"high","fixAvailable":true,"range":"<2.0.0"}}}' \
    > "$T/npm-audit.json"
}

# use_registry <path>: point the checker at one real registry (whole-file selection, no merging).
use_registry() { export JENGA_CHECKLISTS_FILE="$1"; }

# ck <args...>: run the checker; $output is stdout only, $stderr is stderr only.
ck() { run --separate-stderr bash "$CHECKLIST" "$@"; }

# field <id> <key>: one field of one item in the last `check`/`list` report.
field() { printf '%s' "$output" | jq -r --arg id "$1" --arg k "$2" '.[] | select(.id == $id) | .[$k]'; }

# =============================================================================
# 1. The registries
# =============================================================================

@test "both registries contain both items" {
  local f id
  for f in "$SHIPPED" "$INSTANCE"; do
    for id in "$RELEASE_ID" "$REVIEWED_ID"; do
      [ "$(jq -r --arg id "$id" '[.items[] | select(.id == $id)] | length' "$f")" = "1" ] \
        || { echo "$f does not contain exactly one $id" >&2; return 1; }
    done
  done
}

@test "the two registries carry identical id, text, situations, kind, enforcement, tick_scope and verify for both items" {
  local id a b
  for id in "$RELEASE_ID" "$REVIEWED_ID"; do
    a="$(jq -cS --arg id "$id" '.items[] | select(.id == $id)' "$SHIPPED")"
    b="$(jq -cS --arg id "$id" '.items[] | select(.id == $id)' "$INSTANCE")"
    [ -n "$a" ] && [ "$a" = "$b" ] || { echo "$id differs: shipped=$a instance=$b" >&2; return 1; }
  done
}

@test "dependency-audit-before-release: machine, pre-release and pre-publish, confirm (never block), run" {
  local f
  for f in "$SHIPPED" "$INSTANCE"; do
    run jq -r --arg id "$RELEASE_ID" '.items[] | select(.id == $id)
      | [.kind, (.situations | join(",")), .enforcement, .tick_scope] | join(" ")' "$f"
    [ "$status" -eq 0 ]
    [ "$output" = "machine pre-release,pre-publish confirm run" ]
  done
}

@test "dependency-audit-before-release verify runs audit-deps.sh with --dir . --json via the dual-path idiom" {
  local f v
  for f in "$SHIPPED" "$INSTANCE"; do
    v="$(jq -r --arg id "$RELEASE_ID" '.items[] | select(.id == $id) | .verify' "$f")"
    case "$v" in *"scripts/audit-deps.sh"*"node_modules/@jenga-ai/agent/scripts/audit-deps.sh"*) ;; *) echo "$f: no dual-path in $v" >&2; return 1 ;; esac
    case "$v" in *"--dir . --json"*) ;; *) echo "$f: missing --dir . --json" >&2; return 1 ;; esac
    case "$v" in *"no consent"*) ;; *) echo "$f: missing the no-consent message" >&2; return 1 ;; esac
  done
}

@test "dependency-audit-reviewed: judgment, pre-commit, advisory, run, no verify, the specified text" {
  local f
  for f in "$SHIPPED" "$INSTANCE"; do
    run jq -r --arg id "$REVIEWED_ID" '.items[] | select(.id == $id)
      | [.kind, (.situations | join(",")), .enforcement, .tick_scope, (has("verify") | tostring), .text] | join("|")' "$f"
    [ "$status" -eq 0 ]
    [ "$output" = "judgment|pre-commit|advisory|run|false|If package.json or a lockfile changed, the dependency audit was run or the user declined it." ]
  done
}

@test "both registries declare pre-publish (the validator requires it for the new item) and validate clean" {
  local f
  for f in "$SHIPPED" "$INSTANCE"; do
    [ "$(jq -r '(.situations // []) | index("pre-publish") != null' "$f")" = "true" ] \
      || { echo "$f does not declare pre-publish" >&2; return 1; }
    run bash "$VALIDATE" "$f"
    [ "$status" -eq 0 ] || { echo "$f: $output" >&2; return 1; }
  done
}

# =============================================================================
# 2. Check behaviour (stubbed npm, temp project root)
# =============================================================================

@test "mode ask: the release item is unsatisfied with a no-consent message, not passed and not a crash; npm is never called" {
  local f
  for f in "$SHIPPED" "$INSTANCE"; do
    use_registry "$f"
    ck check pre-release --run r-ask
    [ "$status" -eq 11 ] || { echo "$f: exit $status, stderr: $stderr" >&2; return 1; }
    [ "$(field "$RELEASE_ID" result)" = "failed" ]
    [ "$(field "$RELEASE_ID" action)" = "prompt" ]
    [ "$(field "$RELEASE_ID" exit_status)" = "4" ]
    [ "$(field "$RELEASE_ID" cause)" = "nonzero_exit" ]
    case "$(field "$RELEASE_ID" reason)" in *"audit not run: no consent"*) ;; *) echo "reason: $(field "$RELEASE_ID" reason)" >&2; return 1 ;; esac
  done
  [ ! -e "$NPM_CALLS" ]
}

@test "mode off: the release item is unsatisfied (no consent), not passed" {
  write_config off
  use_registry "$INSTANCE"
  ck check pre-release --run r-off
  [ "$(field "$RELEASE_ID" result)" = "failed" ]
  [ "$(field "$RELEASE_ID" exit_status)" = "4" ]
  [ ! -e "$NPM_CALLS" ]
}

@test "mode on with a clean stubbed audit: the release item is satisfied" {
  write_config on
  local f
  for f in "$SHIPPED" "$INSTANCE"; do
    use_registry "$f"
    ck check pre-release --run "r-on-$(basename "$(dirname "$f")")"
    [ "$(field "$RELEASE_ID" result)" = "passed" ] || { echo "$f: $output" >&2; return 1; }
    [ "$(field "$RELEASE_ID" action)" = "proceed" ]
  done
  [ -e "$NPM_CALLS" ]
}

@test "mode on, findings at or above the threshold: the release item is unsatisfied and says so" {
  write_config on
  high_audit
  use_registry "$INSTANCE"
  ck check pre-release --run r-findings
  [ "$(field "$RELEASE_ID" result)" = "failed" ]
  [ "$(field "$RELEASE_ID" exit_status)" = "1" ]
  case "$(field "$RELEASE_ID" reason)" in *"vulnerabilities"*) ;; *) echo "reason: $(field "$RELEASE_ID" reason)" >&2; return 1 ;; esac
}

@test "mode on, audit unavailable under offline_behavior fail: the release item is unsatisfied" {
  printf '{"config_version":1,"mode":"on","severity_threshold":"high","offline_behavior":"fail","production_only":false}\n' \
    > "$PROJ/project/configs/audit-config.json"
  rm "$PROJ/package-lock.json"
  use_registry "$INSTANCE"
  ck check pre-release --run r-unavailable
  [ "$(field "$RELEASE_ID" result)" = "failed" ]
  [ "$(field "$RELEASE_ID" exit_status)" = "3" ]
}

@test "a project with no package.json has nothing to audit: the release item is satisfied without running anything" {
  rm "$PROJ/package.json" "$PROJ/package-lock.json"
  use_registry "$INSTANCE"
  ck check pre-release --run r-nopkg
  [ "$(field "$RELEASE_ID" result)" = "passed" ]
  [ ! -e "$NPM_CALLS" ]
}

@test "the release item also fires at pre-publish" {
  use_registry "$INSTANCE"
  ck check pre-publish --run r-publish
  [ "$(field "$RELEASE_ID" result)" = "failed" ]
  [ "$(field "$RELEASE_ID" enforcement)" = "confirm" ]
}

@test "pre-commit: dependency-audit-reviewed is a reminder only, never self-certified, never halting" {
  local f
  for f in "$SHIPPED" "$INSTANCE"; do
    use_registry "$f"
    ck check pre-commit --run r-commit
    [ "$(field "$REVIEWED_ID" result)" = "requires_confirmation" ] || { echo "$f: $output" >&2; return 1; }
    [ "$(field "$REVIEWED_ID" action)" = "remind" ]
  done
}

# =============================================================================
# 3. Hook behaviour is unchanged
# =============================================================================

@test "the pre-flight hook does not refuse a release action because of the release item (confirm never blocks a tool call)" {
  local f
  for f in "$SHIPPED" "$INSTANCE"; do
    use_registry "$f"
    # The audit is refused (mode ask), so the item IS unsatisfied; the hook must still let the call through.
    bash "$MARKER" write --situation pre-release --run r-hook --skill j.test >/dev/null
    local cmd p
    for cmd in "git push origin main" "npm publish" "gh release create v1.0.0" "git tag v1.0.0"; do
      p="$(jq -nc --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}')"
      run --separate-stderr bash "$HOOK" <<<"$p"
      [ "$status" -eq 0 ] || { echo "$f: hook exited $status on '$cmd': $stderr" >&2; return 1; }
      case "$output" in *'"deny"'*) echo "$f: deny on '$cmd': $output" >&2; return 1 ;; esac
    done
    bash "$MARKER" clear >/dev/null 2>&1 || true
  done
}
