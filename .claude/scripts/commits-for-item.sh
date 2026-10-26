#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/commits-for-item.sh - the shared "which commits belong to this board item" resolver
# (epic E79, story E79_S02, task E79_S02_T01)
#
# One place that turns a board id into a commit set. Until now every consumer ran its own `git log --grep`
# (the audit in project/documentation/commit-consumer-audit.md lists them as M1 to M11, with `commits_for_ticket`
# copied four times). Later tasks (E79_S02_T04 to T07) migrate those consumers onto this script; this task only
# provides it. It changes no consumer and no board file: it is read-only and prints SHAs.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   commits-for-item.sh <id> [--require-nonempty] [--repo <dir>]
#   commits-for-item.sh -h | --help          print this usage on stdout, exit 0
#
#   <id>                 an epic (E##), story (E##_S##) or task (E##_S##_T##) id. Any other shape is a usage
#                        error (exit 2) raised before any git command runs.
#   --require-nonempty   an empty result is an error: exit non-zero and print a message naming the id on stderr.
#                        Without the flag an empty result exits 0 and prints nothing (today's behaviour).
#   --repo <dir>         resolve against the git repository containing <dir> (default: the current directory),
#                        the same as the consumers' existing `git -C "$REPO_ROOT"`.
#
# Flags and the id may appear in any order. Output: one full commit SHA per line, newest first (git's own
# `git log` order), nothing else on stdout.
#
# ---------------------------------------------------------------------------
# WHAT COUNTS AS "A COMMIT FOR <id>"  (three forms, always, whatever the project's configuration says)
# ---------------------------------------------------------------------------
#   1. EST form and anything else that names the id. The id appears anywhere in the commit message (subject or
#      body): `task(E51_S02_T01): ...`, `chore(E51_S02_T01): add rapport ...`, `story(E51_S02): ...`,
#      `merge: E51_S02_T01-slug into ...`. This is exactly the call the four anchored consumers make today,
#      so EST-only history resolves identically (E79_S02_T02 is the differential proof).
#   2. A `Jenga-Task: <id>` trailer. Read with git's own trailer parser (`%(trailers:key=Jenga-Task,...)`), so
#      several trailers in one block, the key in any letter case, and a value listing several ids separated by
#      spaces, commas or semicolons are all handled. A commit is attributed when one value equals <id> exactly.
#   3. A template-form subject (`{ref} {summary}`, for example `ASD-001 add retry`) is NEVER matched by its ref:
#      the ref is a display label (often shared by many tasks), not a trace key. Such a commit resolves only
#      through its `Jenga-Task:` trailer. A template-form commit with no trailer is not attributable and is not
#      guessed at; it is simply absent from the output (see --require-nonempty for how a consumer finds out).
#
# Because the forms are always all recognised, mixed history (EST commits and template commits interleaved, before
# or after opting in or out) needs no configuration lookup. The resolver reads history, not config.
#
# ---------------------------------------------------------------------------
# ID ANCHORING
# ---------------------------------------------------------------------------
#   The id must not be followed by a digit or an underscore: the pattern is `<id>([^0-9_]|$)` (extended regex),
#   the same anchor mark-merged.sh, check-privatized.sh, mark-publicized.sh and mark-deployed.sh already use.
#   So `E51_S02` does not match `E51_S02_T01`, and `E51_S02_T01` does not match `E51_S02_T010`. The left side is
#   deliberately not anchored (as in those scripts), to keep EST-only history byte-identical to today.
#   Consequence: an epic or story query returns the commits that name that epic or story itself; it does not
#   return commits that only name one of its child tasks. (extract-diff-stats.sh, audit row M2, is unanchored on
#   purpose and so behaves differently; its migration, E79_S02_T04, decides how to handle that.)
#   The id is validated against ^E[0-9]+(_S[0-9]+(_T[0-9]+)?)?$ first, so it only ever holds [A-Z0-9_]; it is
#   handed to git as an argument and to awk through -v, never interpolated into a shell string.
#
# ---------------------------------------------------------------------------
# REVISION AND MERGE SEMANTICS  (--all --no-merges, kept on purpose)
# ---------------------------------------------------------------------------
#   Every pass uses `git log --all --no-merges`, as every current consumer does:
#     --all         every ref, so work on a task branch or worktree branch that is not yet merged is found, and
#                   a story-close or reconcile run sees commits made on a sibling worktree. The cost, recorded in
#                   the audit (section 6): cherry-picks (`[pick <sha>]` copies) are counted as separate commits,
#                   and every local worktree branch counts. This script reproduces that, it does not "fix" it.
#     --no-merges   merge commits carry no diff of their own and would double-count the work they merge.
#   Changing either is a behaviour change for the consumers and belongs to a later, explicit decision.
#
# ---------------------------------------------------------------------------
# EXIT STATUS
# ---------------------------------------------------------------------------
#   0   success (including an empty result, unless --require-nonempty was given)
#   1   --require-nonempty and no commit carries <id>
#   2   usage error: unknown flag, missing or extra argument, missing --repo value, malformed id
#   3   --require-nonempty, no commit found, AND the repository is shallow: "history unavailable", which is a
#       different condition from "no commit carries this task" (commit-traceability-contract.md, section 6)
#   4   git failure: not a git repository, or a git command failed
#   All diagnostics go to stderr. Every message names the id where one is known.
#
# ---------------------------------------------------------------------------
# PORTABILITY
# ---------------------------------------------------------------------------
#   macOS bash 3.2 (no associative arrays, no mapfile, no ${var,,}), POSIX awk, git >= 2.24 (for
#   `%(trailers:valueonly)`), no jq. Runs from any directory; temp files live in one mktemp directory that is
#   removed on every exit path.
# ---------------------------------------------------------------------------

