# Progress visualisation

This document is the contract of epic `E92` (progress visualisation). It fixes what the progress script counts, what it
prints, and how a status becomes a colour. Every other `E92` task codes against it. Where this document and
`scripts/board-progress.sh` ever disagree, the script wins and this document is corrected in the same change.

Later tasks of `E92` appended their own sections below section 8: the terminal bar (9), the dashboard charts (10), the
pipeline diagram (11), `--summary` and the `j.status` bars (12), and, for the story `E92_S06`, the `--graph` mode (13),
its API routes (14), the epic card bar (15), the overlay dependency tree (16), the restyled terminal bar (17), the scoped
`j.status` block (18) and the label library (19). Sections 9.3 to 9.5 were corrected by `E92_S06_T17` where the restyle
(section 17) had made them wrong.

The rework of 2026-11-13 (`E92_S06_T19` to `E92_S06_T26`, after a browser review of the prototypes in
`project/documentation/prototypes/E92_S06/`) is documented in sections 20 to 28: dependency tree v2 (20), zoom and pan (21),
the Animations toggle (22), the after-task bar on story scope (23), the after-story line (24), the new `j.status` overview
and scope views (25), the `--legacy` and `--all` switch (26), the new label keys (27) and what was and was not checked
(28). The rework is additive: it does not delete the earlier sections, it marks what it replaced as **superseded**
where that text appears (9.2, 12.4, 16 and 18), and the superseded text is kept as history.

The story `E92_S07` (2026-11-13) adds one more section: the large and fullscreen view of the dependency tree (29).

## 1. Purpose and consumers

One script, `scripts/board-progress.sh`, turns the scrum board into status counts per scope and prints them as JSON on
stdout. It makes no model call, writes no file and no board status, so computing progress costs zero model tokens.

Seven consumers read its output and none of them counts:

| Consumer | Story | What it does with the JSON |
|---|---|---|
| Terminal progress bar in `/jenga`, `j.do`, `j.dooo` | `E92_S02` | Renders `totals` as one line |
| Dashboard pie charts (tasks, stories, epics, backlog) | `E92_S03` | Renders `counts` and `totals`, also in the snapshot export |
| Pipeline diagram with the current stage highlighted | `E92_S04` | Reads state only where it needs it |
| `j.status` bars and `--summary` (optional) | `E92_S05` | Renders `totals` next to the existing tables |
| Epic card bar on the Board tab | `E92_S06` | Reads `--graph --counts-only`: one stop per story, percent from the epic's task totals (section 15) |
| Dependency tree in the epic overlay | `E92_S06` | Reads the full `--graph` (`--within <epic>`): tasks, `state`, `blocked_by`, `unlocked_by`, `ready` (section 16) |
| Scoped `j.status` block (`j.status E03`, `j.status E03_S05`) | `E92_S06` | Reads `--graph --within <id>` and lays out the tree, "Ready to take" and "X unlocked by Y" as text (section 18) |

Because the views read one output, the terminal and the dashboard cannot disagree about what "8 of 10" means.

## 2. CLI

Exactly one scope flag per call:

| Flag | Scope |
|---|---|
| `--epic <id>` | One epic: its stories and its tasks |
| `--story <id>` | One story: its tasks |
| `--ids <id>[,<id>...]` | An explicit list of ids, any mix of task, story and epic ids |
| `--backlog` | The items queued in `project/todo.md` (section 6) |
| `--all` | Every epic, story and task on the board, counted per level (`epics`, `stories`, `tasks`) |
| `--by-parent` | Totals per epic (over its stories) and per story (over its tasks), in one pass (section 2.1) |

Options:

| Option | Effect |
|---|---|
| `--items` | Also list `{id, status}` per counted item, ordered numerically |
| `--root <dir>` | Override the working-file anchor; the default comes from `scripts/resolve-root.sh` |

Exit codes:

| Code | Meaning |
|---|---|
| `0` | Ok; JSON on stdout |
| `1` | Internal error |
| `2` | Usage error, or an unknown or malformed id |
| `3` | Empty scope: the scope resolves to zero items; for `--backlog` this includes a missing or empty `project/todo.md` |

For every non-zero exit the message goes to stderr and nothing is printed on stdout. Code `2` (the caller asked for
something that does not exist or is malformed) and code `3` (the request was valid and there is simply nothing in it) are
kept apart on purpose, so the dashboard API can show its "nothing to show" state for `3` without treating it as a
failure, and can report `2` as an error.

Scope resolution as implemented (`E92_S01_T02`): `--epic <id>` and `--story <id>` exit `2` when no epic or story file
carries that id (a story id given to `--epic`, or the other way round, is malformed and also exits `2`); `--epic` exits
`3` when the epic has neither stories nor tasks, `--story` when the story has no tasks. For these two scopes the levels
of the table in section 3 are always present, also when one of them holds zero items (counts `{}`, every total `0`).
`--ids` (`E92_S01_T03`) takes a comma-separated list (a space after a comma is tolerated, and the flag may be repeated).
Each element must match the width-agnostic id grammar (`E86`) and is matched by numeric value, so `E1` and `E01` name the
same epic. Each id is counted at its own level, and an id named twice counts once. An id with no board file at its own
level exits `2` with `board-progress.sh: unknown id: <id>`; a malformed id (`X12`, `E1_T3`, an empty element) exits `2`
with `board-progress.sh: malformed id '<id>' ...`; an empty list exits `2` with `board-progress.sh: empty --ids list ...`.
`--all` (`E92_S01_T03`) is the whole board and always carries the `tasks`, `stories` and `epics` blocks; it exits `3` when
the board has no item. It exists so the dashboard pie charts (`E92_S03`) and `--summary` (`E92_S05`) get whole-board
counts per level without passing every id. `--backlog` (`E92_S01_T04`) counts the board items named by the real entries
of the todo file (`JENGA_TODO_FILE`, else `project/todo.md`) as section 6 describes; it exits `3` when that scope is empty
(a missing or empty todo file, or no entry that resolves to a board item) and never exits `2` for a missing todo file.

### 2.1 `--by-parent` (`E92_S05_T02`)

`j.status` needs a bar for every epic and every story. Calling the script once per item would re-read the whole board
once per item, so `--by-parent` returns them all in one pass. It is a scope of its own: combined with another scope flag,
`--items` or `--summary` it is a usage error (exit `2`). Output (fenced as `text`, not `json`, because the drift guard in
`tests/board-progress-contract.bats` takes the first `json` block of this file as section 3's example):

```text
{
  "schema_version": 1,
  "scope": { "type": "by-parent" },
  "epics":   [ { "id": "E01", "level": "stories", "totals": { "done": 0, "in_progress": 0, "failed": 0, "pending": 0, "rejected": 0, "unknown": 0, "denominator": 0 } } ],
  "stories": [ { "id": "E01_S01", "level": "tasks", "totals": { } } ],
  "warnings": []
}
```

Per epic the `totals` cover its stories (each story belongs to the epic named by its own `epic_id`); per story the `totals`
cover its tasks (each task belongs to the story named by its own `story_id`). The `totals` object, the status table
(section 4) and the denominator rule (section 5) are the ones every other mode uses, so an epic entry equals the `stories`
level of `--epic <id>` and a story entry equals the `tasks` level of `--story <id>`. An epic with no stories and a story
with no tasks are listed with all-zero totals (the renderer shows `0/0`); the mode never exits `3` for an empty parent,
only when the board has no epic file at all. A story whose epic file is missing, or a task whose story file is missing, is
still listed or counted as an item of its own level but belongs to no parent entry, and carries its `orphan_story` or
`orphan_task` warning. Entries are ordered numerically (`E99` before `E100`, `S2` before `S10`) and the output is
byte-identical across runs. On the live board (92 epics, about 530 stories) one run takes the same order of seconds as
`--all` (measured in the `E92_S05_T02` summary).

The script locates the board through `scripts/resolve-root.sh` (reusing `scripts/board_resolver.sh` where it fits) and
hardcodes no `project/...` path.

## 3. JSON shape, `schema_version: 1`

```json
{
  "schema_version": 1,
  "scope": {
    "type": "story",
    "ids": ["E92_S01"]
  },
  "levels": {
    "tasks": {
      "counts": {
        "Pending": 1,
        "In Progress": 1,
        "Passed": 2,
        "Failed": 1,
        "Rejected": 1,
        "Not Started": 1
      },
      "totals": {
        "done": 2,
        "in_progress": 1,
        "failed": 1,
        "pending": 1,
        "rejected": 1,
        "unknown": 1,
        "denominator": 5
      },
      "items": [
        { "id": "E92_S01_T01", "status": "In Progress" },
        { "id": "E92_S01_T02", "status": "Passed" },
        { "id": "E92_S01_T03", "status": "Passed" },
        { "id": "E92_S01_T04", "status": "Failed" },
        { "id": "E92_S01_T05", "status": "Pending" },
        { "id": "E92_S01_T06", "status": "Rejected" },
        { "id": "E92_S01_T07", "status": "Not Started" }
      ]
    }
  },
  "warnings": [
    {
      "kind": "unknown_status",
      "id": "E92_S01_T07",
      "detail": "status \"Not Started\" is not in the status table"
    }
  ]
}
```

The example is illustrative (a story with seven tasks) and is written so that `jq .` accepts it. Its keys are exactly the
keys of the shape, and a consumer may rely on them:

- `schema_version` is the integer `1`. It is incremented on any breaking change to the shape, and this document is
  updated in the same change.
- `scope` is `{type, ids}`. `type` is one of `epic`, `story`, `ids`, `backlog`, `all`. `ids` holds the ids the caller
  named (empty for `backlog` and `all`).
- `levels` holds one block per item level: `tasks`, `stories`, `epics`. A block is `{counts, totals, items}`.
  - `counts` maps a status string to its number of items, listing only statuses with a non-zero count, in the order of
    the status table of section 4 and then any unknown strings in bytewise order.
  - `totals` is `{done, in_progress, failed, pending, rejected, unknown, denominator}` (section 5).
  - `items` is a list of `{id, status}` and appears only with `--items`.
- `warnings` is a list of `{kind, id, detail}`. `kind` is one of `orphan_task`, `orphan_story`, `unknown_status`,
  `todo_unresolved_entry`, `todo_unknown_id`. Warnings never change the exit code. They are ordered with the
  empty-`id` warnings (`todo_unresolved_entry`) first, in todo-file order, and then by the numeric order of their `id`
  (a `todo_unknown_id` warning sits at the position of its id), an `orphan_*` warning before the `unknown_status`
  warning of the same item. The `detail` of an
  orphan warning names what is missing as written in the item's frontmatter (`story E03_S01 has no board file`,
  `epic E04 has no board file`, joined by `; ` when both are missing).

Which `levels` are present:

| Scope | Levels present |
|---|---|
| `--story` | `tasks` |
| `--epic` | `stories` and `tasks` |
| `--ids` | One block per level that has at least one resolved id. An id is counted at its own level: a story id is one story item, not its tasks |
| `--all` | `epics`, `stories` and `tasks` |
| `--backlog` | One block per level that has at least one resolved item (section 6) |

The output is deterministic: no timestamp and no host-dependent value appears anywhere, so the same board and the same
scope give byte-identical JSON on every run.

## 4. Status to colour bucket table (the single table)

The table has one row for every status in `templates/SCRUM_BOARD_SCHEMA.md` "Status Values" (14 rows, in that order) and
the same set as `project/configs/workflow.json` `statuses`, plus the rule for anything else. It is the only mapping; the
script holds it as one table and no consumer carries a copy.

| Status | Bucket | Colour | Reason |
|---|---|---|---|
| `Pending` | `pending` | grey | Created, not yet started |
| `In Progress` | `in_progress` | yellow | Actively being worked on |
| `Passed` | `done` | green | Tests passed, no findings |
| `Passed with remarks` | `done` | green | Tests passed, only non-blocking findings (epic decision 2) |
| `Failed` | `failed` | red | Tests did not pass |
| `Rejected` | `rejected` | muted neutral (blue-grey) | Handled but not delivered; neither done nor remaining (epic decision 3) |
| `Blocked` | `failed` | red | Cannot proceed without a human; red together with `Failed` (epic decision 2) |
| `Backlog` | `pending` | grey | Queued, not started; remaining work |
| `Done` | `done` | green | All child stories and tasks closed out |
| `Merged` | `done` | green | Script-set after `/self-sync` confirmed the ticket's files landed; delivered |
| `Publicized` | `done` | green | Script-set after `/mirror-public` confirmed the ticket's files went public; delivered |
| `Privatized` | `done` | green | Closed-out ticket whose files stay private by `.publicignore`; it is finished, it just never ships |
| `Deployed to Stage` | `done` | green | Script-set from the public repo's stage tag; delivered |
| `Deployed to Prod` | `done` | green | Script-set from the public repo's prod tag; delivered |
| any other string | `unknown` | none (own legend entry) | Surfaced, never dropped (see below) |

Non-obvious rows, with the reason:

- **The five script-set lifecycle statuses and `Done` are `done`.** A ticket reaches `Merged`, `Publicized`,
  `Privatized`, `Deployed to Stage` or `Deployed to Prod` only after it was already judged passed, and `Done` is the
  epic roll-up closing everything beneath it. Counting them as anything but delivered would make a finished board look
  unfinished.
- **`Privatized` is `done`, not `rejected`.** It is a closed-out ticket (schema: set at ticket-close time by a static
  blocklist check). `Publicized` and `Privatized` are mutually exclusive, and `Privatized` is the terminal state of a
  ticket that never leaves the private repo.
- **`Backlog` is `pending`.** It means queued and not yet started. This is unrelated to the backlog *scope* of
  section 6.
- **`Blocked` is `failed`.** The user decided that red covers `Failed` and `Blocked` together.
- **The mapping is level-independent.** The schema calls `Backlog` and `Done` epic-level only, but the board uses them
  elsewhere (measured below), so the same table is applied to tasks, stories and epics.

**Unknown statuses.** A status string that is not in the table lands in the `unknown` bucket. It is listed in `counts`
under its own string, counted in `totals.unknown`, and reported once per item as an `unknown_status` warning. It is never
dropped and never silently mapped to a colour. The script does not fail on it.

**Live-board evidence** (measured on 2026-11-12 over `project/board/epics`, `stories` and `tasks`, 2252 files; the
counts drift as the board moves, the shape of the evidence does not):

