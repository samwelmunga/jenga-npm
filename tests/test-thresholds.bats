#!/usr/bin/env bats
# bats file_tags=tier:unit
#
# Coverage for skills/j-test/scripts/test-thresholds.sh, the one reader of the two
# long-running test thresholds (E77_S06_T02), written by E77_S06_T08.
#
# Fixture only: every config is a throwaway file under $BATS_TEST_TMPDIR, passed with
# --config. The one exception is the shipped init template
# (skills/j-init/assets/test-config_template.json), which is only read.
#
# The subject ships, so this file ships. It names no private tooling.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/j-test/scripts/test-thresholds.sh"
TEMPLATE="$REPO_ROOT/skills/j-init/assets/test-config_template.json"

setup() {
  CFG="$BATS_TEST_TMPDIR/test-config.json"
}

# run_get <name> [args]: stdout lands in $stdout_text, stderr in $stderr_text, exit code in $rc.
run_get() {
  local name="$1"
  shift
  rc=0
  stdout_text="$(bash "$SCRIPT" get "$name" --config "$CFG" "$@" 2>"$BATS_TEST_TMPDIR/stderr")" || rc=$?
  stderr_text="$(cat "$BATS_TEST_TMPDIR/stderr")"
}

@test "E77_S06_T02: the shipped init template yields 50 for mirror-gate and 600 for manual-only" {
  run bash "$SCRIPT" get mirror-gate --config "$TEMPLATE"
  [ "$status" -eq 0 ]
  [ "$output" = "50" ]
  run bash "$SCRIPT" get manual-only --config "$TEMPLATE"
  [ "$status" -eq 0 ]
  [ "$output" = "600" ]
}

@test "E77_S06_T02: a valid value in the config is read back" {
  printf '%s\n' '{"mirror_gate_threshold_seconds": 75, "manual_only_threshold_seconds": 900}' > "$CFG"
  run_get mirror-gate
  [ "$rc" -eq 0 ]
  [ "$stdout_text" = "75" ]
  [ -z "$stderr_text" ]
  run_get manual-only
  [ "$stdout_text" = "900" ]
}

@test "E77_S06_T02: an absent key prints the default silently, exit 0" {
  printf '%s\n' '{"unrelated": true}' > "$CFG"
  run_get mirror-gate
  [ "$rc" -eq 0 ]
  [ "$stdout_text" = "50" ]
  [ -z "$stderr_text" ]
  run_get manual-only
  [ "$stdout_text" = "600" ]
  [ -z "$stderr_text" ]
}

@test "E77_S06_T02: an absent or blank config file prints the defaults silently" {
  run_get mirror-gate
  [ "$rc" -eq 0 ]
  [ "$stdout_text" = "50" ]
  [ -z "$stderr_text" ]
  printf '  \n' > "$CFG"
  run_get manual-only
  [ "$rc" -eq 0 ]
  [ "$stdout_text" = "600" ]
  [ -z "$stderr_text" ]
}

@test "E77_S06_T02: a non-integer value falls back to the default with a stderr warning, exit 0" {
  printf '%s\n' '{"mirror_gate_threshold_seconds": "ten"}' > "$CFG"
  run_get mirror-gate
  [ "$rc" -eq 0 ]
  [ "$stdout_text" = "50" ]
  case "$stderr_text" in
    *mirror_gate_threshold_seconds*'"ten"'*) ;;
    *) echo "stderr: $stderr_text"; return 1 ;;
  esac
}

@test "E77_S06_T02: zero, a negative number, a fraction, a boolean and null all fall back with a warning" {
  local bad
  for bad in 0 -5 1.5 true null; do
    printf '{"mirror_gate_threshold_seconds": %s}\n' "$bad" > "$CFG"
    run_get mirror-gate
    [ "$rc" -eq 0 ]
    [ "$stdout_text" = "50" ]
    case "$stderr_text" in
      *mirror_gate_threshold_seconds*) ;;
      *) echo "no warning for $bad: $stderr_text"; return 1 ;;
    esac
  done
}

