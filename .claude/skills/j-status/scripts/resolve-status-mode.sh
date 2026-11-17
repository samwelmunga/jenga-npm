#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-status/scripts/resolve-status-mode.sh - the `j.status` mode switch (E92_S06_T26; Node routes E92_S08_T06)
#
# One place that parses the arguments of `j.status` and decides which renderer runs, so skills/j-status/SKILL.md only
# calls it. It counts nothing and draws nothing; it chooses a renderer and forwards the layout flags.
#
# USAGE
#   resolve-status-mode.sh mode   [args]   print the mode word on stdout
#   resolve-status-mode.sh plan   [args]   print the renderer command and its arguments on one line
#   resolve-status-mode.sh render [args]   run that renderer (exec); its stdout and exit status are this script's
#   resolve-status-mode.sh -h | --help     print this usage on stdout, exit 0
#
#   args (any order; --flag=value is accepted too):
#     <id>            one epic or story id, any width (E3_S5 equals E03_S05); a task id or a malformed id exits 2
#     --legacy        use the old renderers (render-status-bars.sh, render-status-scope.sh), with or without an id
#     --all           without an id: the full list, which is the legacy overview path; with an id: accepted, the Node
#                     scope view always lists every story, so it is not forwarded
#     --root <dir>    project root, forwarded to the renderer
#     --cols N        terminal width, forwarded
#     --color M       auto, always or never, forwarded
#     --charset C     utf8 or ascii, forwarded to the Node renderer only (unset: the renderer's own precedence,
#                     JENGA_PROGRESS_CHARSET, then config progress_charset, then utf8)
#
# MODES AND RENDERERS
#   mode          arguments                      renderer
#   overview      (no id, no --legacy, no --all) node lib/progress/cli.js overview     (E92_S08_T05, the default)
#   scope         <id>                           node lib/progress/cli.js scope <id>   (E92_S08_T05, the default)
#   legacy        --legacy, or --all, no id      render-status-bars.sh                (the old list; --all is not passed)
#   legacy-scope  --legacy <id>                  render-status-scope.sh <id>          (the old extended block)
#   --legacy wins over --all when both are given with an id. --all with no id and no --legacy is the full list: the
#   overview renderer prints nothing for --all, so the legacy overview path is the one that prints it.
#
# Forwarded flags are written in a fixed order: [<id>] [--charset C] [--cols N] [--color M] [--root D], whatever the
# order they were typed in. The legacy renderers take neither --all nor --charset, so those are never passed to them.
#
# The bash renderers are looked up next to this script and the Node entry point at <this dir>/../../../lib/progress/
# cli.js, so the dual-path idiom of SKILL.md (repository, node_modules or a .claude/.agents mirror) finds the matching
# files either way. `plan` prints the display path lib/progress/cli.js.
#
# NODE FALLBACK (never-fail rule): when `node` is not on PATH, or cli.js is missing, `render` of overview or scope runs
# the legacy renderer of the same scope instead (render-status-bars.sh, render-status-scope.sh <id>) and writes ONE
# warning on stderr, so j.status never prints nothing. render-status-overview.sh and render-status-scope-view.sh
# (E92_S06_T24, T25) stay on disk but are no longer routed.
#
# EXIT CODES: 0 ok; 2 usage error (unknown flag, flag without value, second id, bad id, bad --color, --charset or
# --cols, unknown or missing sub-command); on render, the exit status of the renderer (renderers exit 0 on a problem
# and 2 on a usage error).
# Requires: bash 3.2+; node (optional, see NODE FALLBACK).
# ---------------------------------------------------------------------------
set -u

NAME="resolve-status-mode.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
if [ -f "$SCRIPT_DIR/../../index/scripts/package-root.sh" ]; then . "$SCRIPT_DIR/../../index/scripts/package-root.sh"; else jenga_package_root() { (cd "$1/../../.." && pwd); }; fi
PACKAGE_ROOT="$(jenga_package_root "$SCRIPT_DIR")" || true
usage() { sed -n '/^# USAGE/,/^# MODES AND RENDERERS/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
usage_err() { printf '%s: %s\n' "$NAME" "$1" >&2; exit 2; }

[ "$#" -ge 1 ] || usage_err "a sub-command is required: mode, plan or render (see --help)"
case "$1" in
  -h|--help) usage; exit 0 ;;
  mode|plan|render) cmd="$1"; shift ;;
  *) usage_err "unknown sub-command: $1 (expected mode, plan or render)" ;;
