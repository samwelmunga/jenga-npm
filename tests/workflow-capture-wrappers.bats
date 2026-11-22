#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# Wrapper scripts for captured compute steps (epic E103, task E103_S04_T02):
#
#   1. generate-wrapper.sh show derives <workflows>/scripts/<id>/<step_id>.sh: the command verbatim, set -euo
#      pipefail, no eval, run inputs as positional arguments that are only ever expanded inside double quotes.
#   2. write writes only after a confirmation bound to the shown sha256, mode 755, resolving through
#      scripts/workflow/resolve-compute-command.sh with exit 0, and records the decision (record-answer.sh's
#      `wrapper` kind). decline turns the step into a confirm step. pending lists what is not settled.
#   3. emit-workflow.sh puts a confirm step directly before every generated compute step; the definition passes
#      validate-workflow.sh, re-emits byte-identically, and refuses a wrapper that was edited after confirmation.
#   4. The wrapper directory travels in export-package.sh's package and installs with import-package.sh.
#   5. Nothing under scripts/workflow/ is written by any of this.
#
# Isolation: everything is written under $BATS_TEST_TMPDIR. JENGA_PROJECT_ROOT names a throwaway project whose
# workflows directory is project/.workflows. No captured command is ever run except the harmless printf fixture,
# through the wrapper, to prove an argument is not interpreted. Every script is called with `bash`.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
GW="$REPO_ROOT/skills/j-workflow-capture/scripts/generate-wrapper.sh"
WC="$REPO_ROOT/skills/j-workflow-capture/scripts/write-capture.sh"
RR="$REPO_ROOT/skills/j-workflow-capture/scripts/record-review.sh"
EP="$REPO_ROOT/skills/j-workflow-capture/scripts/export-package.sh"
IP="$REPO_ROOT/skills/j-workflow-capture/scripts/import-package.sh"
RA="$REPO_ROOT/skills/j-workflow-recorder/scripts/record-answer.sh"
VALIDATOR="$REPO_ROOT/scripts/workflow/validate-workflow.sh"
RESOLVE="$REPO_ROOT/scripts/workflow/resolve-compute-command.sh"

WRAPDIR_REL="project/.workflows/scripts/vendor-setup"

setup() {
  T="$BATS_TEST_TMPDIR"
  PROJ="$T/proj"
  mkdir -p "$PROJ/project/configs"
  printf '%s\n' '{"paths":{"workflows":"project/.workflows"}}' > "$PROJ/project/configs/workflow.json"
  RECS="$T/recs"
  CANDS="$T/candidates.json"
  unset JENGA_WORKFLOWS_TEST_ROOT JENGA_RECORDING_DIR JENGA_WORKFLOW_LOADER JENGA_RUN_STATE
  unset CLAUDE_CODE_SESSION_ID JENGA_SESSION_ID JENGA_RECORDING_SESSION_ID
  export JENGA_PROJECT_ROOT="$PROJ"
  export JENGA_RECORDER_NOW=2026-11-21T03:04:05Z
  export JENGA_RECORDING_STATE_DIR="$T/state"
}

# A reviewed (not yet sealed) captured recording:
#   1 npm install @vendor/sdk                               compute, no parameters
#   2 aws s3 cp ... region/bucket in plain, double and single quotes    compute, two parameters
#   3 log in to the vendor dashboard                         confirm
#   4 printf ... with one input                              compute, one parameter
build_recording() {
  cat > "$CANDS" <<'JSON'
{"candidate_steps_version": 1, "steps": [
  {"n": 1, "text": "npm install @vendor/sdk"},
  {"n": 2, "text": "aws s3 cp ./build s3://my-bucket/app --region eu-west-1 --profile 'team eu-west-1' --tag \"env eu-west-1\""},
  {"n": 3, "text": "log in to the vendor dashboard"},
  {"n": 4, "text": "printf 'greeting: %s\\n' hello-world"}
]}
JSON
  REC="$(bash "$WC" create --source pasted --dir "$RECS" "$CANDS" "vendor setup")"
  local n
  for n in 1 2 3 4; do bash "$RR" decide "$REC" "$n" include >/dev/null; done
  bash "$RR" decide "$REC" 1 type compute >/dev/null
  bash "$RR" decide "$REC" 1 params none >/dev/null
  bash "$RR" decide "$REC" 2 type compute >/dev/null
  bash "$RR" decide "$REC" 2 params region=eu-west-1 bucket=my-bucket >/dev/null
  bash "$RR" decide "$REC" 3 type confirm >/dev/null
  bash "$RR" decide "$REC" 3 params none >/dev/null
  bash "$RR" decide "$REC" 4 type compute >/dev/null
  bash "$RR" decide "$REC" 4 params greeting=hello-world >/dev/null
}

