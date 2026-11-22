#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# E100_S03_T09: scripts/merge-settings.sh (E100_S03_T03 to T06); design: project/documentation/e100-s03-merge-design.md.
# Covers the key classes and the manifest: env per key, the permissions.allow opt-in (the yes only through a pseudo-terminal),
# conflict exit 6, manifest write rules, removal (add / update / remove round trip), settings.local.json untouched, --help.
#
# Isolation: every fixture lives under $BATS_TEST_TMPDIR. The script runs against a fixture package root ($PKG, whose
# fragments are written per test, because no shipped fragment declares env) and a throw-away consumer tree ($CONS); no
# repository settings file is written. Paths are canonicalised with pwd -P (macOS /var is a symlink). The terminal answer
# is driven with python3's pty module. Written without being executed by its author; the tester runs it.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/merge-settings.sh"

HOOK_FRAG='{"id":"t-hook","version":1,"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"jenga-fixture-stop"}]}]}}'
ENV_FRAG='{"id":"t-env","version":1,"env":{"JENGA_T_A":"one","JENGA_T_B":"two"}}'
STAY_FRAG='{"id":"t-stay","version":1,"env":{"JENGA_T_S":"stay"}}'
ALLOW_FRAG='{"id":"t-allow","version":1,"permissions":{"allow":[{"rule":"Bash(jt-one *)","optIn":true},{"rule":"Bash(jt-two *)","optIn":true}]}}'

setup() {
  mkdir -p "$BATS_TEST_TMPDIR/pkg" "$BATS_TEST_TMPDIR/cons"
  PKG="$(cd "$BATS_TEST_TMPDIR/pkg" && pwd -P)"
  CONS="$(cd "$BATS_TEST_TMPDIR/cons" && pwd -P)"
  CS="$CONS/.claude/settings.json"; AS="$CONS/.agents/settings.json"
  CM="$CONS/.claude/jenga-settings-manifest.json"; AM="$CONS/.agents/jenga-settings-manifest.json"
  printf '{"version":"9.9.9"}\n' > "$PKG/package.json"
  # A pseudo-terminal driver: runs a command on a pty, types <answer> when the [y/N] prompt appears, prints the transcript,
  # exits with the command's status. The command's stdin, stdout and stderr and its /dev/tty are all the pty.
  PTY="$BATS_TEST_TMPDIR/pty-answer.py"
  cat > "$PTY" <<'PY'
import os, pty, select, sys, time
answer, cmd = sys.argv[1], sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
out = b""; sent = False; end = time.time() + 60
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.5)
    if not r:
        continue
    try:
        d = os.read(fd, 4096)
    except OSError:
        break
    if not d:
        break
    out += d
    if not sent and b"[y/N]" in out:
        os.write(fd, answer.encode() + b"\n"); sent = True
_, st = os.waitpid(pid, 0)
sys.stdout.write(out.decode("utf-8", "replace"))
sys.exit(os.waitstatus_to_exitcode(st))
PY
}

# mkfrag <name> <json>: a fixture skill fragment; mkfrag with an existing name replaces it. rmfrag <name> removes it.
mkfrag() { mkdir -p "$PKG/skills/j-$1"; printf '%s\n' "$2" > "$PKG/skills/j-$1/settings-fragment.json"; }
rmfrag() { rm -rf "$PKG/skills/j-$1"; }
# seed_both <json>: the same settings content in both consumer settings files.
seed_both() { mkdir -p "$CONS/.claude" "$CONS/.agents"; printf '%s\n' "$1" > "$CS"; printf '%s\n' "$1" > "$AS"; }
# merge <args>: the script on a closed stdin (no terminal). pmerge <answer> <args>: on a pseudo-terminal.
merge() { run bash "$SCRIPT" --consumer-root "$CONS" --package-root "$PKG" "$@" </dev/null; }
pmerge() { local a="$1"; shift; run python3 -I "$PTY" "$a" bash "$SCRIPT" --consumer-root "$CONS" --package-root "$PKG" "$@"; }
jv() { jq -c "$2" "$1"; }   # jv <file> <jq expression>
sum() { cksum < "$1"; }
# none_exist / all_exist: plain commands, so a failure stops the test (a failing [ ] in an && list would not).
none_exist() { local f; for f; do [ ! -e "$f" ] || { echo "unexpected: $f exists"; return 1; }; done; }
all_exist() { local f; for f; do [ -e "$f" ] || { echo "missing: $f"; return 1; }; done; }

