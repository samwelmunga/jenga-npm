#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/workflow/artifacts.sh - the workflow output registry (epic E80, task E80_S04_T04)
#
# A workflow run produces outputs: files (kind "artifact", for example a rendered sprint document) and typed
# values (kind "data"). This script is the SINGLE WRITER of the registry that records them and the only place
# that knows its layout, so render-artifact.sh, complete-step.sh and the readers never build these paths
# themselves. E80_S04_T04 added the write side (`register`); E80_S04_T05 adds the read side (`list`, `get`,
# `latest`).
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   artifacts.sh register <workflow_id> <run_id> <step_id> <name> --kind artifact|data --type <type>
#                         --file <path> [--replace]
#   artifacts.sh list [--workflow <id>] [--run <run_id>]
#   artifacts.sh get <workflow_id> <name> [--run <run_id>] [--path]
#   artifacts.sh latest <workflow_id> <name> [--path]
#   artifacts.sh -h | --help        print this usage on stdout, exit 0
#
#   --kind     artifact (a produced file) or data (a typed value other steps and workflows consume)
#   --type     the output type name (a name from templates/playbook-types.json); one plain token
#   --file     the existing regular file to publish; it is copied, never moved
#   --replace  swap this run's own record and file for <name> instead of failing; used when a failed step is
#              retried. It never touches another run's record or file.
#
#   list       prints a JSON array of records, each with an added "run_status" field, sorted by created_at, then
#              run_id, then name. --workflow and --run filter and combine. No match prints [] and exits 0.
#   get        prints one JSON record. With --run it returns that run's record whatever the run's status (an
#              explicit run id is an explicit request). Without --run it behaves as latest.
#   latest     prints the record from the most recent COMPLETED run that produced <name> ("most recent" is that
#              record's created_at, tie-broken by run_id). A run that is failed, cancelled, running, paused,
#              awaiting_confirmation or unknown (its state cannot be read) is skipped.
#   --path     (get and latest) print only the absolute path of the published file instead of the record.
#
#   run_status is read at query time from `run-state.sh status <run_id>` (the "status" field of its state JSON);
#   it is never stored in the registry. A run whose state cannot be read is "unknown": list shows it, latest
#   skips it.
#
# ---------------------------------------------------------------------------
# LAYOUT (under <artifacts> = whatever `scripts/resolve-root.sh get workflow_artifacts` prints)
# ---------------------------------------------------------------------------
#   <artifacts>/<workflow_id>/<run_id>/<name>          the published file (artifact: the rendered file;
#                                                      data: the value)
#   <artifacts>/<workflow_id>/<run_id>/outputs.jsonl   one JSON record per output, append-only per run
#
# One directory per run is what guarantees a re-run never overwrites an earlier run's output. A record is one
# compact JSON object per line with exactly these 9 fields:
#   {"workflow_id","run_id","step_id","name","kind","type","path","created_at","sha256"}
# `path` is "<workflow_id>/<run_id>/<name>", relative to <artifacts> so it survives relocating the tree;
# `created_at` is UTC ISO 8601; `sha256` is the hash of the published file (shasum -a 256, falling back to
# sha256sum).
#
# ---------------------------------------------------------------------------
# RULES
# ---------------------------------------------------------------------------
#   - <workflow_id>, <run_id>, <step_id> and <name> match ^[A-Za-z0-9][A-Za-z0-9._-]*$ (no "/", no "..", no
#     leading "."), so a name can never escape the run directory. The name "outputs.jsonl" (and anything that
#     starts with "outputs.jsonl.") is reserved for the registry itself.
#   - Registering a <name> already recorded for that run fails unless --replace is given.
#   - Crash-safe: the file is written to a temporary name in the run directory and renamed; the outputs.jsonl
#     update is a read-modify-write of a temporary file then a rename, taken under scripts/with-lock.sh on
#     outputs.jsonl. A lock timeout aborts without writing the file or the record (WITH_LOCK_TIMEOUT_SECONDS
#     applies). The only thing created before the lock is the run directory the lock lives in.
#   - Directories are created only under <artifacts>. This script creates no file anywhere else.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0  registered; the record is on stdout
#   1  rejected: bad id, name, kind or type, missing --file, or the name is already recorded (no --replace);
#      nothing was written
#   2  usage error (missing or unknown argument)
#   3  the artifacts root cannot be resolved (resolve-root.sh's message is passed on)
#   4  the lock could not be acquired, or the file or record could not be written; nothing was left behind
#      that a retry would trip over
#   5  get or latest found nothing to return (unknown workflow, unknown name, no such run, or no completed run);
#      a message naming what is missing is on stderr and nothing is printed on stdout
#
# Compatible with macOS bash 3.2 (no associative arrays, no mapfile) and safe under `set -u`. Needs jq.
# ---------------------------------------------------------------------------

