#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# Coverage for scripts/run-tests.sh (E43_S02_T01): parallel bats with a dependency check and a serial fallback;
# E95_S01_T02 bounded `npm test` under a timeout; E95_S02_T03 selects by tier (default tier:fast, `--all` = every
# tier except tier:manual), refuses a selection above full_run_confirm_file_count without --confirm-full (unless
# CI=true), refuses to start from inside a bats run, runs one bats invocation per file with progress, and puts every
# mode under a timeout; E95_S02_T08 runs up to J files at once (scripts/parallel-files.sh), keeps the per-file report
# and output, and makes the tier:fast timeout max(180, 2 x estimate). run_script calls `--all --confirm-full --jobs 1`
# (one file at a time, so the stub log has a fixed order); the cases marked "parallel" run with J > 1.
#
# Isolation: every test runs a COPY of the script (and of the helpers it calls: scripts/parallel-files.sh,
# scripts/test-tiers.sh, scripts/test-estimate.sh, skills/j-test/scripts/test-thresholds.sh, tests/helpers/nested-suite.bash) inside its
# own temp "repo" (the script resolves its repository root from its own location), against a fake tests/ directory
# of tier-tagged empty files, with a PATH that contains only stubs and the real tools the script and those helpers
# need. Nothing here runs a real bats suite, touches the real repository's tests/, .claude/, .agents/, .git/config
# or .mirror-worktrees, or needs GNU parallel / rush installed. The one real-repository case uses --list, which
# runs nothing.
#
# Because these cases call the script from inside bats, they set RUN_TESTS_ALLOW_NESTED=1, the script's test-only
# override of its nesting refusal (and clear JENGA_NESTED_SUITE_RUN, which a mirror gate run sets). This file is
# the only caller that sets it; the nesting-refusal case below runs without it.
#
# The stub `bats` appends each invocation's argv to $STUB_LOG (one line per invocation; `bats --help` is answered
# but not logged), exits 1 when its argv contains any whitespace-separated token listed in $STUB_FAIL_ON (which
# models "a failing test lives in that file"; it then prints a `not ok` line, and an `ok` line otherwise), and hangs (exec sleep 30) when its argv contains $STUB_HANG_ON.
# The stub `parallel` / `rush` exist only so `command -v` finds them; the stub `bats` never delegates to them.

bats_require_minimum_version 1.5.0

SCRIPT_SRC="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/run-tests.sh"
REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
REPO_PKG="$REPO_DIR/package.json"

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

  mkdir -p "$FAKE/scripts" "$FAKE/tests/fixtures" "$FAKE/tests/helpers" "$FAKE/skills/j-test/scripts" \
    "$STUBS" "$TOOLS"
  cp "$SCRIPT_SRC" "$FAKE/scripts/run-tests.sh"
  cp "$REPO_DIR/scripts/test-tiers.sh" "$REPO_DIR/scripts/test-estimate.sh" "$REPO_DIR/scripts/parallel-files.sh" \
    "$FAKE/scripts/"
  cp "$REPO_DIR/skills/j-test/scripts/test-thresholds.sh" "$FAKE/skills/j-test/scripts/"
  cp "$REPO_DIR/tests/helpers/nested-suite.bash" "$FAKE/tests/helpers/"
  # Tier-tagged empty files: a, b fast (npm test); c unit; m manual (never in --all); the two shared-state files.
  tag_file tests/a.bats fast
  tag_file tests/b.bats fast
  tag_file tests/c.bats unit
  tag_file tests/m.bats manual
  tag_file "$PERM" integration
  tag_file "$SUBJ" integration
  # Inputs under tests/fixtures/ must never be run (some are deliberately failing).
  printf '# bats file_tags=tier:fast\n' > "$FAKE/tests/fixtures/broken.bats"

  # The real tools the script and its helpers shell out to (plus bash, for the stubs' shebang). The watchdog polls
  # with sleep. The stubs are bash scripts started through `#!/usr/bin/env bash`, which resolves bash on this PATH.
  local t
  for t in dirname basename grep sleep jq awk sed find sort xargs tr mktemp rm cat wc cut env; do
    ln -s "$(command -v "$t")" "$TOOLS/$t"
  done
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
if [ -n "${STUB_HANG_ON:-}" ]; then
  case " $* " in *" $STUB_HANG_ON "*) exec sleep 30 ;; esac
