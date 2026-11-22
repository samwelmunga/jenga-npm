#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# Epic E103 end to end (task E103_S06_T03): j.workflow-capture's shipped scripts chained in the order
# skills/j-workflow-capture/SKILL.md drives them, from a source to an emitted (and, for scenario 3, imported and run)
# workflow definition. The per-script suites (tests/workflow-capture-*.bats) own each script's contract; this suite
# only proves the scripts fit together.
#
#   1. Transcript capture: a session transcript found by its session id under a throwaway projects directory, a
#      range chosen out of four prompts (2..3), one parameter proposed and confirmed, sealed and emitted.
#   2. External-guide capture: a vendor guide snapshotted as untrusted content, one compute step with a reviewed
#      wrapper and its paired confirm step, and a credential that survives only as a ${inputs.<name>} placeholder.
#   3. Export and import: a captured workflow exported from project A, inspected and installed into project B; the
#      imported compute command resolves in B, and the imported workflow runs there with B's own input value.
#
# Every scenario's emitted definition passes scripts/workflow/validate-workflow.sh.
#
# TWO LAYOUTS. Each scenario runs twice:
#   private checkout             the scripts of the repository this suite lives in;
#   public-shaped mirror layout  a tree built once in setup_file with the rsync flags /j-mirror-public and
#                                scripts/check-publicignore-match.sh use (`rsync -a --exclude-from=.publicignore
#                                --exclude=.git`), narrowed - never widened - by anchored excludes for trees the
#                                scenarios do not read. It has no .git, like the published package, so
#                                check-portability.sh takes its installed-package path. When .publicignore or rsync is
#                                absent (the suite is already running inside the public mirror) this variant skips,
#                                naming why: the checkout variant has then already run in the public layout.
#
# ISOLATION. HOME, TMPDIR, JENGA_PROJECTS_DIR (the Claude Code projects directory resolve-source.sh reads),
# JENGA_RECORDING_STATE_DIR (the recorder's pointer directory) and JENGA_PROJECT_ROOT all point under
# $BATS_TEST_TMPDIR, so the real ~/.claude is never read or written. A PATH shim replaces curl, wget, nc, ssh, scp,
# npm, npx and git's network sub-commands with a stub that logs the attempt and fails; every scenario ends by
# asserting the log is empty, that no .claude appeared under HOME, that the pointer directory holds no file (a
# captured recording never becomes the active recording, epic E103 decision 6), and that the framework's capture,
# recorder and workflow scripts are byte-identical to before. Nothing captured is ever run except scenario 3's
# `mkdir -p releases/<version>`, through its reviewed wrapper, inside project B.

# shellcheck disable=SC2016
# SC2016: ${inputs.<name>} placeholders are compared literally, and `bash -c` bodies take their values as arguments.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
FIXTURE_REL="tests/fixtures/workflow-capture"
SESSION_ID="5d7e9a10-3c2b-4f6e-8a1d-9b0c2e4f6a81"
FAKE_KEY="sk-live-0123456789abcdefABCDEF"
GUIDE_URL="https://docs.vendor.invalid/sdk/quick-start"
AT="2026-11-21T10:00:00Z"

# ---------------------------------------------------------------------------
# the public-shaped mirror tree, built once
# ---------------------------------------------------------------------------

setup_file() {
  E2E_MIRROR=""
  E2E_MIRROR_SKIP=""
  if [ ! -f "$REPO_ROOT/.publicignore" ]; then
    E2E_MIRROR_SKIP="no .publicignore: this tree already is the public layout, which the checkout variant covered"
  elif ! command -v rsync >/dev/null 2>&1; then
    E2E_MIRROR_SKIP="rsync is not installed, so the public-shaped tree cannot be built"
  else
    E2E_MIRROR="$BATS_FILE_TMPDIR/mirror"
    mkdir -p "$E2E_MIRROR"
    # First match wins. The leading rules only narrow the copy to what the scenarios read (the fixture directory is
    # descended into; every file in it still meets .publicignore); .publicignore then applies exactly as it does for
    # the real mirror.
    rsync -a \
      --include=/tests/fixtures/ --include=/tests/fixtures/workflow-capture/ \
      --exclude='/tests/fixtures/*' --exclude='/tests/*' \
      --exclude=/project --exclude=/site --exclude=/docs --exclude=/mcp --exclude=/node_modules \
      --exclude=/.claude --exclude=/.agents --exclude=/.git \
      --exclude-from="$REPO_ROOT/.publicignore" \
      --exclude=.git \
      "$REPO_ROOT/" "$E2E_MIRROR/" || E2E_MIRROR_SKIP="building the public-shaped tree with rsync failed"
  fi
  export E2E_MIRROR E2E_MIRROR_SKIP
}

