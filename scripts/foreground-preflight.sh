#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/foreground-preflight.sh - foreground pre-task gate helper (epic E67, story E67_S11, task E67_S11_T01)
#
# Two `pre-task` checklist items defer every background unit dispatched under /jenga:
#   checkin-run-before-dispatch   (machine)   has a check-in run in this session?
#   dispatch-cost-and-cadence     (judgment)  did the user agree to the cost and cadence of the dispatch?
# A background sub-agent may not answer a judgment item, and both items are run-scoped, so a tick the user gave
# earlier is invisible to a unit that mints its own run id. This script is the one deterministic helper that the
# foreground callers (/jenga, standalone /do, /dooo) and the dispatched units share, so that no SKILL.md carries
# tick logic inline. It builds ON scripts/checklist.sh and scripts/checklist-marker.sh and changes neither.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   foreground-preflight.sh mint
#   foreground-preflight.sh gate   --run <run-id> --via <jenga|do|dooo> [--user-yes]
#   foreground-preflight.sh verify --run <run-id>
#   foreground-preflight.sh -h | --help | help        print this usage on stdout, exit 0
#
# mint
#   Prints a fresh run id, "fg-<UTC time>-<8 hex>" (for example fg-20261111T161500Z-3fa9c07b), and nothing else.
#   It is valid under checklist.sh's run-id rule (1 to 128 characters of letters, digits, dot, colon, underscore
#   or hyphen, starting with a letter or digit). No side effects: it reads and writes nothing.
#
# gate --run <id> --via <jenga|do|dooo> [--user-yes]       THE FOREGROUND STEP
#   Run it in the HOST session, the one the user is talking to, never in a dispatched sub-agent: the check-in gate
#   it runs is keyed by checklist-marker.sh's session key, which only means anything in the session that ran
#   j.check-in. The caller passes --user-yes ONLY after the user explicitly said yes to the stated cost and
#   cadence; nothing here asks, assumes or defaults that answer.
#     1. Runs skills/j-check-in/scripts/checkin-gate.sh (the same command the checkin-run-before-dispatch item
#        verifies). When it exits non-zero it says so, ticks NOTHING and exits 10.
#     2. When it passes, ticks checkin-run-before-dispatch for --run <id> (via checklist.sh tick, --by user:<via>).
#     3. Ticks dispatch-cost-and-cadence for --run <id> (via checklist.sh tick, --by user:<via>) ONLY when
#        --user-yes was given. Without it that item stays unticked, the script says so and exits 11.
#   Both ticks go through "checklist.sh tick ... --run <id> --by user:<via>". Nothing writes the tick store
#   directly and checklist.sh is not modified, so no tick-scope rule is weakened: both items stay run-scoped and a
#   tick for one run id is not visible to another.
#
# verify --run <id>                                        THE VERIFICATION MODE FOR SUB-AGENTS
#   Exit 0 only when BOTH items show "ticked(run) by user:<via> at <time>" for exactly that run id. It reads tick
#   state through the one existing seam ("checklist.sh list pre-task --run <id>", whose last column is
#   tick_state_of's answer), so no second reader of the tick store exists. It prints NOTHING on stdout in any
#   outcome: nothing a caller could mistake for a pass other than the exit code. A one-line reason goes to stderr
#   on failure. It fails (non-zero) when: the run id is missing or malformed (JENGA_CHECKLIST_RUN_ID is ignored on
#   purpose, the id must be named); either item is unticked or absent from the registry; either tick was
#   recorded by an actor that is not "user:<something>"; either tick is persistent-scoped instead of run-scoped;
#   or the tick state cannot be read. A supplied run id, a claim in a sender object, or the existence of a tick
#   file is never sufficient on its own: only the tick state read back for that run id counts.
#   verify only reads. It never ticks, never clears, and never creates a file or directory.
#
# ---------------------------------------------------------------------------
# HONEST LIMIT
# ---------------------------------------------------------------------------
#   The "user:" prefix is CHECKED, not PROVEN. "checklist.sh tick --by user:x" can be typed by anyone with shell
#   access, so an agent that ignores its instructions could forge it. What this script does is narrow the exposure
#   to deliberate forgery rather than an accidental default: a sub-agent's own tick carries the actor it passes
#   (for example agent:developer) or the operating-system default (os-user:<login>), and verify rejects both. It
#   does not claim cryptographic non-repudiation and must not be described as stronger than that.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0    gate: both items ticked / verify: both items ticked by a user for that run / mint, help: success
#   2    usage error (unknown subcommand or flag, missing or malformed value, --via not jenga|do|dooo)
#   3    a helper script could not be found or python3 is missing
#   10   gate: the check-in has not run in this session; nothing was ticked
#   11   gate: the check-in passed and was ticked, but --user-yes was not given, so dispatch-cost-and-cadence is
#        unticked
#   12   gate: a tick could not be recorded (checklist.sh tick failed; its message is on stderr)
#   20   verify: the run id is missing or malformed
#   21   verify: an item is unticked or not in the registry
#   22   verify: an item is ticked by an actor that is not user:*
#   23   verify: an item is ticked with persistent scope rather than for this run
#   24   verify: the tick state could not be read, or was not in the expected shape
#   A caller that only distinguishes zero from non-zero is always on the safe side.
#
# ENVIRONMENT
#   None of its own. It honours checklist.sh's seams (JENGA_PROJECT_ROOT, JENGA_CHECKLISTS_FILE,
#   JENGA_CHECKLIST_STATE_DIR, ...) because it calls checklist.sh, and checklist-marker.sh's session-key probe
#   (CLAUDE_CODE_SESSION_ID, ...) because checkin-gate.sh does. There is deliberately NO override for which
#   check-in gate script runs: the gate is not something a caller may swap out.
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions).
# Every child process is started with stdin from /dev/null.
# ---------------------------------------------------------------------------

