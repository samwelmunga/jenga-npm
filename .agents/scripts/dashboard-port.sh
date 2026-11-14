#!/usr/bin/env bash
# scripts/dashboard-port.sh - stable per-project dashboard port (E47_S11_T01)
#
# The dashboard's browser state (localStorage) is keyed by origin, port included, so each project gets one
# port that is generated once, stored in project/configs/dashboard-config.json (key `dashboard_port`) and
# preferred at start.
#
# Scheme (approved 2026-11-12, Candidate A): port = PP*1000 + NNN, PP in 50..64, NNN in 000..999 (random).
# Every possible port is 50000..64999, inside 1024..65535. Further ports for the same project count the
# prefix up (PP+1, same NNN) and are capped at PP = 64. The range overlaps the macOS/Windows ephemeral range
# (49152-65535), so `ensure` prefers a currently-free port when it generates; the consumer still verifies at start.
#
# Usage:
#   dashboard-port.sh get          print the stored port; exit 1 (reason on stderr) when missing or invalid
#   dashboard-port.sh ensure       print the stored port; when missing or invalid, generate and store one first
#                                  (idempotent: a valid stored port is never changed)
#   dashboard-port.sh next <n>     print the n-th additional port (n >= 1) for the stored port; exit 3 past the cap
#
# Exit codes: 0 ok, 1 stored port missing/invalid (get, next), 2 usage error, 3 cap exceeded,
#             6 configs directory unresolvable or the file could not be written.
#
# Environment:
#   JENGA_PROJECT_ROOT              see scripts/resolve-root.sh
#   JENGA_DASHBOARD_PORT_CANDIDATE  (tests) first candidate `ensure` tries before random ones
#
# Compatible with macOS bash 3.2. Writes are atomic (temp file in the target directory, then mv).

set -u

PORT_MIN=50000
PORT_MAX=64999
PREFIX_MAX=64
KEY="dashboard_port"
FREE_TRIES=50

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

err() { printf 'dashboard-port.sh: %s\n' "$*" >&2; }

configs_dir() {
  local d
  d="$("$here/resolve-root.sh" get configs 2>/dev/null)" || return 1
  [ -n "$d" ] || return 1
  printf '%s\n' "$d"
}

# valid_port <value>: integer (no sign, no leading zero) within PORT_MIN..PORT_MAX
valid_port() {
  case "$1" in
    ''|*[!0-9]*|0*) return 1 ;;
  esac
  [ "${#1}" -le 5 ] || return 1
  [ "$1" -ge "$PORT_MIN" ] && [ "$1" -le "$PORT_MAX" ]
}

# read_port <file>: prints the raw stored value (empty if file/key missing or unparsable)
read_port() {
  [ -f "$1" ] || return 0
  jq -r --arg k "$KEY" 'if type == "object" and (.[$k] | type) == "number" and (.[$k] == (.[$k] | floor)) then .[$k] | tostring else empty end' "$1" 2>/dev/null
}

port_is_free() {
  command -v node >/dev/null 2>&1 || return 0
  node "$here/find-free-port.cjs" --check "$1" >/dev/null 2>&1
}

generate_port() {
  local nnn pp candidate i=0
  nnn=$((RANDOM % 1000))
  if [ -n "${JENGA_DASHBOARD_PORT_CANDIDATE:-}" ] && valid_port "$JENGA_DASHBOARD_PORT_CANDIDATE"; then
    candidate=$JENGA_DASHBOARD_PORT_CANDIDATE
    if port_is_free "$candidate"; then printf '%s\n' "$candidate"; return 0; fi
  fi
  while [ "$i" -lt "$FREE_TRIES" ]; do
    pp=$((50 + RANDOM % 15))
    nnn=$((RANDOM % 1000))
    candidate=$((pp * 1000 + nnn))
    if port_is_free "$candidate"; then printf '%s\n' "$candidate"; return 0; fi
    i=$((i + 1))
  done
  # Every probe was busy: still return a valid port; the consumer verifies freedom at start.
  printf '%s\n' "$candidate"
}

write_port() { # write_port <file> <port>
  local file="$1" port="$2" tmp
  tmp="$(mktemp "${file}.XXXXXX")" || return 1
  if [ -f "$file" ] && jq -e 'type == "object"' "$file" >/dev/null 2>&1; then
    jq --arg k "$KEY" --argjson v "$port" '.[$k] = $v' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  else
    printf '{\n  "%s": %s\n}\n' "$KEY" "$port" > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  chmod 644 "$tmp" 2>/dev/null
  mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

describe_problem() { # describe_problem <file> <raw>
  if [ ! -f "$1" ]; then err "$1 does not exist"
  elif [ -z "$2" ]; then err "$KEY is missing or not an integer in $1"
  else err "$KEY $2 in $1 is outside $PORT_MIN-$PORT_MAX"; fi
}

cmd_get() {
  local dir file raw
  dir="$(configs_dir)" || { err "cannot resolve the configs directory"; return 6; }
  file="$dir/dashboard-config.json"
  raw="$(read_port "$file")"
  if valid_port "$raw"; then printf '%s\n' "$raw"; return 0; fi
  describe_problem "$file" "$raw"
  return 1
}

cmd_ensure_locked() {
  local dir file raw port
  dir="$(configs_dir)" || { err "cannot resolve the configs directory"; return 6; }
  file="$dir/dashboard-config.json"
  raw="$(read_port "$file")"
  if valid_port "$raw"; then printf '%s\n' "$raw"; return 0; fi
  port="$(generate_port)"
  mkdir -p "$dir" 2>/dev/null
  write_port "$file" "$port" || { err "could not write $file"; return 6; }
  printf '%s\n' "$port"
}

cmd_ensure() {
  local dir
  dir="$(configs_dir)" || { err "cannot resolve the configs directory"; return 6; }
  mkdir -p "$dir" 2>/dev/null
  "$here/with-lock.sh" "$dir/dashboard-config.json" -- bash "${BASH_SOURCE[0]}" _ensure
}

cmd_next() {
  local n="${1:-}" port pp nnn
  case "$n" in ''|*[!0-9]*|0*) err "next takes a positive integer"; return 2 ;; esac
  [ "${#n}" -le 3 ] || { err "next: $n exceeds the cap (prefix $PREFIX_MAX)"; return 3; }
  port="$(cmd_get)" || return $?
  pp=$((port / 1000))
  nnn=$((port % 1000))
  if [ $((pp + n)) -gt "$PREFIX_MAX" ]; then
    err "next $n from $port needs prefix $((pp + n)); the cap is $PREFIX_MAX"
    return 3
  fi
  printf '%s\n' $(((pp + n) * 1000 + nnn))
}

command -v jq >/dev/null 2>&1 || { err "jq is required"; exit 6; }

case "${1:-}" in
  get) [ "$#" -eq 1 ] || { err "usage: get"; exit 2; }; cmd_get; exit $? ;;
  ensure) [ "$#" -eq 1 ] || { err "usage: ensure"; exit 2; }; cmd_ensure; exit $? ;;
  _ensure) cmd_ensure_locked; exit $? ;;
  next) [ "$#" -eq 2 ] || { err "usage: next <n>"; exit 2; }; cmd_next "$2"; exit $? ;;
  *) err "usage: dashboard-port.sh get | ensure | next <n>"; exit 2 ;;
esac
