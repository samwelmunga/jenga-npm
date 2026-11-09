# Per-task token usage (`scripts/task-usage.sh`)

Epic `E76`, story `E76_S01`. `scripts/task-usage.sh` reports how many tokens each board task consumed, read after the
fact from Claude Code's session transcripts. The purpose is **budgeting**: knowing what a task of a given size costs
to implement. It reports token counts only. There is no pricing table and no dollar figure anywhere in the output.

This file is internal documentation (`project/documentation/`). The script, its tests and this file are private and
blocklisted in `.publicignore`; every shipping file that calls the script treats "script not present" as a silent
no-op (E76 decision 6).

## Method

**Where the data comes from.** Claude Code writes one JSON-lines transcript per session and one per subagent:

```
~/.claude/projects/<project-slug>/<session>.jsonl                          main session  (kind "session")
~/.claude/projects/<project-slug>/<session>/subagents/agent-<id>.jsonl     a subagent    (kind "subagent")
~/.claude/projects/<project-slug>/<session>/subagents/agent-<id>.meta.json its sidecar
```

The slug is the project path with every character other than a letter, digit or `-` replaced by `-`. A session
started inside a worktree has its **own** slug directory (`<slug>--claude-worktrees-<name>`), so the script reads the
main slug and every sibling named exactly `<slug>--claude-worktrees-*`, and nothing that merely shares a prefix. The
transcript's `cwd` field is never used: it names the main repository, not the worktree, so it cannot attribute
anything.

**Mapping a transcript to a board ID** (subagents only). Three sources are tried in order and the first one that
contains any board ID decides:

1. the meta `name` (`E72_S01_T05`, `E72_S05_T02-tester`, `retest-E85_S01_T06`);
2. the meta `description` (`Implement E72_S01_T05 ...`);
3. the first non-blank line of the first user prompt, as a last resort.

An ID is found anywhere in the text, so a role suffix or prefix (`-tester`, `-tester-r2`, `retest-`) still maps to its
task, but it must stand alone (`E72_S05_T02x` is not an ID). Within the deciding source the most specific ID wins
(task over story over epic). A name such as `verify-group5` carries no ID and falls through to the next source; when
none yields an ID the transcript is **unmapped**. An ID is never guessed. The full rules, the known limits and the
re-verified layout facts are in the header of `scripts/task-usage.sh`.

