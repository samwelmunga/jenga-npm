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

Enter selection (comma-separated, or 'all' for all, or blank for 1 through 2):
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

The mapper reported `No tests found for the changed files`, and the gate said so and offered the full suite. Read
`unmapped_files` in `map-scope.sh`'s output: those are the changed files that no rule's `source` matched and that are not
themselves test files. The usual causes are a change to documentation, configuration or board files (no test covers
them), a source language the shipped map has no rule for, or a layout that differs from the shipped globs (the shipped map
expects tests under `test/` or `tests/`). Add a rule to a project scope map (see "A project scope map") or choose the full
suite. The warnings `rule <n> (<source>): ... matched but no existing test file matched its tests globs` and `... test
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
