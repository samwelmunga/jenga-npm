#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/resolve-commit-ref.sh - walk the commit ref resolution chain for one task and report what it found
# (epic E79, story E79_S04, task E79_S04_T06; solution assessment Problems 8, 9 and 10)
#
# An opted-in project puts a tracker key (for example ASD-001) into the commit messages of board work. The key can come
# from the board (the `external_refs` Jira key of the task, its story or its epic) or from the user's perceived branch,
# captured when the task worktree was created. Jenga task branches are named E##_S##_T##-slug and carry no key, so the
# branch level reads the CAPTURED candidate, never the task's own branch name.
#
# This script only COLLECTS and REPORTS. It does not freeze the winner (scripts/task-commit-ref.sh does, driven by a later
# task), it applies the disagreement policy (--on-conflict, below; the settled default is warn: report once and continue
# with the precedence winner), and it does not decide what an empty result means for the run (a later task applies the
# unresolved-ref policy). It returns a distinct exit code for each of those situations so those tasks can build on it. It writes no file apart from one throw-away temp file for the
# notices of the board reader, never touches the board, the store or git, and never changes config.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   resolve-commit-ref.sh <task-id> [--conventions <file>] [--on-conflict warn|fail]
#   resolve-commit-ref.sh -h | --help            print this usage on stdout, exit 0
#
#   <task-id>             E##_S##_T##. Anything else is a usage error (exit 2).
#   --conventions <file>  handed to scripts/commit-settings.sh unchanged (tests, and callers that hold the path). It
#                         decides opt-in, ref_source and the effective ref_pattern. The story/epic readers and the
#                         per-task store do not take it: the store re-validates the captured branch candidate with the
#                         pattern the project recorded, so ordinary callers omit --conventions.
#   --on-conflict <p>     what to do when valid candidates carry different keys (see DISAGREEMENT below): warn or fail.
#                         Without the flag the policy is DEFAULT_ON_CONFLICT, the one named constant in this script. It is a
#                         flag and not a conventions.json setting on purpose: a new schema field would change the validator's
#                         allowed-key text and regenerate legacy goldens.
#
# ---------------------------------------------------------------------------
# THE CHAIN
# ---------------------------------------------------------------------------
#   1. Settings. `commit-settings.sh show` is read first. A project that is not opted in (no conventions.json, no
#      template, or apply_to_board_commits not true) prints NOTHING and exits 10, before any board path is resolved and
#      before any board file is opened: the legacy path is untouched.
#   2. ref_source picks the levels, in this fixed order:
#        chain             task, story, epic, branch        (the schema default)
#        external_refs     task, story, epic                (a captured branch candidate is ignored)
#        perceived_branch  branch                           (board external_refs are ignored; the board is not opened)
#      `prompt` is reserved by the schema and cannot reach this script; an unknown value is exit 3.
#   3. task, story, epic: `scripts/read-external-refs.sh <item-id> --system jira`. The story and epic ids come from the
#      task id and from the task file's own story_id / epic_id frontmatter (the frontmatter wins when it is well formed).
#      A task whose file or parents are missing does not fail the chain: that level is empty and a notice names it.
#      Decision 7: a Jira key identifies one imported board item at any level, so a task inherits the key of its story or
#      epic and several tasks can share one key.
#   4. branch: `scripts/task-commit-ref.sh get <task-id> --field candidate`. No candidate captured is just an empty level.
#   5. EVERY candidate goes through `scripts/commit-ref.sh validate --pattern <effective ref_pattern>` (stdin only, never
#      a command string). A candidate that fails (for example a key over the length cap, or one the project's pattern does
#      not match) is not a candidate: the chain moves on and a notice on stderr names the level, never the value.
#   6. All applicable levels are always consulted, so a disagreement can be seen. The winner is the first level,
#      in the fixed order above, that produced a valid candidate (decision 8: task, story, epic, then the branch key). If a
#      level lists several valid keys, the first in file order is its candidate and a notice says so.
#
# OUTPUT (stdout; key=value lines, read with `read` or jq and NEVER sourced; a value never holds a newline)
#   ref=<winner>                          only when a winner exists
#   source=task|story|epic|branch         only when a winner exists
#   tried=<comma list of the levels consulted, in order>      always, e.g. tried=task,story,epic,branch
#   candidate.<level>=<value>             one line per level that produced a valid candidate
#   conflict=<level>:<key>                one line per valid key that differs from the winner (policy warn, only on a
#                                         disagreement); several lines are in the fixed level order, then file order. A
#                                         caller passes each one to `task-commit-ref.sh freeze --conflict <text>`.
# When no level produced a candidate, stdout is the single line tried=... and the exit status is 1.
# Under --on-conflict fail and a disagreement stdout is tried=... plus one conflict=<level>:<key> line for EVERY valid key
# (the winner's too, since there is no winner), and ref= and source= are not printed.
# The not-applicable outcome (exit 10) prints nothing on stdout.
#
# STDERR (notices only; nothing here is parsed by a caller)
#   * a level that could not be read, or whose candidate was rejected, is named;
#   * a disagreement between valid candidates, under warn: ONE line per invocation, `warning: the sources disagree
#     (task=ASD-001, epic=ASD-002); continuing with ASD-001 from task`. The values have passed the allowlist of the safety
#     gate. The exit status stays 0. Under fail the line is `conflict: the sources disagree (...); --on-conflict fail
#     chose no ref` and the exit status is 7;
#   * no candidate at all: one line naming the levels tried.
#
# EXIT CODES
#   0   a winner exists (ref=, source=, tried= and the candidate lines are on stdout)
#   1   no level produced a valid candidate ("unresolved"); only tried= is on stdout
#   2   usage error (unknown option, a missing value, a task id that is not E##_S##_T##)
#   3   the settings cannot be used: an invalid or unreadable conventions file, an unknown ref_source, or a ref pattern the
#       safety gate cannot use (message on stderr)
#   5   a dependency is unavailable: a sibling script is missing or failed in a way that is not a verdict
#   7   a disagreement under --on-conflict fail: no winner is printed, every disagreeing level and key is named (never
#       returned by the default policy warn). A distinct code on purpose: 5 already means "dependency unavailable".
#   10  not applicable: the project is not opted in to the commit template; stdout is empty and no board file was opened
# Exit 10 is deliberately not 0 and not 1, so a caller can tell "not opted in" from "found" and from "nothing found".
#
# ---------------------------------------------------------------------------
# DISAGREEMENT (epic E79 decisions 7 and 8; solution assessment Problem 9: reported once, at resolution time)
# ---------------------------------------------------------------------------
# A conflict is any two VALID keys with different values among everything the consulted levels produced, including several
# different Jira entries on one level (that level then disagrees with itself). The rule, pinned by decision 7:
#   * A key identifies one imported board item, and a story or epic key is inherited by every task beneath it, so an
#     inherited key is never a conflict: a task with no key of its own that takes its story's key simply has one candidate.
#   * A conflict arises only when two levels were linked separately and carry different keys.
#   * Precedence is fixed (decision 8): task, story, epic, branch. The winner is the first level with a valid key.
#   * Under warn (the default) a difference never fails the run, in particular not a task key against a different story or
#     epic key while the task level wins: the run warns once on stderr and continues with the winner (exit 0).
#   * Under fail ANY difference stops the run with exit 7 and no winner.
# Invalid keys never take part (they are not candidates). The policy is read in exactly one place, the end of the chain.
#
# ENVIRONMENT
#   JENGA_PROJECT_ROOT redirects the board, the configs and the store to a scratch project (tests, callers holding a root).
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile, case-modifying expansions or `&>>`). It has no
# dynamic-execution builtin, no shell-string invocation and no file inclusion (a bats case greps for them), and uses neither
# jq nor yq itself.
# ---------------------------------------------------------------------------

