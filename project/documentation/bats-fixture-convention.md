# bats fixture convention

How the framework's bats suite (`tests/*.bats`) is run, and how a test that asserts on a script's output is written so
that it checks behaviour rather than describing whatever the repository happens to contain today. Introduced by
`E43_S01_T01`.

Where this document and a suite ever disagree, the suite wins and this document is corrected.

## Running the suite

From a clean checkout, one command pair:

```
npm install     # once; installs bats (a devDependency) into node_modules/
npm test        # runs: bats tests/*.bats
```

`npm test` is the `test` script in `package.json`. To run a single file, use the repo-pinned binary:
`node_modules/.bin/bats tests/discover-tests.bats`. `j.test` discovers and runs the same suites and prints a summary
(see [test-runner.md](test-runner.md)). The suite declaration for tester agents is `project/configs/test-config.json`
(`bats` for both `unit` and `integration`, `shellcheck` for `sast`).

## Why a convention exists

On 2026-08-26, during `E40_S04_T03`, two findings were raised with confidence and both were wrong in the same way:
they were measured under a non-default flag (`discover-subsystems.sh --include-framework`) and then generalised to the
default path that `onboard` actually uses. A test that runs a script against the repository root and asserts on the
output has the same defect built in. It passes today, but the repository's contents change, so the assertion quietly
becomes a description of the present instead of a check of behaviour. (A default `onboard` run over this repository
yields 9 candidates against a cap of 8, exactly one drop, so a green run against it proves almost nothing.)

The convention makes the wrong thing hard and the right thing the easy default.

## The two rules

**Rule 1: assert on a fixture tree, never on the repository root.**
A test that asserts on a candidate set, a ranking, a count or a drop record points the script under test at a
**fixture tree** with a known, committed expected result. It never points it at the repository root, at `$REPO_ROOT`
as a scan target, or at any other live directory whose contents change as the project grows. Reading the live
repository to locate the script under test (`"$REPO_ROOT/skills/..."`) is fine; scanning it is not.

**Rule 2: a non-default flag is named in the `@test` description.**
A test that exercises a non-default flag, environment variable or mode says so in its `@test` name (for example
`--root on a fixture path gives that fixture's output, ...`, `... under --include-framework`). A reader scanning test
names must be able to see which path was measured. A test with no flag in its name is a claim about the default path,
and it must be run on defaults.

## Where fixtures live

Fixture trees live under **`tests/fixtures/`**, one directory per script or feature, one subdirectory per case:

```
tests/fixtures/<script-or-feature>/<case>/
    ...the inert tree the script is pointed at...
    expected.json        # the recorded expected result for this case
```

- **Inert.** A fixture is data. No executable bits, no real test constructs (`@test`, `def test_`, `func Test`), no
  scripts that do anything but `echo`. The runner discovery skips directories named `fixtures`, so a fixture is never
  mistaken for a suite.
- **Read-only.** A test never writes into a fixture. Anything it needs to create or mutate goes under
  `$BATS_TEST_TMPDIR` (copy the fixture there first when the script writes).
- **One case per behaviour.** Prefer several small trees, each named for the behaviour it pins (`empty`,
  `broken-config`, `go-and-cargo`), over one large tree that exercises everything.
- Shared helper code lives in `tests/helpers/` (for example `tests/helpers/assertions.bash`), not in a fixture.

Small, non-tree inputs (a case table, a golden file) may sit directly in `tests/fixtures/` as a single file; the rules
above apply to anything a script scans.

## How a test points at a fixture

The test names the fixture by path, relative to its own location, and passes it to the script through the script's
documented root argument (not by changing directory into the repository):

```bash
REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DISCOVER="$REPO_ROOT/skills/j-test/scripts/discover-tests.sh"
FIXTURES="$REPO_ROOT/tests/fixtures/test-discovery"

run bash "$DISCOVER" --root "$FIXTURES/npm-multi"
```

`$REPO_ROOT` locates the script under test and the fixture directory; it is never what the script scans.

## How expected results are recorded

The expected result is committed **alongside** the fixture it describes, as `expected.json` in the case directory, so
that a change to the tree and a change to its expected result are one diff and cannot drift apart.

- Compare structured output as canonical JSON (`jq -S .` on both sides), not as a substring of the raw text; a
  substring check passes on malformed output.
- On a mismatch, print a diff of expected against actual, so a failure points at the difference.
- Where one property matters on its own (an id is absent, a warning is present), add a targeted `jq` assertion next
  to the whole-output comparison, so a failure names the claim.
- Add a guard that every case directory has an `expected.json` and a case in the test file, so a fixture cannot be
  added and silently never run.

## Worked example

| Piece | Path |
|---|---|
| Script under test | `skills/j-test/scripts/discover-tests.sh` |
| Fixture trees | `tests/fixtures/test-discovery/<case>/` (`npm-multi`, `bats-nested`, `pytest-conventions`, `go-and-cargo`, `empty`, `broken-config`, `config-overlay`) |
| Recorded expected result | `tests/fixtures/test-discovery/<case>/expected.json` |
| Suite | `tests/discover-tests.bats` |

In that suite:

- `fixture_matches <name>` runs `discover-tests.sh --root "$FIXTURES/<name>"` on the default path and compares the
  output to `<name>/expected.json` (rule 1, expected result recorded alongside).
- The test `every directory under tests/fixtures/test-discovery has an expected.json and a case above` is the guard.
- `--root on a fixture path gives that fixture's output, not the surrounding repo's` is rule 2: the non-default
  flag is in the test name, and the assertion is that the answer comes from the fixture rather than from the
  repository around it.
- The script runs under a controlled `PATH` (a temp directory of symlinks to the tools it needs), so `expected.json`
  cannot depend on what is installed on the host.

## Checklist for a new test

1. Does it assert on a candidate set, ranking, count or drop record? Then it scans a fixture tree, not the repository.
2. Does the fixture sit under `tests/fixtures/<script-or-feature>/<case>/`, inert, with `expected.json` beside it?
3. Is the output compared as canonical JSON, with a diff on mismatch?
4. Does a non-default flag, variable or mode appear in the `@test` description?
5. Is everything the test writes under `$BATS_TEST_TMPDIR`?
