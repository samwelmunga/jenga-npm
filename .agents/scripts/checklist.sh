#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/checklist.sh - pre-flight checklist checker (epic E67, story E67_S02)
#
# The single shared implementation of the pre-flight checklist scan. A gating skill calls this script
# instead of describing the scan in prose, so the decision is mechanical and identical across models,
# sessions and skills and no SKILL.md ever restates the logic below. The registry file format is defined
# by preflight-checklists.md in the project documentation directory (the "documentation" path key of the
# working-file registry); that document is the contract for the data and this header is the contract for the checker.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   scripts/checklist.sh list  <situation> [--run <run-id>]
#   scripts/checklist.sh check <situation> [--run <run-id>]
#   scripts/checklist.sh tick  <id> [--run <run-id>] [--note <text>] [--by <actor>]
#   scripts/checklist.sh tick  --clear <id> [--run <run-id>]
#   scripts/checklist.sh suggest --origin <precautionary|recurrence> --evidence <text> [--incident <ref>]
#                         --id <id> --text <text> --situation <s> [--situation <s>...] --kind <machine|judgment>
#                         [--verify <cmd>] --enforcement <e> --tick-scope <t> [--slug <s>] [--task <E##_S##_T##>] [--by <actor>]
#   scripts/checklist.sh pending
#   scripts/checklist.sh rejected [--id <item-id>]
#   scripts/checklist.sh resolve <rapport> accepted|rejected [--reason <text>] [--by <actor>]
#   scripts/checklist.sh -h | --help | help       print this usage on stdout, exit 0
#
# <situation> is a lifecycle phase: one of the base vocabulary (pre-commit, pre-task, pre-release,
# pre-reconcile) or a name declared in the loaded registry file's own top-level "situations".
#
# ---------------------------------------------------------------------------
# SUBCOMMANDS
# ---------------------------------------------------------------------------
# list <situation> [--run <run-id>]   IMPLEMENTED (E67_S02_T01; --run added by E67_S02_T03)
#   --run <run-id> (or JENGA_CHECKLIST_RUN_ID) names the run whose run-scoped ticks are shown; without it
#   run-scoped items read as unticked. Same for check. See "WHAT A RUN IS".
#   Prints the items whose situations[] contains <situation>, in registry order, one per line, with five
#   TAB-separated fields:
#       <id> <TAB> <text> <TAB> <kind> <TAB> <enforcement> <TAB> <tick state>
#   kind is machine|judgment, enforcement is block|confirm|advisory, tick state is the value of
#   tick_state_of for that item (see "TICK STATE" below: "unticked", or "ticked(<scope>) by <actor> at <time>").
#   Tabs and newlines inside an item's text are flattened to single spaces so one item is always exactly one line. list only
#   reads: it never runs a verify command and never writes a file.
#
#   Nothing to list is NOT an error. All of the following print nothing and exit 0, with no warning:
#   no registry file at all, a registry with an empty items array, a known situation that no item names.
#   A project that authored no items must see nothing.
#
# check <situation> [--run <run-id>]   IMPLEMENTED (E67_S02_T02; --run added by E67_S02_T03)
#   Runs the applicable items and reports one JSON object per item, so a calling skill branches on
#   structured data instead of parsing prose. The exit code is the enforcement backstop: a caller that
#   ignores stdout still cannot walk through a hard block. Applicable items are chosen exactly as list
#   chooses them (same registry selection, same validate-first, same unknown-situation exit 3).
#
#   STDOUT is exactly one JSON array (pretty-printed, ASCII-only so hostile verify output can never
#   corrupt it), in registry order, and nothing else. It is valid JSON in every outcome that reaches the
#   check stage, including "nothing applies", which prints [] and exits 0 with no warning (no registry file,
#   empty items, or a known situation no item names). When the run stops before the check stage (invalid
#   registry, unknown situation, usage error) stdout is empty and the exit code says why. All human-readable
#   diagnostics go to STDERR.
#
#   Each element has these keys:
#       id, text, kind, enforcement, tick_scope   copied from the registry item
#       tick_state     what tick_state_of returned ("unticked" or anything else, see "TICK STATE")
#       result         passed | failed | requires_confirmation | already_ticked
#       action         proceed | halt | prompt | remind   (what the gated action must do about this item)
#       reason         one human-readable line; for a failure it carries the cause and a bounded excerpt
#       cause          null, or why a machine item failed: nonzero_exit | not_found | not_executable |
#                      timeout | signal | spawn_error
#       exit_status    the verify command's exit status, or null when it did not run or did not exit
#
#   result and action, per doc section 6:
#       machine, verify exits 0                          passed                 proceed
#       machine, verify fails (any cause)   block        failed                 halt
#                                           confirm      failed                 prompt
#                                           advisory     failed                 remind
#       judgment (never satisfiable by the script alone)
#                                           block        requires_confirmation  halt
#                                           confirm      requires_confirmation  prompt
#                                           advisory     requires_confirmation  remind
#       already ticked (any kind/enforcement)            already_ticked         proceed
#   A judgment item is NEVER reported as passed: the script cannot confirm it. For a block judgment item
#   "halt" means "halt unless the user confirms it" (doc section 6: confirm or stop).
#
#   An item that is already ticked is satisfied (doc section 7): its verify is not re-run and a judgment
#   item is not re-asked. See "TICK STATE". Ticking itself is the tick subcommand below.
#
#   How a verify command is run
#     - as `bash -c <verify>`, from the resolved project root (scripts/resolve-root.sh root, not $PWD),
#       with stdin from /dev/null so it can never hang waiting for input;
#     - in its own process group, so a timeout (or the end of the command) kills the command AND every
#       process it spawned; nothing is left orphaned. The kill is SIGKILL on the whole group. Consequently a
#       verify must not start a deliberately long-lived background process;
#     - bounded by DEFAULT_VERIFY_TIMEOUT_SECS (below). timeout(1) is not used: macOS does not ship it. The
#       timer is python3's subprocess wait, which python3 (already required) provides on every platform;
#     - with its stdout and stderr drained but only the first VERIFY_OUTPUT_CAP_BYTES of each retained, so a
#       verify that prints megabytes cannot grow memory or the JSON. The reason then holds at most
#       REASON_EXCERPT_CHARS characters of stderr (or stdout when stderr is empty), whitespace-collapsed
#       and with control characters removed;
#     - under the caller's own LC_ALL (this script's own LC_ALL=C is not leaked into the command).
#
#   Missing, non-executable and timed-out commands are failures with their own cause, never passes:
#       not_found       the first word is a path that does not exist, or the shell exited 127
#       not_executable  the first word is a path that exists but is not executable (or is a directory), or
#                       the shell exited 126
#       timeout         the command ran past the timeout
#   The 126/127 mapping is by shell exit status, so a script that itself deliberately exits 126 or 127 is
#   reported as not_executable/not_found; the reason's stderr excerpt shows the real message. Known limit: a
#   verify that masks its own failure (for instance `! missing-command`, or `cmd || true`) is a pass, because
#   exit status is all there is to score. A verify must be written so that failure is a non-zero status.
#
#   TRUST MODEL. verify strings are executed as shell. They come from the registry, which is repository
#   content. Treat the registry as trusted policy, exactly like a Makefile or a package.json script: anyone
#   who can edit it can run commands as the user who runs the checker. Never run check against a registry
#   from an untrusted source (an unreviewed pull request, a downloaded template you have not read). No
#   sandboxing is attempted; validation checks structure, not safety.
#
#   Exit code summary for check (full table in "EXIT CODES"): 0 nothing blocks, 10 a block item is
#   unsatisfied, 11 only confirm items need a user decision, plus the shared codes 1, 2, 3, 4, 5.
#
# tick <id> [--run <run-id>] [--note <text>] [--by <actor>]   IMPLEMENTED (E67_S02_T03)
#   Records that item <id> was satisfied: the tick itself, who or what recorded it, when (UTC, to the second)
#   and the note when --note is given (at most NOTE_MAX_BYTES). Prints one confirmation line on stdout and
#   exits 0. Ticking an item that is already ticked refreshes the tick (actor, time and note are replaced).
#   <id> must be an id in the selected registry (same selection and validate-first as list); an id that is not
#   there exits 6 with a message naming the id and the known ids.
#
#   tick does NOT verify the item. It is the caller's job to tick only a satisfied item (doc section 6): a
#   machine item after check reported it passed, a judgment item after the user confirmed it. The actor and
#   note exist so that the record says who took that responsibility.
#
#   Actor: --by <actor>, else the JENGA_CHECKLIST_ACTOR environment variable, else "os-user:<login>". The default
#   only names the operating-system account running the script; it cannot tell a person from an agent acting
#   for them, so agents should pass --by (for instance "agent:developer" or their session id). An actor is 1 to
#   128 characters of letters, digits and . _ : @ / + - (anything else exits 2).
#
#   Run id (run-scoped items): see "WHAT A RUN IS". A run-scoped item cannot be ticked without a run id (exit 7).
#   A persistent item needs none and ignores one.
#
# tick --clear <id> [--run <run-id>]   removes a tick (the only way a persistent tick ends, besides editing the item)
#   Removes <id>'s tick from the persistent store and, when --run is given, from that run's file as well. It is
#   idempotent: nothing to remove prints "no tick recorded for <id>" and still exits 0. It does not consult the
#   registry, so a tick for an item that was since deleted from the registry can still be removed and a broken
#   registry cannot prevent un-ticking. --note and --by are rejected with --clear. The file-level alternative
#   (delete one run file, or the whole tick-state directory) is always safe: the worst outcome is that items are
#   evaluated again.
#
# ---------------------------------------------------------------------------
# SUGGESTIONS (E67_S05_T02): suggest, pending, rejected, resolve
# ---------------------------------------------------------------------------
# Agents never write the checklist registry. A developer or tester that sees a risk (origin "precautionary") or
# wants to stop an issue that already happened from happening again (origin "recurrence") only SUGGESTS an item, by
# filing a Type: checklist_suggestion rapport (templates/PROBLEM_RAPPORT_TEMPLATE.md). Only the Scrum Master turns an
# accepted suggestion into a registry item, after the user confirms, and attaches the item's provenance block then.
# These four subcommands are the deterministic part of that flow. NONE of them reads or writes the registry's items
# (suggest only reads the registry, to learn its declared situations and existing ids), and there is no store of their
# own: state lives on the rapports. The rapports directory is "$(scripts/resolve-root.sh get rapports_problems)".
#
# suggest   --origin <precautionary|recurrence> --evidence "<text>" [--incident <ref>] <item fields> [--slug <s>]
#           [--task <E##_S##_T##>] [--by <actor>]
#   Item fields: --id, --text, --situation (repeat for several), --kind, --verify (machine items only),
#   --enforcement, --tick-scope: the checklists.json item shape (see the schema document). Prints the path of the rapport
#   it wrote, and nothing else, on stdout. It REFUSES, writing nothing, with these checks made in this order (the first
#   to fail is reported):
#       usage (2)   --origin missing or not precautionary|recurrence, a flag with no value, an unknown flag, a bad
#                   --by actor or --task
#       20          --evidence missing, empty or whitespace-only (both origins need a concrete, checkable fact)
#       21          origin recurrence and no --incident
#       22          the proposed item is not schema-valid, or its id is already an item of the loaded registry. The
#                   item is validated by scripts/validate-checklists.sh itself (a temporary one-item registry; its
#                   problem lines are printed), without a provenance block, against the base situations plus those the
#                   loaded registry declares (same registry selection as list). A missing field is reported by the
#                   validator as such: the script does not default any item field.
#       23          --incident does not name an incident. The same validator rule is applied to it (a rapport path
#                   rapports/<...>.md, a commit SHA of 7 to 40 hex characters, or a task id E##_S##_T##): a synthetic
#                   suggested/recurrence provenance whose evidence is exactly the reference is validated, so the
#                   rule is the validator's and is not duplicated. Checked whenever --incident is given, either origin.
#       24          an item with the same id was already REJECTED: a rejected suggestion is not re-proposed
#       25          the rapport could not be written
#   File name: <slug>-checklist-suggestion.md in the rapports directory, <slug> being --slug (else the item id),
#   lower-cased, every run of characters outside a-z0-9 turned into one hyphen, trimmed and capped at 64 characters, so
#   no input can name a path outside the directory. An existing file is NEVER replaced: the content is written to a
#   temp file and hard-linked into place (atomic, exclusive: it appears whole or not at all), and if the name is taken
#   (two agents suggesting the same slug at once) the name falls back to
#   <slug>-checklist-suggestion-<UTC stamp>-<6 random hex>.md. The directory is created if missing. Evidence and
#   incident are collapsed to one line and rendered as blockquotes, so no input can forge a heading (in particular the
#   outcome heading below); the proposed item is rendered as JSON, which escapes everything.
#   The rapport carries the template's header (Date, Agent, Related Epic/Story/Task, Type: `checklist_suggestion`) plus
#   "**Origin:**", "**Proposed Item ID:**", "**Suggested By:**" and "**Suggested At:**" (UTC) header lines, then the
#   template's Sender, Summary, Proposed Item (fenced JSON), Evidence, Originating Incident (when given), Impact,
#   Suggested Next Steps and an untouched Ignore Log placeholder. --task fills the Related fields (else N/A).
#
# pending   (no arguments)
#   Lists suggestion rapports that have no recorded outcome, skipping every *.IGNORE.md (the same convention as
#   hooks/on_session_end.sh). A rapport is a suggestion rapport when its first 40 lines hold a "**Type:**" line naming
#   checklist_suggestion; scaffolded or hand-written, symlinks never followed. One line per rapport, oldest first (then
#   by path), four TAB-separated fields:
#       <path> <TAB> <origin> <TAB> <proposed item id> <TAB> <age>
#   path is the rapports directory joined with the file name; origin and item id are "-" when the rapport lacks
#   them; age is time since "Suggested At" (else the header Date, else the file's mtime), as a whole number of the
#   largest fitting unit with a suffix: 45s, 12m, 5h, 3d. Nothing pending (or no rapports directory) prints nothing,
#   exits 0, no warning.
#
# resolve   <rapport> accepted|rejected [--reason "<text>"] [--by <actor>]
#   Records the outcome ON the rapport, in a section named "## Suggestion Outcome" (Outcome, Resolved By, Resolved At,
#   Reason when given), appended after the existing content. It is never the template's "## Ignore Log", which is
#   reserved for fully resolving a rapport by renaming it to .IGNORE.md; every earlier byte of the rapport (the Ignore
#   Log included) is left exactly as it was. <rapport> is a path or a file name inside the rapports directory; it must
#   be a suggestion rapport directly inside that directory and not *.IGNORE.md (else exit 26). The read-modify-write
#   runs under scripts/with-lock.sh on the rapport and the file is replaced atomically. An already-resolved rapport is
#   NEVER overwritten, not even with the same outcome: exit 27, existing outcome reported. A resolved rapport no
#   longer appears in pending. "accepted" records the outcome ONLY: it does not write checklists.json (the Scrum
#   Master does that). Prints "resolved <path> as <outcome>". --reason is flattened to one line (at most NOTE_MAX_BYTES).
#
# rejected  [--id <item-id>]
#   The "was an equivalent item already rejected?" check for the Scrum Master. Lists suggestion rapports whose recorded
#   outcome is rejected (optionally only those for one item id), same order as pending, five TAB-separated fields:
#       <path> <TAB> <origin> <TAB> <proposed item id> <TAB> <resolved at (UTC)> <TAB> <reason>
#   (reason "-" when none). Nothing to list prints nothing, exits 0. suggest uses the same data to refuse (24) an id that
#   was rejected; "equivalent" beyond an identical id remains the Scrum Master's judgment, informed by this listing.
#
# ---------------------------------------------------------------------------
# WHICH REGISTRY FILE IS READ (decided in E67_S02_T01)
# ---------------------------------------------------------------------------
# The schema defines one file and no precedence between the shipped default and the project instance;
# this is the precedence. The selection is WHOLE-FILE, never item-level:
#   1. If the project instance exists, it is the registry:
#        "$(scripts/resolve-root.sh get configs)/checklists.json"
#      (resolved through the root resolver, never a hardcoded working-tree literal). The shipped default is
#      then not read at all, and not even consulted. An existing project instance with an empty items
#      array is a deliberate "nothing applies here" and does NOT fall back to the default.
#   2. Only when no project instance exists, the shipped default templates/checklists.json is the registry.
#   3. If neither exists there is no registry: list prints nothing and exits 0.
# Items from the two files are NEVER merged, concatenated or overridden by id. Merging (and any rule for
# what an id collision would mean) is out of scope; a project that wants the shipped items alongside its
# own copies them into its instance. Rationale: the schema validates each file on its own and declares
# that nothing is inherited between files; whole-file selection keeps "which items apply" answerable by
# opening exactly one file, and keeps the shipped default free to change without silently altering a
# project's own checklist.
#
# The shipped default is located package-relative first ($SCRIPT_DIR/../templates, as resolve-tools.sh
# finds its own assets), then by the repository's dual-path idiom (templates/checklists.json when it
# exists, otherwise node_modules/@jenga-ai/agent/templates/checklists.json), because in a consumer project
# templates/ lives inside the installed package. Package-relative goes first so a consumer project's own
# unrelated templates/ directory can never be mistaken for the shipped default.
#
# ---------------------------------------------------------------------------
# VALIDATE FIRST (decided in E67_S02_T01)
# ---------------------------------------------------------------------------
# Before reading any item, the selected file is run through scripts/validate-checklists.sh. An invalid
# registry (malformed JSON, missing field, unknown kind, ...) exits 1 with the validator's own
# "<file>: <message>" lines on stderr plus a one-line "invalid registry" note; nothing is listed. This
# gives a user a specific, actionable message instead of a Python traceback or half a listing, and means
# the listing code below may assume a structurally valid file. The cost is one extra python3 start per
# call. Validation covers only the file actually selected, never the one that was not.
#
# Unknown situation: if a registry file was loaded and <situation> is neither a base situation nor
# declared in that file's top-level "situations", list exits 3 with a message naming the situation and
# listing the known ones. This is distinct from the empty-result case (exit 0, silent). With no registry
# file at all there is nothing that could declare an extension, so the call is silent and exits 0 for any
# well-formed situation name.
#
# ---------------------------------------------------------------------------
# TICK STATE (E67_S02_T03)
# ---------------------------------------------------------------------------
# tick_state_of <id> <scope> (defined below) is the ONE place tick state is read; list and check both go through
# it. It prints exactly "unticked", or "ticked(<scope>) by <actor> at <UTC time>". It never fails: anything it
# cannot read (a corrupt or unreadable state file, an unresolvable directory) degrades to "unticked" with a
# warning on stderr, never to a traceback and never to a pass, because a broken lookup must make a check run,
# not skip it. One warning is printed per affected item, since each lookup is independent.
#
# How check reads the seam (E67_S02_T02): it calls tick_state_of once per applicable item BEFORE running
# anything. An empty answer or exactly "unticked" means not ticked (the item is evaluated); any other answer
# means the item is ticked (it is reported already_ticked, with the answer as tick_state, and neither verified
# nor asked).
#
# WHAT A RUN IS (the crux, decided deliberately)
#   A run is one execution of a gated phase by one orchestrating session. Nothing in the script can observe
#   where a run starts or ends, so the CALLER names it: it picks a run id when it begins the phase, passes that
#   same id to every check, list and tick of that phase (--run <id>, or JENGA_CHECKLIST_RUN_ID; the option wins),
#   and picks a NEW id for the next execution. The wiring that does this is E67_S03's job. An id must be unique
#   per execution (for example "<session id>-<situation>-<UTC timestamp>"); reusing one is the one way to leak a
#   tick into a later run, and is documented as a caller bug. A run id is 1 to 128 characters of letters, digits,
#   dot, colon, underscore or hyphen, starting with a letter or digit (anything else exits 2).
#
#   Why an explicit id and not an implicit one (a default id, the date, the parent PID, ...): any default shared
#   by two runs would make a run-scoped tick written in one visible in the next, which is exactly the leak
#   tick_scope "run" exists to prevent. So a run-scoped tick with no run id is an ERROR (exit 7), not a fallback.
#   Reading is the safe mirror image: list/check with no run id see every run-scoped item as unticked, so they
#   evaluate it (a forgotten --run costs a re-verification, never a skipped check). A run tick can therefore only
#   be written under, and read back with, one exact id.
#
#   A run "ends" when its caller stops using its id. Its tick is then unreachable from the next run (a new id),
#   which is the observable behaviour doc section 7 requires, and the file is deleted by the idle-TTL pruning
#   below. There is deliberately no end-of-run command to forget to call.
#
# WHERE STATE LIVES
#   Directory: "$(scripts/resolve-root.sh get queue)/checklist-ticks/" (test seam: JENGA_CHECKLIST_STATE_DIR),
#   resolved through the root resolver, never a hardcoded working-tree literal. Not under the configs directory:
#   that path is not blocklisted in .publicignore and would ship downstream through /j-mirror-public, while tick
#   state is private operational state. The queue directory is blocklisted, and .gitignore ignores this
#   subdirectory's contents (all but .gitkeep), so tick state is never committed. The directory is created by
#   the first tick; list and check never create anything.
#     persistent.json          every persistent tick, one shared file
#     run-<digest>.json        one file per run id (digest = first 24 hex characters of sha256 of the run id)
#     <name>.lock.d            with-lock.sh's lock directory next to the file being written
#     .tmp-<name>.<pid>        a write in flight (renamed over <name> when complete)
#     persistent.json.corrupt  the last unusable store, moved aside (see below)
#   Both files are JSON: {"version": 1, "run_id": "<id>" (run files only), "ticks": {"<item id>": record}} where
#   a record is {definition_hash, tick_scope, ticked_by, ticked_at, note}.
#   "Survives a queue sweep": the only sweeping in the queue today is scoped to other subdirectories
#   (sweep-stale-context-digests.sh to context/, on_session_end.sh to handoffs/), none to this one. Any future
#   queue-wide sweep must exclude checklist-ticks/persistent.json.
#   Known limit: state is rooted at the resolved project root. A session running inside a git worktree resolves
#   that worktree's own tree, so ticks made there are not shared with the main tree (set JENGA_PROJECT_ROOT to
#   share one root) and a persistent tick made in a worktree disappears with it.
#
# HOW CONCURRENT SESSIONS ARE KEPT FROM CLOBBERING EACH OTHER
#   - Per-run state is one file per run id, so two concurrent runs never touch the same file (the same fix as
#     E37_S01's per-session handoffs/, which replaced the single shared .session_handoff.json whose last writer
#     silently won).
#   - persistent.json is genuinely shared, and a run file can be shared by parallel workers of one run. Every
#     read-modify-write of either goes through scripts/with-lock.sh <file> -- <command>: a mkdir-based lock (not
#     flock, which macOS lacks), so two ticks of different items both land and neither overwrites the other.
#     If the lock cannot be acquired within with-lock.sh's timeout, the tick is NOT recorded and exits 8; it is
#     never written unlocked.
#   - Readers (list, check) take no lock: a writer writes a temp file in the same directory, fsyncs it and
#     renames it over the target, so a reader sees a whole old or whole new file, never half of one.
#
# WHAT A TICK IS BOUND TO
#   Each record stores sha256 of the item's kind, text and verify (canonical JSON). A tick whose stored hash no
#   longer matches the registry item is treated as absent (stderr: the item was edited after it was ticked), so
#   tightening a rule's wording or command can never be satisfied by an old acknowledgement. The stale record
#   stays in the file until the item is ticked again or --clear removes it. Editing enforcement, situations or
#   tick_scope does not invalidate a tick.
#
# CORRUPTION
#   An unreadable, non-JSON or wrongly shaped state file is read as "unticked" with a warning. The next tick of
#   that file moves it aside to <name>.corrupt (one file, overwritten each time, so it cannot accumulate) and
#   starts a fresh one. Nothing here ever makes a corrupt file pass an item.
#
# BOUNDING THE ACCUMULATION OF RUN FILES
#   Every successful tick prunes: a run file whose last write is older than RUN_STATE_TTL_MINUTES is deleted,
#   each deletion re-checked under that file's own lock (so a tick that races the prune keeps its file), along
#   with .tmp-* files and .lock.d directories that old (crashed writers). A run file is also treated as
#   unticked on read once that old, so even a reused id cannot see a tick older than the TTL. The TTL is an idle
#   TTL (measured from the run's last tick) and generous (one day) because a run is an orchestrated phase that
#   may be long. The pruning only ever matches run-*.json: it cannot touch persistent.json or a younger run
#   file. Pruning is best effort and never fails the tick.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   success: list ran; or check ran and no applicable block item is unsatisfied and no applicable
#       confirm item needs a decision (advisory failures and unconfirmed advisory judgment items do not
#       count). Includes "nothing to list" / "nothing applies".
#   1   the selected registry is invalid or unreadable, or the configs/root directory could not be resolved
#   2   usage error (no subcommand, unknown subcommand, wrong arguments, bad timeout or TTL override, bad run id,
#       actor, item id or note)
#   3   unknown situation (list, check)
#   4   python3 is not installed
#   5   internal error in the check runner (a bug; stdout is empty)
#   10  check: at least one applicable block item is unsatisfied (a failed machine item, or a judgment
#       item that is not confirmed). The gated action MUST NOT proceed. Takes precedence over 11.
#   11  check: no block item is unsatisfied, but at least one applicable confirm item is (failed machine
#       item or unconfirmed judgment item): the user must be asked. Treat as "do not proceed silently".
#   6   tick: <id> is not an item of the selected registry (or there is no registry)
#   7   tick: the item is run-scoped and no run id was given
#   8   tick: the tick was NOT recorded because the state directory could not be created, its lock could not be
#       acquired, or the write failed (--clear: the tick was not removed)
#       (70, "tick not yet implemented", is retired: tick is implemented)
#   20  suggest: --evidence missing or empty (nothing written)
#   21  suggest: origin recurrence with no --incident (nothing written)
#   22  suggest: the proposed item is not schema-valid, or its id is already in the registry (nothing written)
#   23  suggest: --incident names no incident (nothing written)
#   24  suggest: an item with this id was already rejected (nothing written)
#   25  suggest, resolve: the rapport could not be written (resolve: the outcome was not recorded)
#   26  resolve: <rapport> not found, outside the rapports directory, not a suggestion rapport, or an .IGNORE.md
#   27  resolve: the rapport already has an outcome (left untouched)
#   28  resolve: the rapport's lock could not be acquired; the outcome was NOT recorded
#   (pending and rejected use only 0, 1 and 2; suggest/pending/rejected/resolve also use 1 when the rapports
#   directory cannot be resolved, 2 for usage errors, 4 when python3 is missing, 5 for an internal error.)
# A caller that only distinguishes zero from non-zero is therefore always on the safe side.
#
# ---------------------------------------------------------------------------
# ENVIRONMENT (test seams, in the style of render-ranked-list.sh; unset in normal use)
# ---------------------------------------------------------------------------
#   JENGA_CHECKLISTS_FILE           use this path as the project instance instead of
#                                   <configs>/checklists.json (skips the root resolver)
#   JENGA_CHECKLISTS_DEFAULT_FILE   use this path as the shipped default instead of locating
#                                   templates/checklists.json
#   JENGA_CHECKLIST_VERIFY_TIMEOUT  override DEFAULT_VERIFY_TIMEOUT_SECS for check (positive number of
#                                   seconds, fractions allowed; anything else exits 2)
# Not test seams (normal interface):
#   JENGA_CHECKLIST_RUN_ID          the run id, when --run is not given (see "WHAT A RUN IS")
#   JENGA_CHECKLIST_ACTOR           the actor recorded by tick, when --by is not given
# Test seams for the tick store:
#   JENGA_CHECKLIST_STATE_DIR       use this directory for tick state instead of <queue>/checklist-ticks
#   JENGA_CHECKLIST_RUN_TTL_MINUTES override RUN_STATE_TTL_MINUTES (positive number of minutes; else exits 2)
# Test seams for the suggestion rapports:
#   JENGA_CHECKLIST_RAPPORTS_DIR    use this directory instead of "$(resolve-root.sh get rapports_problems)"
#   JENGA_CHECKLIST_NOW             the current time for stamps and ages, UTC, as 2026-10-03T12:00:00Z (else exits 2)
# with-lock.sh's own WITH_LOCK_* variables apply to the tick store's locks.
#
# CONSTANTS (tunable, deliberately not inline literals)
#   DEFAULT_VERIFY_TIMEOUT_SECS  60    wall-clock limit for one verify command. Generous because a verify
#                                      may run a validator or a linter; a verify that needs longer is
#                                      doing too much for a gate that fires on every commit.
#   VERIFY_OUTPUT_CAP_BYTES      4096  bytes retained per stream (the rest is read and discarded)
#   REASON_EXCERPT_CHARS         240   characters of output quoted in a failing item's reason
#   RUN_STATE_TTL_MINUTES        1440  idle time after which a run's tick file is expired and pruned. Modelled on
#                                      slot_ttl_minutes in scope-thresholds.json (a crash-leak guard), but not read
#                                      from it and no key was added there; longer because a run is a whole phase.
#   NOTE_MAX_BYTES               2000  limit on a tick's --note
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions).
# ---------------------------------------------------------------------------