set -u

SELF="foreground-preflight.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CHECKIN_ITEM="checkin-run-before-dispatch"
COST_ITEM="dispatch-cost-and-cadence"
SITUATION="pre-task"
RUN_ID_PATTERN='^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'
# The exact state a satisfied item reports: run-scoped, by a user actor, with a time. An actor never contains a
# space (checklist.sh's actor rule), so a space is a reliable separator.
SATISFIED_PATTERN='^ticked\(run\) by user:[^ ]+ at [^ ]+$'

err() { printf '%s: %s\n' "$SELF" "$1" >&2; }

usage() {
  cat <<'USAGE'
usage:
  foreground-preflight.sh mint
  foreground-preflight.sh gate   --run <run-id> --via <jenga|do|dooo> [--user-yes]
  foreground-preflight.sh verify --run <run-id>
  foreground-preflight.sh -h | --help | help
USAGE
}

# Resolve a framework helper: package-relative first (scripts/ and skills/ are siblings in a checkout and in the
# installed package alike), then the checkout's node_modules copy.
resolve_helper() {
  local rel="$1" candidate
  for candidate in "$PACKAGE_ROOT/$rel" "$PACKAGE_ROOT/node_modules/@jenga-ai/agent/$rel"; do
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# --------------------------------------------------------------------------- mint
cmd_mint() {
  [ "$#" -eq 0 ] || { err "mint takes no arguments"; usage >&2; return 2; }
  local stamp rand
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  rand="$(od -An -N4 -tx1 /dev/urandom 2>/dev/null </dev/null | tr -d ' \n')"
  if [ "${#rand}" -ne 8 ]; then
    # /dev/urandom unreadable: fall back to $RANDOM (two draws), still unique enough with the timestamp.
    rand="$(printf '%04x%04x' "$RANDOM" "$RANDOM")"
  fi
  printf 'fg-%s-%s\n' "$stamp" "$rand"
}

# --------------------------------------------------------------------------- gate
cmd_gate() {
  local run="" via="" yes=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run)
        [ "$#" -ge 2 ] || { err "--run needs a value"; return 2; }
        run="$2"; shift 2 ;;
      --via)
        [ "$#" -ge 2 ] || { err "--via needs a value"; return 2; }
        via="$2"; shift 2 ;;
      --user-yes) yes=1; shift ;;
      *) err "gate: unknown argument: $1"; usage >&2; return 2 ;;
    esac
  done
  [ -n "$run" ] || { err "gate: --run <run-id> is required"; return 2; }
  [[ "$run" =~ $RUN_ID_PATTERN ]] || { err "gate: malformed run id (1-128 chars of letters, digits, . : _ -; start with a letter or digit)"; return 2; }
  case "$via" in
    jenga|do|dooo) ;;
    '') err "gate: --via <jenga|do|dooo> is required"; return 2 ;;
    *) err "gate: --via must be one of jenga, do, dooo"; return 2 ;;
  esac

  local gate checklist
  gate="$(resolve_helper skills/j-check-in/scripts/checkin-gate.sh)" || { err "cannot find skills/j-check-in/scripts/checkin-gate.sh"; return 3; }
  checklist="$SCRIPT_DIR/checklist.sh"
  [ -f "$checklist" ] || { err "cannot find scripts/checklist.sh"; return 3; }

  # Step 1: the check-in must have run in THIS session. Nothing is ticked when it has not.
  if ! bash "$gate" </dev/null >/dev/null 2>&1; then
    err "the check-in has not run in this session (checkin-gate.sh found no checkin event); run j.check-in first. Nothing was ticked."
    return 10
  fi

  # Step 2: the machine item is satisfied, so record it.
  if ! bash "$checklist" tick "$CHECKIN_ITEM" --run "$run" --by "user:$via" </dev/null >/dev/null; then
    err "could not record the tick for $CHECKIN_ITEM"
    return 12
  fi

  # Step 3: the judgment item is ticked only on the user's explicit yes.
  if [ "$yes" -ne 1 ]; then
    err "$COST_ITEM is unticked: the user's explicit yes (--user-yes) was not given. $CHECKIN_ITEM was ticked."
    return 11
  fi
  if ! bash "$checklist" tick "$COST_ITEM" --run "$run" --by "user:$via" </dev/null >/dev/null; then
    err "could not record the tick for $COST_ITEM"
    return 12
  fi
  printf 'ticked %s and %s for run %s (by user:%s)\n' "$CHECKIN_ITEM" "$COST_ITEM" "$run" "$via"
  return 0
}

