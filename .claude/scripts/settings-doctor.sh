#!/usr/bin/env bash
# scripts/settings-doctor.sh - are the settings every shipped fragment declares actually in effect? (epic E100, task E100_S05_T01)
#
# Reads every shipped settings fragment (skills/j-*/settings-fragment.json and hooks/*.fragment.json; format in
# project/documentation/skill-authoring.md, "Settings fragments") and compares each declared requirement (a hook entry,
# an allow rule, an env key) with the effective configuration of a project.
#
# Usage: settings-doctor.sh [--fragment <id>] [--skill <j-name>] [--quiet] [--json] [--project-dir <dir>] [--home <dir>]
#        settings-doctor.sh --help
#
#   --fragment <id>    check only the fragment with that id (unknown id: exit 2)
#   --skill <j-name>   check only the fragment(s) of that skill (the owner is derived from the fragment path)
#   --quiet            print only inactive requirements
#   --json             print one JSON object per requirement instead of text lines
#   --project-dir      the project (default: $CLAUDE_PROJECT_DIR, else the git top level, else the current directory)
#   --home             the home directory (default: $HOME)
#
# Layers read, the only ones Claude Code reads that count here:
#   <project>/.claude/settings.json, <project>/.claude/settings.local.json, <home>/.claude/settings.json
# A requirement present only in <project>/.agents/settings.json or the repository-root settings.json is inactive, since
# Claude Code does not read them in a consumer. Managed settings cannot be read: reported on stderr as "not readable",
# never as inactive. A layer that is missing, unreadable or not valid JSON provides nothing and never aborts the run.
#
# Output (stdout): one line per requirement, "<fragment-id>: <requirement>: active (<layer file>)" or
# "<fragment-id>: <requirement>: inactive" followed by indented fix lines. Layer notes go to stderr.
# A hook is active when an entry under the same event has a handler command equal to the fragment's, or one containing
# the fragment's hook file name (as check-recorder-hook.sh does). An allow rule is active when the rule string is in
# permissions.allow; an env key when the key has the declared value.
#
# Exit codes: 0 every requirement active (or none declared); 1 at least one inactive (or a fragment unreadable);
#             2 usage error, unknown fragment id or skill, or jq missing.
#
# Read-only: writes no file. Needs jq. The package root is found through skills/index/scripts/package-root.sh so the
# script works in this monorepo and in a consumer install (node_modules/@jenga-ai/agent/scripts/). bash 3.2 compatible.
# smoke-invoke: --help

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

usage() { sed -n '2,/^$/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }
die2() { echo "settings-doctor: $*" >&2; exit 2; }

FRAGMENT=""; SKILL=""; QUIET=0; JSON=0; PROJECT=""; HOME_DIR="${HOME:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)     usage; exit 0 ;;
    --fragment)    [ $# -ge 2 ] || die2 "--fragment needs a value"; FRAGMENT="$2"; shift 2 ;;
    --skill)       [ $# -ge 2 ] || die2 "--skill needs a value"; SKILL="$2"; shift 2 ;;
    --project-dir) [ $# -ge 2 ] || die2 "--project-dir needs a value"; PROJECT="$2"; shift 2 ;;
    --home)        [ $# -ge 2 ] || die2 "--home needs a value"; HOME_DIR="$2"; shift 2 ;;
    --quiet)       QUIET=1; shift ;;
    --json)        JSON=1; shift ;;
    *) die2 "unknown argument '$1' (see --help)" ;;
  esac
done
command -v jq >/dev/null 2>&1 || die2 "jq is required but was not found on PATH"

# Package root (fragments live here), never the project.
if [ -f "$SCRIPT_DIR/../skills/index/scripts/package-root.sh" ]; then . "$SCRIPT_DIR/../skills/index/scripts/package-root.sh" 2>/dev/null || true; fi
PACKAGE_ROOT=""
if command -v jenga_package_root >/dev/null 2>&1; then
  PACKAGE_ROOT="$(jenga_package_root "$SCRIPT_DIR/../skills/index/scripts" 2>/dev/null)" || true
fi
[ -n "$PACKAGE_ROOT" ] || PACKAGE_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

[ -n "$PROJECT" ] || PROJECT="${CLAUDE_PROJECT_DIR:-}"
[ -n "$PROJECT" ] || PROJECT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

