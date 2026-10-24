#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/perceived-branch.sh - the per-session perceived branch (epic E78, task E78_S01_T02)
#
# Lets a session treat a branch other than the checked-out one as its working branch WITHOUT moving the real
# checkout. This script is the one authoritative place every other E78 component asks "which branch am I
# working against": the j-checkout skill sets it, task worktrees read it, the SessionEnd hook clears it.
# It records and reads a per-session state file and creates a missing branch; it never moves the checkout and
# never touches the main working tree's files or index.
#
# The session id is not observable from inside a script, so the key is RESOLVED. The full rationale (what the
# Bash tool, the SessionEnd hook and the WorktreeCreate hook each see, and why JENGA_SESSION_ID cannot be
# trusted at SessionEnd) is in project/documentation/perceived-branch-session-id.md (task E78_S01_T01).
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   perceived-branch.sh set <branch> [--session <key>]
#   perceived-branch.sh get [--real | --perceived] [--session <key>]
#   perceived-branch.sh clear [--session <key>]
#   perceived-branch.sh exists <branch>
#   perceived-branch.sh -h | --help | help        print this header's usage on stdout, exit 0
#
# set <branch>
#   Records <branch> as this session's perceived branch. If the local branch does not exist it is first
#   created from the currently checked-out branch of the MAIN working tree, with a plain branch creation (the
#   checkout is never moved, so the real branch and the main tree's working files are unchanged). Refuses,
#   writing nothing and creating no branch, when no session key can be resolved (exit 7).
#
# exists <branch>
#   Exits 0 when the local branch exists, 1 otherwise (including a name that cannot be a branch). Prints
#   nothing. Needs no session key. It lets a caller ask before set creates a branch.
#
# get [--real | --perceived]
#   Default: prints the perceived branch when one is set and still exists, otherwise the real branch.
#   --real       always prints the real checked-out branch of the main working tree.
#   --perceived  prints ONLY a set, still-existing perceived branch; with none it prints nothing and exits 1.
#   A state file naming a branch that no longer exists never makes get fail: the default form falls back to
#   the real branch and writes one notice on stderr (--perceived prints nothing and exits 1, with that notice).
#   With no resolvable session key, default get prints the real branch (exit 0, notice on stderr).
#   A detached HEAD has no real branch: get then prints nothing, writes a notice and exits 1.
#
# clear
#   Removes this session's state file; a later get reports the real branch. Idempotent: nothing to clear, or no
#   resolvable key, is a notice on stderr and exit 0.
#
# --session <key> (all subcommands but exists; also --session=<key>)
#   Overrides the resolved key. This is the test seam and what the SessionEnd hook passes.
#
# ---------------------------------------------------------------------------
# SESSION KEY (probe order, identical to scripts/checklist-marker.sh)
# ---------------------------------------------------------------------------
#   1. --session <key>
#   2. JENGA_CHECKLIST_SESSION_ID   explicit override and the bats seam
#   3. CLAUDE_CODE_SESSION_ID       the harness session id; the normal source in every caller
#   4. JENGA_SESSION_ID             only meaningful where the harness id is absent. At SessionEnd it is a
#                                   random uuid (see the finding above), so this script never relies on it
#                                   inside the hook: the hook must pass --session explicitly.
# A key is 1 to 128 characters of [A-Za-z0-9._-], starting with a letter or digit and containing no "..";
# anything else is rejected (exit 2), so a key can never contain a path separator or climb out of the state
# directory. There is NO clone-wide or default key and no fallback file: another session's file is never
# opened when asked about this session's key, and a file whose stored session_id differs from the requested key
# is treated as unset.
#
# ---------------------------------------------------------------------------
# STATE
# ---------------------------------------------------------------------------
# <queue directory>/perceived-branch/<session-key>.json, where the queue directory is the output of
# "resolve-root.sh get queue" (never a hardcoded working-tree path). Contents: {session_id, branch, set_at}.
# Written atomically (temp file in the same directory, then mv). Read-only commands never create anything.
# The "real" branch and the branch-creation base are those of the MAIN working tree (first entry of "git
# worktree list"), so running from inside a task worktree still reports the main tree's branch.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0  success (also: exists = yes; clear with nothing to clear; get falling back to the real branch)
#   1  the answer is "no": exists = no; get --perceived with no valid perceived branch; get with a detached
#      HEAD and nothing set
#   2  usage error, malformed session key, or an invalid branch name given to set
#   3  git problem: not inside a git repository, or the branch could not be created
#   5  state problem: the queue directory could not be resolved, jq is missing, or the state file could not be
#      written or removed
#   7  no session key could be resolved (set only; get and clear degrade as described above)
#
# Environment: JENGA_CHECKLIST_SESSION_ID, CLAUDE_CODE_SESSION_ID, JENGA_SESSION_ID (see SESSION KEY) and
# JENGA_PROJECT_ROOT (honoured by resolve-root.sh).
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions).
# ---------------------------------------------------------------------------

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_SUBDIR="perceived-branch"
SESSION_KEY_PATTERN='^[A-Za-z0-9][A-Za-z0-9._-]*$'
SESSION_KEY_MAX=128