set -u
export LC_ALL=C

PROG="resolve-commit-ref"
# The disagreement policy used when --on-conflict is not given (warn or fail). The only place the default is set.
DEFAULT_ON_CONFLICT="warn"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$here/commit-settings.sh"
GATE="$here/commit-ref.sh"
READER="$here/read-external-refs.sh"
STORE="$here/task-commit-ref.sh"
RESOLVER="$here/resolve-root.sh"

ERRF=""
trap 'if [ -n "$ERRF" ]; then rm -f "$ERRF"; fi' EXIT

usage() {
  cat <<'EOF'
Usage:
  resolve-commit-ref.sh <task-id> [--conventions <file>] [--on-conflict warn|fail]
  resolve-commit-ref.sh -h | --help

Prints key=value lines (ref, source, tried, candidate.<level>, conflict) and exits 0 when a ref was found.
--on-conflict: what to do when the levels carry different keys; warn (the default) continues with the precedence winner,
fail stops with exit 7 and no winner.
Exit codes: 0 found, 1 nothing found, 2 usage error, 3 settings unusable, 5 dependency unavailable,
7 disagreement under --on-conflict fail, 10 not applicable (the project is not opted in; nothing is printed).
See the header of this script for the contract.
EOF
}

die_usage() {
  printf '%s: usage error: %s\n' "$PROG" "$1" >&2
  printf "Try '%s --help'.\n" "$PROG" >&2
  exit 2
}

