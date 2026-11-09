---
name: j.test
description: Discover the project's test suites, show them as a numbered list, run the ones you pick (blank means all) in order, and print a pass/fail summary whose exit code is 0 when every suite passed and 1 otherwise. Can also check on its own whether the machine is slow ('probe'), and before a full run offers what to do when it is.
keywords:
  - run tests
  - test suite
  - run all tests
  - which tests
  - j-test
  - slow machine
examples:
  - "run the tests"
  - "j-test"
  - "run all the test suites"
  - "run only the unit tests"
  - "which tests can I run?"
  - "run tests 1 and 3"
  - "is my machine too slow to run the tests?"
---

# Test — Pick Suites and Run Them

`skills/j-test/` is the **canonical, hand-edited** directory for this skill; the frontmatter name is `j.test`, never `j.j-test`. This skill is a user-invoked convenience runner. This file holds only the conversation and the interpretation of results: discovery, de-duplication, rendering, parsing the answer, the slowness probe and execution are scripts in `skills/j-test/scripts/`, whose headers are the contracts. Do not restate or re-implement their logic here.

## Boundaries

- It **never writes board status** (no task, story or epic status) and never replaces the tester agent. A `j.test` result is information for the user, not a verdict on any board item.
- The developer agent never invokes it on its own: the developer never runs tests (see `CLAUDE.md`).
- Per-scope test-run policy (which run must pass before a task, story or epic closes) is a separate mechanism owned by the tester agent: see `scope-policy.sh` and `scope-test-gate.sh` in `skills/j-test/scripts/` and the "Scope test policy" section of `project/documentation/test-runner.md`.
- Blank input means **all suites**: running the full suite is the default.
- The slowness probe never changes which suites run. What a slow result leads to is always the user's choice (step 5); the only thing it writes is the machine-local threshold, and only when the user asks to change it.

## Instructions

Resolve the scripts directory once, and create one scratch file for the catalog:

```bash
TEST_DIR="$([ -d skills/j-test/scripts ] && echo skills/j-test/scripts || echo node_modules/@jenga-ai/agent/skills/j-test/scripts)"
CATALOG="$(mktemp)"
```

Shell variables do not survive between separate commands: define `TEST_DIR` again in each later command, and use the literal catalog path that `mktemp` printed.

### 1. Build the catalog, once

Tell the user discovery can take up to a minute on a large repository, then run:

```bash
bash "$TEST_DIR/build-catalog.sh" > "$CATALOG"
```

Reuse `$CATALOG` for every later step. Never run discovery again in this session. If the script exits non-zero, show its stderr and stop.

### 2. Nothing runnable

If `jq '.runnable | length' "$CATALOG"` is `0`, say so plainly, show `bash "$TEST_DIR/build-catalog.sh" --render "$CATALOG"` (it lists any `not_runnable` entries and warnings) and stop. Do not invent a command.

### 3. Show the list

Print `bash "$TEST_DIR/build-catalog.sh" --render "$CATALOG"` verbatim, including its final prompt line, and take the user's answer exactly as typed (blank included).

### 4. Parse the answer

```bash
bash "$TEST_DIR/parse-selection.sh" <N> "<answer>"
```

`<N>` is `jq '.runnable | length' "$CATALOG"`. Exit `0`: its stdout is the suite numbers, in order, or the single word `probe` (the user only wants to know whether the machine is slow: no suite runs). Exit `1`: show its stderr messages and ask again, repeating until the answer is valid or the user cancels; nothing runs on an invalid answer. Never interpret the answer in this file.

### 5. Slowness check

Only when the answer was `probe`, or the selected numbers are every runnable suite (as many as `<N>`); any other selection goes straight to step 6. Tell the user the check takes about a minute, then run:

```bash
bash "$TEST_DIR/slowness-check.sh" probe
```

Relay its report unchanged and act on its exit code:

- `0`, healthy: say so. A suite selection goes on to step 6. For `probe`, offer `1. Return to test selection`, `2. Done`, `3. Other (describe below)`.
- `1`, the reference file failed, or `3`, skipped (`bats` or the reference file is absent): say that no slowness verdict was reached and why, then treat it as healthy.
- `130`: interrupted; stop.
- `10`, slow: show this menu (for `probe`, leave out option 1, since nothing is waiting to run), with the ratio and threshold from the report:

  ```
  This machine is slow right now. What would you like to do?
  1. Continue anyway
  2. Cancel
  3. Return to test selection
  4. Change what counts as slow on this machine
  5. Other (describe below)
  ```

  - **Continue anyway**: go to step 6 and, after its summary, tell the user that wall-clock durations in this run are not a measure of the tests.
  - **Cancel**: nothing runs. Remove `$CATALOG` and stop.
  - **Return to test selection**: back to step 3 with the same catalog. Never rebuild it.
  - **Change what counts as slow**: show the current value with `bash "$TEST_DIR/slowness-check.sh" threshold` (wall time must exceed this many times CPU time), ask for the new number or `default` for the built-in 2.5, and save it with `bash "$TEST_DIR/slowness-check.sh" set-threshold <n|default>`. The value belongs to this machine only (git-ignored). If it refuses the value, show its message and ask again. Then run `bash "$TEST_DIR/slowness-check.sh" reclassify`, which judges the probe just made against the new value without measuring again: exit `0` means it no longer counts as slow, so carry on as healthy; exit `10` means it still does, so show the menu again.
  - **Other**: follow what the user describes.

### 6. Run

```bash
bash "$TEST_DIR/run-suites.sh" --catalog "$CATALOG" --no-probe <numbers...>
```

`--no-probe` is always passed: step 5 owns the slowness check, so the run never measures a second time. Stream its output as it runs and relay its `Test Results` summary unchanged.

### 7. Interpret and finish

By `run-suites.sh`'s exit code, which is also this skill's own result:

- `0`: every selected suite passed; say so.
- `1`: name the failed suites, then offer next steps:

  ```
  What would you like to do?
  1. Re-run only the failed suites (step 6 again, with their catalog numbers)
  2. Stop here
  3. Other (describe below)
  ```

- `2`: validation or usage error, nothing ran; show its stderr.
- `130`: interrupted; say which suites did not finish.

When the user is done (including after a re-run), remove `$CATALOG`.