err() { printf 'perceived-branch: %s\n' "$*" >&2; }
note() { printf 'perceived-branch: note: %s\n' "$*" >&2; }
die() {
  local code="$1"
  shift
  err "$*"
  exit "$code"
}

usage() {
  # Prints the USAGE block of the header above, without the leading "# ".
  sed -n '/^# USAGE$/,/^# SESSION KEY/{
    /^# ---/d
    /^# USAGE$/d
    /^# SESSION KEY/d
    s/^# \{0,1\}//
    p
  }' "${BASH_SOURCE[0]}"
}

# ---------------------------------------------------------------------------
# Resolution helpers
# ---------------------------------------------------------------------------

# Sets SESSION_KEY from the probe order. $1 is an explicit --session value ("" for none).
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
  SESSION_KEY=""
  if [ -z "$key" ]; then
    return 7
  fi
  case "$key" in
    *..*)
      err "bad session key: must not contain \"..\""
      return 2
      ;;
  esac
  if [ "${#key}" -gt "$SESSION_KEY_MAX" ] || ! [[ "$key" =~ $SESSION_KEY_PATTERN ]]; then
    err "bad session key: 1 to $SESSION_KEY_MAX characters of letters, digits, dot, underscore or hyphen, starting with a letter or digit (no path separators)"
    return 2
  fi
  SESSION_KEY="$key"
  return 0
}

# Sets STATE_DIR. Returns 5 when the queue directory cannot be resolved.
resolve_state_dir() {
  local queue
  if ! queue="$(bash "$SCRIPT_DIR/resolve-root.sh" get queue 2>/dev/null)" || [ -z "$queue" ]; then
    err "could not resolve the queue directory via resolve-root.sh"
    STATE_DIR=""
    return 5
  fi
  STATE_DIR="${queue%/}/$STATE_SUBDIR"
  return 0
}

# Sets MAIN_TREE to the main working tree of the repository containing the current directory. Returns 3 when
# not inside a git repository.
resolve_main_tree() {
  local first
  MAIN_TREE=""
  first="$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
  if [ -z "$first" ]; then
    err "not inside a git repository"
    return 3
  fi
  MAIN_TREE="$first"
  return 0
}

# Prints the real checked-out branch of the main tree (empty when detached). Returns 3 outside a repository.
real_branch() {
  resolve_main_tree || return 3
  git -C "$MAIN_TREE" branch --show-current 2>/dev/null
  return 0
}

# Returns 0 when $1 is a plausible local branch name (also rejects @{-1} style expansion and a leading dash).
valid_branch_name() {
  case "$1" in
    "" | -*) return 1 ;;
  esac
  git check-ref-format "refs/heads/$1" >/dev/null 2>&1
}

# Returns 0 when local branch $1 exists in the main tree's repository.
branch_exists() {
  valid_branch_name "$1" || return 1
  git show-ref --verify --quiet "refs/heads/$1" 2>/dev/null
}

# Reads this session's perceived branch from $1 (the state file) for key $2. Prints the branch and returns 0,
# or prints nothing and returns 1 when the file is absent, unreadable, or belongs to another key.
read_state_branch() {
  local file="$1" key="$2" stored branch
  [ -f "$file" ] || return 1
  if ! command -v jq >/dev/null 2>&1; then
    err "jq is required to read the state file"
    return 1
  fi
  stored="$(jq -r '.session_id // empty' "$file" 2>/dev/null)" || stored=""
  branch="$(jq -r '.branch // empty' "$file" 2>/dev/null)" || branch=""
  if [ "$stored" != "$key" ] || [ -z "$branch" ]; then
    note "ignoring unreadable or foreign state file for this session"
    return 1
  fi
  printf '%s\n' "$branch"
  return 0
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

# Argument parsing shared by all subcommands. Sets SESSION_ARG, MODE and POSITIONAL (one value at most).
parse_args() {
  SESSION_ARG=""
  MODE=""
  POSITIONAL=""
  local seen_positional=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --session)
        [ $# -ge 2 ] || die 2 "--session needs a value"
        SESSION_ARG="$2"
        shift 2
        ;;
      --session=*)
        SESSION_ARG="${1#--session=}"
        shift
        ;;
      --real | --perceived)
        [ -z "$MODE" ] || [ "$MODE" = "${1#--}" ] || die 2 "--real and --perceived are mutually exclusive"
        MODE="${1#--}"
        shift
        ;;
      -*)
        die 2 "unknown option: $1"
        ;;
      *)
        [ "$seen_positional" -eq 0 ] || die 2 "unexpected argument: $1"
        POSITIONAL="$1"
        seen_positional=1
        shift
        ;;
    esac
  done
}

