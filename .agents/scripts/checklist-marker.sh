#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/checklist-marker.sh - the situation marker (epic E67, task E67_S04_T01)
#
# Records which pre-flight lifecycle phase ("situation") is currently active in THIS session, so a hook
# that fires on a tool event can tell pre-commit from pre-task. A hook sees a tool call and nothing else:
# it has no way to know a gating skill is mid-phase, which phase that is, or which run id that phase
# minted. This marker is that channel, and nothing else in the feature carries the information.
#
# A gating skill writes the marker when it enters its phase and clears it when it leaves. The hook
# (E67_S04_T02) reads it, runs "checklist.sh check <situation>" for whatever it finds, and blocks on a
# failed block-enforcement item. With no marker the hook does nothing at all.
#
# The companion script is scripts/checklist.sh: that one owns the registry, the checks and the tick store;
# this one owns only "which phase is active now". Their keying, locking, pruning and degradation rules are
# deliberately the same shape, and where this header says "as the tick store does" it means exactly that.
# The documentation contract for both is preflight-checklists.md in the project documentation directory
# (section 9, "Situation marker").
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   checklist-marker.sh write --situation <s> [--run <run-id>] [--skill <name>] [--session <key>]
#   checklist-marker.sh refresh --token <t> [--session <key>]
#   checklist-marker.sh clear [--situation <s>] [--token <t>] [--session <key>] [--all]
#   checklist-marker.sh read  [--session <key>] [--field <name>]
#   checklist-marker.sh path  [--session <key>]
#   checklist-marker.sh session-key
#   checklist-marker.sh prune
#   checklist-marker.sh -h | --help | help        print this usage on stdout, exit 0
#
# <s> is a lifecycle phase name: pre-commit, pre-task, pre-release, pre-reconcile, or any extension name a
# registry may declare (pre-publish, pre-mirror, ...). It is validated only against the situation-name
# pattern this feature's schema defines (^[a-z][a-z0-9-]*$, doc section 4); the registry is NOT read, so
# the marker stays cheap and cannot fail because of a registry problem. Whether any item names the phase is
# checklist.sh's business, not the marker's.
#
# ---------------------------------------------------------------------------
# SUBCOMMANDS
# ---------------------------------------------------------------------------
# write --situation <s> [--run <run-id>] [--skill <name>] [--session <key>]
#   Pushes a frame for <s> onto this session's marker and prints that frame's TOKEN on stdout (and nothing
#   else), so the caller can later clear exactly the frame it pushed. --run records the run id the phase
#   minted, so a reader can pass the same --run to checklist.sh and see that run's run-scoped ticks;
#   without it a reader's check sees run-scoped items as unticked (checklist.sh's own safe default).
#   --skill records which skill entered the phase, for diagnostics only; nothing branches on it.
#
#   write is a PURE PUSH. Every call pushes a NEW frame with a NEW token, whatever the stack already holds:
#   there is no matching of existing frames, at any depth, and no refresh heuristic. "I am entering a new
#   <s> phase" and "I am still in my <s> phase" are indistinguishable from the argument to write alone, so
#   any rule that guessed between them was wrong somewhere - matching only the top frame mis-handled
#   nesting, matching anywhere mis-handled the same situation re-entered non-adjacently (pre-commit ->
#   pre-task -> pre-commit: the inner write returned the OUTER frame's token, read reported pre-task, and
#   the inner clear then popped the still-running pre-task frame, leaving it ungated). The caller knows
#   which of the two it means, so it says so: write to enter, refresh --token to extend.
#   Consequence, accepted deliberately: a caller that writes twice by mistake DOES grow the stack, by one
#   frame per call. That is a caller bug, bounded by the TTL and by pruning, and far cheaper than silently
#   un-gating an enclosing phase. The stack is never guaranteed not to grow; callers must not rely on a
#   repeated write being idempotent. Expired frames are still dropped on every write, and an expired frame
#   is never resurrected by a later write (see "STALE-MARKER RECOVERY").
#
# refresh --token <t> [--session <key>]
#   Extends the expiry of EXACTLY the one live frame whose token is <t>, wherever it sits in the stack, in
#   place: its token and its position (and so its depth) are unchanged, no frame is pushed, and no other
#   frame is touched. Prints that token on stdout. This is how a phase that outlives marker_ttl_minutes
#   keeps itself gated - including while an inner phase is nested on top of it, where the active phase
#   (the innermost live frame) stays the inner one.
#   A token that names NO LIVE FRAME - never written, already cleared, or expired - is NOT a silent
#   success: refresh prints "no live frame" on stderr and exits 3, writing nothing. A silent no-op would
#   leave the caller believing it is still gated when it is not. Exit 3 lets the caller branch: write
#   again to obtain a fresh frame (and a fresh token) if its phase is still running. An expired frame is
#   never resurrected - once its expiry has passed it is gone, and only a new write brings the phase back.
#   An unreadable, absent or foreign-session marker file is the same "no live frame" case (exit 3), and
#   refresh never creates the marker directory. With no session key, refresh exits 7 like write.
#
# clear [--situation <s>] [--token <t>] [--session <key>] [--all]
#   Pops a frame. With --token, pops that exact frame and every frame above it; with --situation, pops the
#   topmost frame for that situation and everything above it; with neither, pops the topmost frame. --all
#   drops every frame. Frames above the popped one are abandoned by definition (their own phase cannot
#   still be running if an enclosing phase is leaving), so they go too rather than being left to linger
#   until the TTL.
#
#   Clearing is idempotent and never an error: no marker file, no matching frame, or an already-expired
#   frame all succeed silently with exit 0. A caller on an error path must be able to clear
#   unconditionally without having to know whether its write landed.
#
# read [--session <key>] [--field <name>]
#   Prints the active frame as one JSON object on stdout, or NOTHING when no phase is active, and exits 0
#   either way. The active frame is the topmost frame that has not expired (see "STALE-MARKER RECOVERY").
#   --field <name> prints just that field's value as a bare line (situation, run_id, skill, session_id,
#   written_at, expires_at, token, depth), for a caller that wants one value without a JSON parser; an
#   absent or null field prints nothing.
#
#   read NEVER fails the caller. Anything it cannot make sense of - no marker file, a corrupt one, an
#   unresolvable queue directory, a missing or invalid TTL, a session_id that does not match the requested
#   key - is reported as "no phase is active": a warning on stderr, nothing on stdout, exit 0. This is the
#   same degradation checklist.sh's tick_state_of makes to "unticked", and for the same reason: a broken
#   lookup must not break the session that is merely passing through it. Only a usage error exits non-zero
#   (2), because that is a caller bug rather than a state problem.
#
#   read writes nothing: it never creates the directory, never prunes and never takes a lock (a writer
#   renames a finished temp file over the target, so a reader sees a whole old or whole new file).
#
#   WHAT THE NO-MARKER PATH ACTUALLY COSTS. Once the marker directory is known, the no-marker check itself
#   is pure bash: a directory test and a glob, no subprocess. But resolving that directory DOES cost one
#   "resolve-root.sh get queue" subprocess (which climbs for workflow.json and runs jq twice), because the
#   path must not be a hardcoded working-tree literal (E34_S01). So the honest guarantee is: NO python3, NO
#   scope-thresholds.json read and NO marker parsing on the no-marker path - but one root-resolver
#   subprocess, always.
#   Measured in this repository with no marker present, 20 calls, bash 3.2 on Darwin: 40.4 ms/call, of
#   which 20.4 ms is the rest of the script (a bare "bash -c true" is already 10.8 ms of that) and ~20 ms
#   is the root resolver. An earlier version of this comment claimed "not one subprocess", which was only
#   ever true with JENGA_CHECKLIST_MARKER_DIR set - that is, under test. Corrected after the tester
#   measured it on E67_S04_T01; see the rapport
#   E67_S04_T01-marker-noop-cost-claim-and-nested-refresh.md, finding 1.
#   E67_S04_T02 owns the hook that pays this on every tool event and is the only place that can judge
#   whether ~40 ms is material. If it is, the lever is to avoid the resolver on the hot path (for instance
#   by probing a conventional relative path first, or caching the resolved queue directory for the session)
#   - which adds a second resolution rule and is a deliberate design decision for T02, not a mechanical
#   tweak to make here. Sourcing resolve-root.sh instead of spawning it was measured and is NOT the answer:
#   22.9 ms versus 24.5 ms, because its two internal jq calls dominate, not the bash spawn.
#
# path [--session <key>]   prints this session's marker file path (it need not exist). Exits 1 if the queue
#                          directory cannot be resolved, 7 if no session key could be resolved.
# session-key              prints the resolved session key (see "SESSION KEYING"), or exits 7 with nothing.
# prune                    deletes every marker file with no live frame left, plus stale .tmp-* files and
#                          .lock.d directories. Housekeeping only; write and clear prune on their own.
#
# ---------------------------------------------------------------------------
# SESSION KEYING (AC3: two concurrent sessions never read each other's marker)
# ---------------------------------------------------------------------------
# One marker file per session key, named marker-<digest>.json where <digest> is the first 24 hex characters
# of sha256 of the key - the same file-per-key rule, with the same digest length, that the tick store uses
# for run-<digest>.json. Two concurrent sessions in different phases therefore write and read two different
# files and can no more collide than two concurrent runs can. This is the fix E37_S01 made for handoffs/,
# applied a third time: a single shared path whose last writer silently wins is the bug being avoided.
#
# Nothing in a script can observe which session it is running in, so, exactly as the tick store's run id is
# named by its caller, the session key is RESOLVED, through one probe order used identically by the writer
# and the reader:
#
#   1. --session <key>              an explicit key
#   2. JENGA_CHECKLIST_SESSION_ID   an explicit override (and the tests' seam)
#   3. CLAUDE_CODE_SESSION_ID       the harness's own session id, exported into every child process. This
#                                   is the normal source, and it is the same value a hook receives as
#                                   session_id in its stdin payload.
#   4. JENGA_SESSION_ID             the session id hooks/on_session_end.sh already uses
#
# In NORMAL OPERATION NEITHER SIDE PASSES --session: both resolve from the same environment, so they cannot
# disagree. That is the whole reason the probe order exists in one place instead of each caller picking a
# value. A hook in particular should let this script resolve the key rather than passing the session_id
# from its payload; the two are the same value today, and if a future harness ever made them differ, a
# payload-supplied key would silently stop matching what the skill wrote. A key is 1 to 128 characters of
# letters, digits, dot, colon, underscore or hyphen, starting with a letter or digit (anything else exits
# 2), so it can never contain / or .. and is always safe in a filename.
#
# No key at all is asymmetric, the same way a missing run id is in the tick store:
#   write  is an ERROR (exit 7). A marker written under a guessed or shared default key would be visible to
#          a session that never entered the phase - which is precisely the cross-session wedge this design
#          exists to prevent - so there is no fallback key.
#   read   reports "no phase is active" (exit 0). A forgotten key costs a skipped gate, never a gate
#          applied to the wrong session. Fail-open is the correct direction for the reader and the only one
#          consistent with "with no marker present the hook is a silent no-op".
#
# The resolved key is ALSO stored inside the file as session_id and re-checked on read: a file whose
# session_id is not the key being read is treated as absent (with a warning). So even a digest mix-up or a
# hand-copied file cannot make one session read another's phase.
#
# ---------------------------------------------------------------------------
# NESTING (why the marker is a stack and not a single value)
# ---------------------------------------------------------------------------
# Phases nest in practice: /j-commit (pre-commit) is reachable from inside /j-do's pre-task phase, and
# /j-commit itself calls /j-reconcile. If the marker held one value, the inner phase's clear would delete
# the outer phase's marker and the rest of the outer phase would run ungated - a silent hole, visible only
# as "the hook sometimes does not fire".
#
# So the file holds a stack. write always pushes, clear pops, refresh --token extends a frame in place
# without moving it, and the ACTIVE phase is the topmost live frame: the
# innermost phase currently running, which is the one a tool call is happening inside. Clearing a frame
# also clears everything above it, so an inner phase that died without clearing cannot outlive its parent.
# depth (1 for the outermost frame) is reported by read for diagnostics.
#
# ---------------------------------------------------------------------------
# STALE-MARKER RECOVERY (AC2: a dead session must not wedge later sessions)
# ---------------------------------------------------------------------------
# This is the failure mode the task names as primary, and it is handled by three mechanisms, not one:
#
# 1. A TTL PER FRAME. Every frame carries written_at and expires_at (= written_at + marker_ttl_minutes).
#    A frame whose expires_at is at or before now is EXPIRED and is treated as absent: read never reports
#    it, and write and clear drop it before they do anything else. A session that dies mid-phase therefore
#    stops gating anything after at most the TTL, with no cleanup and no human in the loop.
#    This is what makes the resumed-session case safe too: "claude --resume" keeps the SAME session id, so
#    a session that died mid-phase and is resumed an hour later resolves the same key and would read its
#    own abandoned frame straight back. The TTL is the only thing that stops it.
# 2. PER-SESSION KEYING. A reader only ever opens its own key's file, so another session's abandoned marker
#    is not merely expired, it is unreachable. No session can be wedged by a phase it never entered, which
#    is the strongest form of the guarantee and holds regardless of the TTL.
# 3. PRUNING. Every write and clear (and prune) deletes marker files with no live frame left, plus .tmp-*
#    files and .lock.d directories older than the TTL (crashed writers). So abandoned files do not
#    accumulate in the queue directory. Pruning is best effort and never fails the operation that
#    triggered it, and it only ever matches marker-*.json, .tmp-* and *.lock.d - it cannot touch a
#    neighbouring feature's state. Same model as the tick store's prune-on-every-tick.
#
# Note what is deliberately NOT used as a liveness signal: the writing PROCESS's pid. The writer is a
# short-lived script invocation that has exited by the time anyone reads the marker, and its parent is a
# per-command shell, so a pid-liveness check would report almost every marker as orphaned and skip the
# gate. writer_pid is recorded for diagnostics only; nothing branches on it. The liveness key that does
# work is the session key itself (mechanism 2), bounded by the TTL (mechanism 1).
#
# ---------------------------------------------------------------------------
# THE TTL IS READ FROM CONFIG (AC4)
# ---------------------------------------------------------------------------
# marker_ttl_minutes in "$(resolve-root.sh get configs)/scope-thresholds.json", read fresh on every
# operation that needs it, exactly the way scripts/acquire-concurrency-slot.sh reads slot_ttl_minutes from
# the same file (jq -r '.<key> // empty', then a numeric guard, then a hard failure). Nothing about the TTL
# is compiled into this script.
#
# A missing file or a missing/invalid key is an environment error (exit 5) for write, clear and prune - the
# operations that need to know when a frame dies - and "no phase is active" for read, which must never
# fail. JENGA_CHECKLIST_MARKER_TTL_MINUTES overrides it, as a TEST SEAM only (the style of
# JENGA_CHECKLIST_RUN_TTL_MINUTES); it is not a configuration surface and nothing should set it in use.
#
# Why 60 minutes is the shipped value, and the trade-off it is: too long re-creates the wedge the TTL
# exists to prevent (a dead session keeps gating for as long as the TTL lasts); too short lets a long but
# perfectly healthy phase quietly stop being gated. 60 is longer than slot_ttl_minutes (45), which guards
# a single dispatch against a crashed subagent, and far shorter than the tick store's 1440-minute idle TTL,
# which bounds a whole orchestrated run. A phase that genuinely runs longer is expected to call
# "refresh --token <its token>", which extends that frame's expiry in place (see refresh; if it exits 3
# the frame already expired, and the phase writes again). The value is a judgement, not a measurement; change it
# in the config, not here.
#
# ---------------------------------------------------------------------------
# WHERE STATE LIVES
# ---------------------------------------------------------------------------
#   Directory: "$(scripts/resolve-root.sh get queue)/checklist-markers/" (test seam:
#   JENGA_CHECKLIST_MARKER_DIR), resolved through the root resolver, never a hardcoded working-tree
#   literal. A sibling of the tick store's checklist-ticks/ and under the queue directory for the same
#   reasons: the queue is blocklisted in .publicignore so marker state never ships downstream through
#   /j-mirror-public, and .gitignore ignores this subdirectory's contents (all but .gitkeep) so a
#   transient "which phase am I in" value is never committed.
#     marker-<digest>.json     one file per session key
#     <name>.lock.d            with-lock.sh's lock directory next to the file being written
#     .tmp-<name>.<pid>        a write in flight (renamed over <name> when complete)
#   File shape: {"version": 1, "session_id": "<key>", "stack": [frame, ...]} where a frame is
#   {"token", "situation", "run_id", "skill", "written_at", "expires_at", "writer_pid"}.
#   The directory is created by the first write; read, path and session-key never create anything.
#
#   "Survives a queue sweep": the sweeping that exists in the queue today is scoped to other subdirectories
#   (sweep-stale-context-digests.sh to context/, on_session_end.sh to handoffs/), none to this one. A
#   marker is transient by design, so a future queue-wide sweep deleting it would be harmless - unlike the
#   tick store's persistent.json, which such a sweep must exclude.
#
#   Known limit, inherited from the root resolver and NOT re-litigated here (it is already recorded for
#   tick state in scripts/checklist.sh's header): state is rooted at the resolved project root, so a
#   session running inside a git worktree resolves that worktree's own tree. A marker written in a worktree
#   is not visible from the main tree and disappears with the worktree. Set JENGA_PROJECT_ROOT to share one
#   root. In practice this is benign for the marker: a session's hook and its gating skill run in the same
#   tree, so they agree.
#
# ---------------------------------------------------------------------------
# HOW CONCURRENT WRITERS ARE KEPT FROM CLOBBERING EACH OTHER
# ---------------------------------------------------------------------------
#   - One file per session key, so two sessions never touch the same file at all.
#   - Within one session (a skill and, say, a nested skill writing at the same time), every
#     read-modify-write goes through scripts/with-lock.sh <file> -- <command>: a mkdir-based lock, not
#     flock, which macOS does not ship. If the lock cannot be acquired within with-lock.sh's timeout the
#     operation is NOT performed and exits 8; a marker is never written unlocked.
#   - The write itself is a temp file in the same directory, fsynced and renamed over the target, so a
#     concurrent reader sees a whole old or whole new file and never half of one.
#   - Readers take no lock, so read cannot be blocked by a writer and cannot block one.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   success. Includes "read: no phase is active" and every idempotent clear.
#   1   the queue directory could not be resolved (write, refresh, clear, path, prune)
#   2   usage error (no subcommand, unknown subcommand or option, bad situation, run id, session key,
#       skill name, token, field name or TTL override)
#   3   refresh: the token names no LIVE frame (never written, cleared, expired, or no marker file). Nothing
#       was changed. The caller should write again if its phase is still running. 3 is used rather than 6
#       only because it is the lowest free code; neither carried a meaning here before.
#   4   python3 is not installed
#   5   scope-thresholds.json is missing or unreadable, or marker_ttl_minutes is missing or not a positive
#       number (write, refresh, clear, prune). read degrades to "no phase is active" instead.
#   7   no session key could be resolved (write, refresh, path, session-key)
#   8   write/refresh/clear: the marker was NOT written or cleared - the directory could not be created, its lock
#       could not be acquired, or the write failed
#   9   jq is not installed (it is needed only to read the TTL from scope-thresholds.json, so a run that
#       sets JENGA_CHECKLIST_MARKER_TTL_MINUTES never needs it)
# These codes are NOT parallel to scripts/checklist.sh's table, which assigns several of the same numbers
# different meanings (there 6 is "not an item" and 7 is "run-scoped, no run id"; here 7 is "no session
# key" and 8 is "not written/cleared"). Read this table, not that one, and do not assume parity.
# A caller that only distinguishes zero from non-zero is therefore always on the safe side, and read in
# particular only ever returns non-zero for a caller bug.
#
# ---------------------------------------------------------------------------
# ENVIRONMENT (test seams, in the style of scripts/checklist.sh; unset in normal use)
# ---------------------------------------------------------------------------
#   JENGA_CHECKLIST_MARKER_DIR          use this directory instead of <queue>/checklist-markers
#   JENGA_CHECKLIST_MARKER_TTL_MINUTES  override marker_ttl_minutes (positive number of minutes; else 2)
#   JENGA_SCOPE_THRESHOLDS_FILE         read the TTL from this file instead of <configs>/scope-thresholds.json
#   JENGA_CHECKLIST_NOW                 the current time for stamps and ages, UTC, as 2026-10-03T12:00:00Z
# Not a test seam (normal interface):
#   JENGA_CHECKLIST_SESSION_ID          the session key, when --session is not given (see "SESSION KEYING")
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions).
# ---------------------------------------------------------------------------

