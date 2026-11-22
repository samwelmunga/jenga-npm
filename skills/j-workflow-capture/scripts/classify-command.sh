#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-workflow-capture/scripts/classify-command.sh - map a captured command to a workflow step type
# (epic E103, task E103_S04_T01)
#
# A captured process is a list of shell commands and instructions. Only some of them can become a `compute` step:
# scripts/workflow/run-compute.sh gives a compute step stdin /dev/null and a timeout, so anything that prompts,
# logs in, opens a browser or changes the calling shell's state cannot run there. This script decides, per command,
# which step type the review should propose, and says why in one line. It is a pure function of the command text and
# the j.connect descriptors on disk: it writes nothing, runs none of the commands, and never reads or writes the
# recorder's active-recording pointer.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   classify-command.sh [--descriptors-dir <dir>]... <command>      classify one command (all remaining arguments
#                                                                     are joined with one space)
#   classify-command.sh [--descriptors-dir <dir>]... --lines <file|->
#                                                                     one result per non-empty line, numbered n=1..
#   classify-command.sh -h | --help | help                            this usage on stdout, exit 0
#
#   --descriptors-dir <dir>  repeatable; where the j.connect service descriptors (<id>.json) are read from. When
#                            none is given: $CLASSIFY_DESCRIPTORS_DIR if set, else the first existing of
#                              <this script>/../../j-connect/descriptors         (repo, .claude/ mirror, package)
#                              <cwd>/skills/j-connect/descriptors
#                              <cwd>/node_modules/@jenga-ai/agent/skills/j-connect/descriptors   (consumer layout)
#                            An explicit directory that does not exist is a usage error; no directory at all just
#                            means no service can be routed to j.connect.
#
# ---------------------------------------------------------------------------
# OUTPUT (stdout): ONE compact JSON object per command (one per line with --lines)
# ---------------------------------------------------------------------------
#   {"classify_version": 1,
#    "n": 3,                                   --lines only: the 1-based number among the non-empty lines
#    "step_type": "compute" | "confirm" | "skill",
#    "skill": "j.connect" | null,              set only when step_type is "skill"
#    "service": "<descriptor id>" | null,      the j.connect descriptor a login matched
#    "variables": ["VENDOR_KEY", ...],         the names an export / assignment sets ([] otherwise); NEVER a value
#    "category": "deterministic" | "login" | "interactive" | "export" | "shell-state" | "dashboard"
#              | "destructive" | "compound" | "unknown",
#    "uncertain": true | false,                true when no rule classified the command confidently; the review
#                                              walks such a row on its own (render-review-table.sh's uncertain rule)
#    "reason": "one line, never containing a value"}
#
#   The values of exports, assignments, VAR=value prefixes and option arguments are never copied into any field:
#   the reason names only the binary, its subcommand words, flags it relies on, and variable names. This keeps to
#   scan-secrets.sh's rule (E103_S03_T02) that a credential is never printed, whatever the command holds.
#
# ---------------------------------------------------------------------------
# RULES (first match wins)
# ---------------------------------------------------------------------------
#   1. export / declare -x / setx / $env:NAME= / a bare NAME=value line         confirm, category export, naming
#      the variables: an environment change cannot outlive a compute subprocess, so the user sets it.
#      An unquoted value stops at ; & |, so `export KEY=val; npm i` is not an export (it falls to compound).
#   2. dashboard / browser instruction (rule 5 below, checked here so prose punctuation is not read as a compound)
#   3. compound: &&, ||, ;, a pipe, $( ) or backticks                         confirm, category compound, uncertain
#      (a download piped into sh/bash is named as such and is not uncertain: it must be confirmed). Checked
#      before shell state, so `cd app && npm install` is walked part by part.
#   3c. cd / pushd / popd / source / . / alias / unset                        confirm, category shell-state.
#   4. login: a `login` / `signin` / `sign-in` / `logon` word, or `<cli> auth [login|init|signin]`. When a VALID
#      descriptor whose auth.type is not "none" names the CLI (its id, detect.command[0] or auth.check.command[0]
#      equals the login's binary) -> skill j.connect with that service; otherwise confirm. Validity comes from
#      j-connect/scripts/list-services.sh when it is found next to the descriptors or this skill; without it, a
#      descriptor counts when it parses and its id equals its filename stem.
#   5. dashboard / browser instruction: prose mentioning a dashboard, console, portal, browser, website, web UI,
#      admin panel or settings page, or starting with click / navigate / visit / browse / go to, or open/xdg-open
#      of a URL                                                                 confirm, category dashboard.
#   6. interactive: sudo, an editor/pager/passwd/read, a bare REPL, -i/-it/--interactive, `aws configure`,
#      `git commit` without a message, an init/create scaffold without a non-interactive flag     confirm.
#   7. destructive: rm, rmdir, dd, mkfs, shred                              confirm, category destructive.
#   8. deterministic allow-list (package installs, builds, git clone/fetch/pull, mkdir/touch/cp/ln/chmod, and
#      npx/bunx/pnpm dlx/yarn dlx with --yes/-y)                            compute.
#      npx & co. without a yes flag -> confirm, uncertain (npx may ask to install the package).
#   9. anything else                                                         confirm, category unknown, uncertain.
#
# Non-interactive flags recognised: --yes -y --non-interactive --no-interactive --no-input --defaults --ci.
#
# Exit: 0 on success; 2 on a usage error (no command, unknown option, missing --lines file, explicit
#       --descriptors-dir that does not exist, jq missing).
# Dependencies: bash 3.2+, jq.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage_err() {
  echo "classify-command: $1" >&2
  echo "Usage: $(basename "$0") [--descriptors-dir <dir>]... <command> | --lines <file|->" >&2
  exit 2
}