ALL=()
for f in "$PACKAGE_ROOT"/skills/j-*/settings-fragment.json "$PACKAGE_ROOT"/hooks/*.fragment.json; do
  [ -f "$f" ] && ALL+=("$f")
done

owner_of() {
  case "$1" in
    */skills/*/settings-fragment.json) basename "$(dirname "$1")" ;;
    *) basename "$1" ;;
  esac
}
frag_id() { jq -r 'if type=="object" and (.id|type)=="string" then .id else empty end' "$1" 2>/dev/null; }

if [ -n "$FRAGMENT" ]; then
  found=0
  for f in ${ALL[@]+"${ALL[@]}"}; do [ "$(frag_id "$f")" = "$FRAGMENT" ] && found=1; done
  [ "$found" = 1 ] || die2 "unknown fragment id '$FRAGMENT'"
fi
if [ -n "$SKILL" ] && [ ! -d "$PACKAGE_ROOT/skills/$SKILL" ]; then
  die2 "unknown skill '$SKILL'"
fi

# Layers: a missing, unreadable or invalid file provides nothing.
LAYERS=("$PROJECT/.claude/settings.json" "$PROJECT/.claude/settings.local.json")
[ -n "$HOME_DIR" ] && LAYERS+=("$HOME_DIR/.claude/settings.json")
VALID=()
for l in "${LAYERS[@]}"; do
  if [ ! -e "$l" ]; then note="missing"
  elif [ ! -r "$l" ]; then note="not readable"
  elif jq -e . "$l" >/dev/null 2>&1; then note=""; VALID+=("$l")
  else note="not valid JSON, ignored"; fi
  if [ -n "$note" ] && [ "$JSON" = 0 ] && [ "$QUIET" = 0 ]; then echo "settings-doctor: layer $l: $note" >&2; fi
done
if [ "$JSON" = 0 ] && [ "$QUIET" = 0 ]; then echo "settings-doctor: layer managed settings: not readable, not checked" >&2; fi

# jq: fragment -> one compact requirement object per line.
read -r -d '' REQ_PROG <<'JQ'
def names: [ .. | strings | scan("[A-Za-z0-9_-]+\\.sh") ] | unique;
( (.hooks // {}) | to_entries[] | .key as $ev | .value | to_entries[] | .key as $i | .value as $e
  | { kind: "hook", event: $ev,
      requirement: "hooks.\($ev)[\($i)]",
      commands: [ $e.hooks[]? | .command? // empty | strings ],
      names: ($e | names) } ),
( (.permissions.allow // [])[] | { kind: "allow", requirement: "permissions.allow: \(.rule)", rule: .rule } ),
( (.env // {}) | to_entries[] | { kind: "env", requirement: "env.\(.key)", key: .key, value: .value } )
JQ

# jq: settings file + requirement -> true when satisfied.
read -r -d '' CHK_PROG <<'JQ'
if $r.kind == "hook" then
  [ (.hooks[$r.event]? // [])[]? | .hooks[]? | .command? // empty | strings ] as $cmds
  | $cmds | any(. as $c | (($r.commands | index($c)) != null) or ($r.names | any(. as $n | $c | contains($n))))
elif $r.kind == "allow" then ((.permissions.allow // []) | index($r.rule)) != null
elif $r.kind == "env" then ((.env // {})[$r.key]? == $r.value)
else false end
JQ

RC=0
for f in ${ALL[@]+"${ALL[@]}"}; do
  fid="$(frag_id "$f")"
  owner="$(owner_of "$f")"
  if [ -z "$fid" ]; then
    echo "settings-doctor: $f: unreadable fragment (not valid JSON or no id), skipped" >&2; RC=1; continue
  fi
  [ -n "$FRAGMENT" ] && [ "$fid" != "$FRAGMENT" ] && continue
  [ -n "$SKILL" ] && [ "$owner" != "$SKILL" ] && continue
  reqs="$(jq -c "$REQ_PROG" "$f" 2>/dev/null)" || { echo "settings-doctor: $f: cannot be evaluated, skipped" >&2; RC=1; continue; }
  [ -n "$reqs" ] || continue
  while IFS= read -r req; do
    [ -n "$req" ] || continue
    label="$(printf '%s' "$req" | jq -r '.requirement')"
    kind="$(printf '%s' "$req" | jq -r '.kind')"
    hit=""
    for l in ${VALID[@]+"${VALID[@]}"}; do
      if jq -e --argjson r "$req" "$CHK_PROG" "$l" >/dev/null 2>&1; then hit="$l"; break; fi
    done
    if [ -n "$hit" ]; then status="active"; else status="inactive"; RC=1; fi
    fix=""; restart=""
    if [ "$status" = inactive ]; then
      fix="run: npx jenga sync"
      [ "$kind" = allow ] && fix="run: npx jenga sync (an allow rule is opt-in: it is shown to you and written only on a yes)"
      [ "$kind" = hook ] && restart="restart Claude Code afterwards: hooks are read at session start"
    fi
    if [ "$JSON" = 1 ]; then
      [ "$QUIET" = 1 ] && [ "$status" = active ] && continue
      jq -n -c --arg fragment "$fid" --arg owner "$owner" --arg kind "$kind" --arg requirement "$label" \
        --arg status "$status" --arg layer "$hit" --arg fix "$fix" --arg restart "$restart" \
        '{fragment:$fragment, owner:$owner, kind:$kind, requirement:$requirement, status:$status,
          layer:(if $layer=="" then null else $layer end), fix:(if $fix=="" then null else $fix end),
          restart:(if $restart=="" then null else $restart end)}'
    elif [ "$status" = active ]; then
      [ "$QUIET" = 1 ] || echo "$fid: $label: active ($hit)"
    else
      echo "$fid: $label: inactive"
      echo "  fix: $fix"
      [ -n "$restart" ] && echo "  note: $restart"
    fi
  done <<REQS
$reqs
REQS
done

exit "$RC"
