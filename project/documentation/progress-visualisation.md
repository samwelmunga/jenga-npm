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

The story `E92_S08` (2026-11-14) adds section 30: the Node terminal renderer (`lib/progress/cli.js`, `jenga progress`) is
now the default for every terminal view, and the bash renderers of sections 17, 18 and 23 to 26 are the `--legacy` path.

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
| Epic card bar on the Board tab | `E92_S06` | Reads `--graph --counts-only`: one stop per story, percent from the epic's `epic_progress` (sections 5.2, 15) |
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
  "epics":   [ { "id": "E01", "level": "stories", "totals": { "done": 0, "in_progress": 0, "failed": 0, "pending": 0, "rejected": 0, "unknown": 0, "denominator": 0 },
                 "epic_progress": { "stories": 0, "decomposed": 0, "tasks_done": 0, "tasks_denominator": 0, "percent": 0, "goal_reached": false } } ],
  "stories": [ { "id": "E01_S01", "level": "tasks", "totals": { } } ],
  "warnings": []
}
```

Per epic the `totals` cover its stories (each story belongs to the epic named by its own `epic_id`); per story the `totals`
cover its tasks (each task belongs to the story named by its own `story_id`). Each epic entry also carries the epic
percent `epic_progress` of section 5.1 (`E92_S09_T03`); story entries do not. The `totals` object, the status table
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
  updated in the same change. Adding a key is not a breaking change; changing what an existing key means is.
- `epic_progress` (only for `--epic <id>`, between `levels` and `warnings`; `E92_S09_T03`) is the epic percent of
  section 5.1: `{stories, decomposed, tasks_done, tasks_denominator, percent, goal_reached}`. The example above is a
  story scope and so does not carry it.
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
empty state instead of dividing. The one exception is an **epic's** percent, which is not `done / denominator` of any
`totals` object but the `epic_progress` figure of section 5.1, so that stories nobody has broken down yet lower it.

### 5.1 The epic percent: `epic_progress` (`E92_S09_T03`)

Requested by the user on 2026-11-15: an epic whose stories are not all broken down into tasks must not look complete.
The formula is the user's:

```
epic fraction = (task fraction of the decomposed stories) x (decomposed stories / all stories)
percent       = floor(100 * tasks_done * decomposed / (tasks_denominator * stories))
```

`scripts/board-progress.sh` computes it once per epic and prints it as the object `epic_progress`; no consumer
recomputes it (`E92` decision 1).

| Key | Meaning |
|---|---|
| `stories` | The epic's **counted** stories: stories whose own status is not in the `rejected` or `unknown` bucket. It is the denominator rule above applied to stories, so it equals the epic's `stories.totals.denominator` |
| `decomposed` | Counted stories with at least one **counted** task (task denominator above `0`) |
| `tasks_done`, `tasks_denominator` | `done` and the denominator over the tasks of the decomposed stories. A task counts under a story when its own `story_id` names the story and its own `epic_id` names the story's epic |
| `percent` | `floor(100 * tasks_done * decomposed / (tasks_denominator * stories))` in exact integer arithmetic; `0` when `stories` or `decomposed` is `0` (no division by zero); **at most `99` while `failed_stories` is not empty** (`E92_S10_T02`, below) |
| `goal_reached` | `true` exactly when `stories > 0`, `decomposed == stories`, `tasks_done == tasks_denominator` **and `failed_stories` is empty**; so `true` exactly when `percent` is `100` |
| `failed_stories` | (`E92_S10_T02`) the ids of the epic's counted stories whose **own** status is in the failed bucket (`Failed` and `Blocked`, section 4), in numeric id order; `[]` when none. The last key of the object |

Examples (they are the cases of `tests/board-progress-epic-percent.bats`):

| Epic | `epic_progress` | Percent |
|---|---|---|
| 5 stories, 3 decomposed, half their tasks done | 50 % x 3/5 | **30** |
| 5 stories, 3 decomposed, all their tasks done | 100 % x 3/5 | **60** |
| every story decomposed, every task done | 100 % x 5/5 | **100**, `goal_reached` |
| no stories, or stories with no tasks | | **0** |
| 1 story, 199 of 200 tasks done | 99.5 % | **99** (floor), goal not reached |
| 3 stories, every task done, one story's own status `Failed` (or `Blocked`) | 100 % x 3/3, capped | **99**, goal not reached, `failed_stories: ["E11_S02"]` |
| 2 stories, one `Failed` (its task done), the other with 1 of 2 tasks done | 2/3 x 2/2 | **66** (unchanged), goal not reached, `failed_stories: ["E13_S01"]` |

Decisions, with the reason for each:

- **Rejected and unknown work is out, as everywhere (`E92` decision 3).** A `Rejected` task is neither done nor
  remaining, so it does not count and does not by itself make a story decomposed: a story whose tasks are all rejected
  (or of unknown status) is not decomposed. A `Rejected` story, and a story of unknown status, is not one of the
  `stories` either, and its tasks are not counted. "A decomposed story has at least one task" therefore reads "at least
  one counted task", the same test the story's `complete` flag already uses (task denominator above `0`).
- **Rounding: floor to a whole percent, one rule everywhere.** Rounding to nearest would print `100` for 99.5 %, before
  the goal is reached; with the floor, `100` is printed exactly when `goal_reached` is true and never otherwise. The
  cost is that a fraction under 1 % prints `0`.
- **The field is new; nothing changes meaning.** `tasks.totals`, `stories.totals` and `stories.complete` keep their
  meaning, so `schema_version` stays `1` (an added key is backward compatible, section 3).
- **The per-story flag (`E92_S12_T01`).** `--graph` also states, for each story, the fact the epic `decomposed` count is
  made of, so a view can name the undecomposed stories instead of only counting them. `decomposed` on a `stories[]` entry
  is `true` for a counted story with at least one counted task (the definition of the row above), `false` for a counted
  story with no counted task (no task file, or every task rejected or of unknown status), and `null` for a story that is
  not counted (its own status is `Rejected` or of unknown status), which a view must not draw as "not broken down" because
  `epic_progress.stories` does not count it either. It is read from the figures `epic_progress` already derives, with no
  second counting pass, so the two cannot disagree. The invariant, per epic: the number of `true` stories equals
  `epic_progress.decomposed`, and the number of `false` stories equals `epic_progress.stories - epic_progress.decomposed`
  (`tests/board-progress-graph.bats`). No percent, no count and no bar changes because of the flag.
- **No goal while a story has failed (`E92_S10_T02`).** User decision 2026-11-15: "'Goal reached' när en story är Failed:
  hindra det", and, confirming the proposal, "procenten stannar på högst 99 % och mållinjen visar vilken story som är
  Failed i stället för gratulationen" (the percent stops at 99 % at most, and the goal line shows which story has failed
  instead of the congratulation). Observed: `j.status E92` showed "100 % ... Goal reached - well done!" while `E92_S08`
  was `Failed` by its own status with every task done or merged. The rule, decided here and nowhere else:
  1. A counted story whose **own** status is in the failed bucket blocks the goal: `goal_reached` is `false` while there
     is at least one, and the story is listed in `failed_stories`.
  2. While there is at least one, `percent` is capped at `99`, so no view ever shows 100 % without the goal. Below `100`
     the formula is unchanged (a capped value is never lower than the formula's).
  3. A story whose tasks include a failed task is already below 100 % (that task is not done), so the rule adds nothing
     there: it is about the story's own status only.
  4. **Open choice, `Blocked`.** The user named `Failed`; the default applied is the failed bucket of `E92` decision 2,
     `Failed` **and** `Blocked`. If `Blocked` must not stop the goal, only the bucket test in `epic_progress_calc` of
     `scripts/board-progress.sh` (and this paragraph and its tests) change.
  `failed_stories` is an added key (the last of the object), so `schema_version` stays `1`; no existing key changes
  meaning. `--epic <id> --summary` appends ` · failed stories: <ids>` to its `epic` line only while the list is not
  empty (fixed English words, like the rest of that line): `epic     99% · 10/10 stories decomposed · 86/86 tasks done ·
  failed stories: E92_S08`; otherwise the line is unchanged.
- **The goal line that names the failed story (`E92_S10_T02`).** Where a view would have shown the congratulation (the
  terminal message `sc_msg_done`, "Goal reached - well done!"; the overlay goal's `goal_reached`, "Goal reached!"), it
  names the failed story instead, with the labels `goal_failed` (`Goal not reached - %s has failed`, sv `Målet ej nått -
  %s har misslyckats`) and, for more than one, `goal_failed_more` (`Goal not reached - %s and %d more have failed`, sv
  `Målet ej nått - %s och %d till har misslyckats`): the first id in numeric order and the count of the others, chosen so
  the line fits the overlay goal and one terminal line. A view shows it exactly when the stated goal is not reached, the
  stated `percent` is at the cap (`99`) and `failed_stories` is not empty (`goalFailedText` in
  `lib/progress/dependency-structure.js`, shared by the Node views and the dashboard; the `--legacy` jq applies the same
  test); below 99 % the existing messages (`sc_msg_almost`, `sc_msg_half` and so on) are unchanged. A natural 99 % (for
  example 199 of 200 tasks) with a failed story stated also shows it, which is still true: the goal is not reached and
  that story has failed.
- **Modes that carry it:** `--graph` (every epic entry, also with `--counts-only` and `--within`; it feeds the dashboard
  epic card, the overlay goal and the Node renderers), `--by-parent` (every epic entry; `j.status --legacy` and
  `jenga progress bar --each epics`), `--epic <id>` (top level, between `levels` and `warnings`; `jenga progress bar
  --epic`) and `--epic <id> --summary` (one `epic` line after the level lines, section 12.1). `--story`, `--ids`,
  `--all` and `--backlog` do not carry it: no view reads an epic percent from them.
- **The `n/total` shown beside the percent.** A view that shows `epic_progress.percent` shows `tasks_done/
  tasks_denominator` beside it, never `tasks.totals`, and, whenever `decomposed < stories`, also `decomposed/stories`
  (for example `3/6 tasks · 3/5 stories decomposed · 30 %`). The percent is then the floor of the product of the two
  fractions shown, and with every story decomposed it is the floor of the task fraction alone, so no view shows numbers
  that silently contradict it. `tasks_denominator` is never above `tasks.totals.denominator`; they differ only by tasks
  of a rejected or unknown-status story, orphan tasks, and tasks whose `epic_id` disagrees with their story's.
- **The board-level total line is unchanged.** The total line of the `j.status` overview (`lib/progress/overview.js`,
  `skills/j-status/scripts/render-status-overview.sh`) is done/total **tasks** summed over the epics' `tasks.totals`,
  a task count of the whole board and not the completeness of any epic. An undecomposed story holds no task, so it adds
  nothing to that count either way; folding story decomposition into it would need a board-level formula the user did
  not ask for. Each epic **row** under it is an epic percent and switches to `epic_progress` with the other views
  (`E92_S09_T04`, section 5.2).

### 5.2 Which views show the epic percent (`E92_S09_T04`)

Every view below reads `epic_progress` from `board-progress.sh` output **unchanged**: none divides, rounds or derives the
percent, and a payload without `epic_progress` (a hand-built fixture, a payload from before `E92_S09_T03`) shows `0` and
an unreached goal rather than a recomputed figure. Beside the percent each shows `tasks_done/tasks_denominator`, and the
`decomposed/stories` note (label `epic_decomposed`, `%d/%d stories decomposed`, sv `%d/%d berättelser nedbrutna`) whenever
`decomposed < stories`. "Complete", the goal star and the done message follow `goal_reached` only. Since `E92_S10_T02`
each also reads `failed_stories` and, at the 99 % cap, names the failed story where the congratulation would have been
(section 5.1); none recomputes the goal or the cap.

| View | Source | What shows the epic percent |
|---|---|---|
| Dashboard epic card bar | `project/app/ui/src/components/progress/epicBarModel.js` (`--graph --counts-only` via `/v1/progress-cards`) | The percent beside the bar and the `card_bar_aria` label (now "`%d%%` of the epic done"); the card shows no counts as text, so only the aria label's story counts stand beside it (section 15). It has no congratulation; with a failed story it shows the stated `99%` (`E92_S10_T02`) |
| Overlay dependency tree goal | `goalFacts` in `lib/progress/dependency-structure.js`, drawn by `DependencyTree.jsx` | The ring, halo, star fill (`fraction` = `percent / 100`), the `goal_progress` text (`tasks_done / tasks_denominator · percent %`), a second line with the `decomposed/stories` note, the aria label, and `dt-complete` on `goal_reached` (section 20.7). `goalFacts` carries `failedStories`; at the cap the name line (where "Goal reached!" would be) shows `goal_failed` in the failed colour, wrapped on spaces into lines of at most 24 characters, the lines below moving down, and the aria label ends with the same text (`E92_S10_T02`) |
| `j.status` overview (Node default) | `lib/progress/overview.js` (`--graph --counts-only`) | Each epic row: `tasks_done/tasks_denominator`, the percent, the dim note; rows sort by it; "Complete (N)" holds the `goal_reached` epics only. The board total line and its run bar stay summed `tasks.totals` (section 5.1); the row's small bar keeps the task buckets. At the cap a row names the failed story in the failed colour before its title (`E92_S10_T02`); the epic stays in its group (no failed task, so not "Needs attention") |
| `j.status <E##>` scope view (Node default) | `lib/progress/scope.js` (`--graph --within`) | The header (`decomposed/stories · percent %`), the message (its percent, and "stories left" counting an undecomposed story as unfinished) and the milestone goal flag (star on `goal_reached`). At the cap the message is `goal_failed` in the failed colour, ahead of the last-story and percent messages (`E92_S10_T02`). The run bar under it stays the epic's task bar with its own `n/total` (it is the parity-tested task bar; with every task done it still ends in its task star and `n/n`, a task count, not the goal). A story scope keeps its story's task percent and its done message: its payload states neither `epic_progress` nor the story's own status |
| `j.status --legacy` overview and scope view | `skills/j-status/scripts/render-status-overview.sh`, `render-status-scope-view.sh` | The same figures as the two Node views above, row for row and header for header, so `--legacy` and the default agree (`tests/lib-progress-overview-scope.test.mjs` compares them); the failed-story line too (`E92_S10_T02`, colour `31`) |