@test "E77_S06_T02: a value above the 2147483647 cap falls back with a warning" {
  printf '%s\n' '{"manual_only_threshold_seconds": 2147483648}' > "$CFG"
  run_get manual-only
  [ "$rc" -eq 0 ]
  [ "$stdout_text" = "600" ]
  case "$stderr_text" in
    *manual_only_threshold_seconds*) ;;
    *) echo "stderr: $stderr_text"; return 1 ;;
  esac
}

@test "E77_S06_T02: an invalid value for the other key does not warn on get" {
  printf '%s\n' '{"manual_only_threshold_seconds": "junk", "mirror_gate_threshold_seconds": 40}' > "$CFG"
  run_get mirror-gate
  [ "$rc" -eq 0 ]
  [ "$stdout_text" = "40" ]
  [ -z "$stderr_text" ]
}

@test "E77_S06_T02: list prints every threshold as name-TAB-value lines" {
  # E95_S02_T02 added confirm-file-count and ask-before-run; absent here, so defaults.
  printf '%s\n' '{"mirror_gate_threshold_seconds": 30, "manual_only_threshold_seconds": 700}' > "$CFG"
  run bash "$SCRIPT" list --config "$CFG"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'mirror-gate\t30\nmanual-only\t700\nconfirm-file-count\t60\nask-before-run\t300')" ]
}

@test "E77_S06_T02: pre-push-gate is an alias of mirror-gate" {
  printf '%s\n' '{"mirror_gate_threshold_seconds": 33}' > "$CFG"
  run bash "$SCRIPT" get pre-push-gate --config "$CFG"
  [ "$status" -eq 0 ]
  [ "$output" = "33" ]
}

@test "E77_S06_T02: manual-only below mirror-gate warns on stderr and still prints the values" {
  printf '%s\n' '{"mirror_gate_threshold_seconds": 100, "manual_only_threshold_seconds": 60}' > "$CFG"
  run_get manual-only
  [ "$rc" -eq 0 ]
  [ "$stdout_text" = "60" ]
  case "$stderr_text" in
    *"is below"*) ;;
    *) echo "stderr: $stderr_text"; return 1 ;;
  esac
}

@test "E77_S06_T02: malformed JSON exits 6 with empty stdout" {
  printf '%s\n' '{not json' > "$CFG"
  run_get mirror-gate
  [ "$rc" -eq 6 ]
  [ -z "$stdout_text" ]
  [ -n "$stderr_text" ]
}

@test "E77_S06_T02: a JSON array (not an object) exits 6" {
  printf '%s\n' '[1,2,3]' > "$CFG"
  run_get manual-only
  [ "$rc" -eq 6 ]
  [ -z "$stdout_text" ]
}

@test "E77_S06_T02: usage errors exit 2" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" get
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" get nonsense --config "$CFG"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" frobnicate
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" get mirror-gate --bogus
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" get mirror-gate --root "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 2 ]
}

@test "E77_S06_T02: --root resolves the configs directory under that root" {
  mkdir -p "$BATS_TEST_TMPDIR/proj/project/configs"
  printf '%s\n' '{"mirror_gate_threshold_seconds": 61}' > "$BATS_TEST_TMPDIR/proj/project/configs/test-config.json"
  run env -u JENGA_PROJECT_ROOT bash "$SCRIPT" get mirror-gate --root "$BATS_TEST_TMPDIR/proj"
  [ "$status" -eq 0 ]
  [ "$output" = "61" ]
}

@test "E77_S06_T02: the script only reads: the config is byte-identical after a run" {
  printf '%s\n' '{"mirror_gate_threshold_seconds": "bad"}' > "$CFG"
  before="$(cksum < "$CFG")"
  run_get mirror-gate
  run bash "$SCRIPT" list --config "$CFG"
  after="$(cksum < "$CFG")"
  [ "$before" = "$after" ]
}

@test "E77_S06_T02: the script and its help carry no reference to the private mirror tooling" {
  needle="mirror""-public"   # split so this shipped file never carries the private skill name
  run grep -n "$needle" "$SCRIPT"
  [ "$status" -ne 0 ]
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  case "$output" in
    *"$needle"*) return 1 ;;
  esac
}