# use_layout checkout|mirror: sets FW (the framework root every script is called from).
use_layout() {
  case "$1" in
    checkout) FW="$REPO_ROOT" ;;
    mirror)
      [ -z "$E2E_MIRROR_SKIP" ] || skip "$E2E_MIRROR_SKIP"
      FW="$E2E_MIRROR"
      ;;
  esac
  CAP="$FW/skills/j-workflow-capture/scripts"
  WFS="$FW/scripts/workflow"
  FIX="$FW/$FIXTURE_REL"
  local f
  for f in "$CAP/resolve-source.sh" "$CAP/snapshot-external.sh" "$CAP/extract-steps.sh" "$CAP/scan-secrets.sh" \
           "$CAP/detect-parameters.sh" "$CAP/classify-command.sh" "$CAP/render-review-table.sh" \
           "$CAP/record-review.sh" "$CAP/generate-wrapper.sh" "$CAP/write-capture.sh" \
           "$CAP/check-portability.sh" "$CAP/export-package.sh" "$CAP/import-package.sh" \
           "$FW/skills/j-workflow-recorder/scripts/emit-workflow.sh" "$WFS/validate-workflow.sh" \
           "$WFS/resolve-compute-command.sh" "$WFS/load-workflows.sh" "$WFS/run-state.sh" "$WFS/next-step.sh" \
           "$WFS/step-confirm.sh" "$FIX/e2e-session-transcript.jsonl" "$FIX/e2e-vendor-sdk-guide.md" \
           "$FIX/e2e-release-steps.txt"; do
    [ -f "$f" ] || { echo "missing in the $1 layout: ${f#"$FW"/}"; return 1; }
  done
  FW_BEFORE="$(fw_snapshot)"
}

# ---------------------------------------------------------------------------
# isolation
# ---------------------------------------------------------------------------

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq is not installed (the capture scripts need it)"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/home" "$T/tmp" "$T/work" "$T/bin" "$T/claude-projects"
  unset CLAUDE_CODE_SESSION_ID JENGA_SESSION_ID CLAUDE_SESSION_ID JENGA_RECORDING_SESSION_ID JENGA_CAPTURE_SESSION_ID
  unset JENGA_WORKFLOWS_TEST_ROOT JENGA_RECORDING_DIR JENGA_WORKFLOW_LOADER JENGA_RUN_STATE JENGA_PLAYBOOKS_TEST_ROOT
  unset CLASSIFY_DESCRIPTORS_DIR JENGA_CAPTURE_STORIES_DIR
  export HOME="$T/home"
  export TMPDIR="$T/tmp"
  export JENGA_PROJECTS_DIR="$T/claude-projects"
  export JENGA_CAPTURE_OUT_DIR="$T/capture-out"
  export JENGA_CAPTURE_NOW="$AT"
  export JENGA_RECORDER_NOW="2026-11-21T03:04:05Z"
  export JENGA_RECORDING_STATE_DIR="$T/state"
  NETLOG="$T/network-attempts.log"
  install_network_shims
  export PATH="$T/bin:$PATH"
  cd "$T/work" || return 1
}

# Every network-capable command a scenario could reach logs and fails instead. git keeps working for local
# sub-commands (the scripts read `rev-parse` and `remote get-url`) and refuses the ones that talk to a remote.
install_network_shims() {
  local c real_git
  for c in curl wget nc ncat ssh scp sftp npm npx pnpm yarn; do
    printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "%s"\nexit 97\n' "$c" "$NETLOG" > "$T/bin/$c"
    chmod +x "$T/bin/$c"
  done
  real_git="$(command -v git || true)"
  [ -n "$real_git" ] || return 0
  cat > "$T/bin/git" <<SH
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    fetch|pull|push|clone|ls-remote|remote-update|submodule|archive)
      printf 'git %s\n' "\$*" >> "$NETLOG"; exit 97 ;;
  esac
done
exec "$real_git" "\$@"
SH
  chmod +x "$T/bin/git"
}

# A content checksum of the framework scripts a scenario calls; compared before and after.
fw_snapshot() {
  find "$FW/skills/j-workflow-capture" "$FW/skills/j-workflow-recorder" "$FW/scripts/workflow" -type f \
    -exec cksum {} + 2>/dev/null | LC_ALL=C sort
}

