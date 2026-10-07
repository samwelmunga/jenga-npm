#!/usr/bin/env bash
# commit-subject-check.sh - classify a commit subject and check it against the project's commit-format convention
# (E69_S05_T04). Used by skills/j-commit/SKILL.md, section "Project commit-format convention".
#
# Usage:
#   skills/j-commit/scripts/commit-subject-check.sh [--conventions <file>] <subject>
#
# What it decides, deterministically:
#   1. BOARD or NON-BOARD. A subject is a BOARD commit when it is EST naming: it starts with task(, story( or
#      epic(, OR its leading scope names a board id (for example chore(E69_S05_T01): ... or merge: E69_S04 ...).
#      Everything else (chore, docs, a change with no board item) is NON-BOARD.
#   2. For a BOARD subject the project's commit-format convention is NEVER applied, whatever it says (epic E69,
#      Decision 2: EST naming is mandatory for board commits, and a convention applies to non-board commits only).
#      The script reports "kind=board" and exits 0 without reading the convention at all, so a hostile
#      message_regex (one that would reject task(E01_S01_T01): x) cannot affect a board commit.
#   3. For a NON-BOARD subject it reads the recorded commit-format convention (conventions.json, via
#      scripts/resolve-root.sh get configs; JENGA_PROJECT_ROOT honoured) and checks the subject against its
#      message_regex (POSIX ERE, grep -E) and subject_max_length when recorded.
#
# stdout (one line): kind=board; ... | kind=non-board; <verdict>
# Exit codes: 0 board commit, or non-board with no applicable convention, or a conforming subject; 1 a non-board
# subject violates the recorded convention (the reason is on stdout; rewrite the subject and re-check); 2 usage.
# An absent, unreadable or invalid conventions file, an unresolvable configs path, or an unusable regex all mean
# "no applicable convention" (exit 0, a note on stderr where there is something to say): a commit is never blocked
# by a broken convention file. Read-only; writes nothing. Compatible with macOS bash 3.2. Needs jq.
#
# Note on enforcement: this is an advisory self-check the commit flow runs on a message it has already composed.
# The pre-commit checklist phase fires before any message exists and cannot test one (see
# project/documentation/project-conventions.md, "Pre-commit timing finding (E69_S05_T05)").

set -u

SELF="$(basename "$0")"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE_ROOT="$here/../../../scripts/resolve-root.sh"

conv=""
subject=""
have_subject=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --conventions)
      [ "$#" -ge 2 ] || { printf 'usage: %s [--conventions <file>] <subject>\n' "$SELF" >&2; exit 2; }
      conv="$2"
      shift 2
      ;;
    --)
      shift
      if [ "$#" -ge 1 ]; then subject="$1"; have_subject=1; shift; fi
      ;;
    -*)
      printf 'usage: %s [--conventions <file>] <subject>\n' "$SELF" >&2
      exit 2
      ;;
    *)
      if [ "$have_subject" -eq 1 ]; then printf 'usage: %s [--conventions <file>] <subject>\n' "$SELF" >&2; exit 2; fi
      subject="$1"
      have_subject=1
      shift
      ;;
  esac
done
[ "$have_subject" -eq 1 ] && [ -n "$subject" ] || { printf 'usage: %s [--conventions <file>] <subject>\n' "$SELF" >&2; exit 2; }

# --- 1. classify -----------------------------------------------------------------------------------------------

BOARD_ID='E[0-9]+(_S[0-9]+(_T[0-9]+)?)?'
if printf '%s\n' "$subject" | grep -Eq '^(task|story|epic)\('; then
  printf 'kind=board; EST naming, the project commit-format convention is not applied\n'
  exit 0
fi
# A board id token may sit anywhere in a scope ("chore(E53_S13_T02,E53_S13_T03):", "docs(E69_S05_T05-plan):") or in a
# merge subject ("merge: E69_S04 ...", "Merge branch 'E28_S18_T01-...'"); a letter or digit on either side ("E2E") is not one.
BOARD_TOKEN="(^|[^A-Za-z0-9])${BOARD_ID}([^A-Za-z0-9_]|\$)"
scope=$(printf '%s\n' "$subject" | sed -n 's/^[A-Za-z][A-Za-z]*(\([^)]*\)).*/\1/p' | head -n 1)
if { [ -n "$scope" ] && printf '%s\n' "$scope" | grep -Eq "$BOARD_TOKEN"; } \
   || printf '%s\n' "$subject" | grep -Eiq "^merge[: ]([^\"]*[^A-Za-z0-9])?${BOARD_ID}([^A-Za-z0-9_]|\$)" \
   || printf '%s\n' "$subject" | grep -Eq '^Revert "(task|story|epic)\('; then
  printf 'kind=board; names a board item, the project commit-format convention is not applied\n'
  exit 0
fi

# --- 2. non-board: find the convention -------------------------------------------------------------------------

none() { printf 'kind=non-board; %s\n' "$1"; exit 0; }

if [ -z "$conv" ]; then
  cfg="$(bash "$RESOLVE_ROOT" get configs 2>/dev/null)" || none "no applicable commit-format convention (configs path not resolved)"
  [ -n "$cfg" ] || none "no applicable commit-format convention (configs path not resolved)"
  conv="$cfg/conventions.json"
fi
[ -f "$conv" ] || none "no commit-format convention recorded"
command -v jq >/dev/null 2>&1 || none "no applicable commit-format convention (jq not found)"

if ! jq -e '.categories["commit-format"].values | type == "object"' "$conv" >/dev/null 2>&1; then
  none "no commit-format convention recorded"
fi
# A conventions file that fails validation is not trusted (nothing is applied from it).
if ! bash "$here/../../../scripts/validate-conventions.sh" "$conv" >/dev/null 2>&1; then
  printf '%s: conventions file is invalid, ignored: %s\n' "$SELF" "$conv" >&2
  none "no applicable commit-format convention (conventions file invalid)"
fi

regex="$(jq -r '.categories["commit-format"].values.message_regex // empty' "$conv")"
maxlen="$(jq -r '.categories["commit-format"].values.subject_max_length // empty' "$conv")"

# --- 3. check --------------------------------------------------------------------------------------------------

problems=""
if [ -n "$regex" ]; then
  printf '%s\n' "$subject" | grep -Eq -- "$regex"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    printf '%s: message_regex is not a valid extended regular expression, not applied\n' "$SELF" >&2
  elif [ "$rc" -ne 0 ]; then
    problems="does not match the recorded message_regex"
  fi
fi
if [ -n "$maxlen" ]; then
  case "$maxlen" in
    ''|*[!0-9]*) ;;
    *) [ "${#subject}" -le "$maxlen" ] || problems="${problems:+$problems; }subject is ${#subject} characters, over the recorded subject_max_length of $maxlen" ;;
  esac
fi

if [ -n "$problems" ]; then
  printf 'kind=non-board; violates the commit-format convention: %s\n' "$problems"
  exit 1
fi
if [ -z "$regex" ] && [ -z "$maxlen" ]; then
  none "commit-format convention recorded, nothing machine-checkable (follow its style by judgment)"
fi
printf 'kind=non-board; conforms to the commit-format convention\n'
exit 0
