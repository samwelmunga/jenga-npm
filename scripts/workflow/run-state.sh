#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/workflow/run-state.sh - the workflow run-state store (epic E80, task E80_S02_T03)
#
# One JSON state file per workflow run. E80_S02_T03 laid the foundation (the file format, the locked atomic
# writer, corrupt-file detection) and the two read-only commands, status and list. E80_S02_T04 adds start, which
# creates a run. E80_S02_T05 adds the lifecycle transition table (assert_transition) and the pause and cancel
# commands. E80_S02_T06 adds step and await-confirmation, the write interface the executors use to record
# per-step progress. E80_S02_T07 adds resume, which restarts a paused, awaiting_confirmation or failed run from
# its recorded steps and refuses when the workflow definition changed since the run started.
#
# This header is the single source of truth for the state file format until E80_S02_T09 copies it into the
# workflow documentation.
#
# ---------------------------------------------------------------------------
# WHERE THE FILES LIVE
# ---------------------------------------------------------------------------
#   <workflow_runs>/<run_id>.json
# <workflow_runs> is whatever "scripts/resolve-root.sh get workflow_runs" prints, so it follows
# JENGA_PROJECT_ROOT and a relocated (dot-prefixed) working-file tree. This script names no tree directory
# itself. Locks live beside the file as <run_id>.json.lock.d (scripts/with-lock.sh); temporary files as
# .tmp-<run_id>.<pid>. Neither matches the *.json pattern, so list never mistakes them for runs.
#
# ---------------------------------------------------------------------------
# STATE FILE FORMAT, schema_version 1
# ---------------------------------------------------------------------------
#   {
#     "schema_version": 1,                 number, must be exactly 1
#     "run_id": "...",                     string, the file's base name
#     "workflow_id": "...",                string, the workflow definition this run executes
#     "definition_hash": "<sha256>",       string, hash of the definition at start (compared by resume)
#     "inputs": {"k": "v"},                object, the run's input values
#     "status": "running|paused|awaiting_confirmation|failed|completed|cancelled",
#     "created_at": "<UTC ISO 8601>",      string, set once at start
#     "updated_at": "<UTC ISO 8601>",      string, set by every successful run_state_update
#     "last_checkpoint": null,             null or the id of the last checkpointed step
#     "definition_change_ack": null,       null, or {at, from_hash, to_hash} once resume --allow-definition-change accepted a change
#     "steps": [
#       {"id": "...", "type": "...", "checkpoint": false,
#        "status": "pending|in_progress|completed|failed|skipped",
#        "started_at": null, "finished_at": null,
#        "outputs": {}}                    {} at start; the step command fills it (name -> string value)
#       A step may also carry an optional "note" (string), written by step --note; start does not write it.
#     ],
#     "history": [
#       {"at": "<UTC ISO 8601>", "from": "...", "to": "...", "note": "..."}
#     ]
#   }
# All twelve top-level keys are required (a null value counts as present). A file that is empty, is not a
# single valid JSON document, is not an object, lacks a required key, or has a schema_version other than 1 is
# corrupt: it is never printed, never listed as a run and never modified.
#
# Run ids match ^[A-Za-z0-9._-]+$ with two further rules so an id can neither escape the runs directory nor
# produce a hidden file that list would not see: ".." may not appear anywhere in it and it may not start with ".".
#
# ---------------------------------------------------------------------------
# COMMANDS
# ---------------------------------------------------------------------------
#   run-state.sh status <run_id>
#       Prints the run's state JSON (pretty, keys sorted) on stdout. Prints nothing on stdout on any failure.
#   run-state.sh list
#       One line per run: <run_id> TAB <workflow_id> TAB <status> TAB <updated_at>, sorted by created_at and then
#       run id. A corrupt file is reported on stderr as a warning and does not stop the listing; the exit status
#       is then 4, after the full listing. A missing runs directory prints nothing and exits 0.
#   run-state.sh start <workflow_id> [--input k=v ...]
#       Creates a run (E80_S02_T04). Prints ONLY the new run id on stdout (callers capture it with $(...));
#       everything else goes to stderr. In this order, and nothing is written unless every step before the write
#       succeeded:
#         1. Find the definition. E80_S01's loader (load-workflows.sh) takes no arguments and prints the whole
#            merged catalog, so start runs it and selects the entry whose id is <workflow_id> with jq; the entry's
#            "file" is the definition file. The sibling scripts are located through this script's own directory,
#            which is also correct in a consumer install (node_modules/@jenga-ai/agent/scripts/workflow/).
#            Unknown id: exit 2, the message names the id. The loader drops an invalid file from the catalog, so
#            when the id is not in the catalog the builtin and project directories are scanned for a file whose
#            id matches; if there is one, the validator's message is reported (step 2) instead of "unknown".
#         2. Validate that file with validate-workflow.sh (E80_S01; it accepts a file path only). Invalid: exit 2
#            and the validator's lines on stderr.
#         3. Parse --input k=v (split on the FIRST "=", so a value may contain "="; a repeated key is an error).
#            Compare with the definition's "inputs": a declared input with no supplied value and no "default"
#            key is "missing"; a supplied key the definition does not declare is "unknown". One message names
#            every offending key; exit 2. A declared default fills in an input that was not supplied, so the
#            stored "inputs" holds the effective values (supplied ones win).
#         4. definition_hash (below) of the definition file (the file content; the loader's source/file fields
#            are not part of it).
#         5. Run id wf-<workflow_id>-<UTC yyyymmddThhmmssZ>-<6 hex>. Under scripts/with-lock.sh on the new state
#            path an existing file is never overwritten: a fresh id is generated up to 5 times, then exit 1.
#         6. Writes the v1 state atomically: status running, every step pending with type and checkpoint copied
#            from the definition (checkpoint is true only for the boolean true), last_checkpoint null,
#            created_at == updated_at, empty step outputs, one history entry (from null, to running, note
#            "started"), definition_change_ack null.
#       start is the only command that creates the runs directory.
#   run-state.sh pause <run_id>
#       running or awaiting_confirmation -> paused (E80_S02_T05). Prints the new status on stdout. A step that is
#       in_progress stays in_progress: pause asks the executing agent to stop at the next boundary, and the
#       result of the step already in progress is still reported through the step command (below).
#   run-state.sh cancel <run_id>
#       Any non-terminal status (running, awaiting_confirmation, paused, failed) -> cancelled (E80_S02_T05).
#       Prints the new status on stdout. Remaining pending or in_progress steps are left as they are (history,
#       not erased), and the run file is never deleted.
#       Both commands: the status is re-read INSIDE the locked update, so two racing calls cannot both pass a
#       stale check. An illegal move exits 1 with the message below and leaves the file byte-identical; an
#       unknown run exits 3, a corrupt file 4 (nothing written), a lock timeout 5. Every successful move
#       appends a history entry {at, from, to, note} (at equals the new updated_at) and sets updated_at.
#   run-state.sh step <run_id> <step_id> <in_progress|completed|failed|skipped> [--output name=value ...] [--note text]
#       Records one step's status (E80_S02_T06). Executors never edit the state file; they call this. Prints ONE
#       line on stdout: the run status after the write. Everything below is decided inside one lock hold, from the
#       file as it is then, and written in one atomic write (so a checkpoint is set in the same write that marks
#       the step completed). A refusal exits 1, writes nothing and leaves the file byte-identical.
#       Checks, in this order:
#         0. Before any lock: bad arguments, a status word other than the four, --output with any status other
#            than completed, a repeated --output name, an --output without "=" or with an empty name: exit 2.
#            Then a bad run id (2) and an unknown run (3). --output splits on the FIRST "=", so a value may
#            contain "="; the value is stored as a string under the step's "outputs". Interpreting it (artifact
#            path versus data value) is E80_S03 and E80_S04's concern.
#         1. Unknown step id: exit 2, the message lists the valid step ids. A corrupt file is exit 4, a lock
#            timeout 5.
#         2. The run must be running or awaiting_confirmation. One exception: a paused run accepts completed or
#            failed for the step that is in_progress (the step that was running when the pause happened). Any
#            other step call on a paused, failed, completed or cancelled run: exit 1.
#         3. The step's own table (refused with exit 1 otherwise):
#              pending -> in_progress, skipped        in_progress -> completed, failed
#              failed -> in_progress (retry after a resume)
#              completed and skipped: final for this run, no move out of them (this is the store-level guarantee
#              that a completed step is never silently re-run). Moving to the same status is refused too.
#         4. Linear order: a step cannot move to in_progress while any earlier step is not completed or skipped.
#       What the write sets:
#         - started_at on the first in_progress (kept on a retry); finished_at on completed, failed and skipped,
#           and cleared again when a failed step goes back to in_progress. Both are UTC ISO 8601.
#         - --output pairs, merged into the step's "outputs" (completed only). --note text is kept as the step's
#           "note" and is appended to the history note of any run move this call causes.
#         - last_checkpoint = the step id, when a COMPLETED step has "checkpoint": true. A skipped step never
#           sets it and completing a non-checkpoint step never changes it.
#       The run status follows, every move checked with assert_transition and appended to "history" in the same
#       write:
#         - step failed: running or awaiting_confirmation -> failed.
#         - step completed while the run is awaiting_confirmation (the answer "yes" to await-confirmation):
#           awaiting_confirmation -> running.
#         - after that, when this call leaves every step completed or skipped (the last step was completed OR
#           skipped): running -> completed. (Both moves can happen
#           in one call, as two history entries, because the table has no awaiting_confirmation -> completed.)
#         - a paused run only records the step result. It stays paused, even when the step failed or was the last
#           one, because the table has no paused -> failed or paused -> completed edge; resume (E80_S02_T07)
#           works from the recorded steps.
#   run-state.sh await-confirmation <run_id> <step_id>
#       E80_S02_T06. For a step that is in_progress, moves the run running -> awaiting_confirmation and records
#       the step id in the history note ("awaiting confirmation: step <id>"). Prints ONE line on stdout: the new
#       run status. The answer is applied afterwards with "step <run_id> <step_id> completed" (yes; the run
#       returns to running) or "step <run_id> <step_id> failed" (no; the run becomes failed), so the confirm gate
#       itself stays E80_S03's concern. A step that is not in_progress: exit 1. A run that is not running (for
#       example already awaiting_confirmation, or paused): exit 1 through assert_transition. Unknown step: 2.
#   run-state.sh resume <run_id> [--allow-definition-change]
#       E80_S02_T07. Works from a brand-new process and session given only the run id: everything it needs is in
#       the state file plus the current definition. Prints ONE JSON object on stdout, human-readable notes go to
#       stderr:
#         {"run_id", "status", "resumed_from_checkpoint": <step id|null>, "next_step": {"id","type"}|null,
#          "definition_changed": true|false}
#       "status" is the run status after the write (running, or completed when no step is left).
#       Decided in this order, all inside one lock hold (the status is re-read there), in one atomic write; every
#       refusal writes nothing and leaves the file byte-identical:
#         1. Legal starting states, checked with assert_transition: paused, awaiting_confirmation and failed move
#            to running. completed and cancelled are refused (exit 1, the message names the status). A running run
#            is refused as "already running" (exit 1) UNLESS a step is in_progress (the session driving it ended
#            without reporting a result); that is recovered: the status stays running and a running -> running
#            history entry records it.
#         2. Definition guard. The definition is fetched again with "load-workflows.sh lookup <workflow_id>" and
#            hashed with definition_hash (the definition FILE, exactly as start hashed it) and compared with the
#            stored definition_hash.
#              - The definition no longer exists (or no longer validates, so the loader drops it): exit 6 with a
#                message distinct from the changed-hash one.
#              - Hashes differ and --allow-definition-change is absent: exit 6, the message names both hashes
#                (first 12 hex characters each), says the definition changed since the run started and that
#                --allow-definition-change accepts it.
#              - Hashes differ and the flag is given: steps are matched by id. A step id in the state that the
#                changed definition no longer has: exit 6 even with the flag (the stored steps can no longer be
#                mapped), the message names the ids. Otherwise the resume proceeds, definition_change_ack is set to
#                {at, from_hash, to_hash} and the history note says so. The stored definition_hash is NOT rewritten,
#                so a later resume without the flag still sees the change; the ack and history are the audit trail.
#              - Hashes equal: definition_changed is false (the flag, if given, changes nothing).
#         3. Recovery of steps. A step that is in_progress or failed is reset to pending (started_at and finished_at
#            cleared, a step "note" of "interrupted; reset to pending on resume" or "retry after failure"), and the
#            history note of the resume says which ("... was in_progress (interrupted), reset to pending" and
#            "retry after failure: step <id> reset to pending").
#         4. Next step. The first step in definition order AFTER the step named by last_checkpoint (from the first
#            step when last_checkpoint is null) whose status is neither completed nor skipped. A completed step is
#            never reported, including one positioned after the checkpoint. When no step remains the run moves
#            running -> completed (two history entries, since the table has no paused -> completed edge) and
#            next_step is null.
#       Adjustments to the task text, recorded for E80_S02_T09's docs: the recovery of step 3 applies to EVERY legal
#       resume (a paused or awaiting_confirmation run can also hold an in_progress step, and a paused run a step that
#       failed while paused), not only to running and failed runs, because a new session has no live executor and the
#       step table refuses in_progress -> in_progress. The history of a resume is one entry {from: <status>, to:
#       running, note: "resumed; ..."} plus, when no step is left, a second {from: running, to: completed}.
#       Exit codes: 1 not resumable, 2 usage, 3 unknown run, 4 corrupt, 5 lock timeout, 6 definition changed or gone.
#   run-state.sh -h | --help
#       Prints the usage text on stdout, exit 0.
#   No arguments, or an unknown command or argument: usage on stderr, exit 2.
#   (__apply, __create, __transition, __step, __await and __resume are internal re-invocations used under the lock. Do not call them.)
#
# status and list never create a file or directory.
#
# ---------------------------------------------------------------------------
# RUN LIFECYCLE: THE TRANSITION TABLE (E80_S02_T05), the single place the legal status moves are defined
# ---------------------------------------------------------------------------
#   from                    legal moves to
#   running                 paused, awaiting_confirmation, failed, completed, cancelled
#   awaiting_confirmation   running, paused, failed, cancelled
#   paused                  running, cancelled
#   failed                  running (a retry resume, E80_S02_T07), cancelled
#   completed               none (terminal)
#   cancelled               none (terminal)
# Moving to the same status (x -> x) is always refused. The table is exactly the one proposed in the task; no
# adjustment was made, so E80_S02_T09 documents it as it stands. A refused move prints, on stderr:
#   run <id> is <from>; cannot move to <to> (legal from <from>: <list, comma separated, or "none, terminal">)
# Every command that changes "status" calls assert_transition (through run_state_transition); none checks
# statuses on its own.
#
# ---------------------------------------------------------------------------
# FUNCTIONS (available when this file is sourced)
# ---------------------------------------------------------------------------
# Sourcing prints nothing, exits nothing and creates nothing; it defines functions and two _RS_ variables.
#   run_state_path <run_id>
#       Validates the id (see above) and prints the state file path. Exit 2 on an invalid or empty id, before
#       the disk is touched; also 2 when the runs directory cannot be resolved.
#   run_state_read <run_id>
#       Prints the state JSON (keys sorted), or prints nothing on stdout and fails: 3 when the file is missing,
#       4 when it is unreadable, empty, not valid JSON, or valid JSON that lacks a required key or has a
#       schema_version other than 1. The message on stderr names the file and the problem.
#   run_state_update <run_id> <jq-filter> [jq args...]
#       The only writer. Under scripts/with-lock.sh on the state file it re-reads and re-validates the file,
#       applies "( <filter> ) | .updated_at = <now>" (the filter is wrapped in parentheses and cannot set
#       updated_at; the extra arguments, for example --arg k v, go to jq unchanged), writes a temporary file in the
#       same directory, validates the result with the same checks as a read and renames it over the state file.
#       A filter that fails, or a result that is not a valid state, removes the temporary file, leaves the state
#       file byte-identical and exits 2. A missing file exits 3, a corrupt one 4. A lock that could not be taken
#       within WITH_LOCK_TIMEOUT_SECONDS (with-lock.sh's own variable, default 30) exits 5 and writes nothing.
#   assert_transition <from> <to> [<run_id>]
#       Pure table check, touches nothing. Returns 0 when from -> to is legal; otherwise returns 1 and prints the
#       refusal message above on stderr (<run_id> is shown as "?" when omitted). Unknown status names are
#       refused too (message: "unknown status"). Reused by E80_S02_T06 and E80_S02_T07.
#   run_state_transition <run_id> <to> <note>
#       Moves a run to status <to>, appending a history entry {at, from, to, note} and setting updated_at.
#       Under scripts/with-lock.sh it re-reads the file, takes the current status from it, calls
#       assert_transition and writes through the same code as run_state_update, all inside one lock hold.
#       Exit 0 ok, 1 illegal move (file unchanged), 2 invalid id/internal failure, 3 unknown run, 4 corrupt
#       (nothing written), 5 lock timeout. Prints nothing on stdout.
#   run_state_step <run_id> <step_id> <status> [--output name=value ...] [--note text]
#       The step command above, as a function: same arguments, same one-line stdout, same exit codes.
#   run_state_await_confirmation <run_id> <step_id>
#       The await-confirmation command above, as a function.
#   run_state_resume <run_id> [--allow-definition-change]
#       The resume command above, as a function: same arguments, same JSON on stdout, same exit codes.
#   run_state_dir [--create]
#       Prints the runs directory. With --create it also runs mkdir -p on it; only write paths (start) pass
#       --create.
#   definition_hash [<file>|-]
#       Prints the SHA-256 (64 lowercase hex) of the definition in <file> (or on stdin when no argument or "-"),
#       normalised with "jq -S -c ." so key order and whitespace do not affect it while any change of a value
#       does. Uses "shasum -a 256", falling back to sha256sum. Exit 2 when the input is missing or not valid
#       JSON, or no hash tool exists. Reused by E80_S02_T07.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0  ok
#   1  refused transition (pause, cancel and run_state_transition, from E80_S02_T05 on; step and
#      await-confirmation from E80_S02_T06 on: illegal step move, run not accepting step reports, out-of-order
#      start, step not in_progress); also start, when no unique run id could be created
#   2  usage error: bad argument, invalid run id, rejected update filter or result, or the runs directory cannot
#      be resolved; for start also an unknown or invalid workflow definition and missing, unknown or duplicate
#      inputs; for step and await-confirmation also an unknown step id, a status word other than the four, and a
#      misused or malformed --output or --note
#   3  run not found
#   4  corrupt or unreadable state
#   5  lock timeout
#   6  resume only (E80_S02_T07): the workflow definition changed since the run started and
#      --allow-definition-change was not given, or it no longer exists, or a step id of the run is gone from it
#
# Requires jq. Compatible with macOS bash 3.2 and safe under "set -u".
# ---------------------------------------------------------------------------