set -u
export LC_ALL=C

MARKER_SUBDIR="checklist-markers"
MARKER_FILE_VERSION=1
SITUATION_PATTERN='^[a-z][a-z0-9-]*$'
SESSION_KEY_PATTERN='^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'
RUN_ID_PATTERN='^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'
TOKEN_PATTERN='^[A-Za-z0-9._:-]{1,160}$'
SKILL_PATTERN='^[A-Za-z0-9._:/-]{1,64}$'
FIELD_PATTERN='^[a-z_]{1,32}$'

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MARKER_DIR=""
MARKER_FILE=""
SESSION_KEY=""
TTL_MINUTES=""

err() {
  printf '%s: %s\n' "$SELF" "$*" >&2
}

die() {
  local code="$1"; shift
  err "$*"
  exit "$code"
}

usage() {
  cat <<'USAGE'
usage:
  checklist-marker.sh write --situation <s> [--run <run-id>] [--skill <name>] [--session <key>]
  checklist-marker.sh refresh --token <t> [--session <key>]
  checklist-marker.sh clear [--situation <s>] [--token <t>] [--session <key>] [--all]
  checklist-marker.sh read  [--session <key>] [--field <name>]
  checklist-marker.sh path  [--session <key>]
  checklist-marker.sh session-key
  checklist-marker.sh prune
  checklist-marker.sh -h | --help | help

Records which pre-flight lifecycle phase is active in this session, so a hook firing on a tool event can
tell pre-commit from pre-task. write on phase entry, clear on phase exit, refresh --token to extend a long
phase's own frame (exit 3 if that frame is gone, so the caller can write again); read prints the active phase as
JSON (or nothing when none is active) and never fails. An expired frame is treated as absent, so a dead
session cannot wedge a later one. One file per session key, so concurrent sessions never collide.
Full contract: the header of this script, and section 9 of preflight-checklists.md.
USAGE
}

