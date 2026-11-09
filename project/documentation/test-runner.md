# Test runner

This document describes the test tooling that ships with Jenga: the `j.test` skill, which discovers a project's test
suites and runs the ones you pick, the scope mapper that turns changed files into the suites that cover them, the two
`test-config.json` keys that configure them, and the test gate that `j.commit` runs before it commits.

The scripts are the contract. Every claim here is traced to the headers of the scripts under `skills/j-test/scripts/`
and `skills/j-commit/scripts/`, to `skills/j-test/SKILL.md`, and to step 3.5 of `skills/j-commit/SKILL.md`. Where this
document and a script ever disagree, the script wins and this document is corrected.

Paths in this document that point inside a consuming project resolve through the project root. The scripts are found
in `skills/j-test/scripts/` in a checkout and in `node_modules/@jenga-ai/agent/skills/j-test/scripts/` when Jenga is
installed as a dependency; the skills resolve that location themselves.

## Overview

`j.test` (also `/j-test`) is a user-invoked convenience runner. You ask for it, it finds the project's test suites,
shows them as a numbered list, runs the ones you choose in the order you give, and prints a pass/fail summary. Blank
input means all suites. Use it when you want to run the project's tests yourself without remembering each suite's
command.

What it is not:

- It **never writes board status** (no task, story or epic status). A `j.test` result is information for you, not a
  verdict on any board item.
- It **never replaces the tester agent.** The tester remains the only agent that validates work and updates statuses.
- **The developer agent never invokes it.** `CLAUDE.md`'s rule is unchanged: the developer never runs tests.

Following `CLAUDE.md`'s "Scripts Over Inline Logic" principle, `skills/j-test/SKILL.md` holds only the conversation and
the interpretation of results. Discovery, de-duplication, rendering, parsing your answer and execution are scripts:

| Script (`skills/j-test/scripts/`) | Role |
|---|---|
| `discover-tests.sh` | Finds suites by reading files and manifests; prints one JSON object (see "Discovery") |
| `build-catalog.sh` | Turns discovery output into the de-duplicated catalog, and renders the numbered list (see "Running tests") |
| `parse-selection.sh` | Validates the answer typed at the prompt and prints the chosen suite numbers |
| `run-suites.sh` | Runs the chosen suites in order and prints the summary; its exit code is the skill's result |
| `map-scope.sh` | Maps changed files to the suites that cover them; used by the commit gate's scoped option, not by `j.test` itself (see "Scope mapping") |

### How the pieces fit

```
j.test                    discover-tests.sh --> build-catalog.sh --> (numbered list)
                                                                      parse-selection.sh --> run-suites.sh

j.commit, scoped option   discover-tests.sh (once) --+--> map-scope.sh --suites ----+--> derived catalog --> run-suites.sh
                                                     +--> build-catalog.sh ---------+
j.commit, full option     the same catalog j.test builds ----------------------------------> run-suites.sh
```

`j.test` and the commit gate share the same discovery, catalog and execution scripts; the gate adds a decision layer
around them (see "The `j.commit` test gate"). The configuration both read is in "Configuration".

## Discovery

`skills/j-test/scripts/discover-tests.sh` finds the runnable test suites in a directory tree and prints one JSON
object. It takes `--root <dir>` (scan `<dir>` instead of the resolved project root; it must exist) and `--help`.

**It never executes project code.** Detection is manifest and file inspection only: `jq` over `package.json`, a
filesystem walk, and a `PATH` lookup. No project script, test runner or package manager is invoked to enumerate suites.
The commands in the output are strings for a later runner to execute. Discovery also never follows symlinks and never
writes a file.

### What it detects

| Ecosystem | A suite is... | Command |
|---|---|---|
| `npm` | each `package.json` script named `test` or matching `^test[:-]`; the suffix sets the type (`unit`, `integration`, `e2e`, `coverage` are recognised, anything else is `unknown`, bare `test` is `unit`) | `npm test` for `test`, otherwise `npm run <key>` |
| `bats` | one per directory holding `*.bats` files (not one per file), id `bats:<dir>` | `bats <dir>/*.bats` |
| `shellcheck` | one `shellcheck:all` suite when `shellcheck` is on `PATH`; nothing, and no warning, when it is not | a `find ... \| xargs -0 shellcheck` over the `.sh` files, skipping `node_modules` and dot-directories |
| `pytest` | a directory holding `test_*.py` or `*_test.py` (id `pytest:<dir>`); a directory holding only a marker (`conftest.py`, `pytest.ini`, or a `pyproject.toml` with `[tool.pytest.ini_options]`) counts too, unless a test-file directory sits at or below it | `pytest <dir>` |
| `go` | one per directory holding `*_test.go` (id `go:<dir>`); directories under `testdata/` are skipped | `go test ./<dir>/...` |
| `cargo` | needs `./Cargo.toml`; discovery greps for `#[test]` and never runs `cargo test`: in `src/**/*.rs` gives `cargo:unit`, in each `tests/*.rs` gives `cargo:integration:<file>` | `cargo test --lib`, `cargo test --test <file>` |

