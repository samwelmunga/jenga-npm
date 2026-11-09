#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/task-usage.sh - attribute Claude Code transcript usage to board tasks (epic E76, story E76_S01)
#
# STAGE 1 (task E76_S01_T02): transcript discovery and task mapping (--list-transcripts). Reads no usage numbers.
# STAGE 2 (task E76_S01_T03): per-transcript usage extraction with last-line-per-requestId deduplication (--usage).
# STAGE 3 (task E76_S01_T04): per-task aggregation, the overhead and unmapped buckets and the machine-readable
# report (--report). Post-hoc transcript attribution only: no hook, no settings change, no pricing.
# DRIFT PROTECTION (task E76_S02_T01): --report and --check-layout fail loudly, each with its own exit code, when
# the transcript layout, the sidecar meta or the usage fields are not what the script reads (see LAYOUT CHECKS).
# PERSISTENCE (task E76_S02_T03): --persist writes a task's totals into its board file, only on that explicit flag,
# so a task's numbers survive Claude Code pruning old transcripts (see PERSIST).
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   task-usage.sh --list-transcripts [--projects-dir <dir>] [--project-dir <path>]
#   task-usage.sh --usage <transcript.jsonl>
#   task-usage.sh --report [--task <id>]... [--story <id>]... [--stories <id>]... [--allocate]
#                          [--board-stories-dir <dir>] [--projects-dir <dir>] [--project-dir <path>]
#   task-usage.sh --check-layout [--projects-dir <dir>] [--project-dir <path>]
#   task-usage.sh --persist [--task <id>]... [--story <id>]... [--projects-dir <dir>] [--project-dir <path>]
#   task-usage.sh -h | --help          print this usage on stdout, exit 0
#
#   --list-transcripts   print a JSON array on stdout, one record per discovered transcript (see OUTPUT)
#   --usage <file>       print one JSON object with the transcript's four token sums (see USAGE EXTRACTION); the
#                        file is any Claude Code transcript .jsonl, also --usage=<file>. Exactly one mode per run
#   --report             print the per-task report on stdout (see REPORT)
#   --check-layout       run the four layout checks over every discovered transcript WITHOUT aggregating: a human
#                        verdict on stderr, a one-line JSON verdict on stdout (see LAYOUT CHECKS), the same exit
#                        codes as --report, 0 only when all four pass
#   --persist            measure exactly like --report, then write each measured task's usage fields into its board
#                        file under scripts/with-lock.sh (see PERSIST). stdout: one JSON summary of what happened to
#                        each task; stderr: the human messages. The ONLY mode that writes to the board. Exactly one
#                        mode per run
#   --task <id>          only with --report or --persist: keep only this task in the "tasks" map (a task ID such as
#                        E72_S01_T05; also --task=<id>; repeatable, the filters are OR-ed within one option)
#   --story <id>         only with --report or --persist: keep only the tasks of this story (a story ID such as E72_S01;
#                        also --story=<id>; repeatable). With both options a task must satisfy both
#   --stories <id>       only with --report: add the "stories" and "unallocated_overhead" sections (overhead allocation,
#                        see OVERHEAD ALLOCATION) narrowed to this story (also --stories=<id>; repeatable). It narrows
#                        only the "stories" section: the allocation itself, "tasks" and every other key are unchanged
#   --allocate           only with --report: add those two sections for every story. Without --stories or --allocate
#                        the report has exactly the keys it had before E76_S03_T03
#   --board-stories-dir <dir>  only with --report and the sections above: where the board's story files are read from
#                        (task rosters). Default $JENGA_BOARD_STORIES_DIR, else <project dir>/project/board/stories
#   --projects-dir <dir> the Claude Code projects directory (also --projects-dir=<dir>). Default ~/.claude/projects
#   --project-dir <path> the project whose transcripts to read; default is the main repository of the current
#                        directory (a git worktree resolves to its main repository), else the current directory
#
# ENVIRONMENT
#   JENGA_PROJECTS_DIR   the projects directory, exactly like --projects-dir. Precedence: the option, then
#                        JENGA_PROJECTS_DIR (when non-empty), then $HOME/.claude/projects. Tests point it at a fixture.
#
# EXIT CODES
#   0  success. --report: the report was printed (an empty "tasks" map is a success only when no ID was requested,
#      or at least one requested ID has transcripts). --check-layout: all four checks passed. --list-transcripts
#      prints an empty array (and a note on stderr) when the project has no transcripts
#   2  usage error: unknown option, missing option value, unexpected argument, no mode given, two modes given,
#      --task, --story, --stories, --allocate or --board-stories-dir outside --report, or a --task/--story/--stories
#      value that is not a task/story ID of the right shape (message and usage on stderr, nothing on stdout)
#   3  environment error: jq is not installed; for --list-transcripts, --report and --check-layout also
#      scripts/lib/board-ids.sh missing; for --list-transcripts also the projects directory absent; for --usage
#      the transcript file is missing or unreadable
#   4  layout check 1 failed: the transcript root (projects directory) does not exist, or it holds no directory
#      for this project's slug (--report and --check-layout)
#   5  layout check 2 failed: no subagents/ directory, or no agent-*.jsonl file, anywhere under the project's slug
#      directories (--report and --check-layout)
#   6  layout check 3 failed: a subagent transcript has no sibling .meta.json, the .meta.json is not parseable JSON
#      (or not an object), or it lacks a field the mapper reads: "agentType", and "name" or "description"
#   7  layout check 4 failed: a transcript MAPPED TO A TASK has assistant lines but none carries a message.usage
#      object, or a usage object lacks one of the four numeric fields the sums need (input_tokens, output_tokens,
#      cache_creation_input_tokens, cache_read_input_tokens)
#   8  zero versus absent: --report or --persist with --task/--story where EVERY requested ID has no transcripts. With at least
#      one matching ID the run is a bulk run: the absent IDs go under "warnings" and are absent from "tasks"
#   9  persist failure (--persist only): at least one task could not be persisted: the lock on its board file was not
#      acquired (the write was skipped, never forced), the write failed, a transcript of the task could not be read, a
#      stored usage value is not a plain integer, or more than one board file matches the task ID. Tasks that could be
#      persisted still are; the failing ones are listed in the stdout summary and on stderr
# Every failure (4 to 8) writes a message on stderr that names the missing thing and the path that was searched,
# and --report and --persist write NOTHING on stdout (the report is built in a temporary file and printed last, so a failing run
# can never leave a half-written JSON document). Exit codes 4 to 7 are checked in that order; the first failing
# check decides the code (--check-layout lists every check that failed in its verdict, the code is the first's).
# --list-transcripts and --usage are lenient diagnostic primitives: they aggregate nothing, keep exit 3 for a
# missing projects directory, and report a missing sidecar or usage as data (a record's "reason", a usage_lines of 0).
#
# ---------------------------------------------------------------------------
# DISCOVERY
# ---------------------------------------------------------------------------
# The project slug is the project path with every character other than a letter, digit or "-" replaced by "-"
# (re-verified 2026-10-25 against ~/.claude/projects: "/" and "." and "_" and " " all become "-"; for example
# /Users/x/Projects/Jenga2.0 -> -Users-x-Projects-Jenga2-0 and a worktree .claude/worktrees/bundle-E73_S01 ->
# ...--claude-worktrees-bundle-E73-S01). Read, under <projects-dir>:
#   <slug>/<session>.jsonl                          the main session transcript  (kind "session")
#   <slug>/<session>/subagents/agent-<id>.jsonl     a subagent transcript        (kind "subagent")
#   <slug>/<session>/subagents/agent-<id>.meta.json its sidecar (agentType, name, description, ...)
# and the same two shapes under each sibling directory named exactly "<slug>--claude-worktrees-*" (a session
# started inside a worktree has its own slug directory). Nothing else is read: "<slug>-public" and any other
# directory that merely shares a prefix is NOT a sibling. The transcript "cwd" field is never read; it names the
# main repository, not the worktree, so it cannot attribute anything.
#
# ---------------------------------------------------------------------------
# MAPPING (kind "subagent" only)
# ---------------------------------------------------------------------------
# A board ID is E<n>, E<n>_S<n> or E<n>_S<n>_T<n> (shapes come from scripts/lib/board-ids.sh; any digit width).
# Sources are tried in order and the FIRST source that contains any ID decides:
#   1. the meta "name"               E72_S01_T05, E72_S05_T02-tester, test-E85_S03_T09, tester-E80_S04_T07, ...
#   2. the meta "description"        "Implement E72_S01_T05 ..."
#   3. the first user prompt         only the FIRST NON-BLANK LINE of the first user message that has text
# An ID is found anywhere in the text, so a trailing role suffix ("-tester", "-tester-r2", "-retest") or a leading
# one ("test-", "retest-") does not matter. An ID must stand alone: it may not touch a letter, digit or "_" on
# either side, so "E72_S05_T02x" and "TYPE12" yield nothing. Within the deciding source the MOST SPECIFIC ID wins
# (task over story over epic); several IDs of the same level: the first in the text wins and all distinct IDs are
# reported in "candidates". A name with no ID (for example verify-group5) falls through to the next source. When no
# source yields an ID the record is unmapped: id null, level "none", source null, and "reason" says why. An ID is
# never guessed, and a transcript with no resolvable ID is never assigned to any task.
# Known limits: an ID written with a hyphen between its parts (E28_S20-T05) resolves only to the part that is
# written in the underscore form (E28_S20); the full first user message is not scanned because dispatch prompts
# routinely list many unrelated IDs.
#
# ---------------------------------------------------------------------------
# REPORT (--report)  -  stage 3, task E76_S01_T04
# ---------------------------------------------------------------------------
# Lists the transcripts (stage 1), extracts each one's usage (stage 2) and prints ONE JSON document on stdout.
# Valid JSON always (jq . succeeds); it never carries a price, cost or currency field (E76 decision 1: tokens
# only); every human-readable message goes to stderr, including one line per entry of "warnings". Exit 0 also when
# nothing matched (empty maps and lists, and a warning when a filtered ID has no transcripts).
#
# The output contract (schema_version 1; a breaking change to any key below raises schema_version):
#
#   {
#     "schema_version": 1,
#     "generated_at":   "2026-10-26T09:00:00Z",          UTC, ISO 8601
#     "tasks": {                                          keyed by task ID, sorted by ID; "{}" when none
#       "E72_S01_T05": {
#         "story_id": "E72_S01",  "epic_id": "E72",       derived from the task ID
#         "input": 12, "output": 3400, "cache_write": 56000, "cache_read": 2300000,
#                                                         the four sums over ALL transcripts of the task
#         "usage_total_tokens": 2359412,                  = input + output + cache_write + cache_read, nothing else
#         "usage_transcripts": 2,                         number of transcripts summed (rework counted once each)
#         "transcripts": ["/abs/agent-a.jsonl", ...]      the summed transcripts, sorted
#       }
#     },
#     "overhead": [                                       NOT allocated here (see OVERHEAD ALLOCATION), sorted by path
#       { "kind": "session" | "subagent",                 "session" = main-session transcript
#         "agent_type": "scrum-master" | ... | null,      the meta agentType; null for a session
#         "id": "E72_S01" | "E72" | null,                 the story/epic ID the mapper resolved, else null
#         "level": "story" | "epic" | "none",
#         "input": n, "output": n, "cache_write": n, "cache_read": n,
#         "path": "/abs/transcript.jsonl" }
#     ],
#     "unmapped": [                                       subagents that resolved to NO board ID, sorted by path
#       { "kind": "subagent", "agent_type": "..." | null, "name": "..." | null, "reason": "why no ID",
#         "input": n, "output": n, "cache_write": n, "cache_read": n, "path": "/abs/transcript.jsonl" }
#     ],
#     "warnings": [                                       machine-readable; [] when none
#       { "code": "no-transcripts-for-task",  "id": "<id>", "message": "..." },   a --task ID with no transcripts
#       { "code": "no-transcripts-for-story", "id": "<id>", "message": "..." },   a --story ID with no tasks
#       { "code": "transcript-unreadable", "path": "<file>", "message": "..." },   excluded from every sum
#       { "code": "transcript-without-usage", "path": "<file>", "message": "..." }   no assistant line at all:
#                                                           excluded from every sum, never printed as zeros
#     ]
#   }
#
# PARTITION: every readable transcript lands in exactly one of tasks, overhead, unmapped, so nothing is counted
# twice and nothing is dropped:
#   * tasks      subagent whose mapping resolved to a TASK ID (name, description or first prompt line, see MAPPING;
#                a "-tester" or "retest-" form maps to the same task, so developer, tester and rework transcripts of
#                one task are SUMMED into one record: one total per task, no first-attempt/retry split)
#   * overhead   every session transcript, and every subagent that resolved to a STORY or EPIC ID only (for example
#                a Scrum Master subagent named E72_S01). The ID and level are carried so the allocation can place
#                the numbers; "overhead" itself stays unallocated, and an overhead entry is never added to any task
#   * unmapped   every other subagent (no ID anywhere in name, description or first prompt line). Reported with the
#                mapper's reason, never dropped and never guessed into a task
# FILTERS touch only "tasks"; overhead, unmapped and warnings are always complete. An ID that matches no task is a
# warning, never a record of zeros (and exit 8 with nothing on stdout when every requested ID is absent). A task kept by --task/--story keeps its full, unfiltered numbers.
# The meaning of the four fields, why cache reads dominate, and the known approximations are in
# project/documentation/task-usage.md.
#
# ---------------------------------------------------------------------------
# OVERHEAD ALLOCATION (--stories, --allocate)  -  task E76_S03_T03
# ---------------------------------------------------------------------------
# The rule is recorded in project/documentation/task-usage.md ("Allocating overhead to stories"); this is its
# implementation. It is opt-in: without --stories or --allocate the report is exactly the one above (two tests assert
# its exact top-level keys). With either, two keys are added and schema_version stays 1 (additive keys):
#
#   "stories": {                                  keyed by story ID in NUMERIC order (E9_S10 before E10_S01)
#     "E9_S10": {
#       "epic_id": "E9",
#       "measured": true,                         true when at least one of the story's tasks is in "tasks"
#       "weight": 6,                              W_S = sum of input + output + cache_write over those tasks (cache
#                                                 reads allocated, not weighed); null when not measured
#       "board_tasks": ["E9_S10_T01", ...] | null the tasks: list of the board's story file; null when no story file
#                                                 (or no board directory) was found
#       "measured_tasks": ["E9_S10_T01"],         the story's tasks that have transcripts
#       "unmeasured_tasks": [...] | null          board_tasks minus measured_tasks; null when board_tasks is null
#       "tasks": {input, output, cache_write, cache_read, total_tokens} | null     sum over the measured tasks
#       "allocated_overhead": {input, output, cache_write, cache_read, total_tokens}   sum of the entries' shares
#       "total": {input, output, cache_write, cache_read, total_tokens} | null     tasks + allocated_overhead
#     } }
#   "unallocated_overhead": [ {path, id, level, input, output, cache_write, cache_read, reason} ]
#       reason is "no-candidate-story" or "zero-weight"; one record per entry, none for an entry of four zeros
#
# A story with no measured task is NOT given invented numbers: measured false, weight, tasks and total null. It can
# still carry allocated_overhead, because an entry named for that story (level "story") is charged to it in full. The
# section lists every story with a measured task or a direct charge; with --stories only the requested IDs, and a
# requested ID with neither appears as measured false with an all-zero allocated_overhead.
# The sums come from the transcripts (the tasks map), never from the board: the roster only names the unmeasured tasks.
# Per field: sum of every story's allocated_overhead + sum of unallocated_overhead = sum of overhead.
# The allocation reads the UNFILTERED task set, so --task, --story and --stories never change a number in it.
#
# Entries the allocation uses: every "overhead" entry. A session directory is derived from "path" (session: the path
# without .jsonl; subagent: the path without its last two components); a story's tasks are "in the session" when one of
# their transcripts has the same session directory. See the EXACTNESS note at TU_ALLOC_JQ for the integer arithmetic.
#
# ---------------------------------------------------------------------------
# PERSIST (--persist)  -  task E76_S02_T03
# ---------------------------------------------------------------------------
# Claude Code prunes old transcripts, which would erase a task's numbers. --persist copies each measured task's totals
# into its board file (<tasks dir>/<task id>_*.md, the tasks dir from scripts/resolve-root.sh) so they survive. The
# retention policy is the user's decision of 2026-10-15 (persist only on an explicit flag, at j.close-story and at the
# end of the looping skills; mark a partly pruned total possibly incomplete); the three behaviours marked DEFAULT below
# are implementer defaults, not user decisions.
#
# What it does: the same measurement as --report (same layout checks and exit codes 4 to 8, same --task/--story
# filters), then, per measured task, ONE critical section
#     scripts/with-lock.sh <task file> -- task-usage.sh --persist-apply <task file> <id> <numbers>
# (--persist-apply is an internal mode: do not call it). Inside the lock it reads the stored fields, decides, applies
# every change to a temporary copy through skills/j-close-story/scripts/update-task-frontmatter.sh (never by hand-editing
# the file), and swaps the copy in atomically with the original file mode. The fields written are the task fields of
# E76_S01_T01: usage_input_tokens, usage_output_tokens, usage_cache_write_tokens, usage_cache_read_tokens,
# usage_total_tokens, usage_transcripts, usage_measured_on (UTC date; TASK_USAGE_TODAY=YYYY-MM-DD overrides it for
# tests) and, only as described below, usage_possibly_incomplete (the literal true, never false).
#
# Read-only unless asked: no other mode writes to a board file, creates a lock or touches the board. Every mode keeps its
# working files in a private temporary directory that is removed on exit.
#
# Decision per task, given the recomputed numbers (R) and the stored ones (S):
#   * no transcripts for the task, or any transcript mapped to it could not be read (a sum over only some of a task's
#     transcripts must not pass for its total): NOTHING is written, and a persisted value is never overwritten or
#     cleared. A requested task, or a task that already carries persisted usage, is reported on stderr as
#     "not measured ... possibly pruned" (never as zero); an unreadable transcript is a failure (exit 9). An unreadable
#     transcript is attributed to its task from the sidecar alone (the discovery step falls back to the meta when the
#     transcript cannot be read); one whose sidecar names no task cannot be attributed to any task, so it only produces
#     the report's "transcript-unreadable" warning on stderr and cannot make a task fail.
#   * S absent: write R and usage_measured_on.                                                     status persisted
#   * R equals S (the four sums and usage_transcripts): write NOTHING, so the file has no diff, usage_measured_on
#     included.                                                                                   status unchanged
#   * R below S in any of the four sums, or fewer transcripts than S.usage_transcripts (transcripts looked partly
#     pruned): KEEP the stored numbers (a stored value is never silently lowered), add usage_possibly_incomplete: true
#     if it is not there, report it on stderr. usage_measured_on is untouched: no number changed.   status kept-stored
#   * R at or above S everywhere and differing (rework added transcripts, or a session grew): rewrite the numbers,
#     usage_transcripts and usage_measured_on. A stored usage_possibly_incomplete is NEVER cleared by --persist, because
#     the earlier gap is not known to be closed.                                                    status updated
#   DEFAULT (not a user decision): "refresh on rework" is this recompute-and-never-lower rule.
#   DEFAULT (not a user decision): a recently completed task with no transcripts is reported as not measured / possibly
#     pruned rather than skipped silently, and nothing is written for it.
#   DEFAULT (not a user decision): the transcript lifetime. Claude Code's cleanupPeriodDays defaults to 30 days (setting
#     description in Claude Code 2.1.236: "Number of days to retain chat transcripts before automatic cleanup
#     (default: 30). Minimum 1"). This script does not read that setting and encodes no lifetime.
#
# The "possibly incomplete" signal, and what is NOT detected. The only signal the script implements is a REGRESSION
# AGAINST A PERSISTED BASELINE: fewer transcripts than the persisted usage_transcripts, or a lower sum, while at least
# one transcript is still found. The two other candidates of E76_S02 were validated against this machine's real
# transcripts (2026-11-06, this project's transcripts) and NOT adopted, because neither is reliable:
#   * "the parent transcript references a subagent id with no file": 584 agent ids referenced from 51 parent sessions,
#     0 without a file. Pruning appears to work on whole sessions (subagent files older than the 30-day default survive next
#     to a newer parent session file), so this signal never fired on real data and has no positive example to validate
#     against.
#   * "a developer run with no tester run for a task whose status says it was tested": 21 of 338 task-mapped tasks have
#     a developer run and no tester run, 15 of them with a tested status (2 Passed, 3 Passed with remarks, 10 Merged).
#     Nothing distinguishes pruning from a tester whose transcript maps to no task ID or runs in no subagent, so it has
#     false positives and no ground truth.
# Consequence: on the FIRST persist of a task nothing can show that its transcripts were partly pruned already; a total
# persisted then is exact only if everything was still there. usage_possibly_incomplete is set only once a later run sees
# a loss against the stored baseline. Detection beyond that is not claimed.
#
# Reporting: stdout is ONE compact JSON object {"schema_version":1,"results":[{"id","status","message"[,"file"]}]}
# with status persisted | updated | unchanged | kept-stored | not-measured | skipped | failed; stderr carries one line per
# non-trivial result and a final count line. Exit 0 when nothing failed, 8 when every requested ID has no transcripts,
# 9 when at least one task failed to persist (see EXIT CODES); persist failures never touch tasks that persisted. A task
# whose lock on its board file cannot be acquired within with-lock's timeout (WITH_LOCK_TIMEOUT_SECONDS, default 30 s)
# is skipped, reported on stderr and counted in exit 9; the lock is never bypassed or reclaimed early by this script.
# A task with transcripts but no board file (an old or foreign ID) is "skipped", not a failure.
#
# ---------------------------------------------------------------------------
# LAYOUT CHECKS (--report and --check-layout)  -  drift protection, task E76_S02_T01
# ---------------------------------------------------------------------------
# Claude Code owns the transcript format and may change it. Without these checks a changed layout finds nothing and
# prints an empty result that reads as "zero tokens". Four checks, in this order, each with its own exit code
# (see EXIT CODES); every failure message names the missing thing and the searched path:
#   1 (exit 4)  the projects directory exists and holds a directory named like this project's slug (or a
#               "<slug>--claude-worktrees-*" sibling)
#   2 (exit 5)  at least one <slug dir>/<session>/subagents/agent-*.jsonl exists
#   3 (exit 6)  every agent-<id>.jsonl has a sibling agent-<id>.meta.json that parses as a JSON object with a string
#               "agentType" and a string "name" or "description" (the three fields the mapper reads; every sidecar
#               on this machine has agentType and description, "name" is optional)
#   4 (exit 7)  every subagent transcript that maps to a TASK ID, when it has assistant lines, has at least one
#               message.usage object, and every usage object carries all four sum fields as numbers. A transcript
#               whose usage objects are all zero passes: zeros are only ever printed for a transcript that genuinely
#               reports zero usage. Assistant lines are counted on the parsed line when it mentions "usage", else by
#               the compact substring "type":"assistant" (every inspected transcript is compact JSON). A final line
#               cut off mid-write is counted as unreadable, never as a missing field.
# Checks 1 and 2 failing make 3 and 4 meaningless ("skipped"). --report stops at the first failing category;
# --check-layout evaluates 3 and 4 whenever 1 and 2 pass and reports each failed check.
#
# --check-layout verdict, ONE line of JSON on stdout (the only thing it writes there), a short human summary on
# stderr:
#   {"schema_version":1,"ok":true|false,"exit_code":0|4|5|6|7,"projects_dir":"...","project_slug":"...",
#    "transcripts":N,"checks":[{"check":1,"name":"transcript-root","status":"ok"|"fail"|"skipped","message":"...",
#    "count":N,"details":[up to 10 strings]}, ... checks 2 "subagent-transcripts", 3 "meta", 4 "usage"]}
# No transcript is aggregated and no token number is printed.
#
# ---------------------------------------------------------------------------
# OUTPUT (--list-transcripts): a JSON array sorted by "path"; every record has the same keys
# ---------------------------------------------------------------------------
#   path        absolute path of the transcript .jsonl
#   kind        "subagent" | "session"
#   slug_dir    the slug directory name it was found under (main slug or a ...--claude-worktrees-... sibling)
#   session_id  the session id (the <session> of the layout above)
#   agent_id    the id in agent-<id>, or null for a session
#   agent_type  the meta "agentType" (developer, tester, scrum-master, ...), or null (session, or not in the meta)
#   name        the meta "name", or null
#   id          the resolved board ID, or null
#   level       "task" | "story" | "epic" | "none"   ("none" for every session record and every unmapped record)
#   source      "name" | "description" | "prompt", or null
#   candidates  the distinct IDs found in the deciding source (empty when unmapped)
#   reason      null when mapped; for a session "session-level transcript: not mapped to a task"; otherwise why
#               the subagent is unmapped
#
# ---------------------------------------------------------------------------
# USAGE EXTRACTION (--usage <transcript>)  -  stage 2, task E76_S01_T03
# ---------------------------------------------------------------------------
# OUTPUT: one compact JSON object on stdout, the same keys every time:
#   path                      the transcript path as given
#   input                     fresh input tokens        = message.usage.input_tokens
#   output                    output tokens             = message.usage.output_tokens
#   cache_write               cache write tokens        = message.usage.cache_creation_input_tokens
#   cache_read                cache read tokens         = message.usage.cache_read_input_tokens
#   calls                     number of distinct API calls counted (distinct requestId values)
#   calls_without_request_id  number of additional counted units that carry no requestId (see below)
#   usage_lines               assistant lines carrying a usage object, BEFORE deduplication (lets a caller see
#                             that deduplication happened and detect a transcript with no usage at all: --usage
#                             itself yields zeros and exit 0 for one; --report and --check-layout turn it into
#                             exit 7 through the next three counters, see LAYOUT CHECKS)
#   assistant_lines           assistant lines of any kind (with or without a usage object)
#   usage_incomplete_lines    assistant lines whose usage object lacks one of the four numeric fields
#   usage_missing_fields      the sorted names of those missing fields, [] when none
#   unreadable_lines          lines that mention "usage" but are not valid JSON (for example a final line cut off
#                             while the session was still writing); they are skipped, never guessed
# The four sums are kept separate here; --report adds usage_total_tokens, defined as the sum of the four.
#
# METHOD
#   * Only lines with "type":"assistant" and an object at message.usage count; every other line (user, system,
#     attachment, assistant without usage, an unparseable line) changes no sum.
#   * DEDUPLICATION: one API call (one requestId) is written on several lines as it streams, and output_tokens
#     grows from line to line. The LAST line in file order per requestId is the call's final usage and is the only
#     one counted: the first line of such a call can understate output_tokens badly (1,243 versus 6,893 in the
#     brainstorm's test). The other counters repeat the same value on every line of a call. "Last in file order"
#     is used, not "largest"; on real data they coincide (checked below).
#   * CACHE WRITE: cache_creation_input_tokens is the total. The optional cache_creation object (1h and 5m
#     sub-fields, ephemeral_1h_input_tokens and ephemeral_5m_input_tokens) is a breakdown OF that total, so it is
#     never added on top. When the total is absent the sub-fields are summed instead, so the write is counted
#     exactly once either way. When both are present the total wins.
#   * A field that is missing or not a number counts as 0.
#   * A LINE WITHOUT A requestId (a deterministic rule that cannot double-count): the line is its own unit, keyed by
#     its "uuid" (or, when there is no uuid, by its line number), and is counted once. Lines sharing one uuid
#     collapse to the last of them. These units are reported in calls_without_request_id, never in calls. On this
#     machine such a line is an API-error placeholder (model "<synthetic>") with all counters 0, so the rule costs
#     nothing in practice.
#   * output_tokens_details.thinking_tokens is NOT added. Finding (see THINKING TOKENS).
#
# SINGLE PASS, NO WHOLE-FILE LOADING: the transcript is a stdin redirect read once by one `jq -n -R` process that
# reads ONE line at a time ("inputs"), discards a line that does not mention "usage" before parsing it, and keeps
# only a map requestId -> four numbers. Memory is bounded by the number of calls, never by the file size. The file is
# never put in an argument list or a shell variable (a 53 MB file, the largest local transcript of 4.8 MB
# repeated 11 times, took 0.75 s and 8.7 MB peak memory, 2026-10-25).
#
# IMPLEMENTATION CHOICE: jq, not Node. jq is already the dependency of stage 1 and of the repo's other scripts, and
# "last line per requestId" is a single reduce assignment (.calls[$key] = $tuple, later lines overwrite earlier
# ones), so nothing needed Node's streaming readline. Constructs used exist in jq 1.6 and later.
#
# ---------------------------------------------------------------------------
# THINKING TOKENS (verified 2026-10-25 on this machine's real transcripts under ~/.claude/projects)
# ---------------------------------------------------------------------------
# Finding: output_tokens_details.thinking_tokens is a SUBSET of output_tokens, not an addition to it, so it must not
# be added to the output sum. It appears on the later (non-first) lines of a call. Evidence over 1,048 transcripts,
# 61,805 usage lines, 29,947 requestIds (last line per requestId):
#   * 27,753 calls carry thinking_tokens; in none of them does thinking_tokens exceed output_tokens, and in none is
#     it equal to output_tokens (so a call always has non-thinking output besides the thinking).
#   * Sampling the 150 largest subagent transcripts (5,019 calls with thinking): the visible content (text plus
#     tool_use input) is 7.59 M characters against output - thinking = 3.54 M tokens, 2.1 characters per token,
#     which is a plausible rate for code and JSON; against output alone (if thinking were extra) it would be
#     1.2 characters per token, which is not. Thinking text itself is not stored in the transcript (20 K characters
#     of thinking blocks against 2.58 M thinking tokens), so the visible content is the only independent check.
#   * usage.iterations[].output_tokens sums exactly to usage.output_tokens on every call that has iterations.
# Consequence: the sums above already include thinking. "Thinking tokens are only partly visible in the usage
# fields" (E76's known approximations) stays true as a statement about breakdown: they cannot be split out as a
# separate cost, but they are not missing from the output sum.
#
# OTHER RE-VERIFIED FACTS (same data): message.usage carries input_tokens, output_tokens,
# cache_creation_input_tokens, cache_read_input_tokens on every assistant line that has usage (61,805 lines;
# the 1 of them without a requestId is the API-error placeholder above, with usage present and all zero).
# Every cache_creation object (29,947 of 29,947 calls) sums exactly to cache_creation_input_tokens. The last line
# of a call has the largest output_tokens in all 29,947 calls and output_tokens never decreases within a call. A
# requestId maps to one message.id in all 29,947 calls. Early lines of a call omit output_tokens_details,
# iterations and server_tool_use; the final line has them.
#
# bash 3.2 compatible (no associative arrays, no mapfile, no case-modifying expansions). Requires jq.
# ---------------------------------------------------------------------------