| Status | Items | Note |
|---|---|---|
| `Merged` | 722 | Largest single status; it must be `done` or the board reads as mostly unfinished |
| `Publicized` | 90 | |
| `Rejected` | 154 | Large enough that counting it as done or as remaining would distort every chart |
| `Not Started` | 1 | Not in the table; therefore `unknown` (the rule is exercised by a real item) |
| `Privatized` | 1 | A task |
| `Backlog` | 6 | All six are stories, none is an epic |
| `Done` | 146 | 22 epics, 59 stories, 65 tasks |

## 5. Denominator rule

```
denominator = done + in_progress + failed + pending
```

`rejected` and `unknown` are reported separately in `totals`. They are in neither the numerator nor the denominator:
`Rejected` is never counted as done and never as remaining, and an unknown status is neither until someone fixes it.
The progress fraction a consumer shows is `done / denominator`; when `denominator` is `0` the consumer shows its
empty state instead of dividing.

## 6. What "backlog" means as a scope

Decided by the user on 2026-11-12: the backlog scope is **everything queued in `project/todo.md`**, the set of board
items named by its real entries.

- **Real entries** are the lines of `todo.md` that are not blank, not `#` lines and not HTML `<!-- -->` comment lines
  (the `real_entries()` filter of `scripts/todo_manager.sh`, mirrored in miniature by `scripts/render-ranked-list.sh`,
  which also takes the file path from `JENGA_TODO_FILE`, default `project/todo.md`; `board-progress.sh` follows the same
  convention). Each entry has the documented shape `<mission title>: <ref>`, and the ref is the **trailing id** (the
  `TODO_ENTRY_PATTERN` of `project/app/api/parsers/todo.js`, widened here to the `E86` width-agnostic grammar and to
  epic ids).
- **Resolution.** A task id names that task. A story id names that story and expands to every task whose `story_id` is
  it. An epic id names that epic and expands to every story whose `epic_id` is it and every task whose `epic_id` is it.
  Items are counted at the level they belong to (tasks in `tasks`, stories in `stories`, epics in `epics`) and once,
  however many entries name them. A level with no item is absent from `levels`.
- **Orphans, never skipped silently.** A real entry with no resolvable trailing id produces the warning
  `todo_unresolved_entry` (`id` empty, `detail` = line number and entry text). An id that has no board file produces
  `todo_unknown_id` (`id` = the id). Warnings never change the exit code.
- **Empty scope.** A missing `todo.md`, a `todo.md` with no real entry, or entries of which none resolves to a board
  item is an empty scope: exit `3`. Nothing is printed on stdout for a non-zero exit, so the orphans are listed in the
  stderr message in that case.
- **Why this reading.** It is derivable from `todo.md` alone plus the board, it shows the real queue (what `/do` and
  `/dooo` are about to work through), and it matches the eligibility list of `/dooo` (`scripts/render-ranked-list.sh`
  also reads `todo.md`'s real entries).
- **Rejected alternative, and the fact behind it.** "Epics with status `Backlog` and everything beneath them" was
  proposed first and rejected: no epic has status `Backlog` on the board today (checked 2026-11-12: zero), so that
  reading would always show an empty chart. The status `Backlog` itself still maps to the `pending` bucket in the table
  of section 4; that mapping is unrelated to this scope.

## 7. Relations and orphans

Membership is decided by each child's own `story_id` / `epic_id` frontmatter, never by the parent's `tasks:` /
`stories:` lists. A task whose parent story file or epic file does not exist is still counted where its ids place it and
produces a `warnings` entry (`orphan_task`, `orphan_story`); it is never silently skipped. `orphan_task` is a task whose
story or epic file is missing, and `orphan_story` is a story whose epic file is missing.

## 8. Ordering and width

Ids are ordered numerically (`E99` before `E100`; `E92_S01_T02` before `E92_S01_T10`), using `scripts/lib/board-ids.sh`,
never by filename text. Parsing accepts any width, and `E1` matches `E01`.

## Decisions recorded for the `E92` open points

The epic and the story left four points to the breakdown. Three are decided here; the fourth is deliberately not decided here.

| Open point | Status | One-line reason |
|---|---|---|
| What "backlog" means as a scope | Decided (by the user, 2026-11-12): everything queued in `project/todo.md` | It is derivable from `todo.md` plus the board, and the "epics with status `Backlog`" reading would always be empty because zero epics have that status |
| Lifecycle-status mapping (`Merged`, `Publicized`, `Privatized`, `Deployed to Stage`, `Deployed to Prod`, plus `Done` and `Backlog`) | Decided: the lifecycle statuses and `Done` are `done`; `Backlog` is `pending` | The lifecycle statuses are reached only after a ticket passed, `Privatized` is a closed-out ticket, and `Backlog` means queued and not started |
| Unknown-status rule | Decided: an unknown string goes to `unknown`, is listed in `counts`, and raises an `unknown_status` warning, never dropped and never failing the run | Hiding it would understate the board and failing would break every view over one stray status (`Not Started` exists today) |
| Language of terminal labels | Decided: default `en`, `sv` selected with `JENGA_PROGRESS_LANG=sv` (confirmed by the user 2026-11-12; implemented in `E92_S02_T01`) | The JSON of this contract carries status strings and numbers only, no labels |

## 9. Terminal progress bar

Added by `E92_S02_T08`. Every fact below is taken from the merged scripts and skills; where this section and
`scripts/render-progress-bar.sh`, `scripts/lib/progress-labels.sh` or `skills/j-break/scripts/run-progress.sh` disagree,
the script wins and this section is corrected in the same change. The bar is one line, built in three steps by three
scripts, none of which holds a status name twice: `scripts/board-progress.sh` counts (sections 2 to 5),
`skills/j-break/scripts/run-progress.sh` decides which tasks the line is about, and `scripts/render-progress-bar.sh`
draws it.

### 9.1 Where it prints, and who prints

| Caller | When the line is printed | Section that says so |
|---|---|---|
| `/jenga` | After every wave (Phase 4 step b.0, run just before the break check so a stop still shows it) and once after each bundle `/do <E##_S##>` returns (Phase 3.5 step d) | `skills/jenga/SKILL.md`, Phase 0.95 |
| `j.do` (standalone) | After each finished task, right after the execution-ledger call; once per story bundle, after the bundle's cleanup | `skills/j-do/SKILL.md` `### 4.1.3` |
| `j.dooo` | Once per wave, between its step 1 and step 2, so before its break check | `skills/j-dooo/SKILL.md` `### 1.1` |

**`progress_owner`.** A field of the sender object (`skills/j-do/assets/sender_template.json`, empty by default). Empty
means the `/do` that received it is the top-level caller and prints. `caller` means `/jenga` or `/dooo` owns the print:
that `/do` prints nothing and does not resolve the scope. `/dooo` and `/jenga` both pass `progress_owner: "caller"` on
every `/do` call they make (for `/jenga`, the bundle call and every wave dispatch), so a wave shows one line and not one
per task. Known limitation: `/dooo` prints once per wave, but `/do` hands control back after it has launched its background
sub-agents, so the line it prints then shows those tasks as still `In Progress`; it catches up on the next wave.

**Superseded in part (2026-11-13, `E92_S06_T22` and `E92_S06_T23`).** The "line" printed after a finished task or wave is
now always the bar of the task's **story**, and a finished story gets one more line after it; see sections 23 and 24.
The caller table above (who prints, and when) is unchanged.

### 9.2 Scope: run versus parent story (superseded by section 23)

> **Superseded (2026-11-13, `E92_S06_T22`).** The callers no longer resolve a scope: after a finished task or wave they
> run `run-progress.sh --scope story --task <finished task id(s)>`, so the bar always shows the story and never the epic
> or the whole run. The text below describes the earlier rule and is kept as history. `--resolve-scope` and `--scope run`
> still exist in the script, for compatibility, but no `SKILL.md` calls them.

`run-progress.sh` has two scopes and the caller keeps one answer for the whole run.

- **`run`**: the tasks of the run itself, counted with `board-progress.sh --ids`.
- **`story`**: the parent story of one task (`run-progress.sh --scope story --task <task id>`, via
  `board-progress.sh --story`).

**Default rule.** `run-progress.sh --resolve-scope --ids <ids>` prints `run` when the ids expand to at least two distinct
tasks, otherwise `story` (a one-task run would only ever show `0/1` and then `1/1`). A story or an epic id is expanded to
its tasks first. There is no setting that overrides the rule; a caller that wants a scope passes `--scope` itself, and
the three callers above use the rule. **It is resolved once per run**: `/jenga` in Phase 0.95 (after Phase 0.9 on the
bare and scoped branches, right before the first dispatch under `/jenga *`), `/do` once per standalone invocation after
the selection is final, `/dooo` on the first pass. The loop-backs reuse the kept word and never re-make it. An empty
answer (the scope expanded to no task, with a warning on stderr) means no bar for the whole run.

**How the run's scope is formed.** The ids the run was started with are expanded to task ids and unioned with the task
ids this session's execution ledger records (`project/queue/execution-ledger.jsonl`, written by
`skills/j-break/scripts/record-execution.sh`), de-duplicated. The union makes a later `/jenga` wave that adds items
count. The ledger is read by `skills/j-break/scripts/lib/ledger_reader.py` under the session key printed by
`scripts/checklist-marker.sh session-key` (override: `--session KEY`); with no session key the union is skipped. That
reader is the same one `skills/j-break/scripts/render-execution-status.sh` uses for the "ran this session" mark, with the
same terminal-status sets, so the bar and `/break status` agree on what this run has finished.

### 9.3 Colours and the `Rejected` treatment

The cells are drawn in this order, from the buckets of section 4 (`done`, `in_progress`, `failed`, `pending`):

| Bucket | Cell | ANSI code |
|---|---|---|
| `done` | filled (`━`) | 32 green |
| `in_progress` | empty (`╌`) | 33 yellow |
| `failed` | empty (`╌`) | 31 red |
| `pending` | empty (`╌`) | 90 grey |

Each coloured run is closed with `ESC[0m`. Cell counts use largest-remainder rounding over those four buckets only, so
they always add up to the bar width; a non-zero bucket never rounds to zero cells while another bucket has more than one,
and the bar is full only when `pending`, `in_progress` and `failed` are all zero.

**`Rejected` is excluded from the denominator** (section 5), so it is never a filled cell and never a remaining one. It
appears only as a plain-text note at the end of the line (`⊘ 2 rejected (not counted)`), and only when the count is above
zero. The terminal gives the note no colour; the muted blue-grey of section 4 is the dashboard's colour for that bucket.
`unknown` is likewise a text segment only. Each optional segment (`in progress`, `red`, `unknown`, the rejected note)
appears only when its number is above zero, and a `0` denominator prints an all-grey bar with `0/0 · nothing to count`.

**Colour off.** Colour is off when `NO_COLOR` is set and non-empty, when stdout is not a TTY, or with `--color never`;
`--color always` forces it, even over `NO_COLOR`. The text carries every number, so the line is complete without colour;
without it only `done` is told apart from the rest in the bar (filled versus empty cell).

**Glyph fallback.** When the locale is not UTF-8 (the first non-empty of `LC_ALL`, `LC_CTYPE`, `LANG` does not name
UTF-8, or all are empty) the line uses `#` and `-` for cells, `-` for the separator `·`, `(x)` for `⊘`, `>` for the goal
`⚑` and `*` for the star `★`. No multibyte character is printed.

### 9.4 Narrow terminals

The width `W` comes from the first of: `--cols N`, a positive integer in `COLUMNS`, `stty size` when stdout is a TTY (the
terminal is handed over from stderr when that is a terminal, otherwise `/dev/tty`; `tput cols` is not used because it
sizes from its stdout, which is a pipe inside `$(...)`), then `80`. The visible width of the line never exceeds `W`:
every glyph counts as one cell (so `(x)` is three), colour escapes do not count, and the output is always exactly one
line. `MIN_BAR_CELLS` is `4`. In order:

1. The bar is at most `--cells` cells (default `10`) and shrinks so that `[bar] text` fits in `W`.
2. If the room left for the bar is below `MIN_BAR_CELLS`, the bar and its brackets are dropped and the text-only line is
   printed.
3. If the text-only line is still wider than `W`, segments are dropped from the lowest priority upward: `unknown`, then the
   rejected note, then `in_progress`. `done/denominator` and `failed` are never dropped.
4. If those two still do not fit, the text is cut to `W-1` characters and a single `…` is appended (`~` in the ASCII
   fallback).

Rendered by the real renderer for the totals `done 8, in_progress 1, failed 1, pending 0, rejected 2, unknown 0,
denominator 10` (the mixed-with-rejections case; the same input at each width):

```text
W=80  [━━━━━━━━╌╌]⚑ 8/10 · 1 in progress · 1 red · ⊘ 2 rejected (not counted)
W=66  [━━━╌╌]⚑ 8/10 · 1 in progress · 1 red · ⊘ 2 rejected (not counted)
W=62  8/10 · 1 in progress · 1 red · ⊘ 2 rejected (not counted)
W=44  8/10 · 1 in progress · 1 red
W=24  8/10 · 1 red
W=9   8/10 · 1…
```

The first line in the ASCII fallback is `[########--]> 8/10 - 1 in progress - 1 red - (x) 2 rejected (not counted)`, and
the same input with `JENGA_PROGRESS_LANG=sv` gives `[━━━━━━━━╌╌]⚑ 8/10 · 1 pågår · 1 röd · ⊘ 2 avvisade (ej räknade)`. The
goal symbol takes one cell of the width budget, which is why the `W=66` line has a 5-cell bar (it was 6 before the
restyle). Section 17 describes the symbols.

### 9.5 Labels and language

Every user-visible word is in the one table in `scripts/lib/progress-labels.sh`, so a language is a data change:

| Key | `en` (default) | `sv` |
|---|---|---|
| `in_progress` | `in progress` | `pågår` |
| `failed` | `red` | `röd` |
| `rejected_note` | `⊘ %d rejected (not counted)` | `⊘ %d avvisade (ej räknade)` |
| `unknown` | `unknown` | `okända` |
| `nothing` | `nothing to count` | `inget att räkna` |

**The default language is `en`** (`PROGRESS_LABEL_DEFAULT_LANG`; confirmed by the user on 2026-11-12, because the
package is distributed to other projects). `JENGA_PROGRESS_LANG=sv` selects Swedish. The match is exact: any other value,
including an unshipped language or a different case, silently gives the default.

The table has since grown to 17 keys; the twelve added by `E92_S06` are in section 19.

**Adding a language.** In `scripts/lib/progress-labels.sh`: add its code to `PROGRESS_LABEL_LANGS`, and add one
`<lang>:<key>)` line per key of `PROGRESS_LABEL_KEYS` to `_progress_label_raw` (17 lines). `rejected_note` is a `printf`
format string and keeps its `%d`; keep the `⊘` in it, because the renderer swaps it for `(x)` in the ASCII fallback. No
other file changes. Changing the default is the one-word edit of `PROGRESS_LABEL_DEFAULT_LANG`.

