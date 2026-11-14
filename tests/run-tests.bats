#!/usr/bin/env bats
#
# Coverage for scripts/run-tests.sh (E43_S02_T01): parallel bats with a dependency check and a serial fallback.
#
# Isolation: every test runs a COPY of the script inside its own temp "repo" (the script resolves its repository
# root from its own location), against a fake tests/ directory, with a PATH that contains only stubs and the two
# real tools the script needs (dirname, grep). Nothing here runs a real bats suite, touches the real repository's
# tests/, .claude/, .agents/, .git/config or .mirror-worktrees, or needs GNU parallel / rush installed.
#
# The stub `bats` appends each invocation's argv to $STUB_LOG (one line per invocation; `bats --help` is answered
# but not logged) and exits 1 when its argv contains any whitespace-separated token listed in $STUB_FAIL_ON,
# which models "a failing test lives in that file". The stub `parallel` / `rush` exist only so `command -v` finds
# them; the stub `bats` never delegates to them.

bats_require_minimum_version 1.5.0

SCRIPT_SRC="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/run-tests.sh"
REPO_PKG="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/package.json"

PERM="tests/mirror-permission-level-invariant.bats"
SUBJ="tests/mirror-test-subject-invariant.bats"

setup() {
  TMP="$BATS_TEST_TMPDIR"
  FAKE="$TMP/repo"
  STUBS="$TMP/stubs"
  TOOLS="$TMP/tools"
  export STUB_LOG="$TMP/bats.log"
  export STUB_FAIL_ON=""
  : > "$STUB_LOG"

  mkdir -p "$FAKE/scripts" "$FAKE/tests/fixtures" "$STUBS" "$TOOLS"
  cp "$SCRIPT_SRC" "$FAKE/scripts/run-tests.sh"
  local f
  for f in a b c; do : > "$FAKE/tests/$f.bats"; done
  : > "$FAKE/$PERM"
  : > "$FAKE/$SUBJ"
  # Inputs under tests/fixtures/ must never be run (some are deliberately failing).
  : > "$FAKE/tests/fixtures/broken.bats"

  # The two real tools the script shells out to (plus bash, for the stubs' shebang).
  ln -s "$(command -v dirname)" "$TOOLS/dirname"
  ln -s "$(command -v grep)" "$TOOLS/grep"
  # The stubs are bash scripts started through `#!/usr/bin/env bash`, which resolves bash on the restricted PATH.
  ln -s "$BASH" "$TOOLS/bash"

  cat > "$STUBS/bats" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
  if [ -n "${STUB_BATS_NO_JOBS:-}" ]; then
    echo "Usage: bats [OPTIONS] <tests>"
  else
    echo "  -j, --jobs <jobs>         Number of parallel jobs (requires GNU parallel or shenwei356/rush)"
  fi
  exit 0
fi
printf '%s\n' "$*" >> "$STUB_LOG"
for p in ${STUB_FAIL_ON:-}; do
  case " $* " in *" $p "*) exit 1 ;; esac
done
exit 0
EOF
  chmod +x "$STUBS/bats"

  # Core-count stub: the value under test.
  printf '#!/usr/bin/env bash\necho "${STUB_CORES:-4}"\n' > "$STUBS/getconf"
  chmod +x "$STUBS/getconf"
  export STUB_CORES=4
}

# run_script: the script under the stub PATH. Extra "VAR=value" words become env vars of that one run.
run_script() {
  run env PATH="$STUBS:$TOOLS" "$@" "$BASH" "$FAKE/scripts/run-tests.sh"
}