The walk is done once. It skips dot-directories (version-control metadata, tool state, and the generated `.claude/` and
`.agents/` trees with their nested worktrees), `node_modules`, `site-packages` (a virtual environment's own tests are
not the project's), and directories named `fixtures` or `__fixtures__` (inert test data is not a suite). The name is
matched on path components **below** the scan root, so `--root <dir>/fixtures/x` still scans that tree. The known
limitation: a project that keeps real suites under a directory literally named `fixtures` does not have them
discovered. A run can take 25-35 seconds on a large repository, because it walks the whole tree once.

### The `test-config.json` overlay

Discovery also reads `test-config.json` from the project's configs directory (resolved by `scripts/resolve-root.sh`)
and merges its `tools` array with what it detected. The overlay is authoritative but not exclusive. A tool counts as
"detected" when a detected suite has that ecosystem.

| Case | Result |
|---|---|
| `tool_name` is `-` | A "no tool for this type" placeholder: skipped, silently |
| Listed and detected | The suite keeps the detected `command`; its `type` becomes the configured one (unless its own type is already one of the tool's configured types). A configured type that no detected suite of that tool carries is added as `config:<tool>:<type>`, ecosystem `config`, inheriting the tool's first detected command |
| Listed, not detected | `config:<tool>:<type>`, ecosystem `config`, an empty `command`, and the warning `configured tool not detected on disk: <tool> (<type>)` |
| Detected, not listed | Kept, with the warning `detected tool not listed in test-config.json: <tool>` |

A missing file, invalid JSON, no `tools` array or an unreadable file is a warning, and the overlay is skipped; discovery
still exits 0.

### The suite JSON

```json
{"suites":[{"id":"bats:tests","name":"bats tests","type":"unit","ecosystem":"bats",
            "command":"bats tests/*.bats","paths":["tests/*.bats"]}],"warnings":[]}
```

| Field | Meaning |
|---|---|
| `id` | `<ecosystem>:<local-name>`, unique across the array; `suites` is sorted by `id` in byte order, whatever the locale |
| `name` | A human-readable label for a numbered list |
| `type` | `unit`, `integration`, `e2e`, `sast`, `vulnerability`, `performance`, `coverage` or `unknown` |
| `ecosystem` | `npm`, `bats`, `pytest`, `go`, `cargo`, `shellcheck` or `config` |
| `command` | The exact command a runner would execute, with the scanned root as its working directory; empty for a config-only suite |
| `paths` | Root-relative globs selecting the test files the `command` runs; always present, `[]` when they are not knowable, sorted and unique, always the last key |
| `warnings` | Strings, sorted; `[]` when there are none, never null |

`paths` per ecosystem (the scan root written as `.`): `bats:<dir>` gives `<dir>/*.bats`; `pytest:<dir>` gives
`<dir>/**/*_test.py` and `<dir>/**/test_*.py`; `go:<dir>` gives `<dir>/*_test.go`; `cargo:unit` gives `src/**/*.rs`;
`cargo:integration:<name>` gives `tests/<name>.rs`. An npm script is opaque and `shellcheck:all` checks sources rather
than test files, so both get `[]`. A `config:<tool>:<type>` suite carries the `paths` of the detected suite whose command
it inherits, and `[]` when it is config-only. A directory whose name holds one of `* ? [ ] { } \`, `!` or a control
character cannot be written as a glob, so its suite gets `paths: []` rather than a glob that would match the wrong files.

The output is compact single-line JSON with a fixed key order, and two runs over an unchanged tree are byte-identical.
Consumers must ignore keys they do not know: the contract grows by adding trailing keys (`paths` was the first).

Exit codes: `0` success, including the zero-suites case (`{"suites":[],"warnings":[]}`); `1` internal failure (`jq`
missing, the root unresolvable); `2` usage error (an unknown flag, or a missing or non-directory `--root`).

## Running tests

`j.test` builds the catalog once, shows it, parses your answer, runs the selection and relays the summary.

### The numbered list

`build-catalog.sh` runs discovery (or reads a saved discovery file through `--discovery-file <file>`) and prints the
catalog JSON; `build-catalog.sh --render <catalog.json>` prints that catalog as the numbered list. `j.test` prints the
rendering verbatim, including its prompt line. This repository's list is the worked example:

```
Choose which tests to run:
1. npm test (unit) [also covers: bats tests (unit), bats (integration)]
2. shellcheck (sast)

Notes:
- detected tool not listed in test-config.json: npm

Enter selection (comma-separated, or 'all' for all, or 'probe' to only check whether this machine is slow, or blank for 1 through 2):
```

Two entries, not one entry per bats file: `npm test` (which runs `bats tests/*.bats`, so it covers the bats suites) and
`shellcheck`. The `Notes:` block carries discovery's warnings. Blocks are separated by one blank line, and the `Not
runnable` and `Notes` blocks are omitted when empty. `name (type)` labels every entry, except that a name already ending
in ` (<type>)` is printed as is, so a config-only suite reads `semgrep (sast)` and not `semgrep (sast) (sast)`.

### The dedupe rule and `also covers`

Suites that would run the same thing are folded into one entry before numbering, so a "run all" never runs the same
tests twice:

1. The key is the exact `command` string. This repository's discovery reports both `bats:tests` and
   `config:bats:integration` as `bats tests/*.bats`.
2. **The npm alias.** `npm test` and `npm run <key>` are aliases for the body of that script in `package.json` (read
   with `jq`, never executed). For an npm suite the key is that script body when it is a non-empty string, otherwise its
   command. Here `scripts.test` is `bats tests/*.bats`, so `npm:test` shares a key with `bats:tests`; without this, an
   hour-long bats suite would run twice. A missing, unreadable or unparseable `package.json` just means no alias.
3. **The survivor** of a group is the first `npm` entry (the project's own declared entry point), else the first
   non-`config` entry, else the first `config` entry, "first" being `id` order. Everyone else is listed in the survivor's
   `also` array and rendered as `[also covers: ...]`. A group of one is not folded.
4. Scripts that call other scripts (`npm run other`) are not resolved further.

The catalog's `runnable` entries carry `n` (contiguous, `1..N`, in `id` order), `id`, `name`, `type`, `ecosystem`,
`command` and `also`. Unknown keys on discovery's suites, such as `paths`, are tolerated on input and not carried into
the catalog.

### A suite with no command

A suite whose command is empty (a config-only suite, ecosystem `config`) is never numbered, never executed and never
counted as pass or fail. It is listed under `Not runnable (listed only, cannot be selected):` with the reason
`no command declared`:

```
Not runnable (listed only, cannot be selected):
- semgrep (sast): no command declared
```

When no suite is runnable at all, the first block is `No runnable test suites found.`, there is no prompt line, and
`j.test` says so plainly and stops. It does not invent a command.

### The selection grammar

`parse-selection.sh <N> "<answer>"` validates the answer against `N`, the runnable count. On success it prints the chosen
numbers one per line, in the order given (exit 0). On failure it prints nothing to stdout and one message per problem to
stderr (exit 1), and nothing runs; `j.test` shows the messages and asks again until the answer is valid or you cancel.

| Answer | Result |
|---|---|
| blank or whitespace only | all suites, `1` through `N` |
| `all` (any case) | all suites; only valid alone (`all,2` is invalid) |
| `3,1` | suite 3, then suite 1: the order is kept exactly as given |
| `1, 3` | valid: whitespace around each entry is ignored |
| `1-3` | invalid: ranges are not supported; the message suggests `all` or an explicit list |
| `1,3,1` | invalid: a number may appear only once; a repeat is never silently deduplicated |
| `0`, `01`, `1.5`, `abc`, `1,,3` | invalid: each entry must be a positive integer without leading zeros |
| a number above `N` | invalid: out of range |

Every problem is reported, not just the first, and each message names the offending entry and the valid range, for
example `invalid selection '3': out of range, choose 1 through 2`. A usage error (a missing or non-positive `N`) exits 2.

### Running and the summary

`run-suites.sh --catalog <catalog.json> [--root <dir>] <n> [<n> ...]` runs the selected suites one at a time, in argument
order, each exactly once. Before anything runs it validates its input: an unreadable or invalid catalog, a number that is
malformed, repeated or not a runnable suite, no numbers, or an unknown flag print the cause to stderr and exit 2. A
half-run on a bad selection is worse than none.

For each suite it prints a header line `==> [i/total] <name> (<type>)` and runs the catalog's `command` as one shell
string from the project root. Standard input is `/dev/null`, so a suite that prompts cannot hang the run, and standard
output and error pass straight through, so a long suite shows progress. A failing suite (non-zero, including 127 for a
missing command) does not stop the run. It never runs a command that is not in the catalog.

After the last suite it prints the summary, one line per selected suite in run order:

```
Test Results
============
✓ npm test (unit)
✗ shellcheck (sast)

1 passed, 1 failed. Exit code: 1
```

| Exit code | Meaning |
|---|---|
| `0` | Every selected suite passed |
| `1` | At least one suite failed |
| `2` | Validation or usage error, nothing ran (also `jq` missing or the root unresolvable, so that `1` only ever means a suite failed) |
| `130` | Interrupted |

On an interrupt (SIGINT or SIGTERM) `run-suites.sh` stops the running suite's whole process group, starts no further
suite, prints the summary and exits 130. The suite that was running is listed `(interrupted)` and those never started
`(not run)`, and the last line reads `<P> passed, <F> failed, <U> not finished. Exit code: 130`.

The skill's own result is that exit code. After a `1`, `j.test` names the failed suites and offers to re-run only those
(with their catalog numbers) or stop. When you are done it removes its scratch catalog file.

### The slowness preflight

**In `j.test` the check is a step the user controls, not something the run does on its own.** Answering `probe` at the
prompt measures the machine and runs no suite. Choosing every suite (blank or `all`) measures first as well. The skill
passes `--no-probe` to `run-suites.sh`, so the run itself never measures a second time. A healthy result carries on. A
slow result stops and asks:

```
This machine is slow right now. What would you like to do?
1. Continue anyway
2. Cancel
3. Return to test selection
4. Change what counts as slow on this machine
5. Other (describe below)
```

(For `probe` alone, option 1 is left out: nothing is waiting to run.) **Change what counts as slow** saves a new
threshold with `skills/j-test/scripts/slowness-check.sh set-threshold <n|default>` and then judges the probe just made
against it with `slowness-check.sh reclassify`, without measuring again, so a machine that is simply slower than the
default 2.5 stops being flagged without another minute of probing. The saved value is one number in
`project/logs/slowness-threshold`: machine-local, git-ignored, never mirrored. The precedence, for the probe wherever it
is run, is `--threshold`, then `JENGA_SLOWNESS_THRESHOLD`, then that file, then 2.5. `slowness-check.sh` has four
subcommands (`probe`, `threshold`, `set-threshold`, `reclassify`; `--help` for the contract).

The rest of this section describes the probe itself, and the unattended preflight that `run-suites.sh` still runs for
callers that cannot ask anyone (the scope test gate, a direct call). A run that covers **every** runnable suite of the catalog (the `full` scope test policy, or `run-suites.sh` called without `--no-probe` — a `scoped` policy can no longer reach the whole catalog at all, see `E72_S08_T02`) starts with `scripts/slowness-probe.sh`. It runs one reference bats file (`tests/workflow-outputs.bats`, about a minute on a healthy machine) and compares its wall time with its CPU time (user + sys). On a healthy machine the two are close; when something outside the tests makes every process start wait (the case recorded in `project/rapports/problems/E77_S06_T11-wall-clock-timings-inflated-by-first-exec-latency.md`: a security agent authorising each `exec`), the file keeps its CPU time and its wall time grows ten times. **Wall above 2.5 times CPU classifies the machine as slow.**

The probe never changes which suites run or the exit code. It prints its result before the first suite; when the machine is slow it also collects diagnostics, and a note after the summary says that the wall-clock durations of that run are not a measure of the tests.

| Probe exit | Meaning |
|---|---|
| `0` | healthy, the reference file passed |
| `1` | the reference file failed (the ratio is still logged, and diagnosed when slow) |
| `2` | usage error |
| `3` | skipped: `bats` or the reference file is absent (a consumer install, a synthetic root); nothing measured or logged, and `run-suites.sh` prints nothing |
| `10` | slow |
| `130` | interrupted |

It is also run on its own: `bash scripts/slowness-probe.sh` (`--help` for the options; `--threshold`, `--probe-file`, `--exec-files`, `--log`, `--no-log`). Run it by hand when the machine starts to feel sluggish.

**What one run records.** One JSON line is appended to `project/logs/slowness-probe.jsonl` (machine-local, git-ignored, never mirrored): the wall and CPU time and their ratio, the uptime and load, the terminal start time (`$SHELL -i -l -c exit`), the cost of `bash -c :` idle and sampled while the reference file runs (`spawn_inflation`), the highest CPU of the security-agent processes (`wdav*`, `epsext`, `mdatp`) and the number of `git fsmonitor--daemon` processes. When the run is slow it adds the first-exec benchmark (`first_exec_ms` against `reexec_ms` over fresh scripts), the five busiest processes and an `indicators` list naming each measure that crossed its own threshold. Reading the history shows when the slowness returned and what the machine looked like then:

```bash
jq -c '{ts, ratio, uptime_days, terminal_start_s, first_exec_ms, security_agent_cpu_max, fsmonitor_daemons}' project/logs/slowness-probe.jsonl
```

**Turning it off or tuning it.** `JENGA_SLOWNESS_PROBE=0` skips it (a CI job where wall time is trustworthy and the extra minute is not wanted); `JENGA_SLOWNESS_THRESHOLD=<n>` or the saved machine-local value (above) changes the 2.5; it is also skipped inside a nested suite run (`JENGA_NESTED_SUITE_RUN` set). The probe only reads: it never changes a machine setting, and does not itself fix a slow machine. The suites it covers are `tests/slowness-probe.bats`.

## Scope mapping

`skills/j-test/scripts/map-scope.sh` answers one question: which discovered suites cover the files that changed. It is
the deterministic script the commit gate's scoped option calls (see "How a scoped run works" in the gate section below);
`j.test` itself does not use it. It reads a scope-map file, runs `git` and `discover-tests.sh`, and prints one JSON
object. It writes nothing to the repository and never runs a suite command or any project code.

### The change sources

At most one of these, default `--working`:

| Flag | Changed files |
|---|---|
| `--rev <commit>` | That commit against its first parent (a root commit against the empty tree) |
| `--range <a..b>` | Passed to `git diff` (`a..b` or `a...b`) |
| `--staged` | The index against `HEAD` |
| `--working` | Everything differing from `HEAD`: staged, unstaged and untracked-not-ignored files |

Other flags: `--root <dir>` (the project root), `--map <file>` (a scope-map file) and `--suites <file|->` (use this
discovery JSON, or standard input, instead of running discovery). A rename counts as a delete plus an add, so both names
count. `--working` diffs a throwaway copy of the index kept under `${TMPDIR:-/tmp}` and removed on every exit path, so
running it never writes to your repository's index.

### The scope map

The map is resolved first hit wins: `--map <file>`; else the flat key `commit_scope_map_file` in `test-config.json`
(see "Configuration"); else `templates/test-scope-map.json`, the root's own copy when it has one, otherwise the shipped
copy. The shipped map is a generic starting point:

| `source` glob | `tests` globs |
|---|---|
| `src/**/*.js` | `test/**/*.test.js`, `tests/**/*.test.js` |
| `lib/**/*.js` | `test/**/*.test.js` |
| `src/**/*.py` | `tests/test_*.py`, `tests/**/*_test.py` |
| `**/*.go` | `**/*_test.go` |
| `src/**/*.rs` | `tests/*.rs` |
| `**/*.sh` | `tests/**/*.bats` |

The format is `{"map_version":1,"rules":[{"source":<glob>,"tests":[<glob>,...]}]}`; `_comment` and unknown top-level keys
are ignored. **Rules are additive:** every rule whose `source` matches a changed file contributes, and there is no
first-match-wins, so a file matching several rules maps to the union of their `tests`. A project overrides the shipped
map by pointing `commit_scope_map_file` at its own file, not by editing the shipped copy. Note that the `**/*.sh` rule
maps a changed shell script to **every** `tests/**/*.bats` file: the shipped map is generic, and a project that wants
finer mapping supplies its own.

The glob dialect is shared with discovery's `paths`: root-relative, `/`-separated, matched against the whole path and
case-sensitive. `*` is any run of characters except `/`; `?` is one character except `/`; `**` is allowed only as a
complete path segment and matches zero or more segments; everything else is literal. **Negation is not supported:** a glob
beginning with `!` is a validation error, never matched literally. Also rejected are a leading `/` or `./`, a `..` or `.`
segment, an empty segment, any of `[ ] { } \`, a control character and `**` inside a segment.

### How changed files become suites

1. The changed names are the unique, sorted set from the chosen source.
2. The candidates are the files that exist in the working tree (tracked, or untracked and not ignored). Tests run
   against the working tree, so this is the set for every `--rev` and `--range` too.
3. A **test file** is a path some suite's `paths` matches or some rule's `tests` glob matches. For each changed file the
   files to resolve are the file itself when it exists and is a test file (editing a test runs it), plus, for every rule
   whose `source` matches it, every candidate matching that rule's `tests`.
4. A test file resolves to every suite whose non-empty `paths` matches it. When none does, it falls back by extension to
   the ecosystem and takes every suite of it whose `paths` is empty: `.js`, `.jsx`, `.ts`, `.tsx`, `.mjs` and `.cjs` go to
   `npm` (an npm script is opaque, so over-selecting is the safe direction). Other extensions have no fallback.
5. A changed file with at least one resolved suite is mapped; otherwise it is listed in `unmapped_files`.
6. Selected suites with an empty `command` cannot run: they are dropped with the warning
   `suite <id> has no runnable command; skipped`. Selected suites sharing an identical command collapse to the lowest
   `id`, which takes the union of their test files (discovery reports `config:bats:integration` with `bats:tests`'s
   command, and without this a run would execute it twice).

The output is one compact JSON object, byte-identical for identical input:

```json
{"mapped_suites":["bats:tests"],"mapped_tests":{"bats:tests":["tests/a.bats"]},"unmapped_files":["README.md"],"warnings":[]}
```

`mapped_suites` are the suite ids, sorted and unique; `mapped_tests` has one key per mapped suite whose value is the
sorted test files that put it there (this is what lets the commit gate narrow a run to files when the runner accepts file
arguments); `unmapped_files` and `warnings` are sorted arrays.

### Zero mapped is never silent

With a non-empty change set and no mapped suite, `warnings` contains `No tests found for the changed files` (plus
`No test suites discovered` when discovery returned none). The caller reads this to offer the full suite instead of
reporting a vacuous green run. An empty change set (for example `git commit --allow-empty`) gives empty arrays and the
single warning `No changed files`, and discovery is not run. Two further warnings name a rule by its 1-based index:
`rule <n> (<source>): <k> changed file(s) matched but no existing test file matched its tests globs` and
`rule <n> (<source>): test files matched but no discovered suite runs them`.

### Worked examples

These are real outputs of `map-scope.sh --rev <commit>` run over this repository with the shipped map, abridged.

**1. A test file is edited.** A commit that changed only `tests/commit-test-gate-mirror.bats`: the file is itself a test
file (`bats:tests`'s `paths` is `tests/*.bats`), so it maps to that suite alone.

```json
{"mapped_suites":["bats:tests"],"mapped_tests":{"bats:tests":["tests/commit-test-gate-mirror.bats"]},"unmapped_files":[],"warnings":[]}
```

**2. Only documentation or board files change.** A commit that changed `CLAUDE.md` and `README.md` matches no rule and
is no test file:

```json
{"mapped_suites":[],"unmapped_files":["CLAUDE.md","README.md"],"warnings":["No tests found for the changed files"]}
```

The gate treats this as "no test covers these changes", says so plainly, and offers the full suite instead (see "Zero
mapped, or a mapping error" in the gate section).

**3. A shell script is edited.** A commit that added `skills/j-test/scripts/run-suites.sh`, its bats suite, its fixture
JSON files and a plan document: the `**/*.sh` rule maps the script to every `tests/**/*.bats` file, which `bats:tests`'s
`paths` resolves to that one suite (`config:bats:integration` collapses into it by identical command, so only
`bats:tests` appears). The fixtures and the plan match no rule and are no test file, so they are listed under
`unmapped_files` while the commit still maps. `mapped_tests` held 136 files here; it is abridged below.

```json
{"mapped_suites":["bats:tests"],"mapped_tests":{"bats:tests":["tests/a.bats","..."]},"unmapped_files":["project/documentation/plans/E72_S02_T04-plan.md","tests/fixtures/j-test/run/all-pass.json","..."],"warnings":[]}
```

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Success, including zero mapped suites (read `warnings`) |
| `1` | Internal failure: `jq` or `git` missing, discovery failed or produced unusable output, root unresolvable |
| `2` | Usage error: an unknown flag, a missing argument, more than one change source, a non-directory `--root` |
| `3` | The scope map, the path configured for it, or the `--suites` input is missing, unreadable or invalid (stdout empty, a clear stderr message naming the file and, for a rule, its 1-based index) |
| `4` | Not a git repository, or an unknown revision |

Callers treat any non-zero exit as "offer the full suite".

## Configuration

Two flat keys of `project/configs/test-config.json` (the configs directory resolved by `scripts/resolve-root.sh`)
configure the scope mapper and the commit gate. They are two flat top-level strings, not a nested object, because the
configuration schema can express an editable key only as a scalar.

| Key | Values | Default | Meaning |
|---|---|---|---|
| `commit_prompt_default` | `""`, `skip`, `scoped`, `full` | `""` | The answer the `j.commit` test prompt assumes without asking. `""` means no recorded default: always ask |
| `commit_scope_map_file` | a relative path ending in `.json`: no leading `/` (no absolute path), no `..` segment, no backslash or newline | `templates/test-scope-map.json` | The scope map `map-scope.sh` reads |

**An absent key reads as its default.** A `test-config.json` written before these keys existed lacks both, and that is
not an error: an absent `commit_prompt_default` reads as `""` (always ask) and an absent `commit_scope_map_file` reads
the shipped `templates/test-scope-map.json`. New projects scaffolded by `j.init` carry both keys with those defaults.
A `commit_scope_map_file` that is present but unusable (not a string, absolute, containing a `..` segment, not ending in
`.json`) is a configuration error, not a silent fallback: `map-scope.sh` exits 3, and so does a configured file that does
not exist. A `commit_prompt_default` that is present but unusable is treated as `""` with a warning (see the gate section).

Edit both with `jenga config`, which is agentless (no model call) and validates the value against the key's descriptor,
`templates/config-descriptors/test-config.json`:

```bash
jenga config get test-config.commit_prompt_default
jenga config set test-config.commit_prompt_default scoped
jenga config set test-config.commit_scope_map_file config/my-scope-map.json
```

`jenga config set test-config.commit_prompt_default ""` returns to always asking. A value that fails the descriptor (an
absolute path or one with a `..` segment for the map file, which exits 4, or a word outside the four for the default) is
refused and the file is not changed. `jenga config get` on a key that is not in the file exits 3 with a message saying it is not set, and
`jenga config set` creates it. The usage and exit codes are in `project/configs/README.md`.

**`tools` stays read-only.** The `tools` array in the same file (one entry per test type: `unit`, `integration`, `e2e`,
`sast`, `vulnerability`, `performance`, `coverage`) is shown by `jenga config` but cannot be set with it. It is owned by
the tester agent's user-approval flow (`agents/tester.md`, Tool Stack Management). Discovery reads it only for the overlay
described in "Discovery".

### A project scope map

A project that wants a finer mapping than the shipped one writes its own file and points `commit_scope_map_file` at it.
It uses the same format as the shipped map: `map_version` set to `1` and a non-empty `rules` array, each rule exactly a
`source` glob and a non-empty `tests` array of globs, with no other keys in a rule and no negation:

```json
{
  "map_version": 1,
  "rules": [
    { "source": "lib/parser/**/*.js", "tests": ["test/parser/**/*.test.js"] },
    { "source": "lib/**/*.js", "tests": ["test/smoke.test.js"] }
  ]
}
```

Because rules are additive, a change to `lib/parser/a.js` maps to the union of both rules' tests.

The shipped map is a **generic starting point, not a recommendation**: its `**/*.sh` → `tests/**/*.bats` rule maps any
shell edit to every bats file in the project, which is almost never the mapping a real project wants. Overriding it is
how a project gets a scoped run that is actually scoped. Point `commit_scope_map_file` at your own file; never edit the
shipped copy, which would ship your project's policy to every consumer of the package.

A rule may carry **only** `source` and `tests`. Any other key — including a per-rule comment — is a validation error,
so a map's rationale has to live in its single top-level `_comment`.

#### `excluded_tests` — declaring a deliberate omission

An optional top-level `excluded_tests` array names each test file the map deliberately leaves out of every rule, with
a mandatory reason:

```json
{
  "map_version": 1,
  "excluded_tests": [
    { "file": "tests/slow-e2e.bats", "reason": "mutates the real deployment target; run it deliberately" }
  ],
  "rules": [ { "source": "lib/**/*.js", "tests": ["test/unit/**/*.test.js"] } ]
}
```

It exists for one purpose: **visibility**. A map-based omission is invisible by construction — the file is simply never
selected, nothing lands in the gate's `excluded_test_files`, and the reader sees only `selected N test file(s)` with no
way to tell "deliberately kept out" from "simply not mapped". With the declaration, `map-scope.sh` reports it as
`map_excluded_tests` and the gate prints `deliberately not selected by the scope map (NOT verified, and NOT a pass)`
and carries it in `--json` as `map_excluded_test_files`.

Three properties are worth knowing:

- **It subtracts nothing.** `map_version` 1 still has no negation; a declaration is a statement about an omission the
  rules already produce, not a way to remove a file the rules select. This is why `map_version` stays at `1`, and why
  enumerate-and-omit remains the mechanism that actually does the work.
- **A contradicted declaration is reported, never believed.** If some rule selects a declared file anyway, the file
  *is* in the run, so it is listed under `map_exclusion_conflicts` instead of `map_excluded_test_files`, and
  `map-scope.sh` warns. The gate can never claim a file was kept out while in fact running it.
- **`file` must be a literal path and `reason` must be non-empty.** A glob is a validation error, because the
  membership check against the selected files is exact. An empty reason is a validation error for the same purpose the
  baseline marker has one: nothing is kept out of a gate without saying why.

Every entry is sorted by `file`, and the key is **present in the output only when the map declares at least one**, so a
map that does not use it produces byte-identical output to before the key existed.

#### A declared omission only holds on the `scoped` path

A declaration is a statement about what the **scope map's rules** select, so it has force only where those rules decide
the run. **The rule the gate follows is one rule, not a list of paths:** a declared file this run *executes* is reported
as superseded, and a declared file this run *does not execute* is reported as kept out. Every declared file gets exactly
one of the two statements, never both and never neither.

`E72_S08_T02` rewrote this table. It had three rows and claimed "exactly one statement per run"; that held only while
every path either ran *all* the declared files (the escalation to the full catalog) or *none* of them. The bounded
default suite set is a fourth case the old table could not express — the map **was** consulted, so a declaration is in
hand, but the declared files **do not run** — and because the floor is configured independently of the scope map it can
name some declared files and not others, so "one statement per run" became **one statement per declared file**:

| When | What the gate prints | `map_excluded_test_files` | `map_exclusions_superseded` | Did the file run? |
|---|---|---|---|---|
| `scoped`, a suite maps (`effective_mode` `"scoped"`) | `deliberately not selected by the scope map (NOT verified, and NOT a pass):` + the reason | the file | `[]` | no |
| `scoped`, nothing maps → the **bounded default suite set** runs (`effective_mode` `"default-set"`, `fallback_reason` `"no-mapped-suites"`) — **the row `E72_S08_T02` added** | per declared file: `deliberately not selected ...` for the ones the floor does not run, and `the scope map's declared omission is NOT in force for the following: the bounded default suite set runs them, so they WILL RUN and WILL be verified:` for the ones it does | the ones the floor does **not** run | the ones it **does** | per file |
| policy `full` — the map is never consulted | nothing about the declaration | `[]` | `[]` | **yes** |
| `fallback_reason` `"no-commits"` — the map is never consulted either | nothing about the declaration | `[]` | `[]` | no: nothing runs at all (exit 3) |

**In this repository the floor runs none of the three declared files**, so row 2's partition is empty on one side:
`test_default_suite_set` names six suites and not one of them is
`tests/mirror-test-subject-invariant.bats`, `tests/mirror-permission-level-invariant.bats` or
`tests/mirror-staging-branch-push.bats`. The declaration is therefore back **in force** on the `no-mapped-suites` path,
`map_exclusions_superseded` is `[]` and `map_excluded_test_files` keeps all three — the **inverse** of the behaviour
before `E72_S08_T02`, where the full-catalog escalation ran them and so genuinely did supersede the declaration.

Two consequences worth stating plainly:

- **`map_excluded_test_files` never names a file the run executed, and `map_exclusions_superseded` never names one it
  did not.** The second half is the part that inverted: the gate claiming a file was "NOT verified" while executing it
  was the defect `E72_S07`'s fix round 3 removed (the same class as narrowing variant 2), and reporting a file as
  "WILL RUN and WILL be verified" when the floor does not run it would be that same false statement pointing the other
  way. The partition is what keeps both halves true for any configured floor, rather than a constant that happens to be
  right for this one.
- **Under policy `full` the map exclusion has no effect at all, and nothing is said about it.** The scope map is never
  read on a `full` run, so there is no declaration in hand to report; the declared file is simply part of the catalog
  and runs. That is not a false statement, but it *is* silent — if you rely on a declared omission to keep a hostile
  suite out of an automatic gate, a `full` policy does not give you that. Check `test_run_task` / `test_run_story` /
  `test_run_epic` before assuming it does. (`test_run_epic` now defaults to `none` — `E72_S08_T01` — so the
  default epic close consults no map because it runs nothing, not because it runs everything.)

  This is a **documented limitation, not a bug**: a `full` policy's contract is "run the whole catalog", and silently
  dropping a file from it would break that contract more seriously than running a declared omission does. If a suite
  must never run automatically under any policy, the map declaration is the wrong instrument — use the
  `# jenga:requires-baseline-permissions:` marker (see "Suites that cannot pass right now, and how they are excluded"),
  which is read on every path, or keep the suite out of discovery altogether.

  **After `E72_S08_T02` this gap is `full`-only.** It used to extend to both escalations, which reached the whole
  catalog from a `scoped` policy; neither exists now. `"no-commits"` runs nothing at all, and `"no-mapped-suites"` runs
  the bounded default suite set, which in this repository contains none of the declared files. So a `scoped` policy no
  longer executes a declared omission by accident — only an explicitly configured `full` policy does, or a floor that
  explicitly names one.

  **Which suites this gap is live for in this repository, named (2026-11-01).** Three files are declared omissions in
  `project/configs/test-scope-map.json`, and a `full` run executes all three:

  | Declared omission | What a `full` run drives |
  |---|---|
  | `tests/mirror-test-subject-invariant.bats` | ~2 h of runtime; mutates the real `.publicignore`, restored only in `teardown()` |
  | `tests/mirror-permission-level-invariant.bats` | the real `mirror.sh` end-to-end, with real `git push`es |
  | `tests/mirror-staging-branch-push.bats` | the same, including the `--force` flow |

  The two push-driving ones were added to `excluded_tests` on 2026-11-01 by user decision (`E72_S07_T04` fix round 4),
  with the `scoped`-only limit accepted as a known: the declaration makes a tester's repeated refusal to run them
  visible in the gate output instead of depending on a tester declining each time, and it does nothing at all under
  `full`. **Two changes have since shrunk this exposure without removing it.** `E72_S08_T01` re-tiered the epic policy
  default from `full` to `none`, and this repository's own `project/configs/test-config.json` now sets
  `test_run_epic: "none"`; `E72_S08_T02` removed both full-catalog escalations, so a `scoped` policy can no longer
  reach the whole catalog at all. What remains is that `full` stays an accepted value any project can set deliberately,
  and that a `test_default_suite_set` which explicitly named one of these files would run it (and would then be
  reported under `map_exclusions_superseded`, not as kept out).

### This project's own map

Jenga itself runs on `project/configs/test-scope-map.json` (`E72_S07_T03`), with
`commit_scope_map_file` pointing at it. Its shape is worth reading as a worked example, because two of its decisions
are the ones any real project has to make.

**It drops the shipped `**/*.sh` → `tests/**/*.bats` rule.** That one rule is what made a scoped gate select the whole
catalog for any shell edit. Measured on the `E28_S19` change set (31 files): 261 test files / 5666 cases under the
shipped map, **14** under this one. Every other shipped rule is kept — the JavaScript, Python, Go and Rust ones match
nothing here today but cost nothing and keep the map correct if such a suite is ever added.

**It has no catch-all, and that is a deliberate trade.** A change in an area no rule covers maps to zero suites, so the
gate runs the **bounded default suite set** with `fallback_reason: "no-mapped-suites"` and `effective_mode:
"default-set"` on stdout and in its JSON. The consequence is real but bounded: an uncovered story gets the floor, which
asserts something rather than nothing but asserts nothing *about* the change. It is always surfaced rather than silent.
Adding a rule is how a new area gets narrowed; re-adding a catch-all would undo the whole thing.

Until `E72_S08_T02` the consequence was the opposite and much worse: an uncovered story got the **whole catalog**, so
dropping the catch-all did not remove the full run, it relocated it from a mapped selection to a fallback — and 61
specific rules leave a larger uncovered surface than one blanket rule did, so it fired *more* often, not less.

### Documentation changes

Added by `E72_S08_T07` (folded in from the duplicate story `E72_S09`). Until then the map had **no rule covering a
documentation `.md` path**. Three rules touched `.md` — `templates/SCRUM_BOARD_SCHEMA.md`, `agents/*.md` and
`skills/**/SKILL.md` — and the documentation surfaces proper had none at all, so a documentation-only change matched
nothing, `map-scope.sh --files-from` returned `mapped_suites: []`, and `scoped` meant "the whole catalog" for every
docs-only story. `E72_S08_T06`'s bounded default set stops that run, but a floor is generic: it asserts nothing *about*
documentation. These rules are the positive mapping that does.

**The rules.** Per document, not one blanket `**/*.md`:

| `source` | `tests` | Why those suites |
|---|---|---|
| `project/documentation/public-mirror-content-parity.md` | `tests/workflow-publicignore.bats` | reads it as `PARITY_DOC` |
| `project/documentation/workflows.md` | `tests/workflow-doc-sections.bats` | extracts and validates the workflow example out of it |
| `project/documentation/skill-authoring.md` | `tests/smoke-test-error-table.bats`, `tests/check-public-playbook-steps.bats` | both read it off the real root |
| `project/documentation/preflight-checklists.md` | `tests/checklist-gating.bats` | parses its phase-to-skill and situation tables |
| `project/documentation/project-conventions.md` | `tests/prepare-task-commit-ref.bats`, `tests/conventions-precommit-timing.bats` | both grep its tables |
| `project/documentation/config-descriptors.md` | `tests/config-descriptors.bats` | checks every code is documented in it |
| `project/documentation/mcp-registration-decision.md` | `tests/register-mcp.bats` | asserts the decision it records |
| `project/documentation/atlassian-connect.md` | `tests/atlassian-connect.bats` | asserts its sections and tables |
| `project/documentation/distribution.md` | `tests/workflow-skill-registration.bats` | asserts its packaging-decision section |
| `CLAUDE.md` | `tests/break-signal.bats`, `tests/j-test-skill.bats`, `tests/smoke-test-skills.bats`, `tests/connect-skill-shell.bats`, `tests/conventions-skill.bats`, `tests/scope-test-gate-wiring.bats`, `tests/workflow-skill-docs.bats` | each greps its skill table or a named bullet |
| `README.md` | `tests/break-signal.bats`, `tests/j-test-skill.bats`, `tests/smoke-test-skills.bats`, `tests/workflow-skill-docs.bats` | same, for the public readme |
| `AGENTS.md` | `tests/break-signal.bats`, `tests/j-test-skill.bats`, `tests/smoke-test-skills.bats` | same, for the `/j-` slash-form table |
| `site/**/*.md` | `tests/site-dir-migration.bats`, `tests/pages-permalinks.bats`, `tests/connect-skill-shell.bats`, `tests/smoke-test-skills.bats` | front matter, the real permalink set, and `site/reference/skills.md` |
| `docs/**/*.md` | `tests/site-dir-migration.bats` | it asserts `docs/` does **not** exist, so creating one breaks it |
| `templates/PROBLEM_RAPPORT_TEMPLATE.md` | `tests/checklist-suggest.bats` | compares a scaffolded rapport against its sections |
| `templates/CHANGELOG_TEMPLATE.md` | `tests/npm-stage-approve-changelog.bats` | uses it as `TEMPLATE_SRC` |
| `templates/CRITICAL_ERROR_TABLE_TEMPLATE.md` | `tests/smoke-test-error-table.bats` | uses it as `TEMPLATE` |
| `project/board/**/*.md` | `tests/validate-board-yaml.bats` | the one suite that runs `scripts/validate-board.sh` over the real board |

**How the membership was established, and why that matters.** By a recorded grep over `tests/`, not from examples
(`E72_S08_T07` AC3). "Mentions a `.md` path" is useless as a selector: 177 of 271 suites do, because most build a
scratch `.md` under `$BATS_TEST_TMPDIR`. The discriminator used instead is whether the suite **reads a document off
the real repository root** — `"$REPO_ROOT"/<doc>` — rather than out of a fixture tree. Only suites that do are named
above. Suites that look like documentation suites and are not include `tests/workflow-check-doc-refs.bats`,
`tests/strategy-visibility.bats`, `tests/strategy-path-resolver.bats`, `tests/mirror-never-public-refs.bats`,
`tests/check-staged-hardcoded-paths.bats`, `tests/help-twin-only-listing.bats` and `tests/copilot-skill-list.bats`:
each builds a synthetic doc tree and asserts a *script's* behaviour, so editing a real document cannot change its
result. Mapping them would inflate every docs gate while verifying nothing about the change.

**Per document, deliberately, not one `**/*.md` rule.** Same reason the shared scripts under `scripts/` are named
individually rather than via `scripts/*.sh`: so adding a document does not silently inherit another's test set. A
blanket rule would also be the `.md` analogue of the `**/*.sh` catch-all this map dropped — every documentation edit
would select every documentation suite, which is the shape `E72_S07_T03` removed rather than a narrowing of it.

**The no-match outcome.** A documentation path no rule names matches nothing, exactly like any other uncovered area,
and falls through to the bounded default suite set (`E72_S08_T06`) — never to a pass that ran nothing, and never
silently: `map-scope.sh` lists it under `unmapped_files` and warns `No tests found for the changed files`. Adding a
rule to the table above is how a new document gets narrowed. One case is deliberate rather than pending:
`project/documentation/test-runner.md` — this page — gets **no rule**, because no suite asserts its *content*
(`tests/scope-test-gate.bats` only names it in a comment), so there is nothing honest to map it to.

**Three surfaces already had a rule and were left alone**, recorded here so the gap is not mistaken for coverage. The
sweep found further suites reading them off the real root, but each already resolves through a rule, so the gap is
membership rather than absence:

- `agents/*.md` — also read by `tests/commit-test-gate-skill.bats`, `tests/config-descriptors.bats`,
  `tests/tools-registry-e2e.bats` and `tests/commit-test-gate-mirror.bats`. The last is one of the four known-red
  failures `E72_S07_T04` records, so adding it would feed known redness into every agents-doc gate. That is a
  decision, not a drive-by edit.
- `templates/SCRUM_BOARD_SCHEMA.md` — also read by `tests/resolve-root.bats` and `tests/reconcile-ladder-statuses.bats`.
- `skills/**/SKILL.md` — covers `SKILL.md` only. Other skill `.md` assets have no rule, though
  `tests/digitalocean-descriptor.bats` asserts `skills/j-publish/adapters/droplet.md` and its two mirror copies. That
  belongs to the skill-asset rule family rather than this one.

**The `E88_S03` reproduction**, measured read-only with `map-scope.sh --files-from` against a single-bats-suite
discovery. Its change set is two Markdown files,
`project/board/tasks/E88_S03_T02_publicignore-test-updates.md` and
`project/documentation/public-mirror-content-parity.md`
(`project/rapports/problems/E88_S03_T03-npm-channel-criterion-not-documented.md`):

| | selection |
|---|---|
| before | `mapped_suites: []` → full-catalog fallback, 271 test files |
| after | 2 test files, narrowed to `bats 'tests/validate-board-yaml.bats' 'tests/workflow-publicignore.bats'` |

A strict subset of the catalog, at the real end of the chain — the command `narrow-suites.sh` produces, not just the
mapped set. `tests/project-scope-map.bats` pins all of it, including a mutation case that strips every `.md` rule from
a copy of the map and asserts the selection then goes to zero, which is what establishes that the mapping is **data in
the map** rather than an extension list inside a script (`E72_S08_T07` AC4).

### Keeping a hostile suite out of an automatic gate

Three test files in this repository are kept out of scoped selection this way, each declared in
`project/configs/test-scope-map.json`'s `excluded_tests`: `tests/mirror-test-subject-invariant.bats` (below) and the
two push-driving suites in the subsection after it. The mechanism is identical for all three — removed from every
rule, then declared — and so is its limit: it holds only on the `scoped` path.

`tests/mirror-test-subject-invariant.bats` is excluded from scoped selection — and the map **declares** that omission
in its `excluded_tests`, so the gate says so out loud rather than leaving a silent absence (see "`excluded_tests` —
declaring a deliberate omission" above). The reasons are specific rather than a general dislike of slow tests:

- **Runtime.** It runs the whole shipping bats suite *inside* itself — about 20 minutes per real-push case, 7 such
  cases. The 2026-10-16 incident measured 2+ hours with no progress.
- **Side effects on the tree it is validating.** It mutates the real `.publicignore` and restores it only in
  `teardown()`, so a killed run leaves the project's blocklist modified.

Neither property belongs in a gate that runs automatically at every story close.

**How the exclusion is written, and why it looks verbose.** `map_version: 1` has **no negation** — a glob beginning
with `!` is a validation error, not a way to subtract a file. The only way a file is not selected is for no rule's
`tests` glob to match it. So the mirror rule **enumerates its seven test files as literal paths** rather than writing
the obvious `tests/mirror-*.bats`, which would match the excluded file too. The exclusion is therefore auditable by
reading the map: the file is simply absent from it.

**And it is auditable from the gate output, not only from the map.** The enumeration alone leaves a reader of the gate
unable to distinguish this deliberate omission from a file that merely was not mapped, which is what `excluded_tests`
fixes. `tests/project-scope-map.bats` mutation-tests both halves: replacing the enumeration with `tests/mirror-*.bats`
still selects the file (proving the enumeration is load-bearing) *and* flips the declaration to `mapped: true` with a
warning (proving the declaration never quietly rescues it).

**The second gap: the exclusion only holds where the map's rules decide the run.** A declared omission is a statement
about what the map's *rules* select, so it has no force elsewhere. Under policy `full`,
`tests/mirror-test-subject-invariant.bats` **runs** — with its 2+ hours and its `.publicignore` mutation — and the gate
says nothing about the declaration, because the map was never consulted.

**`E72_S08_T02` narrowed this gap to `full` alone.** It used to extend to both full-catalog escalations, which a
`scoped` policy could reach. Now `"no-commits"` runs nothing (exit 3) and `"no-mapped-suites"` runs the bounded default
suite set, which does not contain this file — so on that path the declaration is **in force**, the gate reports it under
`map_excluded_test_files` as deliberately not selected, and `map_exclusions_superseded` is `[]`. The only way the floor
could run it is a `test_default_suite_set` that explicitly named it, which would then be reported as superseded rather
than as kept out. The full four-case table is under "A declared omission only holds on the `scoped` path" above.

`test_run_epic` now defaults to `none` (`E72_S08_T01`), so the default epic close runs nothing at all. Still, do not
treat the map declaration as a guarantee that a hostile suite never runs automatically: it is a visibility mechanism
for the paths where the map decides, and the marker below is the instrument that holds on every path.

**The gap this does not close.** `map-scope.sh` also resolves "a changed file that is itself a test file" to its own
suite — editing a test runs it. So **editing `tests/mirror-test-subject-invariant.bats` still selects it**, and no map
can prevent that. That case belongs to `E77_S02`'s in-file `# jenga:manual-only:` marker, which excludes a file from
every automated run regardless of what the map says. The division of ownership is deliberate:

| Mechanism | Owns |
|---|---|
| The project scope map (`E72_S07_T03`) | which test files a **scoped** gate selects for a given change |
| `E77_S02`'s manual-only marker | "never run this file automatically, in any run, including a change to the file itself" |

There is deliberately **no second exclusion path** for runtime: two mechanisms for "do not run this automatically" is
the outcome to avoid.

**Running it deliberately.** One documented command, which the exclusion does not affect:

```bash
bats tests/mirror-test-subject-invariant.bats
```

#### The two push-driving suites (added 2026-11-01, `E72_S07_T04` fix round 4)

By user decision, `tests/mirror-permission-level-invariant.bats` and `tests/mirror-staging-branch-push.bats` are now
omitted and declared the same way. Both were enumerated in the mirror family until then — the first additionally in
the `scripts/jenga-permission-level-switch.sh` and `templates/permission-levels/*.json` rules — and removing them from
all five places is what excludes them; the declaration only makes it visible.

**Why they cannot be carried by an automatic gate.** Each drives the real `skills/j-mirror-public/scripts/mirror.sh`
end-to-end and executes real `git push`es, which is the only way to test "does a real push get refused" and "where
does a real push land"; `mirror-staging-branch-push.bats` is the only suite that exercises `mirror.sh`'s `--force`
flow against a real bare remote at all. The push destination is a freshly created **local bare** remote via
`MIRROR_PUBLIC_URL_OVERRIDE` and the real `https://github.com/samwelmunga/jenga-npm` URL is never passed — so the
hazard is **not** that a gate publishes to GitHub. It is that the gate would drive the real outward-push pipeline over
a working tree `mirror.sh` rsyncs rather than reading from `git HEAD`, with containment resting entirely on
`MIRROR_PUBLIC_URL_OVERRIDE` and `MIRROR_WORKTREE_PATH_OVERRIDE` being set correctly on every invocation, leaving
scratch worktrees and marker tags behind if killed. Both also carry
`# jenga:requires-baseline-permissions:`, so whether they run or skip depends on ambient session state — a gate result
that flips between "verified" and "skipped" for reasons unrelated to the change under test. Operationally, the tester
declined to run them in every verification round of `E72_S07` and recorded them as **unverified — never as passed**.
Each suite's full reason, and its one documented deliberate command, is in the map's `excluded_tests` entry.

**The limit, stated plainly, because it is the known this decision was taken with.** A map declaration holds only where
the map's rules decide the run. Under policy `full` these two suites **run**, with their real pushes, and the gate says
nothing about the declaration at all because the map is never consulted. `E72_S08_T02` removed the two full-catalog
escalations, so a `scoped` policy no longer reaches them: on `"no-mapped-suites"` the bounded default suite set runs,
and it contains neither file. See the four-case table under "A declared omission only holds on the `scoped` path", which
names all three declared omissions and records what `E72_S08_T01`'s re-tiering of the epic default and `T02`'s removal
of the escalations each shrank.

**Second limit: a change to the test file itself is reported as a conflict, not an exclusion.** The
changed-file-is-a-test-file rule applies to these two exactly as it does to the invariant suite. Measured read-only on
2026-11-01 over `--range 450339d2..HEAD` — a range that includes `411c2f71`, which added the baseline marker to all
three files — the selection is 26 test files and `map-scope.sh` reports all three declarations with `mapped: true`,
each with the warning `scope map declares <file> in excluded_tests but a rule selects it; it is NOT excluded`, so the
gate lists them under `map_exclusion_conflicts` rather than claiming they were kept out. That is the honest outcome
rather than a defect — the declaration never rescues a file the run executes — but it means **editing one of these
three files still selects it**, and only `E77_S02`'s in-file `# jenga:manual-only:` marker closes that.

**The bar for excluding another suite from the map.** The suite must be slow enough or side-effecting enough that an
automatic gate cannot carry it, the reason must be recorded in the map's `excluded_tests` entry (and, for context,
its `_comment`), and there must be a documented command to run it deliberately. "It fails sometimes" is not a reason to exclude — that is a defect to fix. A suite
that fails on a condition it cannot control is a different mechanism again: see "Suites that cannot pass right now".

### Suite granularity, and why a project map alone is not enough

Writing a precise project map narrows **which test files are resolved**. On its own it does not narrow **what runs**,
and the difference matters enough to state plainly.

Discovery emits one bats suite **per directory, not per file** (see "What it detects"). A project whose tests all live
in `tests/` therefore has a single suite whose command is `bats tests/*.bats`. The scope gate used to filter the suite
*list* to the mapped ids and then run each survivor's command unchanged — so a filtered list of one suite still ran the
whole directory. Measured on this repository on 2026-11-01: a change set resolved to 11 test files under a targeted map
and still executed all 261 files / 5666 cases. `test_run_story: scoped` and `test_run_epic: full` were operationally
identical, and one unrelated red assertion anywhere failed every story's closing gate.

What closes the gap is `skills/j-test/scripts/narrow-suites.sh`, which turns the resolved file list into the command:

- **In a `scoped` run** the candidate files are `map-scope.sh`'s `mapped_tests` — the narrowing hook its output has
  always carried for this purpose. A bats suite's command becomes `bats <those files>`, so the run is as narrow as the
  map is precise. With the same change set and a targeted map the executed command went from 261 files to 11.
- **In a `full` run** there is nothing to narrow, by definition. `narrow-suites.sh` only excludes there (next section),
  and with nothing to exclude it is a byte-for-byte no-op, so a full run behaves exactly as it did before.

A command is rewritten **only** when it is a bare `bats` invocation with no shell metacharacter. Anything else — an
opaque `npm` script, a `pytest` or `go` invocation, a command with a pipe — is left exactly as it is and runs whole,
which is the safe direction. The gate reports those under `not_narrowable` rather than guessing at an argument form.

#### The opaque `npm` entry point

`build-catalog.sh` folds suites that would run the same thing, and for an `npm` suite it keys on the **body of that
script read from `package.json`** — here `scripts.test` is `bats tests/*.bats`, so `npm test` folds onto `bats:tests`
and a run-all does not execute the hour-long bats suite twice. Narrowing collides with that fold in two different
ways, and both needed fixing (full reasoning, measurements and the options weighed:
`project/documentation/scope-gate-npm-fold-double-execution.md`).

- **When the body *is* byte-equal to a bats suite's command.** The npm entry is rewritten to the *same* narrowed
  command. On its own that is not enough to keep them folded, because the fold key is the `package.json` body, which
  narrowing never rewrites — so the keys diverged the moment the bats command moved and the group split into two
  entries carrying *byte-identical* commands. `run-suites.sh` runs each numbered entry and never compares commands, so
  a full gate under any exclusion ran the whole narrowed selection **twice**. `build-catalog.sh` therefore folds a
  second time on the final command (its deduplication **rule 5**), which makes two identical commands impossible to
  number separately whatever produced them. It is the identity whenever no two commands coincide, so every catalog
  built from an un-narrowed discovery is unaffected.
- **When the body is *not* byte-equal** — `bats --tap tests/*.bats`, `bats -r tests`, `npm run test:all`, a
  `scripts/test.sh` wrapper — the twin rewrite declines, the command stays `npm test`, and that still expands to the
  whole test directory **including a file an exclusion just removed**. That is not a runtime cost but a false
  statement: the excluded file runs, fails for the baseline reason it was excluded over, and the failure is attributed
  to a suite the reader was told had been narrowed. So whenever an exclusion has actually fired, an `npm` suite the
  twin rule could not cover is **set to not-runnable**: never numbered, never executed, never counted as a pass or a
  fail. It is named on stdout (`not run (NOT verified) because the suite cannot honour the exclusion:`) and in the
  JSON's `disabled_suites`, so it is never a silent drop, and no coverage is lost where a narrowable twin exists
  because that twin runs the same files.

Two consequences of the second rule are accepted deliberately. The `npm` entry leaves the picker while an exclusion is
in force, so a reader loses the `npm test` label; and a project whose **only** suite is an opaque `npm test` gets
exit 3 under an exclusion. Exit 3 means "nothing was verified", which is the honest answer for an entry point that
cannot honour a file-level exclusion — and never a pass. Nothing is disabled when no exclusion fired: a pure `scoped`
narrowing claims nothing about files an opaque suite might additionally run, so running more there is wasteful rather
than wrong.

### Suites that cannot pass right now, and how they are excluded

Some suites fail for a reason that has nothing to do with the change under test. The case this mechanism was built for:
three suites in this repository drive a **real mirror push**, which `mirror.sh`'s `check_permission_level_invariant`
correctly refuses while `.claude/settings.json` or `.agents/settings.json` sit off the level-2 (Guarded) baseline — the
state `/jenga-permission-level` leaves behind during an elevated session. On 2026-10-22 that cost 19 failed assertions
and made every story's closing gate unpassable.

`skills/j-test/scripts/baseline-permissions.sh` is the **sole decider** of both halves of this:

- **The precondition.** `permissions.deny` and `autoMode.allow` of both settings files, compared (order-insensitively)
  against `templates/permission-levels/level-2-guarded.json`. This is deliberately the same comparison the code under
  test performs, and deliberately **not** `.jenga-permission-level.json`'s `session_level`, which goes stale in both
  directions — a stale `2` over loosened files would false-pass, a stale `5` after a restore would false-fail. It is
  also not a whole-file diff: `settings.json` carries `defaultMode`, `env` and `hooks`, which change for unrelated
  legitimate reasons. An absent settings file is a harmless skip; a present-but-unparseable one fails closed.
- **Which files need it.** An in-file marker in the first 40 lines, with a mandatory reason:

  ```text
  # jenga:requires-baseline-permissions: <why this suite needs the baseline>
  ```

  A marker with an empty reason is an error (exit 2), so a suite can never be quietly excluded without saying why. The
  marker lives in the file rather than in `test-config.json` for the same reason `E77_S02`'s manual-only marker does:
  `test-config.json` ships publicly, and a list entry would publish the name of a blocklisted test file.

**A skip is never reported as a pass.** This is the property that matters most, because a gate that goes green by
skipping what would have failed is worse than the honest failure it replaced:

- every excluded file is named on stdout with its reason, and listed in the JSON's `excluded_test_files` alongside
  `exclusion_reason`;
- an excluded file never enters the `passed` tally, which still comes from `run-suites.sh`'s own summary;
- if exclusion empties every selected suite, the gate exits **3** ("nothing was verified"), never 0, and nothing is
  substituted for what the exclusion removed: there is no full catalog for a `scoped` run to reach any more
  (`E72_S08_T02`), and the bounded default suite set answers "no rule covered this change", never "what did match was
  all excluded" — substituting there would silently run around the exclusion instead of reporting it. The same holds
  when the selected suites leave the catalog with no runnable entry at all, which is what happens if the only mapped
  suite was an opaque `npm` one that had to be disabled (see "The opaque `npm` entry point" above);
- a suite disabled because it could not honour the exclusion is named on stdout and in `disabled_suites`, and is
  absent from `suites` and from the pass/fail tally, so it can never read as a pass either.

The suites also skip on their own, through the shared `require_baseline_permissions` helper in
`tests/helpers/assertions.bash`, which keeps a hand-run `bats tests/mirror-*.bats` honest. **The gate never relies on
that**: `run-suites.sh` keys strictly on exit status and a bats `skip` exits 0, so a suite-only skip would reach the
gate as a pass. The gate's own exclusion is what makes the verdict truthful.

Only the cases that actually need ambient baseline state are guarded. In `tests/mirror-permission-level-invariant.bats`
the eight cases that build their own elevated fixture keep running — they are the coverage proving the guard refuses a
bad push, and skipping them would hide the regression class the suite exists for.

**The bar for marking another suite.** The condition must be one the suite cannot control, must be detectable by a
script rather than inferred, and must be stated in the marker's reason. "This test is flaky" and "this test is slow"
are not it: flakiness is a defect to fix, and runtime is `E77_S02`'s manual-only classification, a separate mechanism
with a separate marker.

## The `j.commit` test gate

### What it is, and where it sits

The test gate asks, before a commit is made, whether to run tests, runs them if the user chose to, and decides from the
result whether the commit may go on. It is **step 3.5** of normal-mode `j.commit` (`skills/j-commit/SKILL.md`):

1. reconcile, then doc-sync, then the user-action prerequisites check (steps 1-3);
2. **the test gate (step 3.5)**;
3. the pre-commit checklist gate (step 4), always the last step before the commit command;
4. the commit (step 5).

It sits after step 3 because the reconcile in step 1 can merge orphaned worktrees, so the set of changed files is only
final after step 3. It sits before step 4 because tests can run for a long time, and step 4's situation marker (written
immediately before its first checklist `check`) must never be open across them. The test gate writes **no** situation
marker, and a halt leaves none behind. No existing step was renumbered.

What the gate does not cover:

- **`--inline` mode** (and `JENGA_COMMIT_INLINE=1`) is a non-interactive caller: it never prompts and never runs tests.
  Its own step 3.5 resolves with `--inline --caller noninteractive`, prints `Tests skipped: <reason>` and logs the skip.
- **The `chore(self-sync)` commit** that `j.dev-done` makes after `/self-sync` is not gated. It records generated
  mirror output and `/self-sync`'s own board transitions, not work to validate; the gate already ran, or halted, inside
  the `/commit` of `j.dev-done`'s first step.

All deterministic logic lives in three scripts under `skills/j-commit/scripts/`; `SKILL.md` only relays their output
and holds the conversation. Answers are parsed by `test-gate-decide.sh`, never by the model, and the proceed/halt
decision is a script table, not model judgment.

### Configuration

Two flat keys of `test-config.json` (in the configs directory resolved by `scripts/resolve-root.sh`):

| Key | Values | Default | Meaning |
|---|---|---|---|
| `commit_prompt_default` | `""`, `skip`, `scoped`, `full` | `""` | The remembered choice. `""` means always ask. `skip`, `scoped` or `full` is applied without asking. |
| `commit_scope_map_file` | a root-relative path ending in `.json` | `templates/test-scope-map.json` | The scope map `map-scope.sh` uses to map changed files to test suites. |

**An absent key reads as its default.** Existing consumer `test-config.json` files lack both keys, so a missing key, a
missing file, a missing configs directory and a JSON `null` all behave as the default (`""` and
`templates/test-scope-map.json`) and are not errors. A `commit_prompt_default` that is present but unusable (any other
string, a number, a boolean, an object or an array, or a file that is not a readable JSON object) is also treated as
`""` (ask), and `test-gate-decide.sh resolve` reports a warning that the skill shows to the user.

Set them with `jenga config` (agentless, no model call):

```bash
jenga config set test-config.commit_prompt_default scoped
jenga config set test-config.commit_scope_map_file templates/test-scope-map.json
jenga config get test-config.commit_prompt_default
```

`jenga config set test-config.commit_prompt_default ""` returns to always asking. The gate itself never writes
`test-config.json`: no choice made at a prompt is remembered (see "The failure contract" below for the one place this
matters most).

**Per-invocation override.** `j.commit --tests <ask|skip|scoped|full>` replaces the recorded default for that one
invocation:

| `--tests` | Effect |
|---|---|
| `ask` | Show the prompt, even when a default is recorded (the prompt then names it, see below) |
| `skip` | Skip, without asking |
| `scoped`, `full` | Run that option, without asking |

A value outside those four is rejected (`resolve` exits 2) for every caller, so a typo is never silently swallowed, and
nothing is committed. `j.lgtm` and `j.dev-done` forward `--tests` to `j.commit` unchanged.

**Resolution order** (`test-gate-decide.sh resolve`, first match wins):

1. a non-interactive caller: skip (see "The non-interactive contract"); `--tests` and the recorded default are ignored;
2. interactive with `--tests`: `ask` prompts, `skip` skips, `scoped`/`full` run, reason `per-invocation override`;
3. interactive without `--tests`: `""` prompts (reason `no recorded default`), `skip` skips, `scoped`/`full` run
   (reason `recorded default`).

A recorded default therefore means the user is **not asked**: the skill prints one line naming the default or override
that applies and how to see the prompt instead (`--tests ask`). Only `--tests ask` with a recorded default shows the
prompt, and then its last line carries the `(recorded default: X)` notation.

### The prompt and the three options

When the prompt is shown it is exactly (output of `test-gate-decide.sh prompt`):

```
Run tests before committing?
1. Test covering committed scope (scoped run)
2. Run j.test (full suite)
3. Skip tests
Enter selection (1-3), or blank to skip:
```

With a recorded default X (`prompt --default X`) the last line is instead:

```
Enter selection (1-3), 'default' or blank for the recorded default (X):
```

Answer rules (`test-gate-decide.sh answer <raw> [--default X]`): the answer is trimmed and compared case-insensitively.

| Answer | Result |
|---|---|
| `1` or `scoped` | scoped |
| `2` or `full` | full |
| `3` or `skip` | skip |
| blank | X when a default is recorded, otherwise skip |
| `default` | X when a default is recorded; **invalid** with no recorded default |
| anything else (`1,2`, `4`, `0`, `all`, `1 2`) | invalid: the prompt is asked again and nothing runs |

Cancelling the prompt halts the commit.

The options:

1. **Scoped.** Runs only the tests covering what this commit will record (next section).
2. **Full.** Runs every runnable suite of the catalog, in catalog order, through `skills/j-test/scripts/run-suites.sh`,
   with the same pass/fail summary as `j.test`. A catalog with no runnable suite runs nothing, prints
   `No runnable test suites were found; no tests were run.` and yields the result `unavailable`.
3. **Skip.** Runs nothing. The output says tests were skipped by choice, never "passed". The commit proceeds to the
   pre-commit gate.

### How a scoped run works

`test-gate-scoped.sh` builds a plan and runs no suite; `test-gate-run.sh scoped --plan <plan.json>` runs it.

- **Changed files.** `--staged` when the index is non-empty (exactly what `git commit` will record), otherwise
  `--working` (the work is about to be staged). The source used is reported as `source` in the plan.
- **One discovery run.** `discover-tests.sh` runs exactly once (about 25-35 seconds on a large tree) and that one file
  feeds both `map-scope.sh --suites` and `build-catalog.sh --discovery-file`.
- **Mapping.** `map-scope.sh` maps the changed files to suites and test files using the scope map named by
  `commit_scope_map_file`.
- **Derived catalog.** The plan carries a derived catalog whose `runnable` list holds only the selected entries, with
  their original numbers. They run through `run-suites.sh --catalog`, not as ad-hoc commands.
- **Narrowing.** When every mapped suite landing on a catalog entry is a `bats` suite whose command starts `bats `, the
  entry's command becomes `bats '<file>' ...` over the mapped test files; likewise `pytest`. Every other ecosystem
  (npm scripts, go, cargo, shellcheck, and any mixed group) runs **whole**, because an npm script is opaque and
  running more is the safe direction. Narrowing exists because a whole-suite "scoped" run is useless where one bats
  suite takes over an hour: on this repository a scoped run that ran whole suites would be the full hour.

### Zero mapped, or a mapping error

If the plan's `status` is `zero` (no test covers the changed files, or every mapped suite has no runnable catalog
entry) or `error` (`map-scope.sh` exited non-zero, or discovery or catalog building failed), or the runner refuses the
plan, the skill says plainly that no test was run and that this is **not a pass**. It then shows the fallback prompt
(`test-gate-decide.sh fallback-prompt --reason "<the plan's message>"`): the reason line first, then

