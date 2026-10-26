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
   `/reconcile` relies on it. A `commit-format` convention shapes non-board commits only, **unless the project has
   explicitly opted in** (epic `E79`; see "Commit template fields and the opt-in `commit-trace` category"). No commit
   path honours the opt-in yet.

The checker (`scripts/checklist.sh`) and the hook (`hooks/on_preflight_check.sh`) are unchanged by this feature.

Where to read next: **Schema** (the file format, including the commit template and opt-in settings of epic `E79`),
**Detection output**, **Checklist generation**, **Wizard flow**,
**EST commit naming**, **Agent consumption**, **Scripts index**, **Out of scope**. Each section was written by the
story that built the part it describes; where a section and the script it describes disagree, the script is
right and this document is the bug.

### The 9 categories at a glance

| Id | Covers | Detector (`detect-conventions.sh`) | Checklist item | Situations | Strength |
|---|---|---|---|---|---|
| `commit-format` | Commit message format, non-board commits only (board commits too, for a project that opted in) | last 50 non-board subjects, commitlint config | `conv-commit-format` | `pre-commit` | advisory |
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

v1 has exactly these 9 core category ids, plus the opt-in `commit-trace` (see "Schema vocabulary" and "Commit template
fields and the opt-in `commit-trace` category"). An unknown id is invalid. A category **absent** from `categories`
means "skipped / no convention recorded".

| Id | Meaning | Required `values` field | Optional `values` fields |
|---|---|---|---|
| `commit-format` | Commit message format (non-board commits only unless the project opts in, see below) | `style` (string) | `message_regex` (string), `subject_max_length` (integer), and the `E79` fields `template`, `ref_source`, `ref_pattern` (strings), `on_unresolved` (string), `apply_to_board_commits` (boolean) |
| `branching` | Branching model | `model` (string) | `branch_pattern` (string), `default_branch` (string) |
| `naming` | Identifier, file and type naming | `identifier_case` (string) | `file_case` (string), `type_case` (string) |
| `code-comments` | Code comments and docs-in-code | `policy` (string) | `public_api_docs_required` (boolean), `doc_comment_style` (string) |
| `formatting-linting` | Formatting and linting | `approach` (string) | `format_command` (string), `lint_command` (string), `editorconfig` (boolean) |
| `testing` | Testing expectations | `expectation` (string) | `test_command` (string), `test_dir` (string) |
| `file-layout` | File and directory layout | `layout` (string) | `source_dir` (string), `test_dir` (string) |
| `language-tooling` | Language and tooling | `version_policy` (string) | `runtime` (string), `package_manager` (string), `lockfile_committed` (boolean) |
| `documentation-placement` | Where documentation lives | `policy` (string) | `public_docs_dir` (string), `internal_docs_dir` (string) |
| `commit-trace` (opt-in) | Commit-to-task traceability | none | `mode` (string), `trailer_key` (string) |

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

### Schema vocabulary: field-spec properties and opt-in categories

The validator understands a few optional properties on a `values` field spec and one optional top-level schema
key. **The shipped schema adopts them in `E79_S03_T04`**, for the `commit-format` template fields and the opt-in
`commit-trace` category described in the next section; no other category uses them. The script header of
`scripts/validate-conventions.sh` is the contract's source; where this section and the script disagree, fix this
section. A malformed spec makes the schema fail to load (exit `1`, naming the schema file and the field), never
a silent ignore.

| Spec property | On | Rule |
|---|---|---|
| `enum` | `string` fields | Non-empty array of unique, non-empty strings. Any other value is rejected, naming the path and the allowed list (`not an allowed value`). |
| `reserved` | `string` fields | Object mapping a value to a note. The value is rejected with a message that contains the note (`reserved value: <path> is "x" - reserved for ...`), distinct from the not-allowed message. A value may not be in both `enum` and `reserved`. |
| `max_length` | `string` fields | Positive integer; a longer value is rejected (`too long`). |
| `pattern` | `string` fields | A regular expression the whole value must match (`bad format`). It must compile. |
| `default` | any field | The value an absent field takes. It must satisfy the field's own type, `non_empty`, `single_line`, `enum`, `reserved`, `max_length` and `pattern`, checked when the schema is loaded. The validator never writes a default into a file; consumers read it. |

**Opt-in categories.** The schema may carry a top-level `opt_in_categories` object shaped like `categories`. A
category declared there is recorded in a project's file under `categories.<id>`, exactly like a core one, and is
validated by the same entry checks (`source`, `preset`, `summary`, `values`, and the `block` prohibition at any
depth). It differs from a core category in two ways only: it is **exempt from the preset-catalog rule** (`--presets`
neither requires presets for it nor applies the 2 to 3 count bound, but still validates any preset a catalog gives
it), and it is **not part of the core list** that the wizard, detector, preset catalog and digest enumerate. An id
declared in both `categories` and `opt_in_categories` is a schema error, and an "unknown category" message lists the
core ids first and then the opt-in ones.

### Commit template fields and the opt-in `commit-trace` category (epic E79, story E79_S03)

Epic `E79` lets a project record a commit subject template such as `{ref} {summary}` and a traceability mode, and
lets it apply both to **board commits**. Two separable settings, both opt-in and both default-off:

- **Format.** The `commit-format` category gains five optional fields; the central one is `template`.
- **Traceability.** The opt-in `commit-trace` category records how a commit maps back to its Jenga task. The default
  mode is the `Jenga-Task: <id>` trailer, for the reasons in "Decision record" below.

Phase 1 (story `E79_S03`) **stores, validates, summarises and resolves** these settings. It does not make any commit
use them: see "What this phase does not do". The single implementations are:

| Concern | Single implementation |
|---|---|
| Template grammar, derived regex, length budget, bounded match | `scripts/commit-template.sh` |
| Whether a project is opted in, and every effective value | `scripts/commit-settings.sh` |
| Write-time validation of the file | `scripts/validate-conventions.sh`, driven by `templates/conventions-schema.json` |

No other script re-implements the grammar, the opt-in rule or a default. The schema is **data**; where a rule is a
property of a field (type, `enum`, `reserved`, `max_length`, `default`) the validator reads it from there.

#### New optional `commit-format` fields

The existing `style` (required), `message_regex` and `subject_max_length` are unchanged, and so is the schema's
`applies_to` wording (see "What this phase does not do"). Every new field is optional, and each default below is the
`default` in `templates/conventions-schema.json`; the validator never writes a default into a file, consumers read it
(`scripts/commit-settings.sh`).

| Field | Type | Rule | Default |
|---|---|---|---|
| `template` | string | Single line, non-empty, at most 80 characters, and valid under the closed grammar below. The single source of truth for the subject format (default form `{ref} {summary}`); the regex and length budget are **derived** from it, never stored. | none (absent means no template) |
| `ref_source` | string | One of `chain`, `external_refs`, `perceived_branch`. `prompt` is **reserved** (planned for `E79_S07`) and is rejected as `reserved for a later phase`. Which source resolves a ref, and in what order, is the job of `E79_S04`; today only the validator and `commit-settings.sh` read this field. | `chain` |
| `ref_pattern` | string | Single line, non-empty, at most 100 characters, an ERE with no back-reference that cannot match the empty string. | `[A-Z][A-Z0-9]+-[0-9]+` |
| `on_unresolved` | string | Phase 1 allows only `fail`; any other value is rejected, and the message names the phase. | `fail` |
| `apply_to_board_commits` | boolean | The explicit opt-in that applies the convention to board commits. This is the `E69` Decision 2 reversal, confirmed for opted-in projects only (epic `E79`, Open Decision 10). | `false` |
| `subject_max_length` (existing) | integer | Without a template: any integer, as before. **With** a template: 20 to 200, because the derived budget needs room for the prefix. | none (see the effective-settings subsection) |

`message_regex` is never reinterpreted, rewritten or combined with the template. An entry may carry both; the regex
keeps its old meaning, for non-board commits.

#### The template grammar and what is derived from it

A template is literals plus two placeholders, and **the template is data, never shell**:

- `{summary}` exactly once, `{ref}` at most once.
- Literals are limited to an allowlist: ASCII letters, digits, space and `- _ : . , / # ( ) [ ] @`. Anything else is
  rejected with a message naming the character and its 1-based position: that includes `$`, the backtick, `;`, `|`,
  `&`, `<`, `>`, the backslash, both quote characters, `*`, `?`, `^` and `+`, as well as newline, tab and every other
  control character.
- Also rejected, each with its own message: an empty template, one over 80 characters, any `{...}` other than the two
  placeholders, an unbalanced `{` or `}`, `{summary}` missing or repeated, `{ref}` repeated.
- The template is read one character at a time and only compared, counted and appended to a string. It is never
  handed to a shell, a command substitution, a dynamic-evaluation builtin or the `source` builtin.

`commit-template.sh derive` turns a template into three lines, computed on every call and stored nowhere, so a stored
regex can never disagree with its template:

| Output | Meaning |
|---|---|
| `regex=` | An anchored POSIX ERE. Literals are escaped by a fixed table, `{ref}` becomes the capture group `(<ref_pattern>)` (always group 1), `{summary}` becomes a fixed class: a first character that is neither a control character nor whitespace, then any run of non-control characters. It is run only through bash `[[ =~ ]]` or `grep -E`, both non-backtracking for everything the grammar allows. |
| `prefix_length=` | Length of the rendered literals plus the ref. Without `--ref` it assumes the longest ref allowed (64). |
| `max_summary_length=` | The maximum length minus `prefix_length`, never below 0. The default maximum is 72, or the project's `subject_max_length`. |

For `{ref} {summary}` with the defaults that is `prefix_length=65` and `max_summary_length=7` without `--ref`, and
`8` and `64` with `--ref ASD-001`. `match <template> <subject>` exits `0` when the subject conforms and otherwise `1`
with one reason on stdout: `too-long`, `no-match` or `summary-over-budget`.

**Bounded matching.** Every limit is checked before the regex runs:

| Limit | Value | Effect |
|---|---|---|
| Template | 80 characters | Longer is an invalid template. |
| Subject | 200 characters | `match` returns `too-long` without running the regex. |
| Ref | 64 characters (`[A-Za-z0-9._/-]`) | A `--ref` value over it is refused; a ref captured by a match over it is `no-match`. |
| Ref pattern | 100 characters | Also non-empty, single line, no back-reference, compiles as an ERE and cannot match the empty string. |
| Maximum length | 1 to 200 | `--max-length`; a project's `subject_max_length` with a template is 20 to 200. |

Lengths are counted in bytes (`LC_ALL=C`), the conservative direction for a non-ASCII subject. Exit codes of
`commit-template.sh`: `1` no match, `2` usage, `3` invalid template, `4` invalid option value, `5` internal error.
The script's header is the contract's source.

#### `commit-trace` (opt-in)

Declared under the new top-level schema key `opt_in_categories`, not under `categories`, so the 9 core categories,
the preset catalog, the wizard list, the detector, and the digest's category lines are unchanged. In a project's file
it is recorded at `categories.commit-trace`. Both fields are optional.

| Field | Type | Rule | Default |
|---|---|---|---|
| `mode` | string | **A setting, not hard-coded.** Only `trailer` is usable today. `external-key`, `topology` and `ledger` are **reserved** (planned for `E79_S08`) and rejected as `reserved for a later phase`. | `trailer` |
| `trailer_key` | string | Only `Jenga-Task`, in Phase 1. The shared commit resolver (`E79_S02`) and `est_provenance` (`E79_S06`) read exactly that key, so a configurable key would silently break tracing. | `Jenga-Task` |

A `commit-trace` entry does **not** opt a project in. Opt-in is decided by `commit-format` alone (next subsection), so
a `commit-trace` entry without the opt-in flag is **inert**: `commit-settings.sh` and the digest ignore it, and no
commit changes. (When the project *is* opted in, `commit-settings.sh show` takes `trace_mode` and `trailer_key` from the
entry, or from the schema defaults when there is none.) It is accepted and validated like any other entry, and one
thing still reads it even when inert: the checklist generator renders its advisory reminder (see "Effect on the digest
and on the generated checklist").

**No board ids in the shipped schema.** The reserved notes say `reserved for a later phase` and name no story: the
schema ships to consumers and `tests/conventions-no-leak.bats` (no-leak 6) allows a board id only inside a `_comment` or
`note` key. The stories that will use the reserved values (`E79_S07`, `E79_S08`) are named here, in the maintainer
documentation, instead. The rejection reads, for example,
`reserved value: categories.commit-trace.values.mode is "ledger" - reserved for a later phase`.

#### What "opted in" means, and effective settings (`scripts/commit-settings.sh`)

`scripts/commit-settings.sh` is the **only** place that decides whether a project is opted in and what its effective
commit settings are, so no consumer re-implements the defaults or the rule. It is read-only, runs
`scripts/validate-conventions.sh` first, and needs `jq`.

```
commit-settings.sh [--conventions <file>] opted-in     exit 0 opted in, 1 not opted in, 2 usage, 3 invalid file
commit-settings.sh [--conventions <file>] show         nothing when not opted in; else the effective settings
```

- **Opted in** means the file records the commit-format category with a non-empty `template` **and**
  `apply_to_board_commits: true`. Nothing else opts a project in. A template without the flag, a `commit-trace` entry
  on its own, an empty `categories`, an absent file or an unresolvable configs path is "not opted in": exit 1
  (`opted-in`) or empty output (`show`), silently. That is the legacy path and it stays silent. A file that carries the
  flag without a template is rejected by the validator ("requires template"), so it exits 3.
- **`show`** prints seven `key=value` lines in a fixed order: `template`, `ref_source`, `ref_pattern`, `on_unresolved`,
  `trace_mode`, `trailer_key`, `subject_max_length`. Each value is the recorded one or, when absent, the schema field's
  `default`, read from `templates/conventions-schema.json` (or `JENGA_CONVENTIONS_SCHEMA`) at run time; the script holds
  no copy of any default. An opted-in project with **no** `commit-trace` entry therefore resolves to
  `trace_mode=trailer` and `trailer_key=Jenga-Task`: the trailer is the default value of a setting, not a hard-coded
  mode. The two categories are found by the schema field they declare (`template`, `trailer_key`), not by id.
- **`subject_max_length` default.** The schema gives this field no `default`, and its field spec is deliberately left
  as it is (the legacy `entry categories` output is byte-identical for default-off projects). When a project has not
  recorded it, `show` prints the budget `scripts/commit-template.sh` itself derives with when no `--max-length` is given
  (read by asking that script about a template that is only `{summary}`, so the number is never copied): `72` today. A
  default declared in the schema for this field, if one is ever added, wins over that fallback.
- **Reading the output.** The values are data. Callers read them with `read` (split at the first `=`) or `jq`, and never
  `source` or evaluate the output. A setting with neither a recorded value nor a schema default makes the script exit 3
  with a message naming it, rather than print a hole.
- **Exit 3** also covers an invalid or unreadable conventions file; the validator's lines go to stderr and the script never
  exits 0 or 1 in that case.
- The file is located like the digest does (`scripts/resolve-root.sh get configs`, `JENGA_PROJECT_ROOT` honoured;
  `--conventions <file>` overrides).

#### Write-time validation of the new settings

Beyond the per-field checks the schema drives (type, `enum`, `reserved`, `max_length`, single line),
`scripts/validate-conventions.sh` applies these cross-field rules to `commit-format` values, in an instance and in a
preset catalog alike. The rules are selected by the schema field a category declares (`template`), not by its id. Every
problem in a file is reported, and each message names the JSON path:

| Rule | Behaviour |
|---|---|
| Template validity | The template is passed to `scripts/commit-template.sh validate` as one argument of an argv list (no shell), and that script's message is reported as `invalid template: <path> - <reason>`. The validator never parses the grammar; a NUL character is reported without launching anything. |
| Dependent fields | `ref_source`, `ref_pattern`, `on_unresolved` and `apply_to_board_commits` are rejected with `requires template` when no `template` is recorded. `apply_to_board_commits: true` together with a template is the opt-in. |
| `ref_pattern` | No back-reference (a backslash then a digit), must compile as a POSIX ERE (checked with `grep -E` through argv), at most 100 characters (the schema `max_length`), and, once the template is valid, accepted by `commit-template.sh derive`, so a pattern the commit path would refuse (for example one that can match the empty string) is refused when it is written. |
| `on_unresolved` | Only `fail`. The rejection is the schema's `not an allowed value` message with `Phase 1 accepts only "fail"` appended. |
| `ref_source` | `prompt` is rejected as `reserved for a later phase` (it is planned for `E79_S07`). |
| `subject_max_length` | With a template recorded it must be an integer from 20 to 200 (`out of range`). Without a template the rule is unchanged (any integer). |
| `message_regex` | Never reinterpreted or rewritten. It validates exactly as before. |
| `commit-trace` | `mode` and `trailer_key` follow the schema: `trailer` (or absent) passes, `external-key`, `topology` and `ledger` are rejected as `reserved for a later phase` (planned for `E79_S08`), `trailer_key` must be `Jenga-Task`. The standard entry rules (`source`, `summary`, `values`, no `block` strength) apply. The category has no opt-in flag of its own; an entry on its own is accepted and inert. |

The reserved and phase messages deliberately name no board id (see "No board ids in the shipped schema" above), so
they say "a later phase" and "Phase 1"; the stories they refer to are named in this document. A project with none of
the new keys pays nothing: no subprocess runs and the output is unchanged.

#### Effect on the digest and on the generated checklist

**Digest** (`scripts/conventions-digest.sh`, called with any `--agent`). For an opted-in project, and only then, two
lines follow the fixed `EST:` line (see "Agent consumption"):

```
Commit format (opt-in): template '{ref} {summary}', ref_pattern [A-Z][A-Z0-9]+-[0-9]+, on_unresolved fail; board commits follow the template; trace: trailer via 'Jenga-Task'
EST override: this project opted in (commit-format.apply_to_board_commits=true); the EST line above applies to projects without the opt-in.
```

The values come from `commit-settings.sh show`; the digest holds no copy of the opt-in rule or a default and prints
each value as data. The `EST override:` line is what tells an agent that the `EST:` line above it describes the
default, not this project. The two lines are budgeted like the fixed lines and are never dropped, so an opted-in
project's line cap has a minimum of 7. If the settings cannot be resolved the digest exits 3 and prints nothing on
stdout. `commit-trace` never gets a category line of its own and does not count towards "N recorded"; a file that
records only `commit-trace` prints nothing at all. A project that is not opted in gets exactly the output it always had.

**Generated checklist items** (`scripts/generate-convention-checklist.sh`, map `templates/conventions-checklist-map.json`).
The map carries two additions, in new sections so the existing `categories` table keeps matching the schema's:

| Item | When | Situation | Kind | Enforcement |
|---|---|---|---|---|
| `conv-commit-format`, template variant | `commit-format` records a `template` (opted in or not) | `pre-commit` | judgment | advisory |
| `conv-commit-trace` | `commit-trace` is recorded (opted in or not) | `pre-commit` | judgment | advisory |

The template variant replaces the item's text: it names the template and says board commits follow it **only when**
`apply_to_board_commits` is true, otherwise EST naming stays required for them. Without a template the original text
is generated, byte for byte. Both items are advisory and judgment on purpose: a `pre-commit` check cannot see the
message being written (see "Pre-commit timing finding (E69_S05_T05)"), so the template cannot be machine-verified
there. The generator iterates the core categories first and the opt-in ones after, and does not consult the opt-in
rule, so `conv-commit-trace` is rendered whenever the entry is recorded; the strength rule (never `block`) holds for
both.

#### What "default-off is unchanged" means

A project that records no `template` and no `commit-trace` is unchanged in the following precise sense: the output of
the validator, the digest and the checklist generator is **byte-identical for every valid default-off input, and every
exit code is unchanged**. What does change is *error text that enumerates the allowed keys or categories*: an "unknown
key in values" message for `commit-format` now lists the five new field names, and an "unknown category" message lists
`commit-trace` after the nine core ids. That is an intended consequence of the schema change (the lists are generated
from the schema), not a regression. Six legacy goldens in `tests/fixtures/conventions-legacy-golden/` carry exactly
these enumerations (`entry-categories-json`, `validate-invalid`, `digest-invalid`, `generate-print-invalid`,
`entry-check`, `entry-write-flow-rejections`) and were regenerated for it in a reviewed diff. A seventh,
`entry-presets-unknown`, was regenerated when `conventions-entry.sh` learned the opt-in categories: its
unknown-category message now lists `commit-trace` after the nine core ids, and the same appended token changed one line
in each of `entry-check` and `entry-write-flow-rejections` (already among the six). The other 57 are pinned byte for
byte by `tests/conventions-commit-format.bats`.

#### Decision record (epic E79, answered 2026-10-25)

Epic `E79` carries ten Open Decisions. Three were answered by the project owner on **2026-10-25** and are recorded
here, as they are on the epic ("Decisions answered after breakdown"). The remaining decisions (3 to 9) were still open
when this was written; nothing here answers them.

| # | Question | Answer (2026-10-25) |
|---|---|---|
| 1 | Does "Jenga id preferably not in the message" mean the subject only, or the body too? | **Subject and body.** The Jenga id should preferably appear in neither. The trailer is therefore a justified last resort, not the sanctioned design. |
| 2 | Is the trailer acceptable as the durable default for opted-in projects? | **Yes.** The default is the `Jenga-Task: <id>` trailer. |
| 10 | Is `E69` Decision 2 reversed only for opted-in projects? | **Confirmed.** `E69` Decision 2 (EST naming is mandatory for board commits; `commit-format` applies to non-board commits only) is reversed for opted-in projects only. A project that has not opted in keeps EST naming and byte-identical behaviour. |

**The tension between Decisions 1 and 2, stated openly and not resolved.** The two answers pull in opposite
directions. The trailer puts the Jenga id in the commit body, which Decision 1 says the owner would rather avoid.
Decision 2 accepts it as the default only because the solution assessment (section 6C of
`project/documentation/plans/solution-assessment-project-specific-commit-conventions.md`) found **no id-free mapping
that survives a rebase, an amend, a cherry-pick, a squash, a fresh clone and a shallow CI checkout**: a durable
mapping exists only when the identifier is stored inside the commit object. The owner's preference for an id-free
message therefore **stands, and the default does not meet it**.

Two consequences are built into this phase:

1. **The trace mode is a setting, not hard-coded.** `commit-trace.mode` defaults to `trailer` (key `Jenga-Task`) and
   the id-free mode names are reserved by the schema, so a project that prefers an id-free message can choose one
   once it exists, without a schema change. This is implemented by `E79_S03` and resolved in one place,
   `scripts/commit-settings.sh`.
2. **`E79_S08` is the route for id-free modes.** It is not only a contingency for a hostile client: it delivers the
   reserved modes (`external-key`, `topology`, and an optional ledger), each with a documented, tested horizon and a
   loud failure when the horizon is exceeded. It is decomposed only after the `E79_S01` client fact sheet is filled in.

#### What this phase does not do

- **No commit uses the template yet.** The composer, the subject check and the developer's commit path arrive in
  `E79_S05`; `j.commit` and `skills/j-commit/scripts/commit-subject-check.sh` are unchanged. Recording a template and
  the opt-in flag today changes the validator's verdict, the digest and the generated checklist items, and nothing else:
  a board commit is still made with EST naming.
- **The EST rule and the `applies_to` wording are amended by `E79_S06`.** The section "EST commit naming" below, the
  schema's `applies_to` string for `commit-format` ("non-board commits only: EST naming ... stays mandatory for board
  commits"), and the other scope-defining locations still state the `E69` rule in its original wording. That is
  accurate for every project that has not opted in and is out of date for one that has; `E79_S06` amends `E69`
  Decision 2 in all of them together. Until then, read "EST commit naming" as the default-off behaviour and the
  `EST override:` digest line as the opted-in exception. One concrete case: that section says the digest "always ends
  with" the fixed `EST:` line; for an opted-in project the two `Commit format (opt-in)` and `EST override` lines follow
  it.
- **No ref is resolved.** `ref_source`, `ref_pattern` and `on_unresolved` are validated and summarised; the chain that
  turns them into a ref for a commit is `E79_S04`.
- **No wizard prompt and no detection.** The detector, the preset catalog and the wizard's category list are
  unchanged (`E79_S06`, `E79_S07`); `commit-trace` and the new fields are recorded through the backend (see "Recording
  an opt-in category") or by hand.
- **No id-free trace mode.** `external-key`, `topology` and `ledger` are rejected at write time until `E79_S08`.

#### The commit ref safety gate (`scripts/commit-ref.sh`, epic E79, story E79_S04)

A commit ref (a tracker key such as `ASD-001`) can come from a board file or from a git branch name, so it is untrusted
text on its way into a commit message (solution assessment Problem 19, branch-derived ref injection).
`scripts/commit-ref.sh validate` is the one place that decides whether a string may be used as a ref. The ref resolution
chain and the commit composer route every candidate through it; nothing else re-implements the check.

```
printf '%s\n' "$candidate" | scripts/commit-ref.sh validate [--pattern <ere>] [--conventions <file>]
```

The candidate is read from **stdin only**: a positional argument is a usage error, and the script has no dynamic
execution (no `eval`, no `sh -c`). A ref passes only when all of these hold:

1. it is not empty, and is a single line (one trailing line feed is tolerated, nothing else);
2. it is at most **64** characters, the ref-length cap `scripts/commit-template.sh` already enforces (read from that
   script, not written a second time);
3. every byte is one of `A-Z a-z 0-9 . _ / -`, so a space, quote, `;`, `$`, backtick, `|`, `&`, `>`, a newline, a
   carriage return, a NUL or any other control byte fails here, whatever the pattern says;
4. it **fully** matches the ref pattern (anchored at both ends, one regex call), so `ASD-001-extra` fails against the
   default pattern.

On success the ref is printed unchanged and the exit status is 0. Otherwise nothing is printed on stdout, one reason line
(which never repeats the candidate) goes to stderr, and the exit status is:

| Exit | Meaning |
|---|---|
| 0 | the candidate passes |
| 2 | usage error |
| 3 | the candidate is rejected |
| 4 | the pattern cannot be used: a bad `--pattern`, an invalid or unreadable `conventions.json`, or no pattern available. Never a pass. |

**Which pattern.** `--pattern` wins; otherwise the project's `ref_pattern` from `commit-settings.sh show` (the recorded
value, or the schema default, for an opted-in project); otherwise the schema default, read with
`commit-settings.sh default ref_pattern`. The default is never written in `commit-ref.sh`, and
`JENGA_CONVENTIONS_SCHEMA` redirects it. A pattern is accepted only by `commit-template.sh`'s own pattern check
(non-empty, at most 100 characters, one line, no back-reference, compiles as an ERE, does not match the empty string).

**Restricting `ref_pattern`.** The stored pattern stays as the validator accepts it (it is data and is only ever run by
the regex engine, never executed). The restriction applies where the value is used: the allowlist in point 3 is an upper
bound on what any pattern, however permissive (`.*` included), can let through. A pattern can narrow what passes, never
widen it past the allowlist.

**`commit-settings.sh default <field>`.** A new read-only subcommand that prints the schema's default for a field,
whether or not the project is opted in, reading no conventions file. Exit 3 when the schema declares no such field or no
default. `opted-in` and `show` are unchanged.

#### Finding the ref in a branch name (`commit-ref.sh extract`, task E79_S04_T02)

```
printf '%s' "$branch" | scripts/commit-ref.sh extract [--pattern <ere>] [--conventions <file>]
```

`extract` reads one branch name from **stdin** (the user's perceived branch, for example `feature/ASD-001-foo`; Jenga
task branches are named `E##_S##_T##-slug` and carry no key, so the caller decides which branch to pass) and prints the
**first** ref in it. A branch name is untrusted data, so it is never a positional argument (that is a usage error) and
never placed in a command string. The pattern is chosen exactly as for `validate`.

| Exit | Meaning |
|---|---|
| 0 | a ref was found and passed `validate`; exactly one line is printed |
| 1 | the name holds no ref (`main`, `develop`, `release/2.4`, `HEAD`, an empty input). Nothing is printed; this is "no key", not an error |
| 2 | usage error |
| 3 | the input is rejected: over the cap, a control byte in it (an embedded newline, a carriage return, a NUL), or the found text failed `validate`. One reason line on stderr, nothing on stdout |
| 4 | the pattern cannot be used, or the input cap cannot be read |

How it stays safe and bounded:

1. At most **200** characters are accepted, the subject cap `commit-template.sh` enforces (read from that script, not
   written again); longer input is rejected before the pattern is applied to it.
2. One trailing line feed is tolerated. Any other control byte means the input is not a branch name (git refnames cannot
   contain one), so it is rejected rather than split into lines.
3. One regex call, the pattern held in a variable and wrapped as
   `(start or a non-alphanumeric byte)(pattern)(a non-alphanumeric byte or end)`; no loop over candidates. POSIX
   leftmost-longest picks the first key.
4. **Token boundary:** a key must be preceded by the start of the name or a non-alphanumeric character, and followed by
   the end or a non-alphanumeric character. `feature/ASD-001-foo`, `bugfix/ASD-001` and `user/jo/ASD-001_wip` yield
   `ASD-001`; `fix/xASD-001` and `fix/ASD-0011x` yield nothing.
5. With several keys (`ASD-001-and-ASD-002`) the first wins and the rest are ignored without an error.
6. The found text is piped through `validate` with the same pattern before it is printed, so even a permissive custom
   pattern can never print a value outside the `validate` allowlist.

#### Permissive ref patterns, and why `ref_pattern` is not restricted at write time (task E79_S04_T03)

`ref_pattern` is stored as the user wrote it, so a project can record a very permissive one (`.+`, `[^ ]+`, a class
holding `;` and a space). The question left open by `E79_S03` was whether the write-time validator should refuse such
patterns. **Decision (2026-10-26): no, it does not.** The use-time gate already neutralises them, shown by
`tests/commit-ref-pattern-safety.bats`:

- **Whatever the pattern, a printed ref is one line, at most 64 characters, from `A-Za-z0-9._/-`.** The allowlist and the
  cap are applied by `commit-ref.sh validate` after the pattern, and `extract` pipes what it finds through `validate`.
  Hostile branch names (shell metacharacters, quotes, `$(...)`, backticks, spaces) give exit 3 and nothing on stdout;
  control bytes give exit 3 too. A pattern's own text is data: shell syntax inside it runs nothing.
- **Patterns that can match the empty string are already refused,** at write time by `validate-conventions.sh` and at use
  time by `commit-template.sh` (exit 4, "must not match the empty string"). `.*`, `^`, `$`, `x*` and `x?` therefore never
  produce an empty ref and are not treated as "no ref".
- **A pattern that matches a whole name longer than 64 characters is rejected** (exit 3), not truncated.
- **Backtracking-prone patterns** (`(a|aa)+$`, `(a+)+$`, `(.*)*x`) against a 200-character name finish well inside 5
  seconds; extract's input cap (200) and validate's read cap (66 bytes) bound the work.
- **An alternation cannot step over the boundary rule of `extract`:** the pattern sits inside its own group, so
  `foo|ASD-1` does not find `foo` inside `xfoo`, and `A|AB` finds nothing in `ABC`.

What the gate does **not** promise is a shape. It promises an alphabet and a length, so under a permissive pattern a ref
such as `--amend`, `-` or `../../etc/passwd` is accepted by `validate` (the default pattern rejects all three). A consumer
must therefore put the ref inside message text and never pass it alone as an argv word.

Restricting the pattern at write time is not needed for safety and was not done: it would change validator behaviour (and so need its own
task, tests and a check of the legacy goldens) for no added protection. If earlier feedback is wanted, a separate task could reject patterns that
are obviously too loose (for example a bare `.+`) with a warning in the wizard; that is a usability choice, not a safety one.

#### The per-task commit ref store (`scripts/task-commit-ref.sh`, epic E79, story E79_S04)

Commits 1..n of one task must carry the same ref even when the sources it was resolved from (a board file, the user's
branch) change mid-task. The developer's sender object cannot be the only carrier, because the agent composes it per
call, so `scripts/task-commit-ref.sh` keeps one JSON file per task that the sender field and the commit composer both
read. It stores two things: the **branch candidate**, captured once when the worktree is created (the task branch
`E##_S##_T##-slug` never carries the key; the user's perceived branch does), and the **frozen ref**, set write-once by the
ref resolver. It is neutral to precedence and to the unresolved-ref policy: it stores the outcome the resolver hands it.

```
task-commit-ref.sh capture-branch <task-id> --branch <name> [--candidate <ref>]
task-commit-ref.sh freeze         <task-id> --ref <value> --source task|story|epic|branch [--conflict <text>]...
task-commit-ref.sh get            <task-id> [--field ref|source|candidate]
task-commit-ref.sh clear          <task-id>
```

- **Where.** `<queue>/commit-refs/<task-id>.json`, where `<queue>` is `scripts/resolve-root.sh --strict get queue`
  (never a hardcoded `project/` path; `JENGA_PROJECT_ROOT` redirects it). It follows the working directory's project
  tree, so a developer inside a task worktree uses a worktree-local store: run every call for one task from the same
  place. Fields: `task_id`, `branch_candidate`, `branch`, `captured_at`, `ref`, `source`, `frozen_at`, `conflicts`.
- **Git-ignored on purpose.** The store is per-machine working state, like `project/queue/handoffs/*.json`, not history.
  `.gitignore` lists the whole `project/queue/commit-refs/` directory (not only `*.json`), so the temp files and
  `.lock.d` lock directories of the script cannot be committed by accident either. The public mirror already blocks
  `project/queue/` in `.publicignore`, so it needs no entry of its own. A project that relocates `paths.queue` needs a
  matching ignore entry, as for the other queue files.
- **`capture-branch`** records the ref found in the branch name. The candidate comes from `commit-ref.sh extract` (the
  branch is sent on stdin) unless `--candidate` supplies an already-extracted value; either way it must pass
  `commit-ref.sh validate` before it is written. A branch with no key records `branch_candidate: null` and exits 0 (the
  unresolved decision is made later, by the resolver). It is idempotent: once captured, a second call changes nothing.
- **`freeze`** validates `--ref` through the safety gate before anything is written, then stores it. It is **write-once**:
  the same ref again exits 0 and changes nothing, a different ref exits 4 and leaves the file untouched. That is what
  keeps commits 1..n in agreement, whatever a later capture or an edited board file says.
- **`get`** prints the frozen ref (or its `source`, or the captured `candidate`) and **re-validates it on every read**,
  so a hand-edited or corrupted file exits 3 and prints nothing.
- **Safety.** The task id becomes a file name and must match `E##_S##_T##` (anything else is exit 2 and creates nothing).
  Refs and branch names travel through argv and stdin only, never a shell string. The validator is the one in
  `commit-ref.sh`; this script adds none. Writes are atomic (temp file in the same directory, then `mv`) and run under
  `scripts/with-lock.sh`, so of two concurrent freezes with different refs exactly one wins and the other exits 4. A
  symlinked store directory or file is refused (exit 6). Requires `jq`.

| Exit | Meaning |
|---|---|
| 0 | success (including the identical repeat of `freeze` and a repeated `capture-branch`) |
| 1 | `get`: nothing frozen or captured |
| 2 | usage error, including a task id that is not `E##_S##_T##` |
| 3 | rejected by the safety gate, or the store file is corrupted or hand-edited |
| 4 | `freeze`: a different ref is already frozen; the file is untouched |
| 5 | a dependency is unavailable: `jq`, the working-file root, the safety gate, or an extractor |
| 6 | the store could not be written, was refused (symlink), or the lock could not be taken |

#### Capturing the ref when a task worktree is created (`scripts/create-task-worktree.sh`, task E79_S04_T09)

The task branch (`E##_S##_T##-slug`) never carries the Jira key; the user's branch does (for example
`feature/ASD-001-foo`). So the key is captured **at worktree creation**, not read from the task branch later, and it
survives the user switching branches mid-task. `scripts/create-task-worktree.sh` (called by the `WorktreeCreate` hook and
by `agents/developer.md`) does this after the worktree exists and **only for an opted-in project**
(`commit-settings.sh opted-in` exits 0):

1. take the task id from the start of `<name>` (`E##_S##_T##`); a name without it is not a task worktree and is skipped silently;
2. ask `perceived-branch.sh get` (with the same `--session` the script already passes) for the branch the user is working on,
   which is the perceived branch when one is set and exists, otherwise the real checked-out branch;
3. run `task-commit-ref.sh capture-branch <task-id> --branch <branch>`.

The script's contract does not change: stdout stays exactly one line (`<dir>`) and only on success, everything the capture
prints goes to stderr, and the exit status is untouched. A capture failure (no key in the branch records
`branch_candidate: null` and is not a failure; a missing `task-commit-ref.sh`, an unwritable store or a detached HEAD is a
stderr notice) never fails or delays the worktree. Deciding what an unresolved ref means is the resolver's job, later, with a
message naming the sources tried. A project that is not opted in (`commit-settings.sh` missing, not opted in, or `opted-in`
exiting non-zero for any reason, including an invalid `conventions.json`) takes the unchanged path: the same stdout, stderr,
exit status and git state, and nothing is created under the queue directory. The branch name is only ever an argv value.

The script runs in the main working tree, so the store is written under the **main tree's** queue directory
(`resolve-root.sh get queue`). A reader running inside the task worktree resolves that worktree's own project tree unless
`JENGA_PROJECT_ROOT` points at the main tree, so readers must use the same root as the writer. Tests:
`tests/create-task-worktree-ref-capture.bats`.

#### Resolving the ref (`scripts/resolve-commit-ref.sh`, epic E79, story E79_S04)

`resolve-commit-ref.sh <task-id> [--conventions <file>] [--on-conflict warn|fail]` walks the settled chain and reports what
it found. It only **collects and reports**: it does not freeze the winner (the store does) and it does not decide what
"nothing found" means for the run (decision 5, `fail`). It does apply the disagreement policy described below.

- **Order.** The `external_refs` Jira key of the task, then its story, then its epic (decision 7: a key identifies one
  imported board item at any level, so tasks inherit; the story and epic ids come from the task id and the task's own
  `story_id` / `epic_id` frontmatter), then the branch candidate captured at worktree creation, read with
  `task-commit-ref.sh get --field candidate`. The task's own branch name is never consulted.
- **`ref_source`.** `chain` (the default) uses all four levels, `external_refs` the board levels only, `perceived_branch`
  the captured candidate only (the board is not opened).
- **Every candidate** goes through `commit-ref.sh validate` with the effective `ref_pattern`; a rejected one is not a
  candidate and a notice on stderr names the level, never the value.
- **Output** (stdout, `key=value` lines to be read with `read` or `jq`, never sourced): `ref=`, `source=task|story|epic|branch`,
  `tried=` (every level consulted, in order) and a `candidate.<level>=` line per level with a valid candidate. The winner is
  the first level in the fixed order. With no winner only `tried=` is printed.
- **Disagreement (decisions 7 and 8).** Any two valid keys with different values are a conflict, including two different
  Jira entries on one level (that level disagrees with itself). A key an item inherits is never a conflict (decision 7: a
  key identifies one imported board item, so several tasks sharing it is normal); only levels linked separately that carry
  different keys disagree. The policy is `--on-conflict`; the default is the constant `DEFAULT_ON_CONFLICT` in the script,
  set to `warn`. It is a flag and not a `conventions.json` setting, so the schema and the legacy goldens are untouched.
  - `warn` (default): one `warning: the sources disagree (...); continuing with X from <level>` line on stderr per
    invocation, exit 0, and one `conflict=<level>:<key>` line on stdout for every valid key that differs from the winner,
    after the lines above (for example task `ASD-001` and story `ASD-002` print `conflict=story:ASD-002`). Each line is a
    ready value for `task-commit-ref.sh freeze --conflict`.
  - `fail`: exit **7**, no `ref=` or `source=`; stdout is `tried=` plus a `conflict=` line for every valid key (the winner's
    too), and stderr names the same levels and keys. With no disagreement it behaves exactly as `warn`. The code is 7, not
    5, because 5 already means "dependency unavailable".
- **Not opted in.** A project without the commit template prints nothing and exits 10 before any board path is resolved.

| Exit | Meaning |
|---|---|
| 0 | a winner exists |
| 1 | no level produced a valid candidate ("unresolved"); only `tried=` is on stdout |
| 2 | usage error, including a task id that is not `E##_S##_T##` |
| 3 | the settings cannot be used (invalid conventions file, unknown `ref_source`, unusable `ref_pattern`) |
| 5 | a dependency is unavailable |
| 7 | a disagreement under `--on-conflict fail`; no winner is printed (never returned by the default `warn`) |
| 10 | not applicable: the project is not opted in; stdout is empty |

#### Applying the unresolved-ref policy (`scripts/apply-ref-policy.sh`, epic E79, story E79_S04)

`apply-ref-policy.sh [--check] [--conventions <file>] [--root <dir>] <task-id>` is the thin wrapper that turns the resolver's
outcome into the run-level contract. Phase 1 has exactly one policy, `on_unresolved: fail` (the schema enum has one value):
an opted-in task whose ref cannot be resolved stops **before its first commit**, with no prompt, no silent fallback to EST
naming and no placeholder ref, in interactive and unattended (`j.jenga *`) runs alike. A different policy would be a schema
change and a new task; the script has no code path that substitutes a ref.

- **Resolved:** the resolver's `key=value` lines are printed unchanged (the wrapper parses no line except `tried=`, so extra
  lines and any order are fine), exit 0.
- **Not opted in:** nothing is printed, exit 0, and no board file is opened.
- **Unresolved:** nothing on stdout, exit 6, and one message on stderr: `no commit ref could be resolved for <task-id>; sources
  tried: task external_refs, story external_refs, epic external_refs, captured branch candidate (<branch or none>);
  on_unresolved=fail`, followed by how to fix it (link a Jira key with `scripts/link-external-ref.sh`, or create the task from a
  branch that carries one). The sources come from the resolver's `tried=` list (so `ref_source` shapes it) and the branch name
  from the store; nothing comes from the environment.
- **Policy check:** the effective `on_unresolved` is read from `commit-settings.sh show`; anything but `fail` is exit 7, and the
  resolver is not run.
- **Never interactive:** no `read`, no terminal device, every child runs with stdin from `/dev/null`; the result is the same with
  stdin closed, from `/dev/null` or from an open pipe. `--check` gives the same stdout, stderr and exit codes and guarantees that
  nothing is written, so a pre-flight can report tasks that will have no ref before work starts. Wiring it into `/do` or `/jenga`
  is not part of this task.
- **Task worktrees:** the branch candidate is stored under the **main** tree's queue, while the settings, board and store follow
  the current project root. From inside a task worktree, pass `--root <main working tree>` (or set `JENGA_PROJECT_ROOT`); the
  wrapper never redirects on its own, and when it runs in a linked worktree with neither set, the unresolved message says so.

| Exit | Meaning |
|---|---|
| 0 | resolved, or not opted in (nothing printed) |
| 2 | usage error |
| 3 | settings unusable (passed on) |
| 5 | a dependency is unavailable, or the resolver broke its contract |
| 6 | unresolved under `on_unresolved=fail`; stdout empty, message on stderr |
| 7 | the effective `on_unresolved` is not `fail` |

Tests: `tests/apply-ref-policy.bats`.

#### The developer entry point (`scripts/prepare-task-commit-ref.sh`, task E79_S04_T10)

`prepare-task-commit-ref.sh [--on-conflict warn|fail] [--conventions <file>] [--root <dir>] <task-id>` is the one script the
developer calls, once per task and before its first commit, so `agents/developer.md` only calls scripts. It adds no resolution
logic: it runs `commit-settings.sh opted-in`, then `task-commit-ref.sh get`, then `apply-ref-policy.sh`, then
`task-commit-ref.sh freeze`, and prints `key=value` lines to be read with `read` or `jq`, never sourced.

- **Not opted in:** nothing printed, nothing created, exit 0 (the default-off guarantee, in one place).
- **Already frozen:** prints `commit_ref=<ref>` and `source=<level>` and exits 0 without re-resolving, so a second call is a no-op
  and commits 1..n agree even if the board or the branch changed. Only the call that froze prints the `conflict=` lines.
- **Resolved:** the ref is frozen (write-once) and printed as `commit_ref=`, `source=` and one `conflict=<level>:<key>` line per
  recorded disagreement. Note the output key is `commit_ref=`, not the resolver's `ref=`.
- **Unresolved:** exit 6, `apply-ref-policy.sh`'s message on stderr, empty stdout, nothing frozen. No prompt, no EST fallback.
- **Disagreement:** `--on-conflict warn` (the default, decision 8) freezes the precedence winner and records the others;
  `--on-conflict fail` stops with exit 8 and freezes nothing. `apply-ref-policy.sh` does not forward the flag, so this script
  reads the resolver's own `conflict=` lines instead of comparing keys itself.
- **Task worktrees:** the captured branch candidate lives under the **main** tree's queue, so from inside a task worktree call
  `prepare-task-commit-ref.sh --root <main working tree> <task-id>` (or set `JENGA_PROJECT_ROOT`) every time; the freeze then goes
  to the same store. There is no automatic redirection.

| Exit | Meaning |
|---|---|
| 0 | ready (lines on stdout), or not opted in (nothing on stdout) |
| 2 | usage error |
| 3 | settings unusable, or the safety gate or the store rejected the ref or its file (passed on) |
| 4 | freeze conflict: a different ref is already frozen (passed on) |
| 5 | a dependency is unavailable, or a called script broke its contract |
| 6 | unresolved under `on_unresolved=fail` (passed on) |
| 7 | the effective `on_unresolved` is not `fail` (passed on) |
| 8 | the sources disagree and `--on-conflict fail` was given; nothing frozen (new; the task text said 5, which means "dependency unavailable") |
| 9 | the store could not be read, written or locked (new; the store's own 6, renamed so 6 keeps meaning "unresolved") |

Tests: `tests/prepare-task-commit-ref.bats`.

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
category (the detector `E69_S02` and the generator map `E69_S03`). An **opt-in** category goes under
`opt_in_categories` instead and, to produce a checklist item, under the map's `opt_in_categories`; it needs no presets.

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

Two additions come from epic `E79` and live in separate sections of the map (`opt_in_alternatives`,
`opt_in_categories`), so the table above keeps matching the schema's core categories: a template variant of
`conv-commit-format` and a new advisory item `conv-commit-trace`, both `judgment` / `advisory` at `pre-commit`; see
"Effect on the digest and on the generated checklist".

`formatting-linting` is `confirm` only when the convention recorded a `lint_command`: its `verify` runs that
command. Without one, the generator uses the map's fallback, a judgment/advisory item with no `verify`. Only
`lint_command` is verified; a `format_command` rewrites files, so it is not run as a check. A value that is
nothing but a `<placeholder>` (the preset catalog's unreplaced `<lint command>`) counts as not recorded, so the
item stays judgment/advisory instead of becoming a `confirm` item whose `verify` can never pass.

### `commit-format` is advisory

`commit-format` is `judgment` / `advisory`, and stays so, with or without a `template`. A `verify` command at `pre-commit` cannot see the commit
message being written, so a commit-message regex cannot be checked there (the evidence is in "Pre-commit timing
finding (E69_S05_T05)" below). The map keeps the regex check as a disabled alternative (`"enabled": false`, `confirm`
strength, needing a recorded `message_regex`); its `note` records why it stays disabled. Without a `template`, the item text states that a
project commit format applies to non-board commits only, and that EST naming (`task(E##_S##_T##):`, `story(...)`,
`epic(...)`) stays required for board commits. With a `template` recorded, a variant text names the template and says
board commits follow it only when `apply_to_board_commits` is true, otherwise EST naming stays required for them.

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

### Recording an opt-in category (`commit-trace`)

The wizard flow above covers the 9 core categories; it asks nothing about an opt-in category. The backend still
accepts one, so it can be recorded and shown without a hand edit. `conventions-entry.sh` resolves a category id
through the schema's `categories` first and `opt_in_categories` second (no id is named in the script), and then:

- `draft-set commit-trace --draft <path> --source custom --summary "<text>" --value mode=trailer` records it. Values are
  typed from the schema (`coerce_value`, so `apply_to_board_commits=true` on `commit-format` is a JSON boolean) and the
  whole candidate document goes through `scripts/validate-conventions.sh` before the draft changes. A refusal (an
  invalid template, a reserved `mode`, `on_unresolved=park`) exits `1`, prints the validator's message and leaves the
  draft byte-identical, exactly as for a core category.
- `draft-skip`, `draft-show --category`, `draft-diff`, `commit` and `show --category` accept the id the same way; `check
  commit-trace <field> "<value>"` validates one value.
- Written files and `draft-diff` keep opt-in categories **after** the core ones, in schema order; `normalize_doc` never
  drops a schema-declared id.
- `categories` (both formats) and `presets` for a core id are unchanged. `presets commit-trace` prints `[]`, a one-line
  note on stderr and exits `0`: an opt-in category has no presets.
- The checklist generator iterates the core categories **and then the opt-in ones**, so recording `commit-trace` adds
  one advisory item, `conv-commit-trace` (see "Effect on the digest and on the generated checklist"); `commit-trace`
  itself has no presets and the wizard never prompts for it.

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
Commit format (opt-in): template '<template>', ref_pattern <p>, on_unresolved <u>; board commits follow the template; trace: <mode> via '<key>'
EST override: this project opted in (commit-format.apply_to_board_commits=true); the EST line above applies to projects without the opt-in.
... <N> more categories omitted
```

The two `Commit format (opt-in)` and `EST override` lines are printed **only for an opted-in project** (epic `E79`, see
"Effect on the digest and on the generated checklist"); for every other project the block ends at `EST:` exactly as
before. The `EST:` line is therefore the default-off rule, and the `EST override:` line is how a reader learns it does
not describe an opted-in project.

- **Nothing to say, nothing printed.** With no `conventions.json`, an unresolvable configs path or an empty
  `categories`, it prints nothing and exits `0`, so callers can embed it unconditionally and behave exactly as
  before. An invalid file prints nothing on stdout, the validator's lines on stderr, and exits `1`.
- **`--agent` only reorders.** The named agent's categories come first and the rest follow in schema order:
  `developer` naming, code-comments, formatting-linting, file-layout, language-tooling; `tester` testing,
  formatting-linting; `scrum-master` documentation-placement, file-layout, branching; `commit` commit-format,
  branching. Only the 30-line cap drops categories (the lowest priority first), and it says so on the last line.
- **`Precedence:` and `EST:` are fixed lines** printed whenever any convention is recorded (the two opt-in lines are
  fixed too, and are the only ones that depend on `commit-settings.sh`). A bare `<placeholder>`
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
| `templates/conventions-schema.json` | Machine-readable file format: categories, `opt_in_categories` (`commit-trace`), field specs (including the `E79` template fields and their defaults), strength values. |
| `templates/conventions.json` | Shipped generic default: `{"conventions_version": 1, "categories": {}}`. |
| `templates/conventions-presets.json` | The preset catalog the wizard offers (2 or 3 per category). |
| `templates/conventions-checklist-map.json` | Per category: the item text, situations, kind, enforcement and `verify` template the generator renders; plus `opt_in_categories` and `opt_in_alternatives` for `commit-trace` and the template variant of `conv-commit-format`. |
| `templates/config-descriptors/conventions.json` | Lists `conventions.json` read-only in `jenga config` (the wizard writes it, never `jenga config`); its `categories` description mentions the commit template fields and `commit-trace`. |
| `scripts/validate-conventions.sh` | Validates an instance (or `--presets` a catalog); rejects `block`. Understands the optional spec properties `enum`, `reserved`, `default`, `max_length`, `pattern` and the schema's `opt_in_categories` (see the schema vocabulary section). |
| `skills/j-conventions/scripts/detect-conventions.sh` | Read-only detection of the standard each category already follows. |
| `skills/j-conventions/scripts/conventions-entry.sh` | The wizard's deterministic backend (draft, per-input checks, atomic commit). |
| `scripts/generate-convention-checklist.sh` | Renders, merges and removes the managed `conv-` checklist items. |
| `scripts/conventions-digest.sh` | The agent digest; for an opted-in project it adds the `Commit format (opt-in)` and `EST override` lines, with every value taken from `commit-settings.sh`. |
| `scripts/conventions-suggest.sh` | The non-blocking "run j.conventions" tip. |
| `skills/j-commit/scripts/commit-subject-check.sh` | The board/non-board classifier and advisory subject self-check. |
| `scripts/commit-template.sh` | `validate`, `derive` and `match` for a commit-format `template` (epic `E79`): a closed grammar of literals plus `{ref}` and `{summary}`, the regex and length budget derived from it (never stored), a bounded match. The template is data, never shell. Exit codes: 1 no match, 2 usage, 3 invalid template, 4 invalid option value. Contract in the script's header. |
| `scripts/commit-settings.sh` | `opted-in`, `show` and `default <field>`: the only place that decides whether a project is opted in to the commit template and what its effective settings are (recorded value, else the schema default); `default` prints a schema default with no conventions file. Read-only; exit 0/1 for `opted-in`, 2 usage, 3 invalid file or no such default. Contract in the script's header. |
| `scripts/commit-ref.sh` | `validate`: the one safety gate every candidate commit ref must pass (stdin only, allowlist `A-Za-z0-9._/-`, at most 64 characters, full match against the ref pattern). Exit 0 passes, 2 usage, 3 rejected, 4 unusable pattern. `extract`: finds the first ref in a branch name read from stdin (token-bounded, at most 200 characters, the found text goes through `validate`); exit 1 means no key. See "The commit ref safety gate" and "Finding the ref in a branch name". Contract in the script's header. |
| `scripts/task-commit-ref.sh` | `capture-branch`, `freeze`, `get` and `clear`: the per-task store that captures the branch candidate and freezes the resolved ref write-once, so commits 1..n of a task agree. Refs pass through `commit-ref.sh validate` on write and on every read; the store is git-ignored working state under the resolved queue directory. Exit 0 ok, 1 nothing frozen, 2 usage, 3 rejected or corrupted, 4 freeze conflict, 5 dependency unavailable, 6 write, symlink or lock failure. See "The per-task commit ref store". |
| `scripts/resolve-commit-ref.sh` | Walks the ref chain for one task (the task's, story's and epic's `external_refs` Jira key, then the captured branch candidate), validates every candidate, and prints `ref=`, `source=`, `tried=` and `candidate.<level>=` lines. Collects and reports only: no freeze. `--on-conflict warn` (default) warns once on stderr and prints `conflict=<level>:<key>` lines on a disagreement; `fail` exits 7. Exit 0 found, 1 none found, 2 usage, 3 settings unusable, 5 dependency unavailable, 7 disagreement under `fail`, 10 not opted in. See "Resolving the ref". |
| `scripts/apply-ref-policy.sh` | Applies the Phase 1 unresolved-ref policy on top of the resolver: passes the `key=value` lines through when a ref is found, prints nothing for a project that is not opted in, and otherwise exits 6 with a message naming the sources tried (`on_unresolved=fail`: no prompt, no EST fallback, no placeholder ref). Exit 7 for any other policy value; `--check` writes nothing. Never reads stdin. See "Applying the unresolved-ref policy". |
| `scripts/prepare-task-commit-ref.sh` | The single developer entry point: not opted in prints nothing (exit 0); a frozen ref is returned without re-resolving; otherwise runs `apply-ref-policy.sh`, freezes the winner write-once and prints `commit_ref=`, `source=` and `conflict=` lines. `--on-conflict warn` (default) or `fail` (exit 8); `--root <main tree>` from a task worktree. Exit 0 ready or not opted in, 2 usage, 3 rejected, 4 freeze conflict, 5 dependency or broken contract, 6 unresolved, 7 policy not `fail`, 8 disagreement under `fail`, 9 store unusable. See "The developer entry point". |

## Out of scope

- **No user layer.** Conventions are a project-layer file only (epic Decision 5); there is no
  user-level file and no `--layer` option.
- **Five deferred categories.** Error handling and logging, dependency policy, security hygiene, review and PR
  rules, and release and versioning are not categories in v1. Adding one follows "Extending the categories".
- **No change to the checker or the hook.** `scripts/checklist.sh` and `hooks/on_preflight_check.sh` are
  unchanged; generated items are ordinary registry items. `scripts/validate-checklists.sh` gained only the
  `convention` provenance source ("The validator extension").
- **No blocking enforcement.** `block` is never legal in `conventions.json` and never generated.
- **No commit-message gate.** The commit-message check is an advisory self-check, not a `pre-commit` gate. The same
  holds for the `E79` template: it cannot be machine-verified at `pre-commit`.
- **No commit uses the `E79` template yet**, and the EST rule is not yet amended for opted-in projects: see "What this
  phase does not do".
- **No instance in this repository.** This repository records none, because `project/configs` ships downstream
  via `/j-mirror-public`.