Checked and left unchanged, because they show no epic percent: `scripts/render-story-bar.sh` (the after-story line, a
**story's** `levels.tasks.totals` from `--story`), `lib/progress/bar.js` `renderBarLine` and `jenga progress bar --epic` /
`--each epics` (a task bar with `done/denominator` and no percent), `scripts/pipeline-stage.sh` (an in-progress count),
`render-status-scope.sh` (the `--legacy` tree block, no percent) and the dashboard pie charts (bucket shares of section 10,
not an epic percent).

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
- **The epic line (`E92_S09_T03`).** With `--epic <id>` one more line follows the level lines:
  `epic     <percent>% · <decomposed>/<stories> stories decomposed · <tasks_done>/<tasks_denominator> tasks done`, the
  `epic_progress` figures of section 5.1. Its words are fixed English, like `done` and `pending`. No other scope prints it.
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
                 "epic_progress": { "stories", "decomposed", "tasks_done", "tasks_denominator", "percent", "goal_reached" },
                 "ready_count": <ready tasks under the epic> } ],
  "stories": [ { "id", "epic_id", "title", "depends_on": [..], "totals": {..},
                 "complete": true|false, "decomposed": true|false|null,
                 "stop": "done|in_progress|failed|pending|rejected", "ready_count": <n> } ],
  "tasks":   [ { "id", "story_id", "epic_id", "title", "status", "bucket", "state",
                 "depends_on": [..], "blocked_by": [..], "waiting_on": [..], "unfinished_deps": [..],
                 "unlocked_by": "<id>"|null } ],
  "ready": [ "<task id>", .. ],
  "external": [ { "id", "status", "bucket" } ],          only with --within
  "warnings": [ { "kind", "id", "detail" } ]
}
```

- **Epics.** `stories.totals` is the epic's totals over its stories, `stories.complete` the number of stories whose
  `complete` flag is true, and `tasks.totals` the totals over every task under the epic. `epic_progress`
  (`E92_S09_T03`) is the epic percent of section 5.1, which counts undecomposed stories; it is the figure every view
  shows as the epic's percent (the views read it since `E92_S09_T04`; section 5.2 lists them).
- **Stories.** `complete` is true when the story's task denominator is above 0 and `done` equals it (rejected tasks are
  excluded, as everywhere). `stop` is the story's single colour bucket, decided in this order: `rejected` when the story's
  own status is `Rejected`; `done` when `complete`; `failed` when any task is failed; `in_progress` when any task is in
  progress or some but not all are done; otherwise `pending`.
  `decomposed` (`E92_S12_T01`, between `complete` and `stop`) states whether the story has been broken down into tasks,
  by the same definition as `epic_progress.decomposed` (section 5.1, "The per-story flag"): `true` for a counted story with
  at least one counted task, `false` for a counted story with none, `null` for a story that is not counted at all (its own
  status is `Rejected` or of unknown status). It is a bare JSON literal, present on every story entry in the full board,
  with `--counts-only` and with `--within`, and the same in all three.
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
- **`waiting_on`** (`E92_S10_T01`) lists the same unsatisfied ids, by the same rule and in the same order, for **every**
  task that is not in the done bucket (in progress, failed, rejected and unknown too, not only pending); it is `[]` for a
  done task and for a task whose effective dependencies are all satisfied. For a pending task it equals `blocked_by`,
  which keeps its meaning. It is what the padlock gate reads (20.0, "Rule: the padlock for every task state"), so no
  consumer re-derives satisfaction for a task that has left the pending bucket. An added key: `schema_version` stays 1.
- **`unfinished_deps`** (`E92_S11_T02`) lists the same unsatisfied ids, by the same rule and in the same order, for a task
  **in** the done bucket; it is `[]` for every other task and for a done task whose effective dependencies are all
  satisfied. A done task with a non-empty list is a board contradiction (section 30.12): a dependency reopened after the
  task was done, or a wrong `depends_on`. `waiting_on` and `unfinished_deps` never both hold ids for one task. It changes
  nothing else: the task keeps `state: done`, its bucket and every count, and its padlock stays open. An added key:
  `schema_version` stays 1.
- **`unlocked_by`** is set for a `ready`, `in_progress` or `done` task with at least one `depends_on`: the done
  dependency of the task's OWN `depends_on` that finished last (the larger `date_completed` wins; a tie or missing dates
  fall back to the larger id by numeric order, so `E10` is above `E9`). It is `null` when there is none.
- **`ready`** (top level) lists the ready task ids in numeric order; `ready_count` per epic and per story is the number
  of ready tasks under it.

The reader never re-derives any of this: the card bar, the tree and the scoped `j.status` block all take `state`,
`blocked_by`, `waiting_on`, `unfinished_deps`, `unlocked_by` and `ready` as given.

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
- **The percent beside the bar is the epic percent** `epic_progress.percent` of section 5.1 (`E92_S09_T04`), read as
  the script states it and never recomputed: the task fraction of the decomposed stories times decomposed / all stories,
  floored, so an epic with stories that have no task yet never shows 100 %. An entry without `epic_progress` shows `0%`.
  Before `E92_S09_T04` it was done tasks over total tasks (`tasks.totals`), rounded.
- **Colours** are the `--color-progress-*` tokens in `tokens.css` (the section 4 contract: green done, yellow in
  progress, red failed and blocked, grey pending, muted `Rejected`); no colour literal is in the component or its CSS.
- **Accessibility.** The wrapper is `role="img"` with an `aria-label` filled from the `card_bar_aria` label (`%d of %d
  stories complete, %d%% of the epic done`; it said "of tasks done" before `E92_S09_T04`); the percent text and the stops
  are `aria-hidden`.
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

> **Not the default since `E92_S08`:** the after-task line is drawn by the Node renderer (section 30.4); this bash bar is
> the `--legacy` path of `run-progress.sh` and what `j.status --legacy` draws (section 30.7).

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
>
> **Since `E92_S08`** the default `j.status <id>` is the Node scope view of section 30.5, not section 25.2;
> `j.status --legacy <id>` still runs this block (section 30.7).

`j.status` called with one epic or story id (for example `j.status E03` or `j.status E03_S05`) prints an extended block after
the scoped part of the overview. The plain overview never shows it. The block is produced by
`skills/j-status/scripts/render-status-scope.sh <id>`, which `skills/j-status/SKILL.md` calls once in step 6.10 and whose
output step 7 prints unchanged (layout in `skills/j-status/assets/output_format.md`). The script counts nothing and holds no
dependency logic: it reads `board-progress.sh --graph --within <id>` once and lays out `state`, `ready`, `unlocked_by`,
`depends_on`, `complete` and `stop`.

- **Tree.** A heading, the goal line (`⚑ Goal: <id>`, `★` when every story in the scope is complete), then each story (its
  `stop` symbol, id, title and `╌╌ <depends_on>`) with its tasks indented below it (state symbol, id, state word, title and
  the task's `depends_on`; `━━` before the dependencies of a task that is not blocked, `╌╌` when it is locked, failed or
  rejected). Only a scope with no tasks replaces the tree with the `tree_empty` label; a scope with tasks and no edge draws its
  stories and tasks (`E92_S09_T01`).
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
| `tree_empty` | `No tasks in this scope` | `Inga uppgifter i detta omfång` |
| `nothing_ready` | `Nothing is ready to take right now` | `Inget är redo att ta just nu` |
| `card_bar_aria` | `%d of %d stories complete, %d%% of the epic done` | `%d av %d berättelser klara, %d%% av epicen klar` |
| `epic_decomposed` (`E92_S09_T04`) | `%d/%d stories decomposed` | `%d/%d berättelser nedbrutna` |
| `goal_failed` (`E92_S10_T02`) | `Goal not reached - %s has failed` | `Målet ej nått - %s har misslyckats` |
| `goal_failed_more` (`E92_S10_T02`) | `Goal not reached - %s and %d more have failed` | `Målet ej nått - %s och %d till har misslyckats` |
| `story_undecomposed` (`E92_S12_T03`) | `Not broken down yet` | `Inte nedbruten ännu` |
| `story_undecomposed_aria` (`E92_S12_T03`) | `%s - not broken down into tasks yet` | `%s - ännu inte nedbruten i uppgifter` |

`story_undecomposed_aria` (one `%s`, the story id and title already joined by the caller) is the aria sentence of the start node of
an undecomposed story (section 20.2); the two keys are the last of `PROGRESS_LABEL_KEYS`.
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

### 20.0 Shared structure module (`E92_S08_T02`)

The graph structure (depth columns, gates, marks, folding of groups, story bands and start nodes, edges, goal facts, `ready`
and `unlocked`) lives in `lib/progress/dependency-structure.js`, which ships through the package's `lib/` entry and has no
pixel number and no import, so the Node terminal renderer can share it. `dependencyTreeModel.js` imports it, keeps `LAYOUT`,
`COL_WIDTH`, `layoutTree` (the pixels) and `unfoldGroups`, and re-exports every name it exported before, so the components are
unchanged. The model is deep-equal to the pre-split one (`project/app/ui/scripts/dependency-structure-parity.test.cjs` against
`tests/fixtures/progress/dependency-tree-parity.json`, run by `tests/progress-shared-structure.bats`, which also scans
`lib/progress/` for APIs newer than Node 14.13.1). The Vite dev server lists `lib/progress` in `server.fs.allow`
(`project/app/ui/vite.config.js`); the production build needs no setting.

<!-- begin E92_S09_T01: tree for every epic with tasks -->
#### Rule: a tree for every epic with at least one task (`E92_S09_T01`)

User request of 2026-11-15: an epic's tree always renders, whether or not it has dependency edges; the only exception is an
epic with no tasks.

- `buildDependencyStructure` returns the full structure (story bands with their start nodes, depth columns, edges, goal) for
  every epic with **at least one task**. With no dependency edge (a self-reference does not count) every task sits in depth
  column 0 of its story band with gate `none`, a `start` edge from its story and a `goal` edge; more than 3 tasks of one state
  in that column still fold. `empty` is `true` **only for an epic with zero tasks** (and for an unknown epic or an unreadable
  payload, which have none); the goal facts are filled in either way.
- The dashboard overlay therefore draws the tree for such an epic; the `tree_empty` label ("No tasks in this scope" /
  "Inga uppgifter i detta omfång", component fallback "No tasks to show") appears only for zero tasks.
- The terminal scope view (`j.status <E##>`, `lib/progress/scope.js`) draws the bands and the goal straight from the shared
  module; the one-column `foldStructure` fallback it used to carry for edge-free epics is removed. The legacy block
  (`j.status --legacy <id>`) prints `tree_empty` only for a scope with no tasks.