```
What would you like to do?
1. Run j.test (full suite)
2. Skip tests
```

`fallback-answer` parses it: `1` or `full` runs the full suite, `2` or `skip` or blank skips, anything else asks again.
The outcome is logged as a `fallback` event. A scoped run that executed nothing is never reported as green.

### The failure contract

`test-gate-run.sh` ends its stdout with `TEST_GATE_RESULT=<result>` and `TEST_GATE_FAILED=<names joined by ';'>`. The
result word comes from `run-suites.sh`'s exit code: 0 `passed`; 1 `failed`; 130 `interrupted`; any other (a refused
selection, a catalog that cannot be built) `error`; and, for a full run with no runnable suite, `unavailable`.
`failed` with no parsable name reports `unknown suite`, never an empty list.

For `failed` and `error` the user is shown a numbered choice (`test-gate-decide.sh failure-prompt`):

```
Tests failed: <names>
What would you like to do?
1. Fix first (nothing is committed)
2. Commit anyway (the failure is logged; the next commit is gated again)
3. Abort the commit (nothing is committed)
```

For `error` the first line reads `Tests could not be run: <names>`.

`test-gate-decide.sh directive <result> [--choice <fix|anyway|abort>]` maps every case to `GATE=PROCEED` (exit 0) or
`GATE=HALT` (exit 1). The table below is that script's output for each combination. "Logged" lists the
`commit_test_gate` events the skill appends (the `--action` values, see "The event").