# --------------------------------------------------------------------------- verify
# state_of <list-output> <item id>: prints the tick-state column of the one line for that item. Returns 1 when the
# item is absent, 2 when it appears more than once or its line is not the five-column shape.
state_of() {
  printf '%s\n' "$1" | awk -F'\t' -v id="$2" '
    $1 == id { n++; if (NF != 5) bad = 1; state = $5 }
    END { if (n == 0) exit 1; if (n > 1 || bad) exit 2; print state }'
}

# judge_item <list-output> <item id>: sets VERIFY_CODE and VERIFY_REASON; returns 0 when the item is satisfied.
judge_item() {
  local state rc
  state="$(state_of "$1" "$2")"; rc=$?
  case "$rc" in
    0) ;;
    1) VERIFY_CODE=21; VERIFY_REASON="$2 is not an item of the pre-task registry"; return 1 ;;
    *) VERIFY_CODE=24; VERIFY_REASON="$2: tick state not in the expected shape"; return 1 ;;
  esac
  if [[ "$state" =~ $SATISFIED_PATTERN ]]; then
    return 0
  fi
  case "$state" in
    unticked)
      VERIFY_CODE=21; VERIFY_REASON="$2 is unticked for this run" ;;
    "ticked(persistent)"*)
      VERIFY_CODE=23; VERIFY_REASON="$2 is ticked with persistent scope, not for this run" ;;
    "ticked(run) by user:"*)
      VERIFY_CODE=24; VERIFY_REASON="$2: tick state not in the expected shape" ;;
    "ticked("*)
      VERIFY_CODE=22; VERIFY_REASON="$2 is ticked by an actor that is not user:*" ;;
    *)
      VERIFY_CODE=24; VERIFY_REASON="$2: tick state not in the expected shape" ;;
  esac
  return 1
}

cmd_verify() {
  local run="" have_run=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run)
        [ "$#" -ge 2 ] || { err "verify: --run needs a value"; return 20; }
        run="$2"; have_run=1; shift 2 ;;
      *) err "verify: unknown argument: $1"; return 2 ;;
    esac
  done
  if [ "$have_run" -ne 1 ] || [ -z "$run" ]; then
    err "verify: no run id given (--run <run-id> is required; JENGA_CHECKLIST_RUN_ID is not consulted)"
    return 20
  fi
  [[ "$run" =~ $RUN_ID_PATTERN ]] || { err "verify: malformed run id"; return 20; }

  local checklist listing lrc
  checklist="$SCRIPT_DIR/checklist.sh"
  [ -f "$checklist" ] || { err "verify: cannot find scripts/checklist.sh"; return 24; }

  # One read, through the one seam. stderr is discarded (it carries per-item warnings only); the exit status says
  # whether the read worked, and a failed read is never a pass.
  listing="$(bash "$checklist" list "$SITUATION" --run "$run" </dev/null 2>/dev/null)"; lrc=$?
  if [ "$lrc" -ne 0 ]; then
    err "verify: the tick state could not be read (checklist.sh list exited $lrc)"
    return 24
  fi

  VERIFY_CODE=0; VERIFY_REASON=""
  local item
  for item in "$CHECKIN_ITEM" "$COST_ITEM"; do
    if ! judge_item "$listing" "$item"; then
      err "verify: $VERIFY_REASON"
      return "$VERIFY_CODE"
    fi
  done
  return 0
}

# --------------------------------------------------------------------------- dispatch
[ "$#" -ge 1 ] || { usage >&2; exit 2; }
sub="$1"; shift
case "$sub" in
  -h|--help|help) usage; exit 0 ;;
  mint)   cmd_mint "$@";   exit $? ;;
  gate)   cmd_gate "$@";   exit $? ;;
  verify) cmd_verify "$@"; exit $? ;;
  *) err "unknown subcommand: $sub"; usage >&2; exit 2 ;;
esac
