# Synthetic transcript fixtures for `scripts/task-usage.sh` (E76_S01_T05)

Hand-written, synthetic Claude Code transcripts. No real prompt text, session id, project path or board ID is used:
every ID is the fictitious epic `E99`, every path lives inside this directory, and the numbers are small and round so a
reviewer can check them without running anything. Consumers: `tests/task-usage*.bats` (E76_S01_T06, E76_S02).

## How to point the script at them

```
scripts/task-usage.sh --report --projects-dir tests/fixtures/task-usage/projects --project-dir /fixture/proj
```

`--project-dir /fixture/proj` yields the slug `-fixture-proj`, which is the slug directory below (the path does not need
to exist). Layout (mirrors `~/.claude/projects`):

```
projects/
  -fixture-proj/                                  main slug
    sess-0001.jsonl                               main-session transcript            (case 5)
    sess-0001/subagents/agent-a0001.{jsonl,meta.json}   E99_S01_T01                   (case 1)
    sess-0001/subagents/agent-d0001.{jsonl,meta.json}   scrum-master, name E99_S01    (case 5)
    sess-0002/subagents/agent-b0001.{jsonl,meta.json}   E99_S01_T02 first attempt     (case 2)
    sess-0002/subagents/agent-b0003.{jsonl,meta.json}   name E99_S01_T02-tester        (case 3)
    sess-0002/subagents/agent-c0001.{jsonl,meta.json}   name verify-group5             (case 4)
    sess-0003/subagents/agent-b0002.{jsonl,meta.json}   E99_S01_T02 rework, other session (case 2)
    sess-0004/subagents/agent-g0001.{jsonl,meta.json}   E99_S01_T03, cache_creation split (case 7)
  -fixture-proj--claude-worktrees-E99-S02-T01/    worktree sibling slug              (case 6)
    sess-0005/subagents/agent-f0001.{jsonl,meta.json}   E99_S02_T01
  -fixture-proj-public/                           DECOY: shares the prefix, is NOT a worktree sibling; never read
    sess-0009/subagents/agent-z0001.{jsonl,meta.json}   would be E99_S09_T09 if it were wrongly read
projects-no-meta/   -fixture-proj/sess-0002/subagents/agent-n0001.jsonl                (case 8a, no sidecar)
projects-no-usage/  -fixture-proj/sess-0002/subagents/agent-n0002.{jsonl,meta.json}    (case 8b, no usage object)
```

Every `*.jsonl` is valid JSON line by line and every `*.meta.json` is valid JSON. Token columns below are
`input / output / cache_write / cache_read`; `total` is their sum (`usage_total_tokens`).

## Expected `--report` result for `projects/`

| Bucket | ID | input | output | cache_write | cache_read | total | transcripts |
|---|---|---:|---:|---:|---:|---:|---:|
| tasks | `E99_S01_T01` | 30 | 900 | 1,000 | 11,000 | 12,930 | 1 |
| tasks | `E99_S01_T02` | 17 | 1,700 | 3,500 | 31,000 | 36,217 | 3 |
| tasks | `E99_S01_T03` | 3 | 150 | 1,200 | 6,200 | 7,553 | 1 |
| tasks | `E99_S02_T01` | 10 | 100 | 700 | 6,700 | 7,510 | 1 |
| overhead (session) | id `null`, level `none` | 7 | 70 | 400 | 2,000 | | |
| overhead (scrum-master) | `E99_S01`, level `story` | 8 | 80 | 600 | 2,500 | | |
| unmapped | name `verify-group5` | 6 | 60 | 300 | 1,500 | | |

`warnings` is `[]`. `E99_S09_T09` (the decoy) appears nowhere. Story `E99_S01` (tasks T01+T02+T03) sums to input 50,
output 2,750, cache_write 5,700, cache_read 48,200, total 56,700; story `E99_S02` is just `E99_S02_T01`.

## Per case

### 1. Streaming trap (`agent-a0001`, task `E99_S01_T01`)

Two requestIds interleaved, in file order (`output_tokens` grows within a call; the other counters repeat):

| line | requestId | input | output | cache_write | cache_read |
|---|---|---:|---:|---:|---:|
| 1 | `req_A` | 10 | 100 | 1,000 | 5,000 |
| 2 | `req_B` | 20 | 50 | 0 | 6,000 |
| 3 (system) | | | | | |
| 4 | `req_A` | 10 | 300 | 1,000 | 5,000 |
| 5 | `req_B` | 20 | 200 | 0 | 6,000 |
| 6 (assistant, no usage, `req_X`) | | | | | |
| 7 | `req_A` | 10 | 700 | 1,000 | 5,000 |