set -u
# Remember the caller's locale before forcing LC_ALL=C for this script's own text handling: verify commands
# run under the caller's locale, not ours (see check, "How a verify command is run").
if [ "${LC_ALL+set}" = "set" ]; then
  CALLER_LC_ALL="$LC_ALL"
  CALLER_LC_ALL_SET=1
else
  CALLER_LC_ALL=""
  CALLER_LC_ALL_SET=0
fi
export LC_ALL=C

DEFAULT_VERIFY_TIMEOUT_SECS=60
VERIFY_OUTPUT_CAP_BYTES=4096
REASON_EXCERPT_CHARS=240
RUN_STATE_TTL_MINUTES=1440
NOTE_MAX_BYTES=2000
STATE_SUBDIR="checklist-ticks"
PERSISTENT_FILE_NAME="persistent.json"
RUN_ID_PATTERN='^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'
ACTOR_PATTERN='^[A-Za-z0-9._:@/+-]{1,128}$'
ITEM_ID_PATTERN='^[a-z0-9]+(-[a-z0-9]+)*$'

# Per-invocation tick context (set from the command line / environment, read by tick_state_of).
RUN_ID="${JENGA_CHECKLIST_RUN_ID:-}"
RUN_TTL_MINUTES="${JENGA_CHECKLIST_RUN_TTL_MINUTES:-$RUN_STATE_TTL_MINUTES}"
TICK_REGISTRY=""
STATE_DIR=""

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'USAGE'
usage:
  checklist.sh list  <situation> [--run <run-id>]
  checklist.sh check <situation> [--run <run-id>]
  checklist.sh tick  <id> [--run <run-id>] [--note <text>] [--by <actor>]
  checklist.sh tick  --clear <id> [--run <run-id>]
  checklist.sh suggest --origin <precautionary|recurrence> --evidence <text> [--incident <ref>] --id <id> --text <text>
                       --situation <s> [--situation <s>...] --kind <machine|judgment> [--verify <cmd>]
                       --enforcement <e> --tick-scope <t> [--slug <s>] [--task <E##_S##_T##>] [--by <actor>]
  checklist.sh pending
  checklist.sh rejected [--id <item-id>]
  checklist.sh resolve <rapport> accepted|rejected [--reason <text>] [--by <actor>]
  checklist.sh -h | --help | help

situations: pre-commit, pre-task, pre-release, pre-reconcile, plus any the registry declares.
list prints "<id> <TAB> <text> <TAB> <kind> <TAB> <enforcement> <TAB> <tick state>" per applicable item.
check prints one JSON array (one object per applicable item) and exits 0, 10 (a block item is unsatisfied)
or 11 (a confirm item needs a decision); it runs verify commands from the registry as shell (trusted policy).
tick records that an item was satisfied; a run-scoped item needs --run <run-id> (or JENGA_CHECKLIST_RUN_ID), a
persistent one does not. tick --clear removes a tick.
suggest files a checklist_suggestion rapport (it never writes the registry) and refuses without evidence, or a recurrence
without an incident. pending lists unresolved suggestions; resolve records accepted|rejected on one; rejected lists rejected ones.
Full contract: the header comment of this script.
USAGE
}