| Result | Choice | Gate | Logged |
|---|---|---|---|
| `passed` | any | PROCEED | `passed` |
| `skipped` | any | PROCEED | `skip` (the skip path goes straight to the pre-commit gate and never calls `directive`) |
| `unavailable` | any | PROCEED (the skill says nothing ran; never a pass) | `unavailable` |
| `failed` | `fix` | HALT | `failed`, then `halt` |
| `failed` | `anyway` | PROCEED (an override) | `failed`, then `override` |
| `failed` | `abort` | HALT | `failed`, then `halt` |
| `failed` | none | HALT | `failed`, then `halt` |
| `error` | `fix` | HALT | `error`, then `halt` |
| `error` | `anyway` | PROCEED (an override) | `error`, then `override` |
| `error` | `abort` | HALT | `error`, then `halt` |
| `error` | none | HALT | `error`, then `halt` |
| `interrupted` | any | HALT, with no failure prompt (the user stopped it) | `interrupted`, then `halt` |

An unknown result or choice makes `directive` exit 2, which a caller treats as do not proceed, so a typo can never
commit. "None" is deliberate: a caller that forgot to ask must not commit.

Rules of the failure prompt:

- **There is no default.** A blank answer is invalid (`failure-answer` exits 1) and the prompt is asked again, so an
  unanswered prompt can never turn into a commit. Cancelling halts.
