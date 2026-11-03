#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-workflow-recorder/scripts/active-recording.sh - the pointer to the live recording
# (epic E89, task E89_S01_T03)
#
# Records WHICH recording document this session is currently appending to, so a later turn can find it without
# relying on conversation memory. E89_S02's acceptance criteria require a recording to survive a context
# summarisation mid-session: a fact held in the turn does not survive that, and a file does. This is that file,
# and nothing else in the recorder carries the information.
#
# The recorder's skill body calls "set" when it starts a recording and "clear" when it ends one; every append in
# between asks "get" where to write. "get" prints the path and NOTHING else, and exits non-zero when there is no
# active recording, so a caller branches on the exit code rather than parsing prose.
#
# ---------------------------------------------------------------------------
# HOW THIS DIFFERS FROM scripts/checklist-marker.sh, AND WHY
# ---------------------------------------------------------------------------
# That script is the precedent this one follows for mechanics: a session-keyed state file, a TTL read from
# configuration, expired entries dropped on write, a mkdir-based lock for every read-modify-write, an atomic
# temp-file-then-rename, lock-free readers, and a token returned so a caller can clear exactly what it set. All
# of that is deliberately the same shape, and where this header says "as the marker does" it means exactly that.
#
# ONE substantive difference, and the whole reason this is a separate script rather than another marker
# situation: THE MARKER HOLDS A STACK, THIS HOLDS A SINGLE VALUE.
#   - The marker models lifecycle PHASES, which nest (pre-task may contain pre-commit). It therefore needs a
#     stack, a pure-push "write" that never tries to guess whether the caller means "entering" or "still in",
#     a "refresh" that extends one frame in place wherever it sits, and a "clear" that pops a frame together
#     with everything above it because an inner phase cannot outlive the phase enclosing it.
#   - A recorder has exactly ONE live recording. Recordings do not nest: a second recording is not an inner
#     scope of the first, it is a different process being recorded, and starting one while another is live is a
#     mistake worth stopping for rather than a nesting to model. So the state is a single "active" object or
#     null, and every stack-shaped rule above collapses: no depth, no frame matching at any depth, no
#     abandonment rule.
# That difference is why "set" REFUSES when a recording is already active (exit 6, naming the active path on
# stderr) instead of pushing a second entry the way the marker's "write" pushes a second frame. A push would
# silently make the older recording unreachable; the refusal lets E89_S02_T02 implement "starting a second
# recording while one is active is handled explicitly" as a decision rather than an accident. "--force" is the
# documented, and only, way to replace a live pointer.
#
# Two smaller divergences, for completeness:
#   - All JSON work is done in python3, including reading the TTL from configuration. The marker uses python3
#     for its store and jq for its TTL; doing both in python drops a dependency and a failure mode.
#   - There is no "prune" sub-command. Expired entries are dropped on every write, and a dead sibling file is
#     removed on write too, so there is nothing left for a separate sweep to collect.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   active-recording.sh set <path> [--force] [--title <t>] [--session <key>]
#   active-recording.sh get [--session <key>]
#   active-recording.sh clear [--token <t>] [--session <key>]
#   active-recording.sh status [--field <name>] [--session <key>]
#   active-recording.sh refresh --token <t> [--session <key>]
#   active-recording.sh path [--session <key>]
#   active-recording.sh session-key
#   active-recording.sh -h | --help | help        print this usage on stdout, exit 0
#
# set <path> [--force] [--title <t>]
#   Points this session at <path> and prints that pointer's TOKEN on stdout (and nothing else), so the caller
#   can later clear exactly what it set. <path> is stored VERBATIM and is neither made absolute nor required to
#   exist: "get" must print back exactly what was set, and a caller that wants an absolute path passes one
#   (recording-path.sh always produces one). --title records the recording's title for diagnostics only;
#   nothing branches on it.
#   With a recording already active, set exits 6, prints the already-active path on STDERR, and prints nothing
#   on stdout. --force replaces the pointer instead, and is the only way to do so.
#
# get
#   Prints the active recording's path on stdout and nothing else, exit 0. With no active recording - never
#   set, cleared, or expired - prints NOTHING on stdout and exits 3.
#
# clear [--token <t>]
#   Drops the pointer. Idempotent and never an error: no state file, no active entry, or an already-expired
#   entry all succeed silently with exit 0, because a caller on an error path must be able to clear
#   unconditionally without knowing whether its set landed.
#   With --token, clears only when that token matches the live entry. A live entry with a DIFFERENT token is
#   not cleared (someone else's pointer, most likely a --force replacement); that is reported on stderr but
#   still exits 0, since the caller's own entry is gone either way.
#
# status [--field <name>]
#   Prints the state as one JSON object on stdout and exits 0 whether or not a recording is active - so a
#   caller can see "nothing is active" without treating it as a failure, which is the one thing "get" cannot
#   express. --field prints a single value as a bare line (path, token, title, set_at, expires_at, session_id,
#   writer_pid, active); an absent or null field prints nothing.
#
# refresh --token <t>
#   Extends the live entry's expiry in place; its token and path are unchanged. Prints the token. A token that
#   names no live entry - never set, already cleared, expired, or replaced - exits 3 and changes nothing, so the
#   caller can branch and set again. An expired entry is never resurrected.
#
# path / session-key
#   Print the state file this session would use, and the resolved session key. Diagnostics; neither creates
#   anything.
#
# ---------------------------------------------------------------------------
# WHERE STATE LIVES
# ---------------------------------------------------------------------------
#   Directory: "$(resolve-root.sh get queue)/active-recordings/" (test seam: JENGA_RECORDING_STATE_DIR),
#   resolved through the root resolver, never a working-tree literal. Under the QUEUE directory, as E89's
#   dispatch ruling settles and as the marker resolves its own MARKER_DIR - not a new state location. A
#   sibling of the situation marker's and the tick store's directories, for the reasons the marker gives: the
#   queue is blocklisted for the public mirror so session state never ships downstream, and this directory is
#   ignored by git so a transient "which recording am I appending to" value is never committed. A committed
#   pointer would make every clone believe a recording is live.
#     recording-<digest>.json   one file per session key, digest = sha256(key) truncated to 24 hex characters
#     <name>.lock.d             with-lock.sh's lock directory next to the file being written
#     .tmp-<name>.<pid>         a write in flight (renamed over <name> when complete)
#   File shape: {"version": 1, "session_id": "<key>", "active": {...} | null} where the active object is
#   {"token", "path", "title", "set_at", "expires_at", "writer_pid"}.
#   The directory is created by the first write; get, status, path and session-key create nothing.
#
#   NOT used as a liveness signal, for the same reason the marker rejects it: the writing PROCESS's pid. The
#   writer is a short-lived script invocation that has already exited by the time anyone reads the pointer, so
#   a pid-liveness check would report nearly every pointer as orphaned. writer_pid is recorded for diagnostics
#   only and nothing branches on it. The liveness keys that do work are the session key and the TTL.
#
#   Known limit, inherited from the root resolver and not re-litigated here (already recorded for the tick
#   store and the marker): state is rooted at the resolved project root, so a session inside a git worktree
#   resolves that worktree's own tree. Benign for a recorder: its writer and its readers run in the same tree.
#
# ---------------------------------------------------------------------------
# THE TTL, AND WHERE IT COMES FROM
# ---------------------------------------------------------------------------
# SOURCE: the key "recording_ttl_minutes" in "$(resolve-root.sh get configs)/scope-thresholds.json", read
# fresh on every operation that needs it - exactly how the marker reads marker_ttl_minutes from the same file.
# Nothing about the TTL is a decision made in the code when that key is present.
#
# The key IS in the shipped configuration file, with the value 90 (E89_S05_T04). An absent key (a project whose
# configuration predates it, or a hand-trimmed file) falls back to DEFAULT_TTL_MINUTES below (90 minutes) rather
# than hard-failing, and the script's default is kept equal to the shipped value so the two never disagree. A key
# that IS present but is not a positive number is a configuration ERROR (exit 5), never silently ignored: a
# misconfigured TTL must be audible, while a missing one must not break the feature.
#
# Why 90 is the value, and the trade-off it is: the user chose it (2026-11-02). The two failure modes are not
# symmetric in cost, but the cheap one is cheap to avoid. Too SHORT and a healthy recording would silently lose
# its pointer mid-session, so the next append would have nowhere to go; that is avoided not by a long ceiling but
# by `refresh`, which a live recording uses to renew its own entry in place, so a short TTL only has to outlast
# the gap between refreshes. Too LONG and a dead session leaves a stale pointer that outlives it, so the next
# "set" refuses until someone passes --force or clears. 90 lets a dead session's pointer expire within about an
# hour and a half, where the earlier unapproved fallback of 720 minutes (12 hours) would have let a session that
# died yesterday still look live today. For reference the marker's marker_ttl_minutes is 60 and the concurrency
# slot's slot_ttl_minutes is 45, in the same file. It is a judgement, not a measurement.
# JENGA_RECORDING_TTL_MINUTES overrides it as a TEST SEAM (style of JENGA_CHECKLIST_MARKER_TTL_MINUTES); it is
# not a configuration surface and nothing should set it in use.
#
# ---------------------------------------------------------------------------
# ENVIRONMENT (test seams, in the style of scripts/checklist-marker.sh; unset in normal use)
# ---------------------------------------------------------------------------
#   JENGA_RECORDING_STATE_DIR       use this directory instead of <queue>/active-recordings
#   JENGA_RECORDING_TTL_MINUTES     override recording_ttl_minutes (a positive number of minutes)
#   JENGA_SCOPE_THRESHOLDS_FILE     read the TTL from this file instead of <configs>/scope-thresholds.json
#   JENGA_RECORDING_NOW             the current time for stamps and ages, UTC, as 2026-11-01T13:40:12Z
# Not a test seam (normal interface):
#   JENGA_RECORDING_SESSION_ID      the session key, when --session is not given
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   success. Includes "status: nothing active" and every idempotent clear.
#   1   the queue or configs directory could not be resolved.
#   2   usage error: no sub-command, an unknown sub-command or option, a missing option argument, a bad session
#       key, token, field name, path, or a bad JENGA_RECORDING_NOW / JENGA_RECORDING_TTL_MINUTES.
#   3   get: no active recording. refresh: the token names no live entry; nothing was changed.
#   4   python3 is not installed.
#   5   recording_ttl_minutes is present in the configuration file but is not a positive number.
#   6   set: a recording is already active and --force was not given. Nothing was changed, and the
#       already-active path is on stderr.
#   7   no session key could be resolved.
#   8   the state was NOT written: the directory could not be created, the lock could not be acquired, or the
#       write failed.
# These codes are not parallel to scripts/checklist-marker.sh's table, which assigns some of the same numbers
# different meanings. Read this table, not that one.
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions) and safe under
# `set -u`.
# ---------------------------------------------------------------------------

