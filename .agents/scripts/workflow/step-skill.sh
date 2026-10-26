#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/workflow/step-skill.sh - build the action payload for a workflow "skill" step (epic E80, task E80_S03_T04)
#
# For a `skill` step the dispatcher must hand the calling agent the skill name and the resolved instruction
# text, and an unknown skill must be a clear dispatch-time error rather than a runtime failure. Invoking the
# skill is the agent's job (a shell script cannot do it); everything before that is deterministic and lives here.
#
# This script only validates and reports. It does not execute the skill, does not read or write any workflow
# run record, and does not touch the pre-flight marker.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   step-skill.sh <skill> [input-text...]
#   step-skill.sh -h | --help       print this usage on stdout, exit 0
#
#   <skill>        a step's `skill` field: "j.<name>" (directory skills/j-<name>/), or one of the permanent
#                  bare-directory skills "jenga", "jenga-config", "jenga-permission-level" (directory
#                  skills/<name>/; their frontmatter name is "j.<name>"). The "j.<name>" spelling of those three
#                  is accepted too. The name must be lower-case letters, digits and hyphens, so a skill argument
#                  can never address a path outside the skills tree.
#   [input-text]   the step's input text; any further arguments are joined with single spaces. Empty when absent.
#
# ---------------------------------------------------------------------------
# OUTPUT (stdout, exit 0): one compact JSON object
# ---------------------------------------------------------------------------
#   {"skill":"j.<name>","skill_path":"<path to SKILL.md>","invoke_as":"j.<name>",
#    "instruction":"<input-text or empty string>","prefered_agent":"<value>" | null}
#
#   skill / invoke_as   the canonical name (the SKILL.md frontmatter `name:`); the agent invokes the skill as
#                       this name and reports the outcome through complete-step.sh
#   skill_path          the SKILL.md that was found and validated (an existing file)
#   instruction         the input text, verbatim
#   prefered_agent      metadata.prefered_agent from the frontmatter, or null when absent or empty
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   payload printed
#   1   unknown skill: the name is not a valid skill name, no directory, no SKILL.md, or the SKILL.md
#       frontmatter `name:` differs from the requested name. Nothing on stdout; stderr names the skill and every
#       location checked.
#   2   usage error (no skill given). Nothing on stdout.
#   5   jq is not available. Nothing on stdout.
#
# ---------------------------------------------------------------------------
# RESOLUTION
# ---------------------------------------------------------------------------
# The SKILL.md is looked up in these skills directories, first one that holds the file wins:
#   1. the checkout this script lives in:   <this script's directory>/../../skills
#   2. consumer install (E46 fallback):     <project anchor>/node_modules/@jenga-ai/agent/skills
# A directory that exists without a SKILL.md, or a SKILL.md with the wrong name, is rejected; the lookup does
# not fall through to the next location for those, so one broken skill directory is reported, not masked.
#
# TEST OVERRIDE
#   JENGA_PLAYBOOKS_TEST_ROOT   When set and non-empty, the locations become <root>/skills and then
#                               <root>/node_modules/@jenga-ai/agent/skills, and nothing else is consulted. It is
#                               the same variable skills/jenga/scripts/load-playbooks.sh honours. Never set it in
#                               a real invocation.
# ---------------------------------------------------------------------------
set -u

SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

err() { printf '%s\n' "$*" >&2; }

usage() {
  sed -n '/^# USAGE/,/^# OUTPUT/p' "${BASH_SOURCE[0]}" | sed -e '1d;$d' -e 's/^# \{0,1\}//' -e '/^-\{20,\}$/d'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if [ $# -lt 1 ] || [ -z "$1" ]; then
  err "Usage: step-skill.sh <skill> [input-text...]"
  exit 2
fi

SKILL="$1"
shift
INPUT=""
if [ $# -gt 0 ]; then
  INPUT="$1"
  shift
  for a in "$@"; do INPUT="$INPUT $a"; done
fi

command -v jq >/dev/null 2>&1 || { err "Error: jq is required by step-skill.sh and was not found"; exit 5; }

# --- name -> canonical name + directory name ------------------------------------------------------------
CANON=""
DIRNAME=""
case "$SKILL" in
  jenga|jenga-config|jenga-permission-level|j.jenga|j.jenga-config|j.jenga-permission-level)
    BARE="${SKILL#j.}"
    CANON="j.$BARE"
    DIRNAME="$BARE"
    ;;
  j.*)
    BARE="${SKILL#j.}"
    case "$BARE" in
      ""|-*|*[!a-z0-9-]*) ;;
      *) CANON="$SKILL"; DIRNAME="j-$BARE" ;;
    esac
    ;;
