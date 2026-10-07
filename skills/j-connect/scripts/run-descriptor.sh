#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# skills/j-connect/scripts/run-descriptor.sh
#
# Executes a j.connect service descriptor (project/documentation/service-descriptor.md) step by
# step and reports machine-readable results (E65_S01_T05).
#
# Usage:
#   run-descriptor.sh <descriptor.json> [--step <name>] [--continue]
#                     [--allow-install] [--project-root <dir>]
#                     [--descriptors-dir <dir>]
#
#   --step <name>        run one step only: detect | install | auth |
#                        register_mcp | verify (prerequisites are not run)
#   --continue           keep going after a fail / needs-user-action (default:
#                        stop at the first one; later steps usually depend on it)
#   --allow-install      let the install step actually run the package manager.
#                        Without it a missing tool yields needs-user-action
#                        (docs URL + what would run). Installs change the
#                        machine, so they are opt-in.
#   --project-root <d>   where .mcp.json / the secrets env file live
#                        (default: git toplevel, else $PWD)
#   --descriptors-dir <d> where `requires` ids are resolved as <id>.json
#                        (default: the descriptor's own directory, then
#                        ../descriptors next to this script)
#
# Output (stdout): one compact JSON object per line.
#   step:    {"descriptor":"<id>","step":"<name>","status":"pass|fail|skipped|needs-user-action","message":"..."[,"detail":"..."]}
#   summary: {"summary":true,"descriptor":"<id>","status":"...","counts":{...},"steps":N}
# Human-readable diagnostics go to stderr only. Output of the descriptor's own
# commands (detect/auth/verify/install) is discarded or sent to stderr, never
# stdout, so a tool that prints a token cannot leak it into the results.
#
# Exit: 0 pass; 1 any fail; 3 needs-user-action (no fail); 2 usage error or
#       invalid descriptor (rejected before any step runs).
#
# Rules this script enforces:
#   - Verify by execution: detect/auth.check/verify run the tool (argv array,
#     stdin closed, output discarded) and are judged by exit status only.
#   - Skip if satisfied: a passing check makes install/auth/register report skipped.
#   - Human steps (browser auth, setting a token) print what to do and return
#     needs-user-action; consent is never attempted.
#   - `requires` prerequisites run once per invocation; later references reuse
#     the result (also across a diamond: A -> B,C ; B -> C).
#   - Unknown platform / no usable package manager: print the descriptor's docs
#     URL, return needs-user-action, run NO install command, never guess one.
#   - Secrets: only env-var NAMES appear. Before the env-token auth step writes
#     the secrets env file it calls ensure-secret-safe.sh and aborts the step as
#     fail if that refuses. Env values are never read into output.
#   - The package-manager invocation is built only from descriptor fields
#     (manager + bare unpinned package name); there are no vendor commands here.
#
# Test seams: JENGA_CONNECT_PLATFORM overrides platform detection (darwin|linux|
# anything else = unknown); otherwise `uname -s` is used (stub-able on PATH).
# -----------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE="$SCRIPT_DIR/validate-descriptor.sh"
REGISTER="$SCRIPT_DIR/register-mcp.sh"
GUARD="$SCRIPT_DIR/ensure-secret-safe.sh"

DESCRIPTOR=""
ONLY_STEP=""
CONTINUE=0
ALLOW_INSTALL=0
ROOT=""
DESC_DIR=""

usage_err() { echo "run-descriptor: $1" >&2; echo "Usage: $(basename "$0") <descriptor.json> [--step <name>] [--continue] [--allow-install] [--project-root <dir>] [--descriptors-dir <dir>]" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --step)            [ $# -ge 2 ] || usage_err "--step needs a value"; ONLY_STEP="$2"; shift 2 ;;
    --continue)        CONTINUE=1; shift ;;
    --allow-install)   ALLOW_INSTALL=1; shift ;;
    --project-root)    [ $# -ge 2 ] || usage_err "--project-root needs a value"; ROOT="$2"; shift 2 ;;
    --descriptors-dir) [ $# -ge 2 ] || usage_err "--descriptors-dir needs a value"; DESC_DIR="$2"; shift 2 ;;
    -h|--help)         sed -n '/^# Usage:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)                usage_err "unknown option: $1" ;;
    *)                 [ -z "$DESCRIPTOR" ] || usage_err "unexpected argument: $1"; DESCRIPTOR="$1"; shift ;;
  esac
done