set -u
export LC_ALL=C

STATE_SUBDIR="active-recordings"
STATE_FILE_VERSION=1
DEFAULT_TTL_MINUTES=90
SESSION_KEY_PATTERN='^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'
TOKEN_PATTERN='^[A-Za-z0-9._:-]{1,160}$'
FIELD_PATTERN='^[a-z_]{1,32}$'

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The shared scripts directory, reached by climbing from this skill's scripts directory rather than naming any
# path from the resolved root.
SHARED_DIR="$SCRIPT_DIR/../../../scripts"

STATE_DIR=""
STATE_FILE=""
SESSION_KEY=""
CONFIG_FILE=""

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
  active-recording.sh set <path> [--force] [--title <t>] [--session <key>]
  active-recording.sh get [--session <key>]
  active-recording.sh clear [--token <t>] [--session <key>]
  active-recording.sh status [--field <name>] [--session <key>]
  active-recording.sh refresh --token <t> [--session <key>]
  active-recording.sh path [--session <key>]
  active-recording.sh session-key
  active-recording.sh -h | --help | help

Records which recording document this session is appending to, so a later turn can find it without relying on
conversation memory. set on start (prints a token so you can clear exactly what you set), clear on end, get in
between: get prints the path alone and exits non-zero when nothing is active. A recorder holds ONE active
recording, so set refuses rather than replacing a live pointer - pass --force to replace deliberately. An
expired entry is treated as absent, so a dead session cannot wedge a later one. One file per session key.
Full contract: the header of this script.
USAGE
}