# ---------------------------------------------------------------------------------------------------------------- env

@test "env: a missing key is added without disturbing the other keys of the object or of the file" {
  mkfrag env "$ENV_FRAG"
  seed_both '{"model":"keep-me","env":{"MINE":"x"}}'
  merge
  [ "$status" -eq 0 ]
  assert_output_contains "added env JENGA_T_A"
  assert_output_contains "added env JENGA_T_B"
  [ "$(jv "$CS" '.env')" = '{"MINE":"x","JENGA_T_A":"one","JENGA_T_B":"two"}' ]
  [ "$(jv "$AS" '.env')" = '{"MINE":"x","JENGA_T_A":"one","JENGA_T_B":"two"}' ]
  [ "$(jv "$CS" '.model')" = '"keep-me"' ]
}

@test "env: a differing value is a conflict: client value kept, stderr names file key and both values, exit 6, count line" {
  mkfrag env "$ENV_FRAG"
  mkdir -p "$CONS/.claude"
  printf '{"env":{"JENGA_T_A":"mine"}}\n' > "$CS"
  run --separate-stderr bash "$SCRIPT" --consumer-root "$CONS" --package-root "$PKG" </dev/null
  [ "$status" -eq 6 ]
  [[ "$stderr" == *".claude/settings.json"* ]]
  [[ "$stderr" == *"env.JENGA_T_A"* ]]
  [[ "$stderr" == *'"mine"'* ]]
  [[ "$stderr" == *'"one"'* ]]
  [[ "$output" == *"conflict env.JENGA_T_A"* ]]
  [[ "$output" == *"1 conflict(s)"* ]]
  # the client's value stays, and a conflict never stops the other key from being added
  [ "$(jv "$CS" '.env.JENGA_T_A')" = '"mine"' ]
  [ "$(jv "$CS" '.env.JENGA_T_B')" = '"two"' ]
}

@test "env: an equal value is a no-op: exit 0, unchanged, files byte-identical" {
  mkfrag env "$ENV_FRAG"
  seed_both '{"env":{"JENGA_T_A":"one","JENGA_T_B":"two"}}'
  before="$(sum "$CS")$(sum "$AS")"
  merge
  [ "$status" -eq 0 ]
  assert_output_contains "unchanged"
  [ "$(sum "$CS")$(sum "$AS")" = "$before" ]
}

@test "conflict: a foreign WorktreeCreate handler is not joined by Jenga's, and the run ends with exit 6" {
  mkfrag wt '{"id":"t-wt","version":1,"hooks":{"WorktreeCreate":[{"hooks":[{"type":"command","command":"jenga-fixture-wt"}]}]}}'
  seed_both '{"hooks":{"WorktreeCreate":[{"hooks":[{"type":"command","command":"their-own-wt"}]}]}}'
  merge
  [ "$status" -eq 6 ]
  assert_output_contains "conflict hooks.WorktreeCreate"
  [ "$(jv "$CS" '.hooks.WorktreeCreate | length')" = "1" ]
}

# --------------------------------------------------------------------------------------------------------------- allow

@test "allow: a yes typed on the terminal adds exactly the diffed rules and nothing else" {
  command -v python3 >/dev/null || skip "python3 is needed to drive a pseudo-terminal"
  mkfrag allow "$ALLOW_FRAG"
  seed_both '{"permissions":{"allow":["Bash(mine)","Bash(jt-one *)"]},"model":"m"}'
  pmerge yes --interactive
  [ "$status" -eq 0 ]
  assert_output_contains "+ Bash(jt-two *)"
  assert_output_not_contains "+ Bash(jt-one *)"
  assert_output_contains "added allow Bash(jt-two *)"
  [ "$(jv "$CS" '.permissions.allow')" = '["Bash(mine)","Bash(jt-one *)","Bash(jt-two *)"]' ]
  [ "$(jv "$AS" '.permissions.allow')" = '["Bash(mine)","Bash(jt-one *)","Bash(jt-two *)"]' ]
  [ "$(jv "$CS" '.model')" = '"m"' ]
}