- **The choice is never persisted.** The next commit gates again from scratch, and `test-config.json` is not written
  (`test-gate-run.sh log` writes nothing but `events.json`).
- **Fix first** tells the user which suites failed and that `j.commit` can be run again after the fix; nothing is
  committed.
- **Commit anyway** proceeds to the pre-commit gate and the commit, and is logged as an override with the failed suites.

**On a halt**, the skill prints the line `TEST_GATE=HALT` on its own line and then
`Commit halted at the test gate: nothing was committed.`, logs `halt`, and stops the whole of `j.commit`: nothing is
staged, committed or marked, and no later step runs.

**Non-zero exit from the decision script.** Any non-zero exit from a `test-gate-decide.sh` call other than the answer
parsers' exit 1 (re-ask) and `directive`'s exit 1 (a halt) means do not proceed: a usage error, or `jq` missing
(`resolve` requires it). This halts every commit, including with `--tests skip`, because `resolve` is what decides
whether the gate skips. A machine without `jq` cannot commit through `j.commit` until it is installed.

### The non-interactive contract

A non-interactive caller **never prompts and never runs tests, whatever the recorded default or `--tests` says.** The
gate skips with an explicit output line (`Tests skipped: non-interactive caller: tests are not run on an agent's
behalf`), appends a `commit_test_gate` event with action `skip` and caller `noninteractive`, and the commit proceeds.
`resolve` ignores both the recorded default and a valid `--tests` for such callers (an invalid `--tests` or `--caller`
value is still rejected with exit 2).

`test-gate-decide.sh resolve` treats a caller as non-interactive on any of four triggers:

1. `--caller noninteractive`;
2. `--inline`;
3. the environment variable `JENGA_COMMIT_INLINE=1`;
4. the environment variable `JENGA_COMMIT_NONINTERACTIVE=1` (exactly the value `1`).

The first is how a sub-agent or a sender-object caller (a developer or tester agent) is covered: the script cannot
detect either by itself, so `skills/j-commit/SKILL.md` instructs the model to pass `--caller noninteractive`
whenever `j.commit` was reached by a sub-agent, by a sender-object caller or by any automated run with no human to
answer, and `--caller interactive` otherwise. This is the one judgment the gate leaves to the model; the environment
variables are the reliable trigger for an automated run that sets them.

**Why a non-interactive caller never self-certifies.** A flag an agent passes is not a human decision, and a
background agent that ran tests and then committed on its own result would be certifying its own work. CLAUDE.md
assigns the opposite roles: the developer agent never runs tests, and the tester agent owns validation. The gate keeps
that split: an agent's commit is not blocked, but it carries no test claim either, and the log says why.

The developer agent's `j.commit` call passes `--caller noninteractive` (`agents/developer.md`).

### The event

Every gate outcome appends one event to `events.json` (the logs directory resolved by `scripts/resolve-root.sh`), under
`scripts/with-lock.sh`, through `test-gate-run.sh log`:

```json
{"event":"commit_test_gate","agent":"j.commit","action":"<action>",
 "choice":"<string or null>","reason":"<string or null>","failed_suites":["<name>"],
 "caller":"<interactive|noninteractive or null>","date":"<UTC ISO 8601>"}
```

| Field | Values |
|---|---|
| `action` | required: `skip`, `passed`, `failed`, `error`, `override`, `halt`, `fallback`, `unavailable`, `interrupted` |
| `choice` | free text (for example `skip`, `anyway`, `full`), an empty value is `null` |
| `reason` | free text (the skip reason, the fallback message), an empty value is `null` |
| `failed_suites` | the `;`-separated `--failed` names as an array, `[]` when none |
| `caller` | `interactive`, `noninteractive`, or `null` when not given (the skill always passes it) |
| `date` | UTC, `YYYY-MM-DDTHH:MM:SSZ` |

The append is atomic (a temporary file in the same directory, then `mv`). A missing or empty `events.json` becomes a
one-element array; a file that is not exactly one JSON array is left untouched and the call fails (exit 1). Exit 4
means the lock was not acquired in time and nothing was written.

### How `j.lgtm` and `j.dev-done` inherit the gate

Neither skill has gate logic of its own. Both call `j.commit`, so the gate runs inside it.