# ---------------------------------------------------------------------------
# Resolution helpers
# ---------------------------------------------------------------------------

# Sets MARKER_DIR. Returns 1 when the queue directory cannot be resolved.
resolve_marker_dir() {
  local queue
  if [ -n "${JENGA_CHECKLIST_MARKER_DIR:-}" ]; then
    MARKER_DIR="$JENGA_CHECKLIST_MARKER_DIR"
    return 0
  fi
  if ! queue="$(bash "$SCRIPT_DIR/resolve-root.sh" get queue)" || [ -z "$queue" ]; then
    err "could not resolve the project queue directory via resolve-root.sh"
    MARKER_DIR=""
    return 1
  fi
  MARKER_DIR="$queue/$MARKER_SUBDIR"
  return 0
}

# Sets SESSION_KEY from the documented probe order. $1 is an explicit --session value ("" for none).
# Returns 7 when no key could be resolved, 2 when the resolved key is malformed.
resolve_session_key() {
  local explicit="${1:-}" key=""
  if [ -n "$explicit" ]; then
    key="$explicit"
  elif [ -n "${JENGA_CHECKLIST_SESSION_ID:-}" ]; then
    key="$JENGA_CHECKLIST_SESSION_ID"
  elif [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    key="$CLAUDE_CODE_SESSION_ID"
  elif [ -n "${JENGA_SESSION_ID:-}" ]; then
    key="$JENGA_SESSION_ID"
  fi
  if [ -z "$key" ]; then
    SESSION_KEY=""
    return 7
  fi
  if ! [[ "$key" =~ $SESSION_KEY_PATTERN ]]; then
    err "bad session key \"$key\" (1 to 128 characters of letters, digits, dot, colon, underscore or hyphen, starting with a letter or digit)"
    SESSION_KEY=""
    return 2
  fi
  SESSION_KEY="$key"
  return 0
}

# Prints the first 24 hex characters of sha256 of $1 - the tick store's run-<digest> rule, same length.
key_digest() {
  printf '%s' "$1" | python3 -c 'import hashlib,sys; sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:24])'
}

# Sets MARKER_FILE from MARKER_DIR and SESSION_KEY.
resolve_marker_file() {
  MARKER_FILE="$MARKER_DIR/marker-$(key_digest "$SESSION_KEY").json"
}

# Sets TTL_MINUTES, from the env override or from scope-thresholds.json. Returns 5 on a config problem,
# 2 on a malformed override. Read fresh on every call, as acquire-concurrency-slot.sh reads slot_ttl_minutes.
resolve_ttl_minutes() {
  local configs config_file raw
  if [ -n "${JENGA_CHECKLIST_MARKER_TTL_MINUTES:-}" ]; then
    if ! python3 -c 'import math,sys; v=float(sys.argv[1]); sys.exit(0 if math.isfinite(v) and v > 0 else 1)' \
      "$JENGA_CHECKLIST_MARKER_TTL_MINUTES" 2>/dev/null; then
      err "bad marker TTL \"$JENGA_CHECKLIST_MARKER_TTL_MINUTES\" (JENGA_CHECKLIST_MARKER_TTL_MINUTES must be a positive number of minutes)"
      return 2
    fi
    TTL_MINUTES="$JENGA_CHECKLIST_MARKER_TTL_MINUTES"
    return 0
  fi
  if [ -n "${JENGA_SCOPE_THRESHOLDS_FILE:-}" ]; then
    config_file="$JENGA_SCOPE_THRESHOLDS_FILE"
  else
    if ! configs="$(bash "$SCRIPT_DIR/resolve-root.sh" get configs)" || [ -z "$configs" ]; then
      err "could not resolve the project configs directory via resolve-root.sh"
      return 5
    fi
    config_file="$configs/scope-thresholds.json"
  fi
  if [ ! -f "$config_file" ]; then
    err "config file not found: $config_file (marker_ttl_minutes is required)"
    return 5
  fi
  command -v jq >/dev/null 2>&1 || { err "jq is required to read $config_file but was not found on PATH"; return 9; }
  raw="$(jq -r '.marker_ttl_minutes // empty' "$config_file" 2>/dev/null)" || raw=""
  if [ -z "$raw" ] \
    || ! python3 -c 'import math,sys; v=float(sys.argv[1]); sys.exit(0 if math.isfinite(v) and v > 0 else 1)' "$raw" 2>/dev/null; then
    err "invalid or missing marker_ttl_minutes in $config_file (expected a positive number of minutes)"
    return 5
  fi
  TTL_MINUTES="$raw"
  return 0
}

# A bad JENGA_CHECKLIST_NOW makes MARKER_PY exit 2, which is also with-lock.sh's "lock not acquired" code.
# Catch it here, before any locked call, so the two can never be confused (scripts/checklist.sh pre-checks
# the same seam for the same reason).
validate_now_override() {
  [ -n "${JENGA_CHECKLIST_NOW:-}" ] || return 0
  if ! printf '%s' "$JENGA_CHECKLIST_NOW" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
    err "bad JENGA_CHECKLIST_NOW \"$JENGA_CHECKLIST_NOW\" (expected a UTC time like 2026-10-03T12:00:00Z)"
    return 2
  fi
  return 0
}

require_python3() {
  command -v python3 >/dev/null 2>&1 || die 4 "python3 is required but not found on PATH"
}

# ---------------------------------------------------------------------------
# The marker store, in python3 (as scripts/checklist.sh does its own JSON work).
#
# Invoked as: MARKER_PY <op> <path> <session-key> <ttl-minutes> [op args...]
# ops: write <situation> <run-id> <skill>   <path> is the marker FILE; push a new frame, print its token
#      refresh <token>                      <path> is the marker FILE; extend that one live frame, exit 3 if none
#      clear <situation> <token> <all>      <path> is the marker FILE; pop a frame and everything above it
#      read <field>                         <path> is the marker DIRECTORY; print the active frame
#      prune                                <path> is the marker DIRECTORY; drop dead files and leftovers
# read and prune take the directory and derive the file name themselves, so the cheap no-marker path in
# cmd_read never has to spawn anything just to compute a digest.
# Every op drops expired frames before it does anything else, so an expired frame is never observable.
# ---------------------------------------------------------------------------
MARKER_PY='
import hashlib, json, os, re, sys, time

FILE_VERSION = 1

def now_epoch():
    override = os.environ.get("JENGA_CHECKLIST_NOW", "")
    if override:
        m = re.match(r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$", override)
        if not m:
            sys.stderr.write("bad JENGA_CHECKLIST_NOW %r (expected a UTC time like 2026-10-03T12:00:00Z)\n" % override)
            sys.exit(2)
        import calendar
        return calendar.timegm(tuple(int(g) for g in m.groups()) + (0, 0, 0))
    return int(time.time())

def iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))