@test "allow: y is also an explicit yes, and a fresh consumer gets both rules in both files" {
  command -v python3 >/dev/null || skip "python3 is needed to drive a pseudo-terminal"
  mkfrag allow "$ALLOW_FRAG"
  pmerge y --interactive
  [ "$status" -eq 0 ]
  [ "$(jv "$CS" '.permissions.allow')" = '["Bash(jt-one *)","Bash(jt-two *)"]' ]
  [ "$(jv "$AS" '.permissions.allow')" = '["Bash(jt-one *)","Bash(jt-two *)"]' ]
}

@test "allow: no, an empty answer and an unrecognised answer add nothing, report each rule inactive and exit 6" {
  command -v python3 >/dev/null || skip "python3 is needed to drive a pseudo-terminal"
  mkfrag allow "$ALLOW_FRAG"
  for ans in no n "" maybe yess "ok"; do
    rm -rf "$CONS/.claude" "$CONS/.agents"
    pmerge "$ans" --interactive
    [ "$status" -eq 6 ] || { echo "answer '$ans' gave status $status: $output"; false; }
    assert_output_contains "inactive allow Bash(jt-one *)"
    assert_output_contains "inactive allow Bash(jt-two *)"
    # a declined rule writes neither a settings file nor a manifest
    none_exist "$CS" "$AS" "$CM" "$AM"
  done
}

@test "allow: with no terminal nothing is added, each rule is reported inactive, with the command that asks, exit 6" {
  mkfrag allow "$ALLOW_FRAG"
  merge --interactive
  [ "$status" -eq 6 ]
  assert_output_contains "inactive allow Bash(jt-one *)"
  assert_output_contains "inactive allow Bash(jt-two *)"
  assert_output_contains "to activate:"
  none_exist "$CS" "$AS" "$CM" "$AM"
}

@test "allow: without --interactive nothing is asked, even on a terminal, and the rules are inactive" {
  command -v python3 >/dev/null || skip "python3 is needed to drive a pseudo-terminal"
  mkfrag allow "$ALLOW_FRAG"
  pmerge yes
  [ "$status" -eq 6 ]
  assert_output_not_contains "[y/N]"
  assert_output_contains "inactive allow Bash(jt-one *)"
  none_exist "$CS" "$AS"
}

@test "allow: a yes piped to stdin is ignored" {
  mkfrag allow "$ALLOW_FRAG"
  run bash -c 'yes | bash "$@"' _ "$SCRIPT" --consumer-root "$CONS" --package-root "$PKG" --interactive
  [ "$status" -eq 6 ]
  assert_output_contains "inactive allow Bash(jt-one *)"
  none_exist "$CS" "$AS"
}

@test "allow: a yes passed by a flag is not accepted: the flag is an unknown argument (exit 2) and nothing is written" {
  mkfrag allow "$ALLOW_FRAG"
  for flag in --yes-allow --yes -y --assume-yes --allow; do
    merge "$flag"
    [ "$status" -eq 2 ] || { echo "$flag gave status $status"; false; }
  done
  none_exist "$CS" "$AS"
}

@test "allow: a yes supplied by environment variables is ignored, with and without a terminal" {
  mkfrag allow "$ALLOW_FRAG"
  run env YES=yes JENGA_YES=1 JENGA_YES_ALLOW=yes ASSUME_YES=1 JENGA_ASSUME_YES=1 CI=1 \
    bash "$SCRIPT" --consumer-root "$CONS" --package-root "$PKG" --interactive </dev/null
  [ "$status" -eq 6 ]
  assert_output_contains "inactive allow Bash(jt-one *)"
  none_exist "$CS" "$AS"
  if command -v python3 >/dev/null; then
    # on a terminal the variable does not answer for the user: the typed no is what counts
    run env YES=yes JENGA_YES=1 JENGA_YES_ALLOW=yes python3 -I "$PTY" no bash "$SCRIPT" --consumer-root "$CONS" --package-root "$PKG" --interactive
    [ "$status" -eq 6 ]
    none_exist "$CS" "$AS"
  fi
}