set -u

_TU_SELF="${BASH_SOURCE[0]:-$0}"
_TU_DIR="$(cd "$(dirname "$_TU_SELF")" && pwd)"

tu_usage() {
  cat <<'USAGE'
usage: task-usage.sh --list-transcripts [--projects-dir <dir>] [--project-dir <path>]
       task-usage.sh --usage <transcript.jsonl>
       task-usage.sh --report [--task <id>]... [--story <id>]... [--stories <id>]... [--allocate]
                              [--board-stories-dir <dir>] [--projects-dir <dir>] [--project-dir <path>]
       task-usage.sh --check-layout [--projects-dir <dir>] [--project-dir <path>]
       task-usage.sh --persist [--task <id>]... [--story <id>]... [--projects-dir <dir>] [--project-dir <path>]
       task-usage.sh -h | --help

  --list-transcripts    print a JSON array with one record per transcript: path, kind, agent_type, id, level,
                        source (name|description|prompt), reason
  --usage <file>        print one JSON object with the transcript's input, output, cache_write and cache_read sums
                        (last assistant line per requestId only)
  --report              print one JSON document: per-task sums (tasks), overhead, unmapped and warnings
  --check-layout        check the transcript layout, sidecar meta and usage fields without aggregating: verdict on
                        stderr, one-line JSON verdict on stdout
  --persist             measure like --report, then write each measured task's totals into its board file under
                        scripts/with-lock.sh (the only mode that writes to the board; never lowers a stored value)
  --task <id>           with --report or --persist: keep only this task (repeatable)
  --story <id>          with --report or --persist: keep only the tasks of this story (repeatable)
  --stories <id>        with --report: add the "stories" and "unallocated_overhead" sections (overhead allocated to
                        stories), narrowed to this story (repeatable); does not change the allocation
  --allocate            with --report: add those two sections for every story
  --board-stories-dir <dir>  with --report: where the board's story files are read from (task rosters)
  --projects-dir <dir>  Claude Code projects directory (default: $JENGA_PROJECTS_DIR, else ~/.claude/projects)
  --project-dir <path>  project whose transcripts to read (default: main repository of the current directory)

exit codes: 0 ok, 2 usage, 3 environment, 4 transcript root or project slug directory missing, 5 no subagent
transcripts, 6 sidecar meta missing/unparseable/incomplete, 7 usage object missing or incomplete, 8 every requested
--task/--story ID has no transcripts, 9 --persist could not persist at least one task
USAGE
}