def parse_iso(s):
    if not isinstance(s, str):
        return None
    m = re.match(r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$", s)
    if not m:
        return None
    import calendar
    try:
        return calendar.timegm(tuple(int(g) for g in m.groups()) + (0, 0, 0))
    except Exception:
        return None

def load(path, key):
    """The file as a (frames, was_usable) pair. Anything unreadable, non-JSON, wrongly shaped or belonging
    to another session key reads as an EMPTY stack with a warning - never as another session phase."""
    try:
        with open(path, "r") as fh:
            doc = json.load(fh)
    except IOError:
        return [], True
    except ValueError:
        sys.stderr.write("marker file is not valid JSON; treating it as absent: %s\n" % path)
        return [], False
    if not isinstance(doc, dict) or not isinstance(doc.get("stack"), list):
        sys.stderr.write("marker file is not shaped as a marker; treating it as absent: %s\n" % path)
        return [], False
    stored = doc.get("session_id")
    if stored != key:
        sys.stderr.write(
            "marker file belongs to session %r, not %r; treating it as absent: %s\n" % (stored, key, path))
        return [], False
    frames = [f for f in doc["stack"] if isinstance(f, dict) and isinstance(f.get("situation"), str)]
    return frames, True

def live(frames, now):
    """The frames that have not expired, in order. An expired frame is dropped INDIVIDUALLY rather than
    truncating everything above it: because refresh extends a frame in place, the stack is not
    necessarily ordered by expiry, so an expired outer frame can sit below an inner one that was just
    refreshed and is demonstrably alive. Dropping that live inner frame would stop gating a phase that is
    still running. A frame with no parsable expires_at is expired by definition - an unreadable expiry is
    never trusted into a gate.
    Abandonment of the frames ABOVE a departing phase is handled where it is actually known, by clear,
    which pops its frame and everything above it."""
    out = []
    for f in frames:
        exp = parse_iso(f.get("expires_at"))
        if exp is None or exp <= now:
            continue
        out.append(f)
    return out

def dump(path, key, frames):
    """Atomic replace: temp file in the same directory, fsynced, renamed over the target. A file with no
    live frame left is removed rather than left as an empty husk, so pruning has nothing to collect."""
    d = os.path.dirname(path) or "."
    if not frames:
        try:
            os.unlink(path)
        except OSError:
            pass
        return
    doc = {"version": FILE_VERSION, "session_id": key, "stack": frames}
    tmp = os.path.join(d, ".tmp-%s.%d" % (os.path.basename(path), os.getpid()))
    with open(tmp, "w") as fh:
        json.dump(doc, fh, indent=2, sort_keys=True)
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.rename(tmp, path)

def mint_token(key, situation, now):
    seed = "%s|%s|%d|%d" % (key, situation, now, os.getpid())
    return "%s-%s" % (situation, hashlib.sha256(seed.encode("utf-8")).hexdigest()[:16])

def file_for(directory, key):
    digest = hashlib.sha256(key.encode("utf-8")).hexdigest()[:24]
    return os.path.join(directory, "marker-%s.json" % digest)

op = sys.argv[1]
path = sys.argv[2]
key = sys.argv[3]
ttl_minutes = float(sys.argv[4]) if sys.argv[4] else 0.0
now = now_epoch()

if op == "read":
    path = file_for(path, key)

if op == "prune":
    directory = path
    ttl_seconds = ttl_minutes * 60.0
    try:
        names = os.listdir(directory)
    except OSError:
        sys.exit(0)
    for name in names:
        full = os.path.join(directory, name)
        if re.match(r"^marker-[0-9a-f]{24}\.json$", name):
            try:
                with open(full, "r") as fh:
                    doc = json.load(fh)
                frames = doc["stack"] if isinstance(doc, dict) and isinstance(doc.get("stack"), list) else []
                keep = live([f for f in frames if isinstance(f, dict)], now)
            except (IOError, ValueError, KeyError, TypeError):
                keep = []
            if not keep:
                try:
                    os.unlink(full)
                except OSError:
                    pass
        elif name.startswith(".tmp-") or name.endswith(".lock.d"):
            # Leftovers of a writer that crashed. Only removed once older than the TTL, so a write in
            # flight right now is never disturbed.
            try:
                if now - os.path.getmtime(full) > ttl_seconds:
                    if os.path.isdir(full):
                        import shutil
                        shutil.rmtree(full, ignore_errors=True)
                    else:
                        os.unlink(full)
            except OSError:
                pass
    sys.exit(0)

frames, _ = load(path, key)
frames = live(frames, now)

if op == "read":
    field = sys.argv[5] if len(sys.argv) > 5 else ""
    if not frames:
        sys.exit(0)
    top = dict(frames[-1])
    top["depth"] = len(frames)
    top["session_id"] = key
    if field:
        value = top.get(field)
        if value is not None:
            sys.stdout.write("%s\n" % value)
        sys.exit(0)
    json.dump(top, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    sys.exit(0)

if op == "write":
    situation, run_id, skill = sys.argv[5], sys.argv[6], sys.argv[7]
    expires = now + int(round(ttl_minutes * 60))
    # PURE PUSH: always a new frame with a new token, never a match against an existing one. Whether a
    # caller is entering a new phase or still inside its own is something only the caller knows; guessing
    # from the situation name was wrong at every depth we tried (see the write doc in the header and the
    # rapport E67_S04_T01-marker-noop-cost-claim-and-nested-refresh.md). A caller extending its own frame
    # says so with "refresh --token". Expired frames were already dropped by live() above, so a stale frame
    # is never resurrected or counted.
    token = mint_token(key, situation, now)
    frames = frames + [{
        "token": token,
        "situation": situation,
        "run_id": run_id or None,
        "skill": skill or None,
        "written_at": iso(now),
        "expires_at": iso(expires),
        "writer_pid": os.getpid(),
    }]
    dump(path, key, frames)
    sys.stdout.write("%s\n" % token)
    sys.exit(0)

if op == "refresh":
    token = sys.argv[5]
    # Exactly the frame with this token, among the LIVE ones (an expired frame was dropped by live() above,
    # so it can never be matched and so never resurrected). In place: token and position are unchanged.
    index = None
    for i in range(len(frames) - 1, -1, -1):
        if frames[i].get("token") == token:
            index = i
            break
    if index is None:
        sys.stderr.write("no live frame for token %s (never written, already cleared, or expired); nothing was refreshed\n" % token)
        sys.exit(3)
    frame = dict(frames[index])
    frame["written_at"] = iso(now)
    frame["expires_at"] = iso(now + int(round(ttl_minutes * 60)))
    frame["writer_pid"] = os.getpid()
    frames = frames[:index] + [frame] + frames[index + 1:]
    dump(path, key, frames)
    sys.stdout.write("%s\n" % token)
    sys.exit(0)

if op == "clear":
    situation, token, clear_all = sys.argv[5], sys.argv[6], sys.argv[7]
    if clear_all == "1":
        dump(path, key, [])
        sys.exit(0)
    if not frames:
        sys.exit(0)
    index = None
    if token:
        for i in range(len(frames) - 1, -1, -1):
            if frames[i].get("token") == token:
                index = i
                break
    elif situation:
        for i in range(len(frames) - 1, -1, -1):
            if frames[i].get("situation") == situation:
                index = i
                break
    else:
        index = len(frames) - 1
    if index is None:
        # Nothing matched: the frame was already cleared or already expired. Clearing is idempotent, so
        # this is a success - but the live frames are still written back, which is how an expired frame
        # below gets dropped.
        dump(path, key, frames)
        sys.exit(0)
    dump(path, key, frames[:index])
    sys.exit(0)

sys.stderr.write("internal error: unknown marker op %r\n" % op)
sys.exit(5)
'

# Runs MARKER_PY under with-lock.sh on the marker file. Returns 8 when the lock could not be acquired.
marker_py_locked() {
  local status
  bash "$SCRIPT_DIR/with-lock.sh" "$MARKER_FILE" -- python3 -c "$MARKER_PY" "$@"
  status=$?
  if [ "$status" -eq 2 ]; then
    err "could not acquire the lock on $MARKER_FILE; the marker was not changed"
    return 8
  fi
  return "$status"
}

# Best-effort pruning. Never fails the operation that triggered it (AC2, mechanism 3).
prune_quietly() {
  python3 -c "$MARKER_PY" prune "$MARKER_DIR" "$SESSION_KEY" "$TTL_MINUTES" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

cmd_write() {
  local situation="" run_id="" skill="" session="" status
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --situation) [ "$#" -ge 2 ] && [ -n "$2" ] || die 2 "--situation needs a value"; situation="$2"; shift 2 ;;
      --situation=*) situation="${1#--situation=}"; [ -n "$situation" ] || die 2 "--situation needs a value"; shift ;;
      --run) [ "$#" -ge 2 ] && [ -n "$2" ] || die 2 "--run needs a value"; run_id="$2"; shift 2 ;;
      --run=*) run_id="${1#--run=}"; [ -n "$run_id" ] || die 2 "--run needs a value"; shift ;;
      --skill) [ "$#" -ge 2 ] && [ -n "$2" ] || die 2 "--skill needs a value"; skill="$2"; shift 2 ;;
      --skill=*) skill="${1#--skill=}"; [ -n "$skill" ] || die 2 "--skill needs a value"; shift ;;
      --session) [ "$#" -ge 2 ] && [ -n "$2" ] || die 2 "--session needs a value"; session="$2"; shift 2 ;;
      --session=*) session="${1#--session=}"; [ -n "$session" ] || die 2 "--session needs a value"; shift ;;
      *) die 2 "unknown option for write: $1" ;;
    esac
  done
  [ -n "$situation" ] || die 2 "write needs --situation <s>"
  [[ "$situation" =~ $SITUATION_PATTERN ]] \
    || die 2 "bad situation \"$situation\" (must match $SITUATION_PATTERN, for example pre-commit)"
  [ -z "$run_id" ] || [[ "$run_id" =~ $RUN_ID_PATTERN ]] \
    || die 2 "bad run id \"$run_id\" (1 to 128 characters of letters, digits, dot, colon, underscore or hyphen, starting with a letter or digit)"
  [ -z "$skill" ] || [[ "$skill" =~ $SKILL_PATTERN ]] || die 2 "bad skill name \"$skill\""

  require_python3
  validate_now_override || exit 2
  resolve_session_key "$session"; status=$?
  if [ "$status" -eq 7 ]; then
    die 7 "no session key could be resolved: pass --session <key>, or set JENGA_CHECKLIST_SESSION_ID (normally CLAUDE_CODE_SESSION_ID supplies it). A marker is never written under a default key."
  fi
  [ "$status" -eq 0 ] || exit "$status"
  resolve_ttl_minutes; status=$?
  [ "$status" -eq 0 ] || exit "$status"
  resolve_marker_dir || exit 1
  resolve_marker_file

  mkdir -p "$MARKER_DIR" 2>/dev/null || die 8 "could not create the marker directory: $MARKER_DIR"
  marker_py_locked write "$MARKER_FILE" "$SESSION_KEY" "$TTL_MINUTES" "$situation" "$run_id" "$skill"
  status=$?
  if [ "$status" -ne 0 ]; then
    [ "$status" -eq 8 ] && exit 8
    die 8 "the marker was not written (situation $situation)"
  fi
  prune_quietly
  return 0
}