fi
for p in ${STUB_FAIL_ON:-}; do
  case " $* " in *" $p "*) echo "not ok 1 stub failure in $p"; exit 1 ;; esac
done
echo "ok 1 stub pass"
exit 0
EOF
  chmod +x "$STUBS/bats"

  # Core-count stub: the value under test.
  printf '#!/usr/bin/env bash\necho "${STUB_CORES:-4}"\n' > "$STUBS/getconf"
  chmod +x "$STUBS/getconf"
  export STUB_CORES=4
}

# tag_file <repo-relative path> <tier>: an empty test file in the fake repo carrying that tier tag.
tag_file() { printf '#!/usr/bin/env bats\n# bats file_tags=tier:%s\n' "$2" > "$FAKE/$1"; }

# run_script: the FULL run (`--all --confirm-full`), one file at a time (`--jobs 1`), under the stub PATH. Extra "VAR=value" words become env vars of
# that one run. run_fast: the no-argument run (tier:fast), the same way. run_args: the given script arguments (env
# vars through `export`). CI is cleared so the host's CI cannot leak; RUN_TESTS_ALLOW_NESTED=1 is the script's
# test-only nesting override (see the header).
STUB_ENV=(CI= RUN_TESTS_ALLOW_NESTED=1 JENGA_NESTED_SUITE_RUN=)
run_script() {
  run env PATH="$STUBS:$TOOLS" "${STUB_ENV[@]}" "$@" "$BASH" "$FAKE/scripts/run-tests.sh" --all --confirm-full --jobs 1
}
run_fast() {
  run env PATH="$STUBS:$TOOLS" "${STUB_ENV[@]}" "$@" "$BASH" "$FAKE/scripts/run-tests.sh"
}
run_args() {
  run env PATH="$STUBS:$TOOLS" "${STUB_ENV[@]}" "$BASH" "$FAKE/scripts/run-tests.sh" "$@"
}

add_parallel() { printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/parallel"; chmod +x "$STUBS/parallel"; }
add_rush()     { printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/rush";     chmod +x "$STUBS/rush"; }

log_line() { sed -n "${1}p" "$STUB_LOG"; }
log_count() { wc -l < "$STUB_LOG" | tr -d '[:space:]'; }

# ---------------------------------------------------------------------------------------------------------------
# Serial fallback
# ---------------------------------------------------------------------------------------------------------------

@test "no parallel binary: one plain bats invocation per file, no --jobs, shared-state files last, and exit 0" {
  run_script
  [ "$status" -eq 0 ]
  [ "$(log_count)" -eq 5 ]
  [ "$(cat "$STUB_LOG")" = "$(printf '%s\n' tests/a.bats tests/b.bats tests/c.bats "$PERM" "$SUBJ")" ]
  # Per-file progress streams: i/N after each file.
  case "$output" in *"[1/5] tests/a.bats ok "*"[5/5] $SUBJ ok "*) ;; *) false ;; esac
  # --jobs 1 streams bats' output as before (E95_S02_T03 loop).
  [ "$(grep -c '^ok 1 stub pass$' <<< "$output")" -eq 5 ]
}

@test "parallel: --all selects every top-level tests/*.bats except tier:manual, never tests/fixtures; shared-state files run alone, last" {
  mkdir -p "$FAKE/project/configs"
  printf '{"test_parallel_jobs": 3}\n' > "$FAKE/project/configs/test-config.json"
  run_args --all --confirm-full
  [ "$status" -eq 0 ]
  local covered expected
  covered="$(sort "$STUB_LOG")"
  expected="$(cd "$FAKE" && printf '%s\n' tests/*.bats | grep -v '^tests/m\.bats$' | sort)"
  [ "$covered" = "$expected" ]
  if grep -q 'fixtures\|tests/m\.bats' "$STUB_LOG"; then return 1; fi
  # J from the config key; files in parallel run plain (no in-file --jobs); the shared-state files come last.
  case "$output" in *"up to 3 files at once (test_parallel_jobs in test-config.json)"*) ;; *) false ;; esac
  if grep -q -- --jobs "$STUB_LOG"; then return 1; fi
  [ "$(sed -n '4,5p' "$STUB_LOG")" = "$(printf '%s\n' "$PERM" "$SUBJ")" ]
  # A passing file's own output is not printed in parallel mode.
  case "$output" in *"ok 1 stub pass"*) false ;; esac
  [ "$(grep -c '^run-tests: \[[1-5]/5\] tests/.* ok [0-9]* s (elapsed [0-9]* s)$' <<< "$output")" -eq 5 ]
}