### 9.6 A progress problem never fails a run

An unknown id, an empty scope, a missing script, a malformed ledger line or a renderer failure makes `run-progress.sh`
print one `run-progress.sh: warning: ...` line on stderr, print nothing on stdout and exit `0`. Only a usage error (a
missing, conflicting or unknown argument) exits `2`. Every call site treats the print as best-effort, so a progress
problem never blocks, fails or re-statuses a task or ends a run. The renderer itself exits `2` on bad input and prints
nothing, which `run-progress.sh` turns into the same warning.

### 9.7 Out of scope

A live dashboard panel for running executions is out of scope for `E92`. The terminal line and the dashboard charts
(`E92_S03`) read the same `board-progress.sh` output, but nothing in `E92` streams the state of an execution that is
still running into the dashboard.

## 10. Dashboard pie charts (`E92_S03`)

The dashboard has a **Progress** tab (`project/app/ui/src/tabs/ProgressTab.jsx`, registered in `App.jsx`) that draws four
pie charts from `GET /v1/progress`. Like the terminal bar, it counts nothing: the numbers are the ones
`scripts/board-progress.sh` printed.

### 10.1 The `/v1/progress` payload

The route is `project/app/api/routes/progress.js`, mounted at `/v1/progress` in `project/app/api/server.js`. It runs the
script twice (`--all` and `--backlog`) and passes the script's own `counts` and `totals` objects through untouched; the
statuses and the bucket table of section 4 live only in the script. The envelope's `data` is:

```text
{ schema_version, charts: { tasks, stories, epics, backlog } }
```

| Key | Content |
|---|---|
| `schema_version` | The script's, taken from the `--all` result (the `--backlog` one only if `--all` has none) |
| `tasks`, `stories`, `epics` | The matching `levels.<level>` block of `--all` (`{ counts, totals }`), or `{ "empty": true }` when the board has no item at that level |
| `backlog` | The `levels` object of `--backlog` (only the levels that have items), or `{ "empty": true }` when the script exits `3` (a missing or empty `project/todo.md`, section 6) |

The route fills `JENGA_PROJECT_ROOT` and `JENGA_TODO_FILE` (`<root>/project/todo.md`) for the script, so the backlog is the
todo file of the project being served, never the working directory of the API process. A missing script, exit `1` or `2`,
a timeout or output that is not JSON becomes a `500` error envelope whose message names what failed (and, for a missing
script, every directory searched).

**Finding the script.** `project/app/api/lib/run-board-progress.js` (`locateAgentScript`) looks for `board-progress.sh` in
three places, first match wins: `<project root>/scripts/`, `<project root>/node_modules/@jenga-ai/agent/scripts/` (a
consumer install, where the package is a dependency), then the `scripts/` directory of the monorepo checkout, found
relative to the API's own file. In this repository the first place already holds it.

### 10.2 The four charts

| Chart | Plots | Scope |
|---|---|---|
| Tasks | `charts.tasks` | Every task on the board (`--all`, `tasks` level) |
| Stories | `charts.stories` | Every story on the board (`--all`, `stories` level) |
| Epics | `charts.epics` | Every epic on the board (`--all`, `epics` level) |
| Backlog | One block of `charts.backlog` | The items queued in `project/todo.md` (`--backlog`, section 6) |

The three board charts need no further rule. The Backlog chart is the one choice the view makes (`ProgressView.jsx`,
`backlogBlock`): `charts.backlog` holds up to three levels, and the single pie plots the **tasks** block, because the
queue is a list of work to do and a queued story already expands to its tasks (section 6). Only when the queue has no task
does it fall back to the stories block, then the epics block, so a non-empty queue is never shown as empty.

Each pie shows its slices, a legend (label, count, whole percent) and a headline `<done> of <denominator> done`, read from
the script's `totals.done` and `totals.denominator`. A bucket with a zero count has no slice and no legend row. Slice
sizes are the `totals` of the script. The `counts` map is read only to build a slice's tooltip (`Passed: 4, Merged: 1`).
Percents are whole numbers that add up to exactly 100 (largest remainder). The model is `components/progress/progressModel.js`,
the drawing is `components/progress/PieChart.jsx` and the four-chart grid is `ProgressView.jsx`.

### 10.3 Colours, and the `Rejected` treatment

Slices are filled with `var(<token>)`; no colour literal appears in the chart code or in `progress.css`. The tokens are in
`project/app/ui/src/tokens.css`, with a light value, a dark value for the OS preference and one for an explicit
`data-theme="dark"`:

| Bucket | Slice order | Legend label | Token |
|---|---|---|---|
| `done` | 1 | Done | `--color-progress-done` (green) |
| `in_progress` | 2 | In progress | `--color-progress-in-progress` (yellow) |
| `failed` | 3 | Failed or blocked | `--color-progress-failed` (red) |
| `pending` | 4 | Pending | `--color-progress-pending` (grey) |
| `rejected` | 5 | Rejected (not counted) | `--color-progress-rejected` (muted blue-grey) |
| `unknown` | 6 | Unknown status | `--color-border-strong` |

`check-theme-contrast.cjs` (with `check-theme-contrast.test.cjs`) enforces, in both themes, that the five progress tokens
are pairwise distinct (CIE76 delta E of at least 20) and have a contrast ratio of at least 3:1 on `--color-surface`.

**`Rejected`** has its own colour and is never drawn in the colour of a done, in-progress, failed or pending slice. Per
section 5 it is outside the denominator, so the headline `<done> of <denominator> done` leaves it out. It is still shown,
as a slice and as the legend row `Rejected (not counted)`, only when the count is above zero. The pie therefore adds up
all shown buckets, `rejected` and `unknown` included, while the headline uses the script's `denominator`.

**Not by colour alone.** Each pie is an `<svg role="img">` whose `aria-label` spells out the title, the total and every
slice's label, count and percent, and the legend repeats the same figures as text.

### 10.4 How it is drawn

The charts are plain SVG built with `arc` and `pie` from `d3-shape`, a dependency the dashboard already had
(`project/app/ui/package.json`). No charting library was added, and the view fetches nothing from the network at run time
(no CDN script, stylesheet or font, no URL in the data). A pie with a single slice is drawn as a full circle (two half
arcs), because `d3-shape` draws nothing for a 360-degree arc.

### 10.5 Empty state

A chart whose block is empty (`{ "empty": true }`, absent, or with every bucket at zero) shows its title and the text
`Nothing to show`; it is never a blank or broken SVG. The other charts are unaffected, so an empty or missing
`project/todo.md` empties the Backlog chart only.

### 10.6 The snapshot export

`j.dashboard --snapshot` carries the charts. `project/app/api/scripts/capture-snapshot.js` lists `/v1/progress` among the
routes it captures and stores the full envelope under `routes.progress`. In the exported HTML, `get('/v1/progress')` in
`project/app/ui/src/api/client.js` answers from that embedded data and makes no `fetch` call. Both files hold the same
path-to-key map (`/v1/progress` under `progress`); `tests/dashboard-snapshot-progress.bats` fails when they differ. The
data is a point-in-time capture: the charts show the board and `project/todo.md` as they were when the snapshot was taken.
A snapshot taken before `E92_S03` has no `routes.progress`.

How it is tested:

- `project/app/api/routes/progress.test.js`: the payload, the empty cases, the three script layouts and the error paths.
- `project/app/ui/scripts/progress-model.test.cjs`, `progress-view.test.cjs`, `progress-tab.test.cjs`: the pie model, the
  rendered charts and the tab (including the snapshot-mode client path).
- `tests/dashboard-snapshot-progress.bats`: the capture writes `routes.progress`, and the key-map guard.
- `tests/dashboard-snapshot-progress-charts.bats`: runs the real `skills/j-dashboard/scripts/snapshot.sh` over fixture
  projects, renders the embedded `routes.progress.data` with the real `ProgressView` (through
  `project/app/ui/scripts/progress-view-render.cjs`), and checks the four charts, the legend counts, the `Rejected` slice,
  the `Nothing to show` state and that the page names no network URL or charting-library CDN.

**What has not been done.** Nobody has opened a snapshot over a literal `file://` URL. When `E92_S03_T07` was checked in
a browser, the built-in browser pane refused `file://` URLs and Claude in Chrome was not connected, so the check was made
over `http` on `127.0.0.1` instead. The `file://` open is therefore not verified here; what the tests above prove is
that the snapshot carries the data and that the view renders it without a server.

### 10.7 Out of scope

A live panel for running executions is out of scope (section 9.7). The charts show the board as it is when the tab is
loaded (or, in a snapshot, when it was captured) and do not stream an execution in progress. The epic that proposed a live
dashboard (`E48`, live AI item review) stays `Rejected`.

## 11. Pipeline diagram (`E92_S04`)

The Progress tab shows, under the four pies, a diagram of the **Jenga pipeline**: `todo`, `do`, `test`, `rollup`, the
lifecycle in `CLAUDE.md` ("Workflow Lifecycle"). "Processes" here means those four stages of the board's own flow. It does
**not** mean `j.workflow` runs: no workflow run state (`project/.workflows/`) is read. Every fact below is taken from the
merged code; where this section and `scripts/pipeline-stage.sh` disagree, the script wins.

### 11.1 The stage rule

`scripts/pipeline-stage.sh` fixes the rule once. The dashboard only draws what it prints.

| Stage | Count is | Read from |
|---|---|---|
| `todo` | The entries `scripts/todo_manager.sh list` prints | `project/todo.md`, parsed by `todo_manager.sh` (run with the project root as cwd) |
| `do` | `levels.tasks.totals.in_progress` of `scripts/board-progress.sh --all` (an empty board, exit `3`, is `0`) | The task files on the board, through the status table of section 4; the script knows no status name |
| `test` | The lines of `tester_triggers.jsonl` whose `type` is `test_assignment` | `<queue>/tester_triggers.jsonl` |
| `rollup` | The lines of `scrum_triggers.jsonl` whose `type` is `story_rollup` | `<queue>/scrum_triggers.jsonl` |

`<queue>` is `scripts/resolve-root.sh get queue` (`project/queue/` by default). A stage is **active** when its count is above
zero.

**Why `status_review` is excluded.** `hooks/on_session_end.sh` appends a `status_review` trigger to `scrum_triggers.jsonl` at
the end of every session, so counting it would keep `rollup` lit forever. Only `story_rollup` lines count; `status_review`
and `rapport_review` lines do not.

**The honest limit of `test`.** The developer normally calls the tester synchronously, so a `test_assignment` line is
rarely sitting in `tester_triggers.jsonl`. `test` is lit only while such a line is queued, and will usually show `0`. A task
that is being tested right now is counted under `do` (it is still `In Progress`), not under `test`.

**Bad input.** A missing queue file counts `0`. A queue line that is not valid JSON, or is valid JSON but not an object, is
skipped and counted in `skipped` (both queue files together); it never fails the run. Blank lines are ignored.

**Several stages, or none.** Several stages can be active at once and all are listed, in stage order; no single "current"
stage is forced. `idle` is `true` exactly when no stage is active.

**Checked on a fixture.** A throwaway root with two `todo.md` entries, one `In Progress` task, one `story_rollup` plus one
`status_review` line in `scrum_triggers.jsonl`, and one `test_assignment` plus one non-JSON line in `tester_triggers.jsonl`,
gives (the real output of `bash scripts/pipeline-stage.sh --root <fixture>`, exit `0`):

```json
{"schema_version":1,"stages":[{"id":"todo","label":"To do","count":2,"active":true},{"id":"do","label":"Do","count":1,"active":true},{"id":"test","label":"Test","count":1,"active":true},{"id":"rollup","label":"Rollup","count":1,"active":true}],"active":["todo","do","test","rollup"],"idle":false,"skipped":1}
```

`rollup` is `1`, not `2` (the `status_review` line is not counted), and `skipped` is `1` (the non-JSON line). The output has
no timestamp, so equal input gives identical bytes.

### 11.2 The `/v1/pipeline` payload

`project/app/api/routes/pipeline.js`, mounted at `/v1/pipeline` in `server.js`, runs the script with
`--root <project root>` and returns its JSON untouched as the envelope's `data`:
`{ schema_version, stages, active, idle, skipped }`. Nothing is derived in the route. It finds the script the same three
ways as `/v1/progress` (section 10.1). A missing script, a non-zero exit, a timeout or output that is not JSON becomes a
`500` error envelope that names what failed.

### 11.3 What is drawn

`components/progress/PipelineDiagram.jsx` draws four boxes in the fixed order `To do`, `Do`, `Test`, `Rollup`, joined by
arrows. `pipelineModel.js` builds the view model; a stage the payload lacks or carries malformed is drawn inactive with count
`0`.

- **Active stage, not by colour alone.** A fill from `var(--color-progress-in-progress)` (translucent, so the label keeps its
  contrast), an outline four times as thick as an inactive box's, and the text `● active` under the count.
- **Several active stages** are all marked the same way; none is singled out.
- **Idle.** All four boxes are in the normal state and a caption reads `Idle: nothing queued, running, awaiting test or
  waiting to roll up`.
- **Screen readers.** The SVG is `role="img"` with an `aria-label` naming the active stages, or saying none is active.
- No colour literal and no network access; the tokens are those of section 10.3.

### 11.4 In a snapshot

`j.dashboard --snapshot` captures `/v1/pipeline` like the other routes (`routes.pipeline`, key map in `capture-snapshot.js`
and `client.js`, kept in lockstep by `tests/dashboard-snapshot-progress.bats`). The exported page draws the diagram from that
embedded data with no server. Because the data is a point-in-time capture, the diagram carries the caption
`Point-in-time snapshot: reflects the board when it was captured`. The caption is switched on by `isEmbeddedSnapshot()` in
`client.js` (the embedded data element is present); the component does not detect a snapshot itself. A snapshot taken before
`E92_S04` has no `routes.pipeline`, and then only the pipeline section of the tab shows an error; the pies are unaffected.

How it is tested: `tests/pipeline-stage.bats` (the stage rule on fixtures), `project/app/api/routes/pipeline.test.js` (the
route), `project/app/ui/scripts/pipeline-diagram.test.cjs` (the model and the drawing) and
`tests/dashboard-snapshot-pipeline-diagram.bats` (real `snapshot.sh` output rendered with the real component).

**What has not been done.** The literal `file://` open of a snapshot has not been done: the built-in browser pane refused
`file://` URLs and Claude in Chrome was not connected, so the check was made over `http` on `127.0.0.1`, and only in the
light theme. The dark theme of the diagram has not been looked at in a browser.