cmd_refresh() {
  local token="" session="" status
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --token) [ "$#" -ge 2 ] && [ -n "$2" ] || die 2 "--token needs a value"; token="$2"; shift 2 ;;
      --token=*) token="${1#--token=}"; [ -n "$token" ] || die 2 "--token needs a value"; shift ;;
      --session) [ "$#" -ge 2 ] && [ -n "$2" ] || die 2 "--session needs a value"; session="$2"; shift 2 ;;
      --session=*) session="${1#--session=}"; [ -n "$session" ] || die 2 "--session needs a value"; shift ;;
      *) die 2 "unknown option for refresh: $1" ;;
    esac
  done
  [ -n "$token" ] || die 2 "refresh needs --token <t>"
  [[ "$token" =~ $TOKEN_PATTERN ]] || die 2 "bad token \"$token\""

  require_python3
  validate_now_override || exit 2
  resolve_session_key "$session"; status=$?
  if [ "$status" -eq 7 ]; then
    die 7 "no session key could be resolved: pass --session <key>, or set JENGA_CHECKLIST_SESSION_ID (normally CLAUDE_CODE_SESSION_ID supplies it)"
  fi
  [ "$status" -eq 0 ] || exit "$status"
  resolve_ttl_minutes; status=$?
  [ "$status" -eq 0 ] || exit "$status"
  resolve_marker_dir || exit 1
  resolve_marker_file

  # No marker file means no live frame for any token. That is exit 3, never a silent success and never an
  # excuse to create the directory.
  if [ ! -f "$MARKER_FILE" ]; then
    err "no live frame for token $token (no marker file for this session); nothing was refreshed"
    return 3
  fi
  marker_py_locked refresh "$MARKER_FILE" "$SESSION_KEY" "$TTL_MINUTES" "$token"
  status=$?
  if [ "$status" -ne 0 ]; then
    [ "$status" -eq 3 ] && exit 3
    [ "$status" -eq 8 ] && exit 8
    die 8 "the marker was not refreshed (token $token)"
  fi
  prune_quietly
  return 0
}

