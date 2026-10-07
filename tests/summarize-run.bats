#!/usr/bin/env bats
#
# Coverage for skills/j-connect/scripts/summarize-run.sh (E65_S02_T03).
#
# Synthetic transcripts for the report logic, plus pipelines driven by the REAL
# run-descriptor.sh against stub executables (fakecli, prereqcli, brew) in a
# throwaway git project. No real vendor CLI or package manager is invoked.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SUM="$REPO_ROOT/skills/j-connect/scripts/summarize-run.sh"
RUN="$REPO_ROOT/skills/j-connect/scripts/run-descriptor.sh"
FAKESERVICE="$REPO_ROOT/tests/fixtures/connect/e2e/fakeservice.json"
SENTINEL="SENTINEL-SUMMARY-TOKEN-5e1f90aa"

setup() {
  STUB="$BATS_TEST_TMPDIR/stub"; FAKE_BIN="$BATS_TEST_TMPDIR/bin"; PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$STUB" "$FAKE_BIN" "$PROJ"
  git -C "$PROJ" init -q .
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

# summarize <jsonl text>: feed a transcript on stdin
summarize() { run --separate-stderr bash "$SUM" <<<"$1"; }
pipeline() { # run the real runner then summarize its stdout
  bash "$RUN" "$FAKESERVICE" --project-root "$PROJ" "$@" > "$BATS_TEST_TMPDIR/results.jsonl" 2>/dev/null || true
  run --separate-stderr bash "$SUM" "$BATS_TEST_TMPDIR/results.jsonl"
}
last_line() { printf '%s\n' "$output" | tail -n1; }

OK_TRANSCRIPT='{"descriptor":"svc","step":"detect","status":"pass","message":"tool is present","detail":"present"}
{"descriptor":"svc","step":"install","status":"skipped","message":"already installed"}
{"descriptor":"svc","step":"auth","status":"skipped","message":"already authenticated"}
{"descriptor":"svc","step":"register_mcp","status":"pass","message":"registered"}
{"descriptor":"svc","step":"verify","status":"pass","message":"verification command succeeded"}
{"summary":true,"descriptor":"svc","status":"pass","counts":{"pass":3,"fail":0,"skipped":2,"needs-user-action":0},"steps":5}'

@test "install and auth skipped, verify pass: lists the skips with reasons and ends VERIFIED, exit 0" {
  summarize "$OK_TRANSCRIPT"
  [ "$status" -eq 0 ]
  case "$output" in *"[PASS] detect - tool is present"*) ;; *) false ;; esac
  case "$output" in *"[SKIPPED] install - already installed"*) ;; *) false ;; esac
  case "$output" in *"Skipped (nothing to do):"*"install: already installed"*"auth: already authenticated"*) ;; *) false ;; esac
  [ "$(last_line)" = "VERIFIED: svc" ]
}

@test "auth needs-user-action and nothing after: Needs your action block, did-not-run line, exit 3" {
  summarize '{"descriptor":"svc","step":"detect","status":"pass","message":"tool is present"}
{"descriptor":"svc","step":"install","status":"skipped","message":"already installed"}
{"descriptor":"svc","step":"auth","status":"needs-user-action","message":"sign in yourself"}
{"summary":true,"descriptor":"svc","status":"needs-user-action","counts":{},"steps":3}'
  [ "$status" -eq 3 ]
  case "$output" in *"[ACTION] auth - sign in yourself"*) ;; *) false ;; esac
  case "$output" in *"Needs your action:"*"auth: sign in yourself"*) ;; *) false ;; esac
  [ "$(last_line)" = "NOT VERIFIED: verification did not run (stopped at auth)" ]
}

@test "verify fail: NOT VERIFIED: verification failed, exit 1" {
  summarize '{"descriptor":"svc","step":"auth","status":"skipped","message":"already authenticated"}
{"descriptor":"svc","step":"verify","status":"fail","message":"verification command failed"}
{"summary":true,"descriptor":"svc","status":"fail"}'
  [ "$status" -eq 1 ]
  [ "$(last_line)" = "NOT VERIFIED: verification failed" ]
}

@test "summary pass but no verify step never prints VERIFIED" {
  summarize '{"descriptor":"svc","step":"install","status":"skipped","message":"already installed"}
{"summary":true,"descriptor":"svc","status":"pass","counts":{},"steps":1}'
  [ "$status" -eq 1 ]
  case "$output" in *"VERIFIED: svc"*) false ;; *) ;; esac
  [ "$(last_line)" = "NOT VERIFIED: verification did not run (stopped at install)" ]
}

@test "a skipped verify never produces VERIFIED" {
  summarize '{"descriptor":"svc","step":"verify","status":"skipped","message":"n/a"}
{"summary":true,"descriptor":"svc","status":"pass"}'
  [ "$status" -eq 1 ]
  case "$(last_line)" in "NOT VERIFIED: "*) ;; *) false ;; esac
}