**Counting usage: last line per `requestId`.** Every assistant line carries `message.usage` with
`input_tokens`, `output_tokens`, `cache_creation_input_tokens` and `cache_read_input_tokens`. One API call (one
`requestId`) is written on **several lines** while it streams, with a growing `output_tokens`; the first line can
understate the call badly (1,243 against 6,893 in the brainstorm's test). The script therefore counts each
`requestId` once, from its **last line in file order**. A line with no `requestId` is its own unit (keyed by its
`uuid`, else its line number) and is counted once. The optional `cache_creation` 1h/5m object is a breakdown *of*
`cache_creation_input_tokens`, so it is never added on top. The transcript is read in a single streaming `jq` pass, so
memory follows the number of calls, not the file size.

**One total per task.** All transcripts that map to the same task ID, including a Tester's and any rework, are summed
into one record. There is no first-attempt/retry split.

## Running it

```
scripts/task-usage.sh --report [--task <id>]... [--story <id>]... [--stories <id>]... [--allocate]
                       [--board-stories-dir <dir>] [--projects-dir <dir>] [--project-dir <path>]
scripts/task-usage.sh --check-layout [--projects-dir <dir>] [--project-dir <path>]
```

`--projects-dir` defaults to `$JENGA_PROJECTS_DIR`, else `~/.claude/projects`; `--project-dir` defaults to the main
repository of the current directory. The two lower-level modes remain available: `--list-transcripts` (stage 1, the
mapping) and `--usage <transcript.jsonl>` (stage 2, one transcript's four sums). Exit codes are listed under
[Failing loudly](#failing-loudly-drift-protection): `0` success, `2` usage error, `3` environment error, `4` to `8` the
loud failures of `--report` and `--check-layout`.

## Output contract (`--report`, `schema_version` 1)

stdout is a single JSON document (`jq .` always succeeds); every human-readable message goes to stderr, including one
line per warning.

```
{
  "schema_version": 1,
  "generated_at": "2026-10-26T09:00:00Z",
  "tasks":    { "<task id>": { story_id, epic_id, input, output, cache_write, cache_read,
                               usage_total_tokens, usage_transcripts, transcripts[] } },
  "overhead": [ { kind, agent_type, id, level, input, output, cache_write, cache_read, path } ],
  "unmapped": [ { kind, agent_type, name, reason, input, output, cache_write, cache_read, path } ],
  "warnings": [ { code, id | path, message } ]
}
```

With `--allocate` or `--stories` two more keys are added, `stories` and `unallocated_overhead`; see
[The `stories` section](#the-stories-section---allocate---stories). `schema_version` stays `1`: the keys are additive
and **opt-in**, so a run without either option prints exactly the keys above (two existing tests assert that exact key
set, and consumers of the original shape see no change).

- **`tasks`** is keyed by task ID. A record sums every transcript that resolved to that task. `usage_total_tokens` is
  `input + output + cache_write + cache_read` and nothing else. `usage_transcripts` is the number of transcripts
  summed (a task with a developer run, a tester run and a rework run has 3). `transcripts` lists their paths.
  `story_id` and `epic_id` are derived from the task ID.
- **`overhead`** holds transcripts that belong to no single task: every main-session transcript (`kind: "session"`,
  `agent_type: null`, `id: null`, `level: "none"`) and every subagent that resolved only to a story or epic ID, such
  as a Scrum Master named `E72_S01` (`kind: "subagent"`, `id: "E72_S01"`, `level: "story"`). The ID and level are
  what the mapper resolved. **`overhead` itself is never allocated to a task and is never altered**; with
  `--allocate` or `--stories` the same entries are also split across stories by the rule in
  [Allocating overhead to stories](#allocating-overhead-to-stories) and reported in the `stories` and
  `unallocated_overhead` sections (implemented by `E76_S03_T03`).
- **`unmapped`** holds subagents that resolved to **no** board ID at all (for example `verify-group5`), with the
  mapper's `reason`. They are reported, never dropped and never guessed into a task. Every readable transcript is in
  exactly one of `tasks`, `overhead` or `unmapped`, so no tokens are counted twice. A consumer that wants total
  non-task consumption adds `overhead` and `unmapped`.
- **`warnings`** are machine-readable: `no-transcripts-for-task` and `no-transcripts-for-story` (a requested ID that
  matched nothing), `transcript-unreadable` (a transcript whose usage could not be read; it is excluded from every
  sum rather than counted as zero) and `transcript-without-usage` (a transcript with no assistant line at all; also
  excluded from every sum, because it reports no usage, which is not the same as reporting zero).

**Filters.** `--task <id>` and `--story <id>` filter the `tasks` map only (both repeatable; a task must satisfy every
option that is given). `overhead`, `unmapped` and `warnings` are always complete, and so is the overhead allocation
(it always reads the unfiltered task set). An ID that has no transcripts is
reported in `warnings`, never as a record of zeros, and when every requested ID is absent the run exits `8` instead
(see below). A task kept by a filter keeps its full numbers.

### The `stories` section (`--allocate`, `--stories`)

`--allocate` adds the two sections for every story. `--stories <id>` (repeatable, a story ID such as `E72_S01`) adds
them narrowed to those stories. `--stories` narrows **only** the `stories` section: the allocation reads the unfiltered
task set and the complete `overhead` list, so no number in it depends on `--task`, `--story` or `--stories`. Both
options are `--report`-only (otherwise exit `2`), a malformed `--stories` ID is exit `2`, and unlike `--story` an ID
that has nothing to report is not a warning and does not count towards the exit `8` rule (see below): it is returned
as a story that is not measured.

```
"stories": { "<story id>": { epic_id, measured, weight,
                              board_tasks, measured_tasks, unmeasured_tasks,
                              tasks, allocated_overhead, total } },
"unallocated_overhead": [ { path, id, level, input, output, cache_write, cache_read, reason } ]
```

- **`stories`** is keyed by story ID in **numeric** order (`E9_S10` before `E10_S01`). Without `--stories` it lists
  every story that has a measured task or was charged an overhead entry directly; with `--stories` exactly the
  requested stories. `tasks`, `allocated_overhead` and `total` are each `{input, output, cache_write, cache_read,
  total_tokens}` where `total_tokens` is the sum of the four.
  - `tasks` is the sum over the story's measured tasks; `allocated_overhead` is the sum of its shares over all overhead
    entries; **`total` is their field-by-field sum**, and the two parts stay as separate numbers beside it.
  - `weight` is the story weight `W_S` of the rule (`input + output + cache_write` over its tasks).
  - `measured_tasks` are the story's tasks that have transcripts. `board_tasks` is the `tasks:` list of the story's file
    under `project/board/stories/` (the source `j.close-story` reads) and `unmeasured_tasks` is `board_tasks` minus
    `measured_tasks`. The sums and the weight come from the transcripts, never from the board: the roster only names
    what has no numbers. Both are `null` when no story file was found (or the directory does not exist); that is not an
    error and adds no warning. The directory is `--board-stories-dir`, else `$JENGA_BOARD_STORIES_DIR`, else
    `<project dir>/project/board/stories`.
  - **A story with no measured task is not given invented numbers:** `measured` is `false` and `weight`, `tasks` and
    `total` are `null` (not zeros). It can still have a real `allocated_overhead`, because an entry named for that story
    (level `story`) is charged to it in full whether or not it has tasks (decision D2); a requested story with no tasks
    and no direct charge shows an all-zero `allocated_overhead`, meaning nothing was allocated to it.
- **`unallocated_overhead`** holds the amounts the rule cannot place: one record per overhead entry (its `path`, `id`,
  `level`, the four amounts and `reason`, `no-candidate-story` or `zero-weight`), sorted by path, and none for an entry
  whose four amounts are all zero. These tokens belong to no story and no task.
- **Invariant.** For each of the four fields, the sum of `allocated_overhead` over **all** stories plus the sum of
  `unallocated_overhead` equals the sum of that field over `overhead`. (With `--stories` only the requested stories are
  printed, so the sum is over the printed ones only; run with `--allocate` to check the full identity.)
- **Arithmetic.** Shares are computed with exact integer arithmetic (`T x W_S` can exceed 2^53, which jq's floats cannot
  hold). The script fails loudly rather than rounding when a field total reaches 2^53 or a weight sum reaches 1e14,
  neither of which real data approaches (weights are around 1e9).

## Failing loudly (drift protection)

Claude Code owns the transcript format and may change it. Without protection a changed layout finds nothing and the
report is an empty object that reads as "zero tokens". `--report` and `--check-layout` therefore check the layout
before they print anything, and each failure has its own exit code. Every failure writes a message on stderr that
names the missing thing and the path that was searched, and `--report` writes **nothing** on stdout (it builds the
whole document in a temporary file and prints it last), so a failing run never leaves half a JSON document.

| Code | Check | Fails when |
|---|---|---|
| `0` | | success |
| `2` | | usage error (unknown option, no or two modes, malformed `--task`/`--story`/`--stories` ID, any of those or `--allocate` or `--board-stories-dir` without `--report`) |
| `3` | | environment error (`jq` or `scripts/lib/board-ids.sh` missing; for `--list-transcripts` also an absent projects directory; for `--usage` an unreadable file) |
| `4` | 1 | the transcript root (projects directory) does not exist, or holds no directory for this project's slug |
| `5` | 2 | no `subagents/` directory, or no `agent-*.jsonl`, anywhere under the project's slug directories |
| `6` | 3 | a subagent transcript has no sibling `.meta.json`, the meta is not a parseable JSON object, or it lacks a field the mapper reads (`agentType`, and `name` or `description`) |
| `7` | 4 | a transcript mapped to a **task** has assistant lines but none carries a `message.usage` object, or a usage object lacks one of the four numeric fields (`input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`) |
| `8` | | every ID requested with `--task`/`--story` has no transcripts (see zero versus absent) |

The checks run in the order 1 to 4 and the first failing check decides the code. `--list-transcripts` and `--usage`
are lenient diagnostic primitives and do not apply them: a transcript without a sidecar is a record with a `reason`,
one without usage is `usage_lines: 0`, and a missing projects directory stays exit `3` there. Check 4 reads only
task-mapped transcripts: an unmapped or overhead transcript with no usage cannot corrupt a task's number. A transcript
whose usage objects are all zero passes (the API-error placeholder line is such a case); a final line cut off while the
session was still writing is counted as unreadable, never as a missing field.

**Zero versus absent.** "No transcripts for this task" is never printed as a record of zeros. With `--task`/`--story`,
when **every** requested ID has no transcripts the run exits `8`, with a message and no stdout. When at least one
requested ID matches (a bulk run, for example `--task A --task B` where only `A` has transcripts) the absent IDs appear
under `warnings` and are absent from `tasks`. Zeros are printed only for a transcript that genuinely reports zero
usage; a transcript with no assistant line at all reports no usage, so it is excluded with a
`transcript-without-usage` warning.

### `--check-layout`

Runs checks 1 to 4 over all discovered transcripts **without aggregating** (nothing is summed and no token number is
printed), for the smoke test and any future health check. It writes a short human verdict on stderr and exactly one
line of JSON on stdout, and exits with the same codes as `--report`: `0` only when all four checks pass. Checks 1 and
2 failing make 3 and 4 meaningless (`skipped`); otherwise every check is evaluated and every failure is listed.

```
{"schema_version":1,"ok":false,"exit_code":6,"projects_dir":"...","project_slug":"...","transcripts":12,
 "checks":[{"check":1,"name":"transcript-root","status":"ok","message":"...","count":2,"details":[]},
           {"check":2,"name":"subagent-transcripts","status":"ok", ...},
           {"check":3,"name":"meta","status":"fail","message":"1 of 8 ...","count":1,"details":["<meta path>: no sibling .meta.json"]},
           {"check":4,"name":"usage","status":"ok", ...}]}
```

`status` is `ok`, `fail` or `skipped`; `details` holds the first ten problem lines (a path and the reason). Against this
machine's real transcripts (2026-11-06: 1,158 transcripts, 835 of them task-mapped) it passes, and a full `--report`
over them still succeeds and warns about the 7 transcripts that have no assistant line.

## The four fields, and why cache reads dominate

| Field | Source (`message.usage`) | What it is |
|---|---|---|
| `input` | `input_tokens` | Fresh input: prompt tokens that were not served from, or written to, the cache |
| `output` | `output_tokens` | Tokens the model generated, including thinking (see approximations) |
| `cache_write` | `cache_creation_input_tokens` | Prompt tokens written to the cache so later calls can reuse them |
| `cache_read` | `cache_read_input_tokens` | Prompt tokens served from the cache |

An agent session re-sends its whole growing context on every tool call. After the first call almost all of that
context is a cached prefix, so each call adds a small amount of fresh input and a small amount of output but reads
the entire prefix again. Cache reads therefore **dominate the volume**: a sampled developer run showed roughly 2.3M
cache-read tokens against roughly 1k fresh input and 0.4k output, and on this machine task `E72_S01_T05` (two
transcripts) summed to 130 fresh input, 23,214 output, 958,271 cache write and 4,149,174 cache read, a total of
5,130,789. A single number would hide what it is made of, which is why the four are reported separately and the total is
only their sum. The four kinds are not equally expensive, so the total is a size measure for budgeting, not a bill.

<!-- BEGIN E76_S02_T03: persisting totals (--persist). Self-contained section; keep edits to it inside the markers. -->
## Persisting totals (`--persist`)

Claude Code deletes old transcripts, which would erase a task's numbers. `scripts/task-usage.sh --persist` copies each
measured task's totals into the task's own board file (`project/board/tasks/<id>_*.md`, found through
`scripts/resolve-root.sh`), so they outlive the transcripts.

```
scripts/task-usage.sh --persist [--task <id>]... [--story <id>]... [--projects-dir <dir>] [--project-dir <path>]
```

`--persist` is a mode of its own. It measures exactly like `--report` (same layout checks, same exit codes `4` to `8`,
same `--task` / `--story` filters) and then writes. stdout is one JSON object,
`{"schema_version":1,"results":[{"id","status","message","file"}]}`, where `status` is `persisted`, `updated`,
`unchanged`, `kept-stored`, `not-measured`, `skipped` or `failed`; stderr has one line per notable result and a count
line. **Nothing is written unless `--persist` is passed**: `--report`, `--check-layout`, `--list-transcripts` and
`--usage` never write to the board (like every mode they keep working files in a private temporary directory that is
removed on exit).

### What is written, and how

The task fields defined in `templates/SCRUM_BOARD_SCHEMA.md` ("Usage fields on tasks"): `usage_input_tokens`,
`usage_output_tokens`, `usage_cache_write_tokens`, `usage_cache_read_tokens`, `usage_total_tokens` (the sum of those
four), `usage_transcripts`, `usage_measured_on` (UTC date) and, only as described below, `usage_possibly_incomplete`.
They are never hand-edited. For each task one critical section runs under `scripts/with-lock.sh` on the task file:
read the stored fields, decide, write every field through `skills/j-close-story/scripts/update-task-frontmatter.sh` to a
temporary copy, then swap the copy in atomically (the file mode is kept). If the lock cannot be acquired within
`with-lock.sh`'s timeout (`WITH_LOCK_TIMEOUT_SECONDS`, default 30 s) that task's write is **skipped**, reported on
stderr, counted in the exit code, and the lock is never bypassed. A file written this way still passes
`scripts/validate-board.sh`.

### Decision per task

| Situation | Result |
|---|---|
| Nothing persisted yet | Numbers and `usage_measured_on` are written (`persisted`) |
| Recomputed equals persisted (the four sums and the transcript count) | **Nothing is written**, so the file has no diff and `usage_measured_on` keeps its date (`unchanged`) |
| Rework: recomputed is at or above persisted everywhere and differs | Numbers, `usage_transcripts` and `usage_measured_on` are rewritten upward (`updated`) |
| Recomputed is **below** persisted in any sum, or finds fewer transcripts than `usage_transcripts` | The persisted numbers are **kept**; `usage_possibly_incomplete: true` is added if absent; stderr says so (`kept-stored`). `usage_measured_on` does not move, no number changed |
| No transcripts for the task, or any transcript of it could not be read | **Nothing is written**, and values persisted earlier are never overwritten or cleared. stderr says "not measured ... possibly pruned", never zero (`not-measured`); an unreadable transcript is a `failed` result, because a sum over only some of a task's transcripts must not pass for its total. An unreadable transcript is attributed to its task from its sidecar `.meta.json`; one whose sidecar names no task cannot be attributed, and only produces the `transcript-unreadable` warning on stderr |
| Transcripts for an ID with no board file | `skipped`, nothing written |

`usage_possibly_incomplete` is the literal `true`, never `false`, and `--persist` **never clears** it: a later
run that finds more transcripts cannot show that the earlier gap closed. A task is only reported as "not measured" when
it was asked for (`--task`, or a task of a `--story`) or already carries persisted usage; a bare `--persist` stays quiet
about the many board tasks that never had transcripts.

### Exit codes added by `--persist`

| Code | Meaning |
|---|---|
| `0` | every task was persisted, unchanged, kept, skipped or not measured; none failed |
| `8` | every ID requested with `--task`/`--story` has no transcripts: not measured / possibly pruned, nothing written |
| `9` | at least one task could not be persisted: the lock was not acquired (write skipped), the write failed, a transcript of the task was unreadable, a stored usage value is not a plain integer, or two board files match the ID. The other tasks are still persisted, and the failing ones are in the summary and on stderr |

`4` to `7` are the layout failures of `--report`; they stop `--persist` before it writes anything.

### Trigger points (the user's decision, 2026-10-15)

Persist at `j.close-story` time, computed once in one pass at that trigger, and in addition at the end of every skill
that drives board tasks in a loop. Not on every run. The trigger points are:

| Trigger | Where | Wired by |
|---|---|---|
| `j.close-story` | when a story is closed | `E76_S03_T01` |
| `j.do` | `skills/j-do/SKILL.md` `### 8.1`, called at the loop's end (todo exhausted, user exit), after a story-bundle run, and in the break halt report | `E76_S02_T05` |
| `j.dooo` | `skills/j-dooo/SKILL.md` step 5, at every termination including the break path | `E76_S02_T05` |
| `/jenga` | `skills/jenga/SKILL.md` Exit condition, before either exit message (after the final queue drain and deferral recording) | `E76_S02_T05` |

Each call is `task-usage.sh --persist --task <id>...` for the task IDs the run executed, one line per task from the
JSON `results[]` (`persisted`, `possibly incomplete` or `not measured: <reason>`), and is **non-blocking**: a failed
persist is a warning only and never changes the skill's exit message, a task status or the `/jenga` completion or break
output. Calling again after an inner `/do` already persisted is harmless (unchanged transcripts produce no diff).
**Public-mirror guard (epic decision 6):** each call site first tests that the script exists
(`scripts/task-usage.sh` or `node_modules/@jenga-ai/agent/scripts/task-usage.sh`); when neither does, as on the
public mirror where it is blocklisted, the step is a silent no-op with no output and no warning. This is asserted by
`tests/task-usage-skill-wiring.bats`. `j.proceed`, `j.continue` and `j.redo` do not execute tasks themselves and are
not triggers (`j.todo`'s optional run goes through `/do`, which persists on its own).

### The marker, and what it can and cannot detect

`usage_possibly_incomplete: true` on a task means the persisted numbers are a **lower bound**, never to be presented as
exact. The story's flag is set when any of its tasks carries it (`E76_S03`).

The concrete signal is a **regression against a persisted baseline**: a later `--persist` finds fewer transcripts than
`usage_transcripts`, or a lower sum, while at least one transcript is still there. That is all the script detects. The
two other candidates from `E76_S02` were checked against this machine's real transcripts (2026-11-06) and **not
adopted**, because neither is reliable:

- *A parent session references a subagent id that has no file.* 584 subagent ids are referenced from 51 parent
  sessions of this project, and none is missing a file. Pruning appears to act on whole sessions (subagent files older
  than 30 days survive beside a newer parent session file), so this signal did not fire once and there is no positive
  example to validate it against.
- *A developer run with no tester run for a task whose status says it was tested.* 21 of 338 task-mapped tasks have a
  developer run and no tester run, 15 of them with a tested status (2 `Passed`, 3 `Passed with remarks`, 10 `Merged`).
  Nothing separates pruning from a tester whose transcript maps to no task ID, so it has false positives and no ground
  truth.

So **the first persist of a task cannot tell that its transcripts were already partly pruned**: a total persisted then
is exact only if everything was still on disk, which is why it should happen early (at the trigger points above). The
marker appears only once a later run sees a loss against the stored baseline. No other detection is claimed.

### Defaults, not user decisions

The user decided the trigger points and the possibly-incomplete marker (above). Three further behaviours were **not**
decided by the user and are implemented as the defaults recommended in `E76_S02`; the user can overturn any of them:

1. **Refresh on rework.** A later `--persist` recomputes from the transcripts available and rewrites the stored
   values (so rework adds to the total and the end-of-loop persist agrees with a later `j.close-story` persist), but
   never silently lowers a stored value (the `kept-stored` row). Unchanged transcripts change nothing in the file.
2. **Recent transcripts already gone.** A task with no transcripts (or fewer than its persisted `usage_transcripts`)
   is reported on stderr as not measured / possibly pruned rather than skipped silently, and nothing is written for it.
3. **Transcript lifetime.** Claude Code's `cleanupPeriodDays` setting defaults to **30 days**. Verified against the
   installed Claude Code 2.1.236, whose settings schema describes it as "Number of days to retain chat transcripts
   before automatic cleanup (default: 30). Minimum 1", and neither this machine's `~/.claude/settings.json` nor the project's settings files set it.
   Consistent with that, on 2026-11-06 the oldest main-session transcript of this project had been modified on 2026-10-07 and
   `~/.claude/.last-cleanup` read `2026-11-05T22:36:28Z`. The script itself neither reads the setting nor encodes a
   lifetime. Two things were **not** verified: whether the cutoff is a file's modification time rather than a session's
   start, and whether `cleanupPeriodDays` is the only setting that can delete transcripts. A different value elsewhere
   (user, project or managed settings) changes how long numbers survive without changing anything above.
<!-- END E76_S02_T03: persisting totals (--persist) -->

## Known approximations

These are stated to users and not hidden:

- **Orchestrator and Scrum Master overhead is not tied to one task;** it is allocated to stories by the rule in
  [Allocating overhead to stories](#allocating-overhead-to-stories) (`E76_S03`, implemented by `E76_S03_T03`; ask for
  it with `--allocate` or `--stories`). It is also still reported unallocated, in `overhead`. A story's share depends on
  its tasks' tokens and on which sessions its tasks ran in, so it is an attribution rule for budgeting, not a measure of
  what the overhead caused.
- **Thinking tokens are only partly visible in the usage fields.** `output_tokens_details.thinking_tokens` is a subset
  of `output_tokens` (verified on this machine's transcripts), so thinking is already inside `output`, but it cannot
  be split out as a separate figure, and many usage lines carry no such detail at all.
- **The Copilot path (`hooks/copilot_session_end.sh`) is not covered;** only Claude Code transcripts are read.
- **Claude Code may prune old transcripts,** so a task's numbers can disappear if they are not persisted
  (`E76_S02` mitigates this).

## Allocating overhead to stories

Epic `E76`, story `E76_S03`, task `E76_S03_T02`. Scrum Master and orchestrator overhead is counted against **stories**.
It is not charged to a task and it is not dropped. This section is the rule for how it is split. It is a definition,
not an implementation of its own: `scripts/task-usage.sh --report --allocate` implements it exactly as written here
(`E76_S03_T03`), and `overhead` is still reported unallocated and unchanged as described under
[Output contract](#output-contract---report-schema_version-1). The result is in the
[`stories` section](#the-stories-section---allocate---stories).

### Decisions

**The rule: proportional to task tokens (decided 2026-10-15 by the user).** Each story takes a share of the overhead in
proportion to the tokens its tasks consumed: `share = overhead x story_weight / sum of weights across the split set`.
The rejected alternative was an **even split** (every story in the split set takes the same share). It is simpler, but
it charges a one-task story the same as a story that cost ten times as much to build, so story budgets would stop
reflecting size, which is the purpose of the numbers.

The rule fixes the shape of the formula and nothing else. Five sub-questions were left open, put to the user as
numbered choices and **confirmed by the user in the live session on 2026-11-06**. None was defaulted. Each is recorded
with the answer and the trade-off of each rejected option.

1. **Which overhead transcripts count (2026-11-06).** Scrum Master subagents **and** orchestrator (main-session)
   sessions: every entry `E76_S01_T04` puts in `overhead`.
   - Rejected, Scrum Master subagents only: the cleanest attribution, since that work is planning for named
     stories, but it leaves out the orchestrator's main sessions, which are often the larger part of the overhead, so
     story totals would understate what delivering the story cost.
   - Rejected, only orchestrator sessions that dispatched in-scope tasks: filters out unrelated conversation, but
     "dispatched in-scope tasks" cannot be read from the usage numbers, it depends on which scope a report was asked
     for, and the same session would be counted or not depending on the run, so the numbers would not be reproducible.
2. **The split set for an overhead entry (2026-11-06).** An entry whose ID names one story is charged to that story
   directly. Any other, session-level entry is split across the stories whose tasks ran in that session.
   - Rejected, always the session's stories (even for a story-named entry): one uniform rule, but it spreads a Scrum
     Master's single-story work across unrelated stories that merely shared the session.
   - Rejected, always the epic's stories: a wider pool that includes stories with no work in that session, which are
     then charged for work they did not cause, and a main session has no epic of its own to take the pool from.
3. **Rounding (2026-11-06).** Largest remainder. Floor each share, then hand the leftover tokens out one at a time to
   the largest fractional remainders, ties broken by numeric story ID, so the shares add up exactly to the overhead.
   - Rejected, round each share and put the residual on the largest story: easy, but the residual can be positive or
     negative and it always lands on the same story, which is biased toward the largest.
   - Rejected, floor each share and report the remainder as unallocated: never overcharges, but the shares no longer
     add up to the overhead, and a few tokens per field per entry would sit in `unallocated` as noise someone has to
     reconcile.
4. **Unplaceable overhead (2026-11-06).** Overhead with no candidate story, or whose candidate stories have a combined
   weight of zero, is reported as `unallocated`. It is never silently dropped and never charged to a task or a story.
   - Rejected, an epic-level bucket: keeps the tokens visible, but adds a kind of record that no story total includes,
     so the epic would carry a number that no story owns.
   - Rejected, failing the run: loud, but one session with no task work in it (a planning conversation, say) would
     stop the whole report from being produced.
5. **The weight measure (2026-11-06).** `input + output + cache_write` tokens, **excluding cache reads**.
   - Rejected, `usage_total_tokens` (all four fields): the literal reading of "tokens its tasks consumed", but cache
     reads dominate it (see [the four fields](#the-four-fields-and-why-cache-reads-dominate)), so a story's share would
     follow how long its sessions' contexts were rather than how much work it needed.
   - Rejected, `output` only: measures what the model generated, but ignores the context a task had to load, so a
     read-heavy task would weigh close to nothing.

**Derived, not confirmed.** The user's answers do not cover the points below. They are the natural reading of the
chosen options and are written into the rule so that it can be implemented without further questions, but the user has
**not** separately confirmed them and should be asked to. Changing one changes only the sentence of the rule that names
it.

- **D1, per-field weights.** The user did not say whether each of the four overhead fields is split with its own weights
  or with the same ones. The rule uses the **same per-story weight for all four fields**: the input, output, cache-write
  and cache-read totals of an overhead entry are each split with the weights computed from the tasks'
  `input + output + cache_write`, so cache reads are excluded from the weight but are themselves still allocated.
- **D2, story weight and direct charges.** A story's weight is the sum over **all** of its tasks in the report, not only
  over the part of those tasks that ran in the session being split (a task record is a per-task total and does not say
  how much of it fell in which session). An entry that names one story is charged to it in full regardless of that
  story's weight, even when the story has no task tokens at all.
- **D3, entry by entry.** Each overhead entry is allocated on its own, with its own split set and its own rounding, and
  a story's allocated overhead is the sum over the entries. This follows from the split set being per entry
  (answer 2); a single pooled split would give a different rounding.

### The rule

**Inputs.** The complete `tasks` map and the complete `overhead` list of one `--report` run. The `--task` and `--story`
filters only narrow what `tasks` prints; the allocation always reads the **unfiltered** task set, otherwise a story's
overhead would change with the filter. `unmapped` is **not** an input: those transcripts resolved to no board ID, they
are not overhead for this rule and they stay reported separately, unchanged.

**Task weight and story weight.** For a task, `w_task = input + output + cache_write`. For a story `S`,
`W_S` is the sum of `w_task` over the tasks in the report whose `story_id` is `S`. Both are integers. A story with no
task in the report has `W_S = 0`.

**Which entries name one story.** An overhead entry names one story when `level` is `"story"` and `id` is a story ID
(`E##_S##`). Such an entry is charged **in full to that story**, all four fields, with no split and no weight.
Every other entry is session-level: that is every entry with `kind: "session"` (`level: "none"`, `id: null`) and, as a
direct consequence of answer 2, every entry with `level: "epic"`. An epic ID names an epic, not one story, so it falls to
the session-level split like a main session does.

**Candidate stories of a session-level entry.** The session of an entry is its session directory, derived from `path`:

- `kind: "session"`: `path` is `<slug dir>/<session>.jsonl`, and the session directory is `<slug dir>/<session>`
  (the path without `.jsonl`).
- `kind: "subagent"`: `path` is `<slug dir>/<session>/subagents/agent-<id>.jsonl`, and the session directory is
  `<slug dir>/<session>` (the path with its last two components removed).

A task is **in the session** when at least one path in its `transcripts` has the same session directory (derived the
same way: every task transcript is a subagent transcript). The **candidate stories** are the distinct `story_id` values
of the tasks that are in the session. A session with no task transcript under its directory has no candidate stories.

**Share formula.** For one overhead entry, one field `f` with entry total `T` (`input`, `output`, `cache_write` or
`cache_read`), and candidate stories `C`, with `W = sum of W_S over C`:

1. If `C` is empty, the amount is unplaceable (`no-candidate-story`). If `W = 0`, it is unplaceable (`zero-weight`).
   Otherwise continue.
2. The exact share of story `S` is `T x W_S / W`.
3. Floor it: `q_S = floor(T x W_S / W)`. Its remainder is `r_S = (T x W_S) mod W`.
4. The leftover is `L = T - sum of q_S`. It is an integer with `0 <= L < |C|`.
5. Order the stories by `r_S` descending, ties broken by **numeric story ID** ascending. The first `L` stories in that
   order get one more token each.
6. The share of `S` is `q_S`, plus 1 if it was among those `L`.

All of this is integer arithmetic on the remainders `r_S`, never on floating-point fractions, so there are no ties that
a rounding error could invent or hide. The implementation must keep it exact: `T x W_S` can approach or exceed 2^53
(about 9.0e15) on real data, which is where jq's IEEE-double numbers stop being exact.

Two properties hold, and a test can assert them. The shares add up to `T` exactly. A story with `W_S = 0` never receives
a leftover token, because `sum of r_S = L x W` and every `r_S < W`, so more than `L` stories have a non-zero remainder.

**Numeric story ID order.** A story ID `E<e>_S<s>` sorts by the pair `(e, s)` compared as **integers**, epic first.
`E9_S10` sorts before `E10_S01` (9 < 10) and `E9_S02` sorts before `E9_S10` (2 < 10). A string comparison gets the first
pair wrong (`"E10_S01"` sorts before `"E9_S10"`), which is why the tie-break is stated as numeric.

**Per-field application.** The four fields are allocated **independently**, each with the steps above and the **same**
weights `W_S` (D1). Each field has its own leftover `L` and its own tie-break, so each field's shares sum exactly to that
field's overhead total.

**Unplaceable overhead.** An amount that step 1 rejects is reported as `unallocated`: one record per entry, carrying
the entry's `path`, `id`, `level`, the four field amounts, and one `reason`, `no-candidate-story` or `zero-weight`.
The weights and candidate set do not depend on the field, so the reason is the same for all four fields of an entry,
and the unallocated total per field is the sum over the records. An entry whose four amounts are all zero has nothing
to place and produces no record. `unallocated` is never added to a story or a task.

**Story total.** `story total = the story's task tokens + its allocated overhead`, where each side is the four fields
summed over the tasks, respectively over the entries' shares. The two stay separate numbers next to their sum, so
neither is hidden in the other, and `unallocated` is reported separately and belongs to no story.

**Invariant.** For each field, the sum of the allocated shares over all stories plus the sum of `unallocated` equals
the sum of that field over `overhead`. Every overhead token is therefore in exactly one of: one story, several stories,
or `unallocated`; none is counted twice and none is lost.

### Worked example

Three stories take part in one main-session entry. Weights are the tasks' `input + output + cache_write`, and every
number is kept tiny so that the arithmetic can be followed. The stories are `E9_S02` (weight 3), `E10_S01` (weight 1)
and `E9_S10` (weight 6), so `W = 10`. The entry is `kind: "session"`, `level: "none"`, and all three stories have a task
transcript under its session directory. Its fields are `input` 14, `output` 25, `cache_write` 9 and `cache_read` 1000.

Per field, `T x W_S` is the numerator, the floor is its quotient by 10 and `r_S` is its remainder:

| Field (T) | Story | `T x W_S` | floor `q_S` | remainder `r_S` | leftover | Share |
|---|---|---|---|---|---|---|
| `input` (14) | `E9_S02` | 42 | 4 | 2 | | 4 |
| | `E10_S01` | 14 | 1 | 4 | | 1 |
| | `E9_S10` | 84 | 8 | 4 | `L` = 14 - 13 = 1 | 9 |
| `output` (25) | `E9_S02` | 75 | 7 | 5 | | 8 |
| | `E10_S01` | 25 | 2 | 5 | | 2 |
| | `E9_S10` | 150 | 15 | 0 | `L` = 25 - 24 = 1 | 15 |
| `cache_write` (9) | `E9_S02` | 27 | 2 | 7 | | 3 |
| | `E10_S01` | 9 | 0 | 9 | | 1 |
| | `E9_S10` | 54 | 5 | 4 | `L` = 9 - 7 = 2 | 5 |
| `cache_read` (1000) | `E9_S02` | 3000 | 300 | 0 | | 300 |
| | `E10_S01` | 1000 | 100 | 0 | | 100 |
| | `E9_S10` | 6000 | 600 | 0 | `L` = 0 | 600 |

How the leftovers are handed out:

- `input`, `L` = 1. The largest remainder is 4, held by both `E10_S01` and `E9_S10`: a tie. Numeric order puts
  `E9_S10` first (epic 9 before epic 10), so it gets the token: 4 + 1 + 9 = 14.
- `output`, `L` = 1. The largest remainder is 5, held by `E9_S02` and `E10_S01`: a tie. `E9_S02` comes first, so it gets
  the token: 8 + 2 + 15 = 25.
- `cache_write`, `L` = 2. The remainders in descending order are 9 (`E10_S01`), 7 (`E9_S02`), 4 (`E9_S10`). The first two
  get one token each, with no tie: 3 + 1 + 5 = 9.
- `cache_read`, `L` = 0. The shares are exact and nothing is handed out: 300 + 100 + 600 = 1000.

Allocated overhead per story, and the check that nothing is lost:

| Story | `input` | `output` | `cache_write` | `cache_read` | Sum of the four |
|---|---|---|---|---|---|
| `E9_S02` | 4 | 8 | 3 | 300 | 315 |
| `E10_S01` | 1 | 2 | 1 | 100 | 104 |
| `E9_S10` | 9 | 15 | 5 | 600 | 629 |
| **Column total** | **14** | **25** | **9** | **1000** | **1048** |

Each column adds up exactly to the entry's field (14, 25, 9, 1000), and 315 + 104 + 629 = 1048 = 14 + 25 + 9 + 1000.
A story total then adds its task tokens: if `E9_S10`'s tasks consumed `input` 1, `output` 2, `cache_write` 3 and
`cache_read` 50 (weight 1 + 2 + 3 = 6, as above), its task tokens are 56, its allocated overhead is 629, and its story
total is 56 + 629 = 685, with the two parts kept separate.

**A story-named entry.** A Scrum Master subagent named `E9_S02` resolves to `kind: "subagent"`, `level: "story"`,
`id: "E9_S02"`, with `input` 5, `output` 40, `cache_write` 12 and `cache_read` 700. It names one story, so all of it is
charged to `E9_S02`: 5, 40, 12 and 700. There is no split, no weights and no rounding, and the other stories that
happen to share its session take nothing from it.

**The zero-weight case.** A session entry with `input` 6, `output` 30, `cache_write` 4 and `cache_read` 500 has two
candidate stories, `E9_S02` and `E9_S10`, whose tasks only ever read from the cache (`input + output + cache_write` is 0
for every task), so `W = 0` and `T x W_S / W` is undefined. The whole entry becomes one `unallocated` record with reason
`zero-weight` and the four amounts 6, 30, 4 and 500; neither story changes. A session with no task transcript under its
directory is reported the same way with reason `no-candidate-story`.

### Follow-up for `E76_S01_T04`'s `overhead` output

Recorded here as a follow-up, not as an edit: `scripts/task-usage.sh` and `E76_S01_T04` were unchanged by the task that
wrote this rule (`E76_S03_T02`). `E76_S03_T03` implemented the allocator by deriving the session from the paths, as
point 2 below allows, and did **not** add the `session` field; that robustness follow-up is still open. The
answers above change what the `--report` output has to offer the allocator in two places. Checked against
`scripts/task-usage.sh` on 2026-11-06:

1. **The weight needs no new field.** Excluding cache reads (answer 5) means the allocator needs each task's
   `input + output + cache_write`, and every `tasks` record already carries those three numbers, so the per-story weight
   is computed from the task fields.
2. **An overhead entry already carries what decides "names one story"** (`id` and `level`), but **not its session as a
   field.** An entry has `kind`, `agent_type`, `id`, `level`, the four numbers and `path`, and a task has `transcripts`,
   a list of paths. The session is derivable from those paths with the shapes above (the session directory is the path
   without `.jsonl` for a session, and the path minus its last two components for a subagent), so the allocator can be
   written without a change to the script. Stage 1 (`--list-transcripts`) does hold `session_id` and `slug_dir` for every
   transcript, but the stage 3 report drops them. **Follow-up: add the session to the report**, as a `session` field on
   each `overhead` entry and on each task transcript record (or a `sessions` list on each task), so that the allocator
   does not parse paths. This is a robustness change, not a blocker; additive fields leave existing consumers working,
   and whether `schema_version` moves is for the implementing task to decide.

One note for the implementing task (`E76_S03_T03`): the unfiltered task set the allocator needs is built inside the
report's jq program before the `--task`/`--story` filters are applied, so the allocation has to run on that set and not
on the printed `tasks` map.

## Re-verification (2026-10-25 / 2026-10-26)

The facts in `E76`'s Purpose were re-checked against real files under `~/.claude/projects/` before the stages were
built; the evidence is recorded in the script header (layout, slug rule, `message.usage` field names, several lines per
`requestId` with the last line holding the maximum, `cache_creation` summing to the total, thinking tokens being a
subset of output). Nothing differed from the Purpose except two refinements: a subagent's meta `name` can carry a
prefix as well as a suffix (`test-E85_S03_T09`), and the slug of a worktree session replaces `_` and `.` as well as `/`.
A full `--report` over this machine's transcripts (281 tasks, about 28 seconds) returned plausible numbers, for example
the `E72_S01_T05` figures above.