[ -n "$DESCRIPTOR" ] || usage_err "a descriptor file is required"
[ -f "$DESCRIPTOR" ] || usage_err "descriptor not found: $DESCRIPTOR"
case "$ONLY_STEP" in
  ""|detect|install|auth|register_mcp|verify) ;;
  *) usage_err "--step must be one of detect, install, auth, register_mcp, verify" ;;
esac
command -v jq >/dev/null 2>&1 || usage_err "jq is required but not found on PATH"

DESCRIPTOR="$(cd "$(dirname "$DESCRIPTOR")" && pwd)/$(basename "$DESCRIPTOR")"
[ -n "$DESC_DIR" ] || DESC_DIR="$(dirname "$DESCRIPTOR")"
[ -d "$DESC_DIR" ] || usage_err "descriptors dir not found: $DESC_DIR"
DESC_DIR="$(cd "$DESC_DIR" && pwd)"
if [ -z "$ROOT" ]; then ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; fi
[ -d "$ROOT" ] || usage_err "project root not found: $ROOT"
ROOT="$(cd "$ROOT" && pwd)"
cd "$ROOT" || exit 2

# ---- validate the top-level descriptor before ANY step runs -----------------
if ! VOUT="$(bash "$VALIDATE" "$DESCRIPTOR" 2>&1)"; then
  printf '%s\n' "$VOUT" >&2
  echo "run-descriptor: descriptor rejected; no step was run" >&2
  exit 2
fi

STATE="$(mktemp -d "${TMPDIR:-/tmp}/run-descriptor.XXXXXX")" || exit 2
trap 'rm -rf "$STATE"' EXIT

N_PASS=0; N_FAIL=0; N_SKIPPED=0; N_NEEDS=0; N_STEPS=0
STOP=0

# emit <descriptor-id> <step> <status> <message> [detail]
emit() {
  local d="$1" s="$2" st="$3" m="$4" det="${5:-}"
  N_STEPS=$((N_STEPS + 1))
  case "$st" in
    pass) N_PASS=$((N_PASS + 1)) ;;
    fail) N_FAIL=$((N_FAIL + 1)) ;;
    skipped) N_SKIPPED=$((N_SKIPPED + 1)) ;;
    needs-user-action) N_NEEDS=$((N_NEEDS + 1)) ;;
  esac
  if [ -n "$det" ]; then
    jq -cn --arg d "$d" --arg s "$s" --arg st "$st" --arg m "$m" --arg det "$det" \
      '{descriptor:$d, step:$s, status:$st, message:$m, detail:$det}'
  else
    jq -cn --arg d "$d" --arg s "$s" --arg st "$st" --arg m "$m" \
      '{descriptor:$d, step:$s, status:$st, message:$m}'
  fi
  if [ "$CONTINUE" -eq 0 ] && { [ "$st" = "fail" ] || [ "$st" = "needs-user-action" ]; }; then
    STOP=1
  fi
}

# run_check <file> <jq-path-to-argv>: run an argv array, judged by exit status only.
run_check() {
  local file="$1" path="$2" arg
  local -a argv=()
  while IFS= read -r arg; do argv+=("$arg"); done < <(jq -r "${path}[]" "$file")
  [ "${#argv[@]}" -gt 0 ] || return 1
  "${argv[@]}" >/dev/null 2>&1 </dev/null
}

detect_platform() {
  if [ -n "${JENGA_CONNECT_PLATFORM:-}" ]; then
    printf '%s' "$JENGA_CONNECT_PLATFORM" | tr '[:upper:]' '[:lower:]'
    return
  fi
  local u
  u="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  case "$u" in darwin|linux) printf '%s' "$u" ;; *) printf 'unknown' ;; esac
}

# Package-manager invocation for a supported manager; empty output = unsupported.
manager_install_argv() { # <manager> <package>
  case "$1" in
    brew) printf '%s\n' brew install "$2" ;;
    npm)  printf '%s\n' npm install -g "$2" ;;
  esac
}

step_wanted() { [ -z "$ONLY_STEP" ] || [ "$ONLY_STEP" = "$1" ]; }