@test "parallel: a failing file in tier:fast (npm test) exits non-zero, prints that file's own output, calls on_file_done once per file" {
  STUB_FAIL_ON="tests/a.bats"
  export STUB_FAIL_ON
  # The hook is a no-op in the real script; in this copy it records its arguments.
  export HOOK_LOG="$TMP/hook.log"
  sed -i.bak 's|^  :  # E95_S07 hook point$|  printf "%s %s %s\\n" "$1" "$2" "$3" >> "$HOOK_LOG"|' "$FAKE/scripts/run-tests.sh"
  grep -q 'HOOK_LOG' "$FAKE/scripts/run-tests.sh"
  run_fast
  [ "$status" -eq 1 ]
  [ "$(sort "$STUB_LOG")" = "$(printf '%s\n' tests/a.bats tests/b.bats)" ]
  case "$output" in *"up to 4 files at once (CPU count 4, capped at 8)"*) ;; *) false ;; esac
  case "$output" in *"tests/a.bats FAILED (exit 1) "*) ;; *) false ;; esac
  case "$output" in *"--- output of tests/a.bats ---"*"not ok 1 stub failure in tests/a.bats"*) ;; *) false ;; esac
  case "$output" in *"output of tests/b.bats"*|*"ok 1 stub pass"*) false ;; esac
  [ "$(sort "$HOOK_LOG" | sed 's/ [0-9]*$//')" = "$(printf '%s\n' 'tests/a.bats 1' 'tests/b.bats 0')" ]
}

@test "jobs below 2 (RUN_TESTS_JOBS=1) with a parallel binary present falls back to plain invocations" {
  add_parallel
  run_script RUN_TESTS_JOBS=1
  [ "$status" -eq 0 ]
  [ "$(log_count)" -eq 5 ]
  ! grep -q -- --jobs "$STUB_LOG"
}

@test "a bats without --jobs support falls back to plain invocations even with a parallel binary present" {
  add_parallel
  run_script STUB_BATS_NO_JOBS=1
  [ "$status" -eq 0 ]
  [ "$(log_count)" -eq 5 ]
  ! grep -q -- --jobs "$STUB_LOG"
}

@test "no bats on PATH: exits 127 with a message, runs nothing" {
  rm "$STUBS/bats"
  run -127 env PATH="$STUBS:$TOOLS" "${STUB_ENV[@]}" "$BASH" "$FAKE/scripts/run-tests.sh"
  [ "$status" -eq 127 ]
  case "$output" in *"bats not found"*) ;; *) false ;; esac
}

# ---------------------------------------------------------------------------------------------------------------
# Two passes
# ---------------------------------------------------------------------------------------------------------------

@test "GNU parallel present: --jobs N within each bulk file, then a plain run of each of the two shared-state files" {
  add_parallel
  run_script
  [ "$status" -eq 0 ]
  [ "$(log_count)" -eq 5 ]
  [ "$(log_line 1)" = "--jobs 4 tests/a.bats" ]
  [ "$(log_line 3)" = "--jobs 4 tests/c.bats" ]
  [ "$(log_line 4)" = "$PERM" ]
  [ "$(log_line 5)" = "$SUBJ" ]
}

@test "the invocations together cover every non-manual top-level tests/*.bats exactly once, never tests/fixtures" {
  add_parallel
  run_script
  [ "$status" -eq 0 ]
  local covered expected
  covered="$(sed 's/^--jobs [0-9]* //' "$STUB_LOG" | sort)"
  expected="$(cd "$FAKE" && printf '%s\n' tests/*.bats | grep -v '^tests/m\.bats$' | sort)"
  [ "$covered" = "$expected" ]
  ! grep -q fixtures "$STUB_LOG"
  # Neither shared-state file runs with --jobs.
  ! grep -q -- '--jobs.*mirror-' "$STUB_LOG"
}