- The parity recording (`tests/fixtures/progress/dependency-tree-parity.json`) differs from the pre-split model in exactly the
  three edge-free cases, re-recorded and renamed, plus one added edge-free case; every other case is byte-identical.
<!-- end E92_S09_T01 -->

<!-- begin E92_S09_T02: one ready style, the padlock as the only dependency marker -->
#### Rule: every startable task is drawn ready; the padlock alone tells whether it has dependencies (`E92_S09_T02`)

User request of 2026-11-15: "Items that are available to start must all have a dashed border and the plus icon. The lock
is the only thing that distinguishes items that have/had dependencies from those that do not." The padlock reading below
was confirmed by the user the same day.

- **Ready rule.** A task is startable when `scripts/board-progress.sh` gives it `state: ready` (Pending, every id in its own
  `depends_on` and in its story's `depends_on` satisfied, section 13.2). Every such task is drawn ready, whether it has
  dependencies or not: in the dashboard the dashed border (`.dt-state-ready`), the ready ring and the plus mark; in the
  terminal scope view `◉` in the ready colour (cyan; since `E92_S11_T01` an `in_progress` task has its own `◐` in yellow,
  before that it shared `◉`) and its title under
  "Ready to take". A task in any other state never gets the ready style.
- **Padlock rule.** The gate (`gate` of a task in `lib/progress/dependency-structure.js`) is computed from the task's
  **effective dependencies**, its own `depends_on` plus its story's `depends_on`, the same two lists the script's `state`
  and `blocked_by` come from. It takes the script's verdict and adds no "satisfied" rule of its own:
  - `none` (no badge) only when both lists are empty;
  - `locked` (closed padlock) when the script lists unsatisfied ids in `blocked_by`, including a task locked **only**
    through its story's `depends_on`;
  - `open` (open padlock) for a `ready` task: the script found every effective dependency satisfied (a rejected
    dependency counts as satisfied there, so it opens the padlock of a ready task);
  - for a task that has left the pending bucket (done, in progress, failed, rejected): superseded by `E92_S10_T01`, see
    "Rule: the padlock for every task state" below. (Until then it was `open` when every one of the task's OWN
    dependencies was in the done bucket, else `locked`, which closed the padlock on done tasks.)
  So the padlock is the only visual difference between a startable task that has or had dependencies and one that never
  had any, a startable task never carries the closed padlock, and a locked task never carries the open one or none.
  Story dependencies draw no edge; `dependsOn` and the edges stay the task's own.
- **Cause found on 2026-11-15** (board at `ec7a7cfa`): the gate was computed from the task's own `depends_on` only. 14
  tasks locked only through their story (for example `E91_S02_T01`, `E92_S09_T03`) had gate `none`, so they showed neither
  the plus nor a padlock and read as "no dependency, yet not startable"; 3 tasks (`E91_S03_T02`, `E91_S04_T02`,
  `E91_S04_T03`) showed an open padlock on a task that cannot start. The ready style itself was already keyed on `state`
  alone in both renderers. Edge-free epics showed the empty state instead of their ready tasks until `E92_S09_T01`.
- The terminal arrow into a node follows the gate (`open` green, else the locked colour), so a task locked through its
  story gets the locked arrow colour; the dashboard edge keeps its colour rule (20.3: a locked dependent green when its
  dependency is done).
- The parity recording changed the `gate` of the ready tasks in exactly two cases whose fixtures hold a ready task with an
  unfinished dependency (input the script never prints), from `locked` to `open`; both are renamed with
  `(ready gate open, E92_S09_T02)`, and nothing else in the recording changed.
<!-- end E92_S09_T02 -->

<!-- begin E92_S10_T01: the padlock rule for every task state -->
#### Rule: the padlock for every task state (`E92_S10_T01`)

User decision of 2026-11-15 (decision 1 of `E92_S10`): "Om den inte är genomförd och har beroenden som inte är uppfyllda
ska det vara ett stängt lås, annars ska det alltid visas ett öppet lås oavsett status på ärendet" (if it is not done and has
dependencies that are not satisfied it must be a closed padlock, otherwise always an open padlock, whatever the item's
status). The gate (`gateOf()` in `lib/progress/dependency-structure.js`) reads the task's **effective dependencies** (its own
`depends_on` plus its story's, as in `E92_S09_T02`):

| Task | Gate |
|---|---|
| no effective dependency | `none` (no padlock, unchanged) |
| in the done bucket (`Passed`, `Passed with remarks`, the lifecycle statuses), whatever its dependencies | `open` |
| not done, and at least one effective dependency unsatisfied | `locked` (closed padlock) |
| not done, every effective dependency satisfied (ready, in progress, failed, rejected, unknown) | `open` |

- **Where "unsatisfied" comes from.** The script states it: `waiting_on` (13.2) lists the unsatisfied effective ids of every
  task not in the done bucket, by the script's one rule (the named item is in the done bucket through its own status, or is
  rejected). The gate is `locked` when the task is not done and the payload states something it waits for: a non-empty
  `waiting_on`, a non-empty `blocked_by` or `state: locked` (for a pending task the three agree). No "satisfied" rule is
  re-derived in JavaScript. Of the task's two ways, the script key was taken because the payload states a story's OWN
  status nowhere outside `external` (`stop` is task-derived), so a consumer could not apply the rule to a story dependency.
- **A payload from an older script** (no `waiting_on`) closes the padlock only on a locked pending task; a task in progress,
  failed or rejected shows the open one, as the payload states nothing it waits for.
- **Consequences.** A done task never shows the closed padlock; a `ready` task always shows the open one; a rejected
  dependency opens the padlock (it is satisfied); a task in progress, failed or rejected whose effective dependency is still
  unsatisfied shows the **closed** padlock (the literal reading; open point of `E92_S10`, whether `Rejected` counts as
  "genomförd", for the user to decide).
- **Real board, 2026-11-15** (gate per task bucket, every epic, before and after): done `locked` 43 to 0 and `open` 752 to
  795; rejected `locked` 37 to 0 and `open` 28 to 65; pending unchanged (47 `locked`, 15 `open`); failed and in progress
  unchanged (1 `open` each). No task that is in progress, failed or rejected has an unsatisfied effective dependency today,
  so the open point changes no padlock on the current board.
- Both views follow from the one gate: the dashboard through `dependencyTreeModel.js` (the badge on the card), the terminal
  through `lib/progress/tree-text.js` (the arrow into a node is green for `open`, else the locked colour).
- The parity recording changed `gate` keys only, in eight cases renamed with `(gate rule, E92_S10_T01)` and listed in
  `project/app/ui/scripts/dependency-structure-parity.test.cjs`.
<!-- end E92_S10_T01 -->

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

#### The undecomposed story: a ghost band and start node (`E92_S12`)

A story that has not been broken down into tasks used to have no band at all, so an epic could look finished while a story
was missing from the picture. Since `E92_S12` the overlay tree draws it, from the per-story `decomposed` flag of the payload
(section 5.1, "The per-story flag"); nothing is counted in the browser.

- **What qualifies.** A story of the epic stated `decomposed: false` that has no task node. `true`, `null` and a payload
  without the key add nothing anywhere, so the model is deep-equal to the one built before `E92_S12`. A story stated `false`
  that still has task nodes (every task rejected or of unknown status, which are drawn) keeps them, and gets the dashed
  outline of its band and of its start node and the label on its start node, but no ghost edge (its tasks already reach the goal).
- **What is drawn.** A **ghost band** (`dt-band-ghost`, `data-undecomposed="true"`) with no cells, so **no task node**, and a
  **ghost start node** (`dt-start-ghost`, `data-undecomposed="true"`) with the story id, its title, `0/0` and the label text
  `story_undecomposed` ("Not broken down yet"). The mini bar is left out on purpose, so the node never reads as 0 %
  progress. The outline of the band and of the start node is **dashed** (`9 4`, longer dashes than anything else on the
  map), so the state is not carried by colour; the text is italic in `--color-text-muted`. Bands are ordered by story id with
  the decomposed ones, so a ghost band sits where the story would.
- **Aria.** The start node has `role="group"` and an `aria-label` from `story_undecomposed_aria` filled with the id and the
  title ("E01_S02 Second - not broken down into tasks yet"); its `<title>` tooltip is the same sentence. A payload without
  the two labels still draws the dashed outline and omits the text and the aria label (they are read as optional).
- **The goal edge: drawn (decision of `E92_S12_T02`).** Each ghost band has one edge from its start node to the goal, of
  `kind: ghost`. Without it a ghost band would be an orphan: it has no task, so neither a `start` nor a `goal` edge exists
  for it, and the goal would look reachable without it, which is what the band is there to contradict. It is drawn
  **dash-dot** (`10 3 2 3`) in the neutral border colour, never in the ready colour or dash, and it is not part of any
  card's hover chain (the story has no card), so it recedes with the other edges while a card is hovered. A story that has
  task nodes gets none: its tasks already have `start` and `goal` edges.
- **An epic with no task node keeps the empty state.** Ghost bands appear only in an epic that already has at least one
  task node. An epic whose stories are **all** undecomposed has zero task nodes and so keeps the `empty` structure of
  section 20.0 ("a tree for every epic with at least one task"): the `tree_empty` text, no band, no start node and no ghost
  edge. This is deliberate and pinned by a test (the user may revisit it); the epic card still shows its `0 %` and its
  decomposed count.
- **What does not change.** The epic card bar (section 15), the terminal bars and views (sections 9, 17, 18, 25; the Node
  renderers do not pass the option that enables ghost bands) and the percent formula of section 5.1 are untouched: the
  ghost band draws a fact the payload already states and adds nothing to any figure. The goal still shows `done / total ·
  percent %` and, while `decomposed < stories`, the `epic_decomposed` note. Zoom, Fit, pan and the large and fullscreen view
  (sections 21 and 29) measure the layout, which includes the ghost bands, so they need no special case.