# Sets STATE_DIR. Returns 1 when the queue directory cannot be resolved.
resolve_state_dir() {
  local queue
  if [ -n "${JENGA_RECORDING_STATE_DIR:-}" ]; then
    STATE_DIR="$JENGA_RECORDING_STATE_DIR"
    return 0
  fi
  if [ ! -f "$SHARED_DIR/resolve-root.sh" ]; then
    err "could not find resolve-root.sh (looked for $SHARED_DIR/resolve-root.sh)"
    return 1
  fi
  if ! queue="$(bash "$SHARED_DIR/resolve-root.sh" get queue)" || [ -z "$queue" ]; then
    err "could not resolve the queue directory via resolve-root.sh"
    return 1
  fi
  STATE_DIR="$queue/$STATE_SUBDIR"
  return 0
}

# Sets CONFIG_FILE, the file the TTL is read from. Returns 1 when the configs directory cannot be resolved.
# An absent file is NOT an error here: the python side falls back to the documented default.
resolve_config_file() {
  local configs
  if [ -n "${JENGA_SCOPE_THRESHOLDS_FILE:-}" ]; then
    CONFIG_FILE="$JENGA_SCOPE_THRESHOLDS_FILE"
    return 0
  fi
  if ! configs="$(bash "$SHARED_DIR/resolve-root.sh" get configs)" || [ -z "$configs" ]; then
    err "could not resolve the configs directory via resolve-root.sh"
    return 1
  fi
  CONFIG_FILE="$configs/scope-thresholds.json"
  return 0
}