run_descriptor() { # <file>
  local f="$1" id docs_url
  id="$(jq -r '.id' "$f")"
  docs_url="$(jq -r '.install.docs_url' "$f")"

  # ---- shared prerequisites, by reference, once per invocation -------------
  if [ -z "$ONLY_STEP" ]; then
    local req rfile rstatus
    while IFS= read -r req; do
      [ -n "$req" ] || continue
      [ "$STOP" -eq 0 ] || return 0
      if [ -f "$STATE/done.$req" ]; then
        rstatus="$(cat "$STATE/done.$req")"
        emit "$id" "requires:$req" "skipped" "prerequisite '$req' already ran in this invocation (result: $rstatus)"
        continue
      fi
      if [ -f "$STATE/active.$req" ]; then
        emit "$id" "requires:$req" "fail" "circular prerequisite: '$req' requires itself"
        continue
      fi
      rfile="$DESC_DIR/$req.json"
      if [ ! -f "$rfile" ] && [ -f "$SCRIPT_DIR/../descriptors/$req.json" ]; then rfile="$SCRIPT_DIR/../descriptors/$req.json"; fi
      if [ ! -f "$rfile" ]; then
        emit "$id" "requires:$req" "fail" "prerequisite descriptor '$req' not found (looked for $req.json in the descriptors dir)"
        continue
      fi
      if ! bash "$VALIDATE" "$rfile" >/dev/null 2>&1; then
        emit "$id" "requires:$req" "fail" "prerequisite descriptor '$req' failed validation"
        continue
      fi
      : > "$STATE/active.$req"
      local before_fail="$N_FAIL" before_needs="$N_NEEDS"
      run_descriptor "$rfile"
      rm -f "$STATE/active.$req"
      if [ "$N_FAIL" -gt "$before_fail" ]; then rstatus="fail"
      elif [ "$N_NEEDS" -gt "$before_needs" ]; then rstatus="needs-user-action"
      else rstatus="pass"; fi
      printf '%s' "$rstatus" > "$STATE/done.$req"
      if [ "$rstatus" = "pass" ]; then
        emit "$id" "requires:$req" "pass" "prerequisite '$req' satisfied"
      else
        emit "$id" "requires:$req" "$rstatus" "prerequisite '$req' did not complete ($rstatus)"
      fi
    done < <(jq -r '(.requires // [])[]' "$f")
  fi

  local present=0
  if run_check "$f" '.detect.command'; then present=1; fi

  # ---- detect ---------------------------------------------------------------
  if [ "$STOP" -eq 0 ] && step_wanted detect; then
    if [ "$present" -eq 1 ]; then
      emit "$id" detect pass "tool is present" present
    else
      emit "$id" detect pass "tool not found; the install step decides what to do" absent
    fi
  fi

  # ---- install ----------------------------------------------------------------
  if [ "$STOP" -eq 0 ] && step_wanted install; then
    if [ "$present" -eq 1 ]; then
      emit "$id" install skipped "already installed"
    else
      local platform method_manager="" method_pkg="" m_plat m_mgr m_pkg
      platform="$(detect_platform)"
      if [ "$platform" != "darwin" ] && [ "$platform" != "linux" ]; then
        emit "$id" install needs-user-action "platform not recognised; install it yourself, following the official instructions: $docs_url"
      else
        while IFS=$'\t' read -r m_plat m_mgr m_pkg; do
          [ "$m_plat" = "$platform" ] || continue
          if command -v "$m_mgr" >/dev/null 2>&1; then method_manager="$m_mgr"; method_pkg="$m_pkg"; break; fi
        done < <(jq -r '(.install.methods // [])[] | [.platform, .manager, .package] | @tsv' "$f")
        if [ -z "$method_manager" ]; then
          emit "$id" install needs-user-action "no usable package manager found for $platform in this descriptor; install it yourself, following the official instructions: $docs_url"
        elif [ "$ALLOW_INSTALL" -eq 0 ]; then
          emit "$id" install needs-user-action "not installed. Re-run with --allow-install to run '$method_manager' for package '$method_pkg', or install it yourself: $docs_url"
        else
          local -a iargv=()
          local a
          while IFS= read -r a; do iargv+=("$a"); done < <(manager_install_argv "$method_manager" "$method_pkg")
          if [ "${#iargv[@]}" -eq 0 ]; then
            emit "$id" install needs-user-action "package manager '$method_manager' is not supported by the runner; install it yourself: $docs_url"
          elif "${iargv[@]}" >&2 </dev/null; then
            if run_check "$f" '.detect.command'; then
              present=1
              emit "$id" install pass "installed via $method_manager"
            else
              emit "$id" install fail "$method_manager finished but the tool is still not detected; see $docs_url"
            fi
          else
            emit "$id" install fail "$method_manager install failed; see $docs_url"
          fi
        fi
      fi
    fi
  fi

  # ---- auth -------------------------------------------------------------------
  if [ "$STOP" -eq 0 ] && step_wanted auth; then
    local atype adocs ainstr env_var env_file
    atype="$(jq -r '.auth.type' "$f")"
    adocs="$(jq -r '.auth.docs_url // empty' "$f")"
    ainstr="$(jq -r '.auth.instructions // empty' "$f")"
    env_var="$(jq -r '.auth.env_var // empty' "$f")"
    env_file="$(jq -r '.secrets.env_file // empty' "$f")"
    if [ "$atype" = "none" ]; then
      emit "$id" auth skipped "service needs no authentication"
    elif run_check "$f" '.auth.check.command'; then
      emit "$id" auth skipped "already authenticated"
    elif [ "$atype" = "browser" ]; then
      emit "$id" auth needs-user-action "sign in yourself (an agent cannot complete browser consent). ${ainstr:+$ainstr }${adocs:+See: $adocs}"
    else
      # env-token: make a secret-bearing file safe BEFORE it is created/written.
      local note=""
      if [ -n "$env_file" ]; then
        if ! bash "$GUARD" "$env_file" "$ROOT" >&2; then
          emit "$id" auth fail "refused to prepare '$env_file': the secrets guardrail could not make it git-ignored"
          return 0
        fi
        if [ ! -e "$env_file" ] || ! grep -q "^${env_var}=" "$env_file" 2>/dev/null; then
          mkdir -p "$(dirname "$env_file")"
          printf '%s=\n' "$env_var" >> "$env_file"
        fi
        note=" A placeholder line for $env_var was added to $env_file (git-ignored); put your token there."
      fi
      emit "$id" auth needs-user-action "set the environment variable $env_var.${note} ${ainstr:+$ainstr }${adocs:+See: $adocs}"
    fi
  fi

  # ---- register_mcp ------------------------------------------------------------
  if [ "$STOP" -eq 0 ] && step_wanted register_mcp; then
    if [ "$(jq -r '.register_mcp.supported' "$f")" != "true" ]; then
      emit "$id" register_mcp skipped "service has no MCP server"
    else
      local rname rtype rcmd rurl a rres rstat
      local -a rargv=()
      rname="$(jq -r '.register_mcp.name' "$f")"
      rtype="$(jq -r '.register_mcp.type // "stdio"' "$f")"
      rargv=(--name "$rname" --type "$rtype" --project-root "$ROOT")
      if [ "$rtype" = "http" ]; then
        rurl="$(jq -r '.register_mcp.url' "$f")"; rargv+=(--url "$rurl")
      else
        rcmd="$(jq -r '.register_mcp.command' "$f")"; rargv+=(--command "$rcmd")
        while IFS= read -r a; do rargv+=(--arg "$a"); done < <(jq -r '(.register_mcp.args // [])[]' "$f")
      fi
      while IFS= read -r a; do rargv+=(--env-name "$a"); done < <(jq -r '(.register_mcp.env // [])[]' "$f")
      if rres="$(bash "$REGISTER" "${rargv[@]}" 2>/dev/null)"; then
        rstat="$(jq -r '.status' <<<"$rres")"
        case "$rstat" in
          unchanged) emit "$id" register_mcp skipped "already registered in .mcp.json" unchanged ;;
          updated)   emit "$id" register_mcp pass "updated the '$rname' entry in .mcp.json; approve the server in Claude Code if it shows as pending" updated ;;
          *)         emit "$id" register_mcp pass "registered '$rname' in .mcp.json; approve the server in Claude Code if it shows as pending" added ;;
        esac
      else
        emit "$id" register_mcp fail "registration failed: $(jq -r '.message // "see stderr"' <<<"$rres" 2>/dev/null)"
      fi
    fi
  fi

  # ---- verify ------------------------------------------------------------------
  if [ "$STOP" -eq 0 ] && step_wanted verify; then
    if run_check "$f" '.verify.command'; then
      emit "$id" verify pass "verification command succeeded"
    else
      emit "$id" verify fail "verification command failed"
    fi
  fi
  return 0
}

TOP_ID="$(jq -r '.id' "$DESCRIPTOR")"
: > "$STATE/active.$TOP_ID"
run_descriptor "$DESCRIPTOR"

if [ "$N_FAIL" -gt 0 ]; then OVERALL="fail"; CODE=1
elif [ "$N_NEEDS" -gt 0 ]; then OVERALL="needs-user-action"; CODE=3
else OVERALL="pass"; CODE=0; fi

jq -cn --arg d "$TOP_ID" --arg st "$OVERALL" --argjson steps "$N_STEPS" \
  --argjson p "$N_PASS" --argjson f "$N_FAIL" --argjson s "$N_SKIPPED" --argjson n "$N_NEEDS" \
  '{summary:true, descriptor:$d, status:$st, counts:{pass:$p, fail:$f, skipped:$s, "needs-user-action":$n}, steps:$steps}'
exit "$CODE"