# ---------------------------------------------------------------------------
# Tick store (E67_S02_T03). Layout, keying and locking are specified in the header's "TICK STATE" section.
#
# One python program does every store operation; it is selected by its first argument:
#   lookup   <registry> <id>                   print "<tick_scope> TAB <definition hash>", or exit 30 (unknown id)
#   runfile  <state_dir> <run_id>              print the path of that run's state file
#   read     <registry> <id> <scope> <state_dir> <run_id> <ttl_minutes>   print the item's tick state
#   write    <file> <id> <hash> <scope> <actor> <note> <run_id>            record a tick   (run under the lock)
#   clear    <file> <id>                       remove a tick: prints "cleared" or "none"   (run under the lock)
#   stale    <state_dir> <ttl_minutes>         remove stale temp files and lock dirs, print stale run files
#   rm-stale <file> <ttl_minutes>              delete <file> if it is still stale   (run under the lock)
# Exit codes inside the program: 0 ok, 30 unknown id. It never exits 2, because with-lock.sh uses 2 for
# "lock not acquired" and the caller must be able to tell the two apart.
# ---------------------------------------------------------------------------
IFS= read -r -d '' TICK_PY <<'PY'
import datetime
import hashlib
import json
import os
import re
import sys
import time

STATE_VERSION = 1
PERSISTENT_NAME = "persistent.json"


def warn(message):
    sys.stderr.write("checklist.sh: warning: %s\n" % message)