cmd_clear() {
  local situation="" token="" session="" all=0 status
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --situation) [ "$#" -ge 2 ] && [ -n "$2" ] || die 2 "--situation needs a value"; situation="$2"; shift 2 ;;
      --situation=*) situation="${1#--situation=}"; [ -n "$situation" ] || die 2 "--situation needs a value"; shift ;;
      --token) [ "$#" -ge 2 ] && [ -n "$2" ] || die 2 "--token needs a value"; token="$2"; shift 2 ;;
      --token=*) token="${1#--token=}"; [ -n "$token" ] || die 2 "--token needs a value"; shift ;;
      --session) [ "$#" -ge 2 ] && [ -n "$2" ] || die 2 "--session needs a value"; session="$2"; shift 2 ;;
      --session=*) session="${1#--session=}"; [ -n "$session" ] || die 2 "--session needs a value"; shift ;;
      --all) all=1; shift ;;
      *) die 2 "unknown option for clear: $1" ;;
    esac
  done
  [ -z "$situation" ] || [[ "$situation" =~ $SITUATION_PATTERN ]] \
    || die 2 "bad situation \"$situation\" (must match $SITUATION_PATTERN)"
  [ -z "$token" ] || [[ "$token" =~ $TOKEN_PATTERN ]] || die 2 "bad token \"$token\""

  require_python3
  validate_now_override || exit 2
  resolve_session_key "$session"; status=$?
  # No session key: there is nothing this session could have written, so there is nothing to clear.
  # Clearing is idempotent, and an error-path caller must be able to call it unconditionally.
  [ "$status" -eq 7 ] && return 0
  [ "$status" -eq 0 ] || exit "$status"
  resolve_ttl_minutes; status=$?
  [ "$status" -eq 0 ] || exit "$status"
  resolve_marker_dir || exit 1
  resolve_marker_file

  # No file at all is a successful no-op, and must not create the directory.
  if [ ! -f "$MARKER_FILE" ]; then
    [ -d "$MARKER_DIR" ] && prune_quietly
    return 0
  fi
  marker_py_locked clear "$MARKER_FILE" "$SESSION_KEY" "$TTL_MINUTES" "$situation" "$token" "$all"
  status=$?
  if [ "$status" -ne 0 ]; then
    [ "$status" -eq 8 ] && exit 8
    die 8 "the marker was not cleared"
  fi
  prune_quietly
  return 0
}