assert_isolated() {
  if [ -s "$NETLOG" ]; then
    echo "a network command was attempted:"; cat "$NETLOG"; return 1
  fi
  [ ! -e "$HOME/.claude" ] || { echo "something wrote $HOME/.claude"; return 1; }
  [ -z "$(find "$JENGA_RECORDING_STATE_DIR" -type f 2>/dev/null)" ] || {
    echo "the active-recording pointer directory is not empty:"; find "$JENGA_RECORDING_STATE_DIR" -type f; return 1; }
  [ "$(fw_snapshot)" = "$FW_BEFORE" ] || { echo "a framework script changed during the scenario"; return 1; }
}

new_project() {
  mkdir -p "$1/project/configs"
  printf '%s\n' '{"paths":{"workflows":"project/.workflows"}}' > "$1/project/configs/workflow.json"
}

# ident: sets IDENT, the project-identity options every scenario passes, so nothing is inferred from the machine
# running the suite (an empty value switches that name off).
ident() { IDENT=(--project-root "$JENGA_PROJECT_ROOT" --project-name "" --repo ""); }

# fill_proposals <candidates>: the agent's part of the review - include every row and take its step type from
# classify-command.sh, marking a row uncertain where the classifier is. Rows scan-secrets.sh flagged stay uncertain.
fill_proposals() {
  local cands="$1" n text cls
  for n in $(jq -r '.steps[].n' "$cands"); do
    text="$(jq -r --argjson n "$n" '.steps[] | select(.n == $n) | .text' "$cands")"
    cls="$(bash "$CAP/classify-command.sh" "$text")"
    jq --argjson n "$n" --argjson c "$cls" '.steps |= map(if .n == $n then
        .proposal = "include" | .step_type = $c.step_type
        | (if $c.uncertain then .uncertain = true | .reason = (.reason // $c.reason) else . end)
      else . end)' "$cands" > "$cands.tmp"
    mv "$cands.tmp" "$cands"
  done
}

# confirm_wrapper <recording> <row>: show the wrapper, then write it confirming the sha256 that was shown.
confirm_wrapper() {
  local sha
  sha="$(bash "$CAP/generate-wrapper.sh" show "$1" "$2" | sed -n 's/^sha256 *//p')"
  [ -n "$sha" ]
  bash "$CAP/generate-wrapper.sh" write --confirm "$sha" "$1" "$2"
}

# ---------------------------------------------------------------------------
# scenario 1: transcript capture with range selection and one parameter
# ---------------------------------------------------------------------------

scenario_transcript() {
  use_layout "$1"
  local P="$T/proj" cands="$T/candidates.json" resolved src rec def text
  new_project "$P"
  export JENGA_PROJECT_ROOT="$P"
  mkdir -p "$JENGA_PROJECTS_DIR/-work-demo-app"
  cp "$FIX/e2e-session-transcript.jsonl" "$JENGA_PROJECTS_DIR/-work-demo-app/$SESSION_ID.jsonl"

  # Source: the session is found by id under the throwaway projects directory, never under ~/.claude.
  run --separate-stderr bash "$CAP/resolve-source.sh" host
  [ "$status" -eq 0 ]
  assert_one_of "$output" "claude-transcripts	$JENGA_PROJECTS_DIR" \
    "claude-transcripts	$(cd "$JENGA_PROJECTS_DIR" && pwd -P)"
  run --separate-stderr bash "$CAP/resolve-source.sh" resolve "$SESSION_ID"
  [ "$status" -eq 0 ]
  resolved="$output"
  [ "$(jq -r '[.form, .source, .source_ref, .session_id] | join(" ")' <<<"$resolved")" = \
    "session-id session-transcript $SESSION_ID $SESSION_ID" ]
  src="$(jq -r .path <<<"$resolved")"
  assert_one_of "$src" "$JENGA_PROJECTS_DIR/-work-demo-app/$SESSION_ID.jsonl" \
    "$(cd "$JENGA_PROJECTS_DIR" && pwd -P)/-work-demo-app/$SESSION_ID.jsonl"

  # Range: four prompts are listed; the user picks 2..3.
  run --separate-stderr bash "$CAP/extract-steps.sh" list --kind transcript "$src"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
  assert_contains "${lines[0]}" "Which branch am I on?"
  assert_contains "${lines[3]}" "Thanks, that is all for today"
  run --separate-stderr bash "$CAP/extract-steps.sh" range 2 3 --kind transcript --out "$cands" "$src"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.range.from, .range.to, [.steps[] | [.n, .prompt]]]' "$cands")" = '[2,3,[[1,2],[2,3]]]' ]
  [ "$(jq -r '.steps[0].text' "$cands")" = "Back up the build output to /srv/backups/nightly" ]
  [ "$(jq -r '.steps[1].text' "$cands")" = "Tag the release v1.4.0 and push the tag" ]
  assert_contains "$(jq -r '.steps[0].evidence | join("\n")' "$cands")" "tool Bash: cp -R build /srv/backups/nightly"

  # Write, then review: one parameter is proposed and accepted with the rest.
  bash "$CAP/scan-secrets.sh" scan --apply "$cands" >/dev/null
  run --separate-stderr bash "$CAP/write-capture.sh" create --source "$(jq -r .source <<<"$resolved")" \
    --source-ref "$(jq -r .source_ref <<<"$resolved")" --dir "$T/recs" "$cands" "Nightly backup and tag"
  [ "$status" -eq 0 ]
  rec="$output"
  ident
  bash "$CAP/detect-parameters.sh" propose "${IDENT[@]}" --package-name '' --apply "$cands" >/dev/null
  [ "$(jq -c '[.steps[].parameters]' "$cands")" = '[[{"name":"nightly_path","value":"/srv/backups/nightly"}],[]]' ]
  fill_proposals "$cands"
  # Neither row is a command, so the classifier leaves both uncertain; the review settles them one at a time.
  run --separate-stderr bash "$CAP/render-review-table.sh" "$cands"
  [ "$status" -eq 0 ]
  assert_contains "$output" "nightly_path=/srv/backups/nightly"
  run --separate-stderr bash "$CAP/render-review-table.sh" --uncertain "$cands"
  [ "$(printf '%s\n' "$output" | tr '\n' ' ')" = "1 2 " ]
  local n
  for n in 1 2; do
    bash "$CAP/record-review.sh" decide "$rec" "$n" include >/dev/null
    bash "$CAP/record-review.sh" decide "$rec" "$n" type confirm >/dev/null
  done
  bash "$CAP/record-review.sh" decide "$rec" 1 params nightly_path=/srv/backups/nightly >/dev/null
  bash "$CAP/record-review.sh" decide "$rec" 2 params none >/dev/null
  run --separate-stderr bash "$CAP/record-review.sh" pending "$rec" "$cands"
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$CAP/generate-wrapper.sh" pending "$rec"
  [ "$status" -eq 0 ]

  # Seal and emit.
  run --separate-stderr bash "$CAP/write-capture.sh" seal "$rec" "$cands"
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$CAP/write-capture.sh" emit "$rec"
  [ "$status" -eq 0 ]
  def="$output"
  [ "$def" = "$P/project/.workflows/nightly-backup-and-tag.json" ]
  run --separate-stderr bash "$WFS/validate-workflow.sh" "$def"
  [ "$status" -eq 0 ]

  [ "$(jq -c '.provenance' "$def")" = "{\"source\":\"session-transcript\",\"source_ref\":\"$SESSION_ID\"}" ]
  [ "$(jq -c '[.inputs[].name]' "$def")" = '["nightly_path"]' ]
  [ "$(jq -c '[.inputs[] | has("default")] | unique' "$def")" = '[false]' ]
  [ "$(jq -c '[.steps[] | [.id, .type]]' "$def")" = '[["step_001","confirm"],["step_002","confirm"]]' ]
  [ "$(jq -r '.steps[0].prompt' "$def")" = 'Back up the build output to ${inputs.nightly_path}' ]
  [ "$(jq -r '.steps[1].prompt' "$def")" = 'Tag the release v1.4.0 and push the tag' ]
  run ! grep -qF '/srv/backups/nightly' "$def"
  # The prompts outside the range are in neither the recording nor the definition.
  for text in "Which branch am I on?" "Thanks, that is all for today"; do
    run ! grep -qF "$text" "$rec"
    run ! grep -qF "$text" "$def"
  done
  text="$(cat "$rec")"
  assert_contains "$text" "status: closed"
  assert_contains "$text" "source: session-transcript"
  assert_contains "$text" "emitted_workflow: nightly-backup-and-tag"

  # Portable as emitted, and listed as a project workflow.
  ident
  run --separate-stderr bash "$CAP/check-portability.sh" check --recording "$rec" "${IDENT[@]}" "$def"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run --separate-stderr bash -c 'cd "$1" && bash "$2" lookup nightly-backup-and-tag' _ "$P" "$WFS/load-workflows.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r .source <<<"$output")" = "project" ]

  # And it runs with j.workflow's own runner (epic DoD): both manual steps are confirmed and the run completes.
  local run_id
  run_id="$(in_b "$P" "$WFS/run-state.sh" start nightly-backup-and-tag --input nightly_path=/srv/backups/other)"
  [ -n "$run_id" ]
  answer_gate "$P" "$run_id" step_001
  answer_gate "$P" "$run_id" step_002
  run --separate-stderr in_b "$P" "$WFS/next-step.sh" "$run_id"
  [ "$status" -eq 0 ]
  [ "$(jq -r .signal <<<"$output")" = "complete" ]
  [ "$(in_b "$P" "$WFS/run-state.sh" status "$run_id" | jq -c '[.status, [.steps[] | [.id, .status]]]')" = \
    '["completed",[["step_001","completed"],["step_002","completed"]]]' ]

  assert_isolated
}