cmd_set() {
  parse_args "$@"
  [ -n "$POSITIONAL" ] || die 2 "set needs a branch name"
  [ -z "$MODE" ] || die 2 "set does not take --$MODE"
  local branch="$POSITIONAL" status tmp file now

  resolve_session_key "$SESSION_ARG"
  status=$?
  if [ "$status" -eq 7 ]; then
    die 7 "no session key could be resolved: pass --session <key>, or set CLAUDE_CODE_SESSION_ID (or JENGA_CHECKLIST_SESSION_ID). Nothing was written and no branch was created; a perceived branch is never stored under a default key."
  elif [ "$status" -ne 0 ]; then
    exit "$status"
  fi

  valid_branch_name "$branch" || die 2 "invalid branch name: $branch"
  resolve_main_tree || exit 3
  resolve_state_dir || exit 5
  command -v jq >/dev/null 2>&1 || die 5 "jq is required to write the state file"

  if ! git -C "$MAIN_TREE" show-ref --verify --quiet "refs/heads/$branch"; then
    # Created from the main tree's currently checked-out commit; the checkout itself does not move.
    if ! git -C "$MAIN_TREE" branch "$branch" >/dev/null 2>&1; then
      die 3 "could not create branch $branch from the currently checked-out branch"
    fi
    note "created branch $branch from the currently checked-out branch"
  fi

  mkdir -p "$STATE_DIR" 2>/dev/null || die 5 "could not create state directory $STATE_DIR"
  file="$STATE_DIR/$SESSION_KEY.json"
  tmp="$(mktemp "$STATE_DIR/.tmp-XXXXXX" 2>/dev/null)" || die 5 "could not create a temporary file in $STATE_DIR"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if ! jq -n --arg s "$SESSION_KEY" --arg b "$branch" --arg t "$now" \
    '{session_id: $s, branch: $b, set_at: $t}' >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    die 5 "could not write the state file"
  fi
  if ! mv -f "$tmp" "$file" 2>/dev/null; then
    rm -f "$tmp"
    die 5 "could not move the state file into place"
  fi
  printf '%s\n' "$branch"
}

cmd_exists() {
  parse_args "$@"
  [ -n "$POSITIONAL" ] || die 2 "exists needs a branch name"
  [ -z "$MODE" ] || die 2 "exists does not take --$MODE"
  [ -z "$SESSION_ARG" ] || die 2 "exists does not take --session"
  if branch_exists "$POSITIONAL"; then
    exit 0
  fi
  exit 1
}

cmd_get() {
  parse_args "$@"
  [ -z "$POSITIONAL" ] || die 2 "get takes no branch name"
  local real status file branch

  if [ "$MODE" = "real" ]; then
    real="$(real_branch)" || exit 3
    if [ -z "$real" ]; then
      note "the main working tree has a detached HEAD; there is no real branch name"
      exit 1
    fi
    printf '%s\n' "$real"
    exit 0
  fi

  resolve_session_key "$SESSION_ARG"
  status=$?
  if [ "$status" -eq 2 ]; then
    exit 2
  fi
  branch=""
  if [ "$status" -eq 7 ]; then
    note "no session id found (pass --session or set CLAUDE_CODE_SESSION_ID); no perceived branch can be set"
  else
    resolve_state_dir || exit 5
    file="$STATE_DIR/$SESSION_KEY.json"
    if branch="$(read_state_branch "$file" "$SESSION_KEY")"; then
      if ! branch_exists "$branch"; then
        note "perceived branch $branch no longer exists; falling back to the real branch"
        branch=""
      fi
    else
      branch=""
    fi
  fi

  if [ -n "$branch" ]; then
    printf '%s\n' "$branch"
    exit 0
  fi
  if [ "$MODE" = "perceived" ]; then
    exit 1
  fi
  real="$(real_branch)" || exit 3
  if [ -z "$real" ]; then
    note "the main working tree has a detached HEAD and no perceived branch is set"
    exit 1
  fi
  printf '%s\n' "$real"
  exit 0
}

cmd_clear() {
  parse_args "$@"
  [ -z "$POSITIONAL" ] || die 2 "clear takes no branch name"
  [ -z "$MODE" ] || die 2 "clear does not take --$MODE"
  local status file
  resolve_session_key "$SESSION_ARG"
  status=$?
  if [ "$status" -eq 7 ]; then
    note "no session id found; nothing to clear"
    exit 0
  elif [ "$status" -ne 0 ]; then
    exit "$status"
  fi
  resolve_state_dir || exit 5
  file="$STATE_DIR/$SESSION_KEY.json"
  if [ -e "$file" ]; then
    rm -f "$file" 2>/dev/null || die 5 "could not remove $file"
  fi
  exit 0
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

if [ $# -eq 0 ]; then
  usage >&2
  exit 2
fi

sub="$1"
shift
case "$sub" in
  set) cmd_set "$@" ;;
  get) cmd_get "$@" ;;
  clear) cmd_clear "$@" ;;
  exists) cmd_exists "$@" ;;
  -h | --help | help)
    usage
    exit 0
    ;;
  *)
    err "unknown subcommand: $sub"
    usage >&2
    exit 2
    ;;
esac