@test "only rush present: --parallel-binary-name rush is passed (bats does not fall back to rush by itself)" {
  add_rush
  run_script
  [ "$status" -eq 0 ]
  [ "$(log_line 1)" = "--jobs 4 --parallel-binary-name rush tests/a.bats" ]
  [ "$(log_line 4)" = "$PERM" ]
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
  [ "$(log_count)" -eq 4 ]
  [ "$(log_line 4)" = "$PERM" ]
}

@test "no shared-state files present: only the parallel invocations run" {
  add_parallel
  rm "$FAKE/$SUBJ" "$FAKE/$PERM"
  run_script
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_LOG")" = "$(printf '%s\n' '--jobs 4 tests/a.bats' '--jobs 4 tests/b.bats' '--jobs 4 tests/c.bats')" ]
}

@test "only shared-state files present: only the plain shared-state invocations run" {
  add_parallel
  rm "$FAKE/tests/a.bats" "$FAKE/tests/b.bats" "$FAKE/tests/c.bats"
  run_script
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_LOG")" = "$(printf '%s\n' "$PERM" "$SUBJ")" ]
}

# ---------------------------------------------------------------------------------------------------------------
# Exit-code aggregation: a failure in ANY of the three groups must fail the script
# ---------------------------------------------------------------------------------------------------------------

@test "exit code: a failing test in the bulk-parallel group fails the script, and the shared-state files still run" {
  add_parallel
  STUB_FAIL_ON="tests/b.bats"
  export STUB_FAIL_ON
  run_script
  [ "$status" -ne 0 ]
  [ "$(log_count)" -eq 5 ]
}

@test "exit code: a failing mirror-permission-level-invariant fails the script" {
  add_parallel
  STUB_FAIL_ON="$PERM"
  export STUB_FAIL_ON
  run_script
  [ "$status" -ne 0 ]
  [ "$(log_count)" -eq 5 ]
}

@test "exit code: a failing mirror-test-subject-invariant fails the script" {
  add_parallel
  STUB_FAIL_ON="$SUBJ"
  export STUB_FAIL_ON
  run_script
  [ "$status" -ne 0 ]
  [ "$(log_count)" -eq 5 ]
}

@test "exit code: failures in both groups still fail the script (the first failure is not masked by later files)" {
  add_parallel
  STUB_FAIL_ON="tests/a.bats $SUBJ"
  export STUB_FAIL_ON
  run_script
  [ "$status" -ne 0 ]
  [ "$(log_count)" -eq 5 ]
}

@test "exit code: the bulk failure is not lost when the shared-state files pass afterwards (status 1, not 0)" {
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
  # Files at once (no --jobs, no RUN_TESTS_JOBS, no config key): the CPU count capped at 8, never with in-file --jobs.
  : > "$STUB_LOG"
  export STUB_CORES=12
  run_args --all --confirm-full
  [ "$status" -eq 0 ]
  case "$output" in *"up to 8 files at once (CPU count 12, capped at 8)"*) ;; *) false ;; esac
  ! grep -q -- --jobs "$STUB_LOG"
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