# ---------------------------------------------------------------------------
# scenario 2: external guide -> one wrapper, its paired confirm, a secret placeholder
# ---------------------------------------------------------------------------

scenario_external() {
  use_layout "$1"
  local P="$T/proj" cands="$T/candidates.json" snapdir="$T/snapshots" snap rec def wrapdir
  new_project "$P"
  export JENGA_PROJECT_ROOT="$P"

  # Source: the fetched guide becomes an untrusted snapshot with its provenance.
  run --separate-stderr bash "$CAP/snapshot-external.sh" url --out-dir "$snapdir" --fetched-at "$AT" "$GUIDE_URL" \
    < "$FIX/e2e-vendor-sdk-guide.md"
  [ "$status" -eq 0 ]
  snap="$output"
  [ "$(jq -r .source <<<"$snap")" = "external-url" ]
  assert_starts_with "$(jq -r .source_ref <<<"$snap")" "$GUIDE_URL fetched_at=$AT sha256="

  run --separate-stderr bash "$CAP/extract-steps.sh" list --kind pasted "$(jq -r .path <<<"$snap")"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  run --separate-stderr bash "$CAP/extract-steps.sh" range 1 3 --kind pasted --out "$cands" "$(jq -r .path <<<"$snap")"
  [ "$status" -eq 0 ]

  # Secrets are flagged before anything is written; the key never reaches the candidates.
  bash "$CAP/scan-secrets.sh" scan --apply "$cands" >/dev/null
  run bash "$CAP/scan-secrets.sh" check "$cands"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.steps[] | select(.secret_flags) | .n]' "$cands")" = '[2]' ]
  run ! grep -qF "$FAKE_KEY" "$cands"

  run --separate-stderr bash "$CAP/write-capture.sh" create --source external-url \
    --source-ref "$(jq -r .source_ref <<<"$snap")" --dir "$T/recs" "$cands" "Vendor SDK setup"
  [ "$status" -eq 0 ]
  rec="$output"

  # Review: proposals from the classifier; the package name the detector proposes is not project-specific.
  ident
  bash "$CAP/detect-parameters.sh" propose "${IDENT[@]}" --package-name '' --apply "$cands" >/dev/null
  [ "$(jq -c '.steps[1].parameters' "$cands")" = '[{"name":"vendor_api_key","secret":true}]' ]
  fill_proposals "$cands"
  jq '.steps |= map(if .n == 1 then .parameters = [] else . end)' "$cands" > "$cands.tmp" && mv "$cands.tmp" "$cands"
  [ "$(jq -c '[.steps[].step_type]' "$cands")" = '["compute","confirm","confirm"]' ]
  run --separate-stderr bash "$CAP/render-review-table.sh" --uncertain "$cands"
  [ "$output" = "2" ]
  run --separate-stderr bash "$CAP/record-review.sh" accept "$rec" "$cands"
  [ "$status" -eq 0 ]
  # The flagged row on its own: included, a confirm step, the credential confirmed by name only.
  bash "$CAP/record-review.sh" decide "$rec" 2 include >/dev/null
  bash "$CAP/record-review.sh" decide "$rec" 2 type confirm >/dev/null
  bash "$CAP/record-review.sh" decide "$rec" 2 params vendor_api_key >/dev/null
  run --separate-stderr bash "$CAP/record-review.sh" pending "$rec" "$cands"
  [ "$status" -eq 0 ]

  # The one compute step needs a wrapper; it is shown, confirmed and written. The command is never run.
  run --separate-stderr bash "$CAP/generate-wrapper.sh" pending "$rec"
  [ "$status" -eq 9 ]
  [ "$(printf '%s\n' "$output" | cut -f1,2)" = "step-001	undecided" ]
  run --separate-stderr confirm_wrapper "$rec" 1
  [ "$status" -eq 0 ]
  [ "$output" = "project/.workflows/scripts/vendor-sdk-setup/step_001.sh" ]
  run --separate-stderr bash "$CAP/generate-wrapper.sh" pending "$rec"
  [ "$status" -eq 0 ]

  run --separate-stderr bash "$CAP/write-capture.sh" seal "$rec" "$cands"
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$CAP/write-capture.sh" emit "$rec"
  [ "$status" -eq 0 ]
  def="$output"
  run --separate-stderr bash "$WFS/validate-workflow.sh" "$def"
  [ "$status" -eq 0 ]

  # Exactly one wrapper, executable, holding the command verbatim, and resolvable as a compute command.
  wrapdir="$P/project/.workflows/scripts/vendor-sdk-setup"
  [ "$(cd "$wrapdir" && find . -type f | LC_ALL=C sort)" = "./step_001.sh" ]
  [ -x "$wrapdir/step_001.sh" ]
  [ "$(tail -n 1 "$wrapdir/step_001.sh")" = "npm install @vendor/sdk" ]
  run --separate-stderr bash -c 'cd "$1" && bash "$2" "$3"' _ "$P" "$WFS/resolve-compute-command.sh" \
    "project/.workflows/scripts/vendor-sdk-setup/step_001.sh"
  [ "$status" -eq 0 ]

  # The paired confirm comes directly before its compute step; the other two rows are manual steps.
  [ "$(jq -c '[.steps[] | [.id, .type]]' "$def")" = \
    '[["step_001_confirm","confirm"],["step_001","compute"],["step_002","confirm"],["step_003","confirm"]]' ]
  [ "$(jq -r '.steps[1].command' "$def")" = "project/.workflows/scripts/vendor-sdk-setup/step_001.sh" ]
  assert_contains "$(jq -r '.steps[0].prompt' "$def")" "project/.workflows/scripts/vendor-sdk-setup/step_001.sh"
  assert_contains "$(jq -r '.steps[0].prompt' "$def")" "npm install @vendor/sdk"

  # The secret survives only as a placeholder for an input with no value and no default.
  [ "$(jq -r '.steps[2].prompt' "$def")" = 'export VENDOR_API_KEY=${inputs.vendor_api_key}' ]
  [ "$(jq -c '[.inputs[].name]' "$def")" = '["vendor_api_key"]' ]
  [ "$(jq -c '[.inputs[] | has("default") or has("value")] | unique' "$def")" = '[false]' ]
  [ "$(jq -c '.provenance.source' "$def")" = '"external-url"' ]
  # The key exists only in the untrusted snapshot: not in the recording, the definition, the candidates or the
  # wrapper, nor anywhere else the scenario wrote.
  [ -z "$(grep -rlF "$FAKE_KEY" "$T" | grep -vF "$snapdir/" || true)" ]
  ident
  run --separate-stderr bash "$CAP/check-portability.sh" check --recording "$rec" "${IDENT[@]}" "$def"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # And it runs with j.workflow's own runner (epic DoD). For this run only, npm is a success stub that logs to its own
  # file (not the network log), so the wrapper's verbatim `npm install @vendor/sdk` is seen running. The key input
  # gets a run-time value that is not the guide's key.
  local run_id npmlog="$T/npm-stub.log"
  printf '#!/bin/sh\nprintf "npm %%s\\n" "$*" >> "%s"\nexit 0\n' "$npmlog" > "$T/bin/npm"
  run_id="$(in_b "$P" "$WFS/run-state.sh" start vendor-sdk-setup --input vendor_api_key=run-time-value)"
  [ -n "$run_id" ]
  answer_gate "$P" "$run_id" step_001_confirm
  answer_gate "$P" "$run_id" step_002
  answer_gate "$P" "$run_id" step_003
  run --separate-stderr in_b "$P" "$WFS/next-step.sh" "$run_id"
  [ "$status" -eq 0 ]
  [ "$(jq -r .signal <<<"$output")" = "complete" ]
  [ "$(in_b "$P" "$WFS/run-state.sh" status "$run_id" | jq -c '[.status, [.steps[] | [.id, .status]]]')" = \
    '["completed",[["step_001_confirm","completed"],["step_001","completed"],["step_002","completed"],["step_003","completed"]]]' ]
  [ "$(cat "$npmlog")" = "npm install @vendor/sdk" ]
  [ -z "$(grep -rlF "$FAKE_KEY" "$T" | grep -vF "$snapdir/" || true)" ]

  assert_isolated
}