# A fresh one-step recording with the given text, judged compute, with the given parameters (default none).
SINGLE_N=0
build_single() {
  local text="$1" params="${2:-none}"
  SINGLE_N=$((SINGLE_N + 1))
  jq -n --arg t "$text" '{candidate_steps_version: 1, steps: [{n: 1, text: $t}]}' > "$CANDS"
  REC="$(bash "$WC" create --source pasted --dir "$RECS" "$CANDS" "single step $SINGLE_N")"
  bash "$RR" decide "$REC" 1 include >/dev/null
  bash "$RR" decide "$REC" 1 type compute >/dev/null
  # shellcheck disable=SC2086
  bash "$RR" decide "$REC" 1 params $params >/dev/null
}

sha_of() { bash "$GW" show "$@" | sed -n 's/^sha256 *//p'; }

# The file content between the review's markers.
content_of() { bash "$GW" show "$@" | awk '/^===== BEGIN /{on=1; next} /^===== END /{on=0} on'; }

confirm_all() {
  local n
  for n in 1 2 4; do bash "$GW" write --confirm "$(sha_of "$REC" "$n")" "$REC" "$n" >/dev/null; done
}

# Prints every unquoted expansion of a positional or special parameter in the non-comment lines of a script:
# $1, ${1}, $@, $*, $# outside double quotes (single quotes do not expand, so they cannot leak either).
unquoted_arg_expansions() {
  awk '
    /^[[:space:]]*#/ { next }
    {
      s = $0; st = 0; L = length(s)
      for (i = 1; i <= L; i++) {
        c = substr(s, i, 1)
        if (st == 0) {
          if (c == "\\") { i++; continue }
          if (c == "'\''") { st = 1; continue }
          if (c == "\"") { st = 2; continue }
          if (c == "$" && substr(s, i + 1) ~ /^([0-9@*#]|\{[0-9@*#])/) print NR ": " s
        } else if (st == 1) {
          if (c == "'\''") st = 0
        } else {
          if (c == "\\") { i++; continue }
          if (c == "\"") st = 0
        }
      }
    }' "$1"
}

# ---- 1. the derived file -------------------------------------------------------------------------------------------

@test "show: the command verbatim, set -euo pipefail, no eval, and nothing is written" {
  build_recording
  run --separate-stderr bash "$GW" show "$REC" 1
  [ "$status" -eq 0 ]
  assert_contains "$output" "path      $WRAPDIR_REL/step_001.sh"
  assert_contains "$output" "args      -"
  assert_contains "$output" "timeout   600"
  assert_contains "$output" "on-disk   new"
  assert_contains "$output" "recorded  none"
  content_of "$REC" 1 > "$T/w1.sh"
  [ "$(sed -n '1p' "$T/w1.sh")" = '#!/usr/bin/env bash' ]
  grep -Fxq 'set -euo pipefail' "$T/w1.sh"
  grep -Fxq 'npm install @vendor/sdk' "$T/w1.sh"
  run ! grep -Ewq 'eval' "$T/w1.sh"
  # The printed sha256 is the content's own.
  [ "$(sha_of "$REC" 1)" = "$(shasum -a 256 "$T/w1.sh" | awk '{print $1}')" ]
  # Nothing written: no wrapper directory, no annotation.
  [ ! -e "$PROJ/project/.workflows" ]
  run bash "$RA" --value "$REC" step-001 wrapper
  [ "$status" -eq 1 ]
}

@test "show: run inputs become positional arguments, quoted in every quoting context, never interpolated" {
  build_recording
  content_of "$REC" 2 > "$T/w2.sh"
  # Exactly the command, with each input replaced by its positional parameter.
  grep -Fxq "aws s3 cp ./build s3://\"\${1}\"/app --region \"\${2}\" --profile 'team '\"\${2}\"'' --tag \"env \${2}\"" "$T/w2.sh"
  grep -Fxq '# Arguments: 1=bucket 2=region' "$T/w2.sh"
  # Neither literal was baked into the body.
  run ! grep -Fq 'eu-west-1' "$T/w2.sh"
  run ! grep -Fq 'my-bucket' "$T/w2.sh"
  # No unquoted argument expansion anywhere, and no eval.
  [ -z "$(unquoted_arg_expansions "$T/w2.sh")" ]
  run ! grep -Ewq 'eval' "$T/w2.sh"
  bash -n "$T/w2.sh"
  run --separate-stderr bash "$GW" show "$REC" 2
  assert_contains "$output" "args      bucket region"
  assert_contains "$output" "timeout   -"
}

@test "the scan for unquoted argument expansion bites" {
  printf '%s\n' '#!/usr/bin/env bash' 'echo $1' 'echo "${2}" ok' "echo '\$3' fine" > "$T/bad.sh"
  run unquoted_arg_expansions "$T/bad.sh"
  [ "$output" = '2: echo $1' ]
}

@test "the written wrapper passes an argument as data: shell syntax in an input is never executed" {
  build_recording
  bash "$GW" write --confirm "$(sha_of "$REC" 4)" "$REC" 4 >/dev/null
  W="$PROJ/$WRAPDIR_REL/step_004.sh"
  run bash "$W" "\$(touch $T/pwned); \`touch $T/pwned2\`"
  [ "$status" -eq 0 ]
  [ "$output" = "greeting: \$(touch $T/pwned); \`touch $T/pwned2\`" ]
  [ ! -e "$T/pwned" ]
  [ ! -e "$T/pwned2" ]
  # The argument count is enforced.
  run bash "$W"
  [ "$status" -eq 64 ]
  assert_contains "$output" "expected 1 argument(s)"
}

@test "show refuses what cannot be wrapped safely: eval, positional parameters, undeclared inputs, several lines" {
  build_single 'eval "$(vendor env)"'
  run --separate-stderr bash "$GW" show "$REC" 1
  [ "$status" -eq 5 ]
  assert_contains "$stderr" "eval"

  build_single 'vendor deploy "$1"'
  run --separate-stderr bash "$GW" show "$REC" 1
  [ "$status" -eq 5 ]
  assert_contains "$stderr" "positional"

  build_single 'vendor deploy ${inputs.target}'
  run --separate-stderr bash "$GW" show "$REC" 1
  [ "$status" -eq 5 ]
  assert_contains "$stderr" "inputs.target"

  build_single "$(printf 'npm install\nnpm test')"
  run --separate-stderr bash "$GW" show "$REC" 1
  [ "$status" -eq 5 ]
  assert_contains "$stderr" "exactly one command line"

  build_single "echo 'unbalanced"
  run --separate-stderr bash "$GW" show "$REC" 1
  [ "$status" -eq 5 ]
}

@test "show refuses a step that is not judged compute, and one that is excluded" {
  build_recording
  run --separate-stderr bash "$GW" show "$REC" 3
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "not judged compute"
  bash "$RR" decide "$REC" 1 exclude --replace >/dev/null
  run --separate-stderr bash "$GW" show "$REC" 1
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "excluded"
}

@test "a secret input named in the review replaces its redaction marker and arrives as an argument" {
  build_single 'vendor configure --token <redacted>' 'api_token'
  content_of "$REC" 1 > "$T/w.sh"
  grep -Fxq 'vendor configure --token "${1}"' "$T/w.sh"
  run ! grep -Fq 'redacted' "$T/w.sh"
}

# ---- 2. confirmation, write, decline, pending ------------------------------------------------------------------------

@test "write: no confirmation or a confirmation of other content writes nothing" {
  build_recording
  run --separate-stderr bash "$GW" write "$REC" 1
  [ "$status" -eq 8 ]
  run --separate-stderr bash "$GW" write --confirm "$(sha_of "$REC" 2)" "$REC" 1
  [ "$status" -eq 9 ]
  [ ! -e "$PROJ/project/.workflows" ]
  run bash "$RA" --value "$REC" step-001 wrapper
  [ "$status" -eq 1 ]
}

@test "write: the confirmed file is executable, resolves through resolve-compute-command.sh and is recorded" {
  build_recording
  sha="$(sha_of "$REC" 1)"
  run --separate-stderr bash "$GW" write --confirm "$sha" "$REC" 1
  [ "$status" -eq 0 ]
  [ "$output" = "$WRAPDIR_REL/step_001.sh" ]
  W="$PROJ/$WRAPDIR_REL/step_001.sh"
  [ -f "$W" ] && [ -x "$W" ]
  [ "$(shasum -a 256 "$W" | awk '{print $1}')" = "$sha" ]
  run bash -c "cd '$PROJ' && bash '$RESOLVE' '$WRAPDIR_REL/step_001.sh'"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cd "$PROJ/$WRAPDIR_REL" && pwd -P)/step_001.sh" ]
  [ "$(bash "$RA" --value "$REC" step-001 wrapper)" = "confirmed" ]
  [ "$(bash "$RA" --text "$REC" step-001 wrapper)" = "$(printf 'path=%s\nsha256=%s\nargs=\ntimeout_seconds=600' "$WRAPDIR_REL/step_001.sh" "$sha")" ]
  # No stray temporary file is left in the wrapper directory (it would travel in an export).
  [ "$(ls -A "$PROJ/$WRAPDIR_REL")" = "step_001.sh" ]
  # Writing the same content again is a no-op success.
  run --separate-stderr bash "$GW" write --confirm "$sha" "$REC" 1
  [ "$status" -eq 0 ]
}

@test "write: --timeout is recorded; another file at the path needs --replace" {
  build_recording
  mkdir -p "$PROJ/$WRAPDIR_REL"
  printf '#!/bin/sh\necho other\n' > "$PROJ/$WRAPDIR_REL/step_002.sh"
  sha="$(sha_of --timeout 900 "$REC" 2)"
  run --separate-stderr bash "$GW" write --confirm "$sha" --timeout 900 "$REC" 2
  [ "$status" -eq 7 ]
  grep -q 'echo other' "$PROJ/$WRAPDIR_REL/step_002.sh"
  run --separate-stderr bash "$GW" write --confirm "$sha" --timeout 900 --replace "$REC" 2
  [ "$status" -eq 0 ]
  [ "$(shasum -a 256 "$PROJ/$WRAPDIR_REL/step_002.sh" | awk '{print $1}')" = "$sha" ]
  bash "$RA" --text "$REC" step-002 wrapper | grep -Fxq 'timeout_seconds=900'
  bash "$RA" --text "$REC" step-002 wrapper | grep -Fxq 'args=bucket region'
}

@test "decline: the step becomes a confirm step and no wrapper is written" {
  build_recording
  run --separate-stderr bash "$GW" decline "$REC" 1
  [ "$status" -eq 0 ]
  [ "$(bash "$RA" --value "$REC" step-001 wrapper)" = "declined" ]
  [ "$(bash "$RA" --value "$REC" step-001 step-type)" = "confirm" ]
  [ ! -e "$PROJ/$WRAPDIR_REL/step_001.sh" ]
}

@test "decline after a confirmation removes the wrapper it wrote" {
  build_recording
  bash "$GW" write --confirm "$(sha_of "$REC" 1)" "$REC" 1 >/dev/null
  [ -f "$PROJ/$WRAPDIR_REL/step_001.sh" ]
  run --separate-stderr bash "$GW" decline "$REC" 1
  [ "$status" -eq 0 ]
  [ ! -e "$PROJ/$WRAPDIR_REL/step_001.sh" ]
}

@test "pending: undecided, then settled, then modified and stale" {
  build_recording
  run --separate-stderr bash "$GW" pending "$REC"
  [ "$status" -eq 9 ]
  [ "$(printf '%s\n' "$output" | cut -f1,2 | tr '\t' ' ' | tr '\n' ',')" = "step-001 undecided,step-002 undecided,step-004 undecided," ]
  confirm_all
  run --separate-stderr bash "$GW" pending "$REC"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf 'echo tampered\n' >> "$PROJ/$WRAPDIR_REL/step_001.sh"
  bash "$RR" decide "$REC" 2 params region=eu-west-1 --replace >/dev/null
  run --separate-stderr bash "$GW" pending "$REC"
  [ "$status" -eq 9 ]
  assert_contains "$output" "step-001"$'\t'"modified"
  assert_contains "$output" "step-002"$'\t'"stale"
}

# ---- 3. emission -----------------------------------------------------------------------------------------------------

@test "emit: a confirm step directly before every generated compute step, and the definition validates" {
  build_recording
  confirm_all
  bash "$WC" seal "$REC" "$CANDS" >/dev/null
  run --separate-stderr bash "$WC" emit "$REC"
  [ "$status" -eq 0 ]
  DEF="$output"
  bash "$VALIDATOR" "$DEF"
  [ "$(jq -c '[.steps[] | [.id, .type]]' "$DEF")" = \
    '[["step_001_confirm","confirm"],["step_001","compute"],["step_002_confirm","confirm"],["step_002","compute"],["step_003","confirm"],["step_004_confirm","confirm"],["step_004","compute"]]' ]
  # Every compute step is preceded by a confirm step.
  [ "$(jq '[.steps as $s | range(0; $s | length) | select($s[.].type == "compute") | select(. == 0 or $s[. - 1].type != "confirm")] | length' "$DEF")" -eq 0 ]
  [ "$(jq -c '.steps[1] | [.command, .args, .timeout_seconds]' "$DEF")" = "[\"$WRAPDIR_REL/step_001.sh\",null,600]" ]
  [ "$(jq -c '.steps[3] | [.command, .args, .timeout_seconds]' "$DEF")" = "[\"$WRAPDIR_REL/step_002.sh\",[\"\${inputs.bucket}\",\"\${inputs.region}\"],null]" ]
  [ "$(jq -c '[.inputs[].name]' "$DEF")" = '["region","bucket","greeting"]' ]
  # Every compute command resolves through resolve-compute-command.sh.
  for c in $(jq -r '.steps[] | select(.type == "compute") | .command' "$DEF"); do
    (cd "$PROJ" && bash "$RESOLVE" "$c" >/dev/null)
  done
  # Neither literal is in the definition.
  run ! grep -Fq 'eu-west-1' "$DEF"
  # Re-emission is byte-identical.
  cp "$DEF" "$T/first.json"
  bash "$WC" emit "$REC" >/dev/null
  cmp -s "$DEF" "$T/first.json"
}

@test "emit: a declined wrapper is a plain confirm step" {
  build_recording
  bash "$GW" decline "$REC" 1 >/dev/null
  bash "$GW" write --confirm "$(sha_of "$REC" 2)" "$REC" 2 >/dev/null
  bash "$GW" decline "$REC" 4 >/dev/null
  bash "$WC" seal "$REC" "$CANDS" >/dev/null
  DEF="$(bash "$WC" emit "$REC")"
  bash "$VALIDATOR" "$DEF"
  [ "$(jq -c '[.steps[] | [.id, .type]]' "$DEF")" = \
    '[["step_001","confirm"],["step_002_confirm","confirm"],["step_002","compute"],["step_003","confirm"],["step_004","confirm"]]' ]
}

@test "emit: a wrapper edited after its confirmation is refused with exit 10 and nothing is emitted" {
  build_recording
  confirm_all
  bash "$WC" seal "$REC" "$CANDS" >/dev/null
  printf 'echo tampered\n' >> "$PROJ/$WRAPDIR_REL/step_002.sh"
  run --separate-stderr bash "$WC" emit "$REC"
  [ "$status" -eq 10 ]
  assert_contains "$stderr" "step-002"
  assert_contains "$stderr" "not the content the user confirmed"
  [ ! -e "$PROJ/project/.workflows/vendor-setup.json" ]
}

@test "record-answer: the wrapper kind takes only its machine shape or declined" {
  build_recording
  run bash "$RA" "$REC" step-001 wrapper "path=../outside.sh"
  [ "$status" -eq 2 ]
  run bash -c "printf 'path=a/b.sh\nsha256=abc\nargs=\n' | bash '$RA' '$REC' step-001 wrapper -"
  [ "$status" -eq 2 ]
  run bash -c "printf 'path=a/b.sh\nsha256=%s\nargs=Bad\n' $(printf '%064d' 0) | bash '$RA' '$REC' step-001 wrapper -"
  [ "$status" -eq 2 ]
  run bash "$RA" "$REC" step-001 wrapper no
  [ "$status" -eq 0 ]
  [ "$(bash "$RA" --value "$REC" step-001 wrapper)" = "declined" ]
}

# ---- 4. the package layout -------------------------------------------------------------------------------------------

@test "export and import: the wrappers travel in the package and resolve in the importing project" {
  build_recording
  confirm_all
  bash "$WC" seal "$REC" "$CANDS" >/dev/null
  bash "$WC" emit "$REC" >/dev/null
  PKG="$T/vendor-setup.workflow.tar.gz"
  (cd "$PROJ" && bash "$EP" --out "$PKG" vendor-setup >/dev/null 2>&1)
  [ -f "$PKG" ]
  mkdir -p "$T/unpacked"
  tar -xzf "$PKG" -C "$T/unpacked"
  [ "$(jq -c '[.files[] | select(.role == "script") | [.path, .executable]]' "$T/unpacked/manifest.json")" = \
    '[["scripts/step_001.sh",true],["scripts/step_002.sh",true],["scripts/step_004.sh",true]]' ]

  P2="$T/proj2"
  mkdir -p "$P2/project/configs"
  printf '%s\n' '{"paths":{"workflows":"project/.workflows"}}' > "$P2/project/configs/workflow.json"
  export JENGA_PROJECT_ROOT="$P2"
  run --separate-stderr bash -c "cd '$P2' && bash '$IP' install '$PKG' --confirm --rename vendor-two"
  [ "$status" -eq 0 ]
  DEF2="$P2/project/.workflows/vendor-two.json"
  [ "$(jq -r '.steps[] | select(.type == "compute") | .command' "$DEF2" | tr '\n' ' ')" = \
    "project/.workflows/scripts/vendor-two/step_001.sh project/.workflows/scripts/vendor-two/step_002.sh project/.workflows/scripts/vendor-two/step_004.sh " ]
  for c in $(jq -r '.steps[] | select(.type == "compute") | .command' "$DEF2"); do
    (cd "$P2" && bash "$RESOLVE" "$c" >/dev/null)
  done
}

# ---- 5. scripts/workflow/ is never written -----------------------------------------------------------------------------

@test "the whole flow leaves scripts/workflow/ byte-identical and never names the active-recording pointer" {
  snap() { (cd "$REPO_ROOT/scripts/workflow" && find . -type f -exec shasum -a 256 {} + | sort); }
  before="$(snap)"
  build_recording
  confirm_all
  bash "$GW" decline "$REC" 4 >/dev/null
  bash "$WC" seal "$REC" "$CANDS" >/dev/null
  bash "$WC" emit "$REC" >/dev/null
  [ "$(snap)" = "$before" ]
  run ! grep -Fq 'active-recording.sh' "$GW"
}