set -u

_AR_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
_AR_RESOLVE_ROOT="$_AR_DIR/../resolve-root.sh"
_AR_WITH_LOCK="$_AR_DIR/../with-lock.sh"
_AR_RUN_STATE="$_AR_DIR/run-state.sh"
_AR_ID_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'

_ar_err() {
  printf '%s\n' "$*" >&2
}

_ar_usage() {
  sed -n '/^# USAGE/,/^# LAYOUT/p' "${BASH_SOURCE[0]}" | sed -e '1,2d' | sed -e '$d' | sed -e '$d' -e 's/^# \{0,1\}//'
}

# Succeeds when $1 is a legal id or name token.
_ar_valid_token() {
  [[ $1 =~ $_AR_ID_RE ]]
}

# True for the names the registry keeps for itself (the index file and its temporary or lock siblings).
_ar_reserved() {
  case "$1" in outputs.jsonl|outputs.jsonl.*) return 0 ;; esac
  return 1
}

# Prints the SHA-256 of file $1.
_ar_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

_ar_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# The part that runs UNDER the lock. Arguments: root workflow_id run_id step_id name kind type file replace(0|1)
# Everything it writes goes through a temporary name in the run directory and a rename.
_ar_commit() {
  local root="$1" wf="$2" run="$3" step="$4" name="$5" kind="$6" type="$7" src="$8" replace="$9"
  local dir="$root/$wf/$run" index="$root/$wf/$run/outputs.jsonl"
  local tmp_file="$dir/.$name.tmp.$$" tmp_index="$dir/.outputs.jsonl.tmp.$$"
  local hash record exists=0

  # The trap fires when the script exits, after this function's locals are gone, so it reads globals.
  _AR_TMP_FILE="$tmp_file"
  _AR_TMP_INDEX="$tmp_index"
  trap 'rm -f -- "${_AR_TMP_FILE:-}" "${_AR_TMP_INDEX:-}"' EXIT

  if [ -f "$index" ] && jq -e --arg n "$name" 'select(.name == $n)' "$index" >/dev/null 2>&1; then
    exists=1
  fi
  if [ "$exists" -eq 1 ] && [ "$replace" -ne 1 ]; then
    _ar_err "Error: output '$name' is already registered for run '$run' of workflow '$wf'; use --replace to swap it"
    return 1
  fi

  hash=$(_ar_sha256 "$src") && [ -n "$hash" ] || { _ar_err "Error: cannot compute a SHA-256 (need shasum or sha256sum)"; return 4; }

  record=$(jq -n -c \
    --arg workflow_id "$wf" --arg run_id "$run" --arg step_id "$step" --arg name "$name" \
    --arg kind "$kind" --arg type "$type" --arg path "$wf/$run/$name" --arg created_at "$(_ar_now)" \
    --arg sha256 "$hash" \
    '{workflow_id:$workflow_id,run_id:$run_id,step_id:$step_id,name:$name,kind:$kind,type:$type,path:$path,created_at:$created_at,sha256:$sha256}') \
    || { _ar_err "Error: could not build the record for '$name'"; return 4; }

  # Stage both the file and the new index, and only then rename, file first: a crash between the two leaves a
  # file with no record (a retry with --replace or a fresh name is clean), never a record with no file.
  cp "$src" "$tmp_file" 2>/dev/null || { _ar_err "Error: could not copy '$src' into the registry"; return 4; }
  {
    if [ -f "$index" ]; then
      jq -c --arg n "$name" 'select(.name != $n)' "$index" || return 4
    fi
    printf '%s\n' "$record"
  } > "$tmp_index" || { _ar_err "Error: could not stage the registry index"; return 4; }

  mv -f "$tmp_file" "$dir/$name" 2>/dev/null || { _ar_err "Error: could not publish '$name'"; return 4; }
  mv -f "$tmp_index" "$index" 2>/dev/null || { _ar_err "Error: could not update the registry index"; return 4; }
  printf '%s\n' "$record"
  return 0
}

