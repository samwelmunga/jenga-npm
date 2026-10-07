# Project Conventions

Maintainer documentation for epic `E69` (Project Conventions Wizard). A project records its own conventions
(how it names things, formats commits, comments code) in a declarative `conventions.json`. The `j.conventions`
wizard writes it, a generator derives advisory/confirm pre-flight checklist items from it (see
`preflight-checklists.md`), and agents read it. This document is the single human-readable source for the
file format; the machine-readable source is `templates/conventions-schema.json`, which
`scripts/validate-conventions.sh` reads. Where this document and the schema file disagree, fix the document.

## Overview

The feature has four moving parts, each a script or skill that does one thing:

1. **Record.** `j.conventions` (`skills/j-conventions/SKILL.md`) is a guided wizard. It walks the 9 categories
   below, shows what the project already does (detection) beside 2 or 3 general-standard presets, and writes
   `<configs>/conventions.json` atomically. Hand-editing the file stays supported.
2. **Enforce softly.** `scripts/generate-convention-checklist.sh` derives one managed pre-flight checklist item
   per recorded category (`conv-<category>`), `advisory` or `confirm` strength only, so agents are reminded of a
   convention at the `pre-task` and `pre-commit` moments the E67 checker already gates.
3. **Inform agents.** `scripts/conventions-digest.sh` prints a compact summary the developer, tester,
   scrum-master and `j-commit` consult. A recorded convention beats the developer's inference from the codebase.
4. **Protect EST.** Board commits keep EST naming (`task(E##_S##_T##):`, `story(...)`, `epic(...)`), because
   `/reconcile` relies on it. A `commit-format` convention shapes non-board commits only.

The checker (`scripts/checklist.sh`) and the hook (`hooks/on_preflight_check.sh`) are unchanged by this feature.

Where to read next: **Schema** (the file format), **Detection output**, **Checklist generation**, **Wizard flow**,
**EST commit naming**, **Agent consumption**, **Scripts index**, **Out of scope**. Each section was written by the
story that built the part it describes; where a section and the script it describes disagree, the script is
right and this document is the bug.

### The 9 categories at a glance

| Id | Covers | Detector (`detect-conventions.sh`) | Checklist item | Situations | Strength |
|---|---|---|---|---|---|
| `commit-format` | Commit message format, non-board commits only | last 50 non-board subjects, commitlint config | `conv-commit-format` | `pre-commit` | advisory |
| `branching` | Branching model | local and remote branch names | `conv-branching` | `pre-task` | advisory |
| `naming` | Identifier, file and type naming | file-name case of tracked source files | `conv-naming` | `pre-task`, `pre-commit` | advisory |
| `code-comments` | Code comments and docs-in-code | none (presets only) | `conv-code-comments` | `pre-commit` | advisory |
| `formatting-linting` | Formatting and linting | tool configs, `package.json` scripts | `conv-formatting-linting` | `pre-commit` | `confirm` with a recorded `lint_command`, else advisory |
| `testing` | Testing expectations | test directories, `test-config.json`, test script | `conv-testing` | `pre-commit` | advisory |
| `file-layout` | File and directory layout | top-level directories | `conv-file-layout` | `pre-task` | advisory |
| `language-tooling` | Language and tooling | manifests, lockfiles, runtime pins | `conv-language-tooling` | `pre-task` | advisory |
| `documentation-placement` | Where documentation lives | `docs/`, the configured documentation directory, a README | `conv-documentation-placement` | `pre-commit` | advisory |

The value fields of each category are in the Schema section's category table; the detector rules are in
"Confidence scale and detector rules"; the generated text and strength rule are in "The strength rule".

## Schema

### File location and path resolution

The instance lives at `<configs>/conventions.json`, where `<configs>` is resolved through
`scripts/resolve-root.sh get configs`, never a hardcoded `project/configs` literal. The shipped generic default
is `templates/conventions.json`. This repository holds no instance of its own, because `project/configs`
ships downstream via `/j-mirror-public` and a shipped file must carry no project-specific value.

### Top-level keys

Exactly two keys, nothing else (an unknown top-level key is rejected):

| Key | Type | Rule |
|---|---|---|
| `conventions_version` | integer | Exactly `1`. Never bumped by `jenga config`. |
| `categories` | object | Maps a category id to a category entry. May be empty. |

The shipped default is exactly `{ "conventions_version": 1, "categories": {} }`.

### Categories

v1 has exactly these 9 category ids. An unknown id is invalid. A category **absent** from `categories` means
"skipped / no convention recorded".

| Id | Meaning | Required `values` field | Optional `values` fields |
|---|---|---|---|
| `commit-format` | Commit message format (non-board commits only, see below) | `style` (string) | `message_regex` (string), `subject_max_length` (integer) |
| `branching` | Branching model | `model` (string) | `branch_pattern` (string), `default_branch` (string) |
| `naming` | Identifier, file and type naming | `identifier_case` (string) | `file_case` (string), `type_case` (string) |
| `code-comments` | Code comments and docs-in-code | `policy` (string) | `public_api_docs_required` (boolean), `doc_comment_style` (string) |
| `formatting-linting` | Formatting and linting | `approach` (string) | `format_command` (string), `lint_command` (string), `editorconfig` (boolean) |
| `testing` | Testing expectations | `expectation` (string) | `test_command` (string), `test_dir` (string) |
| `file-layout` | File and directory layout | `layout` (string) | `source_dir` (string), `test_dir` (string) |
| `language-tooling` | Language and tooling | `version_policy` (string) | `runtime` (string), `package_manager` (string), `lockfile_committed` (boolean) |
| `documentation-placement` | Where documentation lives | `policy` (string) | `public_docs_dir` (string), `internal_docs_dir` (string) |