@test "jobs: no way to count cores means 1 job, which means plain invocations" {
  add_parallel
  printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/getconf"
  run_script
  [ "$status" -eq 0 ]
  [ "$(log_count)" -eq 5 ]
  ! grep -q -- --jobs "$STUB_LOG"
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

@test "package.json's test script delegates to scripts/run-tests.sh and nothing else; test:ci is --all, and CI runs it" {
  run jq -r '.scripts.test' "$REPO_PKG"
  [ "$status" -eq 0 ]
  [ "$output" = "bash scripts/run-tests.sh" ]
  run jq -r '.scripts["test:ci"]' "$REPO_PKG"
  [ "$status" -eq 0 ]
  [ "$output" = "bash scripts/run-tests.sh --all" ]
  # The public staging gate keeps the full suite: its test job runs npm run test:ci, not npm test.
  grep -q '^        run: npm run test:ci$' "$REPO_DIR/.github/workflows/mirror-staging-gate.yml"
  ! grep -q '^        run: npm test$' "$REPO_DIR/.github/workflows/mirror-staging-gate.yml"
}

@test "the shared helper lists exactly the two known shared-state files as serial, and the script uses it" {
  run grep -c '^  "tests/mirror-.*-invariant\.bats"$' "$REPO_DIR/scripts/parallel-files.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
  grep -q 'pf_is_serial_file' "$SCRIPT_SRC"
}

# ---------------------------------------------------------------------------------------------------------------
# E95_S02_T03: tiers, deliberate large runs, nesting refusal, timeout, estimate
# ---------------------------------------------------------------------------------------------------------------

@test "regression guard: npm test's selection in this repository is tier:fast only, at most 40 files, and runs nothing" {
  # The real script on the real repository, with the stub bats: --list must not invoke it at all. The bound is 40:
  # npm test stays a bounded run (E95_S01_T02 measured 30 files, about 90 s).
  run env PATH="$STUBS:$TOOLS" "${STUB_ENV[@]}" "$BASH" "$SCRIPT_SRC" --list
  [ "$status" -eq 0 ]
  [ "$(log_count)" -eq 0 ]
  local n=0 f
  while IFS= read -r f; do
    case "$f" in tests/*.bats) ;; *) continue ;; esac   # estimate lines (stderr) are merged into $output
    n=$((n + 1))
    case "$f" in tests/*/*) false ;; esac
    [ -f "$REPO_DIR/$f" ]
    grep -qx '# bats file_tags=tier:fast' "$REPO_DIR/$f"
    [ "$f" != "$PERM" ]
    [ "$f" != "$SUBJ" ]
  done <<< "$output"
  [ "$n" -ge 1 ]
  [ "$n" -le 40 ]
}

@test "a selection above full_run_confirm_file_count without --confirm-full exits 2, runs nothing, and names a cheaper tier" {
  mkdir -p "$FAKE/project/configs"
  printf '{"full_run_confirm_file_count": 2}\n' > "$FAKE/project/configs/test-config.json"
  add_parallel
  run_args --all
  [ "$status" -eq 2 ]
  [ "$(log_count)" -eq 0 ]
  case "$output" in *"selects 5 files"*"full_run_confirm_file_count (2)"*) ;; *) false ;; esac
  case "$output" in *"cheapest tier that covers the request is tier:fast: 2 file(s), estimate "*) ;; *) false ;; esac
  case "$output" in *"scripts/run-tests.sh --tier fast'"*) ;; *) false ;; esac
  case "$output" in *"--all --confirm-full"*) ;; *) false ;; esac
  # The gate is not limited to --all.
  run_args --tier fast,unit
  [ "$status" -eq 2 ]
  [ "$(log_count)" -eq 0 ]
  # --confirm-full accepts it.
  run_args --tier fast,unit --confirm-full
  [ "$status" -eq 0 ]
  [ "$(log_count)" -eq 3 ]
}

@test "CI=true accepts a large run without --confirm-full; the timeout is max(180, 2 x estimate) for tier:fast and the rule otherwise" {
  mkdir -p "$FAKE/project/configs"
  printf '{"full_run_confirm_file_count": 2}\n' > "$FAKE/project/configs/test-config.json"
  run env PATH="$STUBS:$TOOLS" "${STUB_ENV[@]}" CI=true "$BASH" "$FAKE/scripts/run-tests.sh" --all
  [ "$status" -eq 0 ]
  [ "$(log_count)" -eq 5 ]
  # No timing log in the fake repo: every file untimed, so max(600, 2 x 0 + 120 x 5) = 600.
  case "$output" in *"estimate: 0 s for 5 file(s) (0 timed, 5 untimed)"*"untimed: tests/a.bats"*) ;; *) false ;; esac
  case "$output" in *"timeout 600 s (max(600, 2 x 0 s + 120 s x 5 untimed))"*) ;; *) false ;; esac
  : > "$STUB_LOG"
  run_fast
  [ "$status" -eq 0 ]
  case "$output" in *"timeout 180 s (tier:fast: max(180, 2 x 0 s))"*) ;; *) false ;; esac
  # Relative (E95_S02_T08): a 100 s estimate for the fast tier gives 200 s.
  mkdir -p "$FAKE/project/logs"
  printf '%s\n' '{"date":"2026-11-18T00:00:00Z","suite":"tests/a.bats","duration_ms":100000,"scope":"file"}' \
    > "$FAKE/project/logs/test-timings.jsonl"
  run_fast
  [ "$status" -eq 0 ]
  case "$output" in *"timeout 200 s (tier:fast: max(180, 2 x 100 s))"*) ;; *) false ;; esac
}