_ar_register() {
  local wf="" run="" step="" name="" kind="" type="" src="" replace=0 have_kind=0 have_type=0 have_file=0
  local pos=0 root dir rc

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --kind)    [ "$#" -ge 2 ] || { _ar_err "Usage error: --kind needs a value"; return 2; }; kind="$2"; have_kind=1; shift 2 ;;
      --type)    [ "$#" -ge 2 ] || { _ar_err "Usage error: --type needs a value"; return 2; }; type="$2"; have_type=1; shift 2 ;;
      --file)    [ "$#" -ge 2 ] || { _ar_err "Usage error: --file needs a value"; return 2; }; src="$2"; have_file=1; shift 2 ;;
      --replace) replace=1; shift ;;
      --*)       _ar_err "Usage error: unknown option '$1'"; return 2 ;;
      *)
        pos=$((pos + 1))
        case "$pos" in
          1) wf="$1" ;; 2) run="$1" ;; 3) step="$1" ;; 4) name="$1" ;;
          *) _ar_err "Usage error: unexpected argument '$1'"; return 2 ;;
        esac
        shift ;;
    esac
  done
  if [ "$pos" -ne 4 ] || [ "$have_kind" -ne 1 ] || [ "$have_type" -ne 1 ] || [ "$have_file" -ne 1 ]; then
    _ar_err "Usage: artifacts.sh register <workflow_id> <run_id> <step_id> <name> --kind artifact|data --type <type> --file <path> [--replace]"
    return 2
  fi

  local label val
  for label in workflow_id run_id step_id name type; do
    case "$label" in
      workflow_id) val="$wf" ;; run_id) val="$run" ;; step_id) val="$step" ;; name) val="$name" ;; type) val="$type" ;;
    esac
    if ! _ar_valid_token "$val"; then
      _ar_err "Error: invalid $label '$val': must match $_AR_ID_RE (no '/', no '..', no leading '.')"
      return 1
    fi
  done
  case "$name$wf$run$step" in *..*) _ar_err "Error: invalid id or name: '..' is not allowed"; return 1 ;; esac
  if _ar_reserved "$name"; then
    _ar_err "Error: the name '$name' is reserved for the registry index"
    return 1
  fi
  case "$kind" in
    artifact|data) ;;
    *) _ar_err "Error: invalid kind '$kind': must be 'artifact' or 'data'"; return 1 ;;
  esac
  if [ ! -f "$src" ]; then
    _ar_err "Error: --file '$src' is not an existing regular file"
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    _ar_err "Error: jq is required"
    return 4
  fi

  if [ ! -f "$_AR_RESOLVE_ROOT" ]; then
    _ar_err "Error: cannot resolve the artifacts root; $_AR_RESOLVE_ROOT is missing"
    return 3
  fi
  if ! root=$(bash "$_AR_RESOLVE_ROOT" get workflow_artifacts) || [ -z "$root" ]; then
    _ar_err "Error: cannot resolve the workflow artifacts root"
    return 3
  fi
  root="${root%/}"

  dir="$root/$wf/$run"
  mkdir -p "$dir" 2>/dev/null || { _ar_err "Error: could not create '$dir'"; return 4; }

  bash "$_AR_WITH_LOCK" "$dir/outputs.jsonl" -- \
    bash "${BASH_SOURCE[0]}" __commit "$root" "$wf" "$run" "$step" "$name" "$kind" "$type" "$src" "$replace"
  rc=$?
  case "$rc" in
    0|1|4) return "$rc" ;;
    2) _ar_err "Error: could not register '$name': the registry lock for run '$run' was not acquired"; return 4 ;;
    *) return 4 ;;
  esac
}