- **`j.lgtm`** forwards `--tests <ask|skip|scoped|full>` to `j.commit` unchanged. If `j.commit` printed `TEST_GATE=HALT`,
  or reported that nothing was committed, `j.lgtm` stops: it does not invoke `/continue` and does not return to a
  `/do` workflow. This also covers `j.commit`'s `No implementation to commit.` exit, which `j.lgtm` previously ignored.
- **`j.dev-done`** forwards `--tests` to `j.commit` unchanged and passes `j.commit`'s output to
  `skills/j-dev-done/scripts/classify-commit-outcome.sh`. A standalone `TEST_GATE=HALT` line makes the classifier exit 1
  with `Commit halted at the test gate: nothing was committed.` (the existing `No implementation to commit.` halt is
  unchanged), and `j.dev-done` then does **not** invoke `/self-sync`. The text merely appearing in prose, or inside a
  longer line, is not a signal.

### The scripts and suites that pin this contract

| Script | Role |
|---|---|
| `skills/j-commit/scripts/test-gate-decide.sh` | Resolve, prompts, answer parsers, the proceed/halt `directive` table |
| `skills/j-commit/scripts/test-gate-scoped.sh` | The scoped plan: changed files, one discovery run, mapping, derived catalog, narrowing |
| `skills/j-commit/scripts/test-gate-run.sh` | Runs `full` or `scoped` selections through `run-suites.sh`, the result trailer, the `commit_test_gate` event |
| `skills/j-dev-done/scripts/classify-commit-outcome.sh` | Recognises `j.commit`'s two halt signals for `j.dev-done` |
| `skills/j-test/scripts/` (`discover-tests.sh`, `map-scope.sh`, `build-catalog.sh`, `run-suites.sh`) | The discovery, mapping, catalog and execution the gate reuses; none is reimplemented |

| bats suite | Pins |
|---|---|
| `tests/commit-test-gate-decide.bats` | `test-gate-decide.sh`: resolve, prompts, answers, directive |
| `tests/commit-test-gate-scoped.bats` | `test-gate-scoped.sh`: plan statuses, narrowing, the derived catalog |
| `tests/commit-test-gate-run.bats` | `test-gate-run.sh`: result words, trailer, failed names, the event |
| `tests/commit-test-gate-skill.bats` | The structure of `j.commit` step 3.5, the `j.lgtm` / `j.dev-done` wiring and the classifier |
| `tests/commit-test-gate-e2e.bats` | The three real scripts driven in `SKILL.md`'s order over a scratch project: the seams between them, the exit codes a caller must treat as do not proceed, and the events a whole scenario leaves in `events.json` |

The script suites and the end-to-end suite use stub commands and fixtures under `BATS_TEST_TMPDIR` (the end-to-end suite
hands discovery over as a hand-written JSON file, so no real discovery runs); the skill suite reads text only and
executes no gate script and no test command. None runs this repository's real `npm test`.

## Scope test policy

### What it is

The scope test policy says which test run must pass **before a board scope is closed**: a task, a story or an epic. It is
configured per scope, and it is independent of the commit-time gate above. By default:

| Scope | Key | Default | What runs before it closes |
|---|---|---|---|
| Task | `test_run_task` | `none` | Nothing beyond the tests the tester agent writes and runs for the task |
| Story | `test_run_story` | `scoped` | The suites mapped from the story's changed files |
| Epic | `test_run_epic` | `none` | Nothing: the gate prints `no suite run (policy none)` and the rollup proceeds. See "Where the full suite runs" |

The scripts are the contract: `skills/j-test/scripts/scope-policy.sh` resolves a key to a mode and
`skills/j-test/scripts/scope-test-gate.sh` runs what the mode asks for. Both headers carry the full detail; this section
summarises them, and where they disagree the scripts win.

**No automatic gate runs the full suite.** `E72_S08_T01` moved the epic default from `full` to `none`, and
`E72_S08_T02` removed the `scoped`-to-`full` escalation (a `scoped` run with nothing mapped now runs the bounded default
suite set, and one with no commits is a non-pass). `full` is still an accepted value of all three keys, so a project can
choose it deliberately; nothing selects it on its own. What that means for an epic is under "Where the full suite runs".

### The three keys and their values

The keys are three more flat top-level strings of `project/configs/test-config.json`, in addition to the two in
"Configuration". Each takes one of `none`, `scoped` or `full`:

- **`none`**: no suite run beyond the tests the tester agent writes and runs for the item. The gate prints exactly
  `no suite run (policy none)` and exits 0. Nothing is derived, discovered or run, so the tester's existing flow is unchanged.
- **`scoped`**: run only the suites mapped from the scope's changed files by `map-scope.sh`, using the same scope map
  `j.commit` uses (`commit_scope_map_file`, else `templates/test-scope-map.json`).
- **`full`**: run the whole `j.test` catalog: `discover-tests.sh`, then `build-catalog.sh`, then `run-suites.sh`. The gate
  adds no exclusion logic of its own; once `E77_S02` lands, manual-only tests stay excluded because the same discovery,
  catalog and run scripts are reused.

**An absent key reads as its default.** A `test-config.json` written before these keys existed lacks them, and that is not
an error: `scope-policy.sh` prints the default silently. A key that is present but holds anything other than `none`,
`scoped` or `full` (another string, the empty string, a number, `null`, an object) reads as the key's default **with one
warning on stderr** naming the key, the offending value and the default used. An unreadable or malformed
`test-config.json` is treated the same way. A bad value therefore never skips testing silently, and it never fails the
gate by itself.

### When it runs

At the boundary the key is named for, and always before the status that closes the scope is written:

- **Task**: after the tests the tester wrote and ran for the task, before the tester writes the task's judged status.
- **Story**: in the tester's story-closing pass, before it writes the story's `Passed` or `Passed with remarks`. A
  mid-story pass does not call the story gate.
- **Epic**: before the scrum master's rollup writes the epic's closing status. The scrum master requests the gate from
  the tester; it does not run suites itself.

### Who runs it, and what a failure does

The **tester** runs the gate, because it owns test running. The **scrum master** requests the epic gate from the tester
before the epic's closing status. The **developer never runs tests** and never runs the gate. The gate itself never writes
board status; the caller applies the rule:

| Exit | Task | Story | Epic |
|---|---|---|---|
| `0` (satisfied, including policy `none`) | Continue to the judged status | Continue to the story's closing status | Continue the rollup |
| `1` (a suite failed) | `Failed` plus a problem rapport naming the failed suites | `Failed` plus a rapport, and no `story_rollup` trigger | Stays `In Progress`, no `date_completed`, plus a rapport |
| `2` or `3` (nothing was verified: a usage or tooling error, the `no-commits` non-pass, or a refusal of the bounded default suite set) | Reported as an error with a rapport; never a pass | Reported as an error with a rapport; the story's closing status is not written | Reported to the user; no rollup. Never a pass |

A failing policy run therefore prevents closing the scope. It never passes silently.