def definition_hash(item):
    """Binds a tick to the item's definition: kind, text and verify (null for judgment items)."""
    material = json.dumps(
        {"kind": item.get("kind"), "text": item.get("text"), "verify": item.get("verify")},
        sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(material.encode("ascii")).hexdigest()


def find_item(registry_path, item_id):
    with open(registry_path, "rb") as fh:
        doc = json.loads(fh.read().decode("utf-8"))
    for item in doc["items"]:
        if item["id"] == item_id:
            return item, [i["id"] for i in doc["items"]]
    return None, [i["id"] for i in doc["items"]]


def run_file(state_dir, run_id):
    # Hashed, not the raw id: case-insensitive filesystems (macOS default) would otherwise alias "Abc" and
    # "abc" onto one file, which would be exactly the cross-run leak this layout exists to prevent.
    digest = hashlib.sha256(run_id.encode("utf-8")).hexdigest()[:24]
    return os.path.join(state_dir, "run-%s.json" % digest)


def load_store(path):
    """Returns (document, None), ({fresh document}, None) when the file is absent, or (None, why) when unusable."""
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except FileNotFoundError:
        return {"version": STATE_VERSION, "ticks": {}}, None
    except OSError as exc:
        return None, "cannot be read (%s)" % exc
    try:
        doc = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        return None, "is not valid JSON (%s)" % exc
    if not isinstance(doc, dict) or not isinstance(doc.get("ticks"), dict):
        return None, "does not have the expected structure"
    return doc, None


def atomic_write(path, doc):
    """Write-temp-fsync-rename in the same directory: a crash never leaves a partial file at `path`."""
    directory, base = os.path.split(path)
    tmp = os.path.join(directory, ".tmp-%s.%d" % (base, os.getpid()))
    try:
        with open(tmp, "wb") as fh:
            fh.write((json.dumps(doc, indent=2, sort_keys=True, ensure_ascii=True) + "\n").encode("ascii"))
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def ascii_line(value):
    """One tab-free, newline-free, ASCII-only line, whatever a hand-edited store contains."""
    text = re.sub(r"[\x00-\x1f\x7f]+", " ", str(value))
    return " ".join(text.encode("ascii", "replace").decode("ascii").split())


def is_stale(path, ttl_seconds):
    try:
        return (time.time() - os.stat(path).st_mtime) > ttl_seconds
    except OSError:
        return False


def mode_lookup(args):
    registry_path, item_id = args
    item, ids = find_item(registry_path, item_id)
    if item is None:
        shown = ", ".join(ids[:20]) + (", ..." if len(ids) > 20 else "")
        sys.stderr.write('checklist.sh: unknown checklist item id "%s" in %s (known ids: %s)\n'
                         % (item_id, registry_path, shown or "none"))
        return 30
    sys.stdout.write("%s\t%s\n" % (item["tick_scope"], definition_hash(item)))
    return 0


def mode_runfile(args):
    state_dir, run_id = args
    sys.stdout.write(run_file(state_dir, run_id) + "\n")
    return 0


def mode_read(args):
    registry_path, item_id, scope, state_dir, run_id, ttl_minutes = args
    unticked = "unticked"
    item, _ids = find_item(registry_path, item_id)
    if item is None:
        sys.stdout.write(unticked)
        return 0
    if scope == "run":
        if not run_id:
            sys.stdout.write(unticked)  # no run id: nothing can have been ticked for "this run"
            return 0
        path = run_file(state_dir, run_id)
        try:
            idle = time.time() - os.stat(path).st_mtime
        except OSError:
            sys.stdout.write(unticked)
            return 0
        if idle > float(ttl_minutes) * 60:
            sys.stdout.write(unticked)  # expired: a reused id still cannot see a tick this old
            return 0
    else:
        path = os.path.join(state_dir, PERSISTENT_NAME)
    doc, why = load_store(path)
    if doc is None:
        warn("tick store %s %s; treating its items as unticked" % (path, why))
        sys.stdout.write(unticked)
        return 0
    if scope == "run" and doc.get("run_id") != run_id:
        sys.stdout.write(unticked)  # belt and braces: the file must name exactly the run asked about
        return 0
    record = doc["ticks"].get(item_id)
    if not isinstance(record, dict) or not isinstance(record.get("definition_hash"), str):
        sys.stdout.write(unticked)
        return 0
    if record["definition_hash"] != definition_hash(item):
        warn('tick for "%s" ignored: the item was edited after it was ticked (re-verify and tick it again)' % item_id)
        sys.stdout.write(unticked)
        return 0
    sys.stdout.write("ticked(%s) by %s at %s" % (
        scope, ascii_line(record.get("ticked_by", "unknown")), ascii_line(record.get("ticked_at", "unknown"))))
    return 0


def mode_write(args):
    path, item_id, item_hash, scope, actor, note, run_id = args
    os.makedirs(os.path.dirname(path), exist_ok=True)
    doc, why = load_store(path)
    if doc is None:
        aside = path + ".corrupt"
        warn("tick store %s %s; moving it to %s and starting a fresh one" % (path, why, aside))
        os.replace(path, aside)
        doc = {"version": STATE_VERSION, "ticks": {}}
    doc["version"] = STATE_VERSION
    if scope == "run":
        doc["run_id"] = run_id
    note = note.encode("utf-8", "replace").decode("utf-8", "replace")
    doc["ticks"][item_id] = {
        "definition_hash": item_hash,
        "tick_scope": scope,
        "ticked_by": actor,
        "ticked_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "note": note if note else None,
    }
    atomic_write(path, doc)
    return 0


def mode_clear(args):
    path, item_id = args
    doc, why = load_store(path)
    if doc is None:
        warn("tick store %s %s; nothing to clear (it already reads as unticked)" % (path, why))
        sys.stdout.write("none\n")
        return 0
    if item_id not in doc["ticks"]:
        sys.stdout.write("none\n")
        return 0
    del doc["ticks"][item_id]
    atomic_write(path, doc)
    sys.stdout.write("cleared\n")
    return 0


def mode_stale(args):
    state_dir, ttl_minutes = args
    ttl = float(ttl_minutes) * 60
    try:
        names = sorted(os.listdir(state_dir))
    except OSError:
        return 0
    for name in names:
        path = os.path.join(state_dir, name)
        if name.startswith(".tmp-") and is_stale(path, ttl):
            try:
                os.unlink(path)  # a crashed writer's leftover; a live writer's temp file is never this old
            except OSError:
                pass
        elif name.endswith(".lock.d") and is_stale(path, ttl):
            try:
                for inner in os.listdir(path):
                    os.unlink(os.path.join(path, inner))
                os.rmdir(path)  # a lock holder that died a long time ago
            except OSError:
                pass
        elif name.startswith("run-") and name.endswith(".json") and is_stale(path, ttl):
            sys.stdout.write(path + "\n")
    return 0


def mode_rm_stale(args):
    path, ttl_minutes = args
    if is_stale(path, float(ttl_minutes) * 60):  # re-checked under the lock: a tick may have refreshed it
        try:
            os.unlink(path)
        except OSError:
            pass
    return 0


MODES = {"lookup": mode_lookup, "runfile": mode_runfile, "read": mode_read, "write": mode_write,
         "clear": mode_clear, "stale": mode_stale, "rm-stale": mode_rm_stale}

try:
    sys.exit(MODES[sys.argv[1]](sys.argv[2:]))
except SystemExit:
    raise
except Exception as exc:  # a bug or an unusable directory; reported, never a bare traceback
    sys.stderr.write("checklist.sh: tick store error (%s): %s: %s\n" % (sys.argv[1], type(exc).__name__, exc))
    sys.exit(3)
PY

# Runs one tick-store operation. Arguments are the python program's mode and its operands.
tick_py() {
  python3 -c "$TICK_PY" "$@"
}

# Runs one WRITE operation on state file $1 under scripts/with-lock.sh; the rest is the python mode and operands.
# Returns the operation's status, or 2 when the lock could not be acquired (the operation never ran).
tick_py_locked() {
  local file="$1"
  shift
  bash "$SCRIPT_DIR/with-lock.sh" "$file" -- python3 -c "$TICK_PY" "$@"
}

# Sets STATE_DIR (the directory holding every tick file). Returns 1 when it cannot be resolved.
resolve_state_dir() {
  local queue
  if [ -n "${JENGA_CHECKLIST_STATE_DIR:-}" ]; then
    STATE_DIR="$JENGA_CHECKLIST_STATE_DIR"
    return 0
  fi
  if ! queue="$(bash "$SCRIPT_DIR/resolve-root.sh" get queue)" || [ -z "$queue" ]; then
    printf '%s: could not resolve the project queue directory via resolve-root.sh\n' "$SELF" >&2
    STATE_DIR=""
    return 1
  fi
  STATE_DIR="$queue/$STATE_SUBDIR"
}

# Validates the run id in RUN_ID (empty means "none") and the tick-state environment overrides.
# Returns 2 (after a message) on anything malformed.
validate_tick_inputs() {
  if [ -n "$RUN_ID" ] && ! [[ "$RUN_ID" =~ $RUN_ID_PATTERN ]]; then
    printf '%s: bad run id "%s" (1 to 128 characters of letters, digits, dot, colon, underscore or hyphen, starting with a letter or digit)\n' \
      "$SELF" "$RUN_ID" >&2
    return 2
  fi
  if [ -n "${JENGA_CHECKLIST_RUN_TTL_MINUTES:-}" ] \
    && ! python3 -c 'import math,sys; v=float(sys.argv[1]); sys.exit(0 if math.isfinite(v) and v > 0 else 1)' \
      "$JENGA_CHECKLIST_RUN_TTL_MINUTES" 2>/dev/null; then
    printf '%s: bad run TTL "%s" (JENGA_CHECKLIST_RUN_TTL_MINUTES must be a positive number of minutes)\n' \
      "$SELF" "$JENGA_CHECKLIST_RUN_TTL_MINUTES" >&2
    return 2
  fi
  return 0
}

# Consumes a "--run <id>" or "--run=<id>" argument. Used by every subcommand's option loop.
# Sets RUN_ID and returns the number of arguments consumed (1 or 2), or 0 if $1 is not a run option, or 255 if
# the value is missing.
take_run_option() {
  case "$1" in
    --run)
      [ "$#" -ge 2 ] && [ -n "$2" ] || return 255
      RUN_ID="$2"
      return 2
      ;;
    --run=*)
      RUN_ID="${1#--run=}"
      [ -n "$RUN_ID" ] || return 255
      return 1
      ;;
  esac
  return 0
}

# Gives list and check what they need to read tick state through tick_state_of. Sets TICK_REGISTRY and STATE_DIR;
# an unresolvable state directory only means everything reads as unticked (check then evaluates every item).
init_tick_reading() {
  TICK_REGISTRY="$1"
  resolve_state_dir || printf '%s: warning: tick state is unavailable; treating every item as unticked\n' "$SELF" >&2
}

# ---------------------------------------------------------------------------
# Tick state: THE single seam (E67_S02_T03 implemented it; E67_S02_T01 and T02 call it).
#
# $1 = item id, $2 = the item's tick_scope ("run" or "persistent").
# Prints the item's current tick state on stdout: exactly "unticked", or a one-line description starting with
# "ticked(<scope>) by <actor> at <UTC timestamp>". It never fails and never prints a traceback: anything it cannot
# read degrades to "unticked" (with a warning on stderr), because a broken lookup must make a check run, not skip.
# Needs TICK_REGISTRY, STATE_DIR and RUN_ID (set by init_tick_reading and the option parser); without them it
# answers "unticked". A run-scoped item is only ever ticked for a named run, so with no RUN_ID it is unticked.
# ---------------------------------------------------------------------------
tick_state_of() {
  local answer
  if [ -z "${TICK_REGISTRY:-}" ] || [ -z "${STATE_DIR:-}" ]; then
    printf 'unticked'
    return 0
  fi
  answer="$(tick_py read "$TICK_REGISTRY" "$1" "$2" "$STATE_DIR" "$RUN_ID" "$RUN_TTL_MINUTES")" || answer=""
  printf '%s' "${answer:-unticked}"
}