Categories are deliberately coarse. The five deferred categories (error handling / logging, dependency policy,
security hygiene, review / PR rules, release / versioning) are out of scope for v1.

### Category entry

```json
{
  "conventions_version": 1,
  "categories": {
    "commit-format": {
      "source": "preset",
      "preset": "conventional-commits",
      "summary": "Conventional Commits (type(scope): subject)",
      "values": { "style": "conventional-commits" },
      "strength": "advisory"
    }
  }
}
```

| Field | Type | Rule |
|---|---|---|
| `source` | string | Required. One of `detected`, `preset`, `custom`. |
| `preset` | string | A kebab-case preset id from `templates/conventions-presets.json`. **Required** when `source` is `preset`; **optional** for `detected` (set when the detection matched a preset); **forbidden** for `custom`. |
| `summary` | string | Required, non-empty, single line. Shown verbatim in generated checklist text and in the agent digest. |
| `values` | object | Required. Only the fields declared for the category in the table above; an unknown key is rejected, the required field must be present, and each value must have its declared type. |
| `strength` | string | Optional. `advisory` or `confirm`. |

### `strength` and the `block` prohibition

Generated checklist items are advisory or confirm strength only (epic Decision 4): judgment conventions
(naming, comments, docs) are `advisory`, machine-verifiable ones (the lint/format command, a commit-message
regex) are `confirm`. The value `block` is **never legal anywhere in the file**: the validator rejects the
value `block` under a key named `strength` or `enforcement` at any depth, not only in the `strength` field,
and the message says `block` is not allowed for conventions.

### Single-line rule

Every free-text string (`summary` and every string under `values`) must be a single line: newline and
carriage-return characters are rejected. A value later flows into a checklist item's `text` and possibly into
a `verify` command line, so a newline there could split or inject a command. Strings must also be non-empty.

### EST commit naming for board commits

EST commit naming (`task(E##_S##_T##):`, `story(...)`, `epic(...)`) stays **mandatory for board commits**,
because `/reconcile` relies on it. `commit-format` applies to non-board commits only, and a project's
`commit-format` convention can never override EST naming.

### Preset catalog

`templates/conventions-presets.json` is the catalog of general standards the wizard offers beside the detected
one. Shape: `{ "presets_version": 1, "categories": { "<category-id>": [ { "id", "label", "description", "values" } ] } }`
with 2 or 3 presets for every category in the schema. Each preset `id` is kebab-case and unique within its
category, and stable once merged, because detection maps detected values onto preset ids. A preset's `values`
validates against the same per-category field list as an instance, and a preset never sets a `block` strength.
Presets carry placeholder commands only (marked as placeholders in `description`), never a command that is run
blindly. `scripts/validate-conventions.sh --presets <file>` validates a catalog.

### Validating

```
scripts/validate-conventions.sh <file>...            # instances
scripts/validate-conventions.sh --presets <file>     # a preset catalog
```

Exit `0` all valid, `1` at least one invalid or unreadable, `2` usage error, `3` `python3` missing. Every
problem is reported on stderr as `<file>: <message>` naming the offending JSON path.

### Extending the categories

Add the category to `categories` in `templates/conventions-schema.json` (with its `values` field specs), add
2 or 3 presets for it in `templates/conventions-presets.json`, and update the table above. No script keeps its
own copy of the category list, so nothing else needs the id added, except consumers that deliberately map the
category (the detector `E69_S02` and the generator map `E69_S03`).

## Detection output

`skills/j-conventions/scripts/detect-conventions.sh` inspects a project and reports, per category, the standard the
project already follows. It is the first half of the `j.conventions` wizard: the wizard offers each detected value
as the first option (with its evidence and confidence) beside the general-standard presets, and the agent digest
reads the same document. The script header is the contract's source; where this section and the script disagree,
fix this section.

```
bash skills/j-conventions/scripts/detect-conventions.sh       # JSON on stdout
bash skills/j-conventions/scripts/detect-conventions.sh --help
```

The project root comes from `scripts/resolve-root.sh` (`JENGA_PROJECT_ROOT` is honoured). With no `workflow.json`
registry the directory itself is inspected and one warning says so. Test overrides: `JENGA_CONVENTIONS_SCHEMA`,
`JENGA_CONVENTIONS_PRESETS`.

### Object shape

```json
{
  "detect_version": 1,
  "categories": {
    "<category id>": {
      "detected": { "...": "..." },
      "preset_match": "conventional-commits",
      "evidence": "41 of the last 50 commit subjects match type(scope): msg (3 EST board subjects excluded)",
      "confidence": "high",
      "preset_only": false
    }
  },
  "warnings": []
}
```