# read never fails the caller: every state problem degrades to "no phase is active" (nothing on stdout,
# exit 0) with a warning on stderr. Only a usage error is non-zero. See the header.
cmd_read() {
  local session="" field="" status
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session) [ "$#" -ge 2 ] && [ -n "$2" ] || die 2 "--session needs a value"; session="$2"; shift 2 ;;
      --session=*) session="${1#--session=}"; [ -n "$session" ] || die 2 "--session needs a value"; shift ;;
      --field) [ "$#" -ge 2 ] && [ -n "$2" ] || die 2 "--field needs a value"; field="$2"; shift 2 ;;
      --field=*) field="${1#--field=}"; [ -n "$field" ] || die 2 "--field needs a value"; shift ;;
      *) die 2 "unknown option for read: $1" ;;
    esac
  done
  [ -z "$field" ] || [[ "$field" =~ $FIELD_PATTERN ]] || die 2 "bad field name \"$field\""

  resolve_session_key "$session"; status=$?
  [ "$status" -eq 7 ] && return 0
  [ "$status" -eq 0 ] || exit "$status"
  resolve_marker_dir >/dev/null 2>&1 || return 0
  [ -n "$MARKER_DIR" ] || return 0

  # THE CHEAP NO-MARKER PATH (E67_S04_T02's silent no-op rests on it). Cheap RELATIVE to parsing a marker,
  # not free: resolve_marker_dir above has already spent one resolve-root.sh subprocess, and that is
  # unavoidable here because the queue path must not be a hardcoded literal. From this line on it is pure
  # bash - a directory test and a glob, no subprocess, no python3, no config read. See "WHAT THE NO-MARKER
  # PATH ACTUALLY COSTS" in the header for the measured figures and for whose decision the remaining cost is.
  # A glob rather than a digest lookup, deliberately - computing this session's digest would itself cost a
  # spawn, and "no marker file exists at all" is the case an ordinary session is in. Only once some marker
  # exists does anything below run, and the per-session check still happens there (python derives this
  # session's own file name and load() re-checks the stored session_id), so the glob is a fast reject and
  # never a way to read another session's phase.
  [ -d "$MARKER_DIR" ] || return 0
  set -- "$MARKER_DIR"/marker-*.json
  [ -e "$1" ] || return 0

  command -v python3 >/dev/null 2>&1 || { err "warning: python3 is not available; reporting no active phase"; return 0; }
  validate_now_override || return 0
  resolve_ttl_minutes >/dev/null 2>&1 || { err "warning: marker_ttl_minutes is unavailable, so expiry cannot be judged; reporting no active phase"; return 0; }
  python3 -c "$MARKER_PY" read "$MARKER_DIR" "$SESSION_KEY" "$TTL_MINUTES" "$field" || return 0
  return 0
}