# Prints the path of the registry file to read, or nothing when there is none. Returns 1 only when the
# configs directory cannot be resolved.
select_registry() {
  local project_file configs default_file

  if [ -n "${JENGA_CHECKLISTS_FILE:-}" ]; then
    project_file="$JENGA_CHECKLISTS_FILE"
  else
    # resolve-root.sh runs in the caller's working directory so its upward search starts where the
    # caller is (the same pattern resolve-tools.sh uses).
    if ! configs="$(bash "$SCRIPT_DIR/resolve-root.sh" get configs)"; then
      printf '%s: could not resolve the project configs directory via resolve-root.sh\n' "$SELF" >&2
      return 1
    fi
    project_file="$configs/checklists.json"
  fi

  if [ -f "$project_file" ]; then
    printf '%s' "$project_file"
    return 0
  fi

  # No project instance: fall back (whole file, no merging) to the shipped default.
  if [ -n "${JENGA_CHECKLISTS_DEFAULT_FILE:-}" ]; then
    default_file="$JENGA_CHECKLISTS_DEFAULT_FILE"
  elif [ -f "$PACKAGE_ROOT/templates/checklists.json" ]; then
    default_file="$PACKAGE_ROOT/templates/checklists.json"
  else
    default_file="$([ -f templates/checklists.json ] && echo templates/checklists.json || echo node_modules/@jenga-ai/agent/templates/checklists.json)"
  fi

  if [ -f "$default_file" ]; then
    printf '%s' "$default_file"
  fi
  return 0
}

# Emits the applicable rows of validated registry $1 for situation $2 as TAB-separated
# "<id> <text> <kind> <enforcement> <tick_scope>" lines. Exit 3 = unknown situation, 1 = unreadable.
select_rows() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

BASE_SITUATIONS = ["pre-commit", "pre-task", "pre-release", "pre-reconcile"]
path, situation = sys.argv[1], sys.argv[2]

try:
    with open(path, "rb") as fh:
        doc = json.loads(fh.read().decode("utf-8"))
except (OSError, ValueError) as exc:
    sys.stderr.write("checklist.sh: cannot read registry %s: %s\n" % (path, exc))
    sys.exit(1)

declared = [s for s in doc.get("situations", []) if s not in BASE_SITUATIONS]
known = BASE_SITUATIONS + declared
if situation not in known:
    sys.stderr.write(
        'checklist.sh: unknown situation "%s" (known: %s; extensions come from the "situations" array of %s)\n'
        % (situation, ", ".join(known), path))
    sys.exit(3)


def flat(value):
    return " ".join(str(value).split())


for item in doc["items"]:
    if situation in item["situations"]:
        sys.stdout.write("\t".join([
            item["id"], flat(item["text"]), item["kind"], item["enforcement"], item["tick_scope"],
        ]) + "\n")
PY
}

# Option loop shared by list and check: one <situation> plus an optional --run <id>.
# Sets POS_SITUATION and RUN_ID; returns 2 (after a message) on a usage error.
parse_situation_args() {
  local cmd="$1" count=0 consumed
  shift
  POS_SITUATION=""
  while [ "$#" -gt 0 ]; do
    take_run_option "$@"
    consumed=$?
    if [ "$consumed" -eq 255 ]; then
      printf '%s: --run needs a non-empty value\n' "$SELF" >&2
      return 2
    elif [ "$consumed" -gt 0 ]; then
      shift "$consumed"
      continue
    fi
    count=$((count + 1))
    [ "$count" -eq 1 ] && POS_SITUATION="$1"
    shift
  done
  if [ "$count" -ne 1 ] || [ -z "$POS_SITUATION" ]; then
    printf '%s: %s takes exactly one <situation>\n' "$SELF" "$cmd" >&2
    usage >&2
    return 2
  fi
  validate_tick_inputs
}

cmd_list() {
  parse_situation_args list "$@" || return 2
  local situation="$POS_SITUATION" registry rows status id text kind enforcement scope

  registry="$(select_registry)" || return 1
  # No registry at all: nothing authored, nothing to show.
  [ -n "$registry" ] || return 0

  if ! bash "$SCRIPT_DIR/validate-checklists.sh" "$registry" >/dev/null; then
    # The validator already printed "<file>: <message>" for every problem on stderr.
    printf '%s: invalid registry %s; refusing to list (fix the problems above)\n' "$SELF" "$registry" >&2
    return 1
  fi

  rows="$(select_rows "$registry" "$situation")"
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  [ -n "$rows" ] || return 0

  init_tick_reading "$registry"
  printf '%s\n' "$rows" | while IFS=$'\t' read -r id text kind enforcement scope; do
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$text" "$kind" "$enforcement" "$(tick_state_of "$id" "$scope")"
  done
  return 0
}

# Runs the applicable items of validated registry $1 for situation $2 and prints the JSON report on stdout.
#   $3 project root (cwd of every verify)   $4 timeout seconds   $5 per-stream output cap in bytes
#   $6 excerpt characters                   $7 "<id>=<tick state>" lines (from tick_state_of)
#   $8 1 if the caller had LC_ALL set       $9 the caller's LC_ALL
# Exit: 0, 10 (a block item unsatisfied), 11 (only confirm items need a decision), 2 (bad timeout),
# 5 (internal error; stdout empty). The report is only printed once complete, so stdout is never partial.
run_checks() {
  python3 - "$@" <<'PY'
import json
import math
import os
import re
import shlex
import signal
import subprocess
import sys
import threading

(path, situation, root, timeout_arg, cap_arg, excerpt_arg, tick_blob,
 caller_lc_set, caller_lc) = sys.argv[1:10]

EXIT_BLOCK = 10
EXIT_CONFIRM = 11

try:
    timeout = float(timeout_arg)
    if not math.isfinite(timeout) or timeout <= 0:
        raise ValueError(timeout_arg)
except ValueError:
    sys.stderr.write(
        'checklist.sh: bad verify timeout "%s" (JENGA_CHECKLIST_VERIFY_TIMEOUT must be a positive number of seconds)\n'
        % timeout_arg)
    sys.exit(2)
cap = int(cap_arg)
excerpt_chars = int(excerpt_arg)

# Verify commands run under the caller's locale, not this script's LC_ALL=C.
child_env = dict(os.environ)
if caller_lc_set == "1":
    child_env["LC_ALL"] = caller_lc
else:
    child_env.pop("LC_ALL", None)

tick_states = {}
for line in tick_blob.split("\n"):
    if "=" in line:
        key, value = line.split("=", 1)
        tick_states[key] = value


def drain(stream, sink):
    """Read the stream to EOF, keeping only the first `cap` bytes."""
    kept = bytearray()
    fd = stream.fileno()
    while True:
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        if len(kept) < cap:
            kept.extend(chunk[: cap - len(kept)])
    sink["data"] = bytes(kept)


def kill_group(pid):
    try:
        os.killpg(pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError, OSError):
        pass


def excerpt_of(data_err, data_out):
    raw = data_err if data_err.strip() else data_out
    text = raw.decode("utf-8", "replace")
    text = re.sub(r"[\x00-\x1f\x7f]+", " ", text)
    text = " ".join(text.split())
    if len(text) > excerpt_chars:
        text = text[:excerpt_chars].rstrip() + "..."
    return text


def preflight(command):
    """Catch the plain 'first word is a path' case before running, with an exact reason."""
    try:
        tokens = shlex.split(command)
    except ValueError:
        return None
    if not tokens:
        return None
    first = tokens[0]
    if "/" not in first or re.search(r"[$`*?\[~{;&|<>()]", first) or re.match(r"[A-Za-z_][A-Za-z0-9_]*=", first):
        return None
    target = first if os.path.isabs(first) else os.path.join(root, first)
    if not os.path.exists(target):
        return ("not_found", "verify command not found: %s does not exist" % first)
    if os.path.isdir(target):
        return ("not_executable", "verify command not executable: %s is a directory" % first)
    if not os.access(target, os.X_OK):
        return ("not_executable", "verify command not executable: %s lacks the execute permission" % first)
    return None


def run_verify(command):
    """Returns (cause, exit_status, reason). cause is None when the command passed."""
    pre = preflight(command)
    if pre is not None:
        return pre[0], None, pre[1]
    try:
        proc = subprocess.Popen(
            ["bash", "-c", command], cwd=root, env=child_env, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    except OSError as exc:
        return "spawn_error", None, "verify could not be started: %s" % exc
    sinks = [{"data": b""}, {"data": b""}]
    threads = [threading.Thread(target=drain, args=(proc.stdout, sinks[0]), daemon=True),
               threading.Thread(target=drain, args=(proc.stderr, sinks[1]), daemon=True)]
    for thread in threads:
        thread.start()
    timed_out = False
    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
    # Always kill the group: on timeout to stop the command, otherwise to reap anything it left behind.
    kill_group(proc.pid)
    proc.wait()
    for thread in threads:
        thread.join(5)
    status = proc.returncode
    seconds = ("%g" % timeout)
    if timed_out:
        return "timeout", None, "verify timed out after %ss and its process group was killed" % seconds
    detail = excerpt_of(sinks[1]["data"], sinks[0]["data"])
    suffix = (": " + detail) if detail else ""
    if status == 0:
        return None, 0, "verify exited 0"
    if status < 0:
        return "signal", None, "verify was killed by signal %d%s" % (-status, suffix)
    if status == 127:
        return "not_found", status, "verify command not found (exit status 127)%s" % suffix
    if status == 126:
        return "not_executable", status, "verify command not executable (exit status 126)%s" % suffix
    return "nonzero_exit", status, "verify exited with status %d%s" % (status, suffix)


ACTION_FOR = {"block": "halt", "confirm": "prompt", "advisory": "remind"}


def main():
    with open(path, "rb") as fh:
        doc = json.loads(fh.read().decode("utf-8"))
    report = []
    blocking = False
    needs_decision = False
    for item in doc["items"]:
        if situation not in item["situations"]:
            continue
        enforcement = item["enforcement"]
        entry = {
            "id": item["id"], "text": item["text"], "kind": item["kind"], "enforcement": enforcement,
            "tick_scope": item["tick_scope"],
        }
        state = tick_states.get(item["id"], "")
        entry["tick_state"] = state or "unticked"
        cause, exit_status = None, None
        if state not in ("", "unticked"):
            result, action = "already_ticked", "proceed"
            reason = "already ticked (%s); not re-evaluated" % state
        elif item["kind"] == "judgment":
            result, action = "requires_confirmation", ACTION_FOR[enforcement]
            reason = {
                "block": "requires confirmation; halts until it is confirmed",
                "confirm": "requires confirmation; ask the user before proceeding",
                "advisory": "reminder only; no response required",
            }[enforcement]
        else:
            cause, exit_status, reason = run_verify(item["verify"])
            if cause is None:
                result, action = "passed", "proceed"
            else:
                result, action = "failed", ACTION_FOR[enforcement]
        if result in ("failed", "requires_confirmation"):
            if enforcement == "block":
                blocking = True
            elif enforcement == "confirm":
                needs_decision = True
        entry.update({"result": result, "action": action, "reason": reason, "cause": cause,
                      "exit_status": exit_status})
        report.append(entry)
    sys.stdout.write(json.dumps(report, indent=2, ensure_ascii=True) + "\n")
    sys.stdout.flush()
    return EXIT_BLOCK if blocking else (EXIT_CONFIRM if needs_decision else 0)


try:
    code = main()
except Exception as exc:  # a bug, not a user error: stdout stays empty
    sys.stderr.write("checklist.sh: internal error in check: %s: %s\n" % (type(exc).__name__, exc))
    sys.exit(5)
sys.exit(code)
PY
}

cmd_check() {
  parse_situation_args check "$@" || return 2
  local situation="$POS_SITUATION" registry rows status root id text kind enforcement scope state ticks=""

  registry="$(select_registry)" || return 1
  # No registry at all, or nothing applicable: valid empty report, no warning.
  if [ -z "$registry" ]; then
    printf '[]\n'
    return 0
  fi

  if ! bash "$SCRIPT_DIR/validate-checklists.sh" "$registry" >/dev/null; then
    printf '%s: invalid registry %s; refusing to check (fix the problems above)\n' "$SELF" "$registry" >&2
    return 1
  fi

  rows="$(select_rows "$registry" "$situation")"
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  if [ -z "$rows" ]; then
    printf '[]\n'
    return 0
  fi

  # Every verify runs from the resolved root, found the way the rest of the framework finds it.
  if ! root="$(bash "$SCRIPT_DIR/resolve-root.sh" root)" || [ -z "$root" ]; then
    printf '%s: could not resolve the project root via resolve-root.sh\n' "$SELF" >&2
    return 1
  fi

  init_tick_reading "$registry"
  while IFS=$'\t' read -r id text kind enforcement scope; do
    state="$(tick_state_of "$id" "$scope")"
    state="${state//$'\n'/ }"
    ticks="$ticks$id=$state"$'\n'
  done <<EOF_ROWS
$rows
EOF_ROWS

  run_checks "$registry" "$situation" "$root" "${JENGA_CHECKLIST_VERIFY_TIMEOUT:-$DEFAULT_VERIFY_TIMEOUT_SECS}" \
    "$VERIFY_OUTPUT_CAP_BYTES" "$REASON_EXCERPT_CHARS" "$ticks" "$CALLER_LC_ALL_SET" "$CALLER_LC_ALL"
}

# Best-effort pruning of stale per-run state; never fails the tick that triggered it and never touches
# persistent.json or a run file that is not older than the TTL. Each deletion is re-checked under that file's own lock.
prune_stale_state() {
  local path stale
  stale="$(tick_py stale "$STATE_DIR" "$RUN_TTL_MINUTES" 2>/dev/null)" || return 0
  [ -n "$stale" ] || return 0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    tick_py_locked "$path" rm-stale "$path" "$RUN_TTL_MINUTES" >/dev/null 2>&1 || true
  done <<EOF_STALE
$stale
EOF_STALE
  return 0
}

cmd_tick() {
  local id="" note="" note_set=0 actor="" clear=0 positionals=0 consumed
  local registry looked scope item_hash target status result cleared_any=0

  while [ "$#" -gt 0 ]; do
    take_run_option "$@"
    consumed=$?
    if [ "$consumed" -eq 255 ]; then
      printf '%s: --run needs a value\n' "$SELF" >&2
      return 2
    elif [ "$consumed" -gt 0 ]; then
      shift "$consumed"
      continue
    fi
    case "$1" in
      --note)
        [ "$#" -ge 2 ] || { printf '%s: --note needs a value\n' "$SELF" >&2; return 2; }
        note="$2"
        note_set=1
        shift 2
        ;;
      --by)
        [ "$#" -ge 2 ] || { printf '%s: --by needs a value\n' "$SELF" >&2; return 2; }
        actor="$2"
        shift 2
        ;;
      --clear)
        clear=1
        shift
        ;;
      *)
        positionals=$((positionals + 1))
        [ "$positionals" -eq 1 ] && id="$1"
        shift
        ;;
    esac
  done

  if [ "$positionals" -ne 1 ] || [ -z "$id" ]; then
    printf '%s: tick takes exactly one <id>\n' "$SELF" >&2
    usage >&2
    return 2
  fi
  if ! [[ "$id" =~ $ITEM_ID_PATTERN ]]; then
    printf '%s: "%s" is not a valid checklist item id (kebab-case: lowercase letters and digits joined by hyphens)\n' "$SELF" "$id" >&2
    return 2
  fi
  if [ "$clear" -eq 1 ] && { [ "$note_set" -eq 1 ] || [ -n "$actor" ]; }; then
    printf '%s: --clear cannot be combined with --note or --by\n' "$SELF" >&2
    return 2
  fi
  if [ "${#note}" -gt "$NOTE_MAX_BYTES" ]; then
    printf '%s: --note is too long (%d bytes, limit %d)\n' "$SELF" "${#note}" "$NOTE_MAX_BYTES" >&2
    return 2
  fi
  validate_tick_inputs || return 2

  if [ "$clear" -eq 1 ]; then
    # Removal needs no registry: a tick for an item that has since been deleted from the registry must still be
    # removable, and a broken registry must not stop anyone from un-ticking.
    resolve_state_dir || return 1
    if [ ! -d "$STATE_DIR" ]; then
      printf 'no tick recorded for %s\n' "$id"
      return 0
    fi
    local files="$STATE_DIR/$PERSISTENT_FILE_NAME" runfile
    if [ -n "$RUN_ID" ]; then
      runfile="$(tick_py runfile "$STATE_DIR" "$RUN_ID")" || return 1
      files="$files"$'\n'"$runfile"
    fi
    while IFS= read -r target; do
      [ -n "$target" ] || continue
      [ -e "$target" ] || continue
      result="$(tick_py_locked "$target" clear "$target" "$id")"
      status=$?
      if [ "$status" -ne 0 ]; then
        printf '%s: could not update %s (status %d); the tick was not removed\n' "$SELF" "$target" "$status" >&2
        return 8
      fi
      [ "$result" = "cleared" ] && cleared_any=1
    done <<EOF_CLEAR