@test "a prerequisite's verify pass does not stand in for the service's own verify" {
  summarize '{"descriptor":"prereq","step":"verify","status":"pass","message":"verification command succeeded"}
{"descriptor":"svc","step":"requires:prereq","status":"pass","message":"prerequisite satisfied"}
{"descriptor":"svc","step":"auth","status":"needs-user-action","message":"sign in"}
{"summary":true,"descriptor":"svc","status":"needs-user-action"}'
  [ "$status" -eq 3 ]
  case "$output" in *"[PASS] prereq/verify - "*) ;; *) false ;; esac
  [ "$(last_line)" = "NOT VERIFIED: verification did not run (stopped at auth)" ]
}

@test "any fail wins over needs-user-action for the exit code" {
  summarize '{"descriptor":"svc","step":"install","status":"fail","message":"boom"}
{"descriptor":"svc","step":"auth","status":"needs-user-action","message":"sign in"}'
  [ "$status" -eq 1 ]
  [ "$(last_line)" = "NOT VERIFIED: verification did not run (stopped at install)" ]
}

@test "malformed lines are ignored with a stderr notice and never reach the report" {
  summarize "$OK_TRANSCRIPT
this is not json $SENTINEL
{broken
42
\"a string\"
[1,2]
{\"no\":\"step\"}
{\"descriptor\":\"svc\",\"step\":\"x\",\"status\":\"weird\",\"message\":\"nope\"}"
  [ "$status" -eq 0 ]
  [ "$(last_line)" = "VERIFIED: svc" ]
  case "$output" in *"not json"*|*"$SENTINEL"*|*"broken"*|*"weird"*|*"nope"*) false ;; *) ;; esac
  case "$stderr" in *"ignored non-JSON line"*) ;; *) false ;; esac
  case "$stderr" in *"$SENTINEL"*) false ;; *) ;; esac
}

@test "empty input does not crash and is not VERIFIED" {
  summarize ""
  [ "$status" -eq 1 ]
  case "$output" in *"NOT VERIFIED: verification did not run"*) ;; *) false ;; esac
}

@test "reads a results file argument and stdin dash; bad file and usage errors exit 2" {
  printf '%s\n' "$OK_TRANSCRIPT" > "$BATS_TEST_TMPDIR/t.jsonl"
  run --separate-stderr bash "$SUM" "$BATS_TEST_TMPDIR/t.jsonl"
  [ "$status" -eq 0 ]
  [ "$(last_line)" = "VERIFIED: svc" ]
  run --separate-stderr bash "$SUM" - < "$BATS_TEST_TMPDIR/t.jsonl"
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$SUM" "$BATS_TEST_TMPDIR/missing.jsonl"
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SUM" a b
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SUM" --bogus
  [ "$status" -eq 2 ]
}

@test "real runner, tool installed and authenticated: install and auth reported as skipped, VERIFIED, exit 0" {
  touch "$STUB/installed" "$STUB/authed"
  pipeline
  [ "$status" -eq 0 ]
  case "$output" in *"install - already installed"*) ;; *) false ;; esac
  case "$output" in *"auth - already authenticated"*) ;; *) false ;; esac
  case "$output" in *"Skipped (nothing to do):"*) ;; *) false ;; esac
  [ "$(last_line)" = "VERIFIED: fakeservice" ]
}

@test "real runner, tool not installed: reports the install action, no VERIFIED, exit 3, installer not run" {
  pipeline
  [ "$status" -eq 3 ]
  case "$output" in *"[ACTION] install - not installed."*) ;; *) false ;; esac
  case "$output" in *"Needs your action:"*"install: "*) ;; *) false ;; esac
  [ "$(last_line)" = "NOT VERIFIED: verification did not run (stopped at install)" ]
  [ ! -e "$STUB/brew.log" ]
}

@test "real runner, installed but not authenticated: stops at auth, env var NAME only, exit 3" {
  touch "$STUB/installed"
  pipeline
  [ "$status" -eq 3 ]
  case "$output" in *"install - already installed"*) ;; *) false ;; esac
  case "$output" in *"FAKESERVICE_TOKEN"*) ;; *) false ;; esac
  [ "$(last_line)" = "NOT VERIFIED: verification did not run (stopped at auth)" ]
}

@test "real runner: a secret sentinel in the environment never appears in the report" {
  touch "$STUB/installed" "$STUB/authed"
  pipeline
  [ "$status" -eq 0 ]
  case "$output" in *"$SENTINEL"*) false ;; *) ;; esac
  case "$stderr" in *"$SENTINEL"*) false ;; *) ;; esac
  # and again on the not-installed and not-authenticated paths
  rm "$STUB/authed"
  pipeline
  case "$output" in *"$SENTINEL"*) false ;; *) ;; esac
  rm "$STUB/installed"
  pipeline
  case "$output" in *"$SENTINEL"*) false ;; *) ;; esac
}