@test "allow: a yes written in a config value is ignored" {
  mkfrag allow "$ALLOW_FRAG"
  mkdir -p "$CONS/project/configs" "$CONS/.jenga" "$PKG/project/configs"
  for f in "$CONS/project/configs/workflow.json" "$CONS/.jenga/config.json" "$PKG/project/configs/workflow.json"; do
    printf '{"yes":true,"allow":"yes","yes_allow":true,"assume_yes":true,"permissions":{"allow_optin":"yes"}}\n' > "$f"
  done
  merge --interactive
  [ "$status" -eq 6 ]
  assert_output_contains "inactive allow Bash(jt-one *)"
  none_exist "$CS" "$AS"
}

@test "allow: --dry-run shows the diff and would-add lines, never asks, and writes nothing" {
  command -v python3 >/dev/null || skip "python3 is needed to drive a pseudo-terminal"
  mkfrag allow "$ALLOW_FRAG"
  pmerge yes --dry-run --interactive
  [ "$status" -eq 0 ]
  assert_output_contains "+ Bash(jt-one *)"
  assert_output_contains "would add allow Bash(jt-one *)"
  assert_output_not_contains "[y/N]"
  none_exist "$CS" "$AS" "$CONS/.claude"
}

# ------------------------------------------------------------------------------------------------------------- manifest

@test "manifest: written beside each settings file after a successful write, one record per entry written" {
  mkfrag hook "$HOOK_FRAG"; mkfrag env "$ENV_FRAG"
  merge
  [ "$status" -eq 0 ]
  all_exist "$CM" "$AM"
  [ "$(jv "$CM" '.manifestVersion')" = "1" ]
  [ "$(jv "$CM" '.file')" = '".claude/settings.json"' ]
  [ "$(jv "$AM" '.file')" = '".agents/settings.json"' ]
  [ "$(jv "$CM" '.entries | length')" = "3" ]
  [ "$(jv "$CM" '[.entries[].keyClass] | sort')" = '["env","env","hooks"]' ]
  [ "$(jv "$CM" '.entries | all(.id | startswith("sha256:"))')" = "true" ]
  [ "$(jv "$CM" '[.entries[] | select(.keyClass == "hooks") | .fragment] | .[0]')" = '"t-hook"' ]
  [ "$(jv "$CM" '.entries[0].jengaVersion')" = '"9.9.9"' ]
  # a second run changes neither file nor manifest
  before="$(sum "$CS")$(sum "$CM")$(sum "$AS")$(sum "$AM")"
  merge
  [ "$status" -eq 0 ]
  assert_output_contains "unchanged"
  [ "$(sum "$CS")$(sum "$CM")$(sum "$AS")$(sum "$AM")" = "$before" ]
}

@test "manifest: an entry that was written is recorded and an allow rule that was already present is not" {
  command -v python3 >/dev/null || skip "python3 is needed to drive a pseudo-terminal"
  mkfrag allow "$ALLOW_FRAG"
  seed_both '{"permissions":{"allow":["Bash(jt-one *)"]}}'
  pmerge yes --interactive
  [ "$status" -eq 0 ]
  [ "$(jv "$CM" '[.entries[] | select(.keyClass == "allow") | .entry]')" = '["Bash(jt-two *)"]' ]
}

@test "manifest: not written after a conflict that added nothing" {
  mkfrag env '{"id":"t-env","version":1,"env":{"JENGA_T_A":"one"}}'
  seed_both '{"env":{"JENGA_T_A":"mine"}}'
  before="$(sum "$CS")$(sum "$AS")"
  merge
  [ "$status" -eq 6 ]
  none_exist "$CM" "$AM"
  [ "$(sum "$CS")$(sum "$AS")" = "$before" ]
}