$files
EOF_CLEAR
    if [ "$cleared_any" -eq 1 ]; then
      printf 'cleared tick for %s\n' "$id"
    else
      printf 'no tick recorded for %s\n' "$id"
    fi
    return 0
  fi

  if [ -z "$actor" ]; then
    actor="${JENGA_CHECKLIST_ACTOR:-}"
  fi
  if [ -z "$actor" ]; then
    actor="os-user:$(id -un 2>/dev/null || echo unknown)"
  fi
  if ! [[ "$actor" =~ $ACTOR_PATTERN ]]; then
    printf '%s: bad actor "%s" (--by / JENGA_CHECKLIST_ACTOR: 1 to 128 characters of letters, digits and . _ : @ / + -)\n' "$SELF" "$actor" >&2
    return 2
  fi

  registry="$(select_registry)" || return 1
  if [ -z "$registry" ]; then
    printf '%s: unknown checklist item id "%s": there is no checklist registry to look it up in\n' "$SELF" "$id" >&2
    return 6
  fi
  if ! bash "$SCRIPT_DIR/validate-checklists.sh" "$registry" >/dev/null; then
    printf '%s: invalid registry %s; refusing to tick (fix the problems above)\n' "$SELF" "$registry" >&2
    return 1
  fi
  looked="$(tick_py lookup "$registry" "$id")"
  status=$?
  if [ "$status" -eq 30 ]; then
    return 6
  elif [ "$status" -ne 0 ]; then
    return 5
  fi
  scope="${looked%%$'\t'*}"
  item_hash="${looked#*$'\t'}"

  if [ "$scope" = "run" ] && [ -z "$RUN_ID" ]; then
    printf '%s: item "%s" has tick_scope "run", so ticking it needs a run id (--run <id> or JENGA_CHECKLIST_RUN_ID). Without one the tick could not be attributed to a run and would carry over into the next run.\n' \
      "$SELF" "$id" >&2
    return 7
  fi

  resolve_state_dir || return 1
  if ! mkdir -p "$STATE_DIR"; then
    printf '%s: cannot create the tick state directory %s\n' "$SELF" "$STATE_DIR" >&2
    return 8
  fi
  if [ "$scope" = "run" ]; then
    target="$(tick_py runfile "$STATE_DIR" "$RUN_ID")" || return 5
  else
    target="$STATE_DIR/$PERSISTENT_FILE_NAME"
  fi

  tick_py_locked "$target" write "$target" "$id" "$item_hash" "$scope" "$actor" "$note" "$RUN_ID"
  status=$?
  if [ "$status" -eq 2 ]; then
    printf '%s: could not acquire the lock on %s; the tick for "%s" was NOT recorded\n' "$SELF" "$target" "$id" >&2
    return 8
  elif [ "$status" -ne 0 ]; then
    printf '%s: could not record the tick for "%s" in %s (status %d)\n' "$SELF" "$id" "$target" "$status" >&2
    return 8
  fi

  prune_stale_state
  if [ "$scope" = "run" ]; then
    printf 'ticked %s (run %s) by %s\n' "$id" "$RUN_ID" "$actor"
  else
    printf 'ticked %s (persistent) by %s\n' "$id" "$actor"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Suggestion bookkeeping (E67_S05_T02): suggest, pending, rejected, resolve. Contract in the header's
# "SUGGESTIONS" section. Everything lives on the rapports themselves: no store of its own.
#
# One python program; it is selected by its first argument:
#   suggest  <validator> <registry|""> <rapports_dir> <default_actor> <flags...>   scaffold a rapport, print its path
#   pending  <rapports_dir> [no flags]                                             list unresolved suggestions
#   rejected <rapports_dir> [--id <item-id>]                                       list rejected suggestions
#   locate   <rapports_dir> <rapport>                                              print the canonical path, or exit 26/27
#   apply    <path> <accepted|rejected> <actor> <reason>                           append the outcome (run under the lock)
# Exit codes inside the program are the script's own (2, 20-27) plus 25 for a failed write; it never exits with the
# status with-lock.sh reserves for "lock not acquired" except where cmd_resolve says so.
# ---------------------------------------------------------------------------
IFS= read -r -d '' SUGGEST_PY <<'PY'
import datetime
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import uuid

BASE_SITUATIONS = ["pre-commit", "pre-task", "pre-release", "pre-reconcile"]
ORIGINS = ("precautionary", "recurrence")
ACTOR_RE = re.compile(r"[A-Za-z0-9._:@/+-]{1,128}")
EXT_RE = re.compile(r"[a-z][a-z0-9-]*")
TASK_RE = re.compile(r"E(\d+)_S(\d+)_T(\d+)")
SLUG_MAX = 64
FREE_TEXT_MAX = 4000
REASON_MAX = 2000
HEADER_LINES = 40
READ_MAX = 1048576
FILE_SUFFIX = "-checklist-suggestion"
OUTCOME_HEADING = "## Suggestion Outcome"
STAMP_FMT = "%Y-%m-%dT%H:%M:%SZ"

VALUE_FLAGS = {
    "--origin": "origin", "--evidence": "evidence", "--incident": "incident", "--id": "id", "--text": "text",
    "--kind": "kind", "--verify": "verify", "--enforcement": "enforcement", "--tick-scope": "tick_scope",
    "--by": "by", "--slug": "slug", "--task": "task",
}


def die(code, message):
    sys.stderr.write("checklist.sh: %s\n" % message)
    sys.exit(code)


def clean(value):
    """Valid UTF-8 text (lone surrogates and invalid bytes replaced)."""
    return str(value).encode("utf-8", "replace").decode("utf-8")


def flat(value):
    """One line: control characters (tab, newline, ...) and runs of whitespace collapse to single spaces."""
    text = re.sub(r"[\x00-\x1f\x7f\x85\u2028\u2029]+", " ", clean(value))
    return " ".join(text.split())


def now():
    override = os.environ.get("JENGA_CHECKLIST_NOW", "")
    if override:
        try:
            return datetime.datetime.strptime(override, STAMP_FMT).replace(tzinfo=datetime.timezone.utc)
        except ValueError:
            die(2, "bad JENGA_CHECKLIST_NOW %r (expected a UTC time like 2026-10-03T12:00:00Z)" % override)
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)


def parse_time(value):
    try:
        return datetime.datetime.strptime(value, STAMP_FMT).replace(tzinfo=datetime.timezone.utc)
    except (ValueError, TypeError):
        return None


