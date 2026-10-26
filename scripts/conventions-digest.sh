#!/usr/bin/env bash
# conventions-digest.sh - compact summary of a project's recorded conventions for agents (E69_S05_T01)
#
# The one place that turns <configs>/conventions.json into a short plain-text digest, so the developer, tester,
# scrum-master and the j-commit skill never each parse the JSON. Read-only: it writes no file.
#
# Usage:
#   scripts/conventions-digest.sh [--agent developer|tester|scrum-master|commit] [--conventions <file>]
#
# Input: the project's conventions.json (default "<configs>/conventions.json", with <configs> located through
# scripts/resolve-root.sh get configs; JENGA_PROJECT_ROOT is honoured). An explicit --conventions <file> overrides it.
# The category list and order come from templates/conventions-schema.json, located relative to this script, so the
# script works from this checkout and from node_modules/@jenga-ai/agent/.
#
# NOTHING TO SAY, NOTHING PRINTED: with no conventions.json, an unresolvable configs path, or a file whose
# `categories` is empty, the script prints nothing and exits 0 -- never an error, never a placeholder line -- so a
# caller can embed its output unconditionally. An INVALID file (scripts/validate-conventions.sh is run first) prints
# nothing on stdout, the validator's lines on stderr, and exits 1.
#
# Output (plain text, at most 30 lines; the cap is a deliberate contract, not a soft target):
#   Project conventions (<N> recorded; explicit, set through j.conventions):
#   <category-id>: <summary> [<key>=<value>; ...] (checklist item conv-<category-id>)      one line per category
#   Precedence: ...                                                                       fixed line
#   EST: ...                                                                              fixed line
#   Commit format (opt-in): ...                                                           only for an opted-in project
#   EST override: ...                                                                     only for an opted-in project
#   ... <N> more categories omitted                                                       only when truncated
# --agent only chooses which categories come FIRST (the rest follow in schema order, none are dropped except by the
# cap, which drops the lowest-priority ones and says so on the last line):
#   developer     naming, code-comments, formatting-linting, file-layout, language-tooling
#   tester        testing, formatting-linting
#   scrum-master  documentation-placement, file-layout, branching
#   commit        commit-format, branching
# With no --agent, schema order. Lines are also capped at 220 characters (longer ones end in "...").
#
# The "Precedence:" and "EST:" lines are emitted by THIS SCRIPT whenever any convention is recorded; they are not
# read from the file, so a custom commit-format convention can never remove or contradict them (epic E69, Decision
# 2: EST naming for board commits is mandatory; a commit-format convention applies to non-board commits only).
#
# OPT-IN COMMIT SETTINGS: a project that opted in to a commit-format template for board commits gets two more lines
# after the "EST:" line: the effective commit settings, and a line saying the "EST:" line above applies to projects
# without the opt-in. Whether a project is opted in, and every effective value, come from scripts/commit-settings.sh
# (called as `commit-settings.sh --conventions <file> show`); this script holds no copy of the opt-in rule or of any
# default, and prints each value as data (nothing is evaluated). A project that is not opted in (no template, the
# flag absent or false, or a trace entry on its own) gets exactly the output it always had, for every --agent value.
# The two lines are budgeted like the fixed lines, so the cap and the omission note stay correct, and each is clipped
# to the line limit like every other line. Because they must never be dropped, an opted-in project's cap has a
# minimum of 7 lines (header, Precedence, EST, the two lines, at least one category line, the omission note); a
# lower JENGA_CONVENTIONS_DIGEST_MAX_LINES is raised to 7 for that project only.
#
# A string value that is entirely one <...> token (the shipped preset's <lint command> shape) is treated as unset
# and is never printed as a recorded value, exactly as scripts/generate-convention-checklist.sh treats it.
#
# Exit codes: 0 ok (including "nothing to say"); 1 the conventions file is invalid; 2 usage error; 3 jq or python3
# (needed by the validator) is missing while there is a file to read, or the opted-in commit settings cannot be
# resolved (commit-settings.sh reports why on stderr; nothing is printed on stdout).
#
# Environment (tests): JENGA_PROJECT_ROOT; JENGA_CONVENTIONS_SCHEMA (read here and by the validator);
# JENGA_CONVENTIONS_DIGEST_MAX_LINES lowers the 30-line cap (minimum 4) so truncation can be exercised with the
# 9 shipped categories.
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions).

set -u

SELF="$(basename "$0")"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA="${JENGA_CONVENTIONS_SCHEMA:-$here/../templates/conventions-schema.json}"
MAX_LINES=30
LINE_CHARS=220

usage() {
  printf 'usage: %s [--agent developer|tester|scrum-master|commit] [--conventions <file>]\n' "$SELF" >&2
}

agent=""
conv=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      agent="$2"
      shift 2
      ;;
    --conventions)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      conv="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

case "$agent" in
  "") pref='[]' ;;
  developer) pref='["naming","code-comments","formatting-linting","file-layout","language-tooling"]' ;;
  tester) pref='["testing","formatting-linting"]' ;;
  scrum-master) pref='["documentation-placement","file-layout","branching"]' ;;
  commit) pref='["commit-format","branching"]' ;;
  *)
    printf '%s: unknown --agent value "%s" (developer, tester, scrum-master or commit)\n' "$SELF" "$agent" >&2
    exit 2
    ;;
esac

case "${JENGA_CONVENTIONS_DIGEST_MAX_LINES:-}" in
  ''|*[!0-9]*) ;;
  *) [ "$JENGA_CONVENTIONS_DIGEST_MAX_LINES" -ge 4 ] && MAX_LINES="$JENGA_CONVENTIONS_DIGEST_MAX_LINES" ;;