| Field | Meaning |
|---|---|
| `detect_version` | Always `1`. |
| `categories` | One entry for every category id in `templates/conventions-schema.json`, in schema order. The ids are read from the schema, so a category added there appears here (null) without a script change. |
| `detected` | The detected value as an object using the field names of that category's `values` in the schema, or `null` when nothing reliable was found. Only measured fields are present, and the required field is always set when the value is not null. A detected object validates as a `values` object, so it can be written to `conventions.json` as `source: "detected"`. |
| `preset_match` | The id from `templates/conventions-presets.json` that the detected value corresponds to, or `null` (no preset fits, or the catalog was unreadable). Preset ids are looked up in the catalog, never assumed. |
| `evidence` | Concrete, checkable text: counts, file names, directories. Single line. Empty string when nothing was found. Show it to the user verbatim. |
| `confidence` | `high`, `medium`, `low` or `none`. `none` exactly when `detected` is `null`. |
| `preset_only` | `true` only for a category with no reliable detector (`code-comments`). The wizard offers presets only and must not present a detected option. |
| `warnings` | One text per source that was skipped (malformed JSON, unreadable file, unreadable preset catalog, unresolvable `workflow.json` path) and the no-registry note. |

### Guarantees

- **Read-only.** The script writes nothing inside the project: no file, no temp file, no git write (`git status` is
  deliberately not used because it refreshes the index). Detected commands, such as a `package.json` `lint` script,
  are reported and never executed.
- **Exit 0 for every project**, including an empty directory and a repository with no commits (every category null).
  A malformed or unreadable source file is skipped and named in `warnings`; the run continues.
- Only environment failures exit non-zero: `2` usage error, `3` `jq` not found, `4` the schema's category list is
  unreadable.
- Git is used only when the root is itself a repository root. Without commits, commit sampling, branch and naming detection
  report nothing.

### Confidence scale and detector rules

`high` means several independent signals agree, `medium` one clear signal, `low` a weak or absence-based signal,
`none` no detection. The thresholds below are the ones in the script.