Exit 3 does not always mean the gate is broken. Three causes share it, and the tester and the scrum master report each
as what it is (the gate's message names which): a **tooling failure** (nothing was learned about the project); the
**`no-commits` non-pass** (no change set could be derived for the id, which usually means the gate ran from the wrong
checkout); and a **refusal of the bounded default suite set** (`test_default_suite_set` not configured, resolving to no
runnable test file, resolving to the entire catalog, or invalid), which is a real finding about the project's
configuration and is reported as that finding. None of the three is a pass, and none writes a closing status.

### Where the full suite runs

After `E72_S08` **no local lifecycle gate runs the full suite**: not a task close, not a story close, not an epic
rollup. It runs in three places, all chosen by a human or by CI rather than by code:

1. **The public CI `test` job on the `jenga-npm` mirror** (`.github/workflows/mirror-staging-gate.yml`, job `test`,
   running `npm test`, which is `bats tests/*.bats`) against a checkout of the staging branch. The same workflow's
   `promote-main` job declares `needs: [test, pack-smoke]`, so the full suite gates **fast-forwarding the public default
   branch**. It does **not** gate `npm publish`.
2. **`j.test`**, which a user invokes and which runs the whole runnable catalog by default.
3. **`j.commit`'s test gate**, option 2 or its zero-mapping fallback prompt, where a human types the choice.

**The epic-rollup trade-off, stated plainly.** With the default `test_run_epic: none`, an epic can roll up with **no test
run of its own**. That is acceptable because the rollup already requires every story beneath the epic to have passed its
own `scoped` story gate, so the changed code has been tested at the story boundary, and a full run at the epic boundary was the very
route the story removed (a gate whose result is decided by the whole catalog's unrelated redness). The cost is real and is
not hidden: a regression that only shows up in the interaction of several stories' suites is not caught by the epic close. What still catches it:

- The public CI `test` job above, which gates promotion to the public default branch (`promote-main`).
- A user running `j.test`, or a project that sets `test_run_epic` to `full` (`jenga config set test-config.test_run_epic full`).

What does **not** catch it, so nobody relies on it: `npm-publish.yml` is `workflow_dispatch` only and its publish job
declares `needs: audit`, the dependency audit, not the test job; `workflow_dispatch` can target any branch, so promotion
is the normal path onto the public branch but not an enforced one; and its `stage` job declares no `needs:` at all. That
release-path gap is deliberately left open. A mandatory full-suite gate on the release action was proposed as `E72_S10` and
rejected on 2026-11-08: the epic's aim is finer-grained control of test runs, with Jenga giving the user the information and
more frequent offers of a test run at the natural stops, so that nobody is stuck behind a gate. It stays a known limit, not
a covered case. The authoritative account is
`project/documentation/full-run-call-site-audit.md` section 2, which this section does not override. Note too that
`npm test` on the public checkout is top-level only and limited to the suites that survive `.publicignore`: the largest
automatic run that exists, not a superset of a local `j.test` run.

### How to change it

```bash
jenga config get test-config.test_run_story
jenga config set test-config.test_run_story full
jenga config set test-config.test_run_task scoped
```

`jenga config` validates the value against the descriptor `templates/config-descriptors/test-config.json`, where the
three keys are editable strings with `allowed: ["none", "scoped", "full"]`. `jenga config set test-config.test_run_story banana`
is refused with exit 4 and the file is not changed. Projects scaffolded by `j.init` carry all three keys with the
defaults above; for an older file, `jenga config set` creates the key. Usage and exit codes are in `project/configs/README.md`.

### Which changed files a scope is derived from

For `scoped`, the gate derives the scope's changed files from the git history, unless you give it an explicit range:

- **Commits are found by subject** on the history of `HEAD` of the repository at `--root`: a subject starting
  `task(<task id>)`, or the merge commit of a task branch (`Merge branch '<task id>...'`). Other commits that merely
  mention the id (rapports, board bookkeeping, `chore(<id>): ...`) are not part of the change.
- **Each commit contributes the files of its diff against its first parent**, so a merge commit contributes everything its
  branch brought in. The changed files are the unique union over the commits, handed to `map-scope.sh` in one call with its
  additive `--files-from` input.
- **Task**: the commits of that one task id. **Story**: the union over the tasks in the story file's `tasks:` list.
  **Epic**: the union over the stories in the epic file's `stories:` list, each expanded to its tasks. The lists are read
  from the board **under `--root`**, never from the directory of the script. When a board file or its list is missing
  (a worktree that does not carry uncommitted board files, a project that keeps no board), the id prefix is used instead:
  story `E##_S##` matches task ids `E##_S##_T<n>`, and epic `E##` matches `E##_S<n>_T<n>`.
- **`--range <a..b>` or `--rev <commit>`** replaces all of the above for any scope and is passed to `map-scope.sh`
  verbatim. At most one of the two may be given; both are ignored under `none` and `full`.

The consequence for the caller is where the gate runs from. For the task boundary the tester runs it from the task's
worktree (`--root <worktree>`, the sender object's `worktree`) or passes an explicit `--rev` / `--range`, because the
task's commits sit on an unmerged task branch. Story and epic boundaries run against the merged state (the main checkout,
the default `--root`), or with `--root <worktree>` when the closing task's branch is still unmerged.

### The scripts and their exit codes

```bash
bash skills/j-test/scripts/scope-policy.sh get <task|story|epic> [--root <dir>] [--config <file>]
bash skills/j-test/scripts/scope-test-gate.sh --scope <task|story|epic> --id <E##[_S##[_T##]]> \
    [--range <a..b> | --rev <commit>] [--root <dir>] [--config <file>] [--json]
```

`scope-policy.sh` prints exactly one token (`none`, `scoped` or `full`) on stdout. Its exit code is `0` or `2`; exit 1 is
deliberately unused, because a resolver that could fail would let a scope be closed without the gate it asks for.

| `scope-policy.sh` exit | Meaning |
|---|---|
| `0` | Resolved: one mode token on stdout, including every fallback to the default |
| `2` | Usage error: no or unknown subcommand, missing or unknown scope, extra argument, unknown option, an option without its argument, a `--root` that is not a directory |

| `scope-test-gate.sh` exit | Meaning |
|---|---|
| `0` | Gate satisfied: policy `none`, or every suite that ran passed |
| `1` | At least one suite failed; the caller must not close the scope. Reserved for test failures, so a caller can tell "tests failed" from "the gate broke" |
| `2` | Usage error, nothing ran: a missing, unknown or repeated option, a missing or unknown `--scope`, a missing `--id` or one malformed for the scope, both `--range` and `--rev`, a range or revision git rejects, a `--root` that is not a directory |
| `3` | Nothing was verified, which is never a pass. **Four kinds**, sharing the one code `E72_S06` gave that meaning. **(a) the `scoped` `no-commits` non-pass** (`E72_S08_T02`): no commits were found for the id, so no change set could be derived; nothing is run, the reason is on stdout, and `--json` **does** print its object. **(b) a refusal of the bounded default suite set** (`E72_S08_T06`), stdout empty: the changed files mapped to no suite and `test_default_suite_set` is not configured (resolver exit 4), resolves to no runnable test file (5), resolves to the entire catalog (6) or is invalid (3). This is a finding about the project's configuration, not a fault in the tooling, and the message names which. **(c) the `scoped` ≠ `full` refusal** (`E72_S08_T03`): the scoped selection is the entire runnable catalog, so nothing is run; the cause and the remedy are on stdout (stderr with `--json`) and `--json` **does** print its object, with `refusal: "scoped-equals-full"`. **(d) infrastructure error**, stdout empty: `jq` or `git` missing, no git repository for a scoped derivation, a helper script or the root not found, discovery, catalog, mapping, narrowing, the default-set resolver or the run failing for a reason other than a test failing, a `full` catalog with no runnable suite, or **every selected suite having been emptied by exclusion** |
| `130` | Interrupted while the suites ran: `run-suites.sh`'s code, passed through unchanged |

With `--json` the gate prints one compact JSON object on stdout whenever it reached a verdict — exit 0, 1 or 130, and
also the exit 3 of the `scoped` `no-commits` non-pass and of the `scoped` ≠ `full` refusal, which are verdicts about
the scope rather than a broken gate (`E72_S08_T02`, `E72_S08_T03`) — and sends the human text and the suites' own output to stderr. stdout stays empty for exit 2 and for
every *other* exit 3. The object has `scope`, `id`, `mode` (what the policy asked for: `none`, `scoped` or `full`),
`effective_mode` (what actually ran, and it has **four** values, not three: `"none"`, `"scoped"`, `"default-set"` and
`"full"`), `fallback_reason` (`null`, `"no-commits"` or `"no-mapped-suites"`), `suites_run`, `passed`, `failed`,
`suites` and `exit_code`, followed by the keys about narrowing and exclusion:

| Key | Meaning |
|---|---|
| `test_files_run` | how many test files actually ran |
| `test_files_available` | how many the selection covered — the pair that shows a `scoped` run is no longer the whole catalog |
| `excluded_test_files` | every file removed because it cannot pass right now; `[]` when none |
| `disabled_suites` | suite ids set to not-runnable because they could not honour an exclusion (an opaque `npm` entry point); `[]` when none |
| `map_excluded_test_files` | test files the scope map declares it deliberately leaves out of every rule, with the reason, **and that this run really did not execute**; `[]` on a full run and when the map declares none |
| `map_exclusion_conflicts` | declared files some rule selected anyway, so they are in the run and are **not** reported as kept out; `[]` normally |
| `map_exclusions_superseded` | declared files this run **superseded**, meaning it **executed** them. Derived **per file** since `E72_S08_T02`: on the `"no-mapped-suites"` path the declared files are partitioned on whether the bounded default suite set actually runs them. `[]` whenever the floor runs none of them, which is the case in this repository, so the declaration is back in force there; `[]` also under policy `full` and under `"no-commits"`, where no map is consulted at all. See "A declared omission only holds on the `scoped` path" |
| `exclusion_reason` | the cause, or `null` when nothing was excluded |
| `refusal` | `null`, or `"scoped-equals-full"` when the gate refused because the scoped selection was the entire runnable catalog (`E72_S08_T03`); `suites_run` is then `0` and `effective_mode` stays `"scoped"` |

Every one of them was **appended** (`map_exclusions_superseded` most recently); the keys before them keep their
names, order and meaning, so an existing reader is unaffected. `test_files_run` and `test_files_available` are `null` — not `0` — when a run was not narrowed at all
(policy `none`, or a `full` run with nothing excluded), because `0` would say "nothing was selected", which is a very
different and much worse statement than "narrowing did not apply here".

### Zero mapped suites, and no commits

A `scoped` run never exits 0 having executed nothing, and — since `E72_S08_T02` — **it never runs the full catalog
either.** The escalation that used to is gone, and the two causes are now handled *differently from each other*,
because they are different situations.

```text
scoped policy: no commits found for <id>; nothing could be derived, so nothing was verified (not a pass)
                                                                           (fallback_reason "no-commits", exit 3)
scoped policy: no suite maps to the changed files; running the bounded default suite set instead (never the full catalog)
                                                            (fallback_reason "no-mapped-suites", effective_mode "default-set")
```

**`no-commits` is an explicit non-pass.** Nothing is run, the gate exits **3** (`E72_S06`'s "nothing was verified"
code, reused rather than a new one), `effective_mode` stays `"scoped"` and `fallback_reason` keeps `"no-commits"`. No
change set could be derived for the id at all, so there is nothing a default set could honestly verify: running one
would report a pass for a change nobody could determine. `--json` still prints its object for this exit 3, with
`suites_run: 0` and `exit_code: 3`.

**`no-mapped-suites` runs the bounded default suite set** — see the next section. There *is* a change here, only no
rule covers it, so running nothing would be the opposite error. `effective_mode` becomes a third value,
`"default-set"`, which is what makes all three outcomes tellable apart from the exit code and the output alone: a
mapped selection ran (`"scoped"`), nothing mapped so the floor ran (`"default-set"`), or the whole catalog ran
(`"full"`, reachable only from an explicit `full` policy).

**Which bad outcome the `no-mapped-suites` behaviour avoids, and why it is a floor rather than an exit 3 or an exit 0.**
It avoids **both**, and the choice was made against the scrum master's Rollup Logic, which holds a story open on any
non-zero gate exit:

- It does not **wedge a sound story.** The old escalation's exit code was decided by the whole catalog's unrelated
  pre-existing redness — five A/B-verified failures recorded in
  `project/rapports/problems/E28_S20-story-scope-gate-fails-on-three-pre-existing-main-side-suites.md` plus the already
  red package-root sweep in `project/rapports/problems/E87_S07_T01-package-root-sweep-offender.md` — so a sound story
  failed its closing gate on failures it did not cause. On `E88_S03` the scrum master had to decline the gate by hand.
  A small, explicitly configured set cannot carry that in.
- It does not **mask a story with genuinely no coverage.** Something is always run and named, the floor's suites are
  listed on stdout and in `suites`, and a floor that resolves to nothing — or to everything — is **refused** (exit 3)
  rather than passed.

Either way it is always surfaced: the tester copies the line and the reason into its status note and its report, and the
scrum master passes it on to the user as a note rather than a failure.

### The bounded default suite set

*Added by `E72_S08_T06`; wired into the gate by `E72_S08_T02`, which removed the full-catalog escalation it replaces.*

A `scoped` run whose changed files map to **no suite at all** no longer has the full catalog to fall back on.
`E72_S07_T03` moved this project onto a 61-rule `project/configs/test-scope-map.json` and in doing so dropped the
shipped default's `**/*.sh` → `tests/**/*.bats` catch-all, so an uncovered area now matches nothing — and 61 specific
rules leave a larger uncovered surface than one blanket rule did, which made the full-run fallback fire *more* often,
not less. What replaces it is a **bounded default suite set**: a small, explicitly configured set of test files that
always runs when nothing maps. It is never the full catalog and never empty.

Only the `no-mapped-suites` cause gets it. **`no-commits` keeps `exit 3`**: no change set could be derived there at
all, so running a default set would report a pass for an id whose change is unknown.

#### The key

`test_default_suite_set` in `test-config.json`: a flat, comma-separated list of root-relative **test-file globs** in
the same glob dialect the scope map uses (see "The scope map" above).

```json
"test_default_suite_set": "tests/smoke-test-skills.bats,tests/resolve-root.bats,tests/events-append.bats"
```

```bash
jenga config get test-config.test_default_suite_set
jenga config set test-config.test_default_suite_set "tests/a.bats,tests/b.bats"
```

Two shape decisions worth stating, because both look arbitrary until the reason is given:

- **A flat string, not a JSON array.** The descriptor schema can only express an *editable* key as a scalar
  (`lib/config/descriptors.js`), `lib/config/store.js`'s `parseValue` refuses a non-scalar value given on the command
  line, and every array or object key in every shipped descriptor is pinned `editable: false`. An array value could
  therefore never be read or written through `jenga config`, which this key must support. Comma is the separator
  `j.test` already uses for a selection.
- **Test-file globs, not suite ids.** `discover-tests.sh` emits one bats suite **per directory**, so this
  repository's whole catalog is the single suite `bats:tests` whose command is `bats tests/*.bats`. A set named at
  suite granularity would *be* the catalog and could not be bounded at all — the exact defect `E72_S07_T01` measured.
  Test-file granularity is the only granularity at which "smaller than a full run" is expressible, and it is the
  granularity `narrow-suites.sh` runs at.

#### The resolver and the strict-subset guard

```bash
bash skills/j-test/scripts/resolve-default-suites.sh [--root <dir>] [--suites <discovery.json|->] \
    [--config <file>] [--set <value>]
bash skills/j-test/scripts/assert-bounded-subset.sh --root <dir> --suites <discovery.json|-> \
    --files <list|-> [--label <text>] [--json]
```

`resolve-default-suites.sh` turns the configured value into a runnable selection. It reuses `discover-tests.sh` (or
the discovery a caller already ran, through `--suites`, so the gate keeps its single tree walk) and
`build-catalog.sh`'s own runnability verdict; it never re-derives a catalog of its own. Its output deliberately
**mirrors `map-scope.sh`'s contract** — `mapped_suites`, `mapped_tests`, `unmapped_files`, `warnings`, plus an
additive trailing `default_set` object — because `narrow-suites.sh --mapped-tests` reads only `.mapped_tests`. The
gate can therefore substitute the resolver for `map-scope.sh` in the existing discovery → narrow → catalog → run
pipeline with no change to any other script.

`assert-bounded-subset.sh` is the one implementation of the strict-subset property *for a list of test files* (the
floor). `E72_S08_T03`'s `scoped` ≠ `full` invariant deliberately does **not** reuse it: that guard measures a *selection*
against an un-narrowed file universe, which is blind to narrowing and to the level-2 exclusion, so the invariant instead
compares the test files two *catalogs* will really execute (see "The standing `scoped` ≠ `full` invariant"). The guard compares **test files**, which is the only quantity for
which "smaller than a full run" means anything for a file list: suite-id set equality is true for *every* selection (one suite
per directory), and a narrowed command (`bats tests/a.bats`) is never a member of the full catalog's command set
(`bats tests/*.bats`). `--label` is quoted back in a refusal, so the caller can name the offending setting (`T06`).

A **runnable suite can decline to say which files it runs**: `discover-tests.sh` gives `paths: []` to an `npm`
suite (a script body is opaque) and to `shellcheck:all` (it checks sources, not test files). Those files are not in
the universe the guard compares against, because there is no honest way to enumerate them. So `available_count`
counts only *enumerable* files, the suite ids concerned are listed in the guard's `opaque_suites` and named in its
refusal message rather than being papered over, and a selection covering every enumerable file is
`equals-catalog` even though an opaque suite would also have run. That direction is the safe one — a refusal, never
a pass. A project whose only runnable suite is opaque has an empty universe and gets `exit 5` for any value: the
bounded default set is simply not expressible at file level there, and saying so beats selecting something
arbitrary.

| Exit | Meaning |
|---|---|
| `0` | Resolved: a non-empty selection, strictly smaller than the full runnable catalog |
| `2` | Usage error |
| `3` | Infrastructure error, **or an invalid configured value**: a glob outside the dialect, or an empty element between two commas. `map-scope.sh` gives an invalid scope-map file the same code — an explicit setting that is wrong is a misconfiguration, never a silent fallback |
| `4` | **Not configured**: the key is absent, `null` or empty |
| `5` | **Nothing to run**: the value resolves to zero runnable test files |
| `6` | **Not a strict subset**: the value resolves to the entire runnable catalog, so it is refused rather than run, with the offending value named |

#### The empty-set rule, and the absent-key default

A value resolving to zero runnable test files is a **refusal (`exit 5`)**, never a pass. That is the whole point of
the key: a floor that quietly resolves to nothing would be a gate reporting green having executed nothing, which is
`E72_S06`'s standing rule against exactly that. Two ways to reach it, both named in the message: the globs match no
file in the working tree, or every file they match is run by no runnable suite (those paths are listed in
`unmapped_files` and dropped with a warning, so a selection that *still* has a covered file left runs normally).

An **absent or empty key is a separate refusal (`exit 4`)** that names the key and prints the `jenga config set`
command to fix it. The shipped descriptor default and the `j.init` scaffold template are both `""`, deliberately:
naming this repository's own test files in a generic default would be wrong for every consumer, and naming nothing
honestly reports "you have not set this yet". A project that has never heard of the key therefore gets an actionable
refusal — never a silent pass, and never the full catalog, which is what this story exists to remove.

A configuration that resolves to the **entire** catalog is `exit 6` and is never executed. This holds for a one-file
catalog too, where `selected == available` is unavoidable: a "bounded default set" equal to everything is a
contradiction whatever the catalog's size. The guard reports `available_count` in its JSON so a caller that wants the
opposite policy can make that call itself. `E72_S08_T03` decided the same way for the `scoped` invariant: no exemption.

#### What is in the set for this project, and why

Six suites, resolving to **6 of 272 runnable test files** (measured 2026-11-02; 272 counts
`tests/default-suite-set.bats`, which this task adds):

| File | Why it is in the floor |
|---|---|
| `tests/smoke-test-skills.bats` | The structural smoke test over the whole skill catalog — the catalog-wide "did this change break a skill" check, and the one member that is broad rather than targeted |
| `tests/resolve-root.bats` | `scripts/resolve-root.sh`, the root resolver nearly every script in the repository calls |
| `tests/events-append.bats` | `scripts/events-append.sh`, the shared event-log writer every agent writes through |
| `tests/scope-test-policy-resolve.bats` | `scope-policy.sh` — the resolver that decides whether a gate runs anything at all. Silent breakage here means no gate |
| `tests/discover-tests.bats` | `discover-tests.sh`, which every gate and this resolver stand on |
| `tests/j-test-build-catalog.bats` | `build-catalog.sh`, same reason, including the runnability verdict the subset guard reads |

**The membership rule is a property, not a runtime budget.** Per `E72_S08`'s `E72_S09` fold: *no suite that mutates a
tracked artefact of the tree it runs in is eligible for the floor*, regardless of how fast it is. A runtime-only
justification invites re-adding a suite the moment it gets faster or is sharded, and the mutation hazard does not go
away with speed. The same rule bars a suite that drives a real outward push, and a suite carrying
`# jenga:requires-baseline-permissions:` — whether such a file runs or skips depends on ambient session state, which
would make the floor's verdict flip for reasons unrelated to the change under test.
`tests/default-suite-set.bats` asserts all three properties over the resolved set, so the rule is checked rather
than merely written down.

The three suites the project map declares in `excluded_tests` are **excluded from the floor for both of their
recorded reasons**, not only the first:

- `tests/mirror-test-subject-invariant.bats` — roughly **two hours** (it runs the whole shipping bats suite inside
  itself), **and** it mutates the real `.publicignore` of whatever tree it runs in, restoring it only in
  `teardown()`. A gate containing it can damage the exact artefact it is gating: on `E88_S03` the full-catalog
  fallback would have rewritten `.publicignore` while 25 uncommitted lines belonging to other sessions sat in it.
- `tests/mirror-permission-level-invariant.bats` and `tests/mirror-staging-branch-push.bats` — both drive the real
  `mirror.sh` end-to-end with real `git push`es (the `--force` path included) against a scratch bare remote. The real
  `jenga-npm` URL is never passed, so this is not a leak, but the containment rests entirely on
  `MIRROR_PUBLIC_URL_OVERRIDE` and `MIRROR_WORKTREE_PATH_OVERRIDE` being set on every invocation — not a property an
  automatic floor should depend on.

**Considered and rejected.** `tests/config-descriptors.bats` (62 cases) validates the whole config surface and would
look like an obvious floor member, but it cross-checks the live `project/configs/*.json` against the shipped
descriptors, so it goes red while any config key is being added — the "wedge a sound story" hazard, and it is red on
`main` today for exactly that reason (`commit_scope_map_file`'s live value and its descriptor default diverged when
`E72_S07_T03` landed). Every mirror-parity suite was rejected for the same shape of reason: those go red whenever
`.claude/` and `.agents/` are momentarily unsynced, which is a normal mid-story state. `tests/j-test-run-suites.bats`
was rejected as redundant once discovery and the catalog are covered — the floor should be small.

**Runtime.** Not measured by the implementing agent (the developer agent never runs tests). The reference point is
the `E72_S07` story gate: **23 test files / 853 cases in 12 m 06 s wall** on this machine (`project/data/baselines.json`,
`story_gate`, measured 2026-11-02, with the slowness probe flagging the machine slow in-run — wall time there is not a
measure of the tests). This floor is 6 files / 264 cases by `bats --count`, so roughly a quarter of that selection.
The measured wall-clock figure for the floor itself is recorded by the tester at verification.

### The standing `scoped` ≠ `full` invariant

`E72_S07` narrowed what a `scoped` selection contains and `E72_S08_T02` removed the escalation to the full catalog. Both
held only by the *content* of the scope map and of the gate, so a coarse map rule, a re-merged suite definition or a
regression could quietly restore a `scoped` gate that is a `full` one. `E72_S08_T03` is the machinery that makes it a
checked property: **a `scoped` run whose selection is the entire runnable catalog is refused. Nothing runs, the gate
exits 3, and the refusal is never a pass.** It applies to every path that reaches the runner (a mapped selection and the
bounded default suite set alike) and never to policy `full`.

```
scope test gate: REFUSED (task E99_S01_T01, policy scoped): the scoped selection is the entire runnable catalog, so nothing was run and nothing was verified (not a pass)
  a full run would execute 4 test file(s); this run would execute all of them
  cause: the scope map selected these suite definition(s), which together cover the whole catalog: bats:all
         - bats:all (paths: alpha/*.bats, beta/*.bats, delta/*.bats, gamma/*.bats)
         changed files: src/alpha/a.sh
         scope map: project/scope-map.json; rules whose source matches a changed file:
           rule 1: src/alpha/*.sh -> alpha/*.bats, beta/*.bats, delta/*.bats, gamma/*.bats
  remedy: narrow the rule or the suite definition named above so a scoped run selects strictly less, or set test_run_task to full deliberately (...)
```

#### What "the entire catalog" means: one definition, applied to both sides

Earlier attempts compared a *file universe*, then a *command fingerprint*, and each was blind in a different way (an
opaque suite contributes no files; narrowing rewrites a command so a fingerprint differs while the files are identical;
the baseline was the un-narrowed discovery while a full run narrows first). The invariant now has one definition:

- The **units** of a catalog are what its runnable entries execute. A bare `bats` invocation is expanded exactly as the
  shell expands it, at the project root, and yields one unit per test file (`bats tests/*.bats` and
  `bats 'tests/a.bats' 'tests/b.bats'` are the same units whenever they name the same files). Every entry that cannot be
  expanded to files (an npm script whose body is not bats, `shellcheck`, `pytest`) is **one opaque unit**, identified by
  its command text. An `npm test` / `npm run <key>` entry is first resolved to its `package.json` script body, as
  `build-catalog.sh` does, so the npm twin of a bats suite is the same files, not a different unit.
- The **reference** is the catalog a `full` policy would execute, built by `run_full`'s own steps from the one
  discovery this run already has (`narrow-suites.sh` in full mode, then `build-catalog.sh`). Because it is narrowed the same
  way, a file the level-2 baseline excludes is excluded from *both* sides and cannot make a bounded run look whole.
- **What is compared is the test files**, whenever the reference has any. A scope map selects a suite through the test
  files it covers, so an opaque suite such as `shellcheck:all` is not something a selection can include or leave out.
  This repository's full catalog is `bats:tests` plus `shellcheck:all`; comparing the opaque suite too would make the
  invariant vacuous here, and a rule selecting every test file would pass as "smaller" while being the hour-long run
  this story exists to remove. Refusing is the safe direction. Only a reference with **no** test file at all (a catalog
  of opaque suites only) is compared on its opaque commands.
- A `scoped` run is refused iff its compared units **contain every compared unit of the reference**. That is
  containment, not equality, so a run that exceeds a full run is refused too.

The check runs once, at the one point every run goes through (immediately before `run-suites.sh`), and keys on the
policy, which is fixed before anything is derived. It does not depend on which path produced the selection, on how a
command is spelled, or on which suite folded into which. Discovery is not repeated: the reference reuses the single
discovery.

#### Which exit code, which key

It reuses **exit 3** ("nothing was verified"), as `no-commits` does: no consumer needs to tell the two apart by code,
and `--json` carries the distinction in a new trailing key, `refusal` (`null`, or `"scoped-equals-full"`), appended
after `map_exclusions_superseded` as every earlier key was. The object is printed for this exit 3, like `no-commits`,
because it is a verdict about the scope: `suites_run: 0`, `effective_mode: "scoped"` (it never reads `"full"`),
`exit_code: 3`, and `fallback_reason` keeps `"no-mapped-suites"` when the refused run was the bounded default suite set.

#### The single-unit catalog

A catalog with exactly one compared unit (one test file, or one opaque command) has `scoped == full` unavoidably. **There is no exemption**: it is refused, with the
remedy in the message, and a project that really has one thing to run sets `test_run_<scope>: full` deliberately.
That is the same answer the bounded default suite set gives (`resolve-default-suites.sh` refuses an entire-catalog
floor whatever the catalog's size), so the two paths agree, and `full` is untouched, so such a project is not bricked.

#### Fails closed, and what it cannot see

If a reference or run entry that looks like a `bats` invocation cannot be expanded safely (it contains command
substitution, a pipe, a redirect), or the reference has no unit at all, the gate cannot prove the run is smaller than a
full one. It exits 3 with `cannot prove the scoped run is smaller than a full run` and nothing runs. Expansion is
only ever done on commands made solely of plain words, globs and single-quoted strings, so nothing is executed to
decide. Stated limits, not hidden ones:

- A non-`bats` runner is compared by its command text, and only when the catalog has no test file. A scoped run that
  selects every test file is refused whether or not the opaque suites ran, which over-refuses by design (see above).
- A recorded refusal on **this** repository needs a rule selecting every `tests/*.bats` file; the shipped
  `project/configs/test-scope-map.json` has none, which is the point. `shellcheck:all` is never selectable, so no
  scope-map change can make `scoped` run it, and the invariant is about the test files.
- The cause line names the rules whose *source* matched a changed file. That is a superset of the rule that decided, not
  a proof of it, and it is resolved from `commit_scope_map_file` (else `templates/test-scope-map.json`); with
  `--range`/`--rev` the changed files are not listed and the line says so.
- `resolve-default-suites.sh` still compares the floor against the un-narrowed file universe (`E72_S08_T06`). A floor that
  is a strict subset *before* exclusion but the whole catalog *after* it passes that resolver; this check is what refuses
  it, and the message names `test_default_suite_set`.

### Interplay with the `j.commit` gate

The two are independent. The commit gate runs at commit time and is steered by `commit_prompt_default`; the scope test
policy runs at the close of a task, story or epic and is steered by the three keys above. Neither is steered by the other's
keys, and changing one never changes the other. Both reuse the same discovery, mapping, catalog and run scripts and the same
scope map (`commit_scope_map_file`), so a better project scope map improves both. Once `E77_S02` lands, manual-only tests
stay excluded from both for the same reason: the exclusion lives in the shared scripts, not in either gate.

### Troubleshooting the scope test gate

**The gate exits 3.** Nothing was verified, so the scope must not close on it. Read the stderr message: the script names
the cause. The usual ones are `jq` or `git` missing from `PATH`; a `scoped` policy run outside a git repository; the root
or a helper script (`scope-policy.sh`, `discover-tests.sh`, `build-catalog.sh`, `map-scope.sh`, `run-suites.sh`) not
found; a scope map that is missing or invalid (the same causes as "A configured scope map is missing or invalid" below);
a `full` run whose catalog has no runnable suite (see "No suites found"); or a `scoped` run whose changed files mapped
to nothing *and* whose bounded default suite set could not be resolved — not configured, resolving to no runnable test
file, or resolving to the entire catalog (see "The bounded default suite set"). That last one is a refusal and a finding
about `test_default_suite_set`, not a tooling fault: the message names the offending value and the `jenga config set`
line that fixes it. Fix the cause and run the gate again.
Exit 2 is different: the invocation itself was wrong, so check `--scope`, `--id` and `--root`.

Two exit 3 kinds are **not** a broken gate: the `scoped` `no-commits` non-pass and the `scoped` ≠ `full` refusal. Their
message is on stdout (stderr with `--json`), `--json` prints their object, and the fix for each is below.

**The gate says `REFUSED ... the scoped selection is the entire runnable catalog`.** `refusal: "scoped-equals-full"`.
A scoped gate that amounts to a full one is refused (see "The standing `scoped` ≠ `full` invariant"). Read the `cause`
lines: they name the suite definitions and the scope-map rules (or `test_default_suite_set`) responsible. Narrow that
rule or definition so the selection is strictly smaller, or, for a project with a single unit to run, set
`test_run_<scope>` to `full` deliberately. `cannot prove the scoped run is smaller than a full run` is the fail-closed
form: a `bats` command could not be expanded to files, so simplify it (plain words and globs only).

**A scoped run reports `fallback_reason`.** Since `E72_S08_T02` neither value means the full catalog ran. For
`no-mapped-suites`, the changed files matched no rule of the scope map, as in "A scoped run maps nothing", and the
**bounded default suite set** ran instead (`effective_mode: "default-set"`): the gate is satisfied, but it verified the
floor rather than the change, so add a rule to a project scope map (see "A project scope map") if the change deserves
real coverage. For `no-commits`, the gate found no `task(<id>)` commit on the history of `HEAD` at `--root`, ran
nothing, and exited **3** — so the scope must not close on it. For a task this usually means the gate ran from the
wrong checkout: run it with `--root <worktree>`, or pass `--rev` / `--range`. For a story or an epic, check that the
task branches are merged into the checkout being used, or pass `--root <worktree>` or `--range`.

**A policy value set in the main checkout is not seen.** With `--root <worktree>` the gate reads `test-config.json` from
that worktree, so a `jenga config set` made only in the main checkout and not yet committed is not there, and the defaults
apply (`none`, `scoped`, `none` since `E72_S08_T01`). Commit the config change so the worktree carries it, or run the
gate against the checkout where you set it.

**A scoped run is very large.** The shipped scope map maps by file type: its `**/*.sh` rule maps a changed shell script to
every `tests/**/*.bats` file, so in a repository like this one a change to a single script selects a very large suite.
That is the shipped map being generic, not a malfunction. A project that wants a finer mapping supplies its own scope map
through `commit_scope_map_file` (see "A project scope map"), which both this policy and the `j.commit` gate then use.

**The run was interrupted.** The gate returns `run-suites.sh`'s exit 130 unchanged. Nothing was verified, so the scope
must not close on it; run the gate again.

## Troubleshooting

### No suites found

`j.test` prints `No runnable test suites found.` and stops. Discovery found nothing it could run. To see what it saw, run
it directly; it executes nothing, so it is safe:

```bash
bash skills/j-test/scripts/discover-tests.sh | jq .
```

Read its `warnings` array first (an unreadable directory, an unreadable `test-config.json`). If `suites` is empty and
there is no warning, the project has none of the files listed in the next entry, or they sit in a directory the walk
skips (a dot-directory, `node_modules`, `site-packages`, `fixtures` or `__fixtures__`).

### An ecosystem is not detected

Discovery looks only for these files and manifests, and nothing else:

| Ecosystem | What discovery looks for |
|---|---|
| npm | `package.json` with a script named `test` or starting `test:` or `test-` |
| bats | any directory holding `*.bats` files |
| pytest | a directory holding `test_*.py` or `*_test.py`, or a `conftest.py`, `pytest.ini` or `pyproject.toml` with `[tool.pytest.ini_options]` |
| Go | any directory holding `*_test.go` (not under `testdata/`) |
| Cargo | `Cargo.toml` at the scan root, plus `#[test]` in `src/**/*.rs` or in a `tests/*.rs` file |
| shellcheck | the `shellcheck` binary on `PATH` |

A test runner that is configured some other way (a Makefile target, a custom script that is not named `test*`) is not
found by discovery. Give it an npm script named `test:<something>` that runs it. Listing its tool in `test-config.json`
does not help on its own: a listed tool that was not detected becomes a suite with no command (see the next entry).
Symlinked directories are not followed.

### A suite shown as not runnable

A suite under `Not runnable (listed only, cannot be selected):` has no command, so it cannot be selected, run, or counted
as a pass or a fail. It comes from a `test-config.json` `tools` entry whose tool discovery did not detect on disk, and
discovery adds the warning `configured tool not detected on disk: <tool> (<type>)`. Either make the tool detectable (see
the table above), or remove the entry through the tester's approval flow (`tools` is read-only to `jenga config`). An
entry whose `tool_name` is `-` is a deliberate placeholder for "no tool for this type" and is never shown.

### A configured scope map is missing or invalid

`map-scope.sh` exits 3 with a message naming the file. For a configured `commit_scope_map_file` the causes are: the file
does not exist or is unreadable; the value is not a string, is absolute, contains a `..` segment or does not end in
`.json`; or the file itself is not valid (not JSON, `map_version` missing or not `1`, `rules` missing or empty, a rule
with a key other than `source` and `tests`, an empty or non-string glob, a glob outside the dialect, or a `!`
negation). The message names the file and, for a rule, its 1-based index. Fix the file, or point the key back at the
shipped map:

```bash
jenga config set test-config.commit_scope_map_file templates/test-scope-map.json
```

The commit gate treats any non-zero exit from the mapper as an error plan: it says so, states that no test was run and
that this is not a pass, and offers the full suite or skipping (see "Zero mapped, or a mapping error" in the gate
section). A `test-config.json` that cannot be read at all is different: the mapper treats it as the key being absent,
warns `test-config.json could not be read; using the default scope map`, and uses the default map.

### A scoped run maps nothing

The mapper reported `No tests found for the changed files`. What happens next depends on which gate asked: `j.commit`'s
gate says so and **offers** the full suite (its three-option prompt is unchanged, and is a human-invoked surface), while
the scope test gate runs the **bounded default suite set** and never offers or takes the full catalog (`E72_S08_T02`).
Either way, read `unmapped_files` in `map-scope.sh`'s output: those are the changed files that no rule's `source` matched and that are not
themselves test files. The usual causes are a change to documentation, configuration or board files (no test covers
them), a source language the shipped map has no rule for, or a layout that differs from the shipped globs (the shipped map
expects tests under `test/` or `tests/`). Add a rule to a project scope map (see "A project scope map") or choose the full
suite. In **this** repository the first of those causes is largely closed: documentation and board `.md` paths do have
rules, so check the table in "Documentation changes" before concluding a docs change cannot be narrowed. The warnings `rule <n> (<source>): ... matched but no existing test file matched its tests globs` and `... test
files matched but no discovered suite runs them` name the rule whose `tests` globs find nothing, or whose test files no
suite's `paths` covers.

### `npm`, `pytest`, `bats` or `shellcheck` is not on `PATH`

Discovery detects `npm`, `pytest`, `bats`, `go` and `cargo` suites from files, not from the tool being installed, so
the suite is listed and numbered. The failure shows up when it runs: the shell reports command not found (exit 127),
`run-suites.sh` counts the suite as failed, marks it with the failure mark in the summary, and goes on to the next one.
Install the tool and run again. `shellcheck` is the exception: it is detected by a `PATH` lookup, so a machine without it
simply does not list the `shellcheck` suite, with no warning (an optional linter that is not installed is not a
problem). Install it and it appears in the list.

`jq` is required by every script in the runner. Without it discovery exits 1 and `run-suites.sh` exits 2, each naming
`jq` on stderr, and the commit gate's `resolve` step halts every commit until it is installed (see the gate section).