### 11.5 Out of scope

A live panel for running executions is not built (section 9.7). The diagram shows the stage counts as they are when the tab
is loaded (or, in a snapshot, when it was captured) and does not stream anything.

## 12. Summary mode and `j.status` bars (`E92_S05`)

Added by `E92_S05_T06`. Every fact below is taken from the merged scripts; where this section and
`scripts/board-progress.sh`, `scripts/render-progress-bar.sh` or `skills/j-status/scripts/render-status-bars.sh`
disagree, the script wins and this section is corrected in the same change.

### 12.1 `--summary`

`board-progress.sh <scope> --summary` replaces the JSON with a compact plain-text block, built by the same render pass
from the same totals and the same status table (section 4), so the text and the JSON cannot disagree.

- **Shape.** One line per level the scope holds, in the order `tasks`, `stories`, `epics`:
  `<level> <done>/<denominator> done · <n> in progress · <n> red · <n> pending`, then ` · <n> unknown` and the note
  `⊘ <n> rejected (not counted)` only when that number is greater than 0. The rejected count is a note and never part of
  `done/denominator` (section 5). Warnings follow the block as `warning: <kind> <id>: <detail>` lines.
- **Scope.** There is no default scope. `--summary` is an output switch that goes with a scope flag from section 2
  (`--epic`, `--story`, `--ids`, `--backlog` or `--all`), and a call with no scope flag is a usage error (exit `2`). It
  cannot be combined with `--by-parent` (exit `2`); `--items` is ignored. Exit codes are those of the JSON mode.
- **No colour.** The block carries no colour and no ESC byte (control bytes in a warning detail become `?`), and is
  byte-identical across runs.
- **Languages.** `in progress`, `failed`, `unknown` and the rejected note come from `scripts/lib/progress-labels.sh`
  (section 9.5), so `JENGA_PROGRESS_LANG=sv` translates them. The failed bucket is printed as `red` (`röd` in `sv`).
  `done`, `pending` and the level names are fixed English words, because that library has no key for them; they stay
  English under `JENGA_PROGRESS_LANG=sv`.

Real output of `bash scripts/board-progress.sh --all --summary` on the live board, taken on 2026-11-12 (the numbers move
with the board; the warning is the board's own `E28_S22` status):

```text
tasks    1395/1528 done · 2 in progress · 7 red · 124 pending · ⊘ 101 rejected (not counted)
stories  386/484 done · 23 in progress · 5 red · 70 pending · 1 unknown · ⊘ 46 rejected (not counted)
epics    51/85 done · 15 in progress · 0 red · 19 pending · ⊘ 7 rejected (not counted)
warning: unknown_status E28_S22: status "Not Started" is not in the status table
```

The same call for one story with `JENGA_PROGRESS_LANG=sv`, `--story E92_S05 --summary`:

```text
tasks    5/6 done · 1 pågår · 0 röd · 0 pending
```

### 12.2 `--by-parent` and why it exists

`j.status` shows a bar on every epic row and every story row. Asking `board-progress.sh` once per item would read the
whole board once per item (about 625 reads on the live board: its epics plus its stories). `--by-parent` (section 2.1)
returns every epic's totals (over its stories) and every story's totals (over its tasks) from one read of the board, and
is what `render-status-bars.sh` calls.

### 12.3 The renderer's `--each` batch mode

`scripts/render-progress-bar.sh --each epics|stories|array` renders many bars in one process and one `jq` call. Input
is the `epics` or `stories` array of a `--by-parent` document, or a bare array of `{id, totals}` elements. Output is one
`<id><TAB><bar line>` line per element in input order, and each line is exactly what the single-bar mode prints for the
same totals (one code path, so width, colour, glyph fallback and labels apply per line). An empty array prints nothing;
bad input exits `2` with nothing on stdout. `--level` cannot be combined with `--each`.

### 12.4 Where `j.status` shows the bars (legacy path since `E92_S06_T26`)

> **Superseded as the default (2026-11-13).** `j.status` with no argument now prints the overview of section 25.1, not
> the per-epic and per-story list with a bar on each row. What follows is still exactly how the list works, and it is
> what runs for `j.status --all` (no id) and `j.status --legacy`; see section 26.

`skills/j-status/scripts/render-status-bars.sh` reads the board once with `board-progress.sh --by-parent`, pipes that one
document through `render-progress-bar.sh --each epics` and then `--each stories`, and prints `<id><TAB><bar>` lines, epics
first. It accepts `--cols N`, `--color auto|always|never` and `--root <dir>`; with `auto` it decides colour from its own
stdout, because the renderer only ever sees a pipe. Step 6.9 of `skills/j-status/SKILL.md` runs it once, and step 7
appends each returned bar to the end of the epic or story row whose id it carries (`skills/j-status/assets/output_format.md`).
`j.status` counts nothing and draws nothing itself. Real lines (language `en`, `NO_COLOR` set, ASCII fallback):

```text
E92	[##--------] 1/5 - 4 in progress
E92_S05	[########--] 5/6 - 1 in progress
```

Everything else `j.status` prints is unchanged: the status tables, the task rows (they carry no bar), the open rapports,
the queue depth, the `todo.md` format warning and the dependency-audit section.

### 12.5 When the scripts fail

A bar problem never fails `j.status`. If `board-progress.sh` or `render-progress-bar.sh` is missing, or either call
exits non-zero, `render-status-bars.sh` prints one `render-status-bars.sh: warning: ... (status bars skipped)` line on
stderr, prints nothing on stdout and exits `0`; a board with epics but no stories prints the epic lines only. When the
script prints nothing, is missing or fails, `j.status` prints every epic and story row as it did before bars existed and
shows no error for it. Only a usage error (an unknown or valueless argument) exits `2`.

### 12.6 What has been checked

The scripts are covered by `tests/board-progress-summary.bats`, `tests/board-progress-by-parent.bats`,
`tests/render-progress-bar.bats` and `tests/j-status-bars.bats`; the step 6.9 wiring in `skills/j-status/SKILL.md` by
`tests/j-status-bars-wiring.bats`. `j.status` itself (the step 6.9 wiring) was verified statically only, by reading the
skill and running those tests; it was not run in a live session, so nobody has watched the bars appear in a real
`j.status` output.

## 13. The `--graph` mode (`E92_S06`)

Added by `E92_S06_T17`. Every fact below was checked against the merged code: `scripts/board-progress.sh` (the header
comment and `graph_end`, `derive_states`, `collect_blockers`), `project/app/api/routes/progress-cards.js`,
`project/app/api/routes/progress-graph.js`, the UI components named in sections 15 and 16, `scripts/render-progress-bar.sh`,
`skills/j-status/scripts/render-status-scope.sh`, `scripts/lib/progress-labels.sh` and `scripts/progress-labels-json.sh`.
Where this part and a script disagree, the script wins and this part is corrected in the same change.

`board-progress.sh --graph [--counts-only] [--within <id>] [--root <dir>]` is the one batch call behind the epic card bar,
the overlay dependency tree and the scoped `j.status` block. It reads the board once and adds no counting of its own: the
totals are the same objects `--epic` and `--story` print (same load stage, status table of section 4 and denominator rule
of section 5). It is a scope of its own: combined with another scope flag, `--items` or `--summary` it is a usage error
(exit `2`), and it exits `3` only when the board has no epic file at all.

### 13.1 Shape

The output is JSON with `schema_version: 1` and `scope: {"type": "graph"}`, in numeric id order. The example below is
fenced as `text` because `tests/board-progress-contract.bats` reads the first `json` block of this file; it shows the
fields, not live numbers.

```text
{
  "schema_version": 1,
  "scope": { "type": "graph", "within": "E92_S05" },     "within" only with --within
  "epics":   [ { "id", "title", "depends_on": [..],
                 "stories": { "totals": {..}, "complete": <number of complete stories> },
                 "tasks":   { "totals": {..} },
                 "ready_count": <ready tasks under the epic> } ],
  "stories": [ { "id", "epic_id", "title", "depends_on": [..], "totals": {..},
                 "complete": true|false, "stop": "done|in_progress|failed|pending|rejected",
                 "ready_count": <n> } ],
  "tasks":   [ { "id", "story_id", "epic_id", "title", "status", "bucket", "state",
                 "depends_on": [..], "blocked_by": [..], "unlocked_by": "<id>"|null } ],
  "ready": [ "<task id>", .. ],
  "external": [ { "id", "status", "bucket" } ],          only with --within
  "warnings": [ { "kind", "id", "detail" } ]
}
```

- **Epics.** `stories.totals` is the epic's totals over its stories, `stories.complete` the number of stories whose
  `complete` flag is true, and `tasks.totals` the totals over every task under the epic. The card percent is
  `tasks.totals` done divided by its denominator (section 15).
- **Stories.** `complete` is true when the story's task denominator is above 0 and `done` equals it (rejected tasks are
  excluded, as everywhere). `stop` is the story's single colour bucket, decided in this order: `rejected` when the story's
  own status is `Rejected`; `done` when `complete`; `failed` when any task is failed; `in_progress` when any task is in
  progress or some but not all are done; otherwise `pending`.
- **Tasks.** `status` is the raw status, `bucket` its bucket from section 4, `state` the dependency-aware state of
  section 13.2.
- **`--counts-only`.** Leaves out the `tasks` array and changes nothing else. It is the card payload: the Board tab never
  receives tasks.
- **`depends_on` parsing.** Every form found on the board is read (empty, scalar, comma separated, inline list, YAML block
  list). An id that matches a board file by numeric value (`E1` is `E01`) is printed as that file's own id; any other id
  stays as written and is reported as an `unknown_dependency` warning. An edge points from an item to each id in its
  `depends_on`.

### 13.2 Task states, `blocked_by`, `unlocked_by`, `ready`

`state` is one of `done`, `in_progress`, `failed` (the failed bucket: `Failed` and `Blocked`), `rejected`, `unknown` (a
status outside the table), or, for a task in the pending bucket, `ready` or `locked`:

- **`ready`** when every id in the task's own `depends_on` AND in its story's `depends_on` is satisfied; otherwise **`locked`**.
- **Satisfied** means the item the id names (task, story or epic) is in the done bucket through its OWN status, or is
  rejected (rejected work is excluded everywhere). A dependency that is failed, in progress, pending or of unknown
  status is not satisfied, so a task that depends on a failed item stays `locked`. The status of a dependency's children
  is not consulted: a story that depends on another story is satisfied by that story's own status.
- **`blocked_by`** lists the unsatisfied ids (the task's own, then its story's, each once); it is `[]` unless the state
  is `locked`.
- **`unlocked_by`** is set for a `ready`, `in_progress` or `done` task with at least one `depends_on`: the done
  dependency of the task's OWN `depends_on` that finished last (the larger `date_completed` wins; a tie or missing dates
  fall back to the larger id by numeric order, so `E10` is above `E9`). It is `null` when there is none.
- **`ready`** (top level) lists the ready task ids in numeric order; `ready_count` per epic and per story is the number
  of ready tasks under it.

The reader never re-derives any of this: the card bar, the tree and the scoped `j.status` block all take `state`,
`blocked_by`, `unlocked_by` and `ready` as given.

### 13.3 `--within <id>`

Only with `--graph`. `<id>` is an epic or a story id in any width (`E3_S5` equals `E03_S05`). The `epics`, `stories`,
`tasks` and `warnings` arrays are restricted to that scope: an epic scope lists that epic only, a story scope lists no
epic. `depends_on` keeps its edges to items outside the scope, and every outside board item the scope references through
them is listed once under `external` (`{id, status, bucket}`, numeric order; the key is present, possibly empty, only
with `--within`); `scope` gains `within`. State is computed over the whole board first, so a restricted payload and the
whole-board payload give the same `state` for the same task. A malformed id, a task id, an unknown id, or `--within`
without `--graph` exits `2`.

### 13.4 Dependency warnings

Warnings keep the `{kind, id, detail}` shape and, besides the load-stage kinds of section 7, two are added by `--graph`:

- `unknown_dependency` (`id` = the dependent): a `depends_on` entry names no board item. It does not block anything.
- `dependency_cycle`: the item is a member of a cycle. The walk terminates; the members of a cycle stay `locked` and each
  gets one warning.

## 14. The API routes and the snapshot keys (`E92_S06`)

Both routes are thin: they run `scripts/board-progress.sh` through `project/app/api/lib/run-board-progress.js` (an
`execFile`, never a shell) and add the label table from `scripts/progress-labels-json.sh` (a failing labels script gives
`labels: {}`, never a failed route). Nothing is counted in the API. Both are registered in `project/app/api/server.js`.

| Route | Script call | `data` | Used by |
|---|---|---|---|
| `GET /v1/progress-cards` (`project/app/api/routes/progress-cards.js`) | `--graph --counts-only` | `{ schema_version, epics, stories, labels, lang }`; `{ empty: true, labels, lang }` for an empty board (script exit `3`) | The Board tab, once, for every epic card |
| `GET /v1/progress-graph[?within=<id>]` (`project/app/api/routes/progress-graph.js`) | `--graph [--within <id>]` | The whole `--graph` output plus `labels` and `lang`; `{ empty: true, labels, lang }` for an empty board | The epic overlay only; the card never requests it |

`within` is checked against `^E\d+(_S\d+)?$` before it reaches the script. A malformed value (a task id, text, an array)
is a `400` with the error code `INVALID_QUERY_PARAM`. **A well-formed id that names no board item is also a `400`, not a
`404`**: the script exits `2` for it and the route maps that exit to the same `400` and the script's own message. Any other
failure is a `500`. A snapshot has no server, so it cannot filter.

**Snapshot keys.** `project/app/api/scripts/capture-snapshot.js` captures both routes once each into the artifact's
`routes` map as `progressCards` (`/v1/progress-cards`) and `progressGraph` (`/v1/progress-graph`, captured without a
query, so the whole board); `project/app/ui/src/api/client.js` maps the request paths to those keys, and
`skills/j-dashboard/scripts/snapshot.sh` needs no flag for it. The UI filters the whole-board payload client-side (section
16.5). The two mappings must be kept in step by hand, as the comment in `client.js` says.

## 15. The epic card bar (`E92_S06`)

Components: `project/app/ui/src/components/progress/EpicProgressBar.jsx`, its pure model `epicBarModel.js` and the styles in
`progress.css`. `project/app/ui/src/tabs/BoardTab.jsx` requests `/v1/progress-cards` in parallel with the board and never
waits for it; `project/app/ui/src/components/board/EpicCard.jsx` renders the bar when an entry for the epic exists. The
decisions:

- **One stop per story.** The stops come from the epic's story entries, in order.
- **Only a completed story is green.** A stop is `done` only when the story's `complete` flag is true; a story that is
  not complete is never drawn as done, whatever its `stop` says. The other stops take the script's `stop` bucket: yellow
  in progress, red failed, grey pending, muted `rejected`.
- **No text on the stops**, and the bar is **not animated** (`progress.css` declares no animation or transition for it).
- **The percent beside the bar is done tasks divided by total tasks** of the epic (`tasks.totals`), rounded to a whole
  percent, and `0` when the denominator is 0. It is not the share of complete stories.
- **Colours** are the `--color-progress-*` tokens in `tokens.css` (the section 4 contract: green done, yellow in
  progress, red failed and blocked, grey pending, muted `Rejected`); no colour literal is in the component or its CSS.
- **Accessibility.** The wrapper is `role="img"` with an `aria-label` filled from the `card_bar_aria` label (`%d of %d
  stories complete, %d%% of tasks done`); the percent text and the stops are `aria-hidden`.
- **Empty and failing cases.** An epic with 0 stories draws a track with no stops and `0%`; an epic with 0 tasks shows
  `0%`. If `/v1/progress-cards` fails, or a snapshot lacks the key, the cards show no bar and no error banner.

## 16. The overlay dependency tree (`E92_S06`)

> **Superseded (2026-11-13, `E92_S06_T19` to `E92_S06_T21`).** The layout, the node marks and the edge direction in 16.1
> and 16.2, the loading width in 16.3 and the animation list in 16.4 describe the first tree (v1). The tree v2 of sections
> 20 to 22 replaces them: columns across the whole epic with story bands and start nodes, a gate icon, folding, a hover
> chain, a scaling goal, zoom and pan, and the Animations toggle. Sections 16.3 (the overlay loads the tree, never the card)
> and 16.5 (the snapshot) still hold. This section is kept as history.

Components: `project/app/ui/src/components/progress/DependencyTree.jsx` (SVG), `dependencyTreeModel.js` (layout only),
`dependency-tree.css`, mounted by `EpicTreeSection` in `project/app/ui/src/components/history/EntryDetailPanel.jsx` for
epic entries. The model takes the `--graph` payload and selects the epic's tasks itself; it derives no state.

### 16.1 What is drawn

Stories are groups, tasks are nodes, `depends_on` are edges (drawn from the dependent to its dependency, which sits in an
earlier column), and the epic is the goal node at the right; nodes nothing depends on connect to the goal. A dependency on
an item outside the epic is a dashed boundary node in a column at the left, carrying only `{id, status, bucket}` from the
payload's tasks, else its `external` list. Below the drawing are the "Ready to take" list (`ready` of the payload, each
with a plus) and one "X unlocked by Y" line per task whose `unlocked_by` is set. The layout is by dependency depth (column)
and story group (rows); a cycle cannot hang it.

### 16.2 States and marks

A state is never carried by colour alone: every node has a mark, and an `aria-label` and `<title>` of
`<state label>: <id> <title>`.

| State | Border | Mark |
|---|---|---|
| `done` | green | tick |
| `in_progress` | yellow, thicker | half-filled circle |
| `ready` | grey, thicker; pulses | plus |
| `locked` | grey, dashed | padlock |
| `failed` | red, thicker | cross |
| `rejected` | muted blue, dotted; title struck through | dash |

Colours are `--color-*` tokens only, so the tree follows the light and the dark theme. An epic with no tasks, or a payload
the model cannot read, shows the `tree_empty` label instead.

### 16.3 Loading: overlay only

The tree is never part of the card. `EpicTreeSection` mounts only for entries of kind `epic`, so no other overlay kind makes
the request. Live it asks `GET /v1/progress-graph?within=<epic id>`. While it loads the overlay shows the spinner; on a
failure it shows one muted line, `Dependency tree unavailable.`, and nothing else in the overlay changes. A response that
arrives after the overlay changed epic is dropped, so one epic's tree is never shown under another. The overlay scrolls the
tree sideways and keeps it at least 720 px wide rather than shrinking it.

### 16.4 Animation and `prefers-reduced-motion`

The edges draw in once (700 ms) and the nodes in the `ready` state pulse (a 1.8 s stroke-opacity loop), plus a 150 ms stroke
transition on node borders. **All of it is declared inside `@media (prefers-reduced-motion: no-preference)`** in
`dependency-tree.css`, and the base rules show the final state, so a user who asks for reduced motion sees a still tree.
**Honest limit:** this was verified by reading the stylesheet. It was not checked in a browser with the preference set.

### 16.5 In a snapshot

The embedded `progressGraph` is the whole board. `loadEpicGraph` (in `EntryDetailPanel.jsx`) asks for the path without a
query when `isEmbeddedSnapshot()` is true, so the tree works from a `file://` snapshot, and `buildDependencyTreeModel`
selects the epic from the full payload. Because a restricted and a whole-board payload carry the same per-task state, the
tree is the same live and in a snapshot. A snapshot made before `E92_S06` has no `progressGraph` key; there the overlay
shows the unavailable line.

### 16.6 What was not done

The tree was built **without the original concept SVG**: the file named as a design reference in the story's context
(`tree.svg`) was not used, so the layout, node sizes and spacing follow the written description and
the model of `dependencyTreeModel.js`, not the concept drawing. The tree has been checked by the model and component tests
(`project/app/ui/scripts/epic-overlay-tree.test.cjs`), not compared against the concept.

## 17. The restyled terminal bar (`E92_S06`)

`scripts/render-progress-bar.sh` was restyled by `E92_S06_T12` with the symbols of the concept set. The change is
cosmetic and stays in bash: no Node dependency, and the counting, colour rules, width rules and labels are untouched.

- **Cells.** `━` is a filled cell (done, green) and `╌` an empty one (in progress yellow, failed red, pending grey).
- **Goal symbol**, printed right after the bar: `⚑` while work remains, `★` when the denominator is above 0 and everything
  counted is done (nothing pending, in progress, failed or unknown). With denominator `0` there is no goal symbol. The
  symbol belongs to the bar form; the text-only fallback prints none.
- **`⊘`** still marks the rejected note and `·` still separates segments.
- **`●`, `◉`, `○` are not in the one-line bar.** They are used by the scoped `j.status` block (section 18). The line needs
  no per-item markers.
- **One line.** The output is exactly one line, as before; the width budget now reserves the goal symbol, so a bar is one
  cell narrower at a given width than it was.
- **Fallbacks.** `NO_COLOR` and `--color` behave as in section 9.3. A non-UTF-8 locale gives `#` `-` for cells, `>` for the
  goal, `*` for the star, `(x)` and `-`. Narrow terminals follow the rules of section 9.4 unchanged (drop the bar, then
  segments, then truncate).
- **No rich block in `/dooo`.** The rich multi-line block of the concept demo was not built. `/dooo` prints the single line
  once per wave (section 9.1), and `tests/progress-bar-wiring-dooo.bats` asserts that it is one single-line print per wave
  with no multi-line flag.

Real output of the renderer for `done 8, in_progress 1, failed 1, rejected 2` of 10, then the all-done and empty cases:

```text
[━━━━━━━━╌╌]⚑ 8/10 · 1 in progress · 1 red · ⊘ 2 rejected (not counted)
[########--]> 8/10 - 1 in progress - 1 red - (x) 2 rejected (not counted)
[━━━━━━━━━━]★ 4/4
[╌╌╌╌╌╌╌╌╌╌] 0/0 · nothing to count
```

(the second line is the same input in a non-UTF-8 locale).

## 18. The scoped `j.status` block (`E92_S06`)

> **Superseded as the default (2026-11-13, `E92_S06_T25`, `E92_S06_T26`).** `j.status <id>` now runs the scope view of
> section 25.2. The block below is what `render-status-scope.sh` prints, and it is what `j.status --legacy <id>` still runs,
> unchanged; step 6.10 of `skills/j-status/SKILL.md` is the legacy path. Kept as history and as the legacy contract.

`j.status` called with one epic or story id (for example `j.status E03` or `j.status E03_S05`) prints an extended block after
the scoped part of the overview. The plain overview never shows it. The block is produced by
`skills/j-status/scripts/render-status-scope.sh <id>`, which `skills/j-status/SKILL.md` calls once in step 6.10 and whose
output step 7 prints unchanged (layout in `skills/j-status/assets/output_format.md`). The script counts nothing and holds no
dependency logic: it reads `board-progress.sh --graph --within <id>` once and lays out `state`, `ready`, `unlocked_by`,
`depends_on`, `complete` and `stop`.

- **Tree.** A heading, the goal line (`⚑ Goal: <id>`, `★` when every story in the scope is complete), then each story (its
  `stop` symbol, id, title and `╌╌ <depends_on>`) with its tasks indented below it (state symbol, id, state word, title and
  the task's `depends_on`; `━━` before the dependencies of a task that is not blocked, `╌╌` when it is locked, failed or
  rejected). With no edge in the scope the tree is replaced by the `tree_empty` label.
- **Symbols.** `●` done (green), `◉` in progress (yellow) or failed (red), `○` pending, locked or rejected (dim); ASCII
  stand-ins `[x] [~] [ ] > * = -` in a non-UTF-8 locale. A state is also written as a word, so colour is not required.
- **Narrow terminals.** Under 50 columns (`--cols`, else `COLUMNS`, else 80) the tree becomes a flat list, one task per line.
- **"Ready to take"** lists the payload's `ready` ids with their titles, or the `nothing_ready` label; then one `X unlocked by
  Y` line per task with `unlocked_by`.
- **Colour** only when stdout is a terminal and `NO_COLOR` is empty (`--color always|never` overrides); control bytes in
  titles become `?`.
- **A problem never fails `j.status`.** A missing script or library, a failing `board-progress.sh`, malformed JSON or no `jq`
  gives one stderr warning, nothing on stdout and exit `0`; `j.status` then prints as before. Only a usage error (a task id,
  a malformed id, an unknown flag) exits `2`.

Real output, `bash skills/j-status/scripts/render-status-scope.sh E92_S05 --cols 100 --color never` (abridged to two task
rows, language `en`):

```text
Dependency tree (E92_S05)
★ Goal: E92_S05
  ● E92_S05 Bars and counts in j.status, and a --summary mode on the shared script (optional) ╌╌ E92_S01
      ● E92_S05_T01 Done · Add the --summary mode ... ━━ E92_S01_T05, E92_S02_T01
      ● E92_S05_T02 Done · Add the --by-parent mode ... ━━ E92_S05_T01

Ready to take
  Nothing is ready to take right now

  E92_S05_T01 unlocked by E92_S01_T05
  E92_S05_T02 unlocked by E92_S05_T01
