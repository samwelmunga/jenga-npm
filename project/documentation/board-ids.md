# Board IDs

Reference for how scrum-board IDs (`E##`, `E##_S##`, `E##_S##_T##`) are shaped, parsed, ordered and allocated now
that they are width-agnostic (epic `E86`). The sections are written by different stories of the epic, each owning
one section so that no two stories edit the same lines.

## Decisions

Taken in the `E86` brainstorm with the user. Do not reopen without the user.

1. **No renaming, no migration.** Existing two-digit files (`E01` to `E99`, and story and task numbers) are never
   renamed, and no migration, doctor or conversion step exists or is required. The only upgrade step for a consumer
   is installing the new parsers (upgrade-and-go).
2. **No padding contract going forward.** The minimum width is two digits and there is no maximum. New epics are
   simply `E100`, `E101`, ... `E1001`; never pre-pad to `E0100`. An ID's width is whatever its number needs, and
   `E01` and `E1001` are both valid at the same time.
3. **All parsing is width-agnostic.** Every parser matches `E\d+`, `S\d+` and `T\d+`, whatever the digit count.
4. **All ordering compares numeric value.** Every ordering compares the numeric value of each ID segment, never the
   filename text. Lexically `E100_` sorts before `E10_` and `E11_`, and `E1001_` before `E2_`.
5. **Stories and tasks may exceed 99.** `S100` and `T100` are valid; this is in scope for every story of the epic.
6. **The fuzzy-ID grammar is revised, with explicit user approval.** Explicit letters or separators are required for
   values of three or more digits (`e100s2` works), and bare ambiguous digit runs such as `10002` become invalid. The
   unambiguous two-digit-chunk shorthand keeps working wherever it is unambiguous today.
7. **Fixture rule.** When fixing a missed hit, a test fixture that copies a migrated script must also copy
   `scripts/lib`. That is fixture setup only: it never goes into an assertion, and parsers get no fallback regexes
   (a missing shared source is an error, not a silent return to a two-digit-only guard).

Related invariants kept from the brainstorm: `E10` is a string prefix of `E100`, so a lookup by `glob("E10_*")` or
`find -name "E10_*"` is safe only because of the trailing underscore, and an unanchored substring match on an ID
(`grep E10`, `*$id*`) is a bug class to avoid. Update the places that state or enforce the contract; do not churn
cosmetic mentions of `E##_S##_T##`.

**Rejected option: renaming the existing files to a wider padded form.** About 1,900 existing files would have been
renamed (for example `E01` to `E0001`) for a purely cosmetic gain. It was rejected on **cost**, not policy: there is
no repo rule forbidding renames. Nothing is renamed.

## Shared pattern source

### Home

Board-ID shapes are defined once, in two twin files that `tests/board-ids-parity.bats` keeps in agreement against
`tests/fixtures/board-id-cases.txt`:

| File | Language | Use from |
|---|---|---|
| `scripts/lib/board_ids.py` | Python 3, standard library `re` only | Python, and shell scripts that embed Python |
| `scripts/lib/board-ids.sh` | bash 3.2 ERE strings | shell (`[[ $x =~ $RE ]]`, `grep -E`) |

`scripts/lib/` ships in the npm package through the existing `scripts/` entry of `package.json` `files`, and neither
file is in `.publicignore`. Both are silent when imported or sourced and set no shell options. Rules shared by both:
any digit width parses (`E1`, `E01`, `E100`, `E0100`), IDs are case-sensitive (`E`, `S`, `T` uppercase), anchored
patterns accept no trailing newline or junk, and the two-digit minimum is a generation rule, not a parsing rule.

### API

Python (`board_ids`):

- Unanchored fragments for embedding in larger patterns: `EPIC_FRAGMENT`, `STORY_FRAGMENT`, `TASK_FRAGMENT`,
  `ANY_FRAGMENT`, `STORY_OR_TASK_FRAGMENT`, `PREFIX_FRAGMENT`.
- Anchored, compiled (`re.ASCII`, end anchor `\Z`): `EPIC_ID_RE`, `STORY_ID_RE`, `TASK_ID_RE`, `BOARD_ID_RE` (any of
  the three).
- File and reference variants: `PLAN_RE`, `SUMMARY_RE` (group 1 is the story or task ID), `TODO_REF_AT_END_RE`.
- Optional project-code prefix variants (used by the board-graph extractor): `PREFIXED_EPIC_ID_RE`,
  `PREFIXED_STORY_ID_RE`, `PREFIXED_TASK_ID_RE`, `PREFIXED_TARGET_REF_RE`, `PREFIXED_TODO_REF_RE`.
- `classify(id)` returns `"epic"`, `"story"`, `"task"` or `None` (also `None` for a non-string).

Shell (`board-ids.sh`):

- `BOARD_ID_EPIC_RE`, `BOARD_ID_STORY_RE`, `BOARD_ID_TASK_RE`, `BOARD_ID_ANY_RE`: anchored (`^...$`) ERE strings,
  to be used unquoted on the right of `=~` and quoted as the pattern argument of `grep -E`.
- `BOARD_ID_EPIC_FRAGMENT`, `BOARD_ID_STORY_FRAGMENT`, `BOARD_ID_TASK_FRAGMENT`, `BOARD_ID_ANY_FRAGMENT`: unanchored.
- `board_id_kind <id>` prints `epic`, `story` or `task` and returns 0, or prints nothing and returns 1 when malformed.

Malformed IDs stay rejected: `E`, `E1_`, `E01_T01`, lowercase, and trailing junk.

### Caller snippets

Snippets for a script run from a project root (the monorepo root, or a consumer project root). They use the usual
`[ -f scripts/x ] && echo ... || echo node_modules/@jenga-ai/agent/...` resolution idiom. All four were run in both
layouts when this section was written.

Shell:

```bash
BOARD_IDS_SH="$([ -f scripts/lib/board-ids.sh ] && echo scripts/lib/board-ids.sh || echo node_modules/@jenga-ai/agent/scripts/lib/board-ids.sh)"
. "$BOARD_IDS_SH"
board_id_kind E100_S2_T1                       # prints: task
[[ E1001 =~ $BOARD_ID_EPIC_RE ]] && echo epic  # prints: epic
board_id_kind E01_T01 || echo malformed        # prints: malformed
```

Python:

```python
import os, sys
sys.path.insert(0, "scripts/lib" if os.path.isfile("scripts/lib/board_ids.py")
                else "node_modules/@jenga-ai/agent/scripts/lib")
import board_ids
board_ids.classify("E1001")                    # 'epic'
board_ids.STORY_ID_RE.match("E100_S100")       # match object
board_ids.classify("E01_T01")                  # None
```

Consumer layout: the package is installed at `node_modules/@jenga-ai/agent/`, so the same two files are at
`node_modules/@jenga-ai/agent/scripts/lib/`. Both snippets above fall through to that path when `scripts/lib/...` is
absent from the project root.

### How the migrated callers resolve it

A shipped script cannot assume the current directory is the project root, so the migrated callers resolve the
library from their own location, and none of them has a fallback regex when it is missing:

| Caller | Resolution |
|---|---|
| `scripts/validate-board.sh` | `$(dirname "${BASH_SOURCE[0]}")/lib` handed to the embedded Python as `JENGA_BOARD_IDS_LIB`; exits 2 if the import fails |
| `scripts/e25_s01_extract_board_graph.py`, `scripts/e25_s01_generate_synthetic_board.py` | `Path(__file__).resolve().parent / "lib"` on `sys.path` |
| `skills/index/scripts/board_index.py` | `Path(__file__).resolve().parents[3] / "scripts" / "lib"` (the same relative layout holds in the `.claude/`, `.agents/` and `node_modules/@jenga-ai/agent/` copies) |
| `skills/jenga/scripts/cascade-resolve.sh` | candidate loop: `$SCRIPT_DIR/../../../scripts/lib`, then `$SCRIPT_DIR/../../../node_modules/@jenga-ai/agent/scripts/lib`; error if neither has `board_ids.py` |
| `skills/j-close-story/scripts/check-story-closeable.sh`, `extract-task-diff-stats.sh` | candidate loop: script-relative `scripts/lib`, then `$PROJECT_ROOT/node_modules/@jenga-ai/agent/scripts/lib`, then `$PROJECT_ROOT/scripts/lib`; error if none has `board-ids.sh` |
| `skills/j-uncharted/scripts/validate-proposed-items.sh`, `scripts/task-usage.sh` | `$VALIDATOR_ROOT/lib/board-ids.sh` and `$_TU_DIR/lib/board-ids.sh` (next to the script's own `scripts/` directory); error if absent |

### Sweep for remaining two-digit assumptions (task `E86_S01_T07`)

Run after `E86_S01_T02` to `E86_S01_T06`, from the repository root. `.claude/`, `.agents/` and `node_modules/` are
excluded (the first two are generated mirrors of the root directories).

```bash
X='--exclude-dir=node_modules --exclude-dir=.claude --exclude-dir=.agents'
# 1. the strict-width forms: \d{2}, [0-9]{2}, [0-9][0-9], \d\d
grep -rnEI $X -e '\\d\{2\}|\[0-9\]\{2\}|\[0-9\]\[0-9\]|\\d\\d' \
  scripts skills hooks lib templates tests bin project/app
# 2. widened net, each hit read: {2}, [[:digit:]]{2}, BRE [0-9]\{2\}, {1,2}/{2,3}, %02d/zfill, fixed-offset slices
grep -rnEI $X -e '\{2\}|\\\{2\\\}|\[\[:digit:\]\]|\\d\{2' scripts skills hooks lib templates tests bin project/app
grep -rnI  $X -e '%02d' -e 'zfill' -e ':02d' scripts skills hooks lib templates tests bin project/app
grep -rnEI $X -e '\{1,2\}|\{2,3\}|\{0,2\}' scripts skills hooks lib templates tests bin project/app
grep -rnI  $X -e 'E??' -e 'E\[0-9\]\[0-9\]' -e 'E[0-9]\{2\}_S' scripts skills hooks lib templates bin project/app
```

Command 1 returned 39 hits (scripts 6, skills 8, tests 24, project/app 1; hooks, lib, templates and bin 0). Result:
**0 fixed, 39 justified non-hits.** Every board-ID site the survey found was already migrated by `T02` to `T06`
(`tests/conventions-no-leak.bats` now scans `E[0-9]+_S[0-9]+(_T[0-9]+)?`, as `T06` intended). No strict `\d{2}` or
`[0-9]{2}` board-ID regex remains under `scripts/ skills/ hooks/ lib/ templates/ tests/`.

Command 1 hit list (`path:line`, grouped):

| Hit | Count | Classification |
|---|---|---|
| `scripts/validate-checklists.sh:124`, `scripts/validate-board.sh:307`, `scripts/checklist-marker.sh:458,490,504`, `scripts/audit-record.sh:121`, `project/app/api/parsers/rapports.js:35` | 7 | Justified non-hit: ISO date or timestamp shape (`YYYY-MM-DD[THH:MM:SSZ]`), fixed by the calendar |
| `tests/` timestamp assertions: `workflow-run-state-lifecycle-transitions.bats:119`, `checklist-sh.bats:995`, `audit-record.bats:41`, `workflow-run-state-steps.bats:85,86`, `workflow-run-state-start.bats:90`, `checkin-liveness.bats:337`, `workflow-artifact-registry.bats:120`, `commit-test-gate-e2e.bats:1004`, `workflow-run-state-resume.bats:317`, `task-usage-aggregate.bats:191`, `workflow-step-state.bats:257,270,443,504`, `break-signal.bats:84`, `workflow-run-state-store.bats:307`, `commit-test-gate-run.bats:612`, `record-execution.bats:33`, `audit-deps.bats:413` | 20 | Justified non-hit: ISO timestamp assertions on event or state files |
| `skills/j-mirror-public/scripts/release-prep.sh:152` (`[0-9][0-9]*` in a `vN.N.N` tag filter) | 1 | Justified non-hit: semantic-version tag, and `[0-9][0-9]*` is one-or-more digits |
| `skills/j-close-story/scripts/extract-task-diff-stats.sh:95,97,99` (`[0-9][0-9]* file/insertion/deletion`) | 3 | Justified non-hit: `git diff --stat` text, one-or-more digits |
| `skills/j-close-story/scripts/compute-scope-divergence.sh:84,85,86` (`[0-9][0-9]*` over config values) | 3 | Justified non-hit: numeric thresholds from `scope-config.json`, one-or-more digits |
| `skills/j-test/scripts/scope-test-gate.sh:390` (`^\([0-9][0-9]*\) passed, ...`) | 1 | Justified non-hit: test-runner pass and fail counts |
| `tests/checklist-gating.bats:327,329,330` (`grep -o '[0-9][0-9]*'`) | 3 | Justified non-hit: extracts exit-code numbers from documentation |
| `tests/commit-test-gate-skill.bats:60` (`[0-9][0-9]*\(\.[0-9][0-9]*\)\{0,1\}`) | 1 | Justified non-hit: numbered-step headings such as `3.` and `3.1` |

The counts add up to the 39 lines the command printed (7 + 20 + 1 + 3 + 3 + 1 + 3 + 1).

Widened-net commands 2 to 5 surfaced these further sites; each was read:

| Hit | Classification |
|---|---|
| `tests/validate-board-wide-ids.bats:69`, `tests/cascade-resolve-wide-ids.bats:75` (grep for `\d{2}`) | Justified non-hit: regression assertions that the migrated scripts contain no two-digit regex |
| `scripts/checklist-marker.sh:490,504`, `scripts/validate-board.sh:307` | Justified non-hit: timestamp and date shapes (listed above) |
| `skills/j-uncharted/scripts/write-backfilled-epics.sh:330` (`E(\d{2,})_`) | Justified non-hit for this task: `{2,}` accepts any width of two or more digits (it is the generation minimum), used to find the highest existing epic number; allocation is owned by `E86_S04` |
| `skills/j-uncharted/scripts/write-backfilled-epics.sh:379` (`"E%02d"`), `skills/j-todo/scripts/add_trivial_task.sh:141` (`'%02d'`) | Justified non-hit for this task: `%02d` is a minimum width of two and never truncates (`printf '%02d' 100` prints `100`); the padding rule and allocator belong to `E86_S04` |
| `skills/jenga/scripts/resolve-id.sh:377` (`f"{value:02d}"`) | Justified non-hit for this task: output formatting inside the fuzzy-ID resolver, owned by `E86_S03` |
| `scripts/e25_s01_generate_synthetic_board.py:34` (`SYNTH{index:02d}_`) | Justified non-hit: synthetic replica prefix, not a board ID |
| `scripts/validate-tools-registry.sh:64` (`{0,2}`), `scripts/build-pages-site.sh:357` (`#{2,3}`), `scripts/task-usage.sh:291,295`, `skills/j-close-story/scripts/compute-scope-divergence.sh:38` (`${2}`) | Justified non-hit: version-number groups, markdown heading depth, shell positional parameters |
| `scripts/idea_manager.sh:125` (`E[0-9]*)` case glob) | Justified non-hit: `*` is any number of further digits, so width-agnostic |
| slice and `cut -c` hits (`[:3]`, `[2:]`, `cut -c1-60`) | Justified non-hit: truncation of display text and argv, none on an ID |

Closing re-run (task `E86_S06_T07`): command 1 was repeated at the end of the epic and found two strict two-digit ID
patterns that did not exist when the sweep above first ran, both in `tests/board-id-sort.bats` (the file selecting the
two-digit equal-width board names; added by `E86_S02_T01`). **Fixed:** the file now matches the ID shape with
`E[0-9]+...` and compares segment width with `awk` (`equal_width_names`), selecting the same 89 epic, 517 story and
1,569 task file names as before. Every remaining hit under the six root directories is a timestamp or date shape,
a one-or-more-digit count, or a semantic-version filter, as classified above.

## Ordering

_Owner: `E86_S02`. Task `E86_S02_T01` wrote the rules and the shared helper below, `E86_S02_T02` the JavaScript
form, and `E86_S02_T03` to `E86_S02_T06` moved the adopters (the board scan, the board index, bundle resume, the
dashboard board parser and the converted listings of the audit table) onto it. `E86_S02_T07` pins the prefix-collision
invariant and states the rules and the three implementations in one place._

### Ordering rules

Every ordering of board IDs or of names that start with one compares **numeric value**, never filename text
(Decisions, item 4). The rules, pinned by `tests/fixtures/board-id-sort-cases.json`:

1. Epic, story and task numbers compare as integers, in that order: `E01 < E2 < E10 < E11 < E99 < E100 < E101 < E1001`,
   `E10_S2 < E10_S10 < E10_S100`, `E10_S1_T2 < E10_S1_T10 < E10_S1_T100`.
2. A bare ID and a filename order the same way: the name's leading ID decides and the slug is ignored between
   different numbers (`E100_a.md` sorts after `E99_z.md`, whatever the slugs say). The ID ends at the end of the
   name, at `_` or at `.`; `E10x.md` is not epic 10, and `E10_S1x.md` is epic 10 (the story segment does not parse,
   so the name falls back to the shallower ID).
3. A missing deeper segment sorts before a present one, so an epic file sorts before its stories and a story before
   its tasks (`E10_zzz.md` before `E10_S1_aaa.md`).
4. Ties (equal numbers, such as `E001`, `E01` and `E1`, or the same task with different slugs) are broken by the full
   name's text in byte order, so the order is total and the same in every language and locale.
5. A name that is not a board ID (`README.md`, `E10x.md`) sorts after every board ID, then by text.
6. The sort is stable, and on a list of equal-width two-digit IDs the numeric order equals plain text order, so the
   existing two-digit board orders exactly as before. Nothing is renamed.

**Where non-ID names sort.** After every board ID, never among them: `README.md`, `.gitkeep`, `E10x.md` (the ID must end
at `_`, `.` or the end of the name) and lowercase `e10_a.md` all come last, in byte order of the full name. In the
sort key that is `kind` 1 against `kind` 0, so no digit comparison ever involves such a name. A listing that must
hide them filters first and sorts second; the sort itself never drops anything.

### Shared sort helper

Three implementations restate the same rules, because the three runtimes cannot import one another. All three are
silent when imported or sourced, never mutate their input, and are pinned to one case list,
`tests/fixtures/board-id-sort-cases.json`, so a rule changed in one and not the others fails a test:

| Form | Where | Function | Notes |
|---|---|---|---|
| Python | `scripts/lib/board_ids.py` | `board_id_sort_key(name)` | use as `sorted(names, key=board_id_sort_key)`; returns `(kind, epic, story, task, name)` with `-1` for a missing segment and `kind` 0 for a board ID, 1 for anything else |
| shell | `scripts/lib/board-ids.sh` | `board_id_sort` | reads names on stdin, one per line, and writes them in the same order; `awk` emits integer columns and a plain `sort -n` orders them (no `sort -V`), bash 3.2 and BSD tools, `LC_ALL=C` inside so the caller's locale never matters; names containing a tab are not supported |
| JavaScript | `project/app/api/parsers/lib/board-id-sort.js` (`E86_S02_T02`) | `sortBoardIds(names)`, also `compareBoardIds(a, b)` and `boardIdSortKey(name)` | CommonJS, standard library only; `sortBoardIds` returns a new array and `compareBoardIds` is the `Array.prototype.sort` comparator; numbers are `BigInt`, so any digit width is exact, and text ties compare by code point to match `LC_ALL=C sort`; used by `project/app/api/parsers/board.js` (`readMarkdownDir`) |

Tests: `tests/board-id-sort.bats` passes only when the Python and shell forms reproduce every `expected` list of the
case file exactly, and `project/app/api/parsers/lib/board-id-sort.test.js` (a plain Node `assert` test, run with
`node project/app/api/parsers/lib/board-id-sort.test.js` or `npm test` from `project/app/api/`) does the same for the
JavaScript form.

A caller picks the form of its own runtime and never carries a private comparator: a script that orders board names
sources `board-ids.sh` or imports `board_ids` from its own location (see the audit below for how each resolves it),
and the dashboard API requires `./lib/board-id-sort`. Adding a fourth runtime means adding its function and its case
file run in the same change.

```bash
. "$BOARD_IDS_SH"
printf '%s\n' E100_a.md README.md E99_z.md | board_id_sort   # E99_z.md, E100_a.md, README.md
```

```python
sorted(["E100_a.md", "README.md", "E99_z.md"], key=board_ids.board_id_sort_key)
```

```js
const { sortBoardIds } = require('./lib/board-id-sort');
sortBoardIds(['E100_a.md', 'README.md', 'E99_z.md']);   // ['E99_z.md', 'E100_a.md', 'README.md']
```

### Prefix-collision invariant

With width-agnostic IDs `E10` is a string prefix of `E100` and `E1001`, `E10_S1` of `E10_S10`, and `E10_S1_T1` of
`E10_S1_T10`. The invariant, stated once here and in the schema's ID & Filename Conventions block:

- **A lookup of a board file by ID globs `<id>_*.md`, with the trailing underscore.** `E10_*.md` matches `E10_a.md`
  and never `E100_b.md` or `E1001_c.md`; `E10_S1_*.md` never matches `E10_S10_y.md`; `E10_S1_T1_*.md` never matches
  `E10_S1_T10_w.md`. The same holds for `find -name "E10_*"` and for Python `glob`. A glob such as `E10_*.md` still
  reaches the story and task files of epic 10 (their names begin with `E10_`), so a lookup runs inside the one board
  directory that holds that kind of item.
- **An unanchored match on an ID is a bug class**: `${id}*`, `*$id*`, `grep E10`. It is correct on a board of equal
  width two-digit IDs and silently wrong the day `E100` exists.
- **A lookup by the exact file** (`<id>.md`) needs no underscore, and a lookup that wants the number and not the file
  parses it with the shared patterns instead of globbing.

`tests/board-id-prefix-collision.bats` pins this in two parts. Part (a) builds a mixed-width board in a temporary
directory and checks the glob, `find` and Python forms, with a bare `E10*` as the negative control that proves the
collision is real. Part (b) locates each known lookup site **by content** (an anchor regex per site, not a line number,
so line drift does not fail it) and requires its trailing underscore: the ten sites named by `E86_S02_T07`
(`hooks/on_session_end.sh`, `skills/j-check-in/scripts/collect-liveness.sh`, `scripts/render-ranked-list.sh`,
`scripts/link-external-ref.sh`, `skills/j-close-story/scripts/check-story-closeable.sh`,
`skills/j-do/scripts/bundle-resume.sh`, `skills/j-todo/scripts/add_trivial_task.sh`) plus the other one-file lookups of
the audit below and the two `scripts/task-usage.sh` lookups added since. It also fails on any bare ID glob appearing in
a guarded file. The guard runs over a root directory, and mutation cases run the same guard over temporary copies with
one underscore removed to prove that each site is really checked. A new `<id>_*.md` lookup should be added to the
site table in that file.

### Audit of board-directory listings (task `E86_S02_T06`)

Every place under `scripts/ skills/ hooks/ lib/ bin/ project/app/api/` that lists a board directory (epics, stories or
tasks) was found by the sweep below and triaged as **converted** (it now orders by numeric ID), **order-insensitive**
(the answer cannot depend on the order, with the reason), or **order-sensitive, not converted** (the task converts at
most 5 files, so the rest are filed in `project/rapports/problems/E86_S02_T06-remaining-board-listing-conversions.md`
against `E86_S02`). Nothing is renamed and no migration step exists: on the existing two-digit board every converted
site prints exactly what it printed before (`scripts/render-ranked-list.sh` was run on the real board before and after:
60 lines, byte-identical).

Sweep, run from the repository root. Step 1 finds the files that name a board directory; step 2 lists the listing
constructs in them (`find`, `ls`, shell and Python globs, `os.walk`, `iterdir`, `listdir`, `readdir`). `.claude/`,
`.agents/` and `node_modules/` are excluded (generated mirrors and dependencies), as are `*.md` (prose in `SKILL.md`
files is not code) and `*.bats`. On the tree at `E86_S02_T07` it returns 40 files and 80 hit lines (the hits that are
comments, prose or not a listing are covered by the last rows). The counts move as files are added; they are what the
commands below print, run from the repository root under `bash` or `zsh`.

```bash
# An array, not a string, so zsh (which does not word-split an unquoted variable) passes each option separately;
# the globs are quoted so neither shell expands them against the current directory.
X=(--exclude-dir=node_modules --exclude-dir=.claude --exclude-dir=.agents --exclude='*.md' --exclude='*.bats')
F="${TMPDIR:-/tmp}/board-listing-files.txt"
# 1. files that name a board directory
grep -rlEI "${X[@]}" -e 'board/(epics|stories|tasks)' -e '(BOARD|STORIES|TASKS|EPICS)_DIR' \
  -e '(board|stories|tasks|epics)_dir' -e 'get (epics|stories|tasks)' \
  scripts skills hooks lib bin project/app/api | sort > "$F"
# 2. listing constructs in those files (comment-only lines dropped)
xargs grep -nEI -e 'find ' -e '(^|[^a-z_.-])ls ' -e 'glob' -e 'readdir' -e 'iterdir' -e 'os\.walk' \
  -e 'for [A-Za-z_]+ in [^;]*\*' -e 'listdir' < "$F" | grep -vE '^[^:]*:[0-9]+:\s*#'
# 3. the dashboard API reads directories through Node, which step 2 reaches only where step 1 matches the file
grep -rn 'readdirSync' project/app/api --include='*.js'
```

| Site | Triage | One-line reason |
|---|---|---|
| `scripts/render-ranked-list.sh` (`list_board_files`, was `find ... \| sort` at lines 228 and 242) | converted | `/dooo` and `/todo --ranked-list` numbered picker; sorts bare names with `board_id_sort`; `tests/board-listing-order-render-ranked-list.bats` |
| `skills/j-break/scripts/render-execution-status.sh` (glob at 209 and the epic, story and task `sorted()` calls) | converted | the `/break status` rapport printed `E100` before `E11` and `T10` before `T2`; now `board_id_sort_key`, placeholders `-` and `?` keep their old place; `tests/board-listing-order-break-status.bats` |
| `skills/j-publish/scripts/generate_release_notes.sh` (`collect_completed_tasks`, `find` at 364, was `sort -u`) | converted | the changelog's "Completed tasks" bullets; sorted with `board_id_sort`, library loaded lazily and a missing one is an error; `tests/board-listing-order-release-notes.bats` |
| `skills/j-check-in/scripts/collect-liveness.sh` (`grep -l ... *.md` shortlist, board section) | converted | the F5/F6 findings follow the order of the In Progress shortlist; re-sorted with `board_id_sort`; `tests/board-listing-order-checkin.bats` |
| `skills/j-uncharted/scripts/run-engine.sh` (`os.walk` of the board, `sorted(ids)` in `board_linkage`) | converted | the understanding document's Board linkage row shows the first 8 IDs, so text order changed which IDs the `(+N more)` cut-off kept; `tests/board-listing-order-uncharted.bats` |
| `skills/jenga/scripts/board-scan.sh:219`, `skills/index/scripts/board_index.py:373,435,451` | converted (E86_S02_T03, not touched here) | already ordered with `board_id_sort_key` / `board_order_key` |
| `project/app/api/parsers/board.js:36` | converted (E86_S02_T05, not touched here) | `readMarkdownDir` applies `sortBoardIds` |
| `skills/j-do/scripts/bundle-resume.sh:161,168` | converted (earlier task, not touched here) | `sorted(glob(...), key=by_board_id)` |
| `skills/j-publish/scripts/publish_deploy.sh:279` (`print_board_summary`) | order-sensitive, not converted | the "Board summary since last publish" lines come out in raw `find` order (not even text order); filed |
| `skills/j-uncharted/scripts/resolve-segment-target.sh:355,412` (`os.walk` plus `sorted(items), sorted(files)`) | order-sensitive, not converted | the board IDs it reports for a segment are text-sorted; filed |
| `skills/j-close-task/scripts/close-task-context.sh:138` (`open_siblings`) | order-sensitive, not converted | the open-sibling JSON array follows glob (text) order, which only differs from numeric order at T100 and above; filed |
| `skills/j-doc/scripts/resolve_last_update.py:115,160` | order-sensitive, not converted | a tie on `date_completed` falls back to text order of the ID in `matched_items`; `last_update` itself is unaffected; filed |
| `skills/j-uncharted/scripts/find-scan-baseline.sh:407,496` | order-sensitive, not converted | an equal-timestamp tie in `resolved.sort(key=(_ts, id))` falls back to text order of the ID; filed |
| `scripts/e25_s01_extract_board_graph.py:99,134` (`sorted(base.glob("*.md"))`) | order-insensitive | its output is re-sorted by `(type, id)` text (`node_sort_key`) before printing, by design: it is a throwaway extractor whose JSON is a canonical form |
| `scripts/e25_s01_generate_synthetic_board.py:59` | order-insensitive | copies each board file to a prefixed name; no list is emitted |
| `scripts/mark-deployed.sh:487`, `skills/j-mirror-public/scripts/mark-publicized.sh:397`, `skills/j-self-sync/scripts/mark-merged.sh:490` (`find ... \| sort -z`) | order-insensitive | each file's status is rewritten independently; the sort only orders log lines |
| `scripts/next-board-id.sh:151` | order-insensitive | takes a numeric maximum, so the listing order cannot change the answer |
| `skills/j-close-story/scripts/extract-diff-stats.sh:86` | order-insensitive | the task files only feed `sort -u` and then a sum of insertions, deletions and a commit count |
| `<id>_*.md` lookups returning one file: `scripts/render-ranked-list.sh:176`, `scripts/resolve-commit-ref.sh:278`, `skills/j-check-in/scripts/collect-liveness.sh:657`, `skills/j-close-story/scripts/check-story-closeable.sh:82,171`, `skills/j-close-story/scripts/extract-diff-stats.sh:69`, `skills/j-close-task/scripts/close-task-context.sh:77`, `skills/j-verify/scripts/verify-context.sh:149`, `skills/j-test/scripts/scope-test-gate.sh:920`, `skills/j-todo/scripts/add_trivial_task.sh:110,152`, `hooks/on_session_end.sh:219` | order-insensitive | a lookup by ID; the trailing `_` makes it unique (`E10_*` never matches `E100_x.md`), so one file matches whatever the order (`add_trivial_task.sh:152` is the degraded-mode numeric maximum) |
| `skills/jenga/scripts/enrich-nl-prompt.sh:198`, `skills/index/scripts/board_index.py:468,477,564,590` | order-insensitive for the board | they list documentation, examples, skills or agents rather than a board directory (`enrich-nl-prompt.sh` also reads `plans` and `summaries`, whose `-plan.md` names `board_id_sort` does not parse; see the rapport) |
| `hooks/on_session_end.sh:143,251`, `skills/j-break/scripts/render-execution-status.sh:245,264`, `skills/j-check-in/scripts/collect-liveness.sh:387,442,554,619,625,701`, `skills/j-mirror-public/scripts/mirror.sh:2189`, `skills/j-reconcile/scripts/detect-unlinked-code.sh`, `skills/j-test/scripts/baseline-permissions.sh:439`, `skills/j-uncharted/scripts/find-scan-baseline.sh:267`, `scripts/verify-consumer-install.sh:181`, `skills/j-self-sync/scripts/mark-merged.sh:245`, `project/app/api/parsers/rapports.js:48`, `project/app/api/parsers/lib/markdown-dir-reader.js:66` | order-insensitive for the board | rapports, queue, worktrees, handoffs, skill directories, ignore globs and `dist`, not a board directory |

A converted shell caller sources `board-ids.sh` from its own location and a converted Python caller imports
`board_ids` from its own location, with no fallback ordering when the library is missing (an error: exit 1 for
`render-ranked-list.sh` and `collect-liveness.sh`, exit 3 for `render-execution-status.sh` and `run-engine.sh`, a
non-zero exit with a message for `generate_release_notes.sh`). The locations are `scripts/lib` beside `scripts/` for
`render-ranked-list.sh`, and the repo layout (`../../../scripts/lib`) then the installed package
(`../../../node_modules/@jenga-ai/agent/scripts/lib`) for the four skill scripts. A test fixture that copies one of
these scripts must also copy `scripts/lib` (Decisions, item 7); each new test file has a case for the missing-library
error.

## Fuzzy-ID grammar

Implemented in `skills/jenga/scripts/resolve-id.sh` (its header comment is the executable source of the rules);
characterized by `tests/resolve-id-grammar.bats` (two-digit boards, unchanged) and `tests/resolve-id-wide-grammar.bats`
(mixed-width boards).

**User-approved revision of a negotiated grammar.** The original `/jenga <ids>` grammar (`E45`) chunked every digit
run into two-digit pieces and was recorded as final and negotiated with the user. It could not express `E100` or
`S100`. It was revised on 2026-10-25 under `E86`, with the user's explicit approval (Decisions, item 6). It was not
changed unilaterally and should not be reopened without the user. Nothing that resolved on a two-digit board before
resolves differently now.

### Grammar

1. Uppercase the input and strip whitespace, underscores and punctuation. A separator between two digit runs is kept
   as a run boundary, so `100 2` is the runs `100` and `2`, never `1002`.
2. A digit run is **tagged** when a single `E`, `S` or `T` letter is adjacent to it (a letter tags the run after it; a
   trailing letter with no run after it tags the run before it).
3. A **tagged** run is that level's number at any width, compared by numeric value: `e100s2` is `E100_S02`, `E001` is
   epic 1, and `e10s1` never matches `E100_S01`.
4. An **untagged** run is cut into two-digit chunks, which fill the open levels epic, story, task from left to right
   (`0103` is `E01_S03`). A separator-bounded untagged run that fails the cut-off below is one whole number
   (`100 2` is `E100_S02`).
5. A candidate that does not resolve uniquely on the board is rejected, never guessed (a story number with no epic
   that exists under several epics asks for disambiguation).

### Untagged-run cut-off

An untagged run is chunked only when its length is even, at most 6 digits, and none of its chunks is `00` (numbering
starts at `01`). A bare untagged run that fails the cut-off is rejected with a message naming the fix, for example
`10002` ("use letters or separators, e.g. e100s02 or '100 2'"). That covers odd lengths (`10002`, `010`, `100`), a
`00` chunk (`1000`) and runs longer than 6 digits. An even run longer than 6 digits that would chunk into too many
pieces (`0102030405`) keeps the earlier "too many untagged chunks" rejection.

### Tagged-run overlap rule

An even-length tagged run of 4 or 6 digits has two readings: the legacy one, cut into two-digit chunks with the chunk
next to the letter tagged (`E0102` is `E01` plus an untagged `02`, so `E01_S02`), and the wide one, a single number
(`E0102` is epic 102). Both are tried against the board. If only one resolves, that is the answer; if both resolve,
the input is rejected as ambiguous and the message asks for letters or separators (`e01s02` or `e102`). So `E0102`
keeps meaning `E01_S02` on a board with no `E102`. Once both exist, the short form is rejected rather than guessed,
and the unambiguous forms keep working.

### What does not change

No ID is renamed and there is no migration. Callers that feed `resolve-id.sh` need no change:
`skills/j-reconcile/scripts/resolve-reconcile-scope.sh` builds range members such as `E100_S03` (zero-padded to the
wider input width, minimum 2) and sends them through the same grammar; `tests/resolve-reconcile-scope-wide.bats` covers
`e100s3-5` and `S99-101` and `tests/detect-nl-intent-wide.bats` covers the `all_resolved` and not-resolved
classification.

## Contract and allocation

### Contract

The width contract is stated once, in the ID & Filename Conventions block of `templates/SCRUM_BOARD_SCHEMA.md`
(task `E86_S04_T04` replaced the old "zero-padded to two digits" bullet there). It says:

- **Minimum two digits, no maximum.** `E07`, `E99`, `E100`, `E1001`. A number is never pre-padded beyond its own
  digits, so the form is `E100`, never `E0100`.
- **Stories and tasks follow the same rule** (`S03`, `S100`, `T07`, `T100`), so `E100_S100_T100` is a valid task ID.
- **Existing IDs are never renamed and there is no migration.** A board whose IDs are all two digits keeps every file
  name it has, and allocates exactly the IDs it would have before.
- **Parsing accepts any width.** The shared pattern sources are `scripts/lib/board-ids.sh` and
  `scripts/lib/board_ids.py`.
- **Comparison is numeric, never filename text.** `E99` sorts before `E100`, and `E01` and `E1001` may coexist on one
  board (see "Ordering" above).
- **Lookups by ID rely on the trailing underscore** in `<id>_*.md`, so `E10_*.md` does not match `E100_x.md`.
- **New IDs come from `scripts/next-board-id.sh`**, not from counting or sorting file names.

The schema change touches one bullet group only. No frontmatter field definition moved, and the `E##` placeholders
elsewhere in the schema stay placeholders.

### Allocator

`scripts/next-board-id.sh` (task `E86_S04_T01`) is the one deterministic allocator for the next board ID. Callers
run it instead of counting file names, and its answer is the bare ID on one line:

```bash
bash scripts/next-board-id.sh epic              # E100
bash scripts/next-board-id.sh story E100        # E100_S03
bash scripts/next-board-id.sh task  E100_S02    # E100_S02_T04
```

- **Numeric maximum plus one**, never a count and never a text sort: `E01`, `E99`, `E100`, `E1001` allocate `E1002`;
  `E01` to `E99` allocate `E100`; a gap (`T01`, `T03`) allocates `T04`.
- **Scope of the scan.** All three board directories, for every request (a task file proves its story and epic
  numbers are taken), each resolved through `scripts/resolve-root.sh get epics|stories|tasks` plus the legacy
  `<root>/project/epics|stories|tasks` path where it exists. The scan reads the filesystem, so an untracked file
  counts. Names are parsed with the shared pattern source (`scripts/lib/board-ids.sh`); the underscore that must
  follow the ID is what keeps `E9_x.md`, `E10_x.md` and `E100_x.md` apart, and names that do not start with an ID
  (`README.md`, `.gitkeep`, `e99_x.md`, `E99x_x.md`) are ignored. A parent is matched by numeric value (`E1`
  matches `E01_...`) and echoed as given.
- **Width.** The new number is a minimum of two digits and no maximum (`07`, `99`, `100`, `1001`), written by
  `board_id_format_number` in `scripts/lib/board-ids.sh`. That helper is the only place the width rule lives, so
  other generators share it instead of carrying a `printf '%02d'` of their own.
- **Overrides.** `--epics-dir`, `--stories-dir` and `--tasks-dir` (also `--x-dir=PATH`) replace the resolved
  directory, so a scratch directory can be allocated against (the backfill script's dry run relies on this).
- **Exit codes.** 0 ok; 2 usage (bad type, missing or malformed parent, a parent given to `epic`, an unknown option,
  an override that is not a directory, or no board directory to scan), with a usage message on stderr; 1 internal
  (shared library missing, or a number beyond 64-bit arithmetic, refused rather than wrapped).
- Read-only: it creates, renames and changes nothing. Tests: `tests/next-board-id.bats`.

### How agents call the allocator

Agents never compute the next number themselves. They resolve the script with the dual-path idiom, so the same text
works in the monorepo and in a consumer install, and take the one line it prints:

```bash
bash "$([ -f scripts/next-board-id.sh ] && echo scripts/next-board-id.sh || echo node_modules/@jenga-ai/agent/scripts/next-board-id.sh)" task E100_S02
```

The first argument is the type (`epic`, `story` or `task`); `story` and `task` take the parent ID as the second argument.
Use the printed ID verbatim for the file name, the `id:` field and the parent link. A non-zero exit means no ID was
allocated: stop and report the message instead of falling back to counting files.

**Adoption.** The scrum-master instructions (`agents/scrum-master.md`), `skills/j-pi-plan/SKILL.md`,
`skills/j-btw/SKILL.md`, `skills/j-todo/scripts/add_trivial_task.sh` and
`skills/j-uncharted/scripts/write-backfilled-epics.sh` all allocate through this script (sibling tasks `E86_S04_T02`
and `E86_S04_T03`); `git grep -l next-board-id -- agents skills` lists exactly those files.

### Rejected option

**Renaming the existing files to a wider padded form** (for example every `E01_...` to `E0001_...`, so that plain text
sorting stays correct as numbers grow) was rejected. The reason is cost, not policy: it would rename about 1,900 board
files and rewrite every reference to them (frontmatter links, `depends_on`, commit and branch history, rapports,
plans, summaries, queue triggers), and every one of those is a place for a silent break. No repository rule forbids
renames, so this is a judgement about cost against benefit. Numeric comparison, which `E86` already needed for the
fuzzy-ID grammar and the ordering helper, makes the rename unnecessary: the board keeps its names and only new, wider
numbers are written without padding.

### Sweep for remaining statements of the old contract

After the schema fix, `grep -rniE 'zero-padded|two digits|2-digit' agents skills templates` returns five hits. None
states the old contract that board IDs are exactly two digits:

| Hit | Why it is not a statement of the old contract |
|-----|-----------------------------------------------|
| `templates/SCRUM_BOARD_SCHEMA.md:190` | The replacement contract itself: "minimum two digits, no maximum". |
| `skills/j-reconcile/scripts/resolve-reconcile-scope.sh:94` | Range expansion. Pads to the wider of the two input widths, minimum 2 digits, so it already produces `S100`; consistent with the contract. |
| `skills/jenga/scripts/resolve-id.sh:376` | Docstring "Zero-padded to at least two digits ('E09', 'E100')": output formatting of a minimum, not a maximum; consistent. |
| `skills/j-workflow-recorder/scripts/recording-file.sh:227` | Workflow recording step IDs (`step-001`), not board IDs. |
| `skills/j-workflow-recorder/scripts/recording-format.sh:54` | Same: `step-` plus a three-digit sequence number, not board IDs. |

The two recorder hits are the only ones in a different ID space, and they are unrelated to board items.

## Audit table

_Owner: `E86_S05`, assembled by `E86_S05_T07` from the `Group ...` sections of the execution summaries of
`E86_S05_T01` to `T06` (under `project/documentation/summaries/`, one `-summary.md` per task) and the rapports those
tasks filed.
Every row is what a group summary recorded, except the one row that says it was triaged by `E86_S05_T07`._

The audit asked one question of every site that derives something from a board ID (a commit subject, a branch or
worktree name, a queue file, a lookup by ID, a dashboard parser): does it still behave when IDs are three or four
digits wide and `E10` is a string prefix of `E100` and `E1001`? Result: **one real defect, fixed** (`todo_manager.sh
remove`, group 1); every other site was already correct. Nothing was renamed and no migration step exists; the
existing two-digit board behaves as before.

**Groups** (the six of the story, with group 6 split as the summaries split it):

| Group | Scope | Recorded in |
|-------|-------|-------------|
| 1 | Unanchored substring and prefix matches on an ID | `E86_S05_T01` |
| 2 | Worktree and branch names | `E86_S05_T02` |
| 3 | Queue triggers, handoffs, context digests, bundle manifests | `E86_S05_T04` |
| 4 | Events, rapports, plans, summaries, instructions | `E86_S05_T05` |
| 5 | Dashboard (API, board, kanban, todo, ideas, rapports, snapshot) | `E86_S05_T06` |
| 6a | Commit names (`commit-subject-check.sh`, `commits-for-item.sh`) | `E86_S05_T03` |
| 6b | Lifecycle-status scripts, `jenga config`, `lib/`, `bin/`, `j-uncharted` backfill | `E86_S05_T05` |

**Verdicts.** `fixed`: the site was wrong and is anchored by a code change, with a regression test. `safe-by-anchor`:
the site matches or looks up an ID and is protected by a delimiter, a whole-string validation, an exact field compare or
a trailing `_` in a glob. `already safe`: the site never matches on an ID (it copies, orders, renders or slices
something that is not an ID). A pin is a test that exercises the site with a wide ID. Where the fourth column says
`No test applies`, the audit read the code and found no case a test could add (the reason is given); where it says
`No pin added here`, a test could exist but this story did not write one and the verdict rests on the reading recorded
in the summary.

### Table

| Site | Group | Verdict | Pinning test, or reason none applies |
|------|-------|---------|--------------------------------------|
| `scripts/todo_manager.sh:62,66` (`remove "<title>"`) | 1 | fixed | Pin: `tests/todo-manager-remove-id-boundary.bats` (13 cases; the file also runs against the pre-fix script through `TODO_MANAGER_UNDER_TEST`). Commit `633e39e2` |
| `scripts/render-ranked-list.sh:225` | 1 | safe-by-anchor | No pin added here: delimiter class on both sides of the ID (anchored by `E86_S02`) |
| `scripts/commits-for-item.sh:162` (whole-string validation), `:180` (`git log --grep` with a trailing delimiter), `:196` (exact field compare on the `Jenga-Task` trailer) | 1, 6a | safe-by-anchor | Pin: `tests/wide-id-commit-names.bats` (resolver cases on epics `E10`, `E100`, `E1001`, story `E1001_S100`, tasks `E1001_S100_T100`, `E100_S10_T10`, `E10_S1_T1`, `E10_S1_T10`) |
| `skills/j-commit/scripts/commit-subject-check.sh:67` (`BOARD_ID`), `:76,77,111` | 1, 6a | already safe | Pin: `tests/wide-id-commit-names.bats` (subject-check cases: the three wide subjects are `kind=board`, a malformed wide ID in a non-EST scope is rejected under a strict convention). Lines 76, 77 use delimiters; line 111 matches the user's `message_regex`, not an ID |
| `skills/j-reconcile/scripts/gather-perceived-branch-evidence.sh:132,186` | 1, 2 | safe-by-anchor | Pin: `tests/wide-id-worktree-branch.bats` (case 19: a commit naming `E10_S1_T10` or `E100_S10_T10` is not evidence for `E10_S1_T1`) |
| `scripts/epic-worktrees.sh:37,61` | 1 | safe-by-anchor | No pin added here: `^E[0-9]+$` validation and delimiters on both sides, so `E10` never matches `E100-...` |
| `skills/j-test/scripts/scope-test-gate.sh:487,1015` | 1 | safe-by-anchor | No pin added here: 487 is a whole-string validation; 1015 matches `task(<ids>)` and `Merge branch '<ids>'` with paren and quote delimiters over an exact list |
| `skills/j-publish/scripts/generate_release_notes.sh:281` | 1 | safe-by-anchor | No pin added here: parentheses delimit the ID in `task(<id>):`, fixed-string match |
| `skills/j-publish/scripts/generate_release_notes.sh:510` | 1 | safe-by-anchor | No pin added here: the key is `- <task_id> —` or a `(shortsha)` token, so a leading `- ` and trailing ` —` delimit the ID |
| `skills/j-check-in/scripts/collect-liveness.sh:413` (`$id`, `$id-*`, `bundle-$id`) | 1, 2 | safe-by-anchor | Pin: `tests/wide-id-worktree-branch.bats` (cases 12 and 13, `F5` versus `F6` follows each ID's own worktree) |
| `skills/j-check-in/scripts/collect-liveness.sh:470`, `:651`, `:657`, `:730`, `:740`, `:761` | 1 | safe-by-anchor | No pin added here: tab-delimited both sides (470), anchored `test("^E[0-9]+...$")` (651), `"$id"_*.md` glob with a trailing `_` (657), `grep -qx` whole line (730, 740), exact compare (761) |
| `skills/j-check-in/scripts/collect-liveness.sh:352` | 1 | already safe | No test applies: `grep -l` on a status line, no board ID is matched |
| `skills/j-check-in/scripts/collect-liveness.sh:442-447` (story ID from a `bundle-*.json` name) | 3 | already safe | No pin added here: `${f#bundle-}` and `${f%.json}` then an exact `jq index`, no slice |
| `skills/j-close-story/scripts/check-story-closeable.sh:68,82,171` | 1 | safe-by-anchor | No pin added here: `$BOARD_ID_STORY_RE` validation; `find -name "${STORY_ID}_*.md"` and `"${task_id}_*.md"` with a trailing `_` |
| `skills/j-close-story/scripts/extract-diff-stats.sh:32,90,108,145` | 1 | safe-by-anchor | No pin added here: `^E[0-9]+_S[0-9]+$` validation; `sed` anchored at both ends; `^${STORY_ID}_T[0-9]+$`; line 145 matches a commit hash |
| `skills/j-close-story/scripts/extract-task-diff-stats.sh:56`, `compute-scope-divergence.sh` | 1 | safe-by-anchor | No pin added here: `$BOARD_ID_TASK_RE` validation; the other greps read config numbers |
| `skills/j-close-task/scripts/close-task-context.sh:46,77,138` | 1 | safe-by-anchor | No pin added here: whole-string validation; `ls "$1/$2.md" "$1/$2"_*.md`; sibling globs `"${story_id}_T"*` and `"${epic_id}_S"*` end in `_T` or `_S`, so `E10_S1_T*` never matches `E10_S10_T1` |
| `hooks/on_session_end.sh:153` (`jq index`), `:219` (`find -iname "${task_id}_*.md"`), `:286` | 1, 3 | safe-by-anchor | Pin: `tests/wide-id-queue-handoffs.bats` (four `staleness guard:` cases, `E10_S1_T1` versus `E10_S1_T10` in both directions and `E1001_S100_T100` versus `_T10`). `index` on a JSON array is element equality; the trailing `_` anchors the glob |
| `skills/j-todo/scripts/add_trivial_task.sh:89,110,152,154` | 1 | safe-by-anchor | No pin added here: `^E[0-9]+_S[0-9]+$` validation; `"${story_id}_"*.md` globs; the degraded-mode `sed` is anchored at `^` and `_T` and followed by a numeric maximum |
| `skills/j-todo/scripts/add_trivial_task.sh:178` (`${slug:0:60}`) | 2 | already safe | No test applies: the cut is on the title slug after the ID is formed, never on the ID |
| `skills/j-todo/scripts/update_story_tasks.py` | 1 | safe-by-anchor | No pin added here: `line.strip() == task_line.strip()`, an exact line compare |
| `skills/j-do/scripts/bundle-resume.sh:57,161,168,205,211` | 1, 3 | safe-by-anchor | Pin: `tests/wide-id-queue-handoffs.bats` (the three `bundle ...` cases: S100 resumes, S10 stays fresh next to a live S100 manifest, a manifest of another story is refused with exit 3). `^E[0-9]+_S[0-9]+$`, `glob(story_id + "_*.md")` and an exact `story_id` compare |
| `scripts/link-external-ref.sh:175,273,281`, `scripts/read-external-refs.sh:108,118` | 1, 6b | safe-by-anchor | Pin for `link-external-ref.sh`: `tests/wide-id-events-and-lifecycle.bats` (the linker case writes `external_refs` only into the exact ID's file). `read-external-refs.sh`: no pin added here, same `ID_RE` validation and `"$dir/${ID}"_*.md` lookup requiring a count of exactly one |
| `scripts/resolve-commit-ref.sh`, `scripts/task-commit-ref.sh`, `scripts/prepare-task-commit-ref.sh`, `scripts/apply-ref-policy.sh`, `scripts/create-task-worktree.sh:201-230` | 1, 2 | safe-by-anchor | Pin for `create-task-worktree.sh`: `tests/wide-id-worktree-branch.bats` (create cases). The others: no pin added here, anchored `TASK_RE` validation, `${ID%_T*}` and `${ID%%_S*}` strip one segment of a validated ID, store file named `$ID.json` read back with `.task_id == $id` |
| `skills/j-break/scripts/record-execution.sh:67`, `skills/j-verify/scripts/verify-context.sh:199-243`, `scripts/next-board-id.sh:82,85`, `scripts/lib/board-ids.sh:57-59`, `skills/j-uncharted/scripts/validate-proposed-items.sh:137`, `scripts/checklist.sh:1434,1693,1782` | 1 | safe-by-anchor | No pin added here: whole-string validation (`^...$` or `fullmatch`) before any use of the ID |
| `scripts/mark-deployed.sh`, `skills/j-mirror-public/scripts/mark-publicized.sh`, `skills/j-self-sync/scripts/mark-merged.sh` | 1, 6b | safe-by-anchor | Pin: `tests/wide-id-events-and-lifecycle.bats` (each changes only the wide task's status and leaves the neighbours `E100_S10_T10` and `E10_S1_T1` byte-identical; `mark-deployed.sh` for stage and prod, fed a SHA taken from a `Source-Commit:` trailer). Resolution goes through `commits-for-item.sh`; `mark-publicized.sh:313` is an exact `.ticket_id == $id` |
| `skills/jenga/scripts/render-confirmation.sh`, `render-picker.sh`, `skills/j-break/scripts/render-execution-status.sh`, `skills/jenga/scripts/cascade-resolve.sh`, `skills/j-reconcile/scripts/resolve-reconcile-scope.sh:363,444` | 1 | safe-by-anchor | No pin added here: `in` over a set or dict of IDs (exact membership), `re.match(r"^(E\d+)"...)` captures the whole greedy number |
| `skills/jenga/scripts/resolve-id.sh:385,421` | 1 | safe-by-anchor | No pin added here: levels compared as integers; owned and covered by `E86_S03` |
| `skills/j-reconcile/scripts/resolve-reconcile-scope.sh:248` (`RANGE_RE` with `{1,3}`) | 2 | already safe | No test applies in this story: T02 recorded it as out of group 2 (a story-range shorthand, not a branch or directory name; wide-range behaviour is `E86_S03_T04`). It caps range numbers at three digits; see Observations |
| `skills/j-reconcile/scripts/detect-unlinked-code.sh:450-454` | 1 | safe-by-anchor | No pin added here: greedy digit runs plus a word boundary |
| `skills/j-uncharted/scripts/resolve-segment-target.sh:335,356-386,431`, `run-engine.sh:379-423,440` | 1, 6b | safe-by-anchor | No pin added here: the ID is derived from a board file name with a greedy `\d+`; linkage is a path-token test, not an ID match; `run-engine.sh` orders with `board_ids.board_id_sort_key` |
| `skills/j-uncharted/scripts/find-scan-baseline.sh`, `skills/j-doc/scripts/resolve_last_update.py:126,147,160` | 1 | already safe | No test applies: matched on `docs:` paths, never on IDs; the ID is only an output and a sort tie-break |
| `skills/index/scripts/board_index.py:80,93` | 1 | safe-by-anchor | No pin added here: `_ID_PREFIX_RE` is a deliberately greedy longest-prefix match used only to build a sort key |
| `scripts/e25_s01_generate_synthetic_board.py:15`, `scripts/e25_s01_extract_board_graph.py:106,147,266` | 1 | safe-by-anchor | No pin added here: `\b(ANY_FRAGMENT)\b` greedy, `ref in known_ids` set test; the `stem.split("_",1)[0]` at line 106 is a parse fallback for a missing `id:` field (see Observations) |
| `project/app/api/parsers/board.js:80,98-130`, `project/app/api/routes/board.js:28` | 1, 5 | safe-by-anchor | Pin: `project/app/api/parsers/board.mixed-width.test.js` (grouping by exact-key maps, never by prefix: E10 owns only its stories, E100 owns S1, S10 and S100, `E100_S100` owns `T100`, 20 items none dropped or duplicated, IDs not re-padded, exact `_queued` flags; `GET /v1/board/:epicId` exact lookup, `E1` is a 404); ordering in `project/app/api/parsers/board.numeric-order.test.js` |
| `project/app/api/parsers/todo.js:67,82`, `project/app/api/parsers/ideas.js:84`, `project/app/api/parsers/lib/board-id-sort.js:28` | 1, 5 | safe-by-anchor | Pin: `project/app/api/parsers/dashboard-wide-ids.test.js` (todo refs, `PROMOTED: E1001` and `E10001_S100000_T100000`); `project/app/api/parsers/lib/board-id-sort.test.js` for the sort module. The ref is anchored to end of line or a delimiter lookahead, `\d+` greedy |
| `scripts/populate-knowledge-graph.js:50,51,204,220,341` | 1 | safe-by-anchor | No pin added here: whole-string regexes `/^E\d+$/` and `/^E\d+_S\d+$/`; line 341 tests the literal edge-id prefixes `board:contains:` and `board:depends-on:`, not an ID |
| `scripts/todo_manager.sh:39,89,90`, `scripts/idea_manager.sh:56,71`, `scripts/todo_cleanup.sh`, `scripts/check-todo-format.sh` | 1 | safe-by-anchor | No pin added here: blank and comment filters and idea text; `idea_manager.sh` matches the idea TEXT with `grep -Fn` and refuses when more than one line matches; `check-todo-format.sh` delegates to the anchored `todo.js` patterns |
| `scripts/generate-rapport-manifest.sh:37`, the rapport compare in `hooks/on_session_end.sh` | 1, 4 | already safe | Pin for the manifest: `tests/wide-id-events-and-lifecycle.bats` (lists `E1001_S100_T100-wide-id-example.md`, skips an `.IGNORE.md`). Keyed on rapport file paths, not IDs |
| Every `events.json` reader (`security.js:204`, `collect-liveness.sh:221-300`, `checkin-gate.sh:227`, `list-preflight-deferred.sh:94-157`, `check-privatized.sh`, `mark-publicized.sh:313`) | 1, 4 | safe-by-anchor | Round trip pinned by `tests/wide-id-events-and-lifecycle.bats`; the readers themselves: no pin added here, keyed on session IDs, event names or an exact `ticket_id ==` compare, never a substring match on a board ID |
| `scripts/audit-status.sh:85` | 1 | already safe | No test applies: keyed on a directory name inside backticks, no board ID |
| Non-ID hits of sweeps S1 to S10 (config and version checks, gitignore lines, mirror scans, workflow-recorder step IDs, checklist and session IDs, CLI install code, and similar) | 1 | already safe | No test applies: no board ID is involved; the files are listed by sweep in the `E86_S05_T01` summary under "Not ID-keyed" |
| `scripts/merge-task-into-perceived-branch.sh:233` (`cut -c1-60`) | 2 | already safe | Pin: `tests/wide-id-worktree-branch.bats` (case 6, directory `perceived-E1001_S100_T100-some-slug-<cksum>`). The cut is on the sanitised perceived-branch name at 60 characters, uniqueness comes from the cksum of the unmodified name |
| `scripts/merge-task-into-perceived-branch.sh:201,219,220,226,302` (`substr($0, 10)`, `substr($0, 8)`) | 2 | already safe | No test applies: strips the keywords `worktree ` and `branch ` from `git worktree list --porcelain` lines, not an ID |
| `skills/j-tidy/scripts/reap.sh:317,334,358` (`head -c 200` and `head -c 300`) | 2 | already safe | No test applies: truncates a git diagnostic string in a report line, not a name |
| Default-value expansions `${VAR:-}` at `perceived-branch.sh:129-133`, `worktree-remove-guard.sh:152`, `collect-liveness.sh:178,180`, `resolve-reconcile-scope.sh:195`, `reap.sh:235-295`, `report.sh:98-216`, `settings.json:37` | 2 | already safe | No test applies: false positives of the slice pattern, they are default-value expansions |
| `scripts/create-task-worktree.sh` ID recovery (`^(E[0-9]+_S[0-9]+_T[0-9]+)`), `capture_commit_ref` | 2 | already safe | Pin: `tests/wide-id-worktree-branch.bats` (create through the real `settings.json` `WorktreeCreate` command and the script, list, commit guard, remove). The regex is greedy and captures the whole ID; `capture_commit_ref` (opted-in projects only) was read, not exercised end to end |
| `skills/j-tidy/scripts/classify.sh:227-228` and the worktree and branch population handed over by `/reconcile` step 6.6 | 2 | already safe | Pin: `tests/wide-id-worktree-branch.bats` (all three widths are `board-task`, each is judged on its own content and liveness, a wide branch with no worktree is a `branch` entry) |
| `scripts/check-worktree-liveness.sh`, `scripts/worktree-remove-guard.sh` | 2 | already safe | Pin: `tests/wide-id-worktree-branch.bats` (cases 10 and 11: a live process in `E100_S10_T10-x` is reported for it only, in `E10_S1_T1-x` for it only). Both work on paths only and never parse an ID |
| `scripts/perceived-branch.sh`, `scripts/merge-task-into-perceived-branch.sh`, `settings.json` `WorktreeRemove` command | 2 | already safe | Pin: `tests/wide-id-worktree-branch.bats` (set, get, exists; merge subject keeps the whole branch name; a wide task branch as the perceived branch gives exit 6 while its own worktree holds it; remove leaves the sibling untouched) |
| `hooks/on_session_end.sh` section 4, developer handoff to `tester_triggers.jsonl` (`test_assignment`) | 3 | already safe | Pin: `tests/wide-id-queue-handoffs.bats` (`developer handoff for E1001_S100_T100`). Task, story and epic are copied verbatim with `jq`, no slice |
| same hook, scrum-master `planning_complete` to `developer_triggers.jsonl` (`implementation_assignment`) | 3 | already safe | Pin: `tests/wide-id-queue-handoffs.bats` (`scrum-master batch handoff`, T99 and T100 both forwarded in order) |
| same hook, tester `failed` to `story_rollup` and `rework_assignment` | 3 | already safe | Pin: `tests/wide-id-queue-handoffs.bats` (`failed tester handoff`). Same verbatim copy |
| same hook, file name versus content | 3 | already safe | Pin: `tests/wide-id-queue-handoffs.bats` (`routing reads the id from the handoff body`: name says T1, body says T100, body wins). Routing never reads the file name, only `.agent`, `.status`, `.task_id` |
| `scripts/write-context-digest.sh` (`<agent>-<session_id>-<task_id>.json`) | 3 | already safe | Pin: `tests/wide-id-queue-handoffs.bats` (`context digest for E1001_S100_T100 round-trips`, uuid-style session ID). The name is a plain concatenation and the envelope carries `task_id` |
| `scripts/consume-context-digest.sh` | 3 | already safe | Pin: `tests/wide-id-queue-handoffs.bats` (consuming the `E10_S1_T1` digest leaves the `E10_S1_T10` digest in place). Takes an exact path, never a pattern |
| `scripts/sweep-stale-context-digests.sh` and `hooks/on_session_end.sh` section 6 | 3 | already safe | Pin: `tests/wide-id-queue-handoffs.bats` (the stale-digest sweep is age-based; the hook's own sweep keeps a fresh wide-ID digest). Selects by mtime over `*.json`, never by ID |
| `skills/j-break/scripts/render-execution-status.sh:264` (bundle manifests) | 3 | already safe | No pin added here: reads `story_id` from the manifest body; the file name is only a label for an unparseable file |
| `skills/j-do/SKILL.md` steps citing `bundle-<E##_S##>.json` | 3 | already safe | No test applies: prose only; the text says to exclude any path whose basename equals the name, an exact compare |
| `scripts/events-append.sh` (`task_id` field) | 4 | already safe | Pin: `tests/wide-id-events-and-lifecycle.bats` (round trip of `"task_id": "E1001_S100_T100"`, argument and stdin forms, byte for byte; an exact `jq select` finds one record per task). It validates and appends a whole JSON object and never parses an ID |
| Readers of events by task ID (`scripts/task-commit-ref.sh:280`, `.task_id == $id`) | 4 | safe-by-anchor | No pin added here: an equality test, not a prefix test; the only compare found by `git grep -nE task_id` over `scripts`, `hooks`, `skills/*/scripts` |
| Rapport `Related Task` headers | 4 | already safe | No test applies: free text, never parsed by a script |
| `project/app/api/parsers/rapports.js` | 4, 5 | already safe | Pin: `project/app/api/parsers/dashboard-wide-ids.test.js` (`readRapportsFull` and the `/v1/history` reader). No board-ID pattern at all, only a `\d{4}-\d{2}-\d{2}` date pattern |
| `project/documentation/plans/<id>-plan.md` and `<id>-summary.md` | 4 | safe-by-anchor | No pin added here: the index side is `PLAN_RE` in `scripts/lib/board_ids.py`, anchored `^(...)-plan\Z` (`E86_S01_T05`); nothing else parses these names |
| `project/instructions/<id>_INSTRUCTIONS.md` | 4 | safe-by-anchor | No test applies: there is no script to run. Lookups are an exact file name (`skills/j-commit/SKILL.md:82`, `skills/j-do/SKILL.md:782`), `j-publish` only skips `*_INSTRUCTIONS.md`, and a glob on `E10_S1_T1_*` cannot reach `E10_S1_T10_INSTRUCTIONS.md` because of the trailing underscore |
| `lib/commands/config.js`, `lib/config/*` (`jenga config`) | 6b | already safe | No test applies: `address.slice(0, dot)` splits `<file-id>.<key>`, and descriptor `pattern` values are for config keys, not IDs |
| `lib/` and `bin/` (`status.js`, `doctor.js`, `start.js`, `attach.js`, `dashboard.js`, `init.js`, `jenga.js`) | 6b | already safe | No test applies: the searches return only comments citing story IDs; no code parses a board ID |
| `Source-Commit:` trailer resolution (`scripts/compute-deploy-reconcile.sh`) | 6b | already safe | Pin: `tests/wide-id-events-and-lifecycle.bats`, as far as the extraction regex `^Source-Commit: [0-9a-f]{40}$`. The trailer holds a 40-hex SHA, never a board ID; tag discovery needs a network and is out of scope |
| `skills/j-uncharted/scripts/write-backfilled-epics.sh` | 6b | already safe | No pin added here: allocates through the shared allocator and formats through `board_id_format_number` (already fixed by `E86_S04`) |
| `skills/j-uncharted/scripts/run-engine.sh:272` (`cut -c1-40`) | 6b | already safe | No test applies: slugs a target directory name, not an ID |
| `skills/j-uncharted/scripts/validate-proposed-items.sh` (ID-shape guard) | 6b | already safe | No test applies in this story: out of scope here, the guard is `E86_S01_T04` |
| `project/app/api/parsers/git-log.js` | 5 | already safe | No test applies: commit subjects pass through verbatim, no ID logic |
| `project/app/api/parsers/knowledge-graph.js`, `test-links.js` | 5 | already safe | Pin: `project/app/api/parsers/dashboard-wide-ids.test.js` (node IDs and test links keyed by exact string; `E10` carries none of `E100`'s or `E1001`'s links) |
| `project/app/ui/src/components/board/kanbanColumns.js` | 5 | already safe | Pin: `project/app/api/parsers/board.mixed-width.test.js` (every item in exactly one column, or excluded as an unqueued `Pending`, via a dynamic `import()`); ordering in `project/app/ui/src/components/board/kanbanColumns.manual-verify.mjs` (`E86_S02_T05`). Buckets by status, never by ID |
| `project/app/ui/src/components/board/BoardView.jsx:64-82` (`epicOrder`, `filterEpicRange`) | 5 | already safe | No test applies: the functions are module-private, so no automated test reaches them without a refactor the task did not warrant. Verdict by reading: first digit run, `Number()`, numeric compare, correct for `E01`, `E100`, `E1001` |
| `EpicCard`, `StoryCard`, `TaskCard`, `KanbanBoard` ID chips | 5 | already safe | No test applies: render `epic.id`, `story.id`, `task.id`, `item.id` whole, no slice, padding or width; the CSS sets only colour and font size. The rendered DOM was not exercised (no built `dist/`, no browser) |
| `project/app/ui/src/tabs/RapportsTab.jsx:74` | 5 | already safe | No test applies: a user-typed free-text search over file names (`file.toLowerCase().includes(q)`), not ID matching; `E10` showing `E100` files is search behaviour |
| `project/app/ui/src/components/architecture/SADMap.jsx:435` (`label.slice(0, 17)`) | 5 | already safe | No test applies: truncates a graph node's label, which `scripts/populate-knowledge-graph.js:250,259` sets from the epic or story title, not the ID; the full label is in the tooltip |
| Offline snapshot export (`skills/j-dashboard/scripts/snapshot.sh`, `project/app/api/scripts/capture-snapshot.js`, the bundler) | 5 | already safe | Pin: `tests/dashboard-snapshot-wide-ids.bats` (real snapshot pipeline on a mixed-width project; the HTML contains `E1001`, `E100_S100_T100`, `E01` and correctly grouped `/v1/board`, `/v1/ideas`, `/v1/rapports` payloads; the third case needs a built `dist/` and skips with a message otherwise) |
| `scripts/task-usage.sh:` the filter and id-extraction lines, `skills/j-close-story/scripts/persist-task-usage.sh:32-38,` and `scripts/check-test-links.sh` (`grep -F -x`); added by `E76` after the group 1 sweep | 1 | safe-by-anchor | No pin added here. Triaged by `E86_S05_T07` (not in a group summary): the only hits of sweeps S1, S2, S5b, S6 and S10 that are new on `main` `3ddb6fc6` compared with the sweep's base `069f1b6c`. `grep -qx` and `grep -F -x` are whole-line compares; the `sed` is anchored at `^` and at the following `_`; the `jq` `test` is `^E[0-9]+_S[0-9]+_T[0-9]+$`; the story ID is shape-checked with the width-agnostic glob `E[0-9]*_S[0-9]*` and then a character-class check |

### Sites the story names as already width-agnostic

The story listed these as already width-agnostic and asked for them to be verified and pinned, not rewritten. Line
numbers are the current ones on `main` `3ddb6fc6` (several moved since the story was written). Every one was found as
the story said; none was changed.

| Site named by the story | Current location | Verdict | Pin |
|-------------------------|------------------|---------|-----|
| `commit-subject-check.sh:67` | `skills/j-commit/scripts/commit-subject-check.sh:67`, `BOARD_ID='E[0-9]+(_S[0-9]+(_T[0-9]+)?)?'` | already safe | `tests/wide-id-commit-names.bats` |
| `commits-for-item.sh:162` | `scripts/commits-for-item.sh:162`, validation `^E[0-9]+(_S[0-9]+(_T[0-9]+)?)?$` | safe-by-anchor | `tests/wide-id-commit-names.bats` |
| `todo.js:67,82` | `project/app/api/parsers/todo.js:67` (`TODO_ENTRY_PATTERN`) and `:82` (`LEADING_REF_MISORDER_PATTERN`), both `\d+` | safe-by-anchor | `project/app/api/parsers/dashboard-wide-ids.test.js` |
| `ideas.js:84` | `project/app/api/parsers/ideas.js:84`, `^PROMOTED(?::\s*(E\d+...))?$` | safe-by-anchor | `project/app/api/parsers/dashboard-wide-ids.test.js` |
| `<id>_*.md` lookup `hooks/on_session_end.sh:219` | `hooks/on_session_end.sh:219`, `find -iname "${task_id}_*.md"` | safe-by-anchor | `tests/wide-id-queue-handoffs.bats` (`staleness guard:` cases) |
| `<id>_*.md` lookup `collect-liveness.sh:639` | `skills/j-check-in/scripts/collect-liveness.sh:657`, `"$id"_*.md` | safe-by-anchor | No pin added here (the trailing `_` is the anchor); worktree matching in the same script is pinned by `tests/wide-id-worktree-branch.bats` |
| `<id>_*.md` lookup `render-ranked-list.sh:163` | `scripts/render-ranked-list.sh:176`, `"$dir"/"$id"_*.md` (and the delimiter-class match at `:225`) | safe-by-anchor | No pin added here (anchored by `E86_S02`) |
| `<id>_*.md` lookup `link-external-ref.sh:281` | `scripts/link-external-ref.sh:281`, `"$dir/${ID}"_*.md` and `"$dir/${ID}.md"`, a count other than one is refused | safe-by-anchor | `tests/wide-id-events-and-lifecycle.bats` |
| `<id>_*.md` lookup `check-story-closeable.sh:64,153` | `skills/j-close-story/scripts/check-story-closeable.sh:82` (`"${STORY_ID}_*.md"`) and `:171` (`"${task_id}_*.md"`) | safe-by-anchor | No pin added here (the trailing `_` is the anchor) |

Why a trailing underscore is enough: a task ID is always followed by `_` in a board file name, and the next character
after `E10` in `E100_...` is `0`, not `_`, so `E10_*` cannot match an `E100` file. The same holds one level down
(`E10_S1_*` against `E10_S10_...`).

### Sweep commands

The substring and prefix group (1) is a read-only `git grep` over tracked files, run from the repository root under zsh
(`$=P` word-splits the path list; every pattern is single-quoted; `\b` is not used because the BSD regex library has
none). The generated mirrors `.claude/` and `.agents/` are excluded, as are `*.md`, `*.bats` and `*.json` (prose, tests
and data are not code that matches IDs). Each ID-keyed hit was then read in context, not judged from the grep line.

```zsh
P='scripts skills hooks lib bin'
X=(':!*.md' ':!*.bats' ':!*.json' ':!.claude' ':!.agents')

# S1  grep with a variable in the pattern
git grep -nE '(^|[^A-Za-z_-])grep[^|]*\$' -- $=P $X ':!*.js' | grep -vE '^[^:]*:[0-9]+:\s*#'
# S2  an ID-named variable on a line that matches (=~, grep, sed, awk, find, -name, ls, glob, [[ == ]], case)
git grep -nE '\$\{?[A-Za-z_]*([Ii][Dd]|TASK|STORY|EPIC|task|story|epic)[A-Za-z_]*\}?' -- $=P $X ':!*.js' ':!*.jq' | grep -E '(=~|grep|sed |awk|find |-name|-path|-iname|expr |ls |glob|\[\[.*==|case )' | grep -vE '^[^:]*:[0-9]+:\s*#'
# S3  substring, prefix or suffix globs on a quoted variable in [[ ]] or case
git grep -nE '(==|!=|=~) *"[^"]*\$[^"]*"\*|(==|!=) *\*"[^"]*\$[^"]*"|^\s*"[^"]*\$\{?[A-Za-z_]+\}?[^"]*"\*[^)]*\)|\*"[^"]*\$[^"]*"[^)]*\)' -- $=P $X | grep -vE '^\S+:[0-9]+:\s*#'
# S4  sed with a variable in the script
git grep -nE 'sed .*[sy][/|#,].*\$\{?[A-Za-z_]+' -- $=P ':!*.md' ':!*.bats' ':!*.json'
# S5  awk with index(), ~ var, $0 ~, -v *id*=
git grep -nE 'awk .*(index\(|~ *[a-z_]+|\$0 *~|-v +[a-z_]*id[a-z_]*=)' -- $=P ':!*.md' ':!*.bats' ':!*.json'
# S5b in-place sed, awk !index, $0 ~ var, $0 !~
git grep -nE -e 'sed[^|]*(-i|--in-place)' -e 'awk[^|]*(!index|index\()' -e '[$]0 *~ *[a-z_]+' -e '[$]0 *!~' -- $=P $X
# S6  jq startswith, endswith, contains, index, test, ltrimstr, inside, match
git grep -nE '(startswith|endswith|contains|test\(|index\(|ltrimstr|inside|match\()' -- $=P $X ':!*.js' ':!*.py' | grep -E 'jq|select'
# S7  Python startswith, endswith, "x in text", re.* (embedded Python in *.sh included)
git grep -nE '(startswith\(|endswith\(| in (text|line|content|body|s|name|path|fn|fname|filename|data|raw|stem|ref|subject|msg|message)\b|re\.(search|match|findall|compile|sub|fullmatch)\()' -- $=P $X ':!*.js' | grep -iE 'id|task|story|epic|item|ref|target'
# S8  JavaScript startsWith, endsWith, includes, indexOf, test, match, replace, search, split (project/app/api included)
git grep -nE '\.(startsWith|endsWith|includes|indexOf|lastIndexOf|test|match|replace|search|split)\(' -- scripts skills hooks lib bin project/app/api ':!*.md' ':!*.bats' ':!*.json' ':!*.test.js' ':!.claude' ':!.agents' ':!project/app/api/package-lock.json' | grep -E '\.(js|mjs|cjs):'
# S9  find, ls and for globs built from a variable and followed by a glob (two commands)
git grep -nE -e '-(i?name|i?path|regex) +["'"'"']?[^ ]*[$]' -- $=P $X
git grep -nE -e '(ls|rm|cat|for [a-z_]+ in) [^|;]*[$][{]?[A-Za-z_]+[}]?[^ /"]*[*]' -- $=P $X
# S10 grep, sed or awk with a literal board-ID pattern
git grep -nE '(grep|sed|awk|rg|index)[^|]*(E[0-9]{1,}[_ "'"'"'/)\\]|E\[0-9\]|_S\[0-9|_T\[0-9)' -- $=P $X | grep -vE '^\S+:[0-9]+:\s*#'
# S11 word-boundary and regex-variable matches that could carry an ID (two commands; the second is
#     then filtered by dropping variable names ending RE, REGEX, PATTERN, re or pattern)
git grep -nE '\\b(E|\$|\{|\(|\\\()|\\<' -- $=P project/app/api $X ':!*.test.js' | grep -E 'E\\?\[0-9|E\\d|\$\{?[A-Za-z_]*([Ii][Dd]|TASK|STORY|EPIC)|BOARD_ID|ANY_FRAGMENT|_FRAGMENT'
git grep -nE -e '=~ *"?[$][{]?[A-Za-z_]+' -- $=P $X
# S12 lookups keyed on an ID that none of the patterns above can see: read file by file (28 files,
#     listed in the E86_S05_T01 summary)
```

Counts recorded by `E86_S05_T01` on its tree (base `069f1b6c`): S1 165, S2 118, S3 31, S4 29, S5 5, S5b 32, S6 87,
S7 121, S8 159, S9 14 and 0, S10 29, S11 3 and 5 (after the name filter). Re-run by `E86_S05_T07` on `main` `3ddb6fc6`
(raw counts, S11's second command unfiltered): S1 171, S2 123, S3 31, S4 29, S5 5, S5b 33, S6 88, S7 121, S8 159, S9
14 and 0, S10 32, S11 3 and 58. S3, S4, S5, S7, S8, S9 and the first S11 command are unchanged. The five that grew
(S1, S2, S5b, S6, S10) were diffed against the same commands run on `069f1b6c`; the new hits are the `E76`
`task-usage` additions triaged in the last row of the table (all anchored). The S11 raw count is larger only because
the recorded 5 was filtered by hand.

The per-group search commands, for the other groups, as recorded by their tasks (run from the repository root):

```bash
# Group 2 (E86_S05_T02), fixed-width slices of branch and worktree names; 39 lines, per-site verdicts in the table
git grep -nE '\$\{[A-Za-z_]+:[0-9-]+(:[0-9]+)?\}|cut -c|substr\(|\[A-Z\]\[0-9\]\{?[0-9]|\[0-9\]\{[0-9]|\\d\{[0-9]|E[0-9]{2}|E\[0-9\]\[0-9\]|head -c|\bfold\b|\{1,11\}' -- \
  scripts/create-task-worktree.sh scripts/merge-task-into-perceived-branch.sh scripts/perceived-branch.sh \
  scripts/check-worktree-liveness.sh scripts/worktree-remove-guard.sh scripts/install-worktree-commit-guard.sh \
  scripts/commits-for-item.sh 'skills/j-reconcile/scripts/*.sh' skills/j-check-in/scripts/collect-liveness.sh \
  'skills/j-tidy/scripts/*.sh' settings.json | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'

# Group 3 (E86_S05_T04), fixed-width slices in the queue code (no hits), then the readers of the queue directories (5 hits)
grep -rnE 'cut -c|:0:1[0-9]\}' hooks/on_session_end.sh scripts/*context-digest*.sh skills/j-do/scripts/bundle-resume.sh
grep -rnE 'bundle-\*|queue/handoffs|queue/context|handoffs/' hooks scripts skills lib bin project/app/api

# Group 4 (E86_S05_T05)
grep -nE 'grep[^|]*\$\{?(id|ID)\b|\*\$\{?(id|ID)|sed .*\$\{?(id|ID)|\$\{(id|ID):[0-9]' scripts/events-append.sh scripts/generate-rapport-manifest.sh   # no hits
grep -rnE '_INSTRUCTIONS' scripts hooks lib skills
grep -rnE '\-plan\.md|\-summary\.md' scripts hooks lib project/app/api
grep -nE 'E\\d|E\[0-9|_S\\d|\\d\{' project/app/api/parsers/rapports.js

# Group 6b (E86_S05_T05)
grep -rnE "E[0-9]|_S[0-9]|_T[0-9]|\\d" lib bin --include='*.js' --include='*.sh' | grep -vE '^[^:]+:[0-9]+:\s*(\*|//|#|/\*)'   # no non-comment hit
grep -rnE 'E[0-9]{2}\b|\[0-9\]\{2\}|\\d\{2\}' lib bin                                                                # no hit
grep -nE 'E\[0-9|_S\[|_T\[|\{2\}|\\d|startswith|cut -c' skills/j-uncharted/scripts/*.sh

# Group 5 (E86_S05_T06), dashboard API and UI sources: no startsWith, includes, slice or substring is applied to a board ID
git grep -nE "startsWith|includes\(|endsWith|\.slice\(|substring|substr\(|padStart|padEnd|\.match\(|\.test\(|RegExp|/E\\d|E\[0-9\]|\\d\{|_S|_T" -- project/app/api project/app/ui/src ':!*.test.js' ':!*.test.jsx' ':!**/node_modules/**'
git grep -nE "parseInt|Number\(|localeCompare|\.sort\(|\.replace\(|\.split\(|epic_id|story_id" -- project/app/ui/src project/app/api ':!*.test.js' ':!*.test.jsx' ':!*.css' ':!*manual-verify*'
git grep -nE -A8 "\.(epic|story|task)-id|\.kanban-card-id" -- 'project/app/ui/src/**/*.css'
```

The patterns are quoted as the summaries recorded them; the hit list for each group is in the summary named in the
Groups table. The group 6a (commit names) check needed no sweep: both scripts were read whole and each
validates the ID with the width-agnostic patterns shown in the table.

### Defects and observations

**One defect was found; it was fixed in this story.**

| # | Defect | Disposition | Reference |
|---|--------|-------------|-----------|
| 1 | `scripts/todo_manager.sh remove "<title>"` removed the first line containing the title as a bare substring, so a title ending in an ID (`Alpha: E10_S1`) also matched `Alpha: E10_S10` and `Alpha: E10_S1_T01` | Fixed: when the title ends in a board ID the match must end at that ID; a plain title keeps its meaning; a miss exits 1 and never rewrites the file | Task `E86_S05_T01`, commit `633e39e2`; regression test `tests/todo-manager-remove-id-boundary.bats` |

**Rapports filed during the story** (none is a wide-ID defect; each is listed so that nothing is left undocumented):

| Rapport | What it records | Disposition |
|---------|-----------------|-------------|
| `project/rapports/problems/E86_S05_T01-tester-remarks-full-suite-red-on-base.md` | 24 red cases in 9 suites that are red with identical names on the pre-fix base; two concurrency artefacts; one suite not completed. Finding 3 (low): the `ends_in_id` test in the new `remove` code, `E[0-9]+(_S[0-9]+(_T[0-9]+)?)?$`, has no left anchor, so a title ending in a non-ID word such as `TYPE10` also switches on the end-at-ID rule (behaviour only gets stricter) | Open: not caused by this story; the 8 suites without a baseline entry need an owner (see Suggested Next Steps in the rapport), and finding 3 is an optional one-line tweak |
| `project/rapports/problems/E86_S05_T03-ac1-malformed-task-prefix-cannot-be-rejected.md` | Acceptance criterion 1 of `E86_S05_T03` asks `commit-subject-check.sh` to reject `task(E1001_S100_T): x`; the script classifies any `task(`, `story(` or `epic(` subject as `kind=board` before inspecting the ID (E69 Decision 2), at every width including two digits. A malformed ID is rejected only on the scope-token path (`chore(E1001_S100_T): x`), which is pinned | Open: wording of the criterion, not a width defect; changing the script would contradict E69 Decision 2 and the unchanged two-digit behaviour |
| `project/rapports/problems/E86_S05_T04-trigger-queues-are-pretty-printed-not-jsonl.md` | `hooks/on_session_end.sh` appends each trigger with `echo "$TRIGGER" >> file` from `jq -n` without `-c`, so each record spans about 15 lines; `collect-liveness.sh:613` counts lines as triggers and over-reports. Unrelated to ID width | Open: to be filed as a separate task outside `E86_S05` |

**Observations recorded by the group summaries, not filed as separate items** (each is outside what the audit was to
change, or is a limit of a convenience grammar, and none changes behaviour on the two-digit board):

- `skills/j-reconcile/scripts/resolve-reconcile-scope.sh:248`: the story-range shorthand `S03-05` accepts one to three
  digits per number, so a range such as `S1000-1002` does not match and falls through to the single-ID path, where
  `resolve-id.sh` rejects it with its own grammar error (it fails loudly, not silently). Recorded by `E86_S05_T02` as out
  of its group; wide-range behaviour is `E86_S03_T04`'s. Not independently re-checked by `E86_S05_T07`.
- `scripts/e25_s01_extract_board_graph.py:106` falls back to `path.stem.split("_",1)[0]` when a board file has no `id:`
  field. That is a parse fallback, wrong for stories and tasks at any width, not a substring match (`E86_S05_T01`).
- `skills/j-uncharted/scripts/resolve-segment-target.sh:335` and `run-engine.sh:440`: a hypothetical epic file whose slug
  starts with `S<digit>` would also misparse, at two digits as well; unrelated to width (`E86_S05_T05`).
- `project/app/ui/src/components/board/BoardView.jsx` `epicOrder` and `filterEpicRange` are module-private and so not
  pinned by any automated test; the verdict rests on reading them (`E86_S05_T06`).
- The rendered dashboard DOM was not exercised: the repository carries no prebuilt UI `dist/` build and no real
  browser was available, so the snapshot test proves the data path and the code review covers the render path. The
  third case of `tests/dashboard-snapshot-wide-ids.bats` bundles the real `dist/` and skips with a message when none is
  built (`E86_S05_T06`).
- The mutation check of the worktree and branch tests (breaking `match_worktree` to a fixed-width compare and watching
  cases 12 and 13 fail) was not run, so those tests' discriminating power rests on their design, not on an observed
  red run (`E86_S05_T02`).
- `capture_commit_ref` in `scripts/create-task-worktree.sh` (opted-in projects only) was read and its regex checked but
  not exercised end to end (`E86_S05_T02`).
- `Source-Commit:` tag discovery in `scripts/compute-deploy-reconcile.sh` needs a network and is pinned only as far as its
  extraction regex (`E86_S05_T05`).

### Verification of the table

Run from the repository root with bash. The first command checks that every test path named in the table exists. The
second checks that every row has four non-empty cells and that every verdict is one of the three allowed values. The
third checks that every other repository path the table names (without a placeholder, a glob or a line number) exists.

```bash
sec() { awk '/^## Audit table/{f=1;next} /^## Fixture and regression method/{f=0} f' project/documentation/board-ids.md; }

# 1. every test path named in the audit table exists
sec | grep -oE '(tests/[A-Za-z0-9_.-]+\.bats|project/app/[A-Za-z0-9_./-]+\.(test\.js|manual-verify\.mjs))' | sort -u \
  | while read -r p; do if [ -f "$p" ]; then echo "ok      $p"; else echo "MISSING $p"; fi; done

# 2. the main table: four non-empty cells per row, verdict in the allowed set
sec | awk '/^### Table/{f=1;next} /^### /{f=0} f && /^\| /{ if ($0 ~ /^\| (Site|-+) /) next; rows++
    n=split($0,c,"|"); bad=(n!=6)
    for(i=2;i<=5;i++){ x=c[i]; gsub(/^ +| +$/,"",x); if(x=="") bad=1 }
    v=c[4]; gsub(/^ +| +$/,"",v); if(v!="fixed" && v!="safe-by-anchor" && v!="already safe") bad=1
    if(bad){ bad_rows++; print "BAD ROW " NR ": " substr($0,1,90) } }
  END{ print rows " rows, " bad_rows+0 " bad" }'

# 3. every other repository path named in backticks exists (placeholders, globs and line numbers skipped)
sec | grep -oE '`[^`]+`' | tr -d '`' | sed -E 's/:[0-9][0-9,-]*(:.*)?$//' \
  | grep -E '^(scripts|skills|hooks|lib|bin|project|tests|settings\.json)' | grep -vE '[<*{}() ]|\.\.\.|:$' | sort -u \
  | while read -r p; do [ -e "$p" ] || echo "MISSING $p"; done; echo "path check done"
```

Result of the first command: all 11 paths exist (`ok` for each, no `MISSING`): `tests/todo-manager-remove-id-boundary.bats`,
`tests/wide-id-worktree-branch.bats`, `tests/wide-id-commit-names.bats`, `tests/wide-id-queue-handoffs.bats`,
`tests/wide-id-events-and-lifecycle.bats`, `tests/dashboard-snapshot-wide-ids.bats`,
`project/app/api/parsers/board.mixed-width.test.js`, `project/app/api/parsers/board.numeric-order.test.js`,
`project/app/api/parsers/dashboard-wide-ids.test.js`, `project/app/api/parsers/lib/board-id-sort.test.js` and
`project/app/ui/src/components/board/kanbanColumns.manual-verify.mjs`. All six sibling task branches are merged on
`main` (`3ddb6fc6`), so the check holds from a worktree of `main`.

Result of the second command: `80 rows, 0 bad` (no empty cell, no verdict outside `fixed`, `safe-by-anchor`, `already safe`).

Result of the third command: no `MISSING` line, `path check done`. (A first run flagged two entries that were not paths: a placeholder
`E86_S05_T0N-summary.md` and the gitignored UI build directory `dist/`; both were reworded out of the table text.)

## Fixture and regression method

Owner: `E86_S06`. Two fixtures serve two different questions.

- **Does the new code handle wide IDs?** The mixed-width generator, `tests/helpers/mixed-width-board.sh` (task
  `E86_S06_T01`), writes a throwaway project with `E01`, `E10`, `E11`, `E99`, `E100`, `E101`, `E1001`, `S100` and `T100`.
  It is exercised by `tests/mixed-width-board-scripts.bats`, `tests/mixed-width-board-consumers.bats` and the dashboard
  parser test `project/app/api/parsers/board.fixture-mixed-width.test.js`.
- **Does an existing two-digit board behave exactly as before?** This is the upgrade-and-go regression
  (`tests/e86-upgrade-and-go.bats`, task `E86_S06_T05`), described below. It is the evidence for Decision 1: no
  renaming, no migration step.

### Comparison method

The regression compares the **output of the pre-E86 scripts** with the **output of the current scripts** on one frozen
two-digit board, byte for byte.

1. **Baseline ref: `39c530fa`**, the `HEAD` at decomposition time, before any `E86` change. The comparison is against that
   ref as a whole, so a change in behaviour on a two-digit board, whether `E86` made it or another epic did, would show.
2. **Capture (once, by hand).** `tests/helpers/e86-capture-baseline.sh --write` extracts the ref's `scripts/`, `skills/`,
   `lib/` and `project/app/api/` with `git archive` into a temporary directory, builds the frozen board in a second
   temporary directory, runs every compared invocation with the **baseline** scripts, and writes one output file per
   script to `tests/fixtures/e86-two-digit-golden/golden/`. Those 14 files are committed.
3. **Comparison (every test run).** `tests/e86-upgrade-and-go.bats` builds the same board in `$BATS_FILE_TMPDIR`, runs the
   same invocations with the **current** scripts, and asserts each output file equals its committed golden with `diff`.
   Capture and test call the same function (`e86_run_all` in `tests/helpers/e86-upgrade-and-go-lib.sh`), so the
   invocations, the board, the git history and the output filter cannot drift apart. The test uses the committed goldens
   only: it never needs the git ref, needs no network, writes only below its temporary directory and never reads this
   repository's own `project/` tree. It therefore also runs in the public mirror, where the ref is unavailable.
4. **Each run records** the command, its exit status, stdout and stderr, so a changed exit code or a changed warning is a
   difference like any other.

### The frozen board

`tests/fixtures/e86-two-digit-golden/` holds 66 files: the frozen project tree (51 files under `board/proj/`), the commit
list `commits.txt`, and the 14 goldens.

| Part | Content |
|---|---|
| Generated slice | `tests/helpers/mixed-width-board.sh --two-digit`: epics `E01`, `E10`, `E11`, `E99`, stories `E01_S01`, `E10_S01`, `E10_S10`, `E11_S01`, `E99_S99`, their tasks, plans and summaries, `todo.md`, a bundle manifest, handoffs, a trigger queue, an event log and a rapport |
| Added stories | `E01_S02`, `E01_S03`, `E01_S04` and task `E01_S04_T02` (copies of `E01_S01` with the ID rewritten), so the negotiated legacy inputs `E01s02`, `e01 S04 t02` and `0103` resolve to real items instead of "not found" |
| Real-board slice | six files read from the baseline ref: epics `E02`, `E03`, stories `E02_S02`, `E03_S01`, tasks `E03_S01_T02`, `E03_S01_T04` (real frontmatter shapes: `date_*`, `tasks: []`, long bodies) |
| `commits.txt` | one line per commit (`subject`, TAB, paths): replayed with a pinned author, committer and date into a fresh git repository, so every commit SHA, and with it the bundle manifest's `anchor_sha` and the `commits-for-item.sh` output, reproduces on every machine |

Every ID in every file name has at most two digits per segment. The tree is sanitised (the test greps it for absolute
developer paths and secret-shaped text). It is stored as `board/proj/` and copied to `project/` when the harness is built:
`.publicignore` patterns such as `project/board/` and `project/todo.md` match at any depth, so a `board/project/` copy
would reach the public mirror without its board.

### What is compared

| Script | Invocations (golden file) |
|---|---|
| `scripts/validate-board.sh` | every board file at once; seven malformed IDs in a copy of a task file, which must stay rejected (`validate-board.txt`) |
| `skills/jenga/scripts/board-scan.sh` | no arguments (`board-scan.txt`) |
| `skills/jenga/scripts/cascade-resolve.sh` | epics, stories, a task, an unknown ID and comma lists (`cascade-resolve.txt`) |
| `skills/jenga/scripts/resolve-id.sh` | the legacy inputs `E01s02`, `e01 S04 t02`, `0103`, `E01`, other shorthand forms, comma lists, an unknown ID and junk (`resolve-id.txt`) |
| `skills/index/scripts/board_index.py` | `graph::nodes`, `graph::edges`, `graph::nodes --type Epic` (`board-index.txt`) |
| `skills/j-close-story/scripts/check-story-closeable.sh` | closeable, open and unknown stories (`check-story-closeable.txt`) |
| `skills/j-close-story/scripts/extract-task-diff-stats.sh` | every task, a story ID (usage error) and an unknown task (`extract-task-diff-stats.txt`) |
| `skills/j-do/scripts/bundle-resume.sh` | a story with a manifest (resume), stories without one (fresh) and an unknown story (`bundle-resume.txt`) |
| `skills/j-uncharted/scripts/validate-proposed-items.sh` | an epic and task, a story with and without its sections (`validate-proposed-items.txt`) |
| `skills/j-commit/scripts/commit-subject-check.sh` | every subject of the throwaway history, plus subjects that are not board subjects (`commit-subject-check.txt`) |
| `scripts/commits-for-item.sh` | every epic, story and task ID on the board, plus an unknown one (`commits-for-item.txt`) |
| `scripts/render-ranked-list.sh` | no arguments (`render-ranked-list.txt`) |
| `scripts/next-board-id.sh` | next epic, next story of four epics, next task of six stories (`next-board-id.txt`) |
| Dashboard board listing | `parseBoard()` from `project/app/api/parsers/board.js`, called from Node, printed as JSON (`dashboard-board.txt`) |

**Scripts that did not exist at the baseline.** `scripts/next-board-id.sh` and the shared `scripts/lib/` were added by
`E86`, so there is nothing to run at the ref. The `next-board-id.txt` golden is instead produced by the **old numbering
rule**: the highest number among the existing files of that level, plus one, padded to two digits
(`e86_old_next_id` in the library, copied from `skills/j-todo/scripts/add_trivial_task.sh` at the baseline ref, lines
126 to 142, which numbered tasks that way; epics and stories followed the same rule, and
`skills/j-uncharted/scripts/write-backfilled-epics.sh` used `"E%02d"` for epics). The current allocator must give the
same IDs on a two-digit board: `printf '%02d'` never truncates, so even `E99` followed by `E100` agrees.

### Output filter

One fixed filter, applied identically on both sides, and nothing else is rewritten:

- the harness path becomes `<ROOT>` and the scratch temporary path becomes `<TMP>` (the only absolute paths that appear);
- there is no date, time or random value to normalise: the board's dates are frozen in its files, and the git history is
  built with `GIT_AUTHOR_DATE` and `GIT_COMMITTER_DATE` pinned per commit, with author, committer, global and system git
  configuration, hooks and signing isolated;
- PyYAML is hidden from every script, on both sides (a stub `yaml` module whose import fails), because
  `validate-board.sh` runs an extra strict-YAML check, and prints a warning on stderr, only on a host that has PyYAML. The
  golden therefore describes the no-PyYAML path on every host.

### Accepted differences

None found: every compared output is byte-identical. The differences that would be legitimate, and why they are not in
the compared inputs:

| Difference | Reason |
|---|---|
| Revised-grammar error wording for a digit run that cannot be read unambiguously (`E86_S03`: `10002`, `010`, `100` now say "use letters or separators", where the old grammar said "malformed digit run ... has odd length") | The grammar revision is user-approved (Decisions, item 6). No such input is compared, and every input that resolved before still resolves identically |

### What is not covered

- Wide IDs (`E100` and above, `S100`, `T100`): covered by the mixed-width tests named above, not by this regression.
- Inputs the grammar revision deliberately changes (odd-length digit runs, see the table above).
- The strict-YAML check under PyYAML (hidden, see the filter).
- Scripts outside the list, and agent-instruction prose. `E86_S05`'s audit table is the inventory for those.
- Behaviour on this repository's real board. It is about 1500 files; the frozen slice stands in for it,
  and the six real files in the slice are the check that real frontmatter shapes read the same.

### Nothing renamed, no migration step

`tests/e86-upgrade-and-go.bats` demonstrates both claims on the frozen board:

- After every script ran, the checksum and name of every file under `project/` equal the values taken before, the tree is
  identical (`diff -r`) to the committed frozen tree, and `git status` of the throwaway repository is clean: no file was
  renamed, rewritten, added or deleted.
- The pre-E86 outputs were captured on that untouched board, and the current scripts reproduce them, with no conversion
  command run in between; the only step between "old scripts" and "new scripts" is installing the new scripts.

### Regenerating the goldens

```bash
bash tests/helpers/e86-capture-baseline.sh --check      # baseline run vs the committed goldens; exit 0 means identical
bash tests/helpers/e86-capture-baseline.sh --write      # rewrite golden/ from the baseline run
bash tests/helpers/e86-capture-baseline.sh --refreeze   # rebuild the frozen board and commits.txt, then --write
```

The helper needs the baseline commit in the local object database, so it cannot run in the public mirror (it exits 3 with
a message naming the ref). Regenerate only when the frozen board itself must change. If a current script's output differs
from a golden, that is a finding: either record it in "Accepted differences" with a reason, or it is a defect in the
change. Never rewrite a golden to make the test pass. Verification recorded at task close: on an unmodified checkout,
`--check` reports that the baseline run reproduces the committed goldens byte for byte (14 files).