# Sets SESSION_KEY from the documented probe order. $1 is an explicit --session value ("" for none).
# Returns 7 when no key could be resolved, 2 when the resolved key is malformed.
resolve_session_key() {
  local explicit="${1:-}" key=""
  if [ -n "$explicit" ]; then
    key="$explicit"
  elif [ -n "${JENGA_RECORDING_SESSION_ID:-}" ]; then
    key="$JENGA_RECORDING_SESSION_ID"
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

# Prints the first 24 hex characters of sha256 of $1 - the situation marker's rule, same length.
key_digest() {
  printf '%s' "$1" | python3 -c 'import hashlib,sys; sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:24])'
}

resolve_state_file() {
  STATE_FILE="$STATE_DIR/recording-$(key_digest "$SESSION_KEY").json"
}

require_python3() {
  command -v python3 >/dev/null 2>&1 || die 4 "python3 is required but was not found on PATH"
}

# ---------------------------------------------------------------------------
# The pointer store, in python3.
#
# Invoked as: STATE_PY <op> <state-file> <session-key> <config-file> [op args...]
#   ops: set <path> <title> <force>   print the token; exit 6 when already active and force is not "1"
#        get                          print the path; exit 3 when nothing is active
#        clear <token>                drop the pointer; always exit 0
#        status <field>               print the state as JSON, or one field; always exit 0
#        refresh <token>              extend the live entry in place; exit 3 when the token names none
# Every op drops an expired entry before doing anything else, so an expired entry is never observable.
# ---------------------------------------------------------------------------
STATE_PY='
import calendar, hashlib, json, os, re, sys, time

FILE_VERSION = 1
ISO = re.compile(r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$")

def now_epoch():
    override = os.environ.get("JENGA_RECORDING_NOW", "")
    if override:
        m = ISO.match(override)
        if not m:
            sys.stderr.write("bad JENGA_RECORDING_NOW %r (expected a UTC time like 2026-11-01T13:40:12Z)\n" % override)
            sys.exit(2)
        return calendar.timegm(tuple(int(g) for g in m.groups()) + (0, 0, 0))
    return int(time.time())

def iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))