fail() { # fail <exit-code> <message>
  printf '%s: %s\n' "$PROG" "$2" >&2
  exit "$1"
}

notice() {
  printf '%s: %s\n' "$PROG" "$1" >&2
}

# --- arguments -------------------------------------------------------------------------------------------------

ID=""
CONV=""
GOT_CONV=0
POLICY="$DEFAULT_ON_CONFLICT"
GOT_POLICY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --conventions)
      [ "$#" -ge 2 ] || die_usage "--conventions needs a value"
      [ "$GOT_CONV" -eq 0 ] || die_usage "--conventions given twice"
      GOT_CONV=1
      CONV="$2"
      shift 2
      ;;
    --on-conflict)
      [ "$#" -ge 2 ] || die_usage "--on-conflict needs a value (warn or fail)"
      [ "$GOT_POLICY" -eq 0 ] || die_usage "--on-conflict given twice"
      GOT_POLICY=1
      case "$2" in
        warn|fail) POLICY="$2" ;;
        *) die_usage "--on-conflict must be warn or fail" ;;
      esac
      shift 2
      ;;
    -*)
      flag="${1%%=*}"
      die_usage "unknown option $flag"
      ;;
    *)
      [ -z "$ID" ] || die_usage "only one task id may be given"
      ID="$1"
      shift
      ;;
  esac
done

[ -n "$ID" ] || die_usage "a task id (E##_S##_T##) is required"
# The id becomes part of a path glob and is handed to other scripts: only A-Za-z0-9_ is allowed through, then the shape.
case "$ID" in
  *[!A-Za-z0-9_]*) die_usage "the task id must look like E##_S##_T##" ;;
esac
TASK_RE='^E[0-9]+_S[0-9]+_T[0-9]+$'
STORY_RE='^E[0-9]+_S[0-9]+$'
EPIC_RE='^E[0-9]+$'
[[ "$ID" =~ $TASK_RE ]] || die_usage "the task id must look like E##_S##_T##"

for dep in "$SETTINGS" "$GATE" "$READER" "$STORE" "$RESOLVER"; do
  [ -f "$dep" ] || fail 5 "a required script is missing: $(basename "$dep")"
done

# --- step 1: settings and the opt-in gate (no board access before this point is passed) ------------------------------

if [ -n "$CONV" ]; then
  SHOW="$(bash "$SETTINGS" --conventions "$CONV" show)"
else
  SHOW="$(bash "$SETTINGS" show)"
fi
SRC=$?
case "$SRC" in
  0) ;;
  3) fail 3 "the commit settings cannot be used (see the message above)" ;;
  *) fail 5 "commit-settings.sh failed unexpectedly (exit $SRC)" ;;
esac
if [ -z "$SHOW" ]; then
  exit 10
fi

REF_SOURCE=""
PATTERN=""
while IFS= read -r line; do
  case "$line" in
    ref_source=*) REF_SOURCE="${line#ref_source=}" ;;
    ref_pattern=*) PATTERN="${line#ref_pattern=}" ;;
  esac
done <<EOF_SHOW
$SHOW
EOF_SHOW
[ -n "$REF_SOURCE" ] || fail 3 "the effective settings hold no ref_source"
[ -n "$PATTERN" ] || fail 3 "the effective settings hold no ref_pattern"

case "$REF_SOURCE" in
  chain) LEVELS="task story epic branch" ;;
  external_refs) LEVELS="task story epic" ;;
  perceived_branch) LEVELS="branch" ;;
  *) fail 3 "ref_source is not one the resolver can use (expected chain, external_refs or perceived_branch)" ;;
esac

# --- helpers ---------------------------------------------------------------------------------------------------

# gate <value>: send one candidate through the safety gate, on stdin. Sets GATED and returns 0 when it passes, returns 1
# when it is rejected. A pattern the gate cannot use stops the run: it is a settings problem, not a verdict on a candidate.
GATED=""
gate() {
  local rc
  GATED="$(printf '%s' "$1" | bash "$GATE" validate --pattern "$PATTERN" 2>/dev/null)"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    3) return 1 ;;
    4) fail 3 "the ref pattern cannot be used by the commit ref gate" ;;
    *) fail 5 "commit-ref.sh failed unexpectedly (exit $rc)" ;;
  esac
}

# --- the story and epic ids ------------------------------------------------------------------------------------