| Category | Sources | Rule |
|---|---|---|
| `commit-format` | the last 50 non-merge, non-board commit subjects (looking back at most 200 commits); commitlint config (`commitlint.config.*`, `.commitlintrc*`, or a `commitlint` key in `package.json`) | EST board subjects (`task(E##_S##_T##):`, `story(...)`, `epic(...)`) are skipped and counted, never part of the sample. Conventional Commits when at least 20% of the sample matches the `conventional-commits` preset's `message_regex`: `high` at 80% or more, `medium` 50-79%, `low` 20-49%, below 20% not detected (the evidence still states the count). A commitlint config that mentions `conventional` forces `high`. JS, TS and YAML commitlint files are presence-only signals (they cannot be syntax-checked); `.commitlintrc.json`, a JSON-shaped `.commitlintrc` and `package.json` are checked. |
| `branching` | local and remote branch names, deduplicated | `git-flow` = `develop` plus `release/` or `hotfix/` (`high` with `feature/` branches, else `medium`); `github-flow` = `feature/` or `feat/` branches (`high` from 3, else `medium`); `trunk-based` = only `main`/`master`/`trunk`/`develop` branches (`medium` when a remote ref exists, else `low`); anything else is not detected. `default_branch` comes from `origin/HEAD`, else a `main`/`master`/`trunk` branch, else the current branch. |
| `formatting-linting` | `.editorconfig`; eslint (`eslint.config.*`, `.eslintrc*`, `eslintConfig`); prettier (`.prettierrc*`, `prettier.config.*`, `prettier` key); ruff (`ruff.toml`, `.ruff.toml`, `[tool.ruff]`); `go.mod` (gofmt); `package.json` scripts | `high` = a tool config and a runnable script (`lint`, `format` or `fmt`); `medium` = a tool config alone; `low` = `.editorconfig` alone or a script alone. `lint_command` / `format_command` are `<package manager> run <script>` (the script body is quoted in the evidence), never the raw body. `approach` is `formatter-and-linter` when any tool config or script exists, else `editorconfig-only`. |
| `language-tooling` | `package.json`, `tsconfig.json`, `pyproject.toml`, `requirements.txt`, `go.mod`, `Cargo.toml`; lockfiles; runtime pins | Languages are listed in the evidence only. `package_manager` comes from the `packageManager` field, else the first lockfile (`package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `bun.lock[b]`, `uv.lock`, `poetry.lock`, `Pipfile.lock`, `Cargo.lock`, `go.sum`), and is `pip` for a lone `requirements.txt`. `runtime` is the first pin found among `.nvmrc`, `.node-version`, `.tool-versions`, `engines.node`, `.python-version`, `requires-python`, `go.mod`, `rust-version`, `tsconfig` target (all are listed in the evidence). `lockfile_committed` asks git and is omitted outside a repository. `version_policy`: `pinned-runtime-and-lockfile` (`high`), `latest-stable` (`low`), else `runtime-pinned` or `lockfile-committed` (`medium`, no preset). |
| `testing` | top-level `tests/`, `test/`, `__tests__/`, `spec/`; `<configs>/test-config.json` `tools[]`; a `package.json` `test` script; co-located test files | `high` = a test directory and a tool entry or test script, or a tool entry and a test script; `medium` = a test directory or tool entry alone; `low` = a test script or co-located files alone. `expectation` is always the descriptive `tests-present` (a policy cannot be measured from the tree) with `preset_match: null`; `test_dir` and `test_command` are set when found. The `npm init` placeholder test script is ignored. |
| `file-layout` | top-level directories, minus hidden ones, `node_modules`, `dist`, `build`, `out`, `target`, `coverage`, `vendor`, `venv`, `__pycache__` and the Jenga working tree | First rule that applies: `packages/` or `apps/` with sub-directories, or a `workspaces` key (`monorepo-packages`, `high` with both, else `medium`); `src/` plus a top-level test directory (`src-and-tests`, `high`); `src/` holding test files (`co-located-tests`, `medium`); `src/` alone (`src-directory`, `low`); source files at the top level without `src/` (`flat-top-level-modules`, `medium` from 3 files, else `low`); otherwise not detected, with the directory list in the evidence. |
| `documentation-placement` | `docs/`, the directory resolved from `workflow.json` `paths.documentation` (default `project/documentation`), a README | Non-hidden files are counted in each. Both populated and different: `published-docs-in-docs-internal-elsewhere` (`high`); `docs/` alone: `everything-in-docs` (`medium`); only the internal directory: `internal-docs-only` (`medium`, no preset); only a README: `readme-only` (`low`); nothing: not detected. The internal path is resolved, never the literal `project/documentation`, and is reported relative to the root. |
| `naming` | the first 200 tracked source files from `git ls-files` (hidden directories, `node_modules`, `vendor`, `dist`, `build` and the Jenga tree skipped) | The file-name base (before the first dot) is classified `kebab-case`, `snake_case`, `camelCase` or `PascalCase`; single lowercase words are not counted. A case wins with more than 50% of at least 3 classified files, otherwise not detected. `identifier_case` is measured from function and variable definitions in the same files (needs 5 definitions and a majority), else inferred from the file case and the evidence says so; `type_case: PascalCase` is added from 3 type definitions. `medium` only when the winner holds at least 80% of at least 10 files and `identifier_case` was measured, else `low` (never `high`: file names say little about identifiers). Requires a repository with commits. |
| `code-comments` | none | Always `detected: null`, `confidence: none`, `preset_only: true`. Never a guess. |

### Example (Conventional Commits project, categories abridged)

```json
{
  "detect_version": 1,
  "categories": {
    "commit-format": {
      "detected": {
        "style": "conventional-commits",
        "message_regex": "^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\\([^)]+\\))?!?: .+"
      },
      "preset_match": "conventional-commits",
      "evidence": "41 of the last 50 commit subjects match type(scope): msg (3 EST board subjects excluded)",
      "confidence": "high",
      "preset_only": false
    },
    "branching": {
      "detected": { "model": "github-flow", "branch_pattern": "feature/<slug>", "default_branch": "main" },
      "preset_match": "github-flow",
      "evidence": "4 branches (local and remote, deduplicated): 3 feature/, 0 release/, 0 hotfix/, 0 develop; default branch main",
      "confidence": "high",
      "preset_only": false
    },
    "code-comments": {
      "detected": null,
      "preset_match": null,
      "evidence": "",
      "confidence": "none",
      "preset_only": true
    }
  },
  "warnings": [".commitlintrc.json is not valid JSON; skipped"]
}
```

### For the consumers

- **Wizard.** Offer `detected` first when it is not null, show `evidence` and `confidence` next to it, then the
  presets (marking the one named by `preset_match`), skip and custom. For `preset_only: true` offer presets only.
  Surface `warnings` once, before the first category.
- **Agent digest.** Treat a detected value that the user did not confirm as a hint, never as a recorded convention;
  only `conventions.json` is authoritative.
- A `detected` object is already shaped for `conventions.json`: set `source: "detected"`, `preset` to `preset_match`
  when it is not null, a one-line `summary`, and `values` to the object.

## Checklist generation

`scripts/generate-convention-checklist.sh` turns a project's `conventions.json` into pre-flight checklist items, so
a recorded convention is consulted at the lifecycle moments the E67 checker already gates (`pre-commit`,
`pre-task`) without anyone hand-authoring checklist JSON. Which item each category produces, at which phase and
with which strength is data in `templates/conventions-checklist-map.json`, not logic in the script. The E67
checker (`scripts/checklist.sh`, `hooks/on_preflight_check.sh`) and its no-item-level-merge semantics are not
changed (`preflight-checklists.md` section 9).

### Invocation

| Command | Effect |
|---|---|
| `scripts/generate-convention-checklist.sh` | Merge the rendered items into `<configs>/checklists.json` and print one summary line, `conventions checklist: N added, N updated, N removed, N unchanged`. |
| `scripts/generate-convention-checklist.sh --check` | Write nothing and take no lock. Exit `0` when the registry is up to date with `conventions.json`, `1` when a run would change it (or the merged result would not validate). |
| `scripts/generate-convention-checklist.sh --print` | Print the rendered item array on stdout and touch nothing. |
| `--conventions <file>` | Read that file instead of `<configs>/conventions.json` (any mode). |

`<configs>` is resolved through `scripts/resolve-root.sh get configs` (`JENGA_PROJECT_ROOT` is honoured). The
target is the project instance `<configs>/checklists.json`, never the shipped `templates/checklists.json`. The
`j.conventions` wizard runs the generator after every write of `conventions.json`; it can also be run by hand.
Exit codes: `0` ok or up to date, `1` refused or failed (invalid `conventions.json`, an id collision, the strength
rule, an invalid merged registry, or `--check` finding the registry stale), `2` the registry lock could not be
acquired (nothing was written), `3` usage error.

The input is validated with `scripts/validate-conventions.sh` first: an invalid file prints that validator's lines
on stderr, nothing on stdout, and stops the run. No `conventions.json`, or one with an empty `categories`, renders
no items.

### The managed-item boundary

An item is **managed** if and only if its `id` starts with `conv-` **and** its `provenance.source` is
`"convention"` (with `provenance.category` naming the category it came from; see `preflight-checklists.md`
section 9, "Provenance fields"). The generator replaces, adds and removes only managed items. Every other item is
carried through untouched, in its original relative order: hand-written items, `provenance.source: "authored"`,
agent-suggested `"suggested"` items, and a `conv-` id with no or any other provenance. If a rendered id collides
with such a non-managed item, the run exits `1` naming the id and changes nothing; it never overwrites an item it
does not own.

Managed items are placed after all non-managed items, in the schema's category order. A category that is no
longer in `conventions.json` has its `conv-` item removed on the next run, and a changed convention rewrites only
its own item.

### Idempotence

"Changed" means the resulting `items` array differs from the live one in content or order. When it does not
differ, nothing is written, so a second run leaves the registry byte-identical and reports `0 added, 0 updated,
0 removed, N unchanged`. When it does, the whole file is serialised once by the script's single formatter, which
expands objects and keeps arrays of scalars on one line: the style this repository's `checklists.json` and
`templates/checklists.json` already use, so a registry in that style is not reformatted. Top-level keys other
than `items` (for example a `situations` extension) are preserved.

### Seeding from the shipped default

With no `checklists.json` instance and at least one rendered item, the generator creates the instance from the
shipped default (`templates/checklists.json`, located relative to the script so it works from a consumer install
at `node_modules/@jenga-ai/agent/`) **plus** the generated items. The default's items must be carried over
because `scripts/checklist.sh` selects one whole file and never merges instance and default
(`preflight-checklists.md` section 9): an instance holding only `conv-` items would silently drop the default's
checks. With no instance and nothing to render, no file is created.

### Atomic write

The write runs under `scripts/with-lock.sh <registry> -- ...`. The merged result is written to a candidate file
beside the registry, validated with `scripts/validate-checklists.sh`, and only on a pass renamed over the
registry. On a validation failure the candidate is removed, the validator's lines go to stderr, the live file is
left byte-identical and the exit code is `1`, so a registry that fails validation is never left on disk. If the
lock cannot be acquired within `with-lock.sh`'s timeout, nothing is written and the exit code is `2`.

### The strength rule

Generated items are `advisory` or `confirm` only; `block` is never emitted (epic E69, Decision 4). Judgment
conventions are `advisory`; the one machine-verifiable category is `confirm`. The generator enforces this
itself: if the map or a convention ever yields any other enforcement it exits `1` and prints no items, in
addition to `scripts/validate-conventions.sh` (which rejects `block` in any `strength` or `enforcement` key). A
convention entry's own optional `strength` (`advisory` or `confirm`) overrides the map's value for that item.
`scripts/validate-checklists.sh` deliberately has no rule about it for `convention` items, so a hand-edit that
raises a generated item does not make the whole registry unreadable; the next run rewrites the item back.

| Category | Item id | Situations | Kind | Enforcement |
|---|---|---|---|---|
| `commit-format` | `conv-commit-format` | `pre-commit` | judgment | advisory |
| `branching` | `conv-branching` | `pre-task` | judgment | advisory |
| `naming` | `conv-naming` | `pre-task`, `pre-commit` | judgment | advisory |
| `code-comments` | `conv-code-comments` | `pre-commit` | judgment | advisory |
| `formatting-linting` | `conv-formatting-linting` | `pre-commit` | machine | confirm |
| `testing` | `conv-testing` | `pre-commit` | judgment | advisory |
| `file-layout` | `conv-file-layout` | `pre-task` | judgment | advisory |
| `language-tooling` | `conv-language-tooling` | `pre-task` | judgment | advisory |
| `documentation-placement` | `conv-documentation-placement` | `pre-commit` | judgment | advisory |

`formatting-linting` is `confirm` only when the convention recorded a `lint_command`: its `verify` runs that
command. Without one, the generator uses the map's fallback, a judgment/advisory item with no `verify`. Only
`lint_command` is verified; a `format_command` rewrites files, so it is not run as a check. A value that is
nothing but a `<placeholder>` (the preset catalog's unreplaced `<lint command>`) counts as not recorded, so the
item stays judgment/advisory instead of becoming a `confirm` item whose `verify` can never pass.

### `commit-format` is advisory

`commit-format` is `judgment` / `advisory`, and stays so. A `verify` command at `pre-commit` cannot see the commit
message being written, so a commit-message regex cannot be checked there (the evidence is in "Pre-commit timing
finding (E69_S05_T05)" below). The map keeps the regex check as a disabled alternative (`"enabled": false`, `confirm`
strength, needing a recorded `message_regex`); its `note` records why it stays disabled. The item text states that a
project commit format applies to non-board commits only, and that EST naming (`task(E##_S##_T##):`, `story(...)`,
`epic(...)`) stays required for board commits.

### Pre-commit timing finding (E69_S05_T05)

**Question.** Does the `pre-commit` checklist phase fire early enough that a `verify` command could test the commit
message about to be written? Epic E69 carried this as an open risk ("`pre-commit` fires before a commit message
exists"). It was settled from the code and proved by `tests/conventions-precommit-timing.bats`, which runs the real
`scripts/checklist.sh check pre-commit` and the real `hooks/on_preflight_check.sh` in a scratch git repository with
a machine item whose `verify` is a probe that tries every channel it has.

**What is visible at `pre-commit` time.**

- The `verify` runs as `bash -c <verify>` from the resolved project root, with stdin from `/dev/null`, **no
  arguments**, and the caller's own environment. The checker injects no `GIT_*` variable and nothing that carries
  a message.
- `.git/COMMIT_EDITMSG` exists once the repository has any commit, but it holds the **previous** commit's message:
  git writes the new one only when the commit itself runs, after the hook-time check.
- `git log -1` shows the previous commit.
- `hooks/on_preflight_check.sh` is shown the whole command (`git commit -m "<message>"`) in its `PreToolUse`
  payload, so the message is present in the hook's input. It uses the command only to decide whether the call is
  the phase's gated operation (a loose glob on `git*commit*`) and never hands it to `checklist.sh check`, which
  receives the phase and the run id only.
- `skills/j-commit/SKILL.md` fires `pre-commit` immediately before it runs `git commit`, and the message is
  composed as part of that command, so the gate fires first by construction.

**What is not visible.** The message being committed: not in the environment, not in `verify`'s arguments or stdin,
not in `.git/COMMIT_EDITMSG`, and not in `git log -1`. A `verify` that tested a regex against `git log -1
--format=%s` would test the previous commit.

**Consequence, applied through data only.** A commit-message regex machine item would check the wrong message, so
`commit-format` stays `judgment` / `advisory` in `templates/conventions-checklist-map.json`, and its
`message-regex-confirm` alternative stays `"enabled": false` (its `note` records the reason). No `confirm` item is
generated for a commit-message regex, so the generator's strength test needed no change. The commit-message check
that does exist is advisory and runs after the message is composed: `skills/j-commit/` runs
`skills/j-commit/scripts/commit-subject-check.sh "<subject>"` on a non-board subject (see "Agent consumption").
`scripts/checklist.sh` and `hooks/on_preflight_check.sh` are unchanged. Making the message visible to a `pre-commit`
check would need one of them to change (for example the hook forwarding the `-m` argument, or a git `commit-msg`
hook), which this epic puts out of scope.

### Quoting values in `verify`

A user-supplied value reaches a `verify` command only through the `{q:values.<field>}` placeholder, which wraps
the value in single quotes and rewrites each embedded `'` as `'\''`. The map wraps it as one argument
(`bash -c {q:values.lint_command}`), so a value can never end the quoted word it sits in. A `verify_template`
holding an unquoted `{summary}` or `{values.*}` placeholder is refused (exit `1`). Substitution is a single
pass: text that looks like a placeholder inside a value is never expanded. Note that the quoting stops a value
escaping its wrapper, it does not sandbox the user's own command: a legitimate `lint_command` such as
`npm run lint; npm run typecheck` runs as written.

### The validator extension

`scripts/validate-checklists.sh` accepts `provenance.source: "convention"` as a third source (`E69_S03_T01`),
requiring only a non-empty string `provenance.category`. Without it the checker, which validates the registry
before every `list` and `check`, would refuse a registry holding a generated item. Nothing else in the checker or
the hook changed.

### Worked example

A project records one convention in `<configs>/conventions.json`:

```json
{
  "conventions_version": 1,
  "categories": {
    "formatting-linting": {
      "source": "custom",
      "summary": "Prettier via the lint script",
      "values": { "approach": "prettier", "lint_command": "npm run lint" }
    }
  }
}
```

Running `scripts/generate-convention-checklist.sh --print` renders this item (the default invocation appends the
same item to `<configs>/checklists.json`, after the existing items):

```json
{
  "id": "conv-formatting-linting",
  "text": "The project's lint command passes on the working tree, per its formatting and linting convention: Prettier via the lint script.",
  "situations": ["pre-commit"],
  "kind": "machine",
  "verify": "bash -c 'npm run lint'",
  "enforcement": "confirm",
  "tick_scope": "run",
  "provenance": {
    "source": "convention",
    "category": "formatting-linting"
  }
}
```

`text` comes from the map's `text_template` with `{summary}` replaced, `verify` from `verify_template` with the
quoted `lint_command`, and the strength, situations and `tick_scope` straight from the map entry.


## Wizard flow

`j.conventions` (`skills/j-conventions/SKILL.md`) is the conversation; every deterministic step is a subcommand of
`skills/j-conventions/scripts/conventions-entry.sh` (`conventions-entry.sh --help` prints its full contract and is
authoritative). The skill never builds JSON, resolves a path or writes a file itself. It is **project layer
only**: there is one instance per project and no `--layer` option, so the wizard never asks where to write.

### The flow

1. **Start.** The wizard runs `categories --format json` (the 9 ids in schema order with their field lists),
   `detect` once for the whole session (its `warnings` are shown in one line; a failing `detect` is shown and the
   wizard continues with presets only), and `draft-init`. The draft is a temp file under `${TMPDIR:-/tmp}`, never
   inside the project, so cancelling at any point leaves no trace. `draft-init` seeds the draft from the recorded
   `conventions.json` when one exists (this is how a re-run pre-selects the recorded answers); an existing file
   that does not validate is refused with exit `4` and has to be fixed by hand first.
2. **One category at a time**, in schema order. The wizard shows a numbered choice: the detected standard first
   (only when `detected` is not null and `preset_only` is false, with its evidence and confidence verbatim; a
   detected value that equals a preset appears once, as the detected option), then the category's 2 or 3
   presets, then **Skip (record nothing)**, then **Other (describe below)** last. A recorded answer is marked
   `(current answer)` and is the default. The answer is recorded only through `draft-set` (`--source
   detected|preset|custom`) or `draft-skip`. A preset value that is still a bare `<placeholder>` (for example
   `<lint command>`) is a template, not an answer: the wizard asks for the real command, drops an optional field
   with `--unset`, or offers Skip; the script refuses the placeholder anyway. For `commit-format` the wizard says
   first that EST naming stays mandatory for board commits (see "EST commit naming").
3. **Validate every input as it is given.** A typed value goes through `check <category> <field> "<value>"`,
   which runs the real `scripts/validate-conventions.sh` on a one-category probe and prints `{"valid": true}` or
   `{"valid": false, "reason": ...}`. `draft-set` validates the whole resulting document before applying
   anything: on refusal it exits `1`, the reason is on stderr and the draft is byte-identical. Values are one
   line each, and `block` is never offered or accepted.
4. **Review, with go-back.** `draft-diff --format text` and `draft-show` present every category and what changed
   against the recorded file (`+` added, `-` removed, `~` changed, `=` unchanged), the file that will be written
   (`path`), and the choice to change any category (re-running step 2 for it), write, or cancel. Nothing has been
   written yet at this point.
5. **Write atomically.** `commit --draft <path>` validates the draft, takes `scripts/with-lock.sh` on the
   instance, writes a candidate beside it and renames it over `conventions.json` (skipped when the draft records
   exactly what is there), runs `scripts/generate-convention-checklist.sh`, and validates both
   `conventions.json` and the checklist registry. Only then does it print the success JSON
   (`{"ok":true,"action":"commit","path","registry","changed","categories","generator"}`) and remove the draft. If
   the generator or a validation fails it restores the previous `conventions.json` (or removes it when there
   was none) and the previous registry, prints the failing validator's lines on stderr, prints no success line,
   and keeps the draft so the wizard can offer retry or go-back.
6. **Self-validate, then report.** The skill runs `scripts/validate-conventions.sh <path>` and
   `scripts/validate-checklists.sh <registry>` itself and reports success only when `commit` said `"ok": true`
   and both exit `0`. The report names what was recorded, changed or removed and the generated `conv-` items
   (advisory or confirm, never blocking).

### Exit codes of `conventions-entry.sh`

`0` success (`check` also exits `0` for an invalid value; the verdict is in its JSON), `1` precondition failed or
an input refused by `draft-set`, `2` usage, `3` `jq` or `python3` missing, `4` the existing instance, the draft
or the written result failed validation, `5` the configs path could not be resolved, `6` `commit` could not
acquire the lock (nothing written), `7` the checklist generator failed (previous files restored).

### Re-running

Running the wizard again starts from the recorded answers: `draft-init` seeds the draft from `conventions.json`,
the categories the user leaves alone are carried over unchanged in content, and an unchanged `commit` leaves
`conventions.json` and `checklists.json` byte-identical (the generator is idempotent, see "Idempotence").

### Where the wizard is suggested

`scripts/conventions-suggest.sh` prints one line, `Tip: run j.conventions to record this project's conventions
(commit format, naming, formatting, ...).`, when `<configs>/conventions.json` does not exist, and nothing when it
does. It always exits `0` and swallows every error, so it can never change the outcome of the skill that calls it.
`skills/j-init/SKILL.md` runs it at the end of `j.init` and `skills/j-uncharted/SKILL.md` at the end of
`j.uncharted onboard`, as a non-blocking tip: neither skill waits for an answer or starts the wizard itself.

## EST commit naming

**The rule (epic E69, Decision 2).** EST naming (`task(E##_S##_T##):`, `story(...)`, `epic(...)`) stays mandatory
for every board commit, because `/reconcile` finds a task's work through those subjects. A `commit-format`
convention applies to non-board commits only (chores, docs, any change with no board item) and can never
override, loosen or replace EST naming, whatever its `style`, `message_regex` or `subject_max_length` say.

**Where it is enforced.** The rule is held by data and scripts, not by trusting the convention text:

- **The detector** skips EST board subjects when sampling commits, so a project's EST-heavy history does not
  make it look like a custom commit style (the evidence reports how many were excluded).
- **The wizard** says the rule before offering the `commit-format` options.
- **The generated item** `conv-commit-format` states in its text that the convention is for non-board commits
  and EST naming stays required for board commits.
- **The digest** always ends with a fixed `EST:` line (emitted by `scripts/conventions-digest.sh` itself, not read
  from the file), so a recorded `commit-format` can never remove or contradict it.
- **`skills/j-commit/SKILL.md`** classifies each commit as board or non-board. A board commit is EST naming,
  unchanged. For a non-board commit it runs `conventions-digest.sh --agent commit`, writes the message in the
  recorded format, and self-checks the subject with `skills/j-commit/scripts/commit-subject-check.sh "<subject>"`.
  That script reports `kind=board` (exit `0`, the convention is not even read) for a subject that starts with
  `task(`, `story(` or `epic(` or whose leading scope names a board id, so even a hostile `message_regex` cannot
  affect a board commit. For a non-board subject it checks the recorded `message_regex` (POSIX ERE) and
  `subject_max_length`: exit `1` means rewrite and re-check, and a missing, unreadable or invalid conventions
  file means "no applicable convention" (exit `0`).
- **The developer and `j-commit`** both state that a `commit-format` convention never changes EST naming.

**Advisory only, by timing.** `commit-format` is advisory and no commit-message regex check runs at `pre-commit`:
that phase fires before any message exists (the evidence is in "Pre-commit timing finding (E69_S05_T05)"). The
only message check is the self-check above, which runs on a message the agent already composed and gates
nothing.

## Agent consumption

Agents read the recorded conventions through one script, so none of them parses the JSON.
`scripts/conventions-digest.sh [--agent developer|tester|scrum-master|commit] [--conventions <file>]` prints a
plain-text digest of at most 30 lines (lines are capped at 220 characters):

```
Project conventions (<N> recorded; explicit, set through j.conventions):
<category-id>: <summary> [<key>=<value>; ...] (checklist item conv-<category-id>)
Precedence: the conventions above are explicit and beat inference from the codebase; infer only for categories not listed.
EST: board commits keep the mandatory task(E##_S##_T##): / story(...) / epic(...) naming; a recorded commit-format convention applies to non-board commits only.
... <N> more categories omitted
```

- **Nothing to say, nothing printed.** With no `conventions.json`, an unresolvable configs path or an empty
  `categories`, it prints nothing and exits `0`, so callers can embed it unconditionally and behave exactly as
  before. An invalid file prints nothing on stdout, the validator's lines on stderr, and exits `1`.
- **`--agent` only reorders.** The named agent's categories come first and the rest follow in schema order:
  `developer` naming, code-comments, formatting-linting, file-layout, language-tooling; `tester` testing,
  formatting-linting; `scrum-master` documentation-placement, file-layout, branching; `commit` commit-format,
  branching. Only the 30-line cap drops categories (the lowest priority first), and it says so on the last line.
- **`Precedence:` and `EST:` are fixed lines** printed whenever any convention is recorded. A bare `<placeholder>`
  value is never printed as a recorded value, exactly as the generator treats it.

### Who calls it, and what changes

| Caller | Call | Effect |
|---|---|---|
| Developer (`agents/developer.md`, Codebase exploration) | `--agent developer` | **Explicit conventions beat inference.** The developer follows every convention listed, notes a disagreement in the execution summary instead of overriding it, and infers style from the codebase only for categories not listed (or when the digest is empty). |
| Tester (`agents/tester.md`) | `--agent tester` | Applies the `testing` convention when writing or placing tests and `formatting-linting` as findings criteria. A violated `advisory` convention is a remark (`Passed with remarks`), never a `Failed` on its own; a failed `confirm` item follows the existing checklist semantics. |
| Scrum Master (`agents/scrum-master.md`) | `--agent scrum-master` | Places documentation deliverables (and their `docs` and `needs_docs`) per `documentation-placement`, and respects `file-layout` and `branching` in task text. This repository's own rule (documentation under `project/documentation/`) is the default here and is not changed by a recorded convention. |
| `j-commit` (`skills/j-commit/SKILL.md`) | `--agent commit` | Shapes non-board commit messages only; see "EST commit naming". |

### Precedence

A recorded convention is explicit and beats the developer's inference from the codebase. This replaces the
developer's former "pure inference". Only `conventions.json` is authoritative: a value that the detector found
but the user did not confirm in the wizard is a hint, never a convention. Hand edits to a generated `conv-` item
do not change a convention: edit the convention (through the wizard or `conventions.json`) and the next
generator run rewrites the item.

## Scripts index

| Path | Role |
|---|---|
| `templates/conventions-schema.json` | Machine-readable file format: categories, field specs, strength values. |
| `templates/conventions.json` | Shipped generic default: `{"conventions_version": 1, "categories": {}}`. |
| `templates/conventions-presets.json` | The preset catalog the wizard offers (2 or 3 per category). |
| `templates/conventions-checklist-map.json` | Per category: the item text, situations, kind, enforcement and `verify` template the generator renders. |
| `templates/config-descriptors/conventions.json` | Lists `conventions.json` read-only in `jenga config` (the wizard writes it, never `jenga config`). |
| `scripts/validate-conventions.sh` | Validates an instance (or `--presets` a catalog); rejects `block`. |
| `skills/j-conventions/scripts/detect-conventions.sh` | Read-only detection of the standard each category already follows. |
| `skills/j-conventions/scripts/conventions-entry.sh` | The wizard's deterministic backend (draft, per-input checks, atomic commit). |
| `scripts/generate-convention-checklist.sh` | Renders, merges and removes the managed `conv-` checklist items. |
| `scripts/conventions-digest.sh` | The agent digest. |
| `scripts/conventions-suggest.sh` | The non-blocking "run j.conventions" tip. |
| `skills/j-commit/scripts/commit-subject-check.sh` | The board/non-board classifier and advisory subject self-check. |

## Out of scope

- **No user layer.** Conventions are a project-layer file only (epic Decision 5); there is no
  user-level file and no `--layer` option.
- **Five deferred categories.** Error handling and logging, dependency policy, security hygiene, review and PR
  rules, and release and versioning are not categories in v1. Adding one follows "Extending the categories".
- **No change to the checker or the hook.** `scripts/checklist.sh` and `hooks/on_preflight_check.sh` are
  unchanged; generated items are ordinary registry items. `scripts/validate-checklists.sh` gained only the
  `convention` provenance source ("The validator extension").
- **No blocking enforcement.** `block` is never legal in `conventions.json` and never generated.
- **No commit-message gate.** The commit-message check is an advisory self-check, not a `pre-commit` gate.
- **No instance in this repository.** This repository records none, because `project/configs` ships downstream
  via `/j-mirror-public`.