cmd_path() {
  local session="" status
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session) [ "$#" -ge 2 ] && [ -n "$2" ] || die 2 "--session needs a value"; session="$2"; shift 2 ;;
      --session=*) session="${1#--session=}"; [ -n "$session" ] || die 2 "--session needs a value"; shift ;;
      *) die 2 "unknown option for path: $1" ;;
    esac
  done
  require_python3
  resolve_session_key "$session"; status=$?
  [ "$status" -eq 7 ] && die 7 "no session key could be resolved"
  [ "$status" -eq 0 ] || exit "$status"
  resolve_marker_dir || exit 1
  resolve_marker_file
  printf '%s\n' "$MARKER_FILE"
}

cmd_session_key() {
  local status
  [ "$#" -eq 0 ] || die 2 "session-key takes no arguments"
  resolve_session_key ""; status=$?
  [ "$status" -eq 7 ] && exit 7
  [ "$status" -eq 0 ] || exit "$status"
  printf '%s\n' "$SESSION_KEY"
}

cmd_prune() {
  local status
  [ "$#" -eq 0 ] || die 2 "prune takes no arguments"
  require_python3
  validate_now_override || exit 2
  resolve_ttl_minutes; status=$?
  [ "$status" -eq 0 ] || exit "$status"
  resolve_marker_dir || exit 1
  [ -d "$MARKER_DIR" ] || return 0
  SESSION_KEY=""
  prune_quietly
  return 0
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
[ "$#" -ge 1 ] || { usage >&2; exit 2; }
SUBCOMMAND="$1"
shift
case "$SUBCOMMAND" in
  write) cmd_write "$@" ;;
  refresh) cmd_refresh "$@" ;;
  clear) cmd_clear "$@" ;;
  read) cmd_read "$@" ;;
  path) cmd_path "$@" ;;
  session-key) cmd_session_key "$@" ;;
  prune) cmd_prune "$@" ;;
  -h|--help|help) usage; exit 0 ;;
  *) err "unknown subcommand: $SUBCOMMAND"; usage >&2; exit 2 ;;
esac