# ---------------------------------------------------------------------------------------------------------------
# Read side: list, get, latest
# ---------------------------------------------------------------------------------------------------------------

# Prints the lifecycle status of run $1 on one line, then (only when it is "unknown") the reason on a second line.
# Reads the state JSON that run-state.sh prints; never parses prose.
_ar_run_status() {
  local out rc st
  out=$(bash "$_AR_RUN_STATE" status "$1" 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    case "$rc" in
      3) printf 'unknown\nthe run state for run %s was not found\n' "$1" ;;
      0) printf 'unknown\nrun-state returned nothing for run %s\n' "$1" ;;
      *) printf 'unknown\nthe run state for run %s could not be read (run-state exit %s)\n' "$1" "$rc" ;;
    esac
    return 0
  fi
  st=$(printf '%s' "$out" | jq -r '.status // empty' 2>/dev/null)
  case "$st" in
    running|paused|awaiting_confirmation|failed|completed|cancelled) printf '%s\n' "$st" ;;
    *) printf 'unknown\nthe run state for run %s has no recognised status\n' "$1" ;;
  esac
}

# Resolves the artifacts root into _AR_ROOT (absolute, no trailing slash). Returns 3 when it cannot.
_ar_resolve_root() {
  local root
  if [ ! -f "$_AR_RESOLVE_ROOT" ]; then
    _ar_err "Error: cannot resolve the artifacts root; $_AR_RESOLVE_ROOT is missing"
    return 3
  fi
  if ! root=$(bash "$_AR_RESOLVE_ROOT" get workflow_artifacts) || [ -z "$root" ]; then
    _ar_err "Error: cannot resolve the workflow artifacts root"
    return 3
  fi
  root="${root%/}"
  case "$root" in /*) ;; *) root="$PWD/$root" ;; esac
  _AR_ROOT="$root"
  return 0
}

# Loads the records matching workflow $1 and run $2 (either may be empty = any) into _AR_RECS, a JSON array with
# "run_status" added, sorted by created_at, run_id, name. _AR_WHY is a JSON object run_id -> reason for the runs
# whose status is "unknown". Needs _AR_ROOT.
_ar_load() {
  local wf="$1" run="$2" wfg="*" run_g="*" f part raw="" rid st why map='{}' ids
  [ -z "$wf" ] || wfg="$wf"
  [ -z "$run" ] || run_g="$run"
  for f in "$_AR_ROOT"/$wfg/$run_g/outputs.jsonl; do
    [ -f "$f" ] || continue
    if part=$(jq -c 'select(type == "object")' "$f" 2>/dev/null); then
      [ -z "$part" ] || raw="$raw$part"$'\n'
    else
      _ar_err "warning: skipping unreadable registry index $f"
    fi
  done
  _AR_RECS=$(printf '%s' "$raw" | jq -s -c --arg wf "$wf" --arg run "$run" '
    map(select(((.workflow_id // "") | tostring) as $w | ((.run_id // "") | tostring) as $r
               | ($wf == "" or $w == $wf) and ($run == "" or $r == $run)))') || return 4
  _AR_WHY='{}'
  ids=$(printf '%s' "$_AR_RECS" | jq -r '.[].run_id // empty' | LC_ALL=C sort -u)
  while IFS= read -r rid; do
    [ -n "$rid" ] || continue
    st=$(_ar_run_status "$rid")
    why=$(printf '%s\n' "$st" | sed -n 2p)
    st=$(printf '%s\n' "$st" | sed -n 1p)
    map=$(printf '%s' "$map" | jq -c --arg r "$rid" --arg s "$st" '. + {($r): $s}')
    if [ "$st" = unknown ]; then
      _AR_WHY=$(printf '%s' "$_AR_WHY" | jq -c --arg r "$rid" --arg w "$why" '. + {($r): $w}')
    fi
  done <<< "$ids"
  _AR_RECS=$(printf '%s' "$_AR_RECS" | jq -c --argjson st "$map" '
    map(. + {run_status: ($st[.run_id | tostring] // "unknown")})
    | sort_by([.created_at, .run_id, .name])') || return 4
  return 0
}

# Parses the arguments of a read command into _AR_OPT_WF, _AR_OPT_RUN, _AR_OPT_PATH, _AR_NPOS and the positionals
# _AR_POS1/_AR_POS2. $1 is the command name, $2 the maximum number of positionals, $3 the options it accepts
# (space separated, from: workflow run path); the rest are the arguments.
_ar_parse_read() {
  local cmd="$1" maxpos="$2" allowed=" $3 " pos=0
  shift 3
  _AR_OPT_WF=""; _AR_OPT_RUN=""; _AR_OPT_PATH=0; _AR_POS1=""; _AR_POS2=""; _AR_NPOS=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --workflow|--run)
        case "$allowed" in *" ${1#--} "*) ;; *) _ar_err "Usage error: '$1' is not an option of $cmd"; return 2 ;; esac
        [ "$#" -ge 2 ] || { _ar_err "Usage error: $1 needs a value"; return 2; }
        if [ "$1" = "--workflow" ]; then _AR_OPT_WF="$2"; else _AR_OPT_RUN="$2"; fi
        shift 2 ;;
      --path)
        case "$allowed" in *" path "*) ;; *) _ar_err "Usage error: '--path' is not an option of $cmd"; return 2 ;; esac
        _AR_OPT_PATH=1; shift ;;
      --*) _ar_err "Usage error: unknown option '$1'"; return 2 ;;
      *)
        pos=$((pos + 1))
        if [ "$pos" -gt "$maxpos" ]; then _ar_err "Usage error: unexpected argument '$1'"; return 2; fi
        if [ "$pos" -eq 1 ]; then _AR_POS1="$1"; else _AR_POS2="$1"; fi
        shift ;;
    esac
  done
  _AR_NPOS="$pos"
  return 0
}

# Takes label/value pairs; rejects (exit 1) any non-empty value that is not a legal token.
_ar_check_tokens() {
  local label val
  while [ "$#" -ge 2 ]; do
    label="$1"; val="$2"; shift 2
    if [ -n "$val" ] && ! _ar_valid_token "$val"; then
      _ar_err "Error: invalid $label '$val': must match $_AR_ID_RE (no '/', no '..', no leading '.')"
      return 1
    fi
  done
  return 0
}

_ar_need_jq() {
  command -v jq >/dev/null 2>&1 || { _ar_err "Error: jq is required"; return 4; }
}

_ar_list() {
  _ar_parse_read list 0 "workflow run" "$@" || return $?
  _ar_check_tokens workflow_id "$_AR_OPT_WF" run_id "$_AR_OPT_RUN" || return $?
  _ar_need_jq || return $?
  _ar_resolve_root || return $?
  _ar_load "$_AR_OPT_WF" "$_AR_OPT_RUN" || { _ar_err "Error: could not read the registry"; return 4; }
  printf '%s' "$_AR_RECS" | jq .
}

# Prints one record (or, with want_path=1, the absolute path of its file) for get and latest.
# Arguments: workflow name run (empty = the latest completed run) want_path
_ar_select() {
  local wf="$1" name="$2" run="$3" want_path="$4" rec cands n summary why file
  _ar_need_jq || return $?
  _ar_resolve_root || return $?
  _ar_load "$wf" "" || { _ar_err "Error: could not read the registry"; return 4; }

  if [ "$(printf '%s' "$_AR_RECS" | jq 'length')" -eq 0 ]; then
    _ar_err "Error: workflow '$wf' has no registered outputs"
    return 5
  fi
  cands=$(printf '%s' "$_AR_RECS" | jq -c --arg n "$name" 'map(select(.name == $n))')
  n=$(printf '%s' "$cands" | jq 'length')
  if [ "$n" -eq 0 ]; then
    _ar_err "Error: workflow '$wf' has no output named '$name'"
    return 5
  fi

  if [ -n "$run" ]; then
    rec=$(printf '%s' "$cands" | jq -c --arg r "$run" 'map(select(.run_id == $r)) | .[0] // empty')
    if [ -z "$rec" ]; then
      _ar_err "Error: run '$run' of workflow '$wf' has no output named '$name'"
      return 5
    fi
  else
    rec=$(printf '%s' "$cands" | jq -c 'map(select(.run_status == "completed")) | sort_by([.created_at, .run_id]) | last // empty')
    if [ -z "$rec" ]; then
      summary=$(printf '%s' "$cands" | jq -r 'group_by(.run_status) | map("\(.[0].run_status)=\(length)") | join(", ")')
      why=$(printf '%s' "$cands" | jq -r --argjson why "$_AR_WHY" '[.[] | select(.run_status == "unknown") | $why[.run_id]] | unique | join("; ")')
      _ar_err "Error: output '$name' of workflow '$wf' exists in $n run(s) but none belongs to a completed run ($summary)${why:+; $why}"
      return 5
    fi
  fi

  if [ "$want_path" -eq 1 ]; then
    file="$_AR_ROOT/$(printf '%s' "$rec" | jq -r '.path')"
    if [ ! -f "$file" ]; then
      _ar_err "Error: the record for '$name' points at '$file', which does not exist"
      return 5
    fi
    printf '%s\n' "$file"
  else
    printf '%s' "$rec" | jq .
  fi
  return 0
}

_ar_get() {
  _ar_parse_read get 2 "run path" "$@" || return $?
  if [ "$_AR_NPOS" -ne 2 ]; then
    _ar_err "Usage: artifacts.sh get <workflow_id> <name> [--run <run_id>] [--path]"
    return 2
  fi
  _ar_check_tokens workflow_id "$_AR_POS1" name "$_AR_POS2" run_id "$_AR_OPT_RUN" || return $?
  _ar_select "$_AR_POS1" "$_AR_POS2" "$_AR_OPT_RUN" "$_AR_OPT_PATH"
}

_ar_latest() {
  _ar_parse_read latest 2 "path" "$@" || return $?
  if [ "$_AR_NPOS" -ne 2 ]; then
    _ar_err "Usage: artifacts.sh latest <workflow_id> <name> [--path]"
    return 2
  fi
  _ar_check_tokens workflow_id "$_AR_POS1" name "$_AR_POS2" || return $?
  _ar_select "$_AR_POS1" "$_AR_POS2" "" "$_AR_OPT_PATH"
}

main() {
  if [ "$#" -eq 0 ]; then
    _ar_err "Usage: artifacts.sh register|list|get|latest ... (artifacts.sh --help)"
    return 2
  fi
  case "$1" in
    -h|--help) _ar_usage; return 0 ;;
    register) shift; _ar_register "$@"; return $? ;;
    list) shift; _ar_list "$@"; return $? ;;
    get) shift; _ar_get "$@"; return $? ;;
    latest) shift; _ar_latest "$@"; return $? ;;
    __commit) shift; _ar_commit "$@"; return $? ;;
    *) _ar_err "Usage error: unknown subcommand '$1'"; return 2 ;;
  esac
}

main "$@"
exit $?