```

## 19. Label library additions (`E92_S06`)

Every new word of the card bar, the tree, the scoped block and the API payload comes from `scripts/lib/progress-labels.sh`,
in the language of section 9.5: English by default, Swedish with `JENGA_PROGRESS_LANG=sv` (exact match; anything else gives
the default). No label is written in a component or in a `SKILL.md`. The twelve keys added by `E92_S06` (the rework of 2026-11-13 added
fifty-one more, listed in section 27):

| Key | `en` | `sv` |
|---|---|---|
| `ready_to_take` | `Ready to take` | `Redo att ta` |
| `unlocked_by` | `%s unlocked by %s` | `%s upplåst av %s` |
| `tree_title` | `Dependency tree` | `Beroendeträd` |
| `goal` | `Goal` | `Mål` |
| `state_done` | `Done` | `Klar` |
| `state_ready` | `Ready` | `Redo` |
| `state_locked` | `Locked` | `Låst` |
| `state_failed` | `Failed` | `Misslyckad` |
| `state_rejected` | `Rejected` | `Avvisad` |
| `tree_empty` | `No dependencies in this scope` | `Inga beroenden i detta omfång` |
| `nothing_ready` | `Nothing is ready to take right now` | `Inget är redo att ta just nu` |
| `card_bar_aria` | `%d of %d stories complete, %d%% of tasks done` | `%d av %d berättelser klara, %d%% av uppgifterna gjorda` |

`unlocked_by` (two `%s`, task id then the unlocking id) and `card_bar_aria` (`%d` complete stories, `%d` total stories,
`%d%%` percent, in that order) are format strings and keep their placeholders; the caller fills them in. The in-progress
state of the tree reuses the existing `in_progress` key.

**The JSON exporter.** `scripts/progress-labels-json.sh` prints `{"lang": "<effective language>", "labels": {...}}` for every
key of `PROGRESS_LABEL_KEYS` in key order, honouring `JENGA_PROGRESS_LANG`, with the format strings left raw. It makes no
model call and needs no `jq`. The two API routes of section 14 add that object's `labels` and `lang` to their `data`, which
is how the browser gets the same words as the terminal; a component that lacks a key falls back to an English default in
its own source, so an older payload still renders. The label table is covered by `tests/progress-labels.bats`.

## 20. Dependency tree v2 (`E92_S06_T19`, `E92_S06_T20`)

Reworked after the browser review of 2026-11-13; the visual and behavioural reference is the approved prototype
`project/documentation/prototypes/E92_S06/tree-prototype.html`. It replaces the layout, marks and edge direction of
section 16.1 and 16.2 (superseded). The split is the same as before: `dependencyTreeModel.js` is pure (layout and
presentation facts only, no colour, no word, no state of its own, nothing counted that the payload does not already state)
and `DependencyTree.jsx` with `dependency-tree.css` draws it. Everything is still loaded only in the epic overlay (16.3)
and from the embedded `progressGraph` in a snapshot (16.5). The numbers below are `LAYOUT` in the model.

### 20.1 Depth columns

Columns are dependency depth **across the whole epic**, not per story: a task sits one column to the right of its deepest
in-epic dependency (the layout cannot hang on a cycle). A dependency on an item outside the epic is a **boundary node**
(dashed border, only `{id, status, bucket}` from the payload) drawn in a column of its own at the left of the drawing; it
never creates a depth column. Columns start at x 280 and are 260 apart; a card is 200 by 48.

### 20.2 Story bands and start nodes

Each story is one horizontal **band**, and each band has a **start node** at its left (200 by 68): the story id, its
done/total (from the payload's `totals`; from the tasks' own `bucket` only when a `totals` object is absent), its title
cut to 28 characters and a mini bar. Tasks with no dependency inside the epic branch from their own story's start node (edge
`kind: start`). Rows inside a band are deterministic (the same input gives a deep-equal model).

### 20.3 Edges

- **Direction.** An edge `{ from, to }` runs from the dependency to the dependent: it leaves the **right** edge of the
  dependency and arrives at the **left** edge of the dependent (the gate badge included). This reverses the v1 convention
  of 16.1, and the model header states it.
- **Kinds.** `dependency` (task to task), `boundary` (an outside node to a task), `start` (a start node to a task with no
  in-epic dependency) and `goal` (only a task that **nothing in the epic depends on** connects to the goal).
- **Above the bands.** The paint order is bands, then edges, then start nodes, boundary nodes, collapse headers, cards and
  the goal, so no band fill hides a line.
- **Dotted cross-story edges.** An edge between two stories (and every boundary edge) carries `crossStory` and is drawn dotted
  (`dt-edge-cross`). The colour of an edge follows the state of the **dependent**: done green, in progress yellow, failed red,
rejected muted, ready grey and dashed (it flows, see 22.3), and a locked dependent green only when its dependency is done,
else a neutral border colour. Edges are de-duplicated by `from` and `to`; while a chain is highlighted (20.6) the other
edges drop to 10 % opacity.

### 20.4 The gate icon and the status marks

A small circular **gate badge** sits on the left edge of a card and answers one question, "is this task waiting for a
dependency?". It is derived from the dependencies' `bucket === 'done'` (a rejected dependency does **not** open it):

| Gate | Shown | Meaning |
|---|---|---|
| `none` | no badge | the task has no dependency |
| `locked` | closed grey padlock | at least one dependency is not done |
| `open` | open green padlock | it has dependencies and every one is done |

The **status mark** stays on the right of the card: tick (`done`), half-filled dot (`in_progress`), **plus on every ready
task**, cross (`failed`), dash (`rejected`). A **locked task shows only the closed gate**, no status mark. A state is never
carried by colour alone: the marks, the gate, the `aria-label` and the `<title>` all state it in words from the labels.
The padlock shapes are the prototype's final path values, and a test asserts that the open shackle's bounding box, stroke
included, lies inside the badge circle.

### 20.5 Group folding

When **more than 5** tasks (`FOLD_THRESHOLD = 5`) share one state inside one story and one column, they fold into **one
stacked card** ("N tasks . state", with a "Show all N" action); click, Enter or Space expands it and an expanded group gets a
"Collapse" header. The edges of a group are the union of its members' edges, and `unfoldGroups(model, expandedIds)`
re-lays out with chosen groups open. The expansion state lives in the component, not in the model.

### 20.6 The hover chain

Hovering or keyboard-focusing a card highlights its **full upstream and downstream chain** and dims everything else (the
model precomputes `upstream` and `downstream` per node; a group carries the union of its members'). A tooltip lists
"Depends on" and "Unlocks", or "Leads straight to the goal" for a task that connects to it directly. The tooltip is HTML
anchored to the drawing; since zoom and pan (section 21) it is positioned in pixels and follows the view.

### 20.7 The Goal and its progress scaling

The goal is a star in a disc with a **progress ring**, drawn from the epic's done and total (`goal.fraction`, `percent`,
`done`, `total`, `reached`; from the payload's epic totals, rejected not counted, no division by zero). It scales with the
completed share `p` (0 to 1):

- the **halo** has strength `0.07 + 0.38 p` (`--goal-halo-opacity`) and radius `(54 + 26 p) / 54` times its base
  (`--goal-halo-scale`); the halo "breathes" (a slow opacity loop), and the radiating pulse of v1 is gone;
- the **star fills from the bottom** with `p`, and the ring shows the same share with the `goal_progress` text ("done / total · percent %");
- at `p = 1` (`goal.reached`) the goal gets `dt-complete`: green, a **shimmer** sweep, **five sparks** that twinkle, and the
  `goal_reached` word.

### 20.8 Words, colours and checks

Ten new label keys (`gate_waiting`, `gate_open`, `group_tasks`, `show_all`, `collapse`, `goal_reached`, `goal_progress`,
`tip_depends_on`, `tip_unlocks`, `tip_goal_direct`; section 27). Colours are `--color-*` tokens only, with no hex literal in
the component or the stylesheet, and the shimmer takes its highlight from `--color-surface` (light) or `--color-text`
(dark) through a local property. Covered by `project/app/ui/scripts/dependency-tree-model.test.cjs` (15 tests) and
`dependency-tree.test.cjs` (26 tests, with a hook shim for hover, focus, click and Enter). The task summaries record that the
tree was **looked at in a browser pane** in the light and dark theme with the prototype's data and the real dashboard
snapshot; the Swedish rendering was covered by tests only.

## 21. Zoom and pan (`E92_S06_T21`)

`zoomPanModel.js` (the maths, no React), `useZoomPan.js` (event wiring) and `ZoomControls.jsx`, integrated in
`DependencyTree.jsx`. The viewport now owns the size of the drawing: the `min-width: 720px` of 16.3 is gone (superseded), and
`.epic-tree { overflow-x: auto }` was removed with it.

- **Wheel** zooms about the cursor (`WHEEL_RATE` 0.0025 per delta pixel, four times faster with ctrl); **drag** pans (a drag
  starts after `DRAG_THRESHOLD` = 4 px, and only then is the pointer captured, so a plain click still expands a group; the
  click that ends a drag is swallowed); **two pointers pinch**.
- **Controls:** minus, plus (step 1.25), **Fit**, **100 %**, and a percent readout. The scale is **clamped to 0.25 to 3**.
- **Fit** runs on the first measured render, when the epic changes, and on a resize of a view the user has not touched
  (`fitPlan`); it **never** runs on a data refresh of the same epic. A drawing that cannot fit even at 25 % starts at the
  top-left instead of being centred and cut off. The large view of section 29 leaves this rule unchanged: it only gives Fit a
  bigger container to measure.
- Words (`zoom_group`, `zoom_out`, `zoom_in`, `zoom_fit`, `zoom_actual`, `zoom_percent`, `zoom_hint`) come from the labels; a
  control with no label shows its symbol only.
- **Honest limits.** A real mouse drag was observed to move the drawing by exactly the pointer delta, and wheel and button
  zoom were checked live; **real touch pinch was not verified** (the hook was driven with fake pointer events), and the
  snapshot was opened over http because the browser pane refused a `file://` URL.

## 22. The Animations toggle (`E92_S06_T21`)

A top-bar control (`MotionToggle.jsx`, hosted in `App.jsx` in `.header-toggles` beside the theme toggle, icon only on
narrow screens) with two states: **Auto** (follow the system's `prefers-reduced-motion`) and **Off** (disable every tree
animation). The rules live in `motionPreference.js` as plain functions.

### 22.1 State, storage and the attribute

- **Off** sets `data-motion="off"` on `<html>`; **Auto** has no attribute.
- The choice is stored as `off` under the localStorage key **`jenga-dashboard-motion`**; Auto removes the key.
- **Every storage access is guarded** (a throwing `window.localStorage` getter, blocked storage, `file://`): the toggle still
  works for the session and nothing throws.
- A second inline script in `index.html` (its own `try`) resolves the key into the attribute **before first paint**, so a
  reload does not flash the Auto state, and the toggle starts from that attribute rather than from a second storage read, as
  the theme toggle does. In a snapshot the same script and toggle are embedded and work without a server.
- When the system asks for reduced motion and the toggle is in Auto, the control adds the `motion_os_reduced` note.

### 22.2 What is gated, and how

Every tree animation is declared **only** inside `@media (prefers-reduced-motion: no-preference)` and only for selectors
beginning `:root:not([data-motion="off"])`; the base rules show the final state, there is no `transition`, and nothing is
driven from script. So reduced motion at the operating-system level and the Off toggle both leave a still tree.

### 22.3 The six animations

Edge flow (dashed edges into ready tasks), the ready-ring pulse, the goal halo "breathe", the shimmer, the sparks' twinkle
and the in-progress blink. `document.getAnimations().length` was observed at 7 with Auto and 0 with Off in the live page.

### 22.4 Checks and limits

`motion-toggle.test.cjs` evaluates the guards for each combination of reduced-motion and `data-motion` and uses throwing
storage; `tests/dashboard-snapshot-zoom-motion.bats` builds a snapshot and finds the pre-paint script, the toggle, the zoom
controls and the words in it. **Honest limit (as in the superseded 16.4):** the OS-level `prefers-reduced-motion: reduce`
branch could not be emulated by the browser pane, so it is verified by reading and testing the CSS text, not by a browser
with the preference set; a literal `file://` open was not done.

## 23. The after-task bar always shows the story (`E92_S06_T22`)

After every finished task (`j.do`), wave (`j.dooo`, a `j.jenga` wave) or bundle, the callers run
`skills/j-break/scripts/run-progress.sh --scope story --task <finished task id>[,<id>...]` and print what it prints.

- **One line per distinct story**, in the order each story is first seen in the list; two tasks of one story give one line,
  a wave that finished tasks of two stories gives two. The bar is the story's, never the epic's and never the whole run's.