- **Checked.** Tests: `tests/dashboard-snapshot-progress-graph.bats` captures a fixture project of one epic with three
  stories (one decomposed, two without a task file), asserts `decomposed` `true`, `false`, `false` in the captured
  payload, renders the real tree over it (`project/app/ui/scripts/render-captured-epic-tree.cjs`) to three bands, two
  dashed and labelled, and does the same from the `--snapshot` HTML alone, so the payload is embedded and no server is
  needed; the model, drawing and label tests are in `dependency-tree-model.test.cjs`, `dependency-tree.test.cjs` and
  `tests/progress-labels.bats`. In a browser, the project's own board (epic `E01`, 8 stories, 2 undecomposed) was opened
  in the light and the dark theme, live and in a `--snapshot` file: dashed bands, dashed start nodes with the text,
  no task node in them, zoom, Fit and the fullscreen layer working. Two limits, stated as observed: the snapshot file was
  served unchanged over loopback `http` because the browser pane refuses `file://` addresses (the `file://` claim rests on
  the bats case and on the file needing no server, not on a real `file://` open), and native real fullscreen was not
  observed (the pane neither entered it nor fell back by itself; the fixed-layer fallback of section 29.2 was exercised, as
  in `E92_S07_T10`, which is open item 1 of section 29.8 and not caused by this story).

### 20.3 Edges

- **Direction.** An edge `{ from, to }` runs from the dependency to the dependent: it leaves the **right** edge of the
  dependency and arrives at the **left** edge of the dependent (the gate badge included). This reverses the v1 convention
  of 16.1, and the model header states it.
- **Kinds.** `dependency` (task to task), `boundary` (an outside node to a task), `start` (a start node to a task with no
  in-epic dependency), `goal` (only a task that **nothing in the epic depends on** connects to the goal) and, since
  `E92_S12`, `ghost` (the start node of an undecomposed story to the goal, section 20.2).
- **Above the bands.** The paint order is bands, then edges, then start nodes, boundary nodes, collapse headers, cards and
  the goal, so no band fill hides a line.
- **Dotted cross-story edges.** An edge between two stories (and every boundary edge) carries `crossStory` and is drawn dotted
  (`dt-edge-cross`). The colour of an edge follows the state of the **dependent**: done green, in progress yellow, failed red,
rejected muted, ready grey and dashed (it flows, see 22.3), and a locked dependent green only when its dependency is done,
else a neutral border colour. Edges are de-duplicated by `from` and `to`; while a chain is highlighted (20.6) the other
edges drop to 10 % opacity.

### 20.4 The gate icon and the status marks

A small circular **gate badge** sits on the left edge of a card and answers one question, "is this task waiting for a
dependency?". Since `E92_S09_T02` it reads the task's effective dependencies (its own `depends_on` plus its story's), and
since `E92_S10_T01` the script's verdict for every task state (`waiting_on`, `blocked_by`, `state`). The full rule is in
20.0, "Rule: the padlock for every task state":

| Gate | Shown | Meaning |
|---|---|---|
| `none` | no badge | neither the task nor its story has a dependency |
| `locked` | closed grey padlock | the task is not done and at least one effective dependency is unsatisfied (`waiting_on` is non-empty) |
| `open` | open green padlock | it has dependencies and the task is done, or none is unsatisfied (every `ready` task with dependencies) |

The **status mark** stays on the right of the card: tick (`done`), half-filled dot (`in_progress`), **plus on every ready
task**, cross (`failed`), dash (`rejected`). A **locked task shows only the closed gate**, no status mark. A state is never
carried by colour alone: the marks, the gate, the `aria-label` and the `<title>` all state it in words from the labels.
The padlock shapes are the prototype's final path values, and a test asserts that the open shackle's bounding box, stroke
included, lies inside the badge circle.

### 20.5 Group folding

When **more than 3** tasks (`FOLD_THRESHOLD = 3`, lowered from 5 by `E92_S11_T03` on 2026-11-15) share one state inside one story and one column, they fold into **one
stacked card** ("N tasks . state", with a "Show all N" action); click, Enter or Space expands it and an expanded group gets a
"Collapse" header. The edges of a group are the union of its members' edges, and `unfoldGroups(model, expandedIds)`
re-lays out with chosen groups open. The expansion state lives in the component, not in the model.

### 20.6 The hover chain