esac

legacy=0; all=0; id=""; root=""; cols=""; color=""; charset=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --legacy)  legacy=1; shift ;;
    --all)     all=1; shift ;;
    --cols)    [ "$#" -ge 2 ] && [ -n "$2" ] || usage_err "--cols needs a value"; cols="$2"; shift 2 ;;
    --cols=*)  cols="${1#--cols=}"; [ -n "$cols" ] || usage_err "--cols needs a value"; shift ;;
    --color)   [ "$#" -ge 2 ] && [ -n "$2" ] || usage_err "--color needs a value"; color="$2"; shift 2 ;;
    --color=*) color="${1#--color=}"; [ -n "$color" ] || usage_err "--color needs a value"; shift ;;
    --charset)   [ "$#" -ge 2 ] && [ -n "$2" ] || usage_err "--charset needs a value"; charset="$2"; shift 2 ;;
    --charset=*) charset="${1#--charset=}"; [ -n "$charset" ] || usage_err "--charset needs a value"; shift ;;
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
if [ -n "$charset" ]; then case "$charset" in utf8|ascii) ;; *) usage_err "--charset must be utf8 or ascii" ;; esac; fi
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

NODE_CLI="$PACKAGE_ROOT/lib/progress/cli.js"

# The arguments of each renderer, in the fixed order. Node takes --charset; the legacy renderers take no --all and no
# --charset; the Node scope view draws every story, so --all is not passed to it either.
node_args() { # <command> [<id>]
  args=("$@")
  [ -z "$charset" ] || args+=(--charset "$charset")
  [ -z "$cols" ]    || args+=(--cols "$cols")
  [ -z "$color" ]   || args+=(--color "$color")
  [ -z "$root" ]    || args+=(--root "$root")
}
legacy_args() { # [<id>]
  args=("$@")
  [ -z "$cols" ]  || args+=(--cols "$cols")
  [ -z "$color" ] || args+=(--color "$color")
  [ -z "$root" ]  || args+=(--root "$root")
}

case "$mode" in
  overview)     runner="node"; renderer="lib/progress/cli.js";    node_args overview ;;
  scope)        runner="node"; renderer="lib/progress/cli.js";    node_args scope "$id" ;;
  legacy)       runner="bash"; renderer="render-status-bars.sh";  legacy_args ;;
  legacy-scope) runner="bash"; renderer="render-status-scope.sh"; legacy_args "$id" ;;
esac

if [ "$cmd" = "plan" ]; then
  [ "$runner" = "node" ] && printf 'node %s' "$renderer" || printf '%s' "$renderer"
  for a in ${args[@]+"${args[@]}"}; do printf ' %s' "$a"; done
  printf '\n'
  exit 0
fi

# render
note=""
if [ "$runner" = "node" ]; then
  if ! command -v node >/dev/null 2>&1; then
    note="node not found on PATH"
  elif [ ! -f "$NODE_CLI" ]; then
    note="Node renderer not found: $NODE_CLI"
  else
    exec node "$NODE_CLI" ${args[@]+"${args[@]}"}
  fi
  # Fallback: the legacy renderer of the same scope.
  if [ "$mode" = "scope" ]; then renderer="render-status-scope.sh"; legacy_args "$id"
  else renderer="render-status-bars.sh"; legacy_args; fi
fi

target="$SCRIPT_DIR/$renderer"
if [ ! -f "$target" ]; then
  printf '%s: %srenderer not found: %s\n' "$NAME" "${note:+$note; legacy }" "$target" >&2
  exit 0
fi
[ -z "$note" ] || printf '%s: warning: %s; using the legacy renderer %s\n' "$NAME" "$note" "$renderer" >&2
exec bash "$target" ${args[@]+"${args[@]}"}