set -u

PROG="commits-for-item.sh"

usage() {
  cat <<'EOF'
Usage: commits-for-item.sh <id> [--require-nonempty] [--repo <dir>]
       commits-for-item.sh -h | --help

  <id>                E##, E##_S## or E##_S##_T##
  --require-nonempty  exit non-zero (message names the id) when no commit is found
  --repo <dir>        resolve in the git repository containing <dir> (default: current directory)

Prints one commit SHA per line, newest first. Exit: 0 ok, 1 empty (--require-nonempty),
2 usage, 3 empty in a shallow clone (--require-nonempty), 4 git failure.
EOF
}

die_usage() {
  printf '%s: %s\n' "$PROG" "$1" >&2
  printf "Try '%s --help' for usage.\n" "$PROG" >&2
  exit 2
}

ID=""
REQUIRE_NONEMPTY=0
REPO="."

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --require-nonempty)
      REQUIRE_NONEMPTY=1
      shift
      ;;
    --repo)
      [ $# -ge 2 ] || die_usage "--repo needs a directory"
      REPO="$2"
      shift 2
      ;;
    --repo=*)
      REPO="${1#--repo=}"
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      die_usage "unknown option: $1"
      ;;
    *)
      [ -z "$ID" ] || die_usage "more than one id given ('$ID' and '$1')"
      ID="$1"
      shift
      ;;
  esac
done

# Anything left after `--` is a positional id.
while [ $# -gt 0 ]; do
  [ -z "$ID" ] || die_usage "more than one id given ('$ID' and '$1')"
  ID="$1"
  shift
done

[ -n "$ID" ] || die_usage "missing <id> (an epic E##, story E##_S## or task E##_S##_T## id)"
[ -n "$REPO" ] || die_usage "--repo needs a directory"

# Validate before any git command runs. The match is case-sensitive and whole-string, so the validated id can only
# hold [A-Z0-9_] and cannot be mistaken for a git option or carry shell or regex metacharacters.
if ! printf '%s\n' "$ID" | grep -Eq '^E[0-9]+(_S[0-9]+(_T[0-9]+)?)?$'; then
  die_usage "malformed id '$ID': expected E##, E##_S## or E##_S##_T##"
fi

if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  printf '%s: not a git repository: %s (resolving %s)\n' "$PROG" "$REPO" "$ID" >&2
  exit 4
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/commits-for-item.XXXXXX")" || {
  printf '%s: cannot create a temporary directory (resolving %s)\n' "$PROG" "$ID" >&2
  exit 4
}
trap 'rm -rf "$TMP"' EXIT
trap 'exit 4' HUP INT TERM

# Pass A: the id anywhere in the message (EST form, and the text of a trailer too).
if ! git -C "$REPO" log --all --no-merges --extended-regexp \
      --grep="${ID}([^0-9_]|\$)" --pretty=format:'%H' >"$TMP/a" 2>"$TMP/a.err"; then
  printf '%s: git log failed while resolving %s: %s\n' "$PROG" "$ID" "$(tr '\n' ' ' <"$TMP/a.err")" >&2
  exit 4
fi

# Pass B: walk the same revisions in git's order, carrying each commit's Jenga-Task trailer values. TAB separates
# the sha from the values (one TAB per trailer); nothing in a validated trailer value contains a TAB.
if ! git -C "$REPO" log --all --no-merges \
      --pretty=format:'%H%x09%(trailers:key=Jenga-Task,valueonly,unfold,separator=%x09)' \
      >"$TMP/walk" 2>"$TMP/walk.err"; then
  printf '%s: git log failed while resolving %s: %s\n' "$PROG" "$ID" "$(tr '\n' ' ' <"$TMP/walk.err")" >&2
  exit 4
fi

# Union in walk order: a commit is kept when pass A found it, or when one of its trailer values names <id> exactly.
# FILENAME (not NR==FNR) selects the first file, because pass A's file is empty for a trailer-only history.
awk -F'\t' -v id="$ID" -v afile="$TMP/a" '
  FILENAME == afile { if ($1 != "") hit[$1] = 1; next }
  $1 == "" { next }
  {
    if ($1 in hit) { print $1; next }
    for (i = 2; i <= NF; i++) {
      n = split($i, tok, /[ ,;]+/)
      for (j = 1; j <= n; j++) {
        if (tok[j] == id) { print $1; next }
      }
    }
  }
' "$TMP/a" "$TMP/walk" >"$TMP/out" || {
  printf '%s: internal error while filtering commits for %s\n' "$PROG" "$ID" >&2
  exit 4
}

if [ ! -s "$TMP/out" ]; then
  if [ "$REQUIRE_NONEMPTY" -eq 1 ]; then
    if [ "$(git -C "$REPO" rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
      printf '%s: no commit found for %s: history unavailable (shallow clone), so this is not proof that no commit carries it\n' \
        "$PROG" "$ID" >&2
      exit 3
    fi
    printf '%s: no commit carries %s (no EST-form message and no Jenga-Task trailer names it)\n' "$PROG" "$ID" >&2
    exit 1
  fi
  exit 0
fi

cat "$TMP/out"
exit 0