- Every id is resolved to its parent story (the task's own `story_id`) **before** anything is drawn, so an unknown id, or a
  task naming no story, prints nothing at all; a renderer failure part-way stops at the first failing bar with one warning.
- A single id makes exactly the calls it always made, so its line is byte-identical to before (colour, narrow, `NO_COLOR` and
  ASCII were compared on the real board).
- The `SKILL.md` call sites (`skills/j-do` 4.1.3, `skills/j-dooo` 1.1, `skills/jenga` Phase 0.95) say only when to call it; they no
  longer mention `--resolve-scope`, a kept answer or a run-wide bar.
- **Kept for compatibility, not called from any `SKILL.md`:** `--resolve-scope` and `--scope run` (and their tests). Section 9.2
  is superseded by this section; the one-line form itself (section 17) is unchanged.

Real output, `run-progress.sh --scope story --task E92_S05_T01,E92_S06_T02 --cols 80 --color never` (two stories, two lines):

```text
[━━━━━━━━━━]★ 6/6
[━━━━━━━━━╌]⚑ 25/26 · 1 in progress
```

## 24. The after-story line (`E92_S06_T23`)

When all tasks of a story have just reached a terminal state, **Failed and Rejected included**, one more line is printed after
the after-task bars. The design is **Proposal A** of `project/documentation/prototypes/E92_S06/bars-prototype.html`.

### 24.1 Who decides, who draws

- `skills/j-break/scripts/story-finished.sh` **decides** (bash, no Node): for each distinct story it reads
  `board-progress.sh --story`, decides finished, consults the ledger and calls the renderer. It is reached through the new
  flag `run-progress.sh --scope story --task <ids> --after-story` (valid only with `--scope story`), so the `SKILL.md` call
  sites changed by one flag; the after-task bars always print first.
- `scripts/render-story-bar.sh` **draws** (bash plus `jq`). It reads only the `--story` JSON, allocates cells and computes
  the displayed percent, and holds no status name and no word.
- **Finished** means: a denominator above 0, and **no** pending, in-progress or unknown task. (Unknown is also required to be 0:
  a task of an unrecognised status is not terminal. This is the conservative reading of the task text, which names only
  pending and in progress.)

### 24.2 The line

Scope id, two spaces, a bar, the goal symbol, ` done/total · percent %`, then optional counts. The bar is **8 to 30 cells**
(by the width left on the line), one colour per bucket: done green, in progress yellow, failed red, pending dashed grey, by
largest-remainder allocation; a non-zero bucket never gets 0 cells while another has more than one. The goal symbol:

- a **star** whenever the story is finished: **green** when every task is done, **red when the story contains Failed
  tasks** (the failed cells stay red, so the bar is not fully green);
- a flag (grey) otherwise; denominator 0 prints an all-dashed bar and a flag.

Optional counts follow in this order, each only above 0: in progress, failed, ready, rejected. They stay on the line when they
fit and otherwise **wrap onto indented lines under the bar** and are never truncated. Under 40 columns, or when the bar form
cannot fit, the line is text-only (`<id> done/total · pct %`). NO_COLOR and a non-TTY give no escape sequences, a non-UTF-8
locale gives ASCII only, and no line is wider than the terminal. Real output (UTF-8, `--color never`):

```text
E92_S05  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━★ 6/6 · 100 %
E92_S05  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━★ 3/4 · 75 %  ✕ 1 failed
E92_S05  ━━━━━━╌╌⚑ 7/17 · 41 %
         ◉ 2 in progress  ✕ 3 failed  ⊘ 1 rejected
E92_S05 6/6 · 100 %
E92_S05  ##############################* 6/6 - 100 %
```

(lines 2 and 3 are the renderer fed a JSON with those totals, not real board states; line 5 is 30 columns and line 6 is a
non-UTF-8 locale). Without colour the done and the failed cells are the same glyph, as in the prototype: the red star, the
failed count and the percent carry the information.

### 24.3 Once per completion: the ledger

`story-finished.sh` keeps a ledger, `story-finished-ledger.tsv` in the queue directory (`scripts/resolve-root.sh get queue`,
normally `project/queue/`), one record per announced story: `<story id> TAB <signature>`, the signature being the final
bucket counts (`done:in_progress:failed:pending:rejected:unknown:denominator`). A call that finds the same signature prints
nothing; a **different** signature (a Failed task re-run and Passed, or a story that stopped being finished and finished again
with other counts) prints again and replaces the record. The file is rewritten atomically under a best-effort `mkdir`
lock, is machine-local transient state, and is gitignored (with its lock directory and temp files).

Known consequences, from the task summary: the ledger keeps **one** record per story, so a state A, B, A prints each time; a
story whose ledger cannot be read prints nothing (it cannot be known whether it was shown); an unwritable queue directory
still prints the line once per call, with a warning. **A progress problem never fails a run:** an unknown story, a failing
`board-progress.sh`, a missing helper or an unreadable ledger is one stderr warning, nothing on stdout and exit `0`; only a
usage error exits `2`. Covered by `tests/render-story-bar.bats` (21 tests) and `tests/story-finished-trigger.bats` (30 tests).

## 25. The new `j.status` views (`E92_S06_T24`, `E92_S06_T25`)

Both renderers live in `skills/j-status/scripts/`, share `lib/status-render-common.sh` (sibling lookup, UTF-8 detection,
colour, width, the one-warning-exit-0 rule, glyph sets, cell allocation, `emit`), read the board **once** and count nothing:
the totals they print are the ones `board-progress.sh` states (`E92` decision 1), and every word comes from
`scripts/lib/progress-labels.sh` (`JENGA_PROGRESS_LANG=sv` for Swedish). Every line goes through `emit`, which cuts it to the
width and ends it in the "more" glyph, so **no line is wider than the terminal** at any width; a non-UTF-8 locale gives ASCII
only; `NO_COLOR`, a non-TTY and `--color never` give no escape sequences. Both accept `--cols N`, `--color auto|always|never`
and `--root <dir>`, and treat a missing script, library or `jq`, a failing `board-progress.sh` and malformed JSON as one stderr
warning, nothing on stdout and exit `0`; only a usage error exits `2`. Both are covered with a stub `board-progress.sh`
(`JENGA_BOARD_PROGRESS`) by `tests/j-status-overview.bats` and `tests/j-status-scope-view.bats`.

### 25.1 The overview (`render-status-overview.sh`, no argument)

Replaces the 627-line per-epic and per-story list with a page of a few dozen lines, from
`board-progress.sh --graph --counts-only`:

1. a **total line** (epics, done/total tasks, percent), a bar and a counts line (in progress, red, pending, rejected);
2. **only the epics that are not complete**, in groups headed "Needs attention" (has failed tasks), "In progress", "Started"
   and "Not started", each sorted by percent (highest first, ties by numeric id); one row per epic: id, bar, done/total,
   percent, a failed or in-progress marker and the title cut to the width;
3. complete epics collapsed to **one** line ("Complete (N)" and their task total), and epics with only rejected tasks or no
   tasks to **one more** line;
4. a footer hint naming `j.status <id>` and `j.status --all`.

Under **50 columns** the bars are dropped. The overview does not print `--all`'s list itself: given `--all` it prints nothing
and exits `0`, and the full list is produced by the wiring of section 26. Real output (`--cols 80 --color never`, abridged to a
few rows per group):

```text
Board · 92 epics · 1438/1575 tasks · 91 %
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╌╌╌⚑
  ◉ 2 in progress  ✕ 6 red  ○ 129 pending  ⊘ 101 rejected (not counted)

Needs attention (4)
  E70 ━━━━━━━━━━━━━━ 16/17 94 %  ✕1  Retire Jenga's Own Use of docs/ (Site Sour…
In progress (1)
  E92 ━━━━━━━━━━━━━━ 58/59 98 %  ◉1  Progress Visualisation: see how far a run,…

★ Complete (59)  977 tasks · hidden
⊘ Only rejected or empty (9): E02, E04, E23, E48, E55, E81, E82, E84, E90

Details for one epic: j.status <id>  ·  all rows: j.status --all
```

An epic with a zero task denominator goes into the "Only rejected or empty" line even when it has stories (there is no
story-total fallback, unlike the prototype).

### 25.2 The scope view (`render-status-scope-view.sh <id>`)

For an epic or a story id (`E3_S5` equals `E03_S05`; a task id, a missing or a malformed id exits `2`), from
`board-progress.sh --graph --within <id>`. It **replaces** the indented text tree of section 18 as the default.

1. **Header block.** Title and percent; for an epic a **milestone track** (a start glyph, one segment and stop per story, then
   the goal) with a label under each stop (`S01`, ...); a **one-line message** chosen from the stated percent and the number of
   unfinished stories (done; "last story"; at least 80 % "Almost there - N stories left"; at least 50 % "Past halfway"; above 0
   "Good pace!"; else "The first step is just ahead"), joined with "Ready to take: the first two ready ids (+N)". A story id gets
   the header without the track. The track is omitted when it does not fit (more than about 23 stories at 50 columns).
2. **Complete stories** are hidden behind **one line** ("N complete stories hidden, --all shows them"); with `--all` they are
   listed like the others.
3. **Per remaining story** a row (symbol, id, truncated title, an 8-cell bar and done/total, or "nothing to count") and **per
   task** a row: state symbol, short id (`T01`), the state **in words**, the title and a **dependency column**: "after T01 ✓" in
   green when every dependency is done, "waits for T02" in grey when not (done dependencies keep their tick); a dependency in
   another story uses the full id. Done-ness is a lookup in the same JSON (task `state`, story `complete`, `external` bucket;
   an id that is not listed falls back to `blocked_by`), never a derivation.
4. **"Ready to take (N)"** with every id of the stated `ready` list, and, **only when there are locked tasks**, **"Unlocks
   after"**: the locked tasks and the ids they wait for.

Under 50 columns it is a flat list, one node per line, with no track and no dependency column. From 50 columns the dependency
column is capped at 45 percent of the room left after the left part, so it disappears at about 50 columns and shows from
roughly 55 (the title is cut first); between about 55 and 90 it may be clipped when a task has many dependencies. An epic
with no stories prints "No stories in this scope". Glyphs: `●` done, `◉` in progress, `✕` failed, `○` pending or locked, `+`
ready, `⊘` rejected, `⚑` goal, `★` complete, `▸` track start, `✓` tick, with ASCII stand-ins. Real output of
`render E92_S06 --cols 80 --color never` (abridged to three task rows; the board has since moved on):

```text
E92_S06 · Epic progress on cards, dependency tree in overlay, and restyle…  96 %

◉ E92_S06  Epic progress on cards, dependency tree in overlay, a… ━━━━━━━━ 25/26
    ● T01 done        Add the --graph mode to scripts/board-progress.sh: per-ep…
    ● T02 done        Derive task states (ready, loc…  after T01 ✓
    ◉ T26 in progress j.status --legacy switch, SKIL…  after T21 ✓, T23 ✓, T25 ✓

Ready to take (0)
  Nothing is ready to take right now
```

## 26. `j.status --legacy`, `--all` and the mode switch (`E92_S06_T26`)

The arguments of `j.status` are parsed by **one script**, `skills/j-status/scripts/resolve-status-mode.sh`, not by prose in
`skills/j-status/SKILL.md`. Step 1.5 of the skill runs it once with `mode` and follows the word it prints; for the default
path it runs it again with `render` and prints the renderer's stdout **unchanged**.

```text
resolve-status-mode.sh mode|plan|render [<id>] [--legacy] [--all] [--root D] [--cols N] [--color M]
```

| Arguments | Mode | Renderer |
|---|---|---|
| none | `overview` | `render-status-overview.sh` (the default, section 25.1) |
| `<id>` | `scope` | `render-status-scope-view.sh <id>` (the default, section 25.2) |
| `<id> --all` | `scope` | the same, with `--all` passed through: **every story is shown, complete ones too** |
| `--all`, no id | `legacy` | `render-status-bars.sh` and the full list of the legacy path: "the full list, like the legacy overview" |
| `--legacy` | `legacy` | `render-status-bars.sh` (section 12.4) |
| `--legacy <id>` | `legacy-scope` | `render-status-scope.sh <id>` (section 18) |

Arguments may come in any order and as `--flag=value`; `--cols`, `--color` and `--root` are forwarded to the chosen renderer
in a fixed order; `--legacy` wins over `--all`; the legacy renderers never receive `--all`. An unknown flag, a flag with no
value, a second id, a task id, a malformed id or a bad `--color` or `--cols` **exits 2** with one stderr line. `mode` and
`plan` read no board and write nothing; `plan` prints `<renderer> <arguments>` on one line (how the tests see the decision).

- **Default path.** `overview` and `scope` print the renderer's output unchanged after the deploy-reconcile pass (step 6.5),
  so the renderer sees reconciled statuses. After an `overview` the open-rapports, queue, `todo.md`-warning and
  dependency-audit sections still follow (steps 5, 6, 6.7 and 6.8, in the banner style of `assets/output_format.md`); a scope
  view prints **only the view** (a decision of this task, not stated in the task text, recorded in the task summary). When a
  renderer prints nothing or fails, the skill falls back to the legacy path and shows no error.
- **Legacy path.** Steps 2 to 4, 6.9, 6.10 and the board listing of step 7 keep their instructions **verbatim**, and
  `render-status-bars.sh` and `render-status-scope.sh` are unchanged, with `tests/j-status-bars.bats` and
  `tests/j-status-scope.bats` untouched; `render` with `--legacy` prints, byte for byte, what those scripts print when called
  directly (asserted in `tests/j-status-mode-resolver.bats`).
- **Tests.** `tests/j-status-mode-resolver.bats` (the table above, argument order, `--flag=value`, exit `2` for every bad
  argument, byte-for-byte equality with the renderers on the fixture board of `tests/helpers/progress-fixture.bash`);
  `tests/j-status-bars-wiring.bats` and `tests/j-status-scope-wiring.bats` assert the default path (one resolver call with the
  dual-path idiom, no argument parsing and no renderer named in the skill file) and the legacy path.
- **Not changed.** `--resolve-scope` and `--scope run` of `run-progress.sh` stay (section 23).

## 27. Label library additions of the rework (`E92_S06_T20` to `E92_S06_T25`)

Fifty-one keys were added to `scripts/lib/progress-labels.sh`, as delimited blocks (case arms before the catch-all, plus a
line in `PROGRESS_LABEL_KEYS`), in English and Swedish; the library now has 68 keys, `scripts/progress-labels-json.sh` exports
all of them with no change of its own (it iterates `PROGRESS_LABEL_KEYS`), and `tests/progress-labels.bats` checks that the
count is at least 17 (it grows with the table). The rules of section 9.5 and 19 are unchanged: no word is written in a
component, a script or a `SKILL.md`. Format strings keep their placeholders for the caller.

| Task | Keys |
|---|---|
| `E92_S06_T20` (tree v2) | `gate_waiting`, `gate_open`, `group_tasks` (`%d tasks`), `show_all` (`Show all %d`), `collapse`, `goal_reached`, `goal_progress` (`%d / %d done · %d %%`), `tip_depends_on`, `tip_unlocks`, `tip_goal_direct` |
| `E92_S06_T21` (zoom, motion) | `zoom_group`, `zoom_out`, `zoom_in`, `zoom_fit`, `zoom_actual`, `zoom_percent`, `zoom_hint`, `motion_label` (`Animations`), `motion_auto`, `motion_off`, `motion_activate` (`Activate to switch to %s.`), `motion_os_reduced` |
| `E92_S06_T23` (after-story line) | `sl_failed_one`, `sl_failed_many`, `sl_ready`, `sl_rejected` (the in-progress word reuses `in_progress`) |
| `E92_S06_T24` (overview) | `ov_board`, `ov_epics`, `ov_tasks`, `ov_pending`, `ov_group_attention`, `ov_group_progress`, `ov_group_started`, `ov_group_notstarted`, `ov_complete`, `ov_hidden`, `ov_rejected_empty`, `ov_footer_scope`, `ov_footer_all` |
| `E92_S06_T25` (scope view) | `sc_hidden`, `sc_hidden_one`, `sc_msg_done`, `sc_msg_last`, `sc_msg_almost`, `sc_msg_half`, `sc_msg_going`, `sc_msg_start`, `sc_after`, `sc_waits`, `sc_unlocks_after`, `sc_no_stories` |

Examples, `en` and `sv`: `ov_group_attention` "Needs attention" and "Behöver uppmärksamhet"; `ov_group_progress` "In progress"
and "Pågår"; `sc_msg_almost` "Almost there - %d stories left" and "Nästan framme - %d berättelser kvar"; `sc_waits` "waits
for" and "väntar på"; `motion_off` "Off" and "Av". The views reuse older keys for their state words (`state_*`, `in_progress`,
`goal`, `ready_to_take`, `nothing_ready`, `nothing`). The T24, T25, T20, T21 and T23 blocks were added in parallel and merge
mechanically (keep all blocks).

## 28. What was checked, and what was not (`E92_S06_T19` to `E92_S06_T26`)

Taken from the task summaries and this task's own runs; this section does not claim more than they do.

- **Run by the developers as a self-check, not as a verdict:** the new bats of T23 to T26 and the neighbouring suites
  (the wiring and renderer tests above). The formal verdicts are the Tester's.
- **Looked at in a browser pane:** the tree v2 (light and dark, Auto and Off, live dashboard and a snapshot served over http), the
  zoom controls, the toggle and its reload behaviour, the hover chain and group expansion with real pointer events.
- **Not verified:** the OS-level `prefers-reduced-motion: reduce` branch in a browser (tested by CSS text only), real touch
  pinch, a literal `file://` open of a snapshot, the Swedish rendering of the dashboard (labels covered by tests), and the
  tree against the original concept SVG (16.6 still holds; the prototype is the reference now).
- **Not run in a live session:** the `j.status` wiring of section 26 was checked by reading the skill and running the
  resolver and wiring tests and the real renderers (the real output above), not by watching an agent follow `SKILL.md`.
- **Environmental:** `tests/progress-bar-wiring-dooo.bats` case 258 depends on the state of `.claude/` and `.agents/`
  (see the task summaries of T22).

## 29. The large and fullscreen view (`E92_S07`)

Added on 2026-11-13, on the user's request for a button that shows the progress map large or fullscreen. It follows the
browser review of `E92_S06` the same day, where Fit showed a small tree (38 % for `E52`) inside the 480 px wide epic overlay
(`width: min(480px, 100vw)` in `history.css`), so the 100 % button and the zoom were needed to read it. The view is written
here from the code as built (`E92_S07_T01` to `E92_S07_T09`); where a statement rests on a test or on a look in a browser,
the last list of this section says which.

### 29.1 What it is, and where the code lives

A button (`FullscreenToggle.jsx`, class `dt-fs-btn`, `data-testid="dt-fs-toggle"`) in the top-left corner of the tree, next
to the zoom controls in the top-right corner. Pressed, it makes **the tree's own root**, `section.dep-tree`
(`data-testid="dependency-tree"`), use the whole viewport. The root is not re-parented, portalled or duplicated: the same DOM
node and the same React instance are used in the overlay and in the large view. While the view is open the root carries
`data-fullscreen="native"` (real Fullscreen API) or `data-fullscreen="fallback"` (a fixed full-viewport layer); the
attribute is absent when it is closed.

| File (`project/app/ui/src/components/progress/`) | Role |
|---|---|
| `fullscreenModel.js` | Pure logic, no React, no DOM, no timers: `fullscreenSupport`, `reduce`, `isOpen`, `rootMode`, `toggleLabelKey`, `escapeAction`, `keepCentre`, `nextTabTarget` |
| `useFullscreen.js` | Event wiring: the Fullscreen API, the fallback, `fullscreenchange`, Esc, focus return, the two attributes |
| `useFocusContain.js` | The focus trap while the view is open |
| `FullscreenToggle.jsx` | The button and the Esc hint; presentational, no word and no colour literal in it |
| `useZoomPan.js` | One opt-in option, `keepCentreOnResize` (29.3) |
| `dependency-tree.css` | One appended block headed `E92_S07_T06` (additions only) |

No counting and no new data were added (decision 1 of `E92`: counting stays in `scripts/board-progress.sh`), nothing under
`.claude/` or `.agents/` was edited by hand, and no skill was touched.

### 29.2 The Fullscreen API and the fixed-layer fallback