_RS_SELF="${BASH_SOURCE[0]}"
_RS_DIR="$(cd "$(dirname "$_RS_SELF")" && pwd)"
_RS_SELF="$_RS_DIR/$(basename "$_RS_SELF")"

# The twelve required top-level keys of a state file, as a JSON array for jq.
_RS_REQUIRED_KEYS='["schema_version","run_id","workflow_id","definition_hash","inputs","status","created_at","updated_at","last_checkpoint","definition_change_ack","steps","history"]'

_rs_err() {
  printf '%s\n' "$*" >&2
}

_rs_usage_text() {
  cat <<'USAGE'
Usage: run-state.sh start <workflow_id> [--input k=v ...]
       run-state.sh status <run_id>
       run-state.sh pause <run_id>
       run-state.sh cancel <run_id>
       run-state.sh step <run_id> <step_id> <in_progress|completed|failed|skipped> [--output name=value ...] [--note text]
       run-state.sh await-confirmation <run_id> <step_id>
       run-state.sh resume <run_id> [--allow-definition-change]
       run-state.sh list
       run-state.sh -h | --help

  start <id>       create a run of workflow <id>; prints only the new run id
  status <run_id>  print the run's state JSON
  pause <run_id>   running or awaiting_confirmation -> paused; prints the new status
  cancel <run_id>  any non-terminal status -> cancelled; prints the new status
  step <run_id> <step_id> <status>
                   record a step's status (--output name=value only with completed, repeatable); prints the run status
  await-confirmation <run_id> <step_id>
                   in_progress step: run running -> awaiting_confirmation; prints the new status
  resume <run_id>  paused, awaiting_confirmation or failed -> running; prints JSON with the next step. Refuses (exit 6)
                   when the workflow definition changed since start unless --allow-definition-change is given
  list             one line per run: run_id, workflow_id, status, updated_at (tab separated)

Exit codes: 0 ok, 1 refused transition, 2 usage error, 3 run not found, 4 corrupt or unreadable state,
5 lock timeout, 6 definition changed since start.
USAGE
}