@test "manifest: not written after a failed settings write, which exits 5" {
  [ "$(id -u)" -ne 0 ] || skip "a read-only directory does not stop root"
  mkfrag hook "$HOOK_FRAG"
  mkdir -p "$CONS/.claude"; printf '{}\n' > "$CS"
  chmod 555 "$CONS/.claude"
  merge
  chmod 755 "$CONS/.claude"
  [ "$status" -eq 5 ]
  none_exist "$CM" "$AM"
  [ "$(jv "$CS" '.')" = '{}' ]
}

@test "manifest: a failed settings write leaves an existing manifest exactly as it was" {
  [ "$(id -u)" -ne 0 ] || skip "a read-only directory does not stop root"
  mkfrag env "$ENV_FRAG"
  merge
  [ "$status" -eq 0 ]
  before="$(sum "$CM")$(sum "$AM")"
  settings_before="$(sum "$CS")$(sum "$AS")"
  mkfrag hook "$HOOK_FRAG"
  chmod 555 "$CONS/.claude"
  merge
  chmod 755 "$CONS/.claude"
  [ "$status" -eq 5 ]
  [ "$(sum "$CM")$(sum "$AM")" = "$before" ]
  [ "$(sum "$CS")$(sum "$AS")" = "$settings_before" ]
}

# ------------------------------------------------------------------------------------------------------------- removal

@test "removal: the add, update and remove round trip leaves the client's own content and nothing of Jenga's" {
  mkfrag hook "$HOOK_FRAG"; mkfrag env "$ENV_FRAG"; mkfrag stay "$STAY_FRAG"
  seed_both '{"model":"m","env":{"MINE":"x"},"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"theirs"}]}]}}'
  # add
  merge
  [ "$status" -eq 0 ]
  assert_output_contains "added Stop"
  assert_output_contains "added env JENGA_T_A"
  [ "$(jv "$CS" '.env.JENGA_T_A')" = '"one"' ]
  [ "$(jv "$CS" '.hooks.Stop | length')" = "1" ]
  # update: a declared env value changes, so the old value is removed and the new one added: an update, not a conflict
  mkfrag env '{"id":"t-env","version":1,"env":{"JENGA_T_A":"uno","JENGA_T_B":"two"}}'
  merge
  [ "$status" -eq 0 ]
  assert_output_contains "removed env JENGA_T_A"
  assert_output_contains "added env JENGA_T_A"
  [ "$(jv "$CS" '.env.JENGA_T_A')" = '"uno"' ]
  [ "$(jv "$CS" '.env.JENGA_T_B')" = '"two"' ]
  # remove: the env fragment and then the hook fragment are no longer declared
  rmfrag env
  merge
  [ "$status" -eq 0 ]
  assert_output_contains "removed env JENGA_T_A"
  assert_output_contains "removed env JENGA_T_B"
  [ "$(jv "$CS" '.env | has("JENGA_T_A") or has("JENGA_T_B")')" = "false" ]
  [ "$(jv "$CS" '.env.MINE')" = '"x"' ]
  [ "$(jv "$CS" '.hooks.Stop | length')" = "1" ]
  rmfrag hook
  merge
  [ "$status" -eq 0 ]
  assert_output_contains "removed hooks.Stop"
  [ "$(jv "$CS" '.hooks.Stop')" = "null" ]
  [ "$(jv "$CS" '.')" = '{"model":"m","env":{"MINE":"x","JENGA_T_S":"stay"},"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"theirs"}]}]}}' ]
  [ "$(jv "$AS" '.')" = "$(jv "$CS" '.')" ]
  # the manifest now records only what is still declared and written
  [ "$(jv "$CM" '[.entries[].path]')" = '["env.JENGA_T_S"]' ]
}