def parse_iso(s):
    if not isinstance(s, str):
        return None
    m = ISO.match(s)
    if not m:
        return None
    try:
        return calendar.timegm(tuple(int(g) for g in m.groups()) + (0, 0, 0))
    except Exception:
        return None

def positive(raw):
    try:
        v = float(raw)
    except (TypeError, ValueError):
        return None
    if v != v or v in (float("inf"), float("-inf")) or v <= 0:
        return None
    return v

def ttl_minutes(config_file, default_minutes):
    """The TTL, from the env seam, then the configuration key, then the documented default.
    A key that is PRESENT but invalid is exit 5: a misconfigured TTL must be audible, while an
    unshipped one must not break the feature."""
    override = os.environ.get("JENGA_RECORDING_TTL_MINUTES", "")
    if override:
        v = positive(override)
        if v is None:
            sys.stderr.write("bad JENGA_RECORDING_TTL_MINUTES %r (expected a positive number of minutes)\n" % override)
            sys.exit(2)
        return v
    try:
        with open(config_file, "r") as fh:
            doc = json.load(fh)
    except IOError:
        return float(default_minutes)
    except ValueError:
        sys.stderr.write("%s contains malformed JSON; using the default TTL of %s minutes\n"
                         % (config_file, default_minutes))
        return float(default_minutes)
    if not isinstance(doc, dict) or "recording_ttl_minutes" not in doc:
        return float(default_minutes)
    v = positive(doc.get("recording_ttl_minutes"))
    if v is None:
        sys.stderr.write("invalid recording_ttl_minutes in %s (expected a positive number of minutes)\n" % config_file)
        sys.exit(5)
    return v

def load(path, key):
    """The stored active entry, or None. Anything unreadable, non-JSON, wrongly shaped, belonging to another
    session key, or expired reads as NO active recording, with a warning where something was actually wrong.
    A broken lookup must never be reported as another session recording."""
    try:
        with open(path, "r") as fh:
            doc = json.load(fh)
    except IOError:
        return None
    except ValueError:
        sys.stderr.write("state file is not valid JSON; treating it as absent: %s\n" % path)
        return None
    if not isinstance(doc, dict):
        sys.stderr.write("state file is not shaped as a pointer; treating it as absent: %s\n" % path)
        return None
    stored = doc.get("session_id")
    if stored != key:
        sys.stderr.write("state file belongs to session %r, not %r; treating it as absent: %s\n"
                         % (stored, key, path))
        return None
    active = doc.get("active")
    if not isinstance(active, dict) or not isinstance(active.get("path"), str) or not active["path"]:
        return None
    return active

def live(active, now):
    """The entry if it has not expired, else None. An entry with no parsable expires_at is expired by
    definition: an unreadable expiry is never trusted."""
    if active is None:
        return None
    exp = parse_iso(active.get("expires_at"))
    if exp is None or exp <= now:
        return None
    return active

def dump(path, key, active):
    """Atomic replace: temp file in the same directory, fsynced, renamed over the target. A file with no active
    entry left is removed rather than left as an empty husk, so nothing accumulates."""
    d = os.path.dirname(path) or "."
    if active is None:
        try:
            os.unlink(path)
        except OSError:
            pass
        return
    doc = {"version": FILE_VERSION, "session_id": key, "active": active}
    tmp = os.path.join(d, ".tmp-%s.%d" % (os.path.basename(path), os.getpid()))
    with open(tmp, "w") as fh:
        json.dump(doc, fh, indent=2, sort_keys=True)
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.rename(tmp, path)

