#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-status/scripts/resolve-status-mode.sh - the `j.status` mode switch (E92_S06_T26)
#
# One place that parses the arguments of `j.status` and decides which renderer runs, so skills/j-status/SKILL.md only
# calls it. It counts nothing and draws nothing; it chooses a renderer and forwards the layout flags.
#
# USAGE
#   resolve-status-mode.sh mode   [args]   print the mode word on stdout
#   resolve-status-mode.sh plan   [args]   print the renderer file name and its arguments on one line
#   resolve-status-mode.sh render [args]   run that renderer (exec); its stdout and exit status are this script's
#   resolve-status-mode.sh -h | --help     print this usage on stdout, exit 0
#
#   args (any order; --flag=value is accepted too):
#     <id>            one epic or story id, any width (E3_S5 equals E03_S05); a task id or a malformed id exits 2
#     --legacy        use the old renderers (render-status-bars.sh, render-status-scope.sh), with or without an id
#     --all           without an id: the full list, which is the legacy overview path; with an id: the new scope view
#                     lists the complete stories too (passed to the renderer)
#     --root <dir>    project root, forwarded to the renderer
#     --cols N        terminal width, forwarded
#     --color M       auto, always or never, forwarded
#
# MODES AND RENDERERS
#   mode          arguments                      renderer
#   overview      (no id, no --legacy, no --all) render-status-overview.sh            (E92_S06_T24, the default)
#   scope         <id>                           render-status-scope-view.sh <id>     (E92_S06_T25, the default; --all
#                                                 is passed through)
#   legacy        --legacy, or --all, no id      render-status-bars.sh                (the old list; --all is not passed)
#   legacy-scope  --legacy <id>                  render-status-scope.sh <id>          (the old extended block)
#   --legacy wins over --all when both are given with an id. --all with no id and no --legacy is the full list: the
#   overview renderer prints nothing for --all (T24), so the legacy overview path is the one that prints it.
#
# Forwarded flags are written in a fixed order: [<id>] [--all] [--cols N] [--color M] [--root D], whatever the order
# they were typed in. The legacy renderers have no --all, so it is never passed to them.
#
# The renderer files are looked up next to this script, so the dual-path idiom of SKILL.md (repository or node_modules)
# finds the right ones either way.
#
# EXIT CODES: 0 ok; 2 usage error (unknown flag, flag without value, second id, bad id, bad --color or --cols, unknown
# or missing sub-command); on render, the exit status of the renderer (renderers exit 0 on a problem and 2 on a usage error).
# Requires: bash 3.2+.
# ---------------------------------------------------------------------------
set -u

NAME="resolve-status-mode.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '/^# USAGE/,/^# MODES AND RENDERERS/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
usage_err() { printf '%s: %s\n' "$NAME" "$1" >&2; exit 2; }

[ "$#" -ge 1 ] || usage_err "a sub-command is required: mode, plan or render (see --help)"
case "$1" in
  -h|--help) usage; exit 0 ;;
  mode|plan|render) cmd="$1"; shift ;;
  *) usage_err "unknown sub-command: $1 (expected mode, plan or render)" ;;
esac

legacy=0; all=0; id=""; root=""; cols=""; color=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --legacy)  legacy=1; shift ;;
    --all)     all=1; shift ;;
    --cols)    [ "$#" -ge 2 ] && [ -n "$2" ] || usage_err "--cols needs a value"; cols="$2"; shift 2 ;;
    --cols=*)  cols="${1#--cols=}"; [ -n "$cols" ] || usage_err "--cols needs a value"; shift ;;
    --color)   [ "$#" -ge 2 ] && [ -n "$2" ] || usage_err "--color needs a value"; color="$2"; shift 2 ;;
    --color=*) color="${1#--color=}"; [ -n "$color" ] || usage_err "--color needs a value"; shift ;;
    --root)    [ "$#" -ge 2 ] && [ -n "$2" ] || usage_err "--root needs a value"; root="$2"; shift 2 ;;
    --root=*)  root="${1#--root=}"; [ -n "$root" ] || usage_err "--root needs a value"; shift ;;
    -*) usage_err "unknown argument: $1 (see --help)" ;;
    *)  [ -z "$id" ] || usage_err "only one id is allowed (got '$id' and '$1')"; id="$1"; shift ;;
  esac
done

if [ -n "$id" ]; then
  [[ "$id" =~ ^[Ee][0-9]+_[Ss][0-9]+_[Tt][0-9]+$ ]] && usage_err "'$id' is a task id; give an epic or a story id"
  [[ "$id" =~ ^[Ee][0-9]+(_[Ss][0-9]+)?$ ]] || usage_err "malformed id '$id' (expected E<digits> or E<digits>_S<digits>)"
fi
if [ -n "$color" ]; then case "$color" in auto|always|never) ;; *) usage_err "--color must be auto, always or never" ;; esac; fi
if [ -n "$cols" ]; then
  case "$cols" in ''|*[!0-9]*) usage_err "--cols needs a positive integer" ;; esac
  [ "$cols" -ge 1 ] || usage_err "--cols needs a positive integer"
fi

if [ "$legacy" -eq 1 ]; then
  if [ -n "$id" ]; then mode="legacy-scope"; else mode="legacy"; fi
elif [ -n "$id" ]; then
  mode="scope"
elif [ "$all" -eq 1 ]; then
  mode="legacy"
else
  mode="overview"
fi

if [ "$cmd" = "mode" ]; then printf '%s\n' "$mode"; exit 0; fi

case "$mode" in
  overview)     renderer="render-status-overview.sh";   pass_id=0; pass_all=0 ;;
  scope)        renderer="render-status-scope-view.sh"; pass_id=1; pass_all="$all" ;;
  legacy)       renderer="render-status-bars.sh";       pass_id=0; pass_all=0 ;;
  legacy-scope) renderer="render-status-scope.sh";      pass_id=1; pass_all=0 ;;
esac

args=()
[ "$pass_id" -eq 0 ] || args+=("$id")
[ "$pass_all" -eq 0 ] || args+=(--all)
[ -z "$cols" ]  || args+=(--cols "$cols")
[ -z "$color" ] || args+=(--color "$color")
[ -z "$root" ]  || args+=(--root "$root")

if [ "$cmd" = "plan" ]; then
  printf '%s' "$renderer"
  for a in ${args[@]+"${args[@]}"}; do printf ' %s' "$a"; done
  printf '\n'
  exit 0
fi

# render
target="$SCRIPT_DIR/$renderer"
[ -f "$target" ] || { printf '%s: renderer not found: %s\n' "$NAME" "$target" >&2; exit 0; }
exec bash "$target" ${args[@]+"${args[@]}"}