add_parallel() { printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/parallel"; chmod +x "$STUBS/parallel"; }
add_rush()     { printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/rush";     chmod +x "$STUBS/rush"; }

log_line() { sed -n "${1}p" "$STUB_LOG"; }
log_count() { wc -l < "$STUB_LOG" | tr -d '[:space:]'; }

# ---------------------------------------------------------------------------------------------------------------
# Serial fallback
# ---------------------------------------------------------------------------------------------------------------

@test "no parallel binary: one plain 'bats tests/*.bats' invocation, no --jobs, and exit 0" {
  run_script
  [ "$status" -eq 0 ]
  [ "$(log_count)" -eq 1 ]
  [ "$(log_line 1)" = "tests/a.bats tests/b.bats tests/c.bats $PERM $SUBJ" ]
}

@test "no parallel binary: the fallback invocation is identical to the glob the old 'npm test' ran" {
  run_script
  [ "$status" -eq 0 ]
  local expected
  expected="$(cd "$FAKE" && printf '%s ' tests/*.bats)"
  [ "$(log_line 1) " = "$expected" ]
}

@test "no parallel binary: a failing bats makes the script exit non-zero" {
  STUB_FAIL_ON="tests/b.bats"
  export STUB_FAIL_ON
  run_script
  [ "$status" -ne 0 ]
  [ "$(log_count)" -eq 1 ]
}

@test "jobs below 2 (RUN_TESTS_JOBS=1) with a parallel binary present falls back to one serial invocation" {
  add_parallel
  run_script RUN_TESTS_JOBS=1
  [ "$status" -eq 0 ]
  [ "$(log_count)" -eq 1 ]
  case "$(log_line 1)" in *--jobs*) false ;; esac
}

@test "a bats without --jobs support falls back to one serial invocation even with a parallel binary present" {
  add_parallel
  run_script STUB_BATS_NO_JOBS=1
  [ "$status" -eq 0 ]
  [ "$(log_count)" -eq 1 ]
  case "$(log_line 1)" in *--jobs*) false ;; esac
}

@test "no bats on PATH: exits 127 with a message, runs nothing" {
  rm "$STUBS/bats"
  run -127 env PATH="$STUBS:$TOOLS" "$BASH" "$FAKE/scripts/run-tests.sh"
  [ "$status" -eq 127 ]
  case "$output" in *"bats not found"*) ;; *) false ;; esac
}

# ---------------------------------------------------------------------------------------------------------------
# Two passes
# ---------------------------------------------------------------------------------------------------------------

@test "GNU parallel present: pass 1 is --jobs N over the bulk files only, pass 2 is a plain run of exactly the two shared-state files" {
  add_parallel
  run_script
  [ "$status" -eq 0 ]
  [ "$(log_count)" -eq 2 ]
  [ "$(log_line 1)" = "--jobs 4 tests/a.bats tests/b.bats tests/c.bats" ]
  [ "$(log_line 2)" = "$PERM $SUBJ" ]
}

@test "the two passes together cover every top-level tests/*.bats exactly once, and never tests/fixtures" {
  add_parallel
  run_script
  [ "$status" -eq 0 ]
  local covered expected
  covered="$(sed 's/^--jobs [0-9]* //' "$STUB_LOG" | tr ' ' '\n' | sort)"
  expected="$(cd "$FAKE" && printf '%s\n' tests/*.bats | sort)"
  [ "$covered" = "$expected" ]
  ! grep -q fixtures "$STUB_LOG"
  # Neither shared-state file is in the parallel pass.
  case "$(log_line 1)" in *mirror-*) false ;; esac
}

@test "only rush present: --parallel-binary-name rush is passed (bats does not fall back to rush by itself)" {
  add_rush
  run_script
  [ "$status" -eq 0 ]
  [ "$(log_line 1)" = "--jobs 4 --parallel-binary-name rush tests/a.bats tests/b.bats tests/c.bats" ]
  [ "$(log_line 2)" = "$PERM $SUBJ" ]
}

@test "both parallel and rush present: GNU parallel wins, so no --parallel-binary-name is passed" {
  add_parallel
  add_rush
  run_script
  [ "$status" -eq 0 ]
  case "$(log_line 1)" in *parallel-binary-name*) false ;; esac
}

@test "a missing shared-state file (public mirror blocklists some tests) is simply not run" {
  add_parallel
  rm "$FAKE/$SUBJ"
  run_script
  [ "$status" -eq 0 ]
  [ "$(log_count)" -eq 2 ]
  [ "$(log_line 2)" = "$PERM" ]
}

@test "no shared-state files present: only the parallel pass runs" {
  add_parallel
  rm "$FAKE/$SUBJ" "$FAKE/$PERM"
  run_script
  [ "$status" -eq 0 ]
  [ "$(log_count)" -eq 1 ]
  [ "$(log_line 1)" = "--jobs 4 tests/a.bats tests/b.bats tests/c.bats" ]
}

@test "only shared-state files present: only the serial pass runs" {
  add_parallel
  rm "$FAKE/tests/a.bats" "$FAKE/tests/b.bats" "$FAKE/tests/c.bats"
  run_script
  [ "$status" -eq 0 ]
  [ "$(log_count)" -eq 1 ]
  [ "$(log_line 1)" = "$PERM $SUBJ" ]
}

# ---------------------------------------------------------------------------------------------------------------
# Exit-code aggregation: a failure in ANY of the three groups must fail the script
# ---------------------------------------------------------------------------------------------------------------