_rs_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Prints the runs directory. --create also makes it (write paths only).
run_state_dir() {
  local create=0 a dir
  for a in "$@"; do
    case "$a" in
      --create) create=1 ;;
      *) _rs_err "run-state: unknown argument '$a' to run_state_dir"; return 2 ;;
    esac
  done
  if ! dir=$(bash "$_RS_DIR/../resolve-root.sh" get workflow_runs) || [ -z "$dir" ]; then
    _rs_err "run-state: cannot resolve the workflow_runs directory"
    return 2
  fi
  if [ "$create" = "1" ]; then
    mkdir -p "$dir" || { _rs_err "run-state: cannot create '$dir'"; return 2; }
  fi
  printf '%s\n' "$dir"
}

# True when $1 is a usable run id. Pure string check, never touches the disk.
_rs_valid_id() {
  local id="$1"
  [ -n "$id" ] || return 1
  case "$id" in
    .*|*..*) return 1 ;;
  esac
  [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]]
}

run_state_path() {
  local id="${1-}" dir
  if [ "$#" -ne 1 ] || ! _rs_valid_id "$id"; then
    _rs_err "run-state: invalid run id '${id}' (allowed: letters, digits, '.', '_', '-'; no '..', no leading '.', not empty)"
    return 2
  fi
  dir=$(run_state_dir) || return 2
  printf '%s/%s.json\n' "$dir" "$id"
}