tu_die_usage() {
  printf 'task-usage.sh: %s\n' "$1" >&2
  tu_usage >&2
  exit 2
}

tu_die_env() {
  printf 'task-usage.sh: %s\n' "$1" >&2
  exit 3
}

# Exit codes of the layout checks (see EXIT CODES and LAYOUT CHECKS in the header).
TU_EX_ROOT=4
TU_EX_NOSUB=5
TU_EX_META=6
TU_EX_USAGE=7
TU_EX_ABSENT=8
TU_EX_PERSIST=9

# --- arguments --------------------------------------------------------------------------------------------------
MODE=""
USAGE_FILE=""
PROJECTS_DIR_OPT=""
PROJECTS_DIR_OPT_SET=0
PROJECT_DIR_OPT=""
TASK_FILTERS=""    # newline-separated task IDs (--task, repeatable)
STORY_FILTERS=""   # newline-separated story IDs (--story, repeatable)
STORIES_SEL=""     # newline-separated story IDs (--stories, repeatable): narrows the "stories" section (E76_S03_T03)
ALLOCATE=0         # --allocate: add the "stories" and "unallocated_overhead" sections for every story
BOARD_STORIES_DIR_OPT=""   # --board-stories-dir: where the board's story files are read from (task rosters)
NL='
'
APPLY_ARGS=()

tu_set_mode() {
  # $1 mode being requested
  [ -z "$MODE" ] || [ "$MODE" = "$1" ] || tu_die_usage "only one mode may be given (--list-transcripts, --usage, --report, --check-layout or --persist)"
  MODE="$1"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) tu_usage; exit 0 ;;
    --list-transcripts) tu_set_mode "list-transcripts" ;;
    --report) tu_set_mode "report" ;;
    --check-layout) tu_set_mode "check-layout" ;;
    --persist) tu_set_mode "persist" ;;
    --persist-apply)
      # Internal: the critical section that --persist runs under scripts/with-lock.sh. Not a user-facing mode.
      [ $# -ge 8 ] || tu_die_usage "--persist-apply is internal and takes <file> <id> <input> <output> <cache_write> <cache_read> <transcripts>"
      tu_set_mode "persist-apply"; APPLY_ARGS=("$2" "$3" "$4" "$5" "$6" "$7" "$8"); shift 7 ;;
    --usage)
      [ $# -ge 2 ] || tu_die_usage "--usage requires a transcript path"
      tu_set_mode "usage"; USAGE_FILE="$2"; shift ;;
    --usage=*)
      tu_set_mode "usage"; USAGE_FILE="${1#--usage=}" ;;
    --task)
      [ $# -ge 2 ] || tu_die_usage "--task requires a task ID"
      TASK_FILTERS="${TASK_FILTERS}${2}${NL}"; shift ;;
    --task=*) TASK_FILTERS="${TASK_FILTERS}${1#--task=}${NL}" ;;
    --story)
      [ $# -ge 2 ] || tu_die_usage "--story requires a story ID"
      STORY_FILTERS="${STORY_FILTERS}${2}${NL}"; shift ;;
    --story=*) STORY_FILTERS="${STORY_FILTERS}${1#--story=}${NL}" ;;
    --stories)
      [ $# -ge 2 ] || tu_die_usage "--stories requires a story ID"
      STORIES_SEL="${STORIES_SEL}${2}${NL}"; shift ;;
    --stories=*) STORIES_SEL="${STORIES_SEL}${1#--stories=}${NL}" ;;
    --allocate) ALLOCATE=1 ;;
    --board-stories-dir)
      [ $# -ge 2 ] || tu_die_usage "--board-stories-dir requires a value"
      BOARD_STORIES_DIR_OPT="$2"; shift ;;
    --board-stories-dir=*) BOARD_STORIES_DIR_OPT="${1#--board-stories-dir=}" ;;
    --projects-dir)
      [ $# -ge 2 ] || tu_die_usage "--projects-dir requires a value"
      PROJECTS_DIR_OPT="$2"; PROJECTS_DIR_OPT_SET=1; shift ;;
    --projects-dir=*) PROJECTS_DIR_OPT="${1#--projects-dir=}"; PROJECTS_DIR_OPT_SET=1 ;;
    --project-dir)
      [ $# -ge 2 ] || tu_die_usage "--project-dir requires a value"
      PROJECT_DIR_OPT="$2"; shift ;;
    --project-dir=*) PROJECT_DIR_OPT="${1#--project-dir=}" ;;
    -*) tu_die_usage "unknown option: $1" ;;
    *) tu_die_usage "unexpected argument: $1" ;;
  esac
  shift