Hovering or keyboard-focusing a card highlights its **full upstream and downstream chain** and dims everything else (the
model precomputes `upstream` and `downstream` per node; a group carries the union of its members'). A tooltip lists
"Depends on" and "Unlocks", or "Leads straight to the goal" for a task that connects to it directly. The tooltip is HTML
anchored to the drawing; since zoom and pan (section 21) it is positioned in pixels and follows the view.

### 20.7 The Goal and its progress scaling

The goal is a star in a disc with a **progress ring**, drawn from the epic percent (`goal.fraction`, `percent`, `done`,
`total`, `reached`, `stories`, `decomposed`). Since `E92_S09_T04` these are the script's `epic_progress` read unchanged
(section 5.2): `percent` and `reached` (`goal_reached`) as stated, `fraction` = `percent / 100`, `done`/`total` =
`tasks_done`/`tasks_denominator`; while `decomposed < stories` a second line under the counts shows the
`epic_decomposed` note, also in the aria label. Before, they were the epic's task totals. It scales with the completed
share `p` (0 to 1):

- the **halo** has strength `0.07 + 0.38 p` (`--goal-halo-opacity`) and radius `(54 + 26 p) / 54` times its base
  (`--goal-halo-scale`); the halo "breathes" (a slow opacity loop), and the radiating pulse of v1 is gone;
- the **star fills from the bottom** with `p`, and the ring shows the same share with the `goal_progress` text ("done / total · percent %");
- at `p = 1` (`goal.reached`) the goal gets `dt-complete`: green, a **shimmer** sweep, **five sparks** that twinkle, and the
  `goal_reached` word.
- while a story of the epic has failed (`goal.failedStories`, the script's `failed_stories`, `E92_S10_T02`) the goal is
  never reached and `p` stops at `0.99`; at that cap the name line shows `goal_failed` / `goal_failed_more` (class
  `dt-goal-failed`, the failed colour) instead of `Goal`, wrapped into lines of at most 24 characters, and the aria label
  ends with the same text (section 5.1).

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

> **Since `E92_S08`** the story-scope lines are drawn by `cli.js after-task` (section 30.4) by default; the bash output
> below is the `--legacy` path (`--legacy` or `JENGA_PROGRESS_RENDERER=legacy`, section 30.7). The scope rule is unchanged.

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

> **Since `E92_S08`** `story-finished.sh` draws the line with `cli.js after-story` (section 30.4) by default;
> `render-story-bar.sh` (24.1, 24.2) is the `--legacy` path. The decision and the ledger (24.1, 24.3) are unchanged.

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

> **Superseded by `E92_S08`:** `j.status` now runs the Node `overview` and `scope` views (section 30.5); the two scripts
> below stay on disk but are no longer routed, not even by `--legacy` (section 30.7).

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
   percent, a failed or in-progress marker and the title cut to the width (since `E92_S09_T04` the row's done/total and
   percent are the epic's `epic_progress`, with a `decomposed/stories` note while lower; section 5.2);
3. complete epics collapsed to **one** line ("Complete (N)" and their task total; since `E92_S09_T04` an epic is complete
   only when its `goal_reached` is true), and epics with only rejected tasks or no tasks to **one more** line;
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

1. **Header block.** Title and percent (for an epic, since `E92_S09_T04`, the `epic_progress` percent with a
   `decomposed/stories` note while lower, section 5.2); for an epic a **milestone track** (a start glyph, one segment and stop per story, then
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

> **Since `E92_S08`** the `overview` and `scope` rows route to `node lib/progress/cli.js` and the resolver also takes
> `--charset`; the legacy rows are unchanged (current table in section 30.7).

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

## 30. The Node terminal renderer (`E92_S08`)

Story `E92_S08` (2026-11-14) moved the drawing of every terminal progress view from bash to Node, in the design of the
prototype `project/documentation/prototypes/E92_S06/bars-prototype.html` and the story's design image: UTF-8 glyphs,
colour, a milestone line, a hatched run bar with `n/total`, and story bands with ready (`◉`) and locked (`○`) nodes. It
ports **rendering only**. The counts still come from `scripts/board-progress.sh` alone (`E92` decision 1) and the words
from `scripts/lib/progress-labels.sh` alone, so the Node code counts nothing and holds no user-visible word. The bash
renderers of sections 17, 18, 23, 24 and 26 stay on disk, unchanged, as the `--legacy` path.

This section is written from the code as built on main at `e1b14b10` (2026-11-15). Every command it names was run once
for `E92_S08_T09`, with `LANG=` (empty, locale C) and a pipe on stdout unless the text says otherwise, and every block of
output below is real output of that run, abridged where it says so. The board moves on, so the numbers will not match a
later run. Subsection 30.4 is the text `E92_S08_T04` wrote, kept as it was apart from one cross-reference.

### 30.1 Why the bash renderers showed ASCII and no colour

The bash renderers guess. They pick glyphs from `LC_ALL`, `LC_CTYPE` and `LANG`, and colour from "stdout is a terminal"
plus `NO_COLOR`. The Bash tool an agent runs commands in has `LANG=""` (locale C) and a pipe on stdout, so they always
fell back to ASCII and no colour. The same after-task call, drawn both ways in that environment:

```text
$ run-progress.sh --scope story --task E92_S08_T09 --charset utf8 --color never
E92_S08  ▰▰▰▰▰▰▰▱▱▱⚑ 7/10
$ run-progress.sh --scope story --task E92_S08_T09 --legacy --color never
[#######---]> 7/10
```

(`JENGA_PROGRESS_RENDERER=legacy` in place of `--legacy` gives the same second line.) Node always writes UTF-8, so the
glyph set and colour became an **explicit** choice: a flag, then an environment variable, then a config key, then a
default (30.3). Nothing under `lib/progress/` reads `LC_ALL`, `LC_CTYPE` or `LANG`.

The second problem was where the output lands: the desktop app folds tool output into a collapsed tool-call row, so a
rendering is seen only when the agent copies it into its reply. That is handled by the wiring (30.7), not by the
renderer.

### 30.2 Module map, entry point, data and labels

Everything lives in `lib/progress/` (ESM, Node built-ins only, no dependency). The entry point is `lib/progress/cli.js`;
`jenga progress` (30.6) runs the same `run()` in-process.

| Module | What it holds |
|---|---|
| `cli.js` | Argument parsing, the sub-command table (`COMMANDS`), the never-fail rule, the EPIPE guard; exports `run(argv, io)` |
| `charset.js` | The two glyph tables (`utf8`, `ascii`; every glyph one code point and one cell) and the charset resolution |
| `color.js` | The colour mode resolution, the ANSI painter, the palette keyed by bucket name (`SGR`) |
| `config.js` | `resolveChoice` (the one precedence rule) and the reader of the two `dashboard-config.json` keys |
| `width.js` | Terminal width resolution, display width (ANSI counts zero, one cell per code point), truncation with `…` |
| `data.js` | Runs `scripts/board-progress.sh` and parses its JSON; finds the scripts directory |
| `labels.js` | Runs `scripts/progress-labels-json.sh` and fills `%d`/`%s` placeholders |
| `bar.js` | The run bar (`bar` sub-command), cell allocation, the rejected note |
| `lines.js` | The after-task and after-story lines (`after-task`, `after-story`) |
| `overview.js` | The `overview` view |
| `scope.js` | The `scope` view: header, milestone line, run bar, bands, the ready and "unlocked by" lists |
| `tree-text.js` | The character-cell layout of a story band (`--layout horizontal\|vertical\|auto`) |
| `dependency-structure.js` | The shared graph structure (section 20.0), used by the dashboard and by `scope.js` |

- **Data.** `data.js` runs `bash <scripts>/board-progress.sh` with the same arguments the bash renderers pass
  (`--graph`, `--story <id>`, `--within <id>`, `--counts-only`, ...) and parses the JSON. Failure is a value, never a
  throw. The scripts directory is `JENGA_PROGRESS_SCRIPTS_DIR` when set (a test seam, then the only candidate), else
  `scripts/` next to the package's `lib/` (the repository, or `node_modules/@jenga-ai/agent/` when installed), else
  `<cwd>/scripts`, else `<cwd>/node_modules/@jenga-ai/agent/scripts`.
- **Labels.** `labels.js` runs `scripts/progress-labels-json.sh` once per call, with `JENGA_PROGRESS_LANG` set from
  `--lang` when given (English by default, `sv` for Swedish). That script forks per label and takes seconds on the
  maintainer's machine; every command that draws pays it once. `node lib/progress/cli.js labels` prints the table.
- **Shared structure.** `dependency-structure.js` decides what a tree is (depth columns, bands, gates, folding, ready and
  unlocked, goal); `tree-text.js` decides how it is drawn in cells. The dashboard model
  `project/app/ui/src/components/progress/dependencyTreeModel.js` imports the same module (section 20.0, and the
  `E92_S09` rules there).
- **Diagnostics.** `info` prints the resolved settings and both glyph tables, `data <board-progress args>` prints the
  script's JSON, `labels` prints the label table.

`node lib/progress/cli.js --help` prints, exactly:

```text
usage: cli.js [options] <command> [command arguments]

options (anywhere on the line):
  --charset utf8|ascii       glyph set (default utf8; env JENGA_PROGRESS_CHARSET; config progress_charset)
  --color auto|always|never  colour (default auto; env JENGA_PROGRESS_COLOR; config progress_color)
  --cols N                   width in columns (default COLUMNS, then the terminal, then 80)
  --root <dir>               project root (sets JENGA_PROJECT_ROOT)
  --lang <code>              label language (sets JENGA_PROGRESS_LANG; default en)
  -h, --help                 print this usage

commands:
  info         print the resolved settings and the active glyph table
  data         run scripts/board-progress.sh with the given arguments and print its JSON
  labels       print the label table for the effective language
  bar          one run-bar line for a scope (--epic, --story, --ids or bare ids, --all, --backlog), or one per epic or story
  after-task   the line of the story a finished task belongs to: --task <id>[,<id>...] (one line per distinct story)
  after-story  the story-finished line: --story <id>[,<id>...] [--ready N] (the ledger stays in story-finished.sh)
  overview     the board overview: totals, the run bar and the epics still in progress (--all is the caller's legacy list)
  scope        the scope view of one epic or story id: milestone line, run bar, story bands, ready and locked nodes

exit codes: 0 ok (also when progress is unavailable: one warning on stderr), 2 usage error
```

The usage lists the shared flags only. The flags of each sub-command are not in it: `bar` takes `--level`, `--cells`,
`--each`, `--epic`, `--story`, `--ids`, `--all`, `--backlog`; `after-task` takes `--task`, `--story`, `--cells`;
`after-story` takes `--story`, `--ready`; `overview` takes `--all` (accepted, prints nothing, as the bash renderer did);
`scope` takes `--layout`. An unknown flag of a sub-command is a usage error (exit 2). The gap in the usage text is filed
as a rapport (30.10).

**The never-fail rule.** A progress problem (an unknown id, a missing script, a failing script, an invalid environment
or config value, an unexpected exception) prints one `cli.js: warning: ...` line on stderr, nothing on stdout, and exits
`0`. Only a usage error exits `2` (an unknown flag or command, a flag without its value, an invalid flag value), with the
problem and the usage on stderr. Observed: `after-task --task E99_S99_T99` printed `cli.js: warning: unknown task id, or
it names no story: E99_S99_T99` and exit 0; `--color purple bar` printed `cli.js: --color must be auto, always or never
(got: purple)` plus the usage and exit 2; `scope E92_S09_T01` exited 2 (`'E92_S09_T01' is a task id; give an epic or a
story id`).

### 30.3 Charset, colour and width: flag, environment variable, config key, default

| Setting | Flag | Environment variable | Config key (`dashboard-config.json`) | Default |
|---|---|---|---|---|
| Glyph set | `--charset utf8\|ascii` | `JENGA_PROGRESS_CHARSET` | `progress_charset` | `utf8` |
| Colour | `--color auto\|always\|never` | `JENGA_PROGRESS_COLOR` | `progress_color` | `auto` |
| Width | `--cols N` (1 to 10000) | `COLUMNS` | none | the terminal's own width when stdout is a terminal, else `80` |
| Project root | `--root <dir>` | `JENGA_PROJECT_ROOT` | none | the upward search of `scripts/resolve-root.sh` |
| Language | `--lang <code>` | `JENGA_PROGRESS_LANG` | none | `en` |

- **Precedence** is flag, then environment variable, then config key, then default (the story's decision 3), in one
  function, `resolveChoice` in `config.js`. The nearest, most deliberate statement wins. A layer whose value is not
  allowed is skipped with one warning and the next layer is tried: `JENGA_PROGRESS_COLOR=bogus ... info` warned
  `JENGA_PROGRESS_COLOR: "bogus" is not one of auto, always, never; ignored` and reported `color=auto ...
  source=default`.
- **Colour modes.** `auto` is on only when stdout is a terminal and `NO_COLOR` is unset or empty; `always` is on even with
  `NO_COLOR` set and a pipe (observed: `NO_COLOR=1 ... --color always bar` wrote `ESC[32m`); `never` is off even on a
  terminal. The palette is keyed by the bucket names `board-progress.sh` prints, so Node maps no status: done green
  (`32`), in progress yellow (`33`), failed red (`31`), pending grey (`90`), rejected a muted blue-grey (`38;5;67`), plus
  the two node colours of the design, ready cyan (`36`) and locked grey (`90`), and a 256-colour green gradient on the
  milestone line.
- **Charset.** `utf8` and `ascii` have the same keys; every `ascii` glyph is below `0x80`. Run with `LANG=` and a pipe,
  `bar --epic E92` printed `▰▰▰▰▰▰▰▰▰▱⚑ 68/71` and `--charset ascii bar --epic E92` printed `#########-> 68/71`.
- **The config keys** are two optional keys of the **existing** `project/configs/dashboard-config.json` (no new file,
  no rename). A project that predates them simply lacks them, so there is **no migration**: a missing file, key or
  configs directory means the default, silently. The file is found through `scripts/resolve-root.sh get configs`, as
  `board-progress.sh` finds it. Each key has a descriptor in `templates/config-descriptors/dashboard-config.json`
  (a string with an `allowed` list, marked optional), so `jenga config` reads and sets them:

  ```text
  $ jenga config get dashboard-config.progress_charset        (key absent in this repository: the default)
  utf8
  $ jenga config get dashboard-config.progress_color
  auto
  $ jenga config set dashboard-config.progress_charset ascii  (run against a scratch project, not this repository)
  dashboard-config.progress_charset = "ascii"
  $ jenga config set dashboard-config.progress_color purple
  progress_color: "purple" is not one of the allowed values "auto", "always", "never"     (exit 4)
  ```

  In that scratch project `cli.js --root <it> info` then reported `charset=ascii source=config`; with
  `JENGA_PROGRESS_CHARSET=utf8` it reported `source=env`, and with `--charset ascii` as well, `source=flag`.
  `scripts/dashboard-port.sh` keeps the two keys when it rewrites the port (`tests/dashboard-port.bats`, "ensure keeps
  progress_charset and progress_color ...").

### 30.4 The Node run bar and the after-task and after-story lines (`E92_S08_T04`)

`lib/progress/cli.js` draws the run bar and the two story lines in the hatched design (the bash renderers of sections 17,
23 and 24 stay untouched and remain the `--legacy` path). The command is `node lib/progress/cli.js [--charset utf8|ascii]
[--color auto|always|never] [--cols N] [--lang sv] <command>`; charset and colour are explicit settings (section 30.3 and the
story's decision 3), never read from the locale.

| Command | What it draws | Counts from |
|---|---|---|
| `bar [--level tasks\|stories\|epics] [--cells N] [scope]` | the run bar, one line | `board-progress.sh <scope>`; the scope is `--epic <id>`, `--story <id>`, `--ids <list>` (or bare ids), `--all` (the default) or `--backlog` |
| `bar --each epics\|stories` | `<id><TAB><line>` for every epic or story | `board-progress.sh --by-parent` (no scope, no `--level`) |
| `after-task --task <id>[,<id>...]` | one line per distinct story of the finished tasks, led by the story id (`E92_S06  ▰▰▰▱▱▱▱▱▱▱⚑ 3/4`) | `--graph` (`tasks[].story_id`, only for task ids), then `--story <id>` per story; `--story <id>` names stories directly |
| `after-story --story <id>[,<id>...] [--ready N]` | the story-finished line `E92_S06  <bar>★ 4/4 · 100 %` plus counts that wrap under the bar | `--story <id>` |

- **Bar.** Each state has its own cell glyph as well as its own colour, in the order done, in progress, failed, pending: `▰`
  (ASCII `#`) done in green, `▒` (ASCII `=`) in progress in yellow, `✕` (ASCII `x`) failed in red, `▱` (ASCII `-`) not started
  in grey (since `E92_S11_T01`; before it, done, in progress and failed all drew `▰` and only the colour told them apart, see
  30.11). Cells are allocated by the same largest-remainder rule as the bash renderer.
  The goal mark after the bar is `★` when everything counted is done, otherwise `⚑`; none for `0/0`.
- **Text.** `done/denominator`, then `in progress`, `red` (failed), `unknown` and the rejected note, each only when above 0. Every
  word is a label of `scripts/lib/progress-labels.sh` (English by default, `--lang sv` or `JENGA_PROGRESS_LANG=sv` for Swedish).
  `Rejected` is excluded from the denominator and shown as the note `⊘ n rejected (not counted)` in a muted blue-grey that is none of
  the status colours; it is never drawn as a cell.
- **Narrow terminals.** The run bar is at most `--cells` (default 10) and shrinks to the room left; below 4 cells the bar is dropped
  and the text alone is printed, which then loses unknown, the rejected note and in progress, in that order, and only last is cut to
  width-1 cells plus one ellipsis. The story line has a 8 to 30 cell bar, is text-only under 40 columns, and wraps its counts under
  the bar instead of cutting them. No line is wider than the width (display width, ANSI not counted).
- **Never fails a run.** An empty scope (exit 3 of `board-progress.sh`), an unknown id (exit 2), a task naming no story or a missing
  script prints one `cli.js: warning:` line on stderr, nothing on stdout, and exits 0; every id is resolved before anything is
  drawn, so one bad id prints nothing. Only a usage error exits 2. An EPIPE on stdout (a reader that closes early) is ignored.
- **Whether to print** an after-story line, and the once-per-completion ledger, stay in `skills/j-break/scripts/story-finished.sh`.
- **Cost.** `loadLabels` runs `scripts/progress-labels-json.sh`, which forks per label and takes seconds on the maintainer's
  machine, so every command pays it once per call; the tests therefore serve the label tables from a stub scripts directory.

### 30.5 The overview and scope views, and the narrow-terminal layout (`E92_S08_T05`)

Both views replace the bash views of section 25 as the `j.status` default. They read the board once, count nothing,
take every word from the label table and every glyph from `charset.js`, and cut every line before painting it, so no
line is wider than the width. Measured at 80 columns (`--cols` unset, `COLUMNS` unset, a pipe): the widest line of
`overview` and of `scope E92` was 80 cells.

**`overview`** (no id) reads `board-progress.sh --graph --counts-only` and prints the total line, the run bar with its
counts, the epics that are not complete in four groups (needs attention, in progress, started, not started; highest
percent first, ties by id), one line for the complete epics, one for the epics with only rejected tasks or no tasks, and a
footer hint. Under 50 columns the bars are dropped. `--all` is accepted and prints nothing: the full list is the legacy
path (30.7). Real output, `cli.js --charset utf8 --color never overview` (abridged to two rows per group):

```text
Board · 92 epics · 1450/1577 tasks · 92 %
  ▰▰▰▰▰▰▰▰▰▰▰▱⚑ 1450/1577 · 1 in progress · 6 red · ⊘ 101 rejected (not counted)
  ○ 120 pending

Needs attention (4)
  E70 ▰▰▰▰▰▰▰▰▰▰▰▰▰▰ 16/17 94 %  ✕1  Retire Jenga's Own Use of docs/ (Site Sour…
  E61 ▰▰▰▰▱▱▱▱▱▱▱▱▱▱   0/7  0 %  ✕2  Master Set Manifest and Instruction-File M…

Started (16)
  E22 ▰▰▰▰▰▰▰▰▰▰▰▰▰▱ 30/31 97 %    /publish Skill — Deployment Pipeline Orchest…
  E92 ▰▰▰▰▰▰▰▰▰▰▰▰▰▱ 68/71 96 %    Progress Visualisation: see how far a run, a…

Not started (3)
  E52 ▱▱▱▱▱▱▱▱▱▱▱▱▱▱ 0/2 0 %    Agent Orchestration — Cross-Session Message Iso…

★ Complete (60)  1034 tasks · hidden
⊘ Only rejected or empty (9): E02, E04, E23, E48, E55, E81, E82, E84, E90

Details for one epic: j.status <id>  ·  all rows: j.status --all
```

(`E61` shows four filled cells at `0/7`: they are its two failed tasks, red in colour. This sample was captured before
`E92_S11_T01`, when done and failed cells shared `▰`; the same rows now read `E70 ▰▰▰▰▰▰▰▰▰▰▰▰▰✕` and
`E61 ✕✕✕✕▱▱▱▱▱▱▱▱▱▱`, so a failed cell is visible without colour, see 30.11.)

**`scope <E## | E##_S##>`** reads `board-progress.sh --graph --within <id>` and prints:

1. a header, `<id> · <title>` and the percent (for an epic the `epic_progress` percent since `E92_S09_T04`, section 5.2);
2. for an epic, the **milestone line** (below) and one line with the message and "Ready to take" (the first two ids of the
   payload's `ready` list, `(+N)` for the rest); a story id gets the header without the track, and without a message
   unless the story is complete;
3. the run bar of 30.4 with `n/total`;
4. one **band** per story: the story title in capitals with `done/total`, then its tasks as nodes, `●` done, `◉` ready
   (cyan), `◐` in progress (yellow; it shared `◉` with ready until `E92_S11_T01`), `✕` failed, `⊘` rejected, `○` locked or
   pending, joined by arrows that are real
   dependency edges, with references for the other dependencies and `⚑` after every node that reaches the goal (the rule
   is below, "Arrows, references and the row order"); the structure (depth columns, gates, folding of more than three
   tasks of one state into a group node such as `● 4 tasks`, the edges) comes from `dependency-structure.js`. Every story
   is listed, complete ones too (the hiding line of section 25.2 is not drawn, and `j.status <id> --all` therefore
   changes nothing);
5. "Ready to take:" with the titles of the ready tasks, then one "`<task>` unlocked by `<what it waits for>`" line per
   locked node, where a dependency is named by its task title or, for a story dependency, its story id, joined with `+`.

Real output, `cli.js --color never scope E91`, re-captured on 2026-11-15 after `E92_S10_T03` (abridged to three bands
and three "unlocked by" lines; at 80 columns the first two bands fit and stay horizontal, the third is vertical):

```text
E91 · Major-release capture: record why a release is major and which epic…  17 %
●━━━━━━━╌╌╌◉╌╌╌╌╌╌╌╌╌╌○╌╌╌╌╌╌╌╌╌╌○━━━╌╌╌╌╌╌╌◉╌╌╌╌╌╌╌╌╌╌○╌╌⚑
           S01        S02        S03        S04        S05 Goal
Good pace! 5 stories left  ▸  Ready to take: E91_S01_T03

E91  ▰▰▰▰▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱⚑ 3/17

BREAKING-CHANGE RECORD FORMAT AND THE J.BREAKING-CHANGE SKILL (WITH THE J.… 2/3
      ● Define the br…───▸● Add the j.bre…───▸◉ Add the j.maj…───▸⚑

MAJOR-BUMP DETECTION AND THE EPIC PICKER 0/3
      ○ Add detect-ma…───▸○ Add list-epic…───▸○ Add the epic …

DEPLOY-PUBLIC WIRING: CAPTURE STEP, RECORD REUSE AND THE SOFT WARNING AT A… 0/4
  ○ Add release-check.sh (decides skip, reuse or capture; asks nothi… ◂─ S02_T01
    └─▸ ○ Add breaking-gate.sh, the soft warning text for the approve step
      └─▸ ○ Wire the capture and gate steps into deploy-public.json and the … →⚑
  ○ Add the --release mode to the j.breaking-change SKILL.md ◂─ S01_T02

Ready to take: Add the j.major-release…
Add detect-major.sh (ba… unlocked by E91_S01
Add list-epics.sh (comp… unlocked by Add detect-major.sh (ba… + E91_S01
Add release-check.sh (d… unlocked by Add detect-major.sh (ba… + E91_S02
```

**Arrows, references and the row order** (`E92_S10_T03`, user decision 2026-11-15: "lägg till och kör: jag skapar en
task som ritar om så att varje pil motsvarar ett verkligt beroende, och kör den nu", every arrow is a real dependency and
no in-scope dependency is invisible; source: rapport `E92_S08_T08-scope-view-arrows-imply-edges-that-do-not-exist`).
Before it, the arrow in front of a node only meant "has some incoming dependency" and was drawn after whatever node sat
to its left, so it could join two unconnected tasks, and an edge whose source sat on another row was not shown at all.

- **What an arrow means.** An arrow `▸` before a node is drawn only from its *drawn parent*: the first node, in band
  order (column, then slot), of the **same band** that sits in the depth column **directly to its left** and has a
  `dependency` edge to it in `structure.edges`. A folded group stands for its members (its edges are the union of
  theirs, section 20.5), so an arrow to or from a group is real when any member has that edge. A node with no drawn
  parent gets no arrow, only blank padding of the arrow width.
- **Row order.** The drawn parents form one forest per band, roots and children in band order. The horizontal rows are
  a depth-first walk of it: a node's first child continues its row (`───▸`); each further child opens a row below the
  subtree of the previous one and is joined to the parent by a fork, `─┬─▸` on the first child's row, ` ├─▸` / ` └─▸`
  on the later children's rows and ` │` on the rows in between (ASCII `-+->`, ` +->`, ` |`). Every node keeps its depth
  column. The vertical layout draws the same forest, one line per node indented by its depth in the tree (2 cells per
  level), `├─▸` / `└─▸` before a child and `│` on the lines between two siblings; a root starts at the band indent with
  no connector.
- **References.** Every other incoming `dependency` or `boundary` edge of a node (a second dependency, one in an
  earlier non-adjacent column, one in another story or outside the epic) is shown after its name as `◂─ <ids>`
  (ASCII `<- <ids>`), ids sorted and joined by `,`, each written relative to the node: `T03` for a task of its own
  story, `S01_T06` for another story of the epic (`S10` for a story id a task depends on), the full id outside the epic.
  A reference to a group names the members the node depends on. A story's own `depends_on` is not an edge of
  `structure.edges` (it only closes the padlock, section 20.0), so it gets no reference. In a horizontal band a column
  that carries a reference is widened by its widest reference, so the columns of the band stay aligned; in the vertical
  layout the title and then the reference are cut to the room left. The reference takes the arrow's colour (the gate,
  as the arrow it stands for).
- **The goal.** `───▸⚑` follows every node that has a `goal` edge. A task with one has no dependent in the epic, so it
  always ends its row; a folded group can have a goal edge and drawn children, and then gets a last branch ` └─▸⚑`.
  The old rule drew the goal arrow only after the last column of a row, which hid it after a node that happened to have
  a neighbour to its right (on the rapport's fixture: Hotel, Kilo and Juliet).
- **Glyphs.** `fork` (`┬` / `+`) and `back` (`◂` / `<`) were added to `charset.js`, both one cell in both tables.
- **Checked by** `tests/helpers/scope-arrow-walk.mjs`, which reads the arrows, references and goal arrows back out of the
  rendered rows and compares them with `structure.edges`: on the rapport's fixture (`tests/lib-progress-parity.test.mjs`),
  on generated bands with a folded group (`tests/lib-progress-overview-scope.test.mjs`) and on the `j.status` fixture of
  `tests/j-status-scope-view.bats`.

The `E92_S09` and `E92_S10` bands of `cli.js --color never scope E92` after the change (`E92_S09_T04` depends on `T02`,
drawn as the arrow, and on `T03`, shown as the reference; `E92_S10_T02` and `T03` both depend on `T01`, drawn as a fork):

```text
REDO: A TREE FOR EVERY EPIC WITH TASKS, ONE READY STYLE FOR EVERY STARTABL… 4/4
      ● Render the de…───▸● Draw every st…───▸● Show the new … ◂─ T03 ───▸⚑
      ● Compute an ep…

PADLOCK RULE FOR EVERY TASK STATE, AND NO 'GOAL REACHED' WHILE A STORY HAS… 1/3
      ● Closed padloc…─┬─▸◉ No 'Goal reac…───▸⚑
                       └─▸◉ Scope view ar…───▸⚑
```

Before it the `E92_S09` band read `● Render the de…───▸● Draw every st…───▸● Show the new …───▸⚑` over a lone
`● Compute an ep…`, so the edge `E92_S09_T03` → `E92_S09_T04` was invisible.

**The milestone line** (decision 2). The stops are the stories of the scoped epic in the order the payload lists them,
one stop per story, with the epic as the goal at the end (`⚑`, or `★` when every counted task is done) and a label under
each stop (the story title when it fits the segment, else its number, `S01`, ...; then `Goal`). A stop is the `stop` the
payload states: done `●`, in progress `◉`, failed `✕`, else `○`; a story with no counted task gets `⊘`. The current
milestone is a story whose stop is in progress: `◉`, its label in bold. Each story's segment is filled in proportion to
its done share, in a green 256-colour gradient along the line, and the rest is dashed grey. The message is chosen from the stated percent and the number of
unfinished stories exactly as `render-status-scope-view.sh` chose it (complete; last story; at least 80 %; at least 50 %;
above 0; else the start line), and "next" is that script's "Ready to take" selection. The track is dropped under 50
columns, or when it does not fit (width `min(cols, 64)`, at most 10 cells per story). No new rule was invented; the
Scrum Master's reading of the user's answer is recorded in the story and the user may still correct it.

**The narrow-terminal layout** (decision 1). `scope` takes `--layout horizontal|vertical|auto`, default `auto`; the design
width is 80 columns.

- `horizontal`: one text row per row of the band's drawn-parent forest (above) and one column per depth column. A column
  is 20 cells: a 4-cell arrow, the mark, a space and a 14-cell name; a longer title ends in `…` (ASCII `~`); a column that
  carries a reference is wider by the widest reference plus two spaces. A band row starts 6 cells in. So a band whose
  rows span three depth columns without references fits 80 columns (67 cells with the goal arrow) and one that spans
  four does not (87). Forced `horizontal` shrinks the name width, never below one cell, until every band fits: rows are never added,
  titles only get shorter (`scope E92_S08 --layout horizontal` at 80 printed `◉ Ex…───▸◉ No…───▸● No…...`).
- `vertical`: an indented tree of the same forest, one line per node, indented by its depth in the tree, `├─▸` / `└─▸`
  (ASCII `+->`) before a child, `│` between two siblings, the title and the reference cut to the room left.
- `auto`: a band is drawn vertical **only when its longest horizontal row, at the 14-cell name width, is wider than the
  terminal**; every other band stays horizontal; a reference counts in that width. In the `E91` output above the first
  band (67 cells) stays horizontal and the third (wider than 80 with its reference) is vertical at 80. `E92_S08` (nine
  depth columns) is vertical at 80.

The width is that of 30.3 (`--cols`, `COLUMNS`, the terminal, 80). `j.status` cannot pass `--layout` (30.7).

**The four decisions of `E92_S08_T01`**, as recorded in the story's "Decisions" section, and where they live in code:

1. Narrow layout: option 4, the hybrid by width with a flag, as above (`tree-text.js`, `scope` sub-command flag).
2. Milestone line: option 1, **interpreted** from the user's answer ("build on the same principle as is done now, only the
   design changes"), as above (`scope.js`).
3. Charset and colour defaults: option 1 with the user's amendment, two keys in the existing `dashboard-config.json`,
   precedence flag, environment variable, config key, default (30.3; `config.js`, `charset.js`, `color.js`, the
   descriptor file).
4. A user-run colour command: option 2, `jenga progress` (30.6; `lib/commands/progress.js`, `E92_S08_T10`).

### 30.6 `jenga progress` (`E92_S08_T10`)

`jenga progress <sub-command> [flags]` is the short way to see the views with colour in a real terminal. It is a thin
forwarder in `lib/commands/progress.js`, behind the `jenga` bin (`bin/jenga.js`), modelled on `jenga config`: it runs
`run()` of `lib/progress/cli.js` in-process with the same sub-commands and flags, and adds one thing, `--color always`
in front of the arguments unless the caller passed `--color` (as `--color x` or `--color=x`). Because that is a flag, it
outranks `JENGA_PROGRESS_COLOR` and `progress_color`: `progress_color: never` does not turn its colour off,
`jenga progress --color never ...` does. It makes no model call and uses no network; exit codes are those of `cli.js`.

```text
jenga progress overview              the board overview, in colour
jenga progress scope E92             the scope view of an epic (or a story id)
jenga progress bar --epic E92        one run-bar line
jenga progress --help                the usage of cli.js (30.2), unchanged
```

`jenga --help` lists it as `jenga progress  Show board progress in the terminal (colour on; see also: jenga progress
--help)`. Observed: `jenga progress bar --epic E92` into a pipe began with `ESC[32m` (colour on without a terminal, as
`always` means), `jenga progress --color=never scope E92_S09` printed plain text, and `jenga progress` with no
sub-command printed `cli.js: no command given` and the usage and exited 2. In a consumer project it runs as
`npx jenga progress ...`.

### 30.7 Wiring, the copy into the reply, and `--legacy` (`E92_S08_T06`, `E92_S08_T07`)

**`j.status`.** Step 1.5 of `skills/j-status/SKILL.md` runs `resolve-status-mode.sh mode <the user's arguments>` and,
for `overview` or `scope`, the same with `render` and `--charset utf8 --color never` in front of the user's arguments.
The resolver now routes:

| Mode | Arguments | Renderer |
|---|---|---|
| `overview` | none | `node lib/progress/cli.js overview` (the default) |
| `scope` | `<id>` (`--all` accepted, not forwarded) | `node lib/progress/cli.js scope <id>` (the default) |
| `legacy` | `--legacy`, or `--all` with no id | `render-status-bars.sh` (section 12.4) |
| `legacy-scope` | `--legacy <id>` | `render-status-scope.sh <id>` (section 18) |

Observed `plan` output: `node lib/progress/cli.js scope E92_S08 --charset utf8 --color never`, `node lib/progress/cli.js
overview` and `render-status-scope.sh E92`; `mode --all` printed `legacy`. `--charset` is accepted and forwarded to the
Node renderer only. When `node` is not on `PATH` or `cli.js` is missing, `render` runs the legacy renderer of the same
scope with one warning on stderr. `render-status-overview.sh` and `render-status-scope-view.sh` (section 25) stay on disk
but are **no longer routed** by anything, neither as the default nor as `--legacy`. `--layout` is not an argument of the
resolver (`mode E92 --layout vertical` exits 2, `unknown argument: --layout`), so `j.status` always draws the scope view
with `auto`; filed as a rapport (30.10).

**`run-progress.sh` and `story-finished.sh`.** In story scope (`--scope story --task <ids>`) the after-task lines are
drawn by **one** `node lib/progress/cli.js ... after-task --story <S1,S2,...>` call for every distinct story, and the
after-story line by `story-finished.sh` with `cli.js after-story --story <id>`; deciding whether a story just finished,
and the ledger, stay in bash (section 24.1, 24.3). `--legacy`, or `JENGA_PROGRESS_RENDERER=legacy` in the environment,
draws with `scripts/render-progress-bar.sh` and `scripts/render-story-bar.sh` byte for byte as before; any other value of
the variable means the Node default. When the Node drawing is not possible (no `node`, no `cli.js`, a non-zero exit or
no output) one `... (legacy drawing used, run unaffected)` warning is written and the legacy renderers draw instead.
`--charset` goes to Node only; `--cols` and `--color` go to both. `--scope run` and `--resolve-scope` (compatibility
only, section 23) always draw with the legacy renderer. Node's output is captured so that it can fall back, so Node sees
a pipe and `auto` never colours it.

**The call sites.** `skills/j-do/SKILL.md` (4.1.3), `skills/j-dooo/SKILL.md` (1.1), `skills/jenga/SKILL.md` (Phase 0.95,
and its bundle and wave steps) and `skills/j-break/SKILL.md` ("Progress lines") run `run-progress.sh --scope story --task
<ids> --after-story --charset utf8 --color never`. Which glyphs, colour and width, and what to print, stay in the
renderer; the `SKILL.md` files say only when to call it.

**Why the copy into the reply, as a fenced code block.** The desktop app folds tool output into a collapsed tool-call row,
so a rendering left there is never seen. Each of those `SKILL.md` files therefore tells the agent to copy the stdout into
its reply as a fenced code block, byte for byte: the block keeps the monospace alignment of the bands and the bar, and
the agent adds, counts or rewords nothing. The rule sits in one short block per file (`j-status` "Show the rendering in
the reply", `j-break` "Progress lines", which the other three point at). The copy is run with `--charset utf8 --color
never`: ANSI colour cannot render in chat markdown, and UTF-8 must be explicit because the Bash tool has `LANG=""`.
**Colour is for a real terminal and needs `--color always` there** (or `jenga progress`, 30.6), because the default
`auto` is off for a pipe and the callers capture the output.

### 30.8 Node version floor, banned APIs and the packaging boundary

- **Floor.** `package.json` `engines.node` is `>=14.13.1`, and `E92_S08` did not raise it. The story bans
  `String.prototype.replaceAll`, `Array.prototype.at`, `??=` (and the other logical assignments), `Object.hasOwn`,
  `structuredClone`, `node:test` and `fetch`; `import` of `node:` built-ins is allowed from 14.13.1.
  `tests/progress-shared-structure.bats` and `tests/lib-progress-core.test.mjs` scan `lib/progress/` for them, and
  `tests/progress-node14-guard.bats` scans `lib/commands/progress.js` and the story's Node test files too, with a wider
  list (`rmSync`/`rm`, `cpSync`/`cp`, `randomUUID`, `findLast`, `toSorted`, `new AbortController`, the `*/promises`
  modules), and imports every module and runs `cli.js info` on a real Node 14.13.1 binary when one is available
  (`JENGA_NODE14_BIN`, or nvm's `v14.13.1`), skipping that case otherwise.
- **Packaging boundary.** `package.json` `files` ships `project/app/ui/dist` and `project/app/ui/scripts`, **not**
  `project/app/ui/src`, so a terminal renderer cannot import the dashboard's model from `src` in a consumer install. That
  is why `E92_S08_T02` moved the graph structure to `lib/progress/dependency-structure.js` (shipped through `lib/`) and the
  dashboard imports it from there; the Vite dev server allows the path in `server.fs.allow`
  (`project/app/ui/vite.config.js`), and the built `dist` bundles it.
- **Tests.** The Node tests are `tests/lib-progress-core.test.mjs`, `lib-progress-bar.test.mjs`,
  `lib-progress-overview-scope.test.mjs` and `lib-progress-parity.test.mjs`, each run by a bats wrapper of the same name
  (`.bats`), because `j.test` discovers bats suites, not bare `.test.mjs` files. The bats files that lock the `--legacy`
  output (`tests/render-progress-bar.bats`, `tests/j-status-bars.bats`, `tests/j-status-scope.bats`, ...) stay as they
  were; `tests/progress-command.bats` covers `jenga progress`.

### 30.9 What was observed, and what was not

**Observed** by `E92_S08_T09` (a background agent, through the Bash tool, `LANG=` and a pipe, Node v24.18.0): every
command and every output block of sections 30.1 to 30.8; the widest line at 80 columns (80 cells); the ANSI bytes with
`--color always` and `jenga progress` (read with `od -c`) and their absence with `--color never`; the Swedish labels
(`--lang sv bar --epic E61` printed `▰▰▰▱▱▱▱▱▱▱⚑ 0/7 · 2 röd`).

**Not observed:**

- **The real-session reply check** of the story's Definition of Done: that `j.status`, a `j.do` after-task line and a
  `j.jenga` wave line, drawn by the Node renderer in a real session, appear in the reply as a fenced code block in UTF-8.
  This task cannot look at a reply in the desktop app. The blocks in this section are the same bytes the renderer prints,
  copied from the Bash tool, but how a reply shows them was not looked at.
- **The real-terminal colour check**: that `--color always` output was looked at once in a real terminal and compared
  with the prototype and the design image. This task has no terminal to look at. Only the escape sequences were checked
  (which SGR codes are written, and that they are closed), not how they look.
- **A run on Node 14.13.1.** No such binary was used here; the floor rests on the scans and the opt-in case of
  `tests/progress-node14-guard.bats` (30.8).

Both Definition-of-Done checks remain for a person to do in a real session and a real terminal.

### 30.10 Distribution, manifest and mirror verification (`E92_S08_T09`)

All four checks were read-only and ran in the task's own worktree; nothing was fixed.

1. **`npm pack --dry-run`** (run as `npm pack --dry-run --ignore-scripts --json`: the `prepack` script builds the
   dashboard UI and would write `project/app/ui/dist`, which a read-only check must not do; the file list does not depend
   on it apart from `dist`). Result: 660 files, version 5.0.0. All 13 files of `lib/progress/` are listed, and so is every
   non-test file outside `project/` that an `E92_S08` commit changed: `bin/jenga.js`, `lib/commands/progress.js`,
   `lib/config/descriptors.js`, `lib/config/store.js`, `templates/config-descriptor-schema.json`,
   `templates/config-descriptors/dashboard-config.json`, `skills/j-status/scripts/resolve-status-mode.sh`,
   `skills/j-break/scripts/run-progress.sh`, `skills/j-break/scripts/story-finished.sh`,
   `skills/j-status/assets/output_format.md` and the five `SKILL.md` files (`j-status`, `j-do`, `j-dooo`, `jenga`,
   `j-break`); also the scripts the renderer runs (`scripts/board-progress.sh`, `scripts/progress-labels-json.sh`,
   `scripts/lib/progress-labels.sh`, `scripts/resolve-root.sh`) and `lib/config/paths.js`, which `cli.js` imports. No
   path under `project/app/ui/src` and none under `tests/` is listed. No manifest change was needed: `lib/`, `bin/`,
   `scripts/`, `skills/` and `templates/` are already in `files`.
2. **Manifests: no entry needed** (so there is nothing to test). `lib/postinstall-manifest.js` records only the files the
   consumer postinstall mirrors from `skills/` and `agents/` into `.claude/` and `.agents/`; `lib/` stays in
   `node_modules` and is not recorded (`scripts/postinstall.js` header). `lib/legacy-shipped-paths.json` is the seed list
   of old shipped `agents/` and `skills/` paths for delete reconciliation; `lib/progress/` is new, so it is not legacy.
   `lib/skill-allow-list.json` is a list of 64 skill names with no command patterns; no skill was added, and the skills
   reach Node through their existing scripts (`resolve-status-mode.sh`, `run-progress.sh`).
3. **`.publicignore` and the mirror.** `.publicignore` has no pattern that excludes `lib/` or `lib/progress/` (the only
   `lib/` text in it is a comment naming `lib/skill-allow-list.json`). **`mirror.sh --dry-run` could not complete:** it
   stopped with exit 1 before its preview because the public `origin/main` (`5eb42b1`, "chore(publish): record v5.1.0
   stage_tested and approved ledger entries") has moved past the local `last-mirror-sync` marker (`68c9d00`), and a fresh
   clone has no marker at all. `--force` was not used: its path pushes a rescue tag to the public remote. Filed as a
   rapport. To still answer the question, `mirror.sh`'s own functions `compute_full_ship_set`, `compute_ship_list` and
   `check_never_public_refs_invariant` were extracted verbatim and run against a scratch copy of the scratch clone (so
   the shared `.mirror-worktrees/public` was not touched). The full ship set has 2677 files and contains all 13 files of
   `lib/progress/` and `lib/commands/progress.js`; the public tip contains no file under `lib/progress/` yet, so the next
   mirror adds them. **The shared-never-public reference guard passed**: "no failing reference to a never-public skill
   (95 non-failing mention(s) logged, 45 path hit(s) exempted ...) — OK", exit 0.
4. **`.claude/` and `.agents/`** were not edited by hand by this task. They are generated by `j.self-sync`, which must be
   run to bring this story's root changes into them, and **was not run** by this task. At `e1b14b10` the mirrored copies
   of `resolve-status-mode.sh`, `run-progress.sh` and the `j-status`, `j-do` and `jenga` `SKILL.md` files differ from the
   root files, and so do 2 of the 14 mirrored Node files (`lib/progress/dependency-structure.js` and `scope.js`, the
   `E92_S09` changes).

### 30.11 Every state has its own glyph, colour or not (`E92_S11_T01`)

User decision of 2026-11-15 (story `E92_S11`, decision 1), answering "2" to: "in the bar, in-progress gets ▒ (ASCII =)
and failed ✕ (ASCII x); in the terminal tree, in-progress gets a half dot ◐ (ASCII %), as in the dashboard."

Until then the Node renderers told some states apart by colour alone: `paintCells()` in `lib/progress/bar.js` drew done,
in-progress and failed cells all as `▰` (ASCII `#`), and `STATE_VIEW` in `lib/progress/tree-text.js` gave an in-progress
task the ready mark `◉`. With colour off, as in the copy into a chat reply (section 30.7), a story with 2 of 3 tasks done
and 1 in progress looked full. **In the Node renderers a state is no longer told apart by colour alone:** every state has
its own glyph in both charsets, and the colours are unchanged.

**Run-bar cells** (`paintCells()`, used by the run bar, the after-task and after-story lines and the `j.status` overview and
scope views), in this order:

| State | `utf8` | `ascii` | `charset.js` key | Colour |
|---|---|---|---|---|
| done | `▰` | `#` | `runFull` | green |
| in progress | `▒` | `=` | `runInProgress` | yellow |
| failed | `✕` | `x` | `cross` | red |
| pending | `▱` | `-` | `runEmpty` | grey |

**Tree marks** (`STATE_VIEW`, the bands of the scope view):

| State | `utf8` | `ascii` | `charset.js` key | Colour |
|---|---|---|---|---|
| done | `●` | `*` | `done` | green |
| ready | `◉` | `@` | `ready` | cyan |
| in progress | `◐` | `%` | `inProgress` | yellow |
| failed | `✕` | `x` | `cross` | red |
| rejected | `⊘` | `x` | `rejected` | muted blue-grey |
| locked or pending | `○` | `o` | `locked` | grey |
| done, but a dependency is not done (`E92_S11_T02`, 30.12) | `?` | `?` | `unfinished` | yellow (in progress) |

- `runInProgress` is its own key, not `hatch`: both are `▒` in `utf8`, but `hatch` is `:` in `ascii` and the user chose `=`
  for the in-progress cell. Every new glyph is one code point and one terminal cell (the width pin in
  `tests/lib-progress-core.test.mjs` covers every key of both tables) and every `ascii` glyph is a byte below `0x80`.
- In `ascii`, failed and rejected tree marks are both `x`, as before `E92_S11_T01`; a rejected task is never a bar cell.
- Counting is unchanged: the renderer still counts nothing, and the cell allocation is the same.
- Example, `--color never`, 3 done, 1 in progress, 1 failed, 1 pending at 6 cells: `▰▰▰▒✕▱` in `utf8`, `###=x-` in `ascii`.
- Not changed: the `--legacy` bash renderers (sections 17, 18, 23 to 25) and the dashboard UI, which already had a distinct
  mark per state. The overview's per-epic marker (`◉1`, `✕2`) and the milestone line's in-progress stop (`◉`) keep their
  glyphs: in those places `◉` is the only in-progress mark and no ready mark is drawn next to it.

### 30.12 A done task whose dependency is not done: the `?` mark and the `j.reconcile` finding (`E92_S11_T02`)

User decision of 2026-11-15 (story `E92_S11`, decision 2): "En ticket kan inte både vara genomförd och samtidigt vara
beroende av en icke genomförd ticket. Om ticketen är genomförd före dess är det ett defacto bevis för att den inte var
beroende av den andra ticketen." (A ticket cannot both be done and depend on a ticket that is not done; if it was done
first, that is proof it did not depend on it.) The user chose to flag the contradiction, with "ett frågetecken i samma gula
färg som pågående ärenden där plustecknet brukar ligga för ärenden som är redo" (a question mark in the in-progress yellow,
where a ready task has its plus).

**The script states it.** `board-progress.sh --graph` gives every task `unfinished_deps` (section 13.2): for a task in the
done bucket, the effective dependencies (own `depends_on`, then the story's, each once) that are not satisfied, `[]`
otherwise. Renderers count nothing and decide nothing: they read the key. A payload without it (an older script or
snapshot) renders exactly as before, because the shared structure (`lib/progress/dependency-structure.js`) adds
`unfinishedDeps` to a task or a folded group only when the stated list is not empty.

**Nothing else changes.** The task keeps `state: done`, stays in the done bucket and counts as done in every bar, percent
and goal. The padlock rule of `E92_S10_T01` is unchanged: a done task keeps the open padlock. The flag is a separate mark,
not a gate.

**How it is shown.**

| Where | Mark | Words |
|---|---|---|
| Dashboard tree (`DependencyTree.jsx`) | `?` in `--color-progress-in-progress` at the card's mark position, in place of the done tick (`data-mark="unfinished"`, class `dt-mark-q`) | a `<title>` tooltip on the `?`, the card's `aria-label` and the hover tooltip name the dependency |
| Terminal tree (`lib/progress/tree-text.js`) | `?` (glyph key `unfinished`, `?` in `utf8` and `ascii`) in the in-progress colour, in place of `●`; the name keeps the done style | one line per flagged task after the "unlocked by" lines: `? <task>: <words>` |

The words are two labels of `scripts/lib/progress-labels.sh` (and the English fallbacks in `DependencyTree.jsx`):

| Key | en | sv |
|---|---|---|
| `dep_unfinished` | `Done although dependency %s is not done - check the dependency` | `Klar trots att beroendet %s inte är klart - kontrollera beroendet` |
| `dep_unfinished_more` | `Done although dependency %s and %d more are not done - check the dependencies` | `Klar trots att beroendet %s och %d till inte är klara - kontrollera beroendena` |

With several unfinished dependencies the words name the first (own `depends_on` first, then the story's) and a count of
the others, the same choice as the failed-story goal line (`goal_failed_more`). They use ` - ` rather than an en dash, as
`goal_failed` does, so `--charset ascii` keeps them readable. The state is not carried by colour alone: the `?` is the cue
without colour, and the words say it.

Terminal sample (`cli.js --charset utf8 --color never scope E01 --layout vertical`, the fixture of
`tests/lib-progress-overview-scope.test.mjs` "E92_S11_T02"):

```text
FIRST 2/3
  ● Plan
    └─▸ ✕ Build it
      └─▸ ? Write docs →⚑

SECOND 1/1
  ? Ship it ◂─ S01_T02 →⚑

Nothing is ready to take right now
? Write docs: Done although dependency E01_S01_T02 is not done - check the dependency
? Ship it: Done although dependency E01_S01_T02 and 1 more are not done - check the dependencies
```

**`j.reconcile` reports it.** `skills/j-reconcile/scripts/detect-done-before-dependency.sh [--within <id>] [--root <dir>]`
reads `--graph`, keeps the tasks whose `unfinished_deps` is not empty, names each dependency with its level and status
(one `--ids ... --items` call) and prints `{"count": N, "findings": [...]}`. `j.reconcile` lists the findings under "DONE
BEFORE ITS DEPENDENCY" and offers to inspect the dependency. It is report-only: no status, `depends_on` or file is changed,
because which side is wrong is the user's call. With no flagged task it reports nothing new.

**Observed on the real board, 2026-11-15** (`detect-done-before-dependency.sh` on this repository): 8 findings, all through
a STORY dependency (none through a task's own `depends_on`): `E51_S05_T01`..`T03` (`Merged`, story `E51_S04` is
`Pending`), `E91_S04_T01` (`Passed`, `E91_S03` is `Pending`) and `E92_S09_T01`..`T04` (`Merged`, `E92_S08` is `Failed`). The
story's count of 0 cases on 2026-11-15 looked at the tasks' own dependencies only.