def sweep_siblings(path, now):
    """Best effort: remove sibling state files whose entry has expired, and write-in-flight leftovers older
    than a day. Never fails the operation that triggered it, and only ever matches this feature\x27s own
    names, so a neighbouring feature\x27s state cannot be touched."""
    d = os.path.dirname(path) or "."
    try:
        names = os.listdir(d)
    except OSError:
        return
    for name in names:
        full = os.path.join(d, name)
        if full == path:
            continue
        if re.match(r"^recording-[0-9a-f]{24}\.json$", name):
            try:
                with open(full, "r") as fh:
                    doc = json.load(fh)
                entry = doc.get("active") if isinstance(doc, dict) else None
                keep = live(entry if isinstance(entry, dict) else None, now)
            except (IOError, ValueError, TypeError):
                keep = None
            if keep is None:
                try:
                    os.unlink(full)
                except OSError:
                    pass
        elif name.startswith(".tmp-recording-") or name.endswith(".lock.d"):
            try:
                if now - os.path.getmtime(full) > 86400:
                    if os.path.isdir(full):
                        import shutil
                        shutil.rmtree(full, ignore_errors=True)
                    else:
                        os.unlink(full)
            except OSError:
                pass

def mint_token(key, target, now):
    seed = "%s|%s|%d|%d" % (key, target, now, os.getpid())
    return "rec-%s" % hashlib.sha256(seed.encode("utf-8")).hexdigest()[:16]

op = sys.argv[1]
path = sys.argv[2]
key = sys.argv[3]
config_file = sys.argv[4]
default_minutes = sys.argv[5]
now = now_epoch()

active = live(load(path, key), now)

if op == "get":
    if active is None:
        sys.exit(3)
    sys.stdout.write("%s\n" % active["path"])
    sys.exit(0)

if op == "status":
    field = sys.argv[6] if len(sys.argv) > 6 else ""
    state = {"version": FILE_VERSION, "session_id": key, "active": active}
    if field:
        if field == "active":
            sys.stdout.write("%s\n" % ("true" if active else "false"))
        elif field == "session_id":
            sys.stdout.write("%s\n" % key)
        elif active is not None and active.get(field) is not None:
            sys.stdout.write("%s\n" % active[field])
        sys.exit(0)
    sys.stdout.write("%s\n" % json.dumps(state, indent=2, sort_keys=True))
    sys.exit(0)

if op == "set":
    target, title, force = sys.argv[6], sys.argv[7], sys.argv[8]
    if active is not None and force != "1":
        sys.stderr.write("a recording is already active: %s\n" % active["path"])
        sys.stderr.write("pass --force to replace it, or clear it first\n")
        sys.exit(6)
    minutes = ttl_minutes(config_file, default_minutes)
    entry = {
        "token": mint_token(key, target, now),
        "path": target,
        "title": title or None,
        "set_at": iso(now),
        "expires_at": iso(now + int(minutes * 60)),
        "writer_pid": os.getpid(),
    }
    dump(path, key, entry)
    sweep_siblings(path, now)
    sys.stdout.write("%s\n" % entry["token"])
    sys.exit(0)

if op == "clear":
    token = sys.argv[6] if len(sys.argv) > 6 else ""
    if active is None:
        # Idempotent: remove any husk and succeed. Nothing to report.
        dump(path, key, None)
        sweep_siblings(path, now)
        sys.exit(0)
    if token and active.get("token") != token:
        sys.stderr.write("the active recording (%s) was not set by this token; leaving it alone\n"
                         % active["path"])
        sys.exit(0)
    dump(path, key, None)
    sweep_siblings(path, now)
    sys.exit(0)

if op == "refresh":
    token = sys.argv[6]
    if active is None or active.get("token") != token:
        sys.stderr.write("no live recording for that token; nothing was changed\n")
        sys.exit(3)
    minutes = ttl_minutes(config_file, default_minutes)
    active["expires_at"] = iso(now + int(minutes * 60))
    dump(path, key, active)
    sweep_siblings(path, now)
    sys.stdout.write("%s\n" % token)
    sys.exit(0)