# ---------------------------------------------------------------------------
# scenario 3: export from project A, import into project B, the compute command resolves and runs there
# ---------------------------------------------------------------------------

scenario_export_import() {
  use_layout "$1"
  local A="$T/a" B="$T/b" cands="$T/candidates.json" snap rec def pkg="$T/release-steps.workflow.tar.gz" before
  local def_b run_id cmd
  new_project "$A"
  new_project "$B"

  # Capture in A: a pasted list of two steps, the version confirmed as a parameter, the wrapper confirmed.
  export JENGA_PROJECT_ROOT="$A"
  snap="$(bash "$CAP/snapshot-external.sh" paste --out-dir "$T/snapshots" < "$FIX/e2e-release-steps.txt")"
  bash "$CAP/extract-steps.sh" range 1 2 --kind pasted --out "$cands" "$(jq -r .path <<<"$snap")" 2>/dev/null
  bash "$CAP/scan-secrets.sh" scan --apply "$cands" >/dev/null
  rec="$(bash "$CAP/write-capture.sh" create --source pasted --source-ref "$(jq -r .source_ref <<<"$snap")" \
    --dir "$T/recs" "$cands" "Release steps")"
  ident
  bash "$CAP/detect-parameters.sh" propose "${IDENT[@]}" --package-name '' --apply "$cands" >/dev/null
  fill_proposals "$cands"
  [ "$(jq -c '[.steps[].step_type]' "$cands")" = '["compute","confirm"]' ]
  bash "$CAP/record-review.sh" accept "$rec" "$cands" 1 >/dev/null
  bash "$CAP/record-review.sh" decide "$rec" 1 params version=1.4.0 --replace >/dev/null
  bash "$CAP/record-review.sh" decide "$rec" 2 include >/dev/null
  bash "$CAP/record-review.sh" decide "$rec" 2 type confirm >/dev/null
  bash "$CAP/record-review.sh" decide "$rec" 2 params none >/dev/null
  confirm_wrapper "$rec" 1 >/dev/null
  bash "$CAP/write-capture.sh" seal "$rec" "$cands" >/dev/null
  run --separate-stderr bash "$CAP/write-capture.sh" emit "$rec"
  [ "$status" -eq 0 ]
  def="$output"
  run --separate-stderr bash "$WFS/validate-workflow.sh" "$def"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.steps[] | [.id, .type]]' "$def")" = \
    '[["step_001_confirm","confirm"],["step_001","compute"],["step_002","confirm"]]' ]
  [ "$(jq -c '.steps[1].args' "$def")" = '["${inputs.version}"]' ]

  # Export from A: the definition and the wrapper, nothing else.
  run --separate-stderr bash -c 'cd "$1" && bash "$2" --out "$3" release-steps' _ "$A" "$CAP/export-package.sh" "$pkg"
  [ "$status" -eq 0 ]
  [ "$output" = "$pkg" ]
  [ "$(tar -tzf "$pkg" | grep -v '/$' | LC_ALL=C sort | tr '\n' ' ')" = \
    "definition/release-steps.json manifest.json scripts/step_001.sh " ]

  # Import into B: inspect writes nothing, install with --confirm writes and validates.
  export JENGA_PROJECT_ROOT="$B"
  before="$(cd "$B" && find . -print | LC_ALL=C sort)"
  run --separate-stderr bash -c 'cd "$1" && bash "$2" inspect "$3"' _ "$B" "$CAP/import-package.sh" "$pkg"
  [ "$status" -eq 0 ]
  assert_contains "$output" "collision    none"
  assert_contains "$output" "command      step_001 project/.workflows/scripts/release-steps/step_001.sh"
  [ "$(cd "$B" && find . -print | LC_ALL=C sort)" = "$before" ]
  run --separate-stderr bash -c 'cd "$1" && bash "$2" install "$3" --confirm' _ "$B" "$CAP/import-package.sh" "$pkg"
  [ "$status" -eq 0 ]
  def_b="$output"
  [ "$def_b" = "$(cd "$B" && pwd -P)/project/.workflows/release-steps.json" ]
  run --separate-stderr bash "$WFS/validate-workflow.sh" "$def_b"
  [ "$status" -eq 0 ]
  cmp "$A/project/.workflows/scripts/release-steps/step_001.sh" "$B/project/.workflows/scripts/release-steps/step_001.sh"
  [ -x "$B/project/.workflows/scripts/release-steps/step_001.sh" ]

  # The imported compute command resolves inside B, to B's own copy of the wrapper.
  cmd="$(jq -r '.steps[] | select(.type == "compute") | .command' "$def_b")"
  [ "$cmd" = "project/.workflows/scripts/release-steps/step_001.sh" ]
  run --separate-stderr bash -c 'cd "$1" && bash "$2" "$3"' _ "$B" "$WFS/resolve-compute-command.sh" "$cmd"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cd "$B/project/.workflows/scripts/release-steps" && pwd -P)/step_001.sh" ]
  run --separate-stderr bash -c 'cd "$1" && bash "$2" lookup release-steps' _ "$B" "$WFS/load-workflows.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r .source <<<"$output")" = "project" ]

  # And it runs in B: the paired gate is answered, then the compute step runs the wrapper with B's input.
  run_id="$(in_b "$B" "$WFS/run-state.sh" start release-steps --input version=2.0.0)"
  [ -n "$run_id" ]
  answer_gate "$B" "$run_id" step_001_confirm
  answer_gate "$B" "$run_id" step_002
  run --separate-stderr in_b "$B" "$WFS/next-step.sh" "$run_id"
  [ "$status" -eq 0 ]
  [ "$(jq -r .signal <<<"$output")" = "complete" ]
  [ "$(in_b "$B" "$WFS/run-state.sh" status "$run_id" | jq -c '[.status, [.steps[] | [.id, .status]]]')" = \
    '["completed",[["step_001_confirm","completed"],["step_001","completed"],["step_002","completed"]]]' ]
  [ -d "$B/releases/2.0.0" ]
  [ ! -e "$B/releases/1.4.0" ]
  [ ! -e "$A/releases" ]

  assert_isolated
}