- **Which one.** `fullscreenSupport(doc, el)` answers `native` when `doc.fullscreenEnabled` is truthy and
  `el.requestFullscreen` is a function (or the `webkit` pair of both), otherwise `fallback`. Every property read is guarded;
  a throwing getter reads as "not available", so a `file://` snapshot, an iframe without permission or a missing API never
  throws.
- **Native.** The root is asked for fullscreen. The model stays **closed until the browser reports the root as the fullscreen
  element** (`fullscreenchange`, or the promise resolving with the root fullscreen), so the hook never believes it is
  fullscreen when it is not. A synchronous throw, a rejected promise, a resolution that is not fullscreen on the root, a
  broken thenable or `fullscreenerror` is a **refusal**, and a refusal switches to the fallback layer (`enterRefused`): the
  button never ends in a state where nothing happens because the browser said no.
- **Fallback.** `.dep-tree[data-fullscreen="fallback"]` is `position: fixed; inset: 0; z-index: 200` with an opaque
  `var(--color-surface)` background. The epic overlay's backdrop is 100 and its panel 101 (`history.css`), the leave-guard
  modal 1000, so the layer covers the overlay and the top bar and the leave-guard dialog still shows above it. The panel has
  no transform once its slide-in has ended, so a fixed child covers the whole viewport (a click within the 0.2 s of the
  slide-in animation could still be positioned inside the panel; it was measured and left alone).
- **Scroll lock.** In the fallback the hook also sets `data-dt-fullscreen="fallback"` on `<html>`, and
  `html[data-dt-fullscreen] { overflow: hidden }` stops the page behind from scrolling. Both attributes are removed on close.
- **Real fullscreen styling.** `.dep-tree:fullscreen` and `.dep-tree:-webkit-full-screen` (separate rules, so a browser that
  does not know one keeps the other) give the top layer the surface background and padding.
- **A snapshot** (`j.dashboard --snapshot`) contains the button and the whole view with no change to `snapshot.sh` or
  `build-snapshot-html.cjs` (a test asserts neither mentions fullscreen). Where the API is missing the fallback layer is used.

### 29.3 State that is kept

Entering and leaving keeps, for free, everything that lives in the same node and the same React instance: the **hover chain**,
which **groups are expanded**, and the **Animations toggle** (`data-motion` on `<html>` and its stored choice; the hook writes
only `data-dt-fullscreen` to `<html>`).

**Zoom and pan** are kept except for one adjustment: `useZoomPan` takes a new option **`keepCentreOnResize`** (default
`false`, the hook then behaves exactly as before; `DependencyTree.jsx` passes `true`). When the measured viewport size changes
(never on the first measurement) while the user has touched the view, `measure()` replaces the view with
`keepCentre(view, oldSize, newSize)`: the same scale, and the drawing point that was at the old viewport centre is at the new
centre. No clamp, no refit, and `touched` stays true, so leaving restores the part of the tree the user was looking at.

Honest edge: Fit is **not re-run on enter or exit**, but a view the user has **not touched** still follows the existing rule
"Fit on a resize of an untouched view" (section 21), so an untouched tree opened large is fitted to the bigger container
(observed in a harness during `E92_S07_T07`: 31 % to 69 %). That is the old rule meeting a bigger container, not a new trigger.

### 29.4 Esc and focus

- **Esc in the fallback.** `useFullscreen` registers one `keydown` listener on **`window` in the capture phase** while the
  fallback layer is open. It closes the large view and calls `stopPropagation()` and `preventDefault()`, so the overlay's own
  document-level Escape handler (`EntryDetailPanel.jsx`) does not also close the epic overlay beneath. After the layer is
  closed the next Esc reaches the overlay as before. The listener is removed on close and on unmount.
- **Esc in real fullscreen.** The browser consumes Esc itself and fires `fullscreenchange`; the hook registers nothing for
  Esc. `fullscreenchange` (and `webkitfullscreenchange`) on `document` is fed into the model, so leaving by Esc or by the
  browser's own UI ends in the same closed state as the close button, and a change on a closed view does nothing.
- **Closing** by the button, Esc, `fullscreenchange` or unmount calls `document.exitFullscreen()` only while the root is the
  fullscreen element (a throw or a rejection is swallowed), removes both attributes and returns **focus to the opener**, the
  element that was pressed, on the next animation frame (immediately where there is no `requestAnimationFrame`; skipped when
  the opener has left the page).
- **Focus trap.** `useFocusContain` moves focus to the first focusable control of the root on opening (the button, which is
  first in DOM order and so becomes the "exit" button), wraps Tab from the last control to the first and Shift+Tab back
  (the list is queried on every Tab because groups expand and collapse), and sends a `focusin` that lands outside the root
  back inside. A Tab in the middle is left to the browser; Enter and Space always reach their control. The root gets
  `role="dialog"`, `aria-modal="true"` and an `aria-label` from `fullscreen_layer` while open, and the button has
  `aria-pressed`.
- **Why not `inert`.** The tree root sits several levels deep in the epic overlay, so making "the rest of the page" inert
  would mean writing the attribute on ancestors and siblings at every level and restoring each exactly on close. The trap
  writes no attribute to any element and changes no markup outside the root. (A test asserts the hook contains no `inert`.)

### 29.5 Labels

Four keys were added to `scripts/lib/progress-labels.sh` as one delimited block `E92_S07_T02` (case arms plus a line in
`PROGRESS_LABEL_KEYS`), so the library has 72 keys, `scripts/progress-labels-json.sh` exports them with no change of its own,
and a snapshot carries them in the same `labels` object as the zoom words. No word is written in a component, a script or a
`SKILL.md`; a key that is missing leaves the symbol alone (no `aria-label`, no `title`, no hint, no `role`).

| Key | English | Swedish | Used for |
|---|---|---|---|
| `fullscreen_enter` | Show full screen | Visa i helskärm | `aria-label` and `title` of the button while closed |
| `fullscreen_exit` | Exit full screen | Avsluta helskärm | the same, while open |
| `fullscreen_hint` | Press Esc to exit | Tryck Esc för att avsluta | the visible hint next to the button while open |
| `fullscreen_layer` | Dependency tree, full screen | Beroendeträd i helskärm | `aria-label` of the root while open |

### 29.6 Fit stays exactly as is

The user has not decided whether Fit itself should change and will decide after previewing the dashboard, so on 2026-11-13
this story was frozen against it. **Unchanged:** `zoomPanModel.js` (`fitView`, `fitPlan`, the 0.25 to 3 clamp, `clampScale`,
`FIT_PAD`); in `useZoomPan.js` the Fit effect, `fit()`, the first-render fit, the fit on an epic change, the rule that a data
refresh of the same epic never refits, and the Fit button. Inside the large view Fit measures the bigger container and nothing
else. No existing zoom/pan test needed a changed expected value; `fullscreen-view.test.cjs` pins `fitPlan`, `fitView`,
`clampScale` and the constants with values computed from the current code and asserts that `zoomPanModel.js` contains no
"fullscreen" and imports nothing.

### 29.7 Theme and motion

Colours are tokens only (`--color-surface`, `--color-surface-alt`, `--color-border-strong`, `--color-accent`, `--color-text`,
`--color-text-muted`); the new CSS and `FullscreenToggle.jsx` contain no hex literal (tests assert it), and the icon is an
inline SVG in `currentColor`. The button keeps the zoom buttons' look with a 32 px minimum target and a 2 px `--color-accent`
focus ring (`:focus-visible`, offset 2 px). The layer appears **without a fade**: a new keyframes animation would have broken
`dependency-tree.test.cjs`, which requires the set of `animation:` names to be exactly the six tree animations. The only motion
is a hover `transition` of the button, declared inside `@media (prefers-reduced-motion: no-preference)` and only for
`:root:not([data-motion="off"])`, like every other tree animation (section 22.2).

### 29.8 What was checked, and what was not

Taken from the task summaries and rapports of `E92_S07_T01` to `E92_S07_T09` and from this task's own browser run; this
section does not claim more than they do. The developers did not run tests as a verdict; the formal verdicts are the Tester's.

**Tests (structure and logic, not a browser).** `fullscreen-model.test.cjs`, `fullscreen-hook.test.cjs` (a fake document,
window and elements), `fullscreen-focus.test.cjs`, `fullscreen-css.test.cjs` (the block as text), `fullscreen-toggle.test.cjs`,
`fullscreen-view.test.cjs` (the real `DependencyTree.jsx` driven through a fake page, both modes, English and Swedish),
the `keepCentreOnResize` cases appended to `tree-zoom-pan.test.cjs`, and `tests/dashboard-snapshot-fullscreen.bats` (the
snapshot carries the toggle, the attributes, the selectors and the words in both languages, and its inline script loads in a
Node `vm` with no Fullscreen API and throwing storage without requesting fullscreen). All of these live under
`project/app/ui/scripts/` or `tests/`.

**Browser run of `E92_S07_T10` (desktop browser pane, 663 x 799, a small scratch board of one epic and 16 tasks, snapshot
built from the `E92_S07_T10` worktree and served over http from 127.0.0.1; the server was stopped afterwards).** Dark is the
pane's own system theme, light was set with the dashboard's theme button.

| Combination | Result |
|---|---|
| Light, fallback layer | **Observed.** Layer fixed at 0,0 over the whole 663 x 799 viewport, z-index 200, opaque white surface, hint shown, label switched to "Exit full screen"; Esc closed only the layer, the epic overlay stayed open, focus ended on the button |
| Dark, fallback layer | **Observed.** The same attributes and geometry (`data-fullscreen="fallback"`, `data-dt-fullscreen="fallback"` on `<html>`, `role="dialog"`, `aria-modal`, `aria-label` "Dependency tree, full screen", `<html>` overflow hidden), the same node before and after |
| Dark, real fullscreen | **Not observed.** See open item 1 |
| Light, real fullscreen | **Not observed.** See open item 1 |

How the fallback was reached: the pane reports `document.fullscreenEnabled` as true, so the page was given
`fullscreenEnabled` and `webkitFullscreenEnabled` getters that return false before the real click (Chromium has the
`webkit` pair too; overriding only the unprefixed one leaves the native path chosen). That is a stand-in for "the API is
unavailable", not a `file://` open.

| Other check | Result |
|---|---|
| The button in the overlay | **Observed** (live look, both themes: top-left icon button, zoom controls top-right); the button's 2 px focus ring was visible after focus returned to it from the keyboard |
| Esc | **Observed** in the fallback in both themes (real key press); in native: not observed |
| The close button | **Observed once, dark only**, by a real click; the layer closed, focus returned to the button, the hand-set zoom (31 %) was unchanged after closing. Not pressed in the light theme |
| Focus return | **Observed** after Esc (dark and light) and after the close button (dark). After Esc the focus was not yet on the button 400 ms later and was when read again about a second afterwards: the return waits for an animation frame, and the pane's frames are slow, so the exact delay is not established |
| Enter on the focused button | **Observed** (opened the layer with Enter) |
| Focus trap | **Partially observed.** 66 Tab presses in the dark fallback layer (21 focusable controls in the root) always left focus inside the root; Shift+Tab and the wrap point were not examined one by one |
| Zoom and pan kept | **Partially observed.** The tree started at 25 % and was 25 % inside the layer and after leaving; with a hand-set 31 % it was 31 % after closing. 25 % is the clamp of Fit for this wide tree, so this run cannot tell Fit from `keepCentre` there; the centre arithmetic rests on `keepCentre` and `tree-zoom-pan.test.cjs` and on the harness look of `E92_S07_T07` (87 % kept across enter, Esc, re-enter and close) |
| Swedish | **Observed** in the fallback: "Visa i helskärm", "Avsluta helskärm", "Tryck Esc för att avsluta", "Beroendeträd i helskärm" |
| The snapshot | **Partially observed.** The button and the fallback layer work in a snapshot served over **http**; a literal `file://` open was **not** done (the pane refuses it: "couldn't open file"), and a snapshot of the real board, built once by `E92_S07_T09`, was **not opened** |

**Open items, stated plainly.**

1. **Real fullscreen never settled in the desktop browser pane.** With a real click and the real API, `requestFullscreen()`
   there neither resolves nor rejects, no `fullscreenchange` or `fullscreenerror` arrives, and `document.fullscreenElement`
   stays null (observed again in this run after 3 s). `useFullscreen.js` has no timeout, so it stays pending and ignores
   further presses: **the button can look dead while the request is pending.** Real browsers settle the promise; a pending
   timeout would harden the hook. That is a follow-up and was not changed here (`useFullscreen.js` is `E92_S07_T03`'s file).
2. **Native fullscreen is therefore unverified in any browser.** It still needs one look in a normal browser; the story's
   Definition of Done asks for it, and it is **not** ticked by this documentation. What exists for the native path is the
   unit and hook tests with a fake document, the CSS text of the `:fullscreen` rules, and the rejected-request path that
   ends in the fallback.
3. **`.todo-bubble` paints over the large view.** It is `position: fixed; z-index: 900` at the root and the fallback layer
   lives inside the panel's stacking context (101), so the bubble covers the bottom-right corner. The fix,
   `html[data-dt-fullscreen] .todo-bubble { display: none }`, belongs in `todo-bubble.css` and was **not done**. In a snapshot
   the bubble is not in the DOM, so it could not be reproduced there; this run did not include the live dashboard.
4. **The button bar is placed by an inline style** (`BAR_STYLE`, position only) in `FullscreenToggle.jsx`, because
   `dependency-tree.css` was outside that task's file list; a `.dt-fs-bar` rule would be tidier. It works as it is.
5. **The earlier browser looks were not independent of the developers' harness.** The `E92_S07_T06` and `E92_S07_T07` looks
   ran in developer harness pages (hand-written markup, and an esbuild build of the real components), not in the running
   app, and the Tester did not repeat them (its rapports for those two tasks say so); `E92_S07_T09` served a snapshot over
   http because the pane refused `file://`. This run repeats the look in a built snapshot of a small scratch board, the
   closest thing to the real app that was available; it was not run against the live dashboard and not against the real board.
6. **The capture-based bats suites are slow, and may fail under heavy machine load.** `E92_S07_T09` records about 40 s for
   the first test of `dashboard-snapshot-fullscreen.bats` (a lazy `vite build` per file). No task summary or rapport of
   this story records an actual flake; that these suites *can* flake under load is the orchestrator's brief for this task, and
   the project's own note on slow runs is that slowness on the maintainer's machine is environmental (wall time far above CPU
   time). A failure there under load should be re-run before it is called a defect.

**Also not verified:** real touch, the Safari or mobile Fullscreen behaviour, the leave-guard dialog above the layer (only its
z-index was read), and the layer opened within 0.2 s of the overlay's slide-in.