@test "removal: a client-edited entry is kept and reported, a hand-deleted one is reported absent, and both records are dropped" {
  mkfrag hook "$HOOK_FRAG"; mkfrag env "$ENV_FRAG"; mkfrag stay "$STAY_FRAG"
  merge
  [ "$status" -eq 0 ]
  # the client edits the value of JENGA_T_A and the hook entry (an added timeout), and deletes JENGA_T_B by hand
  jq '.env.JENGA_T_A = "edited" | del(.env.JENGA_T_B) | .hooks.Stop[0].hooks[0].timeout = 5' "$CS" > "$CS.new" && mv "$CS.new" "$CS"
  rmfrag env; rmfrag hook
  merge
  [ "$status" -eq 0 ]
  assert_output_contains "kept, client-modified env.JENGA_T_A"
  assert_output_contains "kept, client-modified hooks.Stop"
  assert_output_contains "already absent env.JENGA_T_B"
  [ "$(jv "$CS" '.env.JENGA_T_A')" = '"edited"' ]
  [ "$(jv "$CS" '.hooks.Stop[0].hooks[0].timeout')" = "5" ]
  [ "$(jv "$CS" '.env | has("JENGA_T_B")')" = "false" ]
  # both records are dropped, so the next run no longer reports them
  [ "$(jv "$CM" '[.entries[].path]')" = '["env.JENGA_T_S"]' ]
  merge
  [ "$status" -eq 0 ]
  assert_output_not_contains "client-modified"
  assert_output_not_contains "already absent"
}

@test "removal: an allow rule needs a yes: with none it stays and is reported, and the last removed rule drops the empty permissions key" {
  command -v python3 >/dev/null || skip "python3 is needed to drive a pseudo-terminal"
  mkfrag allow "$ALLOW_FRAG"
  pmerge yes --interactive
  [ "$status" -eq 0 ]
  [ "$(jv "$CS" '.permissions.allow | length')" = "2" ]
  rmfrag allow; mkfrag stay "$STAY_FRAG"
  # no terminal: the rules stay and are reported
  merge --interactive
  [ "$status" -eq 0 ]
  assert_output_contains "still present allow Bash(jt-one *)"
  assert_output_contains "still present allow Bash(jt-two *)"
  assert_output_contains "to remove:"
  [ "$(jv "$CS" '.permissions.allow | length')" = "2" ]
  # a typed no: they stay
  pmerge no --interactive
  assert_output_contains "still present allow Bash(jt-one *)"
  [ "$(jv "$CS" '.permissions.allow | length')" = "2" ]
  # a typed yes: the exact diff is shown, the rules go, and the now-empty permissions key goes with them
  pmerge yes --interactive
  [ "$status" -eq 0 ]
  assert_output_contains "- Bash(jt-one *)"
  assert_output_contains "removed allow Bash(jt-one *)"
  assert_output_contains "removed allow Bash(jt-two *)"
  [ "$(jv "$CS" 'has("permissions")')" = "false" ]
  [ "$(jv "$AS" 'has("permissions")')" = "false" ]
  [ "$(jv "$CS" '.env.JENGA_T_S')" = '"stay"' ]
}

@test "removal: removing one of two allow rules keeps the permissions key and the client's own rule" {
  command -v python3 >/dev/null || skip "python3 is needed to drive a pseudo-terminal"
  mkfrag allow "$ALLOW_FRAG"
  seed_both '{"permissions":{"allow":["Bash(mine)"],"deny":["Bash(rm *)"]}}'
  pmerge yes --interactive
  [ "$status" -eq 0 ]
  mkfrag allow '{"id":"t-allow","version":1,"permissions":{"allow":[{"rule":"Bash(jt-one *)","optIn":true}]}}'
  pmerge yes --interactive
  [ "$status" -eq 0 ]
  assert_output_contains "removed allow Bash(jt-two *)"
  [ "$(jv "$CS" '.permissions')" = '{"allow":["Bash(mine)","Bash(jt-one *)"],"deny":["Bash(rm *)"]}' ]
}