usage() { sed -n '/^# USAGE/,/^# Dependencies:/p' "$0" | sed 's/^# \{0,1\}//'; }

DIRS=()
LINES_FILE=""
LINES_MODE=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help) [ "${#ARGS[@]}" -eq 0 ] && { usage; exit 0; }; ARGS+=("$1"); shift ;;
    --descriptors-dir) [ $# -ge 2 ] || usage_err "--descriptors-dir needs a value"; DIRS+=("$2"); shift 2 ;;
    --lines) [ $# -ge 2 ] || usage_err "--lines needs a file or -"; LINES_MODE=1; LINES_FILE="$2"; shift 2 ;;
    --) shift; while [ $# -gt 0 ]; do ARGS+=("$1"); shift; done ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

command -v jq >/dev/null 2>&1 || usage_err "jq is required but not found on PATH"

if [ "$LINES_MODE" -eq 1 ]; then
  [ "${#ARGS[@]}" -eq 0 ] || usage_err "--lines takes no command argument"
  [ "$LINES_FILE" = "-" ] || [ -f "$LINES_FILE" ] || usage_err "lines file not found: $LINES_FILE"
else
  [ "${#ARGS[@]}" -gt 0 ] || usage_err "no command given"
fi

# ---------------------------------------------------------------------------
# Descriptor directories and the login-binary -> service index
# ---------------------------------------------------------------------------
if [ "${#DIRS[@]}" -gt 0 ]; then
  for d in "${DIRS[@]}"; do [ -d "$d" ] || usage_err "descriptors dir not found: $d"; done
elif [ -n "${CLASSIFY_DESCRIPTORS_DIR:-}" ]; then
  [ -d "$CLASSIFY_DESCRIPTORS_DIR" ] || usage_err "descriptors dir not found: $CLASSIFY_DESCRIPTORS_DIR"
  DIRS=("$CLASSIFY_DESCRIPTORS_DIR")
else
  for d in "$SCRIPT_DIR/../../j-connect/descriptors" \
           "$PWD/skills/j-connect/descriptors" \
           "$PWD/node_modules/@jenga-ai/agent/skills/j-connect/descriptors"; do
    if [ -d "$d" ]; then DIRS=("$d"); break; fi
  done
fi

# SERVICE_INDEX: "<binary><TAB><id>" lines, first descriptor wins (newline string, not an associative array:
# stock macOS bash is 3.2).
SERVICE_INDEX=""
index_descriptor() {   # <file>
  local f="$1" pairs
  pairs="$(jq -r 'select((.auth.type // "none") != "none")
                  | .id as $id
                  | [$id, (.detect.command[0] // empty), (.auth.check.command[0] // empty)]
                  | map(select(type == "string" and . != "")) | unique[] | "\(.)\t\($id)"' "$f" 2>/dev/null)" || return 0
  [ -n "$pairs" ] && SERVICE_INDEX="${SERVICE_INDEX}${pairs}"$'\n'
  return 0
}

if [ "${#DIRS[@]}" -gt 0 ]; then
  for d in "${DIRS[@]}"; do
    d="$(cd "$d" && pwd)"
    lister=""
    for cand in "$d/../scripts/list-services.sh" "$SCRIPT_DIR/../../j-connect/scripts/list-services.sh"; do
      if [ -f "$cand" ]; then lister="$cand"; break; fi
    done
    if [ -n "$lister" ]; then
      files="$(bash "$lister" --descriptors-dir "$d" 2>/dev/null | jq -r '.services[].file' 2>/dev/null)" || files=""
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$f" in /*) ;; *) f="$d/$(basename "$f")" ;; esac
        [ -f "$f" ] && index_descriptor "$f"
      done <<EOF_FILES
$files
EOF_FILES
    else
      for f in "$d"/*.json; do
        [ -f "$f" ] || continue
        stem="$(basename "$f" .json)"
        [ "$(jq -r '.id // empty' "$f" 2>/dev/null)" = "$stem" ] && index_descriptor "$f"
      done
    fi
  done
fi

lookup_service() {   # <binary> -> prints the descriptor id or nothing
  local b="$1"
  [ -n "$b" ] || return 0
  printf '%s' "$SERVICE_INDEX" | awk -F'\t' -v b="$b" '$1 == b { print $2; exit }'
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

in_list() {   # <word> <space-separated list>
  case " $2 " in *" $1 "*) return 0 ;; esac
  return 1
}

# NAME=value with a quoted or unquoted value, then whitespace or end. The value is matched, never captured into
# output.
RE_ASSIGN='^([A-Za-z_][A-Za-z0-9_]*)=("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|]*)([[:space:]]+|$)'
RE_NAME_ONLY='^([A-Za-z_][A-Za-z0-9_]*)([[:space:]]+|$)'
RE_FLAG='^-[^[:space:]]*([[:space:]]+|$)'

NONINTERACTIVE_FLAGS="--yes -y --non-interactive --no-interactive --no-input --defaults --ci"

emit() {   # <n|""> <step_type> <skill|""> <service|""> <variables-newline-list> <category> <uncertain> <reason>
  jq -cn --arg n "$1" --arg st "$2" --arg sk "$3" --arg sv "$4" --arg vars "$5" --arg cat "$6" \
         --argjson unc "$7" --arg reason "$8" '
    {classify_version: 1}
    + (if $n == "" then {} else {n: ($n | tonumber)} end)
    + {step_type: $st,
       skill: (if $sk == "" then null else $sk end),
       service: (if $sv == "" then null else $sv end),
       variables: ($vars | split("\n") | map(select(. != ""))),
       category: $cat,
       uncertain: $unc,
       reason: $reason}'
}

# parse_assignments <text> <leading-keyword-regex>: consumes NAME=value / NAME tokens after the keyword; sets
# ASSIGN_NAMES (newline list) and returns 0 when the whole text was consumed.
ASSIGN_NAMES=""
parse_assignments() {
  local rest="$1" allow_bare="$2" got=0
  ASSIGN_NAMES=""
  while [ -n "$rest" ]; do
    if [[ "$rest" =~ $RE_ASSIGN ]]; then
      ASSIGN_NAMES="${ASSIGN_NAMES}${BASH_REMATCH[1]}"$'\n'; rest="${rest:${#BASH_REMATCH[0]}}"; got=1
    elif [ "$allow_bare" = 1 ] && [[ "$rest" =~ $RE_FLAG ]]; then
      rest="${rest:${#BASH_REMATCH[0]}}"
    elif [ "$allow_bare" = 1 ] && [[ "$rest" =~ $RE_NAME_ONLY ]]; then
      ASSIGN_NAMES="${ASSIGN_NAMES}${BASH_REMATCH[1]}"$'\n'; rest="${rest:${#BASH_REMATCH[0]}}"; got=1
    else
      return 1
    fi
  done
  [ "$got" = 1 ]
}

join_names() { printf '%s' "$1" | awk 'NF { printf "%s%s", (c++ ? ", " : ""), $0 }'; }
is_are() { [ "$(printf "%s" "$1" | awk "NF" | wc -l | tr -d " ")" -gt 1 ] && echo are || echo is; }

has_flag() {   # <flag-list> -> 0 when any word of WORDS is in the list
  local w
  for w in "${WORDS[@]}"; do in_list "$w" "$1" && return 0; done
  return 1
}

# ---------------------------------------------------------------------------
# classify <n|""> <command>
# ---------------------------------------------------------------------------
classify() {
  local n="$1" cmd="$2" low rest names b0 b1 b2 bin sub svc i w
  # trim, drop a shell prompt and surrounding backticks
  cmd="$(printf '%s' "$cmd" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  case "$cmd" in '$ '*|'> '*|'% '*|'# '*) cmd="${cmd:2}" ;; esac
  case "$cmd" in '`'*'`') cmd="${cmd#\`}"; cmd="${cmd%\`}" ;; esac
  cmd="$(printf '%s' "$cmd" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -n "$cmd" ] || return 0
  low="$(lc "$cmd")"

  # 1. export / assignment ------------------------------------------------------------------------------------
  rest=""
  case "$cmd" in
    'export '*)     rest="${cmd#export }" ;;
    'declare -x '*) rest="${cmd#declare -x }" ;;
  esac
  if [ -n "$rest" ]; then
    rest="$(printf '%s' "$rest" | sed 's/^[[:space:]]*//')"
    if parse_assignments "$rest" 1; then
      names="$(join_names "$ASSIGN_NAMES")"
      emit "$n" confirm "" "" "$ASSIGN_NAMES" export false \
        "export sets ${names} in the calling shell, which a compute subprocess cannot do; confirm that ${names} $(is_are "$ASSIGN_NAMES") set (the value is never recorded)"
      return 0
    fi
  fi
  if [[ "$cmd" =~ ^setx[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)([[:space:]]|$) ]] \
     || [[ "$cmd" =~ ^\$env:([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]]; then
    names="${BASH_REMATCH[1]}"
    emit "$n" confirm "" "" "$names" export false \
      "sets the environment variable ${names}, which a compute subprocess cannot do; confirm that ${names} $(is_are "$names") set (the value is never recorded)"
    return 0
  fi
  if parse_assignments "$cmd" 0; then
    names="$(join_names "$ASSIGN_NAMES")"
    emit "$n" confirm "" "" "$ASSIGN_NAMES" export false \
      "assigns ${names} in the calling shell, which a compute subprocess cannot do; confirm that ${names} $(is_are "$ASSIGN_NAMES") set (the value is never recorded)"
    return 0
  fi

  # Strip leading VAR=value prefixes and `env` for word matching (their values are dropped here, never output).
  rest="$cmd"
  while :; do
    if [[ "$rest" =~ $RE_ASSIGN ]]; then rest="${rest:${#BASH_REMATCH[0]}}"; continue; fi
    case "$rest" in 'env '*) rest="${rest#env }"; rest="$(printf '%s' "$rest" | sed 's/^[[:space:]]*//')"; continue ;; esac
    break
  done
  local sudo=0
  case "$rest" in 'sudo '*) sudo=1; rest="${rest#sudo }"; rest="$(printf '%s' "$rest" | sed 's/^[[:space:]]*//')" ;; esac

  WORDS=()
  read -r -a WORDS <<<"$(lc "$rest")"
  b0="${WORDS[0]:-}"; b1="${WORDS[1]:-}"; b2="${WORDS[2]:-}"

  # 3a. dashboard / browser ---------------------------------------------------------------------------------------
  local known_cli="npm yarn pnpm bun npx bunx pip pip3 python python3 brew apt apt-get cargo go gem composer poetry uv
                   git mkdir touch cp ln chmod make node docker kubectl terraform curl wget"
  if { ! in_list "$b0" "$known_cli" && [[ "$low" =~ (dashboard|console|portal|browser|website|web[[:space:]]ui|web[[:space:]]app|admin[[:space:]]panel|settings[[:space:]]page) ]]; } \
     || in_list "$b0" "click navigate visit browse" \
     || [[ "$low" =~ ^go[[:space:]]+to[[:space:]] ]] \
     || { in_list "$b0" "open xdg-open start" && [[ "$low" =~ https?:// ]]; }; then
    emit "$n" confirm "" "" "" dashboard false \
      "a dashboard or browser action the user performs by hand; it cannot run as a script"
    return 0
  fi

  # 3. compound ------------------------------------------------------------------------------------------------
  if [[ "$rest" =~ \|[[:space:]]*(sudo[[:space:]]+)?(sh|bash|zsh)([[:space:]]|$) ]]; then
    emit "$n" confirm "" "" "" compound false \
      "pipes output into a shell (for example a downloaded install script); it runs code that was not reviewed, so it must be confirmed"
    return 0
  fi
  case "$rest" in
    *'&&'*|*'||'*|*';'*|*'|'*|*'$('*|*'`'*)
      emit "$n" confirm "" "" "" compound true \
        "compound command (&&, ||, ;, a pipe or a substitution); review each part on its own before it can become a step"
      return 0 ;;
  esac

  # 3c. shell state (after compound, so `cd app && npm install` is walked part by part) ------------------------
  if in_list "$b0" "cd pushd popd source . alias unset"; then
    emit "$n" confirm "" "" "" shell-state false \
      "${b0} changes the calling shell's state, which does not survive a compute subprocess; confirm it by hand"
    return 0
  fi

  # Resolve the binary a runner launches (npx/bunx <tool>, pnpm/yarn dlx <tool>).
  local runner="" tool_i=1
  bin="$b0"
  if in_list "$b0" "npx bunx" || { in_list "$b0" "pnpm yarn" && [ "$b1" = "dlx" ]; }; then
    runner="$b0"; [ "$b1" = "dlx" ] && { runner="$b0 dlx"; tool_i=2; }
    bin=""
    i=$tool_i
    while [ "$i" -lt "${#WORDS[@]}" ]; do
      w="${WORDS[$i]}"
      case "$w" in -*) ;; *) bin="$w"; tool_i=$i; break ;; esac
      i=$((i + 1))
    done
    # strip a version (@x.y / pkg@x) and keep the last path part of a scoped package
    case "$bin" in @*/*) bin="${bin#@}"; bin="@${bin%%@*}" ;; *) bin="${bin%%@*}" ;; esac
    bin="${bin##*/}"
    sub="${WORDS[$((tool_i + 1))]:-}"
  else
    sub="$b1"
  fi

  # 4. login ---------------------------------------------------------------------------------------------------
  local is_login=0
  for w in "${WORDS[@]:1}"; do
    in_list "$w" "login signin sign-in logon" && { is_login=1; break; }
  done
  if [ "$is_login" = 0 ]; then
    i=1; while [ "$i" -lt "${#WORDS[@]}" ]; do
      if [ "${WORDS[$i]}" = "auth" ]; then
        w="${WORDS[$((i + 1))]:-}"
        if [ -z "$w" ] || in_list "$w" "login init signin"; then is_login=1; fi
        break
      fi
      i=$((i + 1))
    done
  fi
  if [ "$is_login" = 1 ]; then
    svc="$(lookup_service "$bin")"
    if [ -n "$svc" ]; then
      emit "$n" skill j.connect "$svc" "" login false \
        "a ${bin} login is interactive and cannot be a compute step; j.connect has a descriptor for ${svc}, so the step runs j.connect"
    else
      emit "$n" confirm "" "" "" login false \
        "a ${bin:-command} login is interactive and cannot be a compute step, and j.connect has no descriptor for it; confirm it by hand"
    fi
    return 0
  fi

  # 6. interactive -----------------------------------------------------------------------------------------------
  if [ "$sudo" = 1 ]; then
    emit "$n" confirm "" "" "" interactive false \
      "sudo may prompt for a password, and a compute step has no stdin; confirm it by hand"
    return 0
  fi
  if in_list "$b0" "vi vim nvim nano emacs less more top htop passwd read ssh telnet ftp sftp" \
     || { in_list "$b0" "node python python3 irb mysql psql mongosh redis-cli sqlite3" && [ "${#WORDS[@]}" -eq 1 ]; }; then
    emit "$n" confirm "" "" "" interactive false \
      "${b0} is interactive (editor, pager, shell or prompt) and cannot run with no stdin; confirm it by hand"
    return 0
  fi
  if has_flag "-i -it -ti --interactive --tty"; then
    emit "$n" confirm "" "" "" interactive false \
      "${b0} runs with an interactive flag (-i/-it/--interactive) and cannot run with no stdin; confirm it by hand"
    return 0
  fi
  if [ "$b0" = "aws" ] && [ "$b1" = "configure" ] && [ "$b2" != "set" ]; then
    emit "$n" confirm "" "" "" interactive false \
      "aws configure prompts for credentials; confirm it by hand (the values are never recorded)"
    return 0
  fi
  if [ "$b0" = "git" ] && [ "$b1" = "commit" ] && ! has_flag "-m --message -f --file --no-edit -c -C --reuse-message --fixup" \
     && ! [[ "$low" =~ [[:space:]](-[a-z]*m|--message=) ]]; then
    emit "$n" confirm "" "" "" interactive false \
      "git commit without a message opens an editor; confirm it by hand"
    return 0
  fi
  local scaffold=0
  if in_list "$b0" "npm yarn pnpm bun" && in_list "$b1" "init create"; then scaffold=1; fi
  if [ -n "$runner" ]; then
    case "$bin" in create-*) scaffold=1 ;; esac
    in_list "$sub" "init create" && scaffold=1
  fi
  if [ "$scaffold" = 1 ] && ! has_flag "$NONINTERACTIVE_FLAGS"; then
    emit "$n" confirm "" "" "" interactive false \
      "${runner:+$runner }${bin} scaffold without a non-interactive flag (--yes, -y, --non-interactive) may prompt; confirm it, or add the flag to make it a compute step"
    return 0
  fi

  # 7. destructive -----------------------------------------------------------------------------------------------
  if in_list "$b0" "rm rmdir dd mkfs shred"; then
    emit "$n" confirm "" "" "" destructive false \
      "${b0} deletes or overwrites data; it is never run automatically, confirm it by hand"
    return 0
  fi

  # 8. deterministic allow-list ----------------------------------------------------------------------------------
  local det=0 what=""
  case "$b0" in
    npm)  in_list "$b1" "install i ci add uninstall remove rm update rebuild prune dedupe run run-script test build pack init" && det=1 ;;
    yarn) { [ -z "$b1" ] || in_list "$b1" "install add remove upgrade run build test init"; } && det=1 ;;
    pnpm) in_list "$b1" "install i add remove update run build test init" && det=1 ;;
    bun)  in_list "$b1" "install i add remove update run build test init" && det=1 ;;
    pip|pip3) in_list "$b1" "install uninstall" && det=1 ;;
    python|python3) [ "$b1" = "-m" ] && in_list "$b2" "pip venv" && det=1 ;;
    brew) in_list "$b1" "install tap update upgrade bundle" && det=1 ;;
    apt|apt-get) in_list "$b1" "install update" && has_flag "-y --yes --assume-yes" && det=1 ;;
    cargo) in_list "$b1" "build install add fetch test" && det=1 ;;
    go)   in_list "$b1" "get install build mod test" && det=1 ;;
    gem)  [ "$b1" = "install" ] && det=1 ;;
    composer) in_list "$b1" "install require update" && det=1 ;;
    poetry) in_list "$b1" "install add" && det=1 ;;
    uv)   in_list "$b1" "add sync pip venv" && det=1 ;;
    git)  in_list "$b1" "clone fetch pull checkout switch submodule init" && det=1 ;;
    mkdir|touch|cp|ln|chmod) det=1 ;;
    make) det=1 ;;
  esac
  if [ "$det" = 1 ]; then
    what="$b0"; [ -n "$b1" ] && case "$b1" in -*) ;; *) what="$b0 $b1" ;; esac
    [ "$b0" = "python" ] || [ "$b0" = "python3" ] && what="$b0 -m $b2"
    emit "$n" compute "" "" "" deterministic false \
      "${what} is non-interactive and deterministic; it can run as a compute step"
    return 0
  fi
  if [ -n "$runner" ]; then
    if has_flag "$NONINTERACTIVE_FLAGS"; then
      emit "$n" compute "" "" "" deterministic false \
        "${runner} ${bin}${sub:+ $sub} runs with a non-interactive flag; it can run as a compute step"
    else
      emit "$n" confirm "" "" "" unknown true \
        "${runner} ${bin} without --yes may ask to install the package; confirm it, or add --yes to make it a compute step"
    fi
    return 0
  fi

  # 9. unknown ---------------------------------------------------------------------------------------------------
  if has_flag "$NONINTERACTIVE_FLAGS"; then
    emit "$n" confirm "" "" "" unknown true \
      "${b0} is not a known command; it passes a non-interactive flag but was not classified with confidence, review it"
  else
    emit "$n" confirm "" "" "" unknown true \
      "no rule classified ${b0:-this line} with confidence; it defaults to a confirm step, review it"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [ "$LINES_MODE" -eq 1 ]; then
  count=0
  if [ "$LINES_FILE" = "-" ]; then src=/dev/stdin; else src="$LINES_FILE"; fi
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$trimmed" ] || continue
    count=$((count + 1))
    classify "$count" "$line"
  done <"$src"
else
  classify "" "${ARGS[*]}"
fi
exit 0