@test "exit code: a failing test in the bulk-parallel group fails the script, and the serial pass still runs" {
  add_parallel
  STUB_FAIL_ON="tests/b.bats"
  export STUB_FAIL_ON
  run_script
  [ "$status" -ne 0 ]
  [ "$(log_count)" -eq 2 ]
}

@test "exit code: a failing mirror-permission-level-invariant fails the script" {
  add_parallel
  STUB_FAIL_ON="$PERM"
  export STUB_FAIL_ON
  run_script
  [ "$status" -ne 0 ]
  [ "$(log_count)" -eq 2 ]
}

@test "exit code: a failing mirror-test-subject-invariant fails the script" {
  add_parallel
  STUB_FAIL_ON="$SUBJ"
  export STUB_FAIL_ON
  run_script
  [ "$status" -ne 0 ]
  [ "$(log_count)" -eq 2 ]
}

@test "exit code: failures in both passes still fail the script (the first failure is not masked by the second pass)" {
  add_parallel
  STUB_FAIL_ON="tests/a.bats $SUBJ"
  export STUB_FAIL_ON
  run_script
  [ "$status" -ne 0 ]
  [ "$(log_count)" -eq 2 ]
}

@test "exit code: the bulk failure is not lost when the serial pass passes afterwards (status 1, not 0)" {
  add_parallel
  STUB_FAIL_ON="tests/c.bats"
  export STUB_FAIL_ON
  run_script
  [ "$status" -eq 1 ]
}

@test "exit code: everything passing exits 0" {
  add_parallel
  run_script
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------------------------------------------
# Job count comes from the machine, not a constant
# ---------------------------------------------------------------------------------------------------------------

@test "jobs: derived from getconf _NPROCESSORS_ONLN (two different core counts give two different --jobs)" {
  add_parallel
  run_script STUB_CORES=3
  [ "$status" -eq 0 ]
  case "$(log_line 1)" in "--jobs 3 "*) ;; *) false ;; esac
  : > "$STUB_LOG"
  run_script STUB_CORES=12
  [ "$status" -eq 0 ]
  case "$(log_line 1)" in "--jobs 12 "*) ;; *) false ;; esac
}

@test "jobs: falls back to nproc when getconf yields nothing" {
  add_parallel
  printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/getconf"
  printf '#!/usr/bin/env bash\necho 7\n' > "$STUBS/nproc"
  chmod +x "$STUBS/nproc"
  run_script
  [ "$status" -eq 0 ]
  case "$(log_line 1)" in "--jobs 7 "*) ;; *) false ;; esac
}

@test "jobs: falls back to sysctl -n hw.ncpu when getconf and nproc yield nothing" {
  add_parallel
  printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/getconf"
  printf '#!/usr/bin/env bash\n[ "$1 $2" = "-n hw.ncpu" ] && echo 9\n' > "$STUBS/sysctl"
  chmod +x "$STUBS/sysctl"
  run_script
  [ "$status" -eq 0 ]
  case "$(log_line 1)" in "--jobs 9 "*) ;; *) false ;; esac
}

@test "jobs: no way to count cores means 1 job, which means the serial fallback" {
  add_parallel
  printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/getconf"
  run_script
  [ "$status" -eq 0 ]
  [ "$(log_count)" -eq 1 ]
  case "$(log_line 1)" in *--jobs*) false ;; esac
}

@test "jobs: RUN_TESTS_JOBS overrides detection" {
  add_parallel
  run_script RUN_TESTS_JOBS=2
  [ "$status" -eq 0 ]
  case "$(log_line 1)" in "--jobs 2 "*) ;; *) false ;; esac
}

@test "jobs: an invalid RUN_TESTS_JOBS is ignored with a warning and detection is used" {
  add_parallel
  run_script RUN_TESTS_JOBS=lots
  [ "$status" -eq 0 ]
  case "$output" in *"invalid RUN_TESTS_JOBS"*) ;; *) false ;; esac
  case "$(log_line 1)" in "--jobs 4 "*) ;; *) false ;; esac
}

# ---------------------------------------------------------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------------------------------------------------------

@test "package.json's test script delegates to scripts/run-tests.sh and nothing else" {
  run jq -r '.scripts.test' "$REPO_PKG"
  [ "$status" -eq 0 ]
  [ "$output" = "bash scripts/run-tests.sh" ]
}

@test "the script lists exactly the two known shared-state files as serial" {
  run grep -c '^  "tests/mirror-.*-invariant\.bats"$' "$SCRIPT_SRC"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}