done

[ -n "$MODE" ] || tu_die_usage "no mode given (expected --list-transcripts, --usage, --report, --check-layout or --persist)"
if [ "$MODE" != "report" ] && [ "$MODE" != "persist" ] && { [ -n "$TASK_FILTERS" ] || [ -n "$STORY_FILTERS" ]; }; then
  tu_die_usage "--task and --story are only valid with --report or --persist"
fi
if [ "$MODE" != "report" ] && { [ -n "$STORIES_SEL" ] || [ "$ALLOCATE" = 1 ] || [ -n "$BOARD_STORIES_DIR_OPT" ]; }; then
  tu_die_usage "--stories, --allocate and --board-stories-dir are only valid with --report"
fi
if [ "$PROJECTS_DIR_OPT_SET" = 1 ] && [ -z "$PROJECTS_DIR_OPT" ]; then
  tu_die_usage "--projects-dir must not be empty"
fi

# --- environment ------------------------------------------------------------------------------------------------
command -v jq >/dev/null 2>&1 || tu_die_env "jq is required but was not found on PATH"
# The discovery environment (board-ID library, projects directory, project slug) is only needed by
# --list-transcripts and --report; --usage needs only jq and the transcript file.
if [ "$MODE" = "list-transcripts" ] || [ "$MODE" = "report" ] || [ "$MODE" = "check-layout" ] || [ "$MODE" = "persist" ]; then
[ -f "$_TU_DIR/lib/board-ids.sh" ] || tu_die_env "missing $_TU_DIR/lib/board-ids.sh (shared board-ID shapes)"
# shellcheck source=lib/board-ids.sh
. "$_TU_DIR/lib/board-ids.sh"

# --task / --story values must be IDs of the right shape (an empty value is rejected too).
tu_check_filter() {
  # $1 option name, $2 newline-separated values, $3 shape regex, $4 kind word, $5 example
  local v
  [ -n "$2" ] || return 0
  while IFS= read -r v; do
    [[ $v =~ $3 ]] || tu_die_usage "$1 expects a $4 ID (for example $5), got: '$v'"
  done <<FILTER_VALUES
${2%"$NL"}
FILTER_VALUES
}
tu_check_filter "--task" "$TASK_FILTERS" "$BOARD_ID_TASK_RE" "task" "E72_S01_T05"
tu_check_filter "--story" "$STORY_FILTERS" "$BOARD_ID_STORY_RE" "story" "E72_S01"
tu_check_filter "--stories" "$STORIES_SEL" "$BOARD_ID_STORY_RE" "story" "E72_S01"

if [ "$PROJECTS_DIR_OPT_SET" = 1 ]; then
  PROJECTS_DIR="$PROJECTS_DIR_OPT"
elif [ -n "${JENGA_PROJECTS_DIR:-}" ]; then
  PROJECTS_DIR="$JENGA_PROJECTS_DIR"
else
  PROJECTS_DIR="${HOME:-}/.claude/projects"
fi
# A missing projects directory is an environment error for the diagnostic --list-transcripts, but layout check 1
# (exit 4) for --report and --check-layout, which are the modes that would otherwise print an empty result.
if [ -d "$PROJECTS_DIR" ]; then
  PROJECTS_DIR="$(cd "$PROJECTS_DIR" && pwd)"
elif [ "$MODE" = "list-transcripts" ]; then
  tu_die_env "projects directory not found: $PROJECTS_DIR"
fi

# Default project: the main repository of the current directory. A worktree's git common dir lives in the main
# repository, so running from a worktree still yields the main repository's slug.
tu_default_project_dir() {
  local top common
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || { pwd -P; return; }
  common="$(cd "$top" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)" || { (cd "$top" && pwd -P); return; }
  if [ "$(basename "$common")" = ".git" ]; then dirname "$common"; else (cd "$top" && pwd -P); fi
}

if [ -n "$PROJECT_DIR_OPT" ]; then
  PROJECT_DIR="$PROJECT_DIR_OPT"
else
  PROJECT_DIR="$(tu_default_project_dir)"
fi

# Claude Code's slug: every character that is not a letter, digit or "-" becomes "-".
PROJECT_SLUG="$(printf '%s' "$PROJECT_DIR" | LC_ALL=C sed 's/[^A-Za-z0-9-]/-/g')"

# --- mapping ----------------------------------------------------------------------------------------------------
# The ID regex is built from the shared fragment; the look-arounds make an ID stand alone (see header).
TU_ID_RE="(?<![A-Za-z0-9_])${BOARD_ID_ANY_FRAGMENT}(?![A-Za-z0-9_])"
fi