# in_b <project> <script> [args]: a workflow script run inside the project, in a session of its own.
in_b() {
  local proj="$1"
  shift
  (cd "$proj" && JENGA_PROJECT_ROOT="$proj" CLAUDE_CODE_SESSION_ID="e2e-import-run" bash "$@")
}

# answer_gate <project> <run> <step>: the next action is that confirm step; it waits, and the answer is "Yes".
answer_gate() {
  local out
  out="$(in_b "$1" "$WFS/next-step.sh" "$2")"
  [ "$(jq -r '[.signal, .step_id, .type] | join(" ")' <<<"$out")" = "step $3 confirm" ] || { echo "$out"; return 1; }
  out="$(in_b "$1" "$WFS/next-step.sh" "$2")"
  [ "$(jq -r .signal <<<"$out")" = "awaiting_confirmation" ] || { echo "$out"; return 1; }
  out="$(in_b "$1" "$WFS/step-confirm.sh" reply "$2" "$3" 1)"
  [ "$(jq -r .option <<<"$out")" = "Yes" ] || { echo "$out"; return 1; }
}

# ---------------------------------------------------------------------------
# the tests
# ---------------------------------------------------------------------------

@test "mirror layout: the public-shaped tree applies .publicignore and holds every script and fixture the scenarios read" {
  use_layout mirror
  [ ! -e "$FW/.git" ]
  [ -f "$FW/.publicignore" ]
  # A skill the blocklist keeps private is absent, so the tree is the ship list and not a plain copy.
  [ -d "$REPO_ROOT/skills/j-mirror-public" ]
  [ ! -e "$FW/skills/j-mirror-public" ]
  [ ! -e "$FW/project/board" ]
  [ "$(cd "$FW/$FIXTURE_REL" && find . -name 'e2e-*' | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' ')" = \
    "e2e-release-steps.txt e2e-session-transcript.jsonl e2e-vendor-sdk-guide.md " ]
}

@test "transcript capture (private checkout): a range of a session, one parameter, a valid definition" {
  scenario_transcript checkout
}

@test "transcript capture (public-shaped mirror layout): a range of a session, one parameter, a valid definition" {
  scenario_transcript mirror
}

@test "external capture (private checkout): one wrapper, its paired confirm and a secret placeholder" {
  scenario_external checkout
}

@test "external capture (public-shaped mirror layout): one wrapper, its paired confirm and a secret placeholder" {
  scenario_external mirror
}

@test "export and import (private checkout): the imported compute command resolves and runs in the other project" {
  scenario_export_import checkout
}

@test "export and import (public-shaped mirror layout): the imported compute command resolves and runs in the other project" {
  scenario_export_import mirror
}