@test "tier selection: --tier runs only those tags, tier:manual only when named, unknown tier or empty selection exits 2" {
  run_args --tier unit
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_LOG")" = "tests/c.bats" ]
  : > "$STUB_LOG"
  run_args --tier manual
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_LOG")" = "tests/m.bats" ]
  : > "$STUB_LOG"
  run_args --list --tier fast,unit
  [ "$status" -eq 0 ]
  case "$output" in *"tests/a.bats"*"tests/b.bats"*"tests/c.bats"*) ;; *) false ;; esac
  run_args --tier bogus
  [ "$status" -eq 2 ]
  case "$output" in *"unknown tier 'bogus'"*) ;; *) false ;; esac
  run_args --tier slow
  [ "$status" -eq 2 ]
  case "$output" in *"selects no file"*"not a pass"*) ;; *) false ;; esac
  run_args --tier fast --all
  [ "$status" -eq 2 ]
  [ "$(log_count)" -eq 0 ]
  # --jobs wants a positive whole number.
  run_args --jobs 0
  [ "$status" -eq 2 ]
  run_args --jobs many
  [ "$status" -eq 2 ]
  [ "$(log_count)" -eq 0 ]
}

@test "nesting refusal: a run started from inside bats, or under JENGA_NESTED_SUITE_RUN=1, exits 3 and runs nothing" {
  # Inside this bats run, without the test-only override: BATS_TEST_FILENAME / BATS_RUN_TMPDIR are set.
  run env PATH="$STUBS:$TOOLS" CI= JENGA_NESTED_SUITE_RUN= "$BASH" "$FAKE/scripts/run-tests.sh"
  [ "$status" -eq 3 ]
  [ "$(log_count)" -eq 0 ]
  case "$output" in *"refusing to start a test run from inside another one: started from inside a bats run"*) ;; *) false ;; esac
  # E77_S01's flag, read through tests/helpers/nested-suite.bash, with the bats variables removed.
  run env -u BATS_TEST_FILENAME -u BATS_RUN_TMPDIR PATH="$STUBS:$TOOLS" CI= JENGA_NESTED_SUITE_RUN=1 \
    "$BASH" "$FAKE/scripts/run-tests.sh"
  [ "$status" -eq 3 ]
  [ "$(log_count)" -eq 0 ]
  case "$output" in *"JENGA_NESTED_SUITE_RUN=1"*) ;; *) false ;; esac
  # --list runs nothing and is never refused.
  run env PATH="$STUBS:$TOOLS" CI= "$BASH" "$FAKE/scripts/run-tests.sh" --list
  [ "$status" -eq 0 ]
}

@test "parallel timeout: every running file is stopped, finished / stopped / never-started are listed, and the exit is 124" {
  export STUB_HANG_ON="tests/b.bats"
  export RUN_TESTS_TIMEOUT=2
  local t0=$SECONDS
  run_args --tier fast,unit,integration --jobs 2
  [ "$status" -eq 124 ]
  case "$output" in *"timed out after 2 s"*) ;; *) false ;; esac
  # a and c finish around the hanging b; the shared-state files never start (they run only after the batch).
  case "$output" in *"finished (2 of 5):"*) ;; *) false ;; esac
  case "$output" in *"run-tests:   ok tests/a.bats"*) ;; *) false ;; esac
  case "$output" in *"run-tests:   ok tests/c.bats"*) ;; *) false ;; esac
  case "$output" in *"not finished (3 of 5):"*"stopped     tests/b.bats"*"not started $PERM"*"not started $SUBJ"*) ;; *) false ;; esac
  [ "$(sort "$STUB_LOG")" = "$(printf '%s\n' tests/a.bats tests/b.bats tests/c.bats)" ]
  # The hanging file (sleep 30) was stopped, not waited for.
  [ $((SECONDS - t0)) -lt 15 ]
}