`req_A` is on three lines, `req_B` on two, 5 usage lines in all. The three summing rules give three different
totals:

| rule | input | output | cache_write | cache_read | total |
|---|---:|---:|---:|---:|---:|
| first line per requestId | 30 | **150** (100+50) | 1,000 | 11,000 | **12,180** |
| every line | 70 | **1,350** (100+300+700+50+200) | 3,000 | 27,000 | **31,420** |
| **last line per requestId (correct)** | 30 | **900** (700+200) | 1,000 | 11,000 | **12,930** |

`--usage` on this file reports `calls` 2, `usage_lines` 5.

### 2. Rework (`E99_S01_T02`)

Two developer transcripts, different agent ids and different sessions, both with meta name `E99_S01_T02`:

| transcript | session | input | output | cache_write | cache_read |
|---|---|---:|---:|---:|---:|
| `agent-b0001` (calls `req_C1` 5/400/2,000/8,000 and `req_C2` 5/600/0/10,000) | `sess-0002` | 10 | 1,000 | 2,000 | 18,000 |
| `agent-b0002` (`req_D1`) | `sess-0003` | 4 | 500 | 1,000 | 9,000 |

### 3. Tester suffix (`E99_S01_T02`)

`agent-b0003`, meta name `E99_S01_T02-tester`, one call `req_E1` 3/200/500/4,000, maps to the same task. The task
total therefore sums all three transcripts: input 17, output 1,700, cache_write 3,500, cache_read 31,000, total
36,217, `usage_transcripts` 3. Without the tester it would be 14 / 1,500 / 3,000 / 27,000 = 31,514 (2 transcripts).

### 4. Unmapped (`agent-c0001`)

Meta name `verify-group5`, a description with no ID, and a first user prompt with no ID. One call `req_G1`
6/60/300/1,500. Expected: listed in `unmapped` (reason: no board ID in meta name or description; no board ID in first
user prompt line), absent from `tasks`, never guessed into a task.

### 5. Overhead

- `sess-0001.jsonl`, the main session: one call `req_H1` 7/70/400/2,000; `kind` `session`, `agent_type` null, `id` null,
  `level` `none`.
- `agent-d0001`, `agentType` `scrum-master`, meta name `E99_S01` (a story ID): one call `req_I1` 8/80/600/2,500;
  `kind` `subagent`, `id` `E99_S01`, `level` `story`.

Both are in `overhead` only; neither is added to any task or story.

### 6. Worktree slug (`E99_S02_T01`)

Lives under `-fixture-proj--claude-worktrees-E99-S02-T01/`, a sibling of the main slug. Two calls: `req_J1`
9/90/700/3,000 and `req_J2` 1/10/0/3,700; total 10 / 100 / 700 / 6,700 = 7,510. The decoy `-fixture-proj-public/`
(one call 1/1/1/1) must not be read, so `E99_S09_T09` is never reported.

### 7. Cache split (`agent-g0001`, `E99_S01_T03`)

Call `req_F1` has `cache_creation_input_tokens` 1,000 **and** the optional breakdown
`cache_creation: {ephemeral_1h_input_tokens: 600, ephemeral_5m_input_tokens: 400}`; call `req_F2` has the total only
(200). The breakdown is a part of the total and must not be added on top: `cache_write` = 1,000 + 200 = **1,200**
(adding the breakdown would wrongly give 2,200). Input 2+1 = 3, output 100+50 = 150, cache_read 3,000+3,200 = 6,200,
total 7,553.

### 8. Negative layout cases (for E76_S02)

- **8a `projects-no-meta/`**: `agent-n0001.jsonl` is the content of `E99_S01_T02`'s first attempt (calls `req_C1`,
  `req_C2`, output 1,000) with its `.meta.json` removed and no ID in the prompt. `--list-transcripts` still lists it
  unmapped with reason beginning `no meta.json`; since `E76_S02_T01`, `--report` and `--check-layout` exit 6 (layout
  check 3) with nothing on stdout from `--report`.
- **8b `projects-no-usage/`**: `agent-n0002.jsonl` (meta name `E99_S01_T02`) has assistant lines with no `message.usage`
  object. `--usage` still gives `usage_lines` 0 (`assistant_lines` 2); since `E76_S02_T01`, `--report` and
  `--check-layout` exit 7 (layout check 4) instead of reporting the task with all four sums 0.

Either negative tree can also be reproduced at test time by copying `projects/` and deleting a `.meta.json` or
stripping the `usage` objects.
