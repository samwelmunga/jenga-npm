# Event log merge strategy (`project/logs/events.json`)

- **Task:** E75_S01_T02 ("Decide and implement a merge strategy for the shared event log")
- **Story / Epic:** E75_S01 / E75
- **Status of this record:** decided and implemented on branch `E75_S01_T02-event-log-merge-strategy`
- **Decision basis:** the user chose **JSONL, one event per line** through a structured question on 2026-10-19. A full `/j-brainstorm` session was **not** held for this decision. The options below were evaluated directly, and the user's choice was made on that basis. Re-opening the format is out of scope for this task.

## 1. Problem

`project/logs/events.json` is the shared inter-agent event log. It is a single JSON array. Every writer (developer session-start, `on_session_end.sh`, `j.commit`'s test gate, `j.mirror-public`'s publicized marker, `j.close-story`'s privatized check, the orchestrator's preflight-deferred and check-in events) appends by rewriting the array's closing bracket.

Two branches that each append an event both edit the same end-of-file region. Git's three-way merge sees two conflicting edits at the array's tail and stops with conflict markers. The file is tracked and committed, so this happens in ordinary parallel work (for example, parallel worktrees finishing tasks in the same wave). A writer lock inside one checkout does not help, because the conflict is created by git merging two branches, not by two writers racing on one disk.

## 2. Options considered

| Option | Verdict | Reason |
|---|---|---|
| **A. One event file per session or worktree** (`events/<session>.json`) | Rejected | Removes the conflict by never sharing a file. It moves the cost to every reader: each reader (`checkin-gate.sh`, `collect-liveness.sh`, `list-preflight-deferred.sh`, the dashboard) would have to glob and merge many files, and "the log" would no longer be one ordered trail. Ordering across sessions would be lost. It is a larger change to the read path than the write problem warrants, and the file path `project/logs/events.json` is referenced across skills and the schema. |
| **B. Keep one array; fix it only in the writer** (locks, retries, rebase-on-write) | Rejected | Locks (`scripts/with-lock.sh`) serialise writers on one checkout only. Two branches are merged by git later, long after either writer finished, and git still sees two edits to the array's tail. No writer-side discipline can make a later `git merge` clean. |
| **C. JSON array plus `.gitattributes merge=union`** | Rejected | `merge=union` keeps the lines from both sides. In a JSON array the separators and the closing `]` are shared lines, so union produces duplicated or interleaved brackets and commas. This was verified in a scratch repository: the merged file was **invalid JSON**. The union driver is only safe for line-oriented content. |
| **D. JSONL (one complete JSON object per line) plus `.gitattributes merge=union`** | **Chosen** | Each event is a self-contained line, so two branches' appends are two sets of whole new lines. `merge=union` keeps both sets and produces valid JSONL. JSONL alone is not enough: without the union driver, git still conflicts at end-of-file (verified: `git merge` exit 1 with conflict markers in the scratch repo). The attribute is what makes the merge clean. |

## 3. Why `merge=union` is acceptable here

`merge=union` is a blunt tool, and it is only safe under the conditions below. All of them hold for this file.

- **Line-oriented content.** Each record is one JSON object on one line. A union of whole lines never splits a record. This is the reason the format decision and the merge rule are one decision.
- **Append-only.** Events are never edited or deleted in place by a writer. A union of two branches that each only appended is the correct result.
- **Order is not chronological across branches.** Union keeps both sides' lines, but the relative order of lines from two branches is whatever git's merge produced. Readers must not rely on file position for cross-branch correctness. The existing readers either filter by `session_id` and `event`, or deduplicate by `item_id`, so they do not depend on global order. Any new reader must follow the same rule.
- **Duplicate lines.** If two branches append byte-identical lines, union keeps the lines it sees; the exact duplicate behaviour was not separately tested here. Existing readers that need uniqueness deduplicate in code (`list-preflight-deferred.sh` de-duplicates by `item_id`; `mark-publicized.sh` checks for an existing event before appending). Event lines carry a `date`, so identical lines are unlikely in practice.
- **Torn final line.** A line written without its trailing newline (a writer mid-append, or a crash) is not yet a record. Readers ignore an unterminated final line; a bad line anywhere else is real damage and is reported.