# Checks state file $1. Returns 0 valid, 3 missing, 4 corrupt or unreadable. Sets _RS_REASON to a short
# description of the problem (empty when valid). Prints nothing.
_rs_check() {
  local f="$1"
  _RS_REASON=""
  if [ ! -e "$f" ]; then
    _RS_REASON="file does not exist"
    return 3
  fi
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    _RS_REASON="not a readable regular file"
    return 4
  fi
  if [ ! -s "$f" ]; then
    _RS_REASON="file is empty"
    return 4
  fi
  if ! jq -e -s 'length == 1' "$f" >/dev/null 2>&1; then
    _RS_REASON="not valid JSON (or not a single JSON document)"
    return 4
  fi
  _RS_REASON=$(jq -r --argjson req "$_RS_REQUIRED_KEYS" '
    if type != "object" then "top level is not a JSON object"
    else . as $o
      | ($req | map(select(. as $k | $o | has($k) | not))) as $missing
      | if ($missing | length) > 0 then "missing required key(s): " + ($missing | join(", "))
        elif .schema_version != 1 then "unsupported schema_version " + (.schema_version | tojson) + " (expected 1)"
        else empty end
    end' "$f" 2>/dev/null)
  if [ -n "$_RS_REASON" ]; then
    return 4
  fi
  return 0
}

# Reports a failed _rs_check for $1 (status $2) on stderr, with prefix $3.
_rs_report() {
  local f="$1" rc="$2" prefix="${3-}"
  if [ "$rc" = "3" ]; then
    _rs_err "${prefix}run-state: run not found: $f"
  else
    _rs_err "${prefix}run-state: corrupt state file $f: $_RS_REASON"
  fi
}

run_state_read() {
  local f rc out
  f=$(run_state_path "$@") || return $?
  _rs_check "$f"; rc=$?
  if [ "$rc" != "0" ]; then
    _rs_report "$f" "$rc"
    return "$rc"
  fi
  out=$(jq -S . "$f" 2>/dev/null) || { _RS_REASON="could not be parsed"; _rs_report "$f" 4; return 4; }
  printf '%s\n' "$out"
}

# Runs inside the lock (called via the internal __apply command). Exit codes 0, 3, 4 are passed through by
# run_state_update; 12 means the filter failed or produced an invalid state. 12, not 2, so a failure here can
# never be mistaken for with-lock.sh's own exit 2 (lock timeout).
_rs_apply() {
  local id="${1-}" filter="${2-}" f rc tmp now
  [ "$#" -ge 2 ] || return 12
  shift 2
  f=$(run_state_path "$id") || return 12
  _rs_check "$f"; rc=$?
  if [ "$rc" != "0" ]; then
    _rs_report "$f" "$rc"
    return "$rc"
  fi
  tmp="$(dirname "$f")/.tmp-${id}.$$"
  now=$(_rs_now)
  if ! jq --arg __rs_now "$now" "$@" "($filter) | .updated_at = \$__rs_now" "$f" > "$tmp"; then
    rm -f "$tmp"
    _rs_err "run-state: update of $id rejected: the jq filter failed; state file unchanged"
    return 12
  fi
  _rs_check "$tmp"; rc=$?
  if [ "$rc" != "0" ]; then
    rm -f "$tmp"
    _rs_err "run-state: update of $id rejected: the result is not a valid state ($_RS_REASON); state file unchanged"
    return 12
  fi
  if ! mv -f "$tmp" "$f"; then
    rm -f "$tmp"
    _rs_err "run-state: update of $id failed: could not replace $f"
    return 12
  fi
  return 0
}

run_state_update() {
  local id="${1-}" filter="${2-}" f rc
  if [ "$#" -lt 2 ]; then
    _rs_err "Usage: run_state_update <run_id> <jq-filter> [jq args...]"
    return 2
  fi
  f=$(run_state_path "$id") || return $?
  # A run that does not exist is reported before any lock is taken (the directory may not even exist).
  if [ ! -e "$f" ]; then
    _rs_check "$f"; rc=$?
    _rs_report "$f" "$rc"
    return "$rc"
  fi
  shift 2
  "${BASH:-bash}" "$_RS_DIR/../with-lock.sh" "$f" -- "${BASH:-bash}" "$_RS_SELF" __apply "$id" "$filter" "$@"
  rc=$?
  case "$rc" in
    0|3|4) return "$rc" ;;
    2)
      _rs_err "run-state: could not lock $f (another process holds it); nothing was written"
      return 5
      ;;
    *) return 2 ;;
  esac
}

# The legal moves out of status $1, space separated (empty for a terminal status). Returns 1 for an unknown
# status. This case statement is the transition table.
_rs_legal_moves() {
  case "$1" in
    running) printf '%s\n' "paused awaiting_confirmation failed completed cancelled" ;;
    awaiting_confirmation) printf '%s\n' "running paused failed cancelled" ;;
    paused) printf '%s\n' "running cancelled" ;;
    failed) printf '%s\n' "running cancelled" ;;
    completed|cancelled) printf '%s\n' "" ;;
    *) return 1 ;;
  esac
}

# assert_transition <from> <to> [<run_id>]: 0 when legal; otherwise 1 with the refusal message on stderr.
assert_transition() {
  local from="${1-}" to="${2-}" id="${3:-?}" legal m list
  if [ "$#" -lt 2 ]; then
    _rs_err "Usage: assert_transition <from> <to> [<run_id>]"
    return 1
  fi
  if ! legal=$(_rs_legal_moves "$from"); then
    _rs_err "run $id has unknown status '$from'; cannot move to '$to'"
    return 1
  fi
  if ! _rs_legal_moves "$to" >/dev/null; then
    _rs_err "run $id is $from; cannot move to unknown status '$to'"
    return 1
  fi
  for m in $legal; do
    [ "$m" = "$to" ] && return 0
  done
  if [ -z "$legal" ]; then
    list="none, terminal"
  else
    list="${legal// /, }"
  fi
  _rs_err "run $id is $from; cannot move to $to (legal from $from: $list)"
  return 1
}

# Runs inside the lock (called via the internal __transition command). Exit 0, 1 (illegal), 3, 4 are passed
# through by run_state_transition; 12 means an internal failure.
_rs_transition_locked() {
  local id="${1-}" to="${2-}" note="${3-}" f rc from
  [ "$#" -eq 3 ] || return 12
  f=$(run_state_path "$id") || return 12
  _rs_check "$f"; rc=$?
  if [ "$rc" != "0" ]; then
    _rs_report "$f" "$rc"
    return "$rc"
  fi
  # Read the status now, under the lock: a value read before the lock could already be stale.
  from=$(jq -r '.status' "$f" 2>/dev/null) || return 12
  assert_transition "$from" "$to" "$id" || return 1
  _rs_apply "$id" '.status as $f | .status = $__to
    | .history += [{at: $__rs_now, from: $f, to: $__to, note: $__note}]' \
    --arg __to "$to" --arg __note "$note"
}

run_state_transition() {
  local id="${1-}" to="${2-}" note="${3-}" f rc
  if [ "$#" -ne 3 ]; then
    _rs_err "Usage: run_state_transition <run_id> <to> <note>"
    return 2
  fi
  f=$(run_state_path "$id") || return $?
  if [ ! -e "$f" ]; then
    _rs_check "$f"; rc=$?
    _rs_report "$f" "$rc"
    return "$rc"
  fi
  "${BASH:-bash}" "$_RS_DIR/../with-lock.sh" "$f" -- "${BASH:-bash}" "$_RS_SELF" __transition "$id" "$to" "$note"
  rc=$?
  case "$rc" in
    0|1|3|4) return "$rc" ;;
    2)
      _rs_err "run-state: could not lock $f (another process holds it); nothing was written"
      return 5
      ;;
    *) return 2 ;;
  esac
}

# Prints the SHA-256 of a definition (file argument, or stdin for none or "-") normalised with jq -S -c .
definition_hash() {
  local src="${1-}" norm sum
  if [ -z "$src" ] || [ "$src" = "-" ]; then
    norm=$(jq -S -c . 2>/dev/null) || { _rs_err "run-state: definition_hash: input is not valid JSON"; return 2; }
  else
    if [ ! -r "$src" ]; then
      _rs_err "run-state: definition_hash: cannot read '$src'"
      return 2
    fi
    norm=$(jq -S -c . "$src" 2>/dev/null) || { _rs_err "run-state: definition_hash: '$src' is not valid JSON"; return 2; }
  fi
  if [ -z "$norm" ]; then
    _rs_err "run-state: definition_hash: empty input"
    return 2
  fi
  if command -v shasum >/dev/null 2>&1; then
    sum=$(printf '%s\n' "$norm" | shasum -a 256)
  elif command -v sha256sum >/dev/null 2>&1; then
    sum=$(printf '%s\n' "$norm" | sha256sum)
  else
    _rs_err "run-state: definition_hash: neither shasum nor sha256sum is available"
    return 2
  fi
  printf '%s\n' "${sum%% *}"
}