# --persist and its internal critical section need the lock wrapper, the one sanctioned frontmatter writer and the day's
# date; --persist also the board's tasks directory. They are looked up relative to this script (the script and its
# helpers always ship together in the monorepo layout).
if [ "$MODE" = "persist" ] || [ "$MODE" = "persist-apply" ]; then
  TU_WITH_LOCK="$_TU_DIR/with-lock.sh"
  TU_UPDATE_FM="$_TU_DIR/../skills/j-close-story/scripts/update-task-frontmatter.sh"
  [ -f "$TU_WITH_LOCK" ] || tu_die_env "missing $TU_WITH_LOCK (the lock wrapper --persist writes under)"
  [ -f "$TU_UPDATE_FM" ] || tu_die_env "missing $TU_UPDATE_FM (the frontmatter writer --persist uses)"
  TU_TODAY="${TASK_USAGE_TODAY:-$(date -u +%Y-%m-%d)}"
  [[ $TU_TODAY =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || tu_die_env "TASK_USAGE_TODAY must be YYYY-MM-DD, got: $TU_TODAY"
fi
if [ "$MODE" = "persist" ]; then
  [ -f "$_TU_DIR/resolve-root.sh" ] || tu_die_env "missing $_TU_DIR/resolve-root.sh (the working-file path resolver)"
  TASKS_DIR="$(bash "$_TU_DIR/resolve-root.sh" get tasks 2>/dev/null)" || tu_die_env "could not resolve the board tasks directory (scripts/resolve-root.sh get tasks failed)"
  [ -d "$TASKS_DIR" ] || tu_die_env "board tasks directory not found: $TASKS_DIR (nothing is persisted)"
fi

# Reads one subagent transcript (stdin raw lines) and the meta file; prints one compact JSON record.
# The transcript is read lazily and only when the meta yields no ID, and only its first user message is parsed.
# The transcript's "cwd" is never referenced.
# shellcheck disable=SC2016  # a jq program: its $ names are jq variables, not shell expansions
TU_SUBAGENT_JQ='
def lv: [scan("_")] | length;
def pick($s):
  if ($s | type) != "string" then null
  else
    [ $s | match($re; "g") | {id: .string, off: .offset, lv: (.string | lv)} ] as $c
    | if ($c | length) == 0 then null
      else ($c | map(.lv) | max) as $m
        | { id: ($c | map(select(.lv == $m)) | sort_by(.off) | .[0].id),
            level: (["epic", "story", "task"][$m]),
            candidates: ($c | map(.id) | unique) }
      end
  end;
def firstline($t):
  if ($t | type) != "string" then null
  else ($t | split("\n") | map(select(test("\\S"))) | .[0]) end;
def promptline:
  first(inputs
        | (fromjson? // empty)
        | select(type == "object" and .type == "user" and ((.isMeta // false) | not))
        | .message.content
        | (if type == "string" then .
           elif type == "array" then (map(select(type == "object" and .type == "text") | (.text // "")) | join("\n"))
           else "" end)
        | select(test("\\S")))
  // null;
($meta | fromjson? // null) as $m
| (if ($m | type) == "object" then $m else {} end) as $mo
| ($mo.name // null) as $name
| ($mo.description // null) as $desc
| ([ (pick($name) | select(.) | . + {source: "name"}),
     (pick($desc) | select(.) | . + {source: "description"}) ] | .[0]) as $nd
| (if $nd then null else promptline end) as $pl
| (if $nd then null else (firstline($pl) | pick(.)) end) as $pp
| ($nd // (if $pp then $pp + {source: "prompt"} else null end)) as $hit
| ( if $hit then null
    else
      ( [ (if $meta_state == "missing" then "no meta.json"
           elif ($m | type) != "object" then "meta.json unreadable"
           else "no board ID in meta name or description" end),
          (if $pl == null then "no user prompt found"
           else "no board ID in first user prompt line" end) ] | join("; "))
    end ) as $reason
| { path: $path, kind: "subagent", slug_dir: $slug, session_id: $session, agent_id: $agent_id,
    agent_type: ($mo.agentType // null), name: $name,
    id: ($hit.id // null), level: ($hit.level // "none"), source: ($hit.source // null),
    candidates: ($hit.candidates // []), reason: $reason }
'

tu_emit_subagent() {
  # $1 jsonl path, $2 slug dir name, $3 session id
  local f="$1" slugdir="$2" sid="$3" base aid metaf state rec
  base="$(basename "$f" .jsonl)"
  aid="${base#agent-}"
  metaf="${f%.jsonl}.meta.json"
  if [ -f "$metaf" ]; then state="present"; else state="missing"; metaf="/dev/null"; fi
  # shellcheck disable=SC2094  # --arg path only carries the string; the file is read once, from stdin
  rec="$(jq -n -R -c --arg re "$TU_ID_RE" --arg path "$f" --arg slug "$slugdir" --arg session "$sid" \
          --arg agent_id "$aid" --arg meta_state "$state" --rawfile meta "$metaf" \
          "$TU_SUBAGENT_JQ" <"$f" 2>/dev/null)" || rec=""
  if [ -z "$rec" ]; then
    # The transcript could not be read (for example permissions), so nothing could be mapped from it. The sidecar usually
    # names the task, and --persist needs to know which task owns an unreadable transcript (a sum over only some of a
    # task's transcripts must not be persisted), so map from the sidecar alone before giving up. Only a record that
    # resolved an ID is used; anything else falls through to the unmapped fallback below, with its reason.
    # shellcheck disable=SC2094  # --arg path only carries the string; stdin is /dev/null here
    rec="$(jq -n -R -c --arg re "$TU_ID_RE" --arg path "$f" --arg slug "$slugdir" --arg session "$sid" \
            --arg agent_id "$aid" --arg meta_state "$state" --rawfile meta "$metaf" \
            "$TU_SUBAGENT_JQ" </dev/null 2>/dev/null | jq -c 'select(.id != null)' 2>/dev/null)" || rec=""
  fi
  if [ -z "$rec" ]; then
    rec="$(jq -n -c --arg path "$f" --arg slug "$slugdir" --arg session "$sid" --arg agent_id "$aid" \
      '{path: $path, kind: "subagent", slug_dir: $slug, session_id: $session, agent_id: $agent_id,
        agent_type: null, name: null, id: null, level: "none", source: null, candidates: [],
        reason: "transcript or meta could not be read"}')"
  fi
  printf '%s\n' "$rec"
}

tu_emit_session() {
  # $1 jsonl path, $2 slug dir name
  local f="$1" slugdir="$2" sid
  sid="$(basename "$f" .jsonl)"
  jq -n -c --arg path "$f" --arg slug "$slugdir" --arg session "$sid" \
    '{path: $path, kind: "session", slug_dir: $slug, session_id: $session, agent_id: null,
      agent_type: null, name: null, id: null, level: "none", source: null, candidates: [],
      reason: "session-level transcript: not mapped to a task"}'
}

tu_scan_slug_dir() {
  # $1 slug directory (absolute)
  local sd="$1" sdname f d
  sdname="$(basename "$sd")"
  for f in "$sd"/*.jsonl; do
    [ -f "$f" ] && tu_emit_session "$f" "$sdname"
  done
  for d in "$sd"/*/; do
    [ -d "${d}subagents" ] || continue
    d="${d%/}"
    for f in "$d"/subagents/agent-*.jsonl; do
      [ -f "$f" ] && tu_emit_subagent "$f" "$sdname" "$(basename "$d")"
    done
  done
}

tu_list_transcripts() {
  local sd found=0
  {
    for sd in "$PROJECTS_DIR/$PROJECT_SLUG" "$PROJECTS_DIR/$PROJECT_SLUG"--claude-worktrees-*; do
      [ -d "$sd" ] || continue
      found=1
      tu_scan_slug_dir "$sd"
    done
    if [ "$found" = 0 ]; then
      printf 'task-usage.sh: no slug directory for project %s under %s (looked for %s)\n' \
        "$PROJECT_DIR" "$PROJECTS_DIR" "$PROJECT_SLUG" >&2
    fi
  } | jq -s 'sort_by(.path)'
}

# --- usage extraction (stage 2) ----------------------------------------------------------------------------------
# Reads one transcript from stdin, one raw line at a time (-R, -n, "inputs"): a line that does not mention "usage" is
# dropped before it is parsed, and only a map  unit-key -> four numbers  is kept, so memory follows the number of
# calls, not the file size. A later line with the same key overwrites an earlier one, which is the whole
# "last line per requestId" rule. Keys: "r:<requestId>" for a call, "u:<uuid>" (or "l:<line number>") for a line
# that has no requestId. See the USAGE EXTRACTION header section for the semantics.
# shellcheck disable=SC2016  # a jq program: its $ names are jq variables, not shell expansions
TU_USAGE_JQ='
def num: if type == "number" then . else 0 end;
def tuple($u):
  { input: ($u.input_tokens | num),
    output: ($u.output_tokens | num),
    cache_write: (if ($u.cache_creation_input_tokens | type) == "number" then $u.cache_creation_input_tokens
                  elif ($u.cache_creation | type) == "object" then ([$u.cache_creation[] | num] | add // 0)
                  else 0 end),
    cache_read: ($u.cache_read_input_tokens | num) };
def key($n):
  if (.requestId | type) == "string" and .requestId != "" then "r:" + .requestId
  elif (.uuid | type) == "string" and .uuid != "" then "u:" + .uuid
  else "l:" + ($n | tostring) end;
def four_names: ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"];
reduce inputs as $raw ({n: 0, lines: 0, bad: 0, asst: 0, inc: 0, miss: {}, units: {}};
    .n += 1 | .n as $ln
    | if ($raw | contains("\"usage\"")) | not
      then (if ($raw | contains("\"type\":\"assistant\"")) then .asst += 1 else . end)
      else
        ($raw | try fromjson catch null) as $j
        | if ($j | type) != "object" then .bad += 1
          elif $j.type == "assistant" then
            .asst += 1
            | if (($j.message | type) == "object") and (($j.message.usage | type) == "object")
              then .lines += 1 | .units[$j | key($ln)] = tuple($j.message.usage)
                   | ($j.message.usage) as $u
                   | ([four_names[] | select(($u[.] | type) != "number")]) as $m
                   | if ($m | length) > 0 then .inc += 1 | .miss += ($m | map({key: ., value: true}) | from_entries) else . end
              else . end
          else . end
      end)
| . as $s
| ($s.units | to_entries) as $e
| { path: $path,
    input: ([$e[].value.input] | add // 0),
    output: ([$e[].value.output] | add // 0),
    cache_write: ([$e[].value.cache_write] | add // 0),
    cache_read: ([$e[].value.cache_read] | add // 0),
    calls: ([$e[] | select(.key | startswith("r:"))] | length),
    calls_without_request_id: ([$e[] | select(.key | startswith("r:") | not)] | length),
    usage_lines: $s.lines,
    assistant_lines: $s.asst,
    usage_incomplete_lines: $s.inc,
    usage_missing_fields: ($s.miss | keys),
    unreadable_lines: $s.bad }
'

# Prints the compact usage JSON of one transcript; returns non-zero (nothing on stdout) when it cannot be read.
tu_usage_json() {
  local f="$1"
  [ -f "$f" ] && [ -r "$f" ] || return 1
  # The transcript is a stdin redirect: read once, never an argument and never a shell variable.
  # shellcheck disable=SC2094  # --arg path only carries the string; the file is read once, from stdin
  jq -n -R -c --arg path "$f" "$TU_USAGE_JQ" <"$f" 2>/dev/null
}

tu_usage_extract() {
  local f="$1"
  [ -f "$f" ] && [ -r "$f" ] || tu_die_env "transcript not found or not readable: $f"
  tu_usage_json "$f" || tu_die_env "could not read usage from: $f"
}

# --- layout checks (drift protection, task E76_S02_T01) ----------------------------------------------------------
# State lives in a private temporary directory and in C_* variables; nothing is written to stdout while checking.
TU_TMP=""
tu_mktmp() {
  [ -z "$TU_TMP" ] || return 0
  TU_TMP="$(mktemp -d "${TMPDIR:-/tmp}/task-usage.XXXXXX")" || tu_die_env "could not create a temporary directory"
  # shellcheck disable=SC2064  # expand now: the temporary path is fixed
  trap "rm -rf '$TU_TMP'" EXIT
}

C_STATUS1=skipped; C_STATUS2=skipped; C_STATUS3=skipped; C_STATUS4=skipped
C_MSG1=""; C_MSG2=""; C_MSG3=""; C_MSG4=""
C_COUNT1=0; C_COUNT2=0; C_COUNT3=0; C_COUNT4=0
TU_NTRANS=0       # transcripts discovered (sessions and subagents)
TU_N4=0           # task-mapped transcripts that check 4 looked at

# Program for check 3, over lines "<P|M>\t<meta path>\t<meta content on one line>" (M = no sidecar). Prints one
# line per problem and nothing for a sidecar that is fine.
# shellcheck disable=SC2016  # a jq program
TU_META_JQ='
split("\t") as $p
| $p[0] as $k | $p[1] as $m | ($p[2:] | join(" ")) as $t
| if $k == "M" then $m + ": no sibling .meta.json"
  else (($t | fromjson?) // null) as $j
    | if ($j | type) != "object" then $m + ": not parseable as a JSON object"
      else ([ (if ($j.agentType | type) == "string" then empty else "agentType" end),
              (if (($j.name | type) == "string") or (($j.description | type) == "string") then empty
               else "name or description" end) ]) as $miss
           | if ($miss | length) > 0 then $m + ": lacks the field(s) the mapper reads: " + ($miss | join(", ")) else empty end
      end
  end
'

# Program for check 4, over the rows of tu_collect_rows: one line per task-mapped transcript that fails.
# shellcheck disable=SC2016  # a jq program
TU_USAGE_CHECK_JQ='
select(has("usage") and .rec.kind == "subagent" and .rec.level == "task")
| .usage as $u
| if ($u.assistant_lines > 0 and $u.usage_lines == 0)
  then .rec.path + ": " + ($u.assistant_lines | tostring) + " assistant line(s) but none carries a message.usage object"
  elif $u.usage_incomplete_lines > 0
  then .rec.path + ": " + ($u.usage_incomplete_lines | tostring) + " usage object(s) lack numeric field(s): "
       + ($u.usage_missing_fields | join(", "))
  else empty end
'

tu_searched() {
  printf '%s/%s and %s/%s--claude-worktrees-*' "$PROJECTS_DIR" "$PROJECT_SLUG" "$PROJECTS_DIR" "$PROJECT_SLUG"
}

# Checks 1 and 2. Fills $TU_TMP/slugdirs and $TU_TMP/agents (one agent-*.jsonl path per line).
tu_check_1_2() {
  local sd d f have_sub=0 list
  : >"$TU_TMP/slugdirs"
  : >"$TU_TMP/agents"
  if [ ! -d "$PROJECTS_DIR" ]; then
    C_STATUS1=fail
    C_MSG1="transcript root not found: $PROJECTS_DIR (searched there for project slug $PROJECT_SLUG; see --projects-dir and JENGA_PROJECTS_DIR)"
    return 0
  fi
  for sd in "$PROJECTS_DIR/$PROJECT_SLUG" "$PROJECTS_DIR/$PROJECT_SLUG"--claude-worktrees-*; do
    if [ -d "$sd" ]; then printf '%s\n' "$sd" >>"$TU_TMP/slugdirs"; fi
  done
  if [ ! -s "$TU_TMP/slugdirs" ]; then
    C_STATUS1=fail
    C_MSG1="no directory for project slug $PROJECT_SLUG under $PROJECTS_DIR (searched: $(tu_searched))"
    return 0
  fi
  C_STATUS1=ok
  C_COUNT1="$(grep -c '' "$TU_TMP/slugdirs")"
  C_MSG1="transcript root and project slug directory found under $PROJECTS_DIR"
  while IFS= read -r sd; do
    for d in "$sd"/*/; do
      [ -d "${d}subagents" ] || continue
      have_sub=1
      for f in "${d}subagents"/agent-*.jsonl; do
        if [ -f "$f" ]; then printf '%s\n' "$f" >>"$TU_TMP/agents"; fi
      done
    done
  done <"$TU_TMP/slugdirs"
  list="$(tr '\n' ',' <"$TU_TMP/slugdirs")"
  list="${list%,}"
  if [ ! -s "$TU_TMP/agents" ]; then
    C_STATUS2=fail
    if [ "$have_sub" = 0 ]; then
      C_MSG2="no subagents/ directory found in any session directory under: $list"
    else
      C_MSG2="no agent-*.jsonl file found in any subagents/ directory under: $list"
    fi
    return 0
  fi
  C_STATUS2=ok
  C_COUNT2="$(grep -c '' "$TU_TMP/agents")"
  C_MSG2="$C_COUNT2 subagent transcript(s) found under: $list"
}

# Check 3, over $TU_TMP/agents. One jq process for all sidecars; the sidecars are read with shell builtins.
tu_check_3() {
  local f m c
  while IFS= read -r f; do
    m="${f%.jsonl}.meta.json"
    if [ -f "$m" ]; then
      c=""
      { c="$(<"$m")"; } 2>/dev/null
      c="${c//$'\n'/ }"; c="${c//$'\r'/ }"; c="${c//$'\t'/ }"
      printf 'P\t%s\t%s\n' "$m" "$c"
    else
      printf 'M\t%s\t\n' "$m"
    fi
  done <"$TU_TMP/agents" | jq -R -r "$TU_META_JQ" >"$TU_TMP/c3"
  [ "${PIPESTATUS[1]}" = 0 ] || tu_die_env "could not check the sidecar meta files"
  C_COUNT3="$(grep -c '' "$TU_TMP/c3")"
  if [ "$C_COUNT3" -gt 0 ]; then
    C_STATUS3=fail
    C_MSG3="$C_COUNT3 of $C_COUNT2 subagent transcript(s) have a missing, unparseable or incomplete .meta.json (expected next to each agent-<id>.jsonl, a JSON object with agentType and name or description)"
  else
    C_STATUS3=ok
    C_MSG3="every subagent transcript has a parseable sidecar meta with the fields the mapper reads"
  fi
}

# Stage 1 mapping plus stage 2 usage into $TU_TMP/rows, one {"rec":..,"usage":..} (or {"rec":..,"error":..}) line
# per transcript. $1 = all: every transcript (--report needs them all); tasks: only the task-mapped subagents
# (--check-layout aggregates nothing, so it reads only what check 4 inspects).
tu_collect_rows() {
  local mode="$1" recs path rec usage tab
  tab="$(printf '\t')"
  recs="$(tu_list_transcripts)" || tu_die_env "could not list transcripts"
  TU_NTRANS="$(printf '%s' "$recs" | jq 'length')"
  # One line per transcript: its path, a tab, its stage 1 record. A tab never occurs inside the compact JSON
  # (jq escapes it); a transcript path that itself contains a tab is not supported.
  printf '%s\n' "$recs" | jq -r --arg m "$mode" \
    '.[] | select($m == "all" or (.kind == "subagent" and .level == "task")) | .path + "\t" + tojson' |
  while IFS="$tab" read -r path rec; do
    if usage="$(tu_usage_json "$path")" && [ -n "$usage" ]; then
      printf '{"rec":%s,"usage":%s}\n' "$rec" "$usage"
    else
      printf '{"rec":%s,"error":"usage could not be read"}\n' "$rec"
    fi
  done >"$TU_TMP/rows"
}

# Check 4, over $TU_TMP/rows.
tu_check_4() {
  jq -r "$TU_USAGE_CHECK_JQ" "$TU_TMP/rows" >"$TU_TMP/c4" || tu_die_env "could not check the usage fields"
  TU_N4="$(jq -s '[.[] | select(has("usage") and .rec.kind == "subagent" and .rec.level == "task")] | length' "$TU_TMP/rows")"
  C_COUNT4="$(grep -c '' "$TU_TMP/c4")"
  if [ "$C_COUNT4" -gt 0 ]; then
    C_STATUS4=fail
    C_MSG4="$C_COUNT4 of $TU_N4 task-mapped transcript(s) have no usable usage data (each file's assistant lines were read for message.usage)"
  else
    C_STATUS4=ok
    C_MSG4="$TU_N4 task-mapped transcript(s) carry complete usage objects"
  fi
}

# Runs the checks in order. $1 = all (--report: stop before check 4 when check 3 failed, and keep every transcript's
# usage for the report) or tasks (--check-layout: always run check 4, over the task-mapped transcripts only).
tu_run_checks() {
  local mode="$1"
  : >"$TU_TMP/c3"; : >"$TU_TMP/c4"; : >"$TU_TMP/rows"
  tu_check_1_2
  [ "$C_STATUS1" = ok ] && [ "$C_STATUS2" = ok ] || return 0
  tu_check_3
  if [ "$mode" = all ] && [ "$C_STATUS3" = fail ]; then return 0; fi
  tu_collect_rows "$mode"
  tu_check_4
}

# Sets TU_CODE to the exit code of the first failing check, 0 when none failed.
tu_exit_code() {
  TU_CODE=0
  if [ "$C_STATUS1" = fail ]; then TU_CODE=$TU_EX_ROOT
  elif [ "$C_STATUS2" = fail ]; then TU_CODE=$TU_EX_NOSUB
  elif [ "$C_STATUS3" = fail ]; then TU_CODE=$TU_EX_META
  elif [ "$C_STATUS4" = fail ]; then TU_CODE=$TU_EX_USAGE
  fi
}

# Prints, on stderr, one block per failed check: its message and up to five of its details.
tu_print_failures() {
  local n code msg status det total
  for n in 1 2 3 4; do
    case "$n" in
      1) status="$C_STATUS1"; msg="$C_MSG1"; code=$TU_EX_ROOT;  det="" ;;
      2) status="$C_STATUS2"; msg="$C_MSG2"; code=$TU_EX_NOSUB; det="" ;;
      3) status="$C_STATUS3"; msg="$C_MSG3"; code=$TU_EX_META;  det="$TU_TMP/c3" ;;
      4) status="$C_STATUS4"; msg="$C_MSG4"; code=$TU_EX_USAGE; det="$TU_TMP/c4" ;;
    esac
    [ "$status" = fail ] || continue
    printf 'task-usage.sh: layout check %s failed (exit %s): %s\n' "$n" "$code" "$msg" >&2
    if [ -n "$det" ] && [ -s "$det" ]; then
      head -n 5 "$det" | sed 's/^/  /' >&2
      total="$(grep -c '' "$det")"
      if [ "$total" -gt 5 ]; then printf '  ... and %s more\n' "$((total - 5))" >&2; fi
    fi
  done
}

# One check as a compact JSON object: number, name, status, message, count, details (first ten).
tu_check_json() {
  local det='[]'
  if [ -n "$6" ] && [ -s "$6" ]; then
    det="$(head -n 10 "$6" | jq -R -s -c 'split("\n") | map(select(length > 0))')"
  fi
  jq -n -c --argjson n "$1" --arg name "$2" --arg status "$3" --arg msg "$4" --argjson count "$5" --argjson det "$det" \
    '{check: $n, name: $name, status: $status, message: $msg, count: $count, details: $det}'
}

tu_check_layout() {
  local checks ok=false
  tu_mktmp
  tu_run_checks tasks
  tu_exit_code
  checks="$(
    tu_check_json 1 transcript-root "$C_STATUS1" "$C_MSG1" "$C_COUNT1" ""
    tu_check_json 2 subagent-transcripts "$C_STATUS2" "$C_MSG2" "$C_COUNT2" ""
    tu_check_json 3 meta "$C_STATUS3" "$C_MSG3" "$C_COUNT3" "$TU_TMP/c3"
    tu_check_json 4 usage "$C_STATUS4" "$C_MSG4" "$C_COUNT4" "$TU_TMP/c4"
  )"
  [ "$TU_CODE" = 0 ] && ok=true
  # Human verdict first (stderr), then the single JSON line (stdout), after every check has run.
  if [ "$TU_CODE" = 0 ]; then
    printf 'task-usage.sh: layout check passed: %s transcript(s) discovered, %s task-mapped transcript(s) checked, project slug %s under %s\n' \
      "$TU_NTRANS" "$TU_N4" "$PROJECT_SLUG" "$PROJECTS_DIR" >&2
  else
    tu_print_failures
    printf 'task-usage.sh: layout check FAILED (exit %s)\n' "$TU_CODE" >&2
  fi
  printf '%s\n' "$checks" | jq -s -c --argjson ok "$ok" --argjson code "$TU_CODE" --arg dir "$PROJECTS_DIR" \
    --arg slug "$PROJECT_SLUG" --argjson n "$TU_NTRANS" \
    '{schema_version: 1, ok: $ok, exit_code: $code, projects_dir: $dir, project_slug: $slug, transcripts: $n, checks: .}'
  exit "$TU_CODE"
}

# --- overhead allocation (task E76_S03_T03) -----------------------------------------------------------------------
# The rule is project/documentation/task-usage.md, "Allocating overhead to stories"; this block only implements it.
# The jq function definitions below are prepended to TU_REPORT_JQ. They run on the UNFILTERED task set ($all_tasks)
# and the complete overhead list, before --task/--story narrow what "tasks" prints, and only when the sections were
# asked for (--stories or --allocate): the default report is unchanged.
#
# EXACTNESS. A share is floor(T x W_S / W) and its remainder is (T x W_S) mod W, and T x W_S can exceed 2^53, where
# jq's IEEE doubles stop being exact. muldiv therefore returns exact integers: when the double product is below 2^53
# it is itself exact (jq's % is an integer remainder), otherwise T x W_S is multiplied out in decimal digits and
# divided by W digit by digit (the running remainder stays below W, so rem x 10 + 9 is exact while W < 1e14). No
# floating-point fraction or comparison of fractions is ever used; ties are therefore real ties. Real data has W
# around 1e9 to 1e10; a W or a field total at or above the bounds fails the run loudly instead of rounding.
# shellcheck disable=SC2016  # a jq program: its $ names are jq variables, not shell expansions
TU_ALLOC_JQ='
def f4: ["input", "output", "cache_write", "cache_read"];
def zero4: {input: 0, output: 0, cache_write: 0, cache_read: 0};
def skey: capture("^E(?<e>[0-9]+)_S(?<s>[0-9]+)") | [(.e | tonumber), (.s | tonumber)];
def bigdigits: tostring | explode | map(. - 48) | reverse;
def bigmul($a; $b):
  reduce range(0; ($a | length)) as $i
    ([range(0; ($a | length) + ($b | length)) | 0];
     reduce range(0; ($b | length)) as $j (.; .[$i + $j] += $a[$i] * $b[$j]))
  | reduce range(0; length) as $k
      (.; if .[$k] >= 10 then (.[$k + 1] += ((.[$k] / 10) | floor)) | (.[$k] %= 10) else . end);
def muldiv($t; $ws; $w):
  if $t >= 9007199254740992 or $w >= 100000000000000
  then error("task-usage.sh: overhead allocation bound exceeded (field total " + ($t | tostring) + ", weight " + ($w | tostring) + ")")
  else ($t * $ws) as $p
    | if $p < 9007199254740992
      then ($p % $w) as $r | { q: (($p - $r) / $w), r: $r }
      else (bigmul($t | bigdigits; $ws | bigdigits) | reverse) as $n
        | reduce $n[] as $d ({q: 0, r: 0};
            (.r * 10 + $d) as $cur
            | (($cur / $w) | floor) as $g
            | ($cur - $g * $w) as $rem
            | (if $rem < 0 then {g: ($g - 1), rem: ($rem + $w)}
               elif $rem >= $w then {g: ($g + 1), rem: ($rem - $w)}
               else {g: $g, rem: $rem} end) as $f
            | .q = .q * 10 + $f.g | .r = $f.rem)
      end
  end;
# Largest-remainder split of one field total $t over candidates $c ([{s, key, w}]) with weight sum $w.
def split_field($t; $c; $w):
  ( $c | map(. as $x | muldiv($t; $x.w; $w) as $m | $x + {q: $m.q, r: $m.r}) ) as $d
  | ($t - ($d | map(.q) | add)) as $l
  | ($d | sort_by([-.r, .key[0], .key[1]]) | .[0:$l] | map(.s)) as $plus
  | $d | map(. as $x | {key: $x.s, value: ($x.q + (if ($plus | index($x.s)) != null then 1 else 0 end))}) | from_entries;
def tu_alloc($ov; $at):
  ( reduce $at[] as $t ({}; .[$t.value.story_id] += ($t.value.input + $t.value.output + $t.value.cache_write)) ) as $wmap
  | ( reduce $at[] as $t ({};
        reduce ($t.value.transcripts[] | split("/") | .[:-2] | join("/")) as $d
          (.; .[$d] = ((.[$d] // []) + [$t.value.story_id])))
      | map_values(unique) ) as $sess
  | ( reduce $ov[] as $e ({shares: [], unalloc: []};
        ($e | {input, output, cache_write, cache_read}) as $amt
        | ($amt | map(. != 0) | any) as $nonzero
        | if $e.level == "story" and (($e.id | type) == "string") and ($e.id | test("^E[0-9]+_S[0-9]+$"))
          then .shares += [{story: $e.id} + $amt]
          else
            ( $sess[ (if $e.kind == "session" then ($e.path | sub("\\.jsonl$"; ""))
                      else ($e.path | split("/") | .[:-2] | join("/")) end) ] // [] ) as $cs
            | ($cs | map({s: ., key: (. | skey), w: $wmap[.]})) as $c
            | ($c | map(.w) | add // 0) as $w
            | (if ($cs | length) == 0 then "no-candidate-story" elif $w == 0 then "zero-weight" else null end) as $why
            | if $why != null
              then (if $nonzero
                    then .unalloc += [{path: $e.path, id: $e.id, level: $e.level} + $amt + {reason: $why}]
                    else . end)
              else
                (reduce f4[] as $f ({}; .[$f] = split_field($amt[$f]; $c; $w))) as $sp
                | .shares += [ $c[] | .s as $s | {story: $s} + (reduce f4[] as $f ({}; .[$f] = $sp[$f][$s])) ]
              end
          end) ) as $r
  | { alloc: ( reduce $r.shares[] as $x ({};
                 .[$x.story] = (reduce f4[] as $f (.[$x.story] // zero4; .[$f] += $x[$f]))) ),
      unalloc: $r.unalloc };
def with_total: . + {total_tokens: (.input + .output + .cache_write + .cache_read)};
# The "stories" section. $board is the roster text ("S<TAB><story id><TAB><task>,<task>,..." per story file),
# $sel the requested story IDs ([] = every story that has a measured task or a direct charge).
def tu_stories($al; $at; $board; $board_ok; $sel):
  ( reduce $at[] as $t ({};
      .[$t.value.story_id] |= ((. // {tasks: [], sum: zero4, weight: 0})
        | .tasks += [$t.key]
        | .sum = (reduce f4[] as $f (.sum; .[$f] += $t.value[$f]))
        | .weight += ($t.value.input + $t.value.output + $t.value.cache_write))) ) as $m
  | ( if $board_ok
      then ( $board | split("\n") | map(select(length > 0) | split("\t"))
             | map({key: .[1], value: ((.[2] // "") | split(",") | map(select(test("^E[0-9]+_S[0-9]+_T[0-9]+$"))))})
             | from_entries )
      else {} end ) as $bm
  | ( if ($sel | length) > 0 then ($sel | unique)
      else ((($m | keys) + ($al.alloc | keys)) | unique) end ) as $ids
  | ($ids | sort_by(skey)) as $sorted
  | $sorted | map( . as $id
      | ($m[$id]) as $mm
      | ($al.alloc[$id] // zero4 | with_total) as $ao
      | ($bm[$id]) as $bt
      | { key: $id,
          value: { epic_id: ($id | split("_")[0]),
                   measured: ($mm != null),
                   weight: ($mm.weight // null),
                   board_tasks: $bt,
                   measured_tasks: ($mm.tasks // []),
                   unmeasured_tasks: (if $bt == null then null else ($bt - ($mm.tasks // [])) end),
                   tasks: (if $mm then ($mm.sum | with_total) else null end),
                   allocated_overhead: $ao,
                   total: (if $mm then (reduce f4[] as $f ({}; .[$f] = ($mm.sum[$f] + $ao[$f])) | with_total) else null end) } } )
  | from_entries;
'

# Fills $TU_TMP/board with one line per board story file, "S<TAB><story id><TAB><task>,<task>,...", read from the
# frontmatter (id: and the tasks: list, block or inline form) of project/board/stories/E*_S*.md, and sets TU_BOARD_OK.
# The directory is --board-stories-dir, else $JENGA_BOARD_STORIES_DIR, else <project dir>/project/board/stories. A
# missing directory is not an error: the roster is information only (the sums never depend on it), TU_BOARD_OK is
# false and every board_tasks is null. Reads nothing when the stories section was not asked for.
TU_WANT_STORIES=false
TU_BOARD_OK=false
tu_board_roster() {
  local dir
  : >"$TU_TMP/board"
  if [ "$ALLOCATE" = 1 ] || [ -n "$STORIES_SEL" ]; then TU_WANT_STORIES=true; else return 0; fi
  if [ -n "$BOARD_STORIES_DIR_OPT" ]; then dir="$BOARD_STORIES_DIR_OPT"
  elif [ -n "${JENGA_BOARD_STORIES_DIR:-}" ]; then dir="$JENGA_BOARD_STORIES_DIR"
  else dir="$PROJECT_DIR/project/board/stories"; fi
  [ -d "$dir" ] || return 0
  TU_BOARD_OK=true
  find "$dir" -maxdepth 1 -type f -name 'E*_S*.md' -print0 2>/dev/null | LC_ALL=C xargs -0 awk '
    function clean(v) { sub(/[ \t]+#.*/, "", v); gsub(/[\[\]"\047 \t\r]/, "", v); return v }
    function flush() { if (id != "") printf "S\t%s\t%s\n", id, tl; id = ""; tl = "" }
    FNR == 1 { flush(); fm = 0; intasks = 0 }
    /^---[ \t\r]*$/ { fm++; if (fm == 2) flush(); next }
    fm != 1 { next }
    /^id:/ { v = $0; sub(/^id:[ \t]*/, "", v); id = clean(v); intasks = 0; next }
    /^tasks:/ {
      v = $0; sub(/^tasks:[ \t]*/, "", v)
      if (v ~ /^\[/) { n = split(clean(v), a, ","); for (i = 1; i <= n; i++) if (a[i] != "") tl = tl a[i] ","; intasks = 0 }
      else intasks = 1
      next
    }
    intasks && /^[ \t]*-[ \t]/ { v = $0; sub(/^[ \t]*-[ \t]*/, "", v); v = clean(v); if (v != "") tl = tl v ","; next }
    intasks && /^[ \t]*#/ { next }
    { intasks = 0 }
    END { flush() }' >"$TU_TMP/board" || true
}

# --- report (stage 3) --------------------------------------------------------------------------------------------
# Input to the program (jq -s): one object per transcript, {rec: <stage 1 record>, usage: <stage 2 object>} or
# {rec: ..., error: "..."} when the usage could not be read. See the REPORT header section for the contract.
# shellcheck disable=SC2016  # a jq program: its $ names are jq variables, not shell expansions
TU_REPORT_JQ='
def four: {input: .input, output: .output, cache_write: .cache_write, cache_read: .cache_read};
def sum4: { input: (map(.usage.input) | add // 0), output: (map(.usage.output) | add // 0),
            cache_write: (map(.usage.cache_write) | add // 0), cache_read: (map(.usage.cache_read) | add // 0) };
def lines: split("\n") | map(select(length > 0));
($tasks_f | lines) as $tf
| ($stories_f | lines) as $sf
| [ .[] | select(has("usage") and .usage.assistant_lines > 0) ] as $ok
| [ .[] | select(has("usage") and .usage.assistant_lines == 0) ] as $none
| [ .[] | select(has("usage") | not) ] as $bad
| [ $ok[] | select(.rec.kind == "subagent" and .rec.level == "task") ] as $tk
| ( $tk | group_by(.rec.id)
    | map( (.[0].rec.id) as $id | sum4 as $s
           | { key: $id,
               value: ( { story_id: ($id | split("_")[0:2] | join("_")), epic_id: ($id | split("_")[0]) }
                        + $s
                        + { usage_total_tokens: ($s.input + $s.output + $s.cache_write + $s.cache_read),
                            usage_transcripts: length,
                            transcripts: (map(.rec.path) | sort) } ) } ) ) as $all_tasks
| ($all_tasks | map(.key)) as $task_ids
| ($all_tasks | map(.value.story_id) | unique) as $story_ids
| ( [ $ok[]
      | select(.rec.kind == "session"
               or (.rec.kind == "subagent" and (.rec.level == "story" or .rec.level == "epic")))
      | { kind: .rec.kind, agent_type: .rec.agent_type, id: .rec.id, level: .rec.level }
        + (.usage | four) + { path: .rec.path } ]
    | sort_by(.path) ) as $overhead
| ( if $want_stories then tu_alloc($overhead; $all_tasks) else null end ) as $al
| { schema_version: 1,
    generated_at: $now,
    tasks: ( $all_tasks
             | map(select( (($tf | length) == 0 or (.key as $k | $tf | index($k) != null))
                           and (($sf | length) == 0 or (.value.story_id as $k | $sf | index($k) != null)) ))
             | from_entries ),
    overhead: $overhead,
    unmapped: ( [ $ok[]
                  | select(.rec.kind == "subagent" and .rec.level == "none")
                  | { kind: .rec.kind, agent_type: .rec.agent_type, name: .rec.name, reason: .rec.reason }
                    + (.usage | four) + { path: .rec.path } ]
                | sort_by(.path) ),
    warnings: ( [ $tf[] | select(. as $i | $task_ids | index($i) | not)
                  | {code: "no-transcripts-for-task", id: ., message: ("no transcripts map to task " + .)} ]
                + [ $sf[] | select(. as $i | $story_ids | index($i) | not)
                    | {code: "no-transcripts-for-story", id: ., message: ("no transcripts map to a task of story " + .)} ]
                + [ $bad[] | {code: "transcript-unreadable", path: .rec.path,
                              message: ("usage could not be read from " + .rec.path + "; excluded from every sum")} ]
                + [ $none[] | {code: "transcript-without-usage", path: .rec.path,
                               message: ("no assistant line in " + .rec.path + "; excluded from every sum, not counted as zero")} ] )
  }
| if $al then . + { stories: tu_stories($al; $all_tasks; $board; $board_ok; $sel_f | lines),
                     unallocated_overhead: ($al.unalloc | sort_by(.path)) } else . end
'

tu_report() {
  local now nreq
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tu_mktmp
  tu_run_checks all
  tu_exit_code
  if [ "$TU_CODE" != 0 ]; then
    tu_print_failures
    if [ "$MODE" = persist ]; then printf 'task-usage.sh: nothing was persisted\n' >&2; fi
    exit "$TU_CODE"
  fi
  # The whole report is built in a temporary file and printed last, so nothing reaches stdout before every
  # failure check (above and below) has passed.
  tu_board_roster
  jq -s -c --arg now "$now" --arg tasks_f "$TASK_FILTERS" --arg stories_f "$STORY_FILTERS" \
    --arg sel_f "$STORIES_SEL" --argjson want_stories "$TU_WANT_STORIES" \
    --rawfile board "$TU_TMP/board" --argjson board_ok "$TU_BOARD_OK" \
    "${TU_ALLOC_JQ}${TU_REPORT_JQ}" "$TU_TMP/rows" >"$TU_TMP/out" || tu_die_env "could not build the report"
  # Zero versus absent: when every requested ID has no transcripts there is nothing to report, so say so.
  nreq="$(printf '%s%s' "$TASK_FILTERS" "$STORY_FILTERS" | grep -c .)"
  if [ "$nreq" -gt 0 ] && jq -e --argjson n "$nreq" \
       '[.warnings[] | select(.code | startswith("no-transcripts-for-"))] | length == $n' "$TU_TMP/out" >/dev/null; then
    jq -r '.warnings[] | "task-usage.sh: warning: " + .message' "$TU_TMP/out" >&2
    printf 'task-usage.sh: no transcripts found for the requested ID(s): %s (searched %s)\n' \
      "$(jq -r '[.warnings[] | select(.code | startswith("no-transcripts-for-")) | .id] | join(", ")' "$TU_TMP/out")" \
      "$(tu_searched)" >&2
    if [ "$MODE" = persist ]; then
      printf 'task-usage.sh: not measured (possibly pruned); nothing was persisted and any persisted values are untouched\n' >&2
    fi
    exit "$TU_EX_ABSENT"
  fi
  # Human-readable notes on stderr only, one per warning.
  jq -r '.warnings[] | "task-usage.sh: warning: " + .message' "$TU_TMP/out" >&2
  if [ "$MODE" = persist ]; then tu_persist; else cat "$TU_TMP/out"; fi
}


# --- persist (task E76_S02_T03) ----------------------------------------------------------------------------------
# See the PERSIST header section for the contract. Two halves: tu_persist (outside any lock: which tasks, which board
# file, one lock per file, the summary) and tu_persist_apply (inside the lock: read, decide, write).

# Prints the value of frontmatter key $2 in file $1 (between the first two --- lines), empty when absent or empty.
tu_fm_get() {
  awk -v k="$2" '
    /^---[ \t]*$/ { n++; if (n == 2) exit; next }
    n == 1 { i = index($0, ":")
             if (i > 0 && substr($0, 1, i - 1) == k) {
               v = substr($0, i + 1); sub(/^[ \t]+/, "", v); sub(/[ \t\r]+$/, "", v); print v; exit } }
  ' "$1"
}

# Runs inside scripts/with-lock.sh. $1 task file, $2 id, $3-$6 recomputed input/output/cache_write/cache_read,
# $7 recomputed transcript count. Prints ONE line on stdout, "persist-status: <status>", and the human messages on
# stderr. Without a status line on stdout the caller treats the run as failed. Exit 0 whenever a status was printed.
tu_persist_apply() {
  local file="$1" id="$2" r_in="$3" r_out="$4" r_cw="$5" r_cr="$6" r_nt="$7"
  local v have=0 lower=0 same=1 r_total flag
  local s_in s_out s_cw s_cr s_nt s_tot
  for v in "$r_in" "$r_out" "$r_cw" "$r_cr" "$r_nt"; do
    case "$v" in ''|*[!0-9]*) printf 'task-usage.sh: %s: internal error, non-numeric measurement\n' "$id" >&2; return 1 ;; esac
  done
  [ -f "$file" ] || { printf 'task-usage.sh: %s: board file vanished: %s\n' "$id" "$file" >&2; return 1; }
  r_total=$((r_in + r_out + r_cw + r_cr))
  s_in="$(tu_fm_get "$file" usage_input_tokens)"
  s_out="$(tu_fm_get "$file" usage_output_tokens)"
  s_cw="$(tu_fm_get "$file" usage_cache_write_tokens)"
  s_cr="$(tu_fm_get "$file" usage_cache_read_tokens)"
  s_nt="$(tu_fm_get "$file" usage_transcripts)"
  s_tot="$(tu_fm_get "$file" usage_total_tokens)"
  flag="$(tu_fm_get "$file" usage_possibly_incomplete)"
  for v in "$s_in" "$s_out" "$s_cw" "$s_cr" "$s_nt" "$s_tot"; do
    [ -z "$v" ] && continue
    have=1
    case "$v" in
      *[!0-9]*)
        printf 'task-usage.sh: %s: a stored usage value is not a plain integer (%s in %s); nothing written\n' "$id" "$v" "$file" >&2
        printf 'persist-status: failed\n'; return 0 ;;
    esac
  done
  : "${s_in:=0}" "${s_out:=0}" "${s_cw:=0}" "${s_cr:=0}" "${s_nt:=0}"

  if [ "$have" = 1 ]; then
    if [ "$r_in" -lt "$s_in" ] || [ "$r_out" -lt "$s_out" ] || [ "$r_cw" -lt "$s_cw" ] || [ "$r_cr" -lt "$s_cr" ] \
       || [ "$r_nt" -lt "$s_nt" ]; then
      lower=1
    fi
    if [ "$r_in" != "$s_in" ] || [ "$r_out" != "$s_out" ] || [ "$r_cw" != "$s_cw" ] || [ "$r_cr" != "$s_cr" ] \
       || [ "$r_nt" != "$s_nt" ]; then
      same=0
    fi
    if [ "$lower" = 1 ]; then
      printf 'task-usage.sh: %s: recomputed %s transcript(s) / %s tokens is below the persisted %s / %s (possibly pruned): kept the persisted values' \
        "$id" "$r_nt" "$r_total" "$s_nt" "$((s_in + s_out + s_cw + s_cr))" >&2
      if [ "$flag" = true ]; then
        printf ' (usage_possibly_incomplete already true)\n' >&2
        printf 'persist-status: kept-stored\n'; return 0
      fi
      printf ' and set usage_possibly_incomplete: true\n' >&2
      tu_apply_write "$file" "$id" usage_possibly_incomplete true || return 1
      printf 'persist-status: kept-stored\n'; return 0
    fi
    if [ "$same" = 1 ]; then
      printf 'persist-status: unchanged\n'; return 0
    fi
  fi

  tu_apply_write "$file" "$id" \
    usage_input_tokens "$r_in" usage_output_tokens "$r_out" usage_cache_write_tokens "$r_cw" \
    usage_cache_read_tokens "$r_cr" usage_total_tokens "$r_total" usage_transcripts "$r_nt" \
    usage_measured_on "$TU_TODAY" || return 1
  if [ "$have" = 1 ]; then printf 'persist-status: updated\n'; else printf 'persist-status: persisted\n'; fi
}

# tu_apply_write <file> <id> <key> <value> [<key> <value>]...: applies every pair to a temporary copy through
# update-task-frontmatter.sh and swaps the copy in only when all of them succeeded, so a failing write leaves the board
# file exactly as it was. The writer replaces a file through mv from a 0600 temp file, so the original mode is restored.
tu_apply_write() {
  local file="$1" id="$2" tmp mode
  shift 2
  tmp="$(mktemp "${file}.persist.XXXXXX")" || { printf 'task-usage.sh: %s: could not create a temporary copy next to %s\n' "$id" "$file" >&2; return 1; }
  # shellcheck disable=SC2064  # expand now: the temporary path is fixed
  trap "rm -f '$tmp'" EXIT
  cp -p "$file" "$tmp" || { printf 'task-usage.sh: %s: could not copy %s\n' "$id" "$file" >&2; return 1; }
  while [ $# -ge 2 ]; do
    bash "$TU_UPDATE_FM" "$tmp" "$1" "$2" >/dev/null || {
      printf 'task-usage.sh: %s: update-task-frontmatter.sh failed on %s; %s not changed\n' "$id" "$1" "$file" >&2; return 1; }
    shift 2
  done
  mode="$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file" 2>/dev/null)"
  mv "$tmp" "$file" || { printf 'task-usage.sh: %s: could not replace %s\n' "$id" "$file" >&2; return 1; }
  trap - EXIT
  case "$mode" in ''|*[!0-7]*) ;; *) chmod "$mode" "$file" 2>/dev/null || true ;; esac
}

# Appends one result {id,status,message[,file]} to $TU_TMP/results.
tu_result() {
  jq -n -c --arg id "$1" --arg st "$2" --arg msg "$3" --arg file "${4:-}" \
    '{id: $id, status: $st, message: $msg} + (if $file == "" then {} else {file: $file} end)' >>"$TU_TMP/results"
}

# Sets TU_BFILE to the one board file of task $1 and returns 0; returns 1 for none, 2 for several.
tu_board_file() {
  local f n=0
  TU_BFILE=""
  for f in "$TASKS_DIR/$1"_*.md; do
    [ -f "$f" ] || continue
    n=$((n + 1)); TU_BFILE="$f"
  done
  [ "$n" = 1 ] && return 0
  TU_BFILE=""
  [ "$n" = 0 ] && return 1
  return 2
}

# True when the non-empty word $2 is a whole line of the newline-separated list $1.
tu_in_list() {
  [ -n "$2" ] || return 1
  printf '%s\n' "$1" | grep -qx -- "$2"
}

# Persists the tasks of the report in $TU_TMP/out and reports the ones that were asked for but have no measurement.
tu_persist() {
  local tab id in out cw cr nt st rc failed_ids measured_ids cand stored status f
  local n_new=0 n_upd=0 n_same=0 n_kept=0 n_skip=0 n_nm=0 n_fail=0
  tab="$(printf '\t')"
  : >"$TU_TMP/results"
  : >"$TU_TMP/cands"
  # Tasks with a transcript that could not be read: their sum is partial, so nothing may be persisted for them.
  failed_ids="$(jq -r 'select(has("usage") | not) | select(.rec.kind == "subagent" and .rec.level == "task") | .rec.id' "$TU_TMP/rows" | sort -u)"
  measured_ids="$(jq -r '.tasks | keys[]' "$TU_TMP/out")"

  # 1. every measured task
  while IFS="$tab" read -r id in out cw cr nt; do
    # An empty tasks map still feeds the loop one empty line; there is nothing to persist then.
    [ -n "$id" ] || continue
    if tu_in_list "$failed_ids" "$id"; then
      printf 'task-usage.sh: %s: a transcript of this task could not be read, so its sum would be partial: not measured, nothing written\n' "$id" >&2
      tu_result "$id" failed "a transcript of this task could not be read; nothing written"
      continue
    fi
    tu_board_file "$id"; rc=$?
    if [ "$rc" = 1 ]; then
      tu_result "$id" skipped "no board file for this task ID; nothing written"
      continue
    elif [ "$rc" = 2 ]; then
      printf 'task-usage.sh: %s: more than one board file matches under %s: nothing written\n' "$id" "$TASKS_DIR" >&2
      tu_result "$id" failed "more than one board file matches this task ID; nothing written"
      continue
    fi
    f="$TU_BFILE"
    st="$(bash "$TU_WITH_LOCK" "$f" -- bash "$_TU_SELF" --persist-apply "$f" "$id" "$in" "$out" "$cw" "$cr" "$nt" </dev/null)"
    rc=$?
    status="$(printf '%s\n' "$st" | sed -n 's/^persist-status: //p' | head -n 1)"
    if [ -n "$status" ] && [ "$status" != failed ]; then
      case "$status" in
        persisted)   st="usage fields written for the first time" ;;
        updated)     st="usage fields rewritten upward (rework or a longer session)" ;;
        unchanged)   st="recomputed totals equal the persisted ones; nothing written" ;;
        kept-stored) st="recomputed totals are below the persisted ones (possibly pruned); persisted values kept, usage_possibly_incomplete: true" ;;
        *)           st="$status" ;;
      esac
      tu_result "$id" "$status" "$st" "$f"
    elif [ "$status" = failed ]; then
      tu_result "$id" failed "a stored usage value is not a plain integer; nothing written" "$f"
    elif [ "$rc" = 2 ] && [ -z "$status" ]; then
      printf 'task-usage.sh: %s: could not acquire the lock on %s: write skipped (the lock is never bypassed)\n' "$id" "$f" >&2
      tu_result "$id" failed "lock on the board file not acquired; write skipped" "$f"
    else
      printf 'task-usage.sh: %s: write failed for %s (exit %s)\n' "$id" "$f" "$rc" >&2
      tu_result "$id" failed "write failed; the board file is unchanged" "$f"
    fi
  done <<TU_PERSIST_ROWS
$(jq -r '.tasks | to_entries[] | [.key, .value.input, .value.output, .value.cache_write, .value.cache_read, .value.usage_transcripts] | @tsv' "$TU_TMP/out")
TU_PERSIST_ROWS

  # 2. asked for but not measured: requested tasks, the tasks of requested stories, and (with no filter) every task that
  #    already carries persisted usage. Never a zero, never a write.
  { printf '%s' "$TASK_FILTERS"
    # a task with an unreadable transcript is always reported, filtered or not
    printf '%s\n' "$failed_ids"
    if [ -n "$STORY_FILTERS" ]; then
      while IFS= read -r id; do
        [ -n "$id" ] || continue
        for f in "$TASKS_DIR/$id"_T*_*.md; do
          [ -f "$f" ] && basename "$f" | sed -E 's/^(E[0-9]+_S[0-9]+_T[0-9]+)_.*/\1/'
        done
      done <<TU_STORY_IDS
${STORY_FILTERS%"$NL"}
TU_STORY_IDS
    fi
    if [ -z "$TASK_FILTERS" ] && [ -z "$STORY_FILTERS" ]; then
      for f in "$TASKS_DIR"/E*_S*_T*_*.md; do
        [ -f "$f" ] || continue
        [ -n "$(tu_fm_get "$f" usage_transcripts)" ] && basename "$f" | sed -E 's/^(E[0-9]+_S[0-9]+_T[0-9]+)_.*/\1/'
      done
    fi
  } | grep . | sort -u >"$TU_TMP/cands"
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    tu_in_list "$measured_ids" "$cand" && continue
    if tu_in_list "$failed_ids" "$cand"; then
      printf 'task-usage.sh: %s: a transcript of this task could not be read: not measured, nothing written\n' "$cand" >&2
      tu_result "$cand" failed "a transcript of this task could not be read; nothing written"
      continue
    fi
    if ! tu_board_file "$cand"; then
      if printf '%s' "$TASK_FILTERS" | grep -qx "$cand"; then
        printf 'task-usage.sh: %s: not measured (no transcripts found, and no board file for this task); nothing written\n' "$cand" >&2
        tu_result "$cand" not-measured "no transcripts found and no board file; nothing written"
      fi
      continue
    fi
    f="$TU_BFILE"
    stored="$(tu_fm_get "$f" usage_transcripts)"
    if [ -n "$stored" ]; then
      printf 'task-usage.sh: %s: not measured, possibly pruned (no transcripts found, %s persisted): the persisted values are untouched\n' "$cand" "$stored" >&2
      tu_result "$cand" not-measured "no transcripts found, possibly pruned; the persisted values are untouched" "$f"
    elif printf '%s' "$TASK_FILTERS" | grep -qx "$cand"; then
      printf 'task-usage.sh: %s: not measured (no transcripts found, possibly pruned); nothing written\n' "$cand" >&2
      tu_result "$cand" not-measured "no transcripts found, possibly pruned; nothing written" "$f"
    else
      case "$(tu_fm_get "$f" status)" in
        Pending|"In Progress"|Blocked) ;;
        *)
          printf 'task-usage.sh: %s: not measured (no transcripts found, possibly pruned); nothing written\n' "$cand" >&2
          tu_result "$cand" not-measured "no transcripts found, possibly pruned; nothing written" "$f" ;;
      esac
    fi
  done <"$TU_TMP/cands"

  jq -s -c '{schema_version: 1, results: .}' "$TU_TMP/results" >"$TU_TMP/summary"
  n_new="$(jq '[.results[] | select(.status == "persisted")] | length' "$TU_TMP/summary")"
  n_upd="$(jq '[.results[] | select(.status == "updated")] | length' "$TU_TMP/summary")"
  n_same="$(jq '[.results[] | select(.status == "unchanged")] | length' "$TU_TMP/summary")"
  n_kept="$(jq '[.results[] | select(.status == "kept-stored")] | length' "$TU_TMP/summary")"
  n_skip="$(jq '[.results[] | select(.status == "skipped")] | length' "$TU_TMP/summary")"
  n_nm="$(jq '[.results[] | select(.status == "not-measured")] | length' "$TU_TMP/summary")"
  n_fail="$(jq '[.results[] | select(.status == "failed")] | length' "$TU_TMP/summary")"
  printf 'task-usage.sh: persist: %s persisted, %s updated, %s unchanged, %s kept (possibly pruned), %s not measured, %s skipped, %s failed\n' \
    "$n_new" "$n_upd" "$n_same" "$n_kept" "$n_nm" "$n_skip" "$n_fail" >&2
  cat "$TU_TMP/summary"
  [ "$n_fail" = 0 ] || exit "$TU_EX_PERSIST"
}

case "$MODE" in
  list-transcripts) tu_list_transcripts ;;
  usage) tu_usage_extract "$USAGE_FILE" ;;
  report|persist) tu_report ;;
  check-layout) tu_check_layout ;;
  persist-apply) tu_persist_apply "${APPLY_ARGS[@]}" ;;
esac