esac

# Locate the file. Anything that means "no conventions recorded" is a silent exit 0.
if [ -z "$conv" ]; then
  cfg="$(bash "$here/resolve-root.sh" get configs 2>/dev/null)" || exit 0
  [ -n "$cfg" ] || exit 0
  conv="$cfg/conventions.json"
fi
[ -f "$conv" ] || exit 0

command -v jq >/dev/null 2>&1 || { printf '%s: jq is required but was not found on PATH\n' "$SELF" >&2; exit 3; }

# Validate first. The validator's problem lines are the user-facing message; its PASS/FAIL line is not needed.
verr="$(bash "$here/validate-conventions.sh" "$conv" 2>&1 >/dev/null)"
vrc=$?
if [ "$vrc" -ne 0 ]; then
  [ -z "$verr" ] || printf '%s\n' "$verr" >&2
  printf '%s: conventions file is invalid, no digest produced: %s\n' "$SELF" "$conv" >&2
  [ "$vrc" -eq 3 ] && exit 3
  exit 1
fi

schema_order="$(jq -c '.categories | keys_unsorted' "$SCHEMA" 2>/dev/null)" || {
  printf '%s: cannot read the category list from %s\n' "$SELF" "$SCHEMA" >&2
  exit 1
}

# One line per recorded category, in priority order. Nothing recorded -> nothing printed.
lines="$(jq -r --argjson pref "$pref" --argjson schema "$schema_order" --argjson cap "$LINE_CHARS" '
  def isph: type == "string" and test("^\\s*<[^<>]*>\\s*$");
  def show: if type == "array" then map(tostring) | join(",") else tostring end;
  def clip: if length > $cap then .[0:($cap - 3)] + "..." else . end;
  (.categories // {}) as $c
  | ($pref + $schema | reduce .[] as $x ([]; if index($x) then . else . + [$x] end)) as $order
  | $order[] | . as $id | select($c | has($id))
  | $c[$id] as $e
  | ([ ($e.values // {}) | to_entries[] | select((.value | isph) | not) | "\(.key)=\(.value | show)" ]
      + (if $e.strength != null then ["strength=\($e.strength)"] else [] end)) as $kv
  | ($e.summary | if isph then "(no summary)" else . end) as $sum
  | ("\($id): \($sum)" + (if ($kv | length) > 0 then " [" + ($kv | join("; ")) + "]" else "" end)
     + " (checklist item conv-\($id))") | clip
' "$conv")" || { printf '%s: could not read %s\n' "$SELF" "$conv" >&2; exit 1; }

[ -n "$lines" ] || exit 0

total="$(printf '%s\n' "$lines" | wc -l | tr -d ' ')"

# Opt-in commit settings. The opt-in rule and the defaults live in commit-settings.sh; empty output means "not opted
# in" and leaves everything below exactly as it was. Resolved before anything is printed, so a failure prints no
# partial digest.
fixed=3
opt_lines=""
settings=""
# A package that lacks commit-settings.sh (a partial copy) behaves exactly as it always did: no opt-in lines.
if [ -f "$here/commit-settings.sh" ]; then
  settings="$(bash "$here/commit-settings.sh" --conventions "$conv" show)"
  src=$?
  if [ "$src" -ne 0 ]; then
    printf '%s: cannot resolve the commit settings, no digest produced: %s\n' "$SELF" "$conv" >&2
    exit 3
  fi
fi
if [ -n "$settings" ]; then
  opt_lines="$(printf '%s\n' "$settings" | jq -Rrs --arg q "'" --argjson cap "$LINE_CHARS" '
    def clip: if length > $cap then .[0:($cap - 3)] + "..." else . end;
    (split("\n") | map(select(length > 0))
      | map(. as $l | ($l | index("=")) as $i | select($i != null) | {key: $l[0:$i], value: $l[($i + 1):]})
      | from_entries) as $s
    | ("Commit format (opt-in): template \($q)\($s.template)\($q), ref_pattern \($s.ref_pattern), on_unresolved \($s.on_unresolved); board commits follow the template; trace: \($s.trace_mode) via \($q)\($s.trailer_key)\($q)" | clip),
      ("EST override: this project opted in (commit-format.apply_to_board_commits=true); the EST line above applies to projects without the opt-in." | clip)
  ')" || { printf '%s: could not format the commit settings\n' "$SELF" >&2; exit 3; }
  fixed=5
  [ "$MAX_LINES" -ge 7 ] || MAX_LINES=7
fi

# Fixed budget: header + Precedence + EST (+ the two opt-in lines). The omission note costs one more line only when
# something is dropped.
slots=$((MAX_LINES - fixed))
omitted=0
if [ "$total" -gt "$slots" ]; then
  slots=$((MAX_LINES - fixed - 1))
  omitted=$((total - slots))
fi

printf 'Project conventions (%s recorded; explicit, set through j.conventions):\n' "$total"
printf '%s\n' "$lines" | head -n "$slots"
printf '%s\n' 'Precedence: the conventions above are explicit and beat inference from the codebase; infer only for categories not listed.'
printf '%s\n' 'EST: board commits keep the mandatory task(E##_S##_T##): / story(...) / epic(...) naming; a recorded commit-format convention applies to non-board commits only.'
if [ -n "$opt_lines" ]; then
  printf '%s\n' "$opt_lines"
fi
if [ "$omitted" -gt 0 ]; then
  printf '... %s more categories omitted\n' "$omitted"
fi
exit 0