esac

if [ -z "$CANON" ]; then
  err "Error: unknown skill '$SKILL': not a valid skill name (expected j.<name> with lower-case letters, digits and hyphens, or one of jenga, jenga-config, jenga-permission-level); no skills directory was checked"
  exit 1
fi

# --- skills directories to search -------------------------------------------------------------------------
DIRS=()
if [ -n "${JENGA_PLAYBOOKS_TEST_ROOT:-}" ]; then
  ROOT="$JENGA_PLAYBOOKS_TEST_ROOT"
  while [ "$ROOT" != "/" ] && [ "${ROOT%/}" != "$ROOT" ]; do ROOT="${ROOT%/}"; done
  DIRS+=("$ROOT/skills" "$ROOT/node_modules/@jenga-ai/agent/skills")
else
  DIRS+=("$SELF_DIR/../../skills")
  ANCHOR="$(bash "$SELF_DIR/../resolve-root.sh" root 2>/dev/null)" || ANCHOR=""
  [ -n "$ANCHOR" ] && DIRS+=("${ANCHOR%/}/node_modules/@jenga-ai/agent/skills")
fi

FOUND=""
CHECKED=""
for d in "${DIRS[@]}"; do
  f="$d/$DIRNAME/SKILL.md"
  CHECKED="${CHECKED:+$CHECKED, }$f"
  if [ -f "$f" ]; then FOUND="$(CDPATH='' cd -- "$d/$DIRNAME" >/dev/null 2>&1 && pwd)/SKILL.md"; break; fi
done

if [ -z "$FOUND" ]; then
  err "Error: unknown skill '$SKILL': no SKILL.md found. Checked: $CHECKED"
  exit 1
fi

# --- frontmatter: name and metadata.prefered_agent (first --- block only) -----------------------------------
FM="$(awk '
  NR == 1 { if ($0 ~ /^---[ \t]*\r?$/) { infm = 1; next } else exit }
  infm && $0 ~ /^---[ \t]*\r?$/ { exit }
  infm { print }
' "$FOUND")"

strip_value() {
  # trims whitespace/CR and one layer of matching quotes
  local v="$1"
  v="${v%$'\r'}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  case "$v" in
    \"*\") v="${v#\"}"; v="${v%\"}" ;;
    \'*\') v="${v#\'}"; v="${v%\'}" ;;
  esac
  printf '%s' "$v"
}

NAME_LINE="$(printf '%s\n' "$FM" | grep -m1 '^name:')"
FM_NAME="$(strip_value "${NAME_LINE#name:}")"

if [ "$FM_NAME" != "$CANON" ]; then
  err "Error: unknown skill '$SKILL': $FOUND declares name '${FM_NAME:-<none>}', expected '$CANON'. Checked: $CHECKED"
  exit 1
fi

AGENT_LINE="$(printf '%s\n' "$FM" | awk '
  /^[^ \t#]/ { inmeta = ($0 ~ /^metadata:[ \t]*\r?$/) ; next }
  inmeta && $0 ~ /^[ \t]+prefered_agent:/ { print; exit }
')"
AGENT=""
if [ -n "$AGENT_LINE" ]; then
  AGENT="$(strip_value "${AGENT_LINE#*prefered_agent:}")"
fi

jq -cn \
  --arg skill "$CANON" \
  --arg path "$FOUND" \
  --arg instruction "$INPUT" \
  --arg agent "$AGENT" \
  '{skill: $skill, skill_path: $path, invoke_as: $skill, instruction: $instruction,
    prefered_agent: (if $agent == "" then null else $agent end)}'