sys.stderr.write("unknown op %r\n" % op)
sys.exit(2)
'

# Runs STATE_PY directly, for the read-only ops. No lock, no directory creation: a writer renames a finished
# temp file over the target, so a reader always sees a whole old or a whole new file.
run_py_unlocked() {
  python3 -c "$STATE_PY" "$1" "$STATE_FILE" "$SESSION_KEY" "$CONFIG_FILE" "$DEFAULT_TTL_MINUTES" "${@:2}"
}

# Runs STATE_PY under with-lock.sh on the state file, for the ops that mutate it. Returns 8 when the directory
# could not be created or the lock could not be acquired.
run_py_locked() {
  local rc
  if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
    err "could not create the state directory $STATE_DIR; nothing was written"
    return 8
  fi
  if [ ! -f "$SHARED_DIR/with-lock.sh" ]; then
    err "could not find with-lock.sh (looked for $SHARED_DIR/with-lock.sh); nothing was written"
    return 8
  fi
  bash "$SHARED_DIR/with-lock.sh" "$STATE_FILE" -- \
    python3 -c "$STATE_PY" "$1" "$STATE_FILE" "$SESSION_KEY" "$CONFIG_FILE" "$DEFAULT_TTL_MINUTES" "${@:2}"
  rc=$?
  # with-lock.sh exits 2 when it could NOT acquire the lock and the command never ran. STATE_PY also uses 2,
  # for a bad environment override, so the two are pre-separated: every override is validated below, before
  # any locked call, which leaves 2 here meaning only "lock not acquired".
  if [ "$rc" -eq 2 ]; then
    err "could not acquire the lock on $STATE_FILE; nothing was written"
    return 8
  fi
  return $rc
}

# Catches a malformed JENGA_RECORDING_NOW / JENGA_RECORDING_TTL_MINUTES here, before any locked call, so
# STATE_PY's exit 2 can never be confused with with-lock.sh's "lock not acquired" 2.
validate_env_overrides() {
  if [ -n "${JENGA_RECORDING_NOW:-}" ]; then
    if ! printf '%s' "$JENGA_RECORDING_NOW" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
      die 2 "bad JENGA_RECORDING_NOW \"$JENGA_RECORDING_NOW\" (expected a UTC time like 2026-11-01T13:40:12Z)"
    fi
  fi
  if [ -n "${JENGA_RECORDING_TTL_MINUTES:-}" ]; then
    if ! python3 -c 'import math,sys; v=float(sys.argv[1]); sys.exit(0 if math.isfinite(v) and v > 0 else 1)' \
      "$JENGA_RECORDING_TTL_MINUTES" 2>/dev/null; then
      die 2 "bad JENGA_RECORDING_TTL_MINUTES \"$JENGA_RECORDING_TTL_MINUTES\" (expected a positive number of minutes)"
    fi
  fi
}