The rule is recorded in `.gitattributes` with a comment pointing back to this document. Changing it requires re-reading this section.

## 4. Decision

- `project/logs/events.json` is **JSONL**: one JSON record per line, `\n`-terminated, no array, no pretty-printing, no internal newlines.
- The file keeps the `.json` suffix. The suffix is kept deliberately so that existing paths, globs, the dashboard's file references, and documentation do not change. The content is JSONL and the schema (`templates/SCRUM_BOARD_SCHEMA.md`) says so.
- `.gitattributes` contains `project/logs/events.json merge=union`. `init.sh` (both the project scaffold and the `j-skillify` asset) writes this rule idempotently.
- Writers append exactly one line, under `scripts/with-lock.sh project/logs/events.json -- ...`. A writer refuses to append to a file still in the legacy array shape (it does not rewrite it).
- The event shape is **unchanged**. No field was added, removed or renamed. The format decision is about layout, not content.

## 5. Migration

### 5.1 The existing log

The committed log was a single 1612-entry JSON array, 714575 bytes at `HEAD`. It was converted by `scripts/events-log-migrate.sh`, which:

1. Tokenises the JSON text.
2. Changes only the whitespace **outside** string literals: the line breaks and indentation between tokens are collapsed to one space or nothing. String literals are copied verbatim.
3. Verifies, before writing anything, that (a) the parsed values are equal to the original, (b) the token stream is equal apart from whitespace, and (c) every string literal is identical, in order. If any check fails it writes nothing and exits non-zero.
4. Writes through a temporary file in the same directory and `os.replace`, keeping the file mode.
5. Is idempotent: a file already in JSONL shape is left as it is.

Results on the `HEAD` copy: 714575 bytes became **621522 bytes**, 1612 entries, all parsed back equal, same order, 28159 string literals identical, and the 22 lines containing non-ASCII text unchanged byte for byte.

### 5.2 What changed and what did not

- **Changed (unavoidable):** every entry is now on one line. The pretty-printed indentation and the line breaks inside each object are gone, the array brackets are gone, and the commas that separated entries become line breaks. Entries are therefore **not byte-identical** to their former pretty-printed form. A one-line record cannot contain internal newlines, so this reformatting cannot be avoided.
- **Unchanged:** every value, every key, the key order inside each object, the order of entries, every string literal (including escape sequences such as `\uXXXX` and raw non-ASCII text).
- **Not forced:** no event shape changed.

The entry bytes are value-identical and string-literal-identical. They are not byte-identical to the old layout, and that is the honest accounting.

### 5.3 The worktree log

The worktree's log (`project/logs/events.json` on this branch) contains the `HEAD` entries plus the developer's `sender_received` entry for this task, 1613 records in total. It is already in JSONL shape.

### 5.4 In-flight branches

Any branch cut before this change still has the array-shaped file. Merging it into a branch that already has the JSONL file will conflict at file level. Recovery is:

1. On the in-flight branch, run `scripts/events-log-migrate.sh project/logs/events.json` on its copy.
2. Commit the migrated file.
3. Merge. The union rule then applies to the new appends.

The known in-flight branch is `bundle-E67_S08`. The migrator refuses to touch a file that is neither an array nor JSONL, and it verifies before writing, so running it on a branch copy is safe.

### 5.5 The main checkout

The main checkout's `project/logs/events.json` carries four uncommitted extra entries (1617 lines against `HEAD`'s 1612). Those entries must be reconciled into the JSONL file before this branch is merged. They are not part of this change and were not touched by it.

## 6. Readers and writers

### 6.1 Readers

| File | Behaviour after this change |
|---|---|
| `skills/j-check-in/scripts/checkin-gate.sh` | Keeps its tolerant scanner, which decodes top-level values with `raw_decode`. It accepts JSONL and the legacy array during the transition. Comment updated; scanner logic unchanged. |
| `skills/j-check-in/scripts/collect-liveness.sh` | Same tolerant parse. Comment updated; code unchanged. |
| `skills/jenga/scripts/list-preflight-deferred.sh` | Strict per line. A file whose first non-space character is `[` is refused with exit 1 and a hint to run the migrator. Each non-empty line is parsed; an unterminated final line is ignored; any other bad line is reported with its line number and exits 1. |

