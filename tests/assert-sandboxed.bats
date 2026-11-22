#!/usr/bin/env bats
# bats file_tags=tier:unit
#
# E99_S01_T07: the shared assert_sandboxed helper (tests/helpers/assert-sandboxed.bash). One table-driven case: each
# row starts from a fully sandboxed setup, breaks exactly one condition, and the helper must refuse and name it; the
# first row is the fully sandboxed setup itself, which it must accept. Another row breaks two conditions at once
# and both must be reported (the helper does not stop at the first).
#
# Nothing here pushes anywhere: the helper only reads the environment, the git configuration and `origin`'s URL.

load helpers/assertions

HELPER="$(cd "$BATS_TEST_DIRNAME/helpers" && pwd)/assert-sandboxed.bash"

setup() {
  SANDBOX="$BATS_TEST_TMPDIR/root"
  OUTSIDE="$BATS_TEST_TMPDIR/outside"
  mkdir -p "$SANDBOX/home" "$SANDBOX/work" "$OUTSIDE/elsewhere"
  git -C "$SANDBOX/work" init -q .
  # a symlink inside the root that points outside it
  ln -s "$OUTSIDE/elsewhere" "$SANDBOX/escape"
}

# row <label> <expected-status> <expected-fragment-or-empty> <mutation>: runs assert_sandboxed in a subshell that starts
# fully sandboxed, applies <mutation> (shell text, evaluated in that subshell) and checks the result.
row() {
  local label="$1" want="$2" fragment="$3" mutation="$4" rc=0 err
  err="$BATS_TEST_TMPDIR/err.txt"
  # every row starts from a fresh repository, so a remote or a config set by one row never reaches the next
  rm -rf "$SANDBOX/work"
  mkdir -p "$SANDBOX/work"
  git -C "$SANDBOX/work" init -q .
  (
    . "$HELPER"
    cd "$SANDBOX/work" || exit 99
    export HOME="$SANDBOX/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_ALLOW_PROTOCOL=file
    unset SSH_AUTH_SOCK GIT_ASKPASS SSH_ASKPASS
    eval "$mutation"
    assert_sandboxed "$SANDBOX" "$SANDBOX/work" "$SANDBOX/origin.git" ${EXTRA:+"$EXTRA"}
  ) 2>"$err" || rc=$?
  if [ "$want" = ok ]; then
    [ "$rc" -eq 0 ] || { echo "row '$label': expected acceptance, got $rc: $(cat "$err")" >&2; return 1; }
    [ ! -s "$err" ] || { echo "row '$label': accepted but wrote to stderr: $(cat "$err")" >&2; return 1; }
  else
    [ "$rc" -eq 1 ] || { echo "row '$label': expected refusal (1), got $rc: $(cat "$err")" >&2; return 1; }
    assert_contains "$(cat "$err")" "$fragment" || { echo "row '$label': refusal does not name '$fragment': $(cat "$err")" >&2; return 1; }
  fi
}

@test "assert_sandboxed accepts a fully sandboxed setup and refuses each broken condition, naming it" {
  row "fully sandboxed" ok "" ":"
  row "push target outside the root" refuse "which is outside" "EXTRA=\"$OUTSIDE/elsewhere/o.git\""
  row "origin on https" refuse "network URL" "git remote add origin https://example.invalid/x.git"
  row "origin scp-like" refuse "scp-like" "git remote add origin git@example.invalid:x/y.git"
  row "target through a symlink that leaves the root" refuse "which is outside" "git remote add origin \"$SANDBOX/escape/o.git\""
  row "HOME outside the root" refuse "HOME" "export HOME=\"$OUTSIDE\""
  row "HOME unset" refuse "HOME" "unset HOME"
  row "GIT_CONFIG_GLOBAL unset" refuse "GIT_CONFIG_GLOBAL" "unset GIT_CONFIG_GLOBAL"
  row "GIT_CONFIG_GLOBAL not /dev/null" refuse "GIT_CONFIG_GLOBAL" "export GIT_CONFIG_GLOBAL=\"$SANDBOX/home/.gitconfig\""
  row "GIT_CONFIG_NOSYSTEM unset" refuse "GIT_CONFIG_NOSYSTEM" "unset GIT_CONFIG_NOSYSTEM"
  row "GIT_ALLOW_PROTOCOL unset" refuse "GIT_ALLOW_PROTOCOL" "unset GIT_ALLOW_PROTOCOL"
  row "GIT_ALLOW_PROTOCOL allows https" refuse "GIT_ALLOW_PROTOCOL" "export GIT_ALLOW_PROTOCOL=file:https"
  row "SSH_AUTH_SOCK set" refuse "SSH_AUTH_SOCK" "export SSH_AUTH_SOCK=/tmp/agent.sock"
  row "GIT_ASKPASS set" refuse "GIT_ASKPASS" "export GIT_ASKPASS=/usr/bin/true"
  row "SSH_ASKPASS set" refuse "SSH_ASKPASS" "export SSH_ASKPASS=/usr/bin/true"
  row "credential.helper configured" refuse "credential.helper" "git config credential.helper store"
  row "two conditions broken: both are reported" refuse "GIT_CONFIG_NOSYSTEM" "unset GIT_CONFIG_NOSYSTEM; export SSH_AUTH_SOCK=/tmp/agent.sock"
}

@test "assert_sandboxed reports every violation, refuses a root that is / or missing, and defaults the root to BATS_TEST_TMPDIR" {
  local err="$BATS_TEST_TMPDIR/err.txt" rc=0
  (
    . "$HELPER"
    cd "$SANDBOX/work" || exit 99
    export HOME="$OUTSIDE" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_ALLOW_PROTOCOL=file
    unset SSH_AUTH_SOCK GIT_ASKPASS SSH_ASKPASS
    assert_sandboxed "$SANDBOX" "$OUTSIDE/a.git" "https://example.invalid/x.git"
  ) 2>"$err" || rc=$?
  [ "$rc" -eq 1 ]
  [ "$(grep -c '^assert_sandboxed: ' "$err")" -eq 3 ]
  assert_contains "$(cat "$err")" "$OUTSIDE/a.git"
  assert_contains "$(cat "$err")" "https://example.invalid/x.git"
  assert_contains "$(cat "$err")" "HOME"

  rc=0
  ( . "$HELPER"; assert_sandboxed / ) 2>"$err" || rc=$?
  [ "$rc" -eq 1 ]
  assert_contains "$(cat "$err")" "filesystem root"
  rc=0
  ( . "$HELPER"; assert_sandboxed "$BATS_TEST_TMPDIR/does-not-exist" ) 2>"$err" || rc=$?
  [ "$rc" -eq 1 ]
  assert_contains "$(cat "$err")" "not an existing directory"

  # no root argument: BATS_TEST_TMPDIR is the root, so a sandbox under it is accepted
  rc=0
  (
    . "$HELPER"
    cd "$SANDBOX/work" || exit 99
    export HOME="$SANDBOX/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_ALLOW_PROTOCOL=file
    unset SSH_AUTH_SOCK GIT_ASKPASS SSH_ASKPASS
    assert_sandboxed
  ) 2>"$err" || rc=$?
  [ "$rc" -eq 0 ]
}