def unquote(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == "`" and value[-1] == "`":
        value = value[1:-1].strip()
    return value


def header_field(head, name):
    match = re.search(r"^\*\*%s:\*\*[ \t]*(.*?)[ \t]*$" % re.escape(name), head, re.M)
    return unquote(match.group(1)) if match else ""


def parse_suggestion(path):
    """A dict describing the rapport, or None when it is not a readable checklist_suggestion rapport."""
    try:
        if os.path.islink(path) or not os.path.isfile(path):
            return None
        with open(path, "rb") as fh:
            raw = fh.read(READ_MAX)
    except OSError:
        return None
    text = raw.decode("utf-8", "replace")
    head = "\n".join(text.splitlines()[:HEADER_LINES])
    if not re.search(r"^\*\*Type:\*\*[ \t]*`?checklist_suggestion`?[ \t]*$", head, re.M):
        return None

    item_id = header_field(head, "Proposed Item ID")
    if not item_id:
        found = re.search(r'"id"[ \t]*:[ \t]*"([^"\n]*)"', text)
        item_id = found.group(1) if found else ""
    origin = header_field(head, "Origin")

    suggested = parse_time(header_field(head, "Suggested At"))
    if suggested is None:
        day = header_field(head, "Date").split(" ")[0]
        try:
            suggested = datetime.datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=datetime.timezone.utc)
        except ValueError:
            suggested = datetime.datetime.fromtimestamp(os.stat(path).st_mtime, datetime.timezone.utc)

    outcome, resolved_at, reason = "", "", ""
    heading = re.search(r"^%s[ \t]*$" % re.escape(OUTCOME_HEADING), text, re.M)
    if heading:
        section = text[heading.end():]
        found = re.search(r"^\*\*Outcome:\*\*[ \t]*`?(accepted|rejected)`?[ \t]*$", section, re.M)
        if found:
            outcome = found.group(1)
            resolved_at = header_field(section, "Resolved At")
            reason = header_field(section, "Reason")
    return {"path": path, "item_id": item_id, "origin": origin, "suggested_at": suggested,
            "outcome": outcome, "resolved_at": resolved_at, "reason": reason}


def scan(rdir):
    """Every suggestion rapport in rdir (never *.IGNORE.md), ordered oldest first, then by path."""
    try:
        names = sorted(os.listdir(rdir))
    except OSError:
        return []
    found = []
    for name in names:
        if not name.endswith(".md") or name.endswith(".IGNORE.md") or name.startswith("."):
            continue
        entry = parse_suggestion(os.path.join(rdir, name))
        if entry is not None:
            found.append(entry)
    found.sort(key=lambda e: (e["suggested_at"], e["path"]))
    return found