### 6.2 Writers

| File | Change |
|---|---|
| `hooks/on_session_end.sh` (`APPEND_EVENT_SCRIPT`) | Shape guard, then `jq -c` one line and `>>`. Still runs under `with-lock.sh`. |
| `skills/j-commit/scripts/test-gate-run.sh` (`APPEND_EVENT_SCRIPT`) | Same shape guard and single-line append. |
| `skills/j-mirror-public/scripts/mark-publicized.sh` | Creates an empty file when absent; shape guard; dedupe with `jq -s -e`; single-line append. |
| `skills/j-close-story/scripts/check-privatized.sh` | Replaced the whole-file `json.load` / `json.dump(indent=2)` rewrite with a shape guard and a single-line append. Nothing already in the file is read back or rewritten. |

Agent and skill prose was migrated to `scripts/events-append.sh` afterwards (E75_S01_T03, see section 7).

### 6.3 Scaffolding

`skills/j-init/scripts/init.sh` and `skills/j-skillify/assets/init-new/scripts/init.sh` now create an **empty** `events.json` (not `[]`) and add the `merge=union` rule to `.gitattributes`, idempotently.

### 6.4 Dashboard and snapshot readers

A search for references to `events.json` and its readers was run under `skills/j-dashboard`, `skills/j-dashboard-share`, `project/app/api`, `project/app/ui`, `lib/`, `mcp/` and `scripts/`. **No dashboard or snapshot reader was found.** This covers the searched paths only. The dashboard's data layer should be re-checked if it is later moved outside them.

### 6.5 Schema

`templates/SCRUM_BOARD_SCHEMA.md` documents the file as JSONL, the `merge=union` rule, where writers append, and why the `.json` suffix is kept.

## 7. Writing events (agents and skills)

Agent and skill prose no longer describes array appends (E75_S01_T03). Every agent-facing instruction that logs an event calls `scripts/events-append.sh` in its dual-path form (`"$([ -f scripts/events-append.sh ] && echo scripts/events-append.sh || echo node_modules/@jenga-ai/agent/scripts/events-append.sh)" '<json-record>'`; the record may also arrive on stdin; `--file <path>` redirects it for tests).

The helper:

- validates that the record is a single JSON object (`jq`, falling back to `python3`) and writes it as one compact, ASCII-escaped line;
- appends with `>>` only, under `scripts/with-lock.sh`; it never truncates or re-serialises existing content, creates an absent target, and terminates an unterminated last line before appending;
- refuses (exit 4, file byte-identical) an array-shaped target or one holding a non-object line, and refuses (exit 3) a bad record.

Event names and shapes are unchanged (`checkin` keeps its spelling and its `session_key` rule).

### 7.1 Shrink guard

`scripts/check-events-log-shrink.sh [--staged]` compares the working-tree (or index) `project/logs/events.json` with its `HEAD` version and fails when the line count decreases or when `HEAD`'s bytes are not an exact prefix of the new content. The log is append-only, so every valid change is a pure extension.

Why a working-tree-versus-`HEAD` script and not a bats test over real history: a test over history would fail forever on `d3dde1d9` (the commit that replaced the log with a 4-entry array) and on any future legitimate rewrite such as a migration, whereas this check runs at the moment of damage and is reusable as a pre-commit gate. Wiring it as a pre-commit checklist item goes through a `checklist_suggestion` rapport (`scripts/checklist.sh suggest`), never a direct write to `project/configs/checklists.json`.

## 8. Notes for the reviewer

- The migrator is `scripts/events-log-migrate.sh`. It is the recovery path for in-flight branches (section 5.4), and it is independently re-runnable.
- The decision was taken by the user, not by this record. If the format is ever revisited, section 3 lists the conditions that make `merge=union` safe. Any change that breaks one of them invalidates the attribute.