@test "removal: a missing manifest removes nothing and says so" {
  mkfrag stay "$STAY_FRAG"
  seed_both '{"env":{"JENGA_T_A":"one"},"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"jenga-fixture-stop"}]}]}}'
  merge
  [ "$status" -eq 0 ]
  assert_output_contains "no manifest, nothing removed"
  [ "$(jv "$CS" '.env.JENGA_T_A')" = '"one"' ]
  [ "$(jv "$CS" '.hooks.Stop | length')" = "1" ]
}

@test "removal: a corrupt manifest is reported, removes nothing and is not overwritten" {
  mkfrag hook "$HOOK_FRAG"; mkfrag env "$ENV_FRAG"
  merge
  [ "$status" -eq 0 ]
  printf 'this is { not json' > "$CM"
  printf '{"manifestVersion":2,"file":".agents/settings.json","entries":[]}\n' > "$AM"
  corrupt_before="$(sum "$CM")$(sum "$AM")"
  rmfrag hook; rmfrag env; mkfrag stay "$STAY_FRAG"
  merge
  [ "$status" -eq 0 ]
  assert_output_contains "corrupt manifest .claude/jenga-settings-manifest.json"
  assert_output_contains "corrupt manifest .agents/jenga-settings-manifest.json"
  assert_output_not_contains "removed hooks"
  assert_output_not_contains "removed env"
  # nothing was removed, though a new entry could still be added, and neither manifest was touched
  [ "$(jv "$CS" '.env.JENGA_T_A')" = '"one"' ]
  [ "$(jv "$CS" '.hooks.Stop | length')" = "1" ]
  [ "$(jv "$CS" '.env.JENGA_T_S')" = '"stay"' ]
  [ "$(sum "$CM")$(sum "$AM")" = "$corrupt_before" ]
}

# ------------------------------------------------------------------------------------------------ settings.local.json

@test "settings.local.json is never read or written, through add, allow, update and removal" {
  command -v python3 >/dev/null || skip "python3 is needed to drive a pseudo-terminal"
  mkdir -p "$CONS/.claude" "$CONS/.agents"
  printf '{"env":{"JENGA_T_A":"local-value"},"permissions":{"allow":["Bash(jt-one *)"]}}\n' > "$CONS/.claude/settings.local.json"
  printf '{"local":true}\n' > "$CONS/.agents/settings.local.json"
  before="$(sum "$CONS/.claude/settings.local.json")$(sum "$CONS/.agents/settings.local.json")"
  mkfrag hook "$HOOK_FRAG"; mkfrag env "$ENV_FRAG"; mkfrag allow "$ALLOW_FRAG"
  pmerge yes --interactive
  [ "$status" -eq 0 ]
  # the local value is not seen: no conflict with it, and the declared value is written to the shared file
  [ "$(jv "$CS" '.env.JENGA_T_A')" = '"one"' ]
  mkfrag env '{"id":"t-env","version":1,"env":{"JENGA_T_A":"uno","JENGA_T_B":"two"}}'
  merge --interactive
  rmfrag env; rmfrag hook; rmfrag allow; mkfrag stay "$STAY_FRAG"
  pmerge yes --interactive
  [ "$(sum "$CONS/.claude/settings.local.json")$(sum "$CONS/.agents/settings.local.json")" = "$before" ]
  [ "$(ls "$CONS/.claude" | grep -c 'settings.local')" = "1" ]
}

# ------------------------------------------------------------------------------------------------------------------ help

@test "--help exits 0 and writes nothing" {
  mkfrag hook "$HOOK_FRAG"
  snap_before="$(find "$BATS_TEST_TMPDIR" -path "$BATS_TEST_TMPDIR/pty-answer.py" -prune -o -type f -print | sort | xargs cksum)"
  run bash "$SCRIPT" --help </dev/null
  [ "$status" -eq 0 ]
  assert_output_contains "merge-settings.sh --consumer-root"
  none_exist "$CONS/.claude" "$CONS/.agents"
  [ "$(find "$BATS_TEST_TMPDIR" -path "$BATS_TEST_TMPDIR/pty-answer.py" -prune -o -type f -print | sort | xargs cksum)" = "$snap_before" ]
}