# Shared option parsing. Sets OPT_SESSION, OPT_TOKEN, OPT_FIELD, OPT_TITLE, OPT_FORCE and POSITIONAL.
OPT_SESSION=""
OPT_TOKEN=""
OPT_FIELD=""
OPT_TITLE=""
OPT_FORCE=0
POSITIONAL=""
parse_options() {
  local a
  OPT_SESSION=""; OPT_TOKEN=""; OPT_FIELD=""; OPT_TITLE=""; OPT_FORCE=0; POSITIONAL=""
  while [ "$#" -gt 0 ]; do
    a="$1"
    case "$a" in
      --session) [ "$#" -ge 2 ] || die 2 "--session needs a key"; OPT_SESSION="$2"; shift 2 ;;
      --session=*) OPT_SESSION="${a#--session=}"; shift ;;
      --token) [ "$#" -ge 2 ] || die 2 "--token needs a value"; OPT_TOKEN="$2"; shift 2 ;;
      --token=*) OPT_TOKEN="${a#--token=}"; shift ;;
      --field) [ "$#" -ge 2 ] || die 2 "--field needs a name"; OPT_FIELD="$2"; shift 2 ;;
      --field=*) OPT_FIELD="${a#--field=}"; shift ;;
      --title) [ "$#" -ge 2 ] || die 2 "--title needs a value"; OPT_TITLE="$2"; shift 2 ;;
      --title=*) OPT_TITLE="${a#--title=}"; shift ;;
      --force) OPT_FORCE=1; shift ;;
      --) shift; break ;;
      -*) usage >&2; die 2 "unknown option \"$a\"" ;;
      *)
        if [ -n "$POSITIONAL" ]; then
          usage >&2
          die 2 "unexpected argument \"$a\""
        fi
        POSITIONAL="$a"; shift
        ;;
    esac
  done
  if [ -n "$OPT_TOKEN" ] && ! [[ "$OPT_TOKEN" =~ $TOKEN_PATTERN ]]; then
    die 2 "bad token \"$OPT_TOKEN\""
  fi
  if [ -n "$OPT_FIELD" ] && ! [[ "$OPT_FIELD" =~ $FIELD_PATTERN ]]; then
    die 2 "bad field name \"$OPT_FIELD\" (lowercase letters and underscores only)"
  fi
}

# Resolves everything the mutating and reading ops need. $1 = 1 to also resolve the config file.
prepare() {
  local want_config="${1:-1}" rc
  resolve_state_dir || exit 1
  if [ "$want_config" = "1" ]; then
    resolve_config_file || exit 1
  else
    CONFIG_FILE="/dev/null"
  fi
  resolve_session_key "$OPT_SESSION"
  rc=$?
  if [ "$rc" -eq 7 ]; then
    die 7 "no session key could be resolved; pass --session <key> or set JENGA_RECORDING_SESSION_ID"
  fi
  [ "$rc" -eq 0 ] || exit "$rc"
  resolve_state_file
}

main() {
  local cmd=""
  [ "$#" -ge 1 ] || { usage >&2; die 2 "no sub-command given"; }
  cmd="$1"; shift

  case "$cmd" in
    -h|--help|help) usage; return 0 ;;
  esac

  require_python3
  parse_options "$@"
  validate_env_overrides

  case "$cmd" in
    set)
      [ -n "$POSITIONAL" ] || { usage >&2; die 2 "set needs a recording path"; }
      prepare 1
      run_py_locked set "$POSITIONAL" "$OPT_TITLE" "$OPT_FORCE"
      ;;
    get)
      [ -z "$POSITIONAL" ] || die 2 "get takes no positional argument"
      prepare 0
      run_py_unlocked get
      ;;
    clear)
      [ -z "$POSITIONAL" ] || die 2 "clear takes no positional argument"
      prepare 0
      if [ ! -d "$STATE_DIR" ]; then
        # Nothing was ever written for any session. Idempotent success, and no directory is created just to
        # clear something that does not exist.
        return 0
      fi
      run_py_locked clear "$OPT_TOKEN"
      ;;
    status)
      [ -z "$POSITIONAL" ] || die 2 "status takes no positional argument"
      prepare 0
      run_py_unlocked status "$OPT_FIELD"
      ;;
    refresh)
      [ -n "$OPT_TOKEN" ] || { usage >&2; die 2 "refresh needs --token"; }
      prepare 1
      if [ ! -f "$STATE_FILE" ]; then
        err "no live recording for that token; nothing was changed"
        return 3
      fi
      run_py_locked refresh "$OPT_TOKEN"
      ;;
    path)
      [ -z "$POSITIONAL" ] || die 2 "path takes no positional argument"
      prepare 0
      printf '%s\n' "$STATE_FILE"
      ;;
    session-key)
      prepare 0
      printf '%s\n' "$SESSION_KEY"
      ;;
    *) usage >&2; die 2 "unknown sub-command \"$cmd\"" ;;
  esac
}

main "$@"
exit $?