STORY_ID="${ID%_T*}"
EPIC_ID="${ID%%_S*}"

case "$REF_SOURCE" in
  perceived_branch) ;;
  *)
    # Prefer the task file's own parents. Only well-formed values are used; anything else leaves the derived ids alone.
    TASK_DIR="$(bash "$RESOLVER" get tasks 2>/dev/null)" || TASK_DIR=""
    if [ -n "$TASK_DIR" ] && [ -d "$TASK_DIR" ]; then
      TASK_FILE=""
      count=0
      for f in "$TASK_DIR/${ID}"_*.md "$TASK_DIR/${ID}.md"; do
        if [ -f "$f" ]; then
          TASK_FILE="$f"
          count=$((count + 1))
        fi
      done
      if [ "$count" -eq 1 ]; then
        case "$TASK_FILE" in
          /*) ;;
          *) TASK_FILE="./$TASK_FILE" ;;
        esac
        PARENTS="$(awk '
          function clean(v) {
            sub(/[ \t]+#.*$/, "", v)
            gsub(/^[ \t]+/, "", v)
            gsub(/[ \t]+$/, "", v)
            gsub(/^["\047]+/, "", v)
            gsub(/["\047]+$/, "", v)
            return v
          }
          { sub(/\r$/, "") }
          NR == 1 { if ($0 !~ /^---[ \t]*$/) exit; next }
          /^---[ \t]*$/ { exit }
          /^story_id:/ { if (!s) { s = 1; print "S " clean(substr($0, 10)) } }
          /^epic_id:/ { if (!e) { e = 1; print "E " clean(substr($0, 9)) } }
        ' "$TASK_FILE" 2>/dev/null)" || PARENTS=""
        while IFS= read -r line; do
          case "$line" in
            "S "*)
              v="${line#S }"
              if [[ "$v" =~ $STORY_RE ]]; then STORY_ID="$v"; fi
              ;;
            "E "*)
              v="${line#E }"
              if [[ "$v" =~ $EPIC_RE ]]; then EPIC_ID="$v"; fi
              ;;
          esac
        done <<EOF_PARENTS
$PARENTS
EOF_PARENTS
      fi
    fi
    ;;
esac

# --- steps 3 to 5: consult every applicable level ----------------------------------------------------------------

TRIED=""
WIN=""
WIN_SRC=""
CAND_TASK=""
CAND_STORY=""
CAND_EPIC=""
CAND_BRANCH=""
CAND=""
EXTRA=""
EX_TASK=""
EX_STORY=""
EX_EPIC=""

# consult_board <level> <item-id>: leaves the level's candidate (or nothing) in CAND, and the further DIFFERENT valid keys of
# the same level (a level that lists several Jira entries disagrees with itself) one per line in EXTRA.
consult_board() {
  local lvl="$1" item="$2" keys rc k n valid first
  CAND=""
  EXTRA=""
  if [ -z "$ERRF" ]; then
    ERRF="$(mktemp "${TMPDIR:-/tmp}/resolve-commit-ref.XXXXXX")" || fail 5 "cannot create a temporary file"
  fi
  : > "$ERRF"
  keys="$(bash "$READER" "$item" --system jira 2>"$ERRF")"
  rc=$?
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    notice "$lvl: $k"
  done < "$ERRF"
  if [ "$rc" -ne 0 ]; then
    notice "the $lvl level could not be read (read-external-refs exit $rc); it holds no candidate"
    return 0
  fi
  n=0
  first=""
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    if gate "$k"; then
      valid="$GATED"
      if [ -z "$first" ]; then
        first="$valid"
      elif [ "$valid" != "$first" ]; then
        n=$((n + 1))
        case "
$EXTRA
" in
          *"
$valid
"*) ;;
          *) EXTRA="${EXTRA:+$EXTRA
}$valid" ;;
        esac
      fi
    else
      notice "the $lvl candidate was rejected by the commit ref gate (length, allowed characters or the ref pattern); skipped"
    fi
  done <<EOF_KEYS
$keys
EOF_KEYS
  if [ "$n" -gt 0 ]; then
    notice "the $lvl level lists more than one valid key; the first one is used"
  fi
  CAND="$first"
}

# consult_branch: the candidate captured at worktree creation (never the task branch's own name).
consult_branch() {
  local out rc
  CAND=""
  out="$(bash "$STORE" get "$ID" --field candidate)"
  rc=$?
  case "$rc" in
    0)
      if gate "$out"; then
        CAND="$GATED"
      else
        notice "the branch candidate was rejected by the commit ref gate (length, allowed characters or the ref pattern); skipped"
      fi
      ;;
    1) ;;
    *) notice "the captured branch candidate could not be read (task-commit-ref exit $rc); it holds no candidate" ;;
  esac
}

for lvl in $LEVELS; do
  TRIED="${TRIED:+$TRIED,}$lvl"
  CAND=""
  EXTRA=""
  case "$lvl" in
    task) consult_board task "$ID" ;;
    story) consult_board story "$STORY_ID" ;;
    epic) consult_board epic "$EPIC_ID" ;;
    branch) consult_branch ;;
  esac
  if [ -n "$CAND" ]; then
    case "$lvl" in
      task) CAND_TASK="$CAND" ;;
      story) CAND_STORY="$CAND" ;;
      epic) CAND_EPIC="$CAND" ;;
      branch) CAND_BRANCH="$CAND" ;;
    esac
    if [ -z "$WIN" ]; then
      WIN="$CAND"
      WIN_SRC="$lvl"
    fi
  fi
  case "$lvl" in
    task) EX_TASK="$EXTRA" ;;
    story) EX_STORY="$EXTRA" ;;
    epic) EX_EPIC="$EXTRA" ;;
  esac
done

# --- step 6: report --------------------------------------------------------------------------------------------------

if [ -z "$WIN" ]; then
  notice "no valid commit ref was found (levels tried: $TRIED)"
  printf 'tried=%s\n' "$TRIED"
  exit 1
fi

# The disagreement. See DISAGREEMENT in the header: any two valid keys with different values are a conflict, whatever the
# policy; the policy only decides what happens next. ALL = every valid level:key pair (for the warning text and for the
# fail output), CONFLICTS = the pairs whose key differs from the winner (the conflict= lines of the warn output). Both are
# built in the fixed level order, a level's own candidate first, then its further different keys. The values passed the gate.
ALL=""
CONFLICTS=""
for lvl in task story epic branch; do
  case "$lvl" in
    task) v="$CAND_TASK"; xs="$EX_TASK" ;;
    story) v="$CAND_STORY"; xs="$EX_STORY" ;;
    epic) v="$CAND_EPIC"; xs="$EX_EPIC" ;;
    branch) v="$CAND_BRANCH"; xs="" ;;
  esac
  [ -n "$v" ] || continue
  ALL="${ALL:+$ALL
}$lvl:$v"
  if [ "$v" != "$WIN" ]; then
    CONFLICTS="${CONFLICTS:+$CONFLICTS
}$lvl:$v"
  fi
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    ALL="$ALL
$lvl:$x"
    if [ "$x" != "$WIN" ]; then
      CONFLICTS="${CONFLICTS:+$CONFLICTS
}$lvl:$x"
    fi
  done <<EOF_XS
$xs
EOF_XS
done

# DIS: the human-readable form, level=key joined by ", ".
DIS=""
while IFS= read -r pair; do
  [ -n "$pair" ] || continue
  DIS="${DIS:+$DIS, }${pair%%:*}=${pair#*:}"
done <<EOF_ALL
$ALL
EOF_ALL

# THE ONE PLACE THE POLICY IS DECIDED. No conflict: both policies behave identically.
if [ -n "$CONFLICTS" ]; then
  case "$POLICY" in
    fail)
      printf 'tried=%s\n' "$TRIED"
      while IFS= read -r pair; do
        [ -n "$pair" ] || continue
        printf 'conflict=%s\n' "$pair"
      done <<EOF_ALL_FAIL
$ALL
EOF_ALL_FAIL
      notice "conflict: the sources disagree ($DIS); --on-conflict fail chose no ref"
      exit 7
      ;;
    *)
      notice "warning: the sources disagree ($DIS); continuing with $WIN from $WIN_SRC"
      ;;
  esac
fi

printf 'ref=%s\n' "$WIN"
printf 'source=%s\n' "$WIN_SRC"
printf 'tried=%s\n' "$TRIED"
for lvl in task story epic branch; do
  case "$lvl" in
    task) v="$CAND_TASK" ;;
    story) v="$CAND_STORY" ;;
    epic) v="$CAND_EPIC" ;;
    branch) v="$CAND_BRANCH" ;;
  esac
  [ -z "$v" ] || printf 'candidate.%s=%s\n' "$lvl" "$v"
done
while IFS= read -r pair; do
  [ -n "$pair" ] || continue
  printf 'conflict=%s\n' "$pair"
done <<EOF_CONFLICTS
$CONFLICTS
EOF_CONFLICTS
exit 0