# Finds and validates the definition of workflow $1. Sets _RS_DEF_FILE. Returns 0, or 2 with a message.
_rs_find_definition() {
  local id="$1" catalog dirs d f verr rc
  _RS_DEF_FILE=""
  if ! catalog=$(bash "$_RS_DIR/load-workflows.sh" 2>/dev/null); then
    bash "$_RS_DIR/load-workflows.sh" >/dev/null   # pass the loader's own message through
    _rs_err "run-state: could not load the workflow catalog"
    return 2
  fi
  _RS_DEF_FILE=$(printf '%s\n' "$catalog" | jq -r --arg id "$id" 'map(select(.id == $id)) | (.[0].file // empty)' 2>/dev/null)
  if [ -z "$_RS_DEF_FILE" ]; then
    # Not in the catalog: either unknown, or present but dropped by the loader as invalid.
    dirs=$( ( . "$_RS_DIR/lib.sh" && workflow_builtin_dir && workflow_project_dir ) 2>/dev/null )
    while IFS= read -r d; do
      [ -n "$d" ] && [ -d "$d" ] || continue
      for f in "$d"/*.json; do
        [ -f "$f" ] || continue
        jq -e --arg id "$id" '.id? == $id' "$f" >/dev/null 2>&1 || continue
        verr=$(bash "$_RS_DIR/validate-workflow.sh" "$f" 2>&1 >/dev/null)
        _rs_err "run-state: workflow '$id' is not a valid definition ($f):"
        printf '%s\n' "$verr" | sed 's/^/  /' >&2
        return 2
      done
    done <<EOF
$dirs
EOF
    _rs_err "run-state: unknown workflow id '$id'"
    return 2
  fi
  verr=$(bash "$_RS_DIR/validate-workflow.sh" "$_RS_DEF_FILE" 2>&1 >/dev/null); rc=$?
  if [ "$rc" != "0" ]; then
    _rs_err "run-state: workflow '$id' is not a valid definition ($_RS_DEF_FILE):"
    printf '%s\n' "$verr" | sed 's/^/  /' >&2
    return 2
  fi
  return 0
}

# Runs inside the lock (called via the internal __create command): writes the new state file $1 from the JSON in
# $2. Exit 9 when the file already exists (the caller regenerates the id), 12 on any other failure.
_rs_create() {
  local id="${1-}" json="${2-}" f tmp rc
  [ "$#" -eq 2 ] || return 12
  f=$(run_state_path "$id") || return 12
  if [ -e "$f" ] || [ -L "$f" ]; then
    return 9
  fi
  tmp="$(dirname "$f")/.tmp-${id}.$$"
  if ! printf '%s\n' "$json" > "$tmp"; then
    rm -f "$tmp"
    _rs_err "run-state: could not write a temporary file for $id"
    return 12
  fi
  _rs_check "$tmp"; rc=$?
  if [ "$rc" != "0" ]; then
    rm -f "$tmp"
    _rs_err "run-state: new state for $id is not valid ($_RS_REASON); nothing written"
    return 12
  fi
  if ! mv -f "$tmp" "$f"; then
    rm -f "$tmp"
    _rs_err "run-state: could not create $f"
    return 12
  fi
  return 0
}

_rs_cmd_start() {
  local wid="" supplied='{}' kv k v check missing unknown msg hash eff dir
  local attempt ts hex run_id f now state rc

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --input)
        if [ "$#" -lt 2 ]; then
          _rs_err "run-state: --input needs a k=v argument"
          return 2
        fi
        kv="$2"
        shift 2
        case "$kv" in
          *=*) ;;
          *) _rs_err "run-state: --input expects k=v, got '$kv'"; return 2 ;;
        esac
        k="${kv%%=*}"
        v="${kv#*=}"
        if [ -z "$k" ]; then
          _rs_err "run-state: --input has an empty key: '$kv'"
          return 2
        fi
        if jq -e --arg k "$k" 'has($k)' <<<"$supplied" >/dev/null; then
          _rs_err "run-state: duplicate --input key '$k'"
          return 2
        fi
        supplied=$(jq -c --arg k "$k" --arg v "$v" '. + {($k): $v}' <<<"$supplied") || return 2
        ;;
      -*)
        _rs_err "run-state: unknown option '$1' for start"
        _rs_usage_text >&2
        return 2
        ;;
      *)
        if [ -n "$wid" ]; then
          _rs_err "run-state: start takes one workflow id; got '$wid' and '$1'"
          return 2
        fi
        wid="$1"
        shift
        ;;
    esac
  done
  if [ -z "$wid" ]; then
    _rs_usage_text >&2
    return 2
  fi
  if ! [[ "$wid" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    _rs_err "run-state: invalid workflow id '$wid' (lowercase letters, digits and single hyphens)"
    return 2
  fi
  command -v jq >/dev/null 2>&1 || { _rs_err "run-state: jq is required"; return 2; }

  _rs_find_definition "$wid" || return 2

  check=$(jq -c --argjson sup "$supplied" '
    [(.inputs // [])[] | select(type == "object" and has("name"))] as $decl
    | ($decl | map(.name)) as $names
    | { missing: [$decl[] | select((has("default") | not) and (. as $d | $sup | has($d.name) | not)) | .name],
        unknown: [$sup | keys_unsorted[] | select(. as $k | ($names | any(. == $k)) | not)],
        inputs:  (reduce $decl[] as $d ({}; if ($d | has("default")) then . + {($d.name): $d.default} else . end) + $sup) }
  ' "$_RS_DEF_FILE") || { _rs_err "run-state: could not read the inputs of $_RS_DEF_FILE"; return 2; }
  missing=$(jq -r '.missing | join(", ")' <<<"$check")
  unknown=$(jq -r '.unknown | join(", ")' <<<"$check")
  if [ -n "$missing" ] || [ -n "$unknown" ]; then
    msg="run-state: cannot start '$wid':"
    [ -z "$missing" ] || msg="$msg missing input(s): $missing;"
    [ -z "$unknown" ] || msg="$msg unknown input(s): $unknown;"
    _rs_err "${msg%;}"
    return 2
  fi
  eff=$(jq -c '.inputs' <<<"$check")

  hash=$(definition_hash "$_RS_DEF_FILE") || return 2

  # Every check has passed; from here on the command may write.
  dir=$(run_state_dir --create) || return 2
  attempt=0
  while [ "$attempt" -lt 5 ]; do
    attempt=$((attempt + 1))
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    hex=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
    run_id="wf-${wid}-${ts}-${hex}"
    f=$(run_state_path "$run_id") || return 2
    now=$(_rs_now)
    state=$(jq -n --arg id "$run_id" --arg wf "$wid" --arg h "$hash" --argjson inputs "$eff" --arg now "$now" \
      --slurpfile def "$_RS_DEF_FILE" '
      $def[0] as $d
      | { schema_version: 1, run_id: $id, workflow_id: $wf, definition_hash: $h, inputs: $inputs,
          status: "running", created_at: $now, updated_at: $now, last_checkpoint: null,
          definition_change_ack: null,
          steps: [$d.steps[] | {id: .id, type: .type, checkpoint: (.checkpoint == true), status: "pending",
                                started_at: null, finished_at: null, outputs: {}}],
          history: [{at: $now, from: null, to: "running", note: "started"}] }') || {
      _rs_err "run-state: could not build the state for '$wid'"
      return 2
    }
    "${BASH:-bash}" "$_RS_DIR/../with-lock.sh" "$f" -- "${BASH:-bash}" "$_RS_SELF" __create "$run_id" "$state"
    rc=$?
    case "$rc" in
      0)
        printf '%s\n' "$run_id"
        return 0
        ;;
      9) continue ;;
      2)
        _rs_err "run-state: could not lock $f (another process holds it); nothing was written"
        return 5
        ;;
      *)
        _rs_err "run-state: could not create the run state for '$wid'"
        return 1
        ;;
    esac
  done
  _rs_err "run-state: could not generate an unused run id for '$wid' after 5 attempts"
  return 1
}

# The legal moves of a STEP out of status $1, space separated (empty for a final status). Returns 1 for an
# unknown status. Per-step table of E80_S02_T06: completed and skipped are final for the run.
_rs_step_legal_moves() {
  case "$1" in
    pending) printf '%s\n' "in_progress skipped" ;;
    in_progress) printf '%s\n' "completed failed" ;;
    failed) printf '%s\n' "in_progress" ;;
    completed|skipped) printf '%s\n' "" ;;
    *) return 1 ;;
  esac
}

# Runs inside the lock (internal __step command): records step $2 of run $1 as status $3. $4 is 1 when a note was
# given (then $5 is it), $6 is the JSON object of --output pairs. Prints the run status after the write on
# stdout. Exit 0 ok, 1 refused (nothing written), 3, 4 as for every command, 12 usage-class failure (unknown
# step id, internal failure; mapped to 2 by the caller so it is never mistaken for with-lock.sh's exit 2).
_rs_step_locked() {
  local id="${1-}" sid="${2-}" to="${3-}" has_note="${4-}" note="${5-}" outputs="${6-}"
  local f rc info run cur found ids open all_done legal m list ok suffix moves cur_run
  [ "$#" -eq 6 ] || return 12
  f=$(run_state_path "$id") || return 12
  _rs_check "$f"; rc=$?
  if [ "$rc" != "0" ]; then
    _rs_report "$f" "$rc"
    return "$rc"
  fi
  # Everything the decision needs is read now, under the lock: a value read before the lock could be stale.
  info=$(jq -c --arg sid "$sid" --arg to "$to" '
    ([.steps[].id]) as $ids
    | ($ids | index($sid)) as $i
    | { run: .status, ids: ($ids | join(", ")), found: ($i != null),
        cur: (if $i == null then "" else .steps[$i].status end),
        open: (if $i == null then "" else
                 ([.steps[:$i][] | select(.status != "completed" and .status != "skipped") | .id + " (" + .status + ")"] | join(", "))
               end),
        done: ([.steps[] | if .id == $sid then $to else .status end] | all(. == "completed" or . == "skipped")) }
  ' "$f") || return 12
  run=$(jq -r '.run' <<<"$info")
  found=$(jq -r '.found' <<<"$info")
  ids=$(jq -r '.ids' <<<"$info")
  cur=$(jq -r '.cur' <<<"$info")
  open=$(jq -r '.open' <<<"$info")
  all_done=$(jq -r '.done' <<<"$info")

  if [ "$found" != "true" ]; then
    _rs_err "run-state: run $id has no step '$sid' (valid step ids: ${ids:-none})"
    return 12
  fi

  # The run must be accepting step reports. A paused run accepts only the result of the step that was in_progress
  # when the pause happened.
  ok=0
  case "$run" in
    running|awaiting_confirmation) ok=1 ;;
    paused)
      if [ "$cur" = "in_progress" ] && { [ "$to" = "completed" ] || [ "$to" = "failed" ]; }; then ok=1; fi
      ;;
  esac
  if [ "$ok" != "1" ]; then
    if [ "$run" = "paused" ]; then
      _rs_err "run $id is paused; step $sid is $cur and cannot move to $to (a paused run only accepts the result of its in_progress step)"
    else
      _rs_err "run $id is $run; step $sid cannot move to $to (step is accepted only while the run is running or awaiting_confirmation)"
    fi
    return 1
  fi

  # The step's own table.
  legal=$(_rs_step_legal_moves "$cur") || { _rs_err "run $id: step $sid has unknown status '$cur'"; return 1; }
  ok=0
  for m in $legal; do
    [ "$m" = "$to" ] && ok=1
  done
  if [ "$ok" != "1" ]; then
    if [ -z "$legal" ]; then
      list="none, final for this run"
    else
      list="${legal// /, }"
    fi
    _rs_err "run $id: step $sid is $cur; cannot move to $to (legal from $cur: $list)"
    return 1
  fi

  # Linear v1 order: a step starts only after every earlier step is completed or skipped.
  if [ "$to" = "in_progress" ] && [ -n "$open" ]; then
    _rs_err "run $id: step $sid cannot start; earlier step(s) not completed or skipped: $open"
    return 1
  fi

  # The run moves that follow, each checked against the lifecycle table in sequence.
  suffix=""
  if [ "$has_note" = "1" ] && [ -n "$note" ]; then
    suffix=": $note"
  fi
  moves="[]"
  cur_run="$run"
  if [ "$run" != "paused" ]; then
    if [ "$to" = "failed" ]; then
      assert_transition "$cur_run" failed "$id" || return 1
      moves=$(jq -c --arg n "step $sid failed$suffix" '. + [{to: "failed", note: $n}]' <<<"$moves") || return 12
      cur_run="failed"
    fi
    if [ "$to" = "completed" ] || { [ "$to" = "skipped" ] && [ "$all_done" = "true" ]; }; then
      # The table has no awaiting_confirmation -> completed edge, so an awaiting run goes through running first.
      if [ "$cur_run" = "awaiting_confirmation" ]; then
        assert_transition "$cur_run" running "$id" || return 1
        moves=$(jq -c --arg n "confirmation answered: step $sid $to$suffix" '. + [{to: "running", note: $n}]' <<<"$moves") || return 12
        cur_run="running"
      fi
      if [ "$all_done" = "true" ]; then
        assert_transition "$cur_run" completed "$id" || return 1
        moves=$(jq -c --arg n "all steps finished (last: $sid)" '. + [{to: "completed", note: $n}]' <<<"$moves") || return 12
        cur_run="completed"
      fi
    fi
  fi

  _rs_apply "$id" '
    (.steps | map(.id) | index($__sid)) as $i
    | .steps[$i] |= (
        .status = $__to
        | (if $__to == "in_progress"
             then .started_at = (.started_at // $__rs_now) | .finished_at = null
             else .finished_at = $__rs_now end)
        | (if $__to == "completed" then .outputs = ((.outputs // {}) + $__outputs) else . end)
        | (if $__has_note == 1 then .note = $__note else . end))
    | (if $__to == "completed" and .steps[$i].checkpoint == true then .last_checkpoint = $__sid else . end)
    | reduce $__moves[] as $m (.; .history += [{at: $__rs_now, from: .status, to: $m.to, note: $m.note}] | .status = $m.to)' \
    --arg __sid "$sid" --arg __to "$to" --argjson __has_note "$has_note" --arg __note "$note" \
    --argjson __outputs "$outputs" --argjson __moves "$moves" || return $?
  printf '%s\n' "$cur_run"
}

# Runs inside the lock (internal __await command): run $1 running -> awaiting_confirmation for step $2, which
# must be in_progress. Prints the new run status on stdout. Exit codes as for _rs_step_locked.
_rs_await_locked() {
  local id="${1-}" sid="${2-}" f rc info found ids cur run
  [ "$#" -eq 2 ] || return 12
  f=$(run_state_path "$id") || return 12
  _rs_check "$f"; rc=$?
  if [ "$rc" != "0" ]; then
    _rs_report "$f" "$rc"
    return "$rc"
  fi
  info=$(jq -c --arg sid "$sid" '
    ([.steps[].id]) as $ids
    | ($ids | index($sid)) as $i
    | { run: .status, ids: ($ids | join(", ")), found: ($i != null),
        cur: (if $i == null then "" else .steps[$i].status end) }' "$f") || return 12
  run=$(jq -r '.run' <<<"$info")
  found=$(jq -r '.found' <<<"$info")
  ids=$(jq -r '.ids' <<<"$info")
  cur=$(jq -r '.cur' <<<"$info")
  if [ "$found" != "true" ]; then
    _rs_err "run-state: run $id has no step '$sid' (valid step ids: ${ids:-none})"
    return 12
  fi
  if [ "$cur" != "in_progress" ]; then
    _rs_err "run $id: step $sid is $cur; await-confirmation needs a step that is in_progress"
    return 1
  fi
  assert_transition "$run" awaiting_confirmation "$id" || return 1
  _rs_apply "$id" '.status as $f | .status = "awaiting_confirmation"
    | .history += [{at: $__rs_now, from: $f, to: "awaiting_confirmation", note: $__note}]' \
    --arg __note "awaiting confirmation: step $sid" || return $?
  printf '%s\n' "awaiting_confirmation"
}

# Calls the internal command "$2..." of this script for run "$1" under scripts/with-lock.sh and maps its status:
# 0, 1, 3, 4 pass through, with-lock's own exit 2 (lock timeout) becomes 5, anything else becomes 2.
_rs_locked_call() {
  local id="${1-}" f rc
  shift
  f=$(run_state_path "$id") || return $?
  if [ ! -e "$f" ]; then
    _rs_check "$f"; rc=$?
    _rs_report "$f" "$rc"
    return "$rc"
  fi
  "${BASH:-bash}" "$_RS_DIR/../with-lock.sh" "$f" -- "${BASH:-bash}" "$_RS_SELF" "$@"
  rc=$?
  case "$rc" in
    0|1|3|4) return "$rc" ;;
    2)
      _rs_err "run-state: could not lock $f (another process holds it); nothing was written"
      return 5
      ;;
    *) return 2 ;;
  esac
}

# run_state_step <run_id> <step_id> <in_progress|completed|failed|skipped> [--output name=value ...] [--note text]
run_state_step() {
  local id="" sid="" to="" npos=0 has_note=0 note="" outputs='{}' nout=0 kv k v
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --output)
        if [ "$#" -lt 2 ]; then
          _rs_err "run-state: --output needs a name=value argument"
          return 2
        fi
        kv="$2"
        shift 2
        case "$kv" in
          *=*) ;;
          *) _rs_err "run-state: --output expects name=value, got '$kv'"; return 2 ;;
        esac
        k="${kv%%=*}"
        v="${kv#*=}"
        if [ -z "$k" ]; then
          _rs_err "run-state: --output has an empty name: '$kv'"
          return 2
        fi
        if jq -e --arg k "$k" 'has($k)' <<<"$outputs" >/dev/null; then
          _rs_err "run-state: duplicate --output name '$k'"
          return 2
        fi
        outputs=$(jq -c --arg k "$k" --arg v "$v" '. + {($k): $v}' <<<"$outputs") || return 2
        nout=$((nout + 1))
        ;;
      --note)
        if [ "$#" -lt 2 ]; then
          _rs_err "run-state: --note needs a text argument"
          return 2
        fi
        if [ "$has_note" = "1" ]; then
          _rs_err "run-state: --note given twice"
          return 2
        fi
        has_note=1
        note="$2"
        shift 2
        ;;
      -*)
        _rs_err "run-state: unknown option '$1' for step"
        _rs_usage_text >&2
        return 2
        ;;
      *)
        case "$npos" in
          0) id="$1" ;;
          1) sid="$1" ;;
          2) to="$1" ;;
          *) _rs_err "run-state: step takes <run_id> <step_id> <status>; unexpected argument '$1'"; return 2 ;;
        esac
        npos=$((npos + 1))
        shift
        ;;
    esac
  done
  if [ "$npos" -ne 3 ] || [ -z "$sid" ]; then
    _rs_usage_text >&2
    return 2
  fi
  case "$to" in
    in_progress|completed|failed|skipped) ;;
    *) _rs_err "run-state: invalid step status '$to' (allowed: in_progress, completed, failed, skipped)"; return 2 ;;
  esac
  if [ "$nout" -gt 0 ] && [ "$to" != "completed" ]; then
    _rs_err "run-state: --output is only allowed with the status completed (got '$to')"
    return 2
  fi
  command -v jq >/dev/null 2>&1 || { _rs_err "run-state: jq is required"; return 2; }
  _rs_locked_call "$id" __step "$id" "$sid" "$to" "$has_note" "$note" "$outputs"
}

# run_state_await_confirmation <run_id> <step_id>
run_state_await_confirmation() {
  if [ "$#" -ne 2 ] || [ -z "$2" ]; then
    _rs_usage_text >&2
    return 2
  fi
  command -v jq >/dev/null 2>&1 || { _rs_err "run-state: jq is required"; return 2; }
  _rs_locked_call "$1" __await "$1" "$2"
}

# Runs inside the lock (internal __resume command): resumes run $1. $2 is 1 when --allow-definition-change was
# given. $3 is "found" or "missing" (the definition lookup done by run_state_resume), $4 the SHA-256 of the current
# definition file, $5 the JSON array of its step ids, $6 the lookup's own message when it is missing. Prints the
# result object on stdout. Exit 0 ok, 1 refused (nothing written), 3, 4 as for every command, 6 definition changed
# or gone (nothing written), 12 internal failure (mapped to 2 by the caller).
_rs_resume_locked() {
  local id="${1-}" allow="${2-}" defstate="${3-}" curhash="${4-}" defids="${5-}" defmsg="${6-}"
  local f rc plan status interrupted failed next missing storedhash changed complete note now ack
  local fromshort toshort
  [ "$#" -eq 6 ] || return 12
  f=$(run_state_path "$id") || return 12
  _rs_check "$f"; rc=$?
  if [ "$rc" != "0" ]; then
    _rs_report "$f" "$rc"
    return "$rc"
  fi
  # Everything is decided from the file as it is now, under the lock. Statuses are read first, the rest is derived
  # from the same read.
  plan=$(jq -c --argjson def "$defids" '
    ([.steps[].id]) as $ids
    | .last_checkpoint as $cp
    | (if $cp == null then 0
       else (($ids | index($cp)) as $i | if $i == null then 0 else $i + 1 end) end) as $start
    | { status: .status, hash: .definition_hash, checkpoint: .last_checkpoint,
        interrupted: [.steps[] | select(.status == "in_progress") | .id],
        failed: [.steps[] | select(.status == "failed") | .id],
        missing: ([$ids[] | select(. as $x | $def | index($x) | not)]),
        next: ([.steps[$start:][] | select(.status != "completed" and .status != "skipped")
                | {id: .id, type: .type}] | first // null) }' "$f") || return 12
  status=$(jq -r '.status' <<<"$plan")
  storedhash=$(jq -r '.hash' <<<"$plan")
  interrupted=$(jq -r '.interrupted | join(", ")' <<<"$plan")
  failed=$(jq -r '.failed | join(", ")' <<<"$plan")
  missing=$(jq -r '.missing | join(", ")' <<<"$plan")
  next=$(jq -c '.next' <<<"$plan")

  # 1. Is the run resumable at all?
  if [ "$status" = "running" ]; then
    if [ -z "$interrupted" ]; then
      _rs_err "run $id is already running; nothing to resume (a running run is resumable only while a step is in_progress)"
      return 1
    fi
  else
    assert_transition "$status" running "$id" || return 1
  fi

  # 2. The definition guard.
  if [ "$defstate" != "found" ]; then
    _rs_err "run-state: cannot resume $id: the workflow definition it was started from no longer exists or is no longer valid; nothing was changed"
    [ -z "$defmsg" ] || printf '%s\n' "$defmsg" | sed 's/^/  /' >&2
    return 6
  fi
  changed=false
  ack=null
  fromshort=$(printf '%.12s' "$storedhash")
  toshort=$(printf '%.12s' "$curhash")
  if [ "$curhash" != "$storedhash" ]; then
    if [ "$allow" != "1" ]; then
      _rs_err "run-state: cannot resume $id: the workflow definition changed since the run started (stored hash ${fromshort}, current hash ${toshort}); pass --allow-definition-change to accept the change; nothing was changed"
      return 6
    fi
    if [ -n "$missing" ]; then
      _rs_err "run-state: cannot resume $id even with --allow-definition-change: step id(s) in the run state no longer exist in the changed definition: $missing; nothing was changed"
      return 6
    fi
    changed=true
  fi

  # 3. What happens, then one atomic write.
  complete=false
  [ "$next" != "null" ] || complete=true
  if [ "$complete" = "true" ]; then
    assert_transition running completed "$id" || return 1
  fi
  note="resumed"
  if [ -n "$interrupted" ]; then
    note="$note; step ${interrupted} was in_progress (interrupted), reset to pending"
  fi
  if [ -n "$failed" ]; then
    note="$note; retry after failure: step ${failed} reset to pending"
  fi
  if [ "$changed" = "true" ]; then
    note="$note; definition change accepted (--allow-definition-change): ${fromshort} -> ${toshort}"
  fi
  now=$(_rs_now)
  if [ "$changed" = "true" ]; then
    ack=$(jq -nc --arg at "$now" --arg a "$storedhash" --arg b "$curhash" '{at: $at, from_hash: $a, to_hash: $b}') || return 12
  fi
  _rs_apply "$id" '
    .status as $f
    | .steps |= map(
        if .status == "in_progress"
          then .status = "pending" | .started_at = null | .finished_at = null | .note = "interrupted; reset to pending on resume"
        elif .status == "failed"
          then .status = "pending" | .started_at = null | .finished_at = null | .note = "retry after failure"
        else . end)
    | (if $__ack != null then .definition_change_ack = $__ack else . end)
    | .status = "running"
    | .history += [{at: $__rs_now, from: $f, to: "running", note: $__note}]
    | (if $__complete then .status = "completed"
         | .history += [{at: $__rs_now, from: "running", to: "completed", note: "resumed: no step left to run"}]
       else . end)' \
    --argjson __ack "$ack" --arg __note "$note" --argjson __complete "$complete" || return $?
  [ -z "$interrupted" ] || _rs_err "run-state: $id: interrupted step ${interrupted} reset to pending"
  [ -z "$failed" ] || _rs_err "run-state: $id: failed step ${failed} reset to pending (retry after failure)"
  [ "$changed" != "true" ] || _rs_err "run-state: $id: definition changed (${fromshort} -> ${toshort}); accepted with --allow-definition-change"
  [ "$complete" != "true" ] || _rs_err "run-state: $id: every step is completed or skipped; run completed"
  jq -nc --arg id "$id" --argjson p "$plan" --argjson complete "$complete" --argjson changed "$changed" '
    { run_id: $id, status: (if $complete then "completed" else "running" end),
      resumed_from_checkpoint: $p.checkpoint, next_step: $p.next, definition_changed: $changed }'
}

# run_state_resume <run_id> [--allow-definition-change]
run_state_resume() {
  local id="" allow=0 a f rc wid hash lk file errf defstate defhash defids defmsg
  for a in "$@"; do
    case "$a" in
      --allow-definition-change) allow=1 ;;
      -*) _rs_err "run-state: unknown option '$a' for resume"; _rs_usage_text >&2; return 2 ;;
      *)
        if [ -n "$id" ]; then
          _rs_err "run-state: resume takes one run id; got '$id' and '$a'"
          return 2
        fi
        id="$a"
        ;;
    esac
  done
  if [ -z "$id" ]; then
    _rs_usage_text >&2
    return 2
  fi
  command -v jq >/dev/null 2>&1 || { _rs_err "run-state: jq is required"; return 2; }
  f=$(run_state_path "$id") || return $?
  _rs_check "$f"; rc=$?
  if [ "$rc" != "0" ]; then
    _rs_report "$f" "$rc"
    return "$rc"
  fi
  wid=$(jq -r '.workflow_id' "$f" 2>/dev/null) || return 4
  # The current definition. The stored workflow_id and definition_hash never change after start, so reading them
  # here, outside the lock, is safe; every decision that depends on the mutable parts happens inside the lock.
  defstate="missing"; defhash=""; defids="[]"; defmsg=""
  errf=$(mktemp "${TMPDIR:-/tmp}/run-state-resume.XXXXXX") || return 2
  if lk=$(bash "$_RS_DIR/load-workflows.sh" lookup "$wid" 2>"$errf"); then
    file=$(jq -r '.file // empty' <<<"$lk" 2>/dev/null)
    if [ -n "$file" ] && hash=$(definition_hash "$file" 2>/dev/null); then
      defstate="found"
      defhash="$hash"
      defids=$(jq -c '[(.steps // [])[] | .id]' <<<"$lk") || defids="[]"
    fi
  fi
  [ "$defstate" = "found" ] || defmsg=$(cat "$errf")
  rm -f "$errf"
  _rs_locked_call_6 "$id" __resume "$id" "$allow" "$defstate" "$defhash" "$defids" "$defmsg"
}

# Like _rs_locked_call, and exit 6 (definition changed) passes through as well.
_rs_locked_call_6() {
  local id="${1-}" f rc
  shift
  f=$(run_state_path "$id") || return $?
  "${BASH:-bash}" "$_RS_DIR/../with-lock.sh" "$f" -- "${BASH:-bash}" "$_RS_SELF" "$@"
  rc=$?
  case "$rc" in
    0|1|3|4|6) return "$rc" ;;
    2)
      _rs_err "run-state: could not lock $f (another process holds it); nothing was written"
      return 5
      ;;
    *) return 2 ;;
  esac
}

_rs_cmd_move() {
  local to="$1" note="$2" rc
  shift 2
  if [ "$#" -ne 1 ]; then
    _rs_usage_text >&2
    return 2
  fi
  run_state_transition "$1" "$to" "$note"; rc=$?
  [ "$rc" = "0" ] || return "$rc"
  printf '%s\n' "$to"
}

_rs_cmd_pause() { _rs_cmd_move paused "paused" "$@"; }
_rs_cmd_cancel() { _rs_cmd_move cancelled "cancelled" "$@"; }
_rs_cmd_step() { run_state_step "$@"; }
_rs_cmd_await_confirmation() { run_state_await_confirmation "$@"; }
_rs_cmd_resume() { run_state_resume "$@"; }

_rs_cmd_status() {
  if [ "$#" -ne 1 ]; then
    _rs_usage_text >&2
    return 2
  fi
  run_state_read "$1"
}

_rs_cmd_list() {
  local dir f rc bad=0 rows=""
  if [ "$#" -ne 0 ]; then
    _rs_usage_text >&2
    return 2
  fi
  dir=$(run_state_dir) || return 2
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    _rs_check "$f"; rc=$?
    if [ "$rc" != "0" ]; then
      _rs_report "$f" "$rc" "warning: "
      bad=1
      continue
    fi
    rows="$rows$(jq -r '[(.created_at // ""), .run_id, .workflow_id, .status, .updated_at] | map(. // "" | tostring) | @tsv' "$f")
"
  done
  if [ -n "$rows" ]; then
    printf '%s' "$rows" | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2 | cut -f2-
  fi
  [ "$bad" = "0" ] || return 4
  return 0
}

_rs_main() {
  local cmd="${1-}"
  if [ "$#" -eq 0 ]; then
    _rs_usage_text >&2
    return 2
  fi
  shift
  case "$cmd" in
    -h|--help) _rs_usage_text ;;
    start) _rs_cmd_start "$@" ;;
    status) _rs_cmd_status "$@" ;;
    list) _rs_cmd_list "$@" ;;
    pause) _rs_cmd_pause "$@" ;;
    cancel) _rs_cmd_cancel "$@" ;;
    step) _rs_cmd_step "$@" ;;
    await-confirmation) _rs_cmd_await_confirmation "$@" ;;
    resume) _rs_cmd_resume "$@" ;;
    __step) _rs_step_locked "$@" ;;
    __await) _rs_await_locked "$@" ;;
    __resume) _rs_resume_locked "$@" ;;
    __transition) _rs_transition_locked "$@" ;;
    __apply) _rs_apply "$@" ;;
    __create) _rs_create "$@" ;;
    *)
      _rs_err "run-state: unknown command '$cmd'"
      _rs_usage_text >&2
      return 2
      ;;
  esac
}

# Dispatch only when executed, never when sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _rs_main "$@"
  exit $?
fi