def age_of(entry):
    seconds = max(0, int((now() - entry["suggested_at"]).total_seconds()))
    if seconds < 60:
        return "%ds" % seconds
    if seconds < 3600:
        return "%dm" % (seconds // 60)
    if seconds < 86400:
        return "%dh" % (seconds // 3600)
    return "%dd" % (seconds // 86400)


def cell(value):
    return flat(value) or "-"


def sanitize_slug(value):
    slug = re.sub(r"[^a-z0-9]+", "-", clean(value).lower()).strip("-")
    return slug[:SLUG_MAX].strip("-")


def run_validator(validator, doc):
    """Validate a registry document with the real validator. Returns the problem lines ([] when valid)."""
    with tempfile.TemporaryDirectory(prefix="checklist-suggest-") as tmp:
        path = os.path.join(tmp, "proposed.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, ensure_ascii=True)
        done = subprocess.run(["bash", validator, path], stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if done.returncode == 0:
        return []
    lines = []
    for line in done.stderr.decode("utf-8", "replace").splitlines():
        prefix = path + ": "
        lines.append(line[len(prefix):] if line.startswith(prefix) else line)
    return lines or ["the validator rejected the proposed item (exit %d)" % done.returncode]


def registry_facts(registry):
    """(declared extension situations, existing item ids) of the loaded registry; tolerant of a broken one."""
    if not registry:
        return [], []
    try:
        with open(registry, "rb") as fh:
            doc = json.loads(fh.read().decode("utf-8"))
        declared = []
        for name in doc.get("situations", []):
            if isinstance(name, str) and EXT_RE.fullmatch(name) and name not in BASE_SITUATIONS and name not in declared:
                declared.append(name)
        ids = [i["id"] for i in doc.get("items", []) if isinstance(i, dict) and isinstance(i.get("id"), str)]
        return declared, ids
    except (OSError, ValueError, AttributeError):
        sys.stderr.write("checklist.sh: warning: could not read %s; validating the proposed item against the base "
                         "situations only\n" % registry)
        return [], []


def parse_suggest_flags(args):
    opts = {key: None for key in VALUE_FLAGS.values()}
    opts["situations"] = []
    i = 0
    while i < len(args):
        flag = args[i]
        if flag == "--situation" or flag in VALUE_FLAGS:
            if i + 1 >= len(args):
                die(2, "%s needs a value" % flag)
            value = clean(args[i + 1])
            if flag == "--situation":
                opts["situations"].append(value)
            else:
                opts[VALUE_FLAGS[flag]] = value
            i += 2
        else:
            die(2, "suggest: unknown argument %r (flags: --origin --evidence --incident --id --text --situation "
                   "--kind --verify --enforcement --tick-scope --by --slug --task)" % flag)
    return opts


def build_item(opts):
    """The proposed item with exactly the fields the caller supplied (the validator names what is missing)."""
    item = {}
    for key in ("id", "text"):
        if opts[key] is not None:
            item[key] = opts[key]
    if opts["situations"]:
        item["situations"] = opts["situations"]
    for key in ("kind", "verify", "enforcement", "tick_scope"):
        if opts[key] is not None:
            item[key] = opts[key]
    return item


def create_exclusive(rdir, slug, content):
    """Create <slug>-checklist-suggestion.md without ever replacing an existing file; on a name clash fall back to
    a stamped, randomised name. The content is written to a temp file first and hard-linked into place, so the
    name appears atomically with its whole content and exactly one racer wins any given name."""
    os.makedirs(rdir, exist_ok=True)
    tmp = os.path.join(rdir, ".tmp-suggest-%d-%s" % (os.getpid(), uuid.uuid4().hex[:8]))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o666)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(content.encode("utf-8"))
            fh.flush()
            os.fsync(fh.fileno())
        stamp = now().strftime("%Y%m%dT%H%M%SZ")
        for attempt in range(50):
            if attempt == 0:
                name = slug + FILE_SUFFIX + ".md"
            else:
                name = "%s%s-%s-%s.md" % (slug, FILE_SUFFIX, stamp, uuid.uuid4().hex[:6])
            final = os.path.join(rdir, name)
            try:
                os.link(tmp, final)
                return final
            except FileExistsError:
                continue
            except OSError:
                # No hard links on this filesystem: exclusive-create the final name instead.
                try:
                    out = os.open(final, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o666)
                except FileExistsError:
                    continue
                with os.fdopen(out, "wb") as fh:
                    fh.write(content.encode("utf-8"))
                    fh.flush()
                    os.fsync(fh.fileno())
                return final
        raise OSError("could not find a free file name for %s" % slug)
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def render_rapport(opts, item, actor, stamp):
    task = opts["task"]
    epic = story = "N/A"
    task_id = story_id = epic_id = ""
    if task:
        m = TASK_RE.fullmatch(task)
        epic_id, story_id, task_id = "E%s" % m.group(1), "E%s_S%s" % (m.group(1), m.group(2)), task
        epic, story = epic_id, story_id
    else:
        task = "N/A"
    sender = {"sender": {"agent": actor, "session_id": "", "task_id": task_id, "story_id": story_id,
                         "epic_id": epic_id, "date": stamp, "paths": [], "worktree": ""}}
    origin = opts["origin"]
    evidence = flat(opts["evidence"])[:FREE_TEXT_MAX]
    incident = flat(opts["incident"] or "")[:FREE_TEXT_MAX]
    lines = [
        "# Rapport: Checklist suggestion: %s" % flat(item.get("id", "")),
        "",
        "**Date:** %s (UTC)" % stamp[:10],
        "**Agent:** %s" % actor,
        "**Related Epic:** %s" % epic,
        "**Related Story:** %s" % story,
        "**Related Task:** %s" % task,
        "**Type:** `checklist_suggestion`",
        "**Origin:** `%s`" % origin,
        "**Proposed Item ID:** `%s`" % flat(item.get("id", "")),
        "**Suggested By:** %s" % actor,
        "**Suggested At:** %s" % stamp,
        "",
        "---",
        "",
        "## Sender",
        "```json",
        json.dumps(sender, indent=2, ensure_ascii=False),
        "```",
        "",
        "---",
        "",
        "## Summary",
        "A `%s` suggestion for a new pre-flight checklist item `%s`. Non-blocking: work continued. Only the Scrum "
        "Master writes the checklist registry, after the user confirms." % (origin, flat(item.get("id", ""))),
        "",
        "---",
        "",
        "## Proposed Item",
        "```json",
        json.dumps(item, indent=2, ensure_ascii=False),
        "```",
        "",
        "---",
        "",
        "## Evidence",
        "> %s" % evidence,
        "",
    ]
    if incident:
        lines += ["---", "", "## Originating Incident", "> %s" % incident, ""]
    lines += [
        "---",
        "",
        "## Impact",
        "Nothing is blocked. The item is not in effect until the Scrum Master accepts it.",
        "",
        "---",
        "",
        "## Suggested Next Steps",
        "Scrum Master: review against the evidence rules, ask the user, then record the outcome with "
        "`checklist.sh resolve <this rapport> accepted|rejected`.",
        "",
        "---",
        "",
        "## Ignore Log",
        "_Only populated by the developer when this rapport is marked `.IGNORE.md`._",
        "",
        "**Ignored by:** Developer",
        "**Date:** YYYY-MM-DD (UTC)",
        "**Reason:**",
        "",
    ]
    return "\n".join(lines)


def cmd_suggest(argv):
    validator, registry, rdir, default_actor = argv[0], argv[1], argv[2], argv[3]
    opts = parse_suggest_flags(argv[4:])

    origin = opts["origin"]
    if origin is None or origin not in ORIGINS:
        die(2, 'suggest: --origin must be "precautionary" or "recurrence" (got %s)'
            % ("nothing" if origin is None else repr(origin)))
    actor = opts["by"] if opts["by"] is not None else default_actor
    if not ACTOR_RE.fullmatch(actor):
        die(2, 'bad actor "%s" (--by / JENGA_CHECKLIST_ACTOR: 1 to 128 characters of letters, digits and . _ : @ / + -)'
            % flat(actor))
    if opts["task"] is not None and not TASK_RE.fullmatch(opts["task"]):
        die(2, 'suggest: bad --task "%s" (expected E##_S##_T##)' % flat(opts["task"]))

    # 1. Evidence: both origins need at least one concrete, checkable fact.
    evidence = flat(opts["evidence"] or "")
    if not evidence:
        die(20, "suggestion refused: --evidence is missing or empty. A suggestion needs at least one concrete, "
                "checkable fact (a specific file/path, an exact error message, a reproduction count, or a "
                "quantifiable impact). Nothing was written.")
    # 2. A recurrence must name the incident it comes from.
    incident = flat(opts["incident"] or "")
    if origin == "recurrence" and not incident:
        die(21, 'suggestion refused: origin "recurrence" needs --incident <ref> naming the incident it prevents '
                "(a rapport path, a commit SHA, or a failed task id such as E##_S##_T##). Nothing was written.")

    # 3. The proposed item must be schema-valid, in the shape it will have in the registry (no provenance yet:
    #    that is attached at acceptance by the Scrum Master), against the situations the loaded registry declares.
    declared, existing_ids = registry_facts(registry)
    item = build_item(opts)
    problems = run_validator(validator, {"checklist_version": 1, "situations": declared, "items": [item]})
    if not problems and item.get("id") in existing_ids:
        problems = ['duplicate item id: "%s" is already an item of the registry (%s); an id is never reused for a '
                    "different item" % (item.get("id"), registry)]
    if problems:
        sys.stderr.write("checklist.sh: suggestion refused: the proposed item is not schema-valid. Nothing was "
                         "written.\n")
        for line in problems:
            sys.stderr.write("  %s\n" % flat(line))
        sys.exit(22)

    # 4. A given incident reference must satisfy the validator's own incident rule (rapport path, commit SHA or
    #    task id): validate a synthetic suggested/recurrence provenance whose evidence is exactly the reference.
    if incident:
        provenance = {"source": "suggested", "suggested_by": actor, "origin": "recurrence",
                      "evidence": incident, "accepted_on": now().strftime("%Y-%m-%d")}
        carrying = dict(item)
        carrying["provenance"] = provenance
        if run_validator(validator, {"checklist_version": 1, "situations": declared, "items": [carrying]}):
            die(23, 'suggestion refused: --incident "%s" names no incident. Use a rapport path (rapports/<...>.md), '
                    "a commit SHA (7 to 40 hex characters) or a task id (E##_S##_T##). Nothing was written."
                % incident[:200])

    # 5. A suggestion whose item id was already rejected is not re-proposed.
    for entry in scan(rdir):
        if entry["outcome"] == "rejected" and entry["item_id"] == item["id"]:
            die(24, 'suggestion refused: an item with id "%s" was already rejected (%s%s). Rejected suggestions are '
                    "not re-proposed. Nothing was written."
                % (item["id"], entry["path"], (": " + entry["reason"]) if entry["reason"] else ""))

    slug = sanitize_slug(opts["slug"] or "") or sanitize_slug(item["id"]) or "suggestion"
    opts["evidence"], opts["incident"] = evidence, incident
    content = render_rapport(opts, item, actor, now().strftime(STAMP_FMT))
    try:
        path = create_exclusive(rdir, slug, content)
    except OSError as exc:
        die(25, "could not write the suggestion rapport in %s: %s" % (rdir, exc))
    sys.stdout.write(path + "\n")


def cmd_pending(argv):
    rdir, rest = argv[0], argv[1:]
    if rest:
        die(2, "pending takes no arguments (got %r)" % rest[0])
    for entry in scan(rdir):
        if not entry["outcome"]:
            sys.stdout.write("\t".join([entry["path"], cell(entry["origin"]), cell(entry["item_id"]),
                                        age_of(entry)]) + "\n")


def cmd_rejected(argv):
    rdir, rest = argv[0], argv[1:]
    only = None
    if rest:
        if len(rest) != 2 or rest[0] != "--id":
            die(2, "rejected takes only: --id <item-id>")
        only = rest[1]
    for entry in scan(rdir):
        if entry["outcome"] == "rejected" and (only is None or entry["item_id"] == only):
            sys.stdout.write("\t".join([entry["path"], cell(entry["origin"]), cell(entry["item_id"]),
                                        cell(entry["resolved_at"]), cell(entry["reason"])]) + "\n")


def cmd_locate(argv):
    rdir, given = argv[0], argv[1]
    now()  # a bad JENGA_CHECKLIST_NOW is a usage error here, before the locked step could mistake it for a lock failure
    candidates = [given]
    if not os.path.isabs(given):
        candidates.append(os.path.join(rdir, given))
    path = next((c for c in candidates if os.path.isfile(c)), None)
    if path is None:
        die(26, 'resolve: no rapport "%s" (looked in the current directory and in %s)' % (given, rdir))
    real, root = os.path.realpath(path), os.path.realpath(rdir)
    if os.path.dirname(real) != root:
        die(26, "resolve: %s is not a rapport directly inside %s; refusing to touch it" % (given, root))
    if real.endswith(".IGNORE.md"):
        die(26, "resolve: %s is an .IGNORE.md rapport (already fully resolved); nothing to record" % real)
    entry = parse_suggestion(real)
    if entry is None:
        die(26, "resolve: %s is not a Type: checklist_suggestion rapport" % real)
    if entry["outcome"]:
        die(27, "resolve: %s is already resolved as %s; the existing outcome was left untouched"
            % (real, entry["outcome"]))
    sys.stdout.write(os.path.join(rdir, os.path.basename(real)) + "\n")


def cmd_apply(argv):
    path, outcome, actor, reason = argv[0], argv[1], argv[2], argv[3]
    entry = parse_suggestion(path)
    if entry is None:
        die(26, "resolve: %s is not a Type: checklist_suggestion rapport" % path)
    if entry["outcome"]:
        die(27, "resolve: %s is already resolved as %s; the existing outcome was left untouched"
            % (path, entry["outcome"]))
    block = ["", OUTCOME_HEADING, "", "**Outcome:** %s" % outcome, "**Resolved By:** %s" % actor,
             "**Resolved At:** %s" % now().strftime(STAMP_FMT)]
    reason = flat(reason)[:REASON_MAX]
    if reason:
        block.append("**Reason:** %s" % reason)
    block.append("")
    tmp = None
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
        if raw and not raw.endswith(b"\n"):
            raw += b"\n"
        mode = stat.S_IMODE(os.stat(path).st_mode)
        tmp = os.path.join(os.path.dirname(path), ".tmp-resolve-%d-%s" % (os.getpid(), uuid.uuid4().hex[:8]))
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as fh:
            fh.write(raw + "\n".join(block).encode("utf-8"))
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
        tmp = None
    except OSError as exc:
        die(25, "resolve: could not record the outcome in %s: %s" % (path, exc))
    finally:
        if tmp is not None:
            try:
                os.unlink(tmp)
            except OSError:
                pass


MODES = {"suggest": cmd_suggest, "pending": cmd_pending, "rejected": cmd_rejected,
         "locate": cmd_locate, "apply": cmd_apply}

try:
    MODES[sys.argv[1]](sys.argv[2:])
except SystemExit:
    raise
except Exception as exc:  # a bug; reported, never a bare traceback
    sys.stderr.write("checklist.sh: suggestion bookkeeping error (%s): %s: %s\n" % (sys.argv[1], type(exc).__name__, exc))
    sys.exit(5)
PY

sug_py() {
  python3 -c "$SUGGEST_PY" "$@"
}

# Sets RAPPORTS_DIR, the directory suggestion rapports live in. Returns 1 when it cannot be resolved.
resolve_rapports_dir() {
  if [ -n "${JENGA_CHECKLIST_RAPPORTS_DIR:-}" ]; then
    RAPPORTS_DIR="$JENGA_CHECKLIST_RAPPORTS_DIR"
    return 0
  fi
  if ! RAPPORTS_DIR="$(bash "$SCRIPT_DIR/resolve-root.sh" get rapports_problems)" || [ -z "$RAPPORTS_DIR" ]; then
    printf '%s: could not resolve the problem rapports directory via resolve-root.sh\n' "$SELF" >&2
    RAPPORTS_DIR=""
    return 1
  fi
}

# Prints the actor a suggestion or outcome is attributed to when --by is not given (same default as tick).
default_actor() {
  local actor="${JENGA_CHECKLIST_ACTOR:-}"
  if [ -z "$actor" ]; then
    actor="os-user:$(id -un 2>/dev/null || echo unknown)"
  fi
  printf '%s' "$actor"
}

cmd_suggest() {
  local registry
  resolve_rapports_dir || return 1
  registry="$(select_registry)" || return 1
  sug_py suggest "$SCRIPT_DIR/validate-checklists.sh" "$registry" "$RAPPORTS_DIR" "$(default_actor)" "$@"
}

cmd_pending() {
  resolve_rapports_dir || return 1
  sug_py pending "$RAPPORTS_DIR" "$@"
}

cmd_rejected() {
  resolve_rapports_dir || return 1
  sug_py rejected "$RAPPORTS_DIR" "$@"
}

cmd_resolve() {
  local rapport="" outcome="" reason="" actor="" positionals=0 target status
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason)
        [ "$#" -ge 2 ] || { printf '%s: --reason needs a value\n' "$SELF" >&2; return 2; }
        reason="$2"
        shift 2
        ;;
      --by)
        [ "$#" -ge 2 ] || { printf '%s: --by needs a value\n' "$SELF" >&2; return 2; }
        actor="$2"
        shift 2
        ;;
      *)
        positionals=$((positionals + 1))
        case "$positionals" in
          1) rapport="$1" ;;
          2) outcome="$1" ;;
        esac
        shift
        ;;
    esac
  done

  if [ "$positionals" -ne 2 ] || [ -z "$rapport" ]; then
    printf '%s: resolve takes <rapport> accepted|rejected [--reason <text>] [--by <actor>]\n' "$SELF" >&2
    usage >&2
    return 2
  fi
  if [ "$outcome" != "accepted" ] && [ "$outcome" != "rejected" ]; then
    printf '%s: resolve outcome must be "accepted" or "rejected" (got "%s")\n' "$SELF" "$outcome" >&2
    return 2
  fi
  if [ "${#reason}" -gt "$NOTE_MAX_BYTES" ]; then
    printf '%s: --reason is too long (%d bytes, limit %d)\n' "$SELF" "${#reason}" "$NOTE_MAX_BYTES" >&2
    return 2
  fi
  [ -n "$actor" ] || actor="$(default_actor)"
  if ! [[ "$actor" =~ $ACTOR_PATTERN ]]; then
    printf '%s: bad actor "%s" (--by / JENGA_CHECKLIST_ACTOR: 1 to 128 characters of letters, digits and . _ : @ / + -)\n' "$SELF" "$actor" >&2
    return 2
  fi

  resolve_rapports_dir || return 1
  target="$(sug_py locate "$RAPPORTS_DIR" "$rapport")"
  status=$?
  [ "$status" -eq 0 ] || return "$status"

  # Read-modify-write of the rapport, under its own lock (the outcome is re-checked inside the lock).
  bash "$SCRIPT_DIR/with-lock.sh" "$target" -- python3 -c "$SUGGEST_PY" apply "$target" "$outcome" "$actor" "$reason"
  status=$?
  if [ "$status" -eq 2 ]; then
    printf '%s: could not acquire the lock on %s; the outcome was NOT recorded\n' "$SELF" "$target" >&2
    return 28
  elif [ "$status" -ne 0 ]; then
    return "$status"
  fi
  printf 'resolved %s as %s\n' "$target" "$outcome"
  return 0
}

if [ "$#" -lt 1 ]; then
  usage >&2
  exit 2
fi

case "$1" in
  -h | --help | help)
    usage
    exit 0
    ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  printf '%s: python3 is required but was not found on PATH\n' "$SELF" >&2
  exit 4
fi

SUBCOMMAND="$1"
shift
case "$SUBCOMMAND" in
  list)
    cmd_list "$@"
    exit $?
    ;;
  check)
    cmd_check "$@"
    exit $?
    ;;
  tick)
    cmd_tick "$@"
    exit $?
    ;;
  suggest)
    cmd_suggest "$@"
    exit $?
    ;;
  pending)
    cmd_pending "$@"
    exit $?
    ;;
  rejected)
    cmd_rejected "$@"
    exit $?
    ;;
  resolve)
    cmd_resolve "$@"
    exit $?
    ;;
  *)
    printf '%s: unknown subcommand "%s"\n' "$SELF" "$SUBCOMMAND" >&2
    usage >&2
    exit 2
    ;;
esac
