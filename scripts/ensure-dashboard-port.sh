#!/usr/bin/env bash
# scripts/ensure-dashboard-port.sh - call-site wrapper for the dashboard port allocator (E47_S11_T02)
#
# j.init (and the maintainer-only distribute script) both need "make sure this project has a valid dashboard port, report what
# happened". The allocation itself lives in scripts/dashboard-port.sh (E47_S11_T01); this wrapper only
# locates it, classifies the prior state and prints one report line, so the two call sites stay identical.
#
# Usage:
#   ensure-dashboard-port.sh [--dry-run] <project_root>
#
# Output (one line on stdout):
#   dashboard-port: kept <port>        a valid port was already stored; nothing written
#   dashboard-port: generated <port>   no usable file/key; a port was generated and stored
#   dashboard-port: repaired <port>    a stored value was invalid (out of range / not an integer); replaced
#   dashboard-port: skipped (<why>)    no Jenga registry in <project_root>, or the allocator was not found
#   --dry-run: "would generate"/"would repair" instead, and nothing is written.
#
# A valid stored port is never changed, and no value is ever read from the repository that runs this
# script: the target's own project/configs/dashboard-config.json is the only file consulted or written.
#
# Exit codes: 0 reported (including skipped), 2 usage error, 6 the allocator failed. Callers treat 6 as a warning.
# Compatible with macOS bash 3.2.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY=0
ROOT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    -*) echo "ensure-dashboard-port.sh: unknown option $1" >&2; exit 2 ;;
    *) [ -z "$ROOT" ] || { echo "ensure-dashboard-port.sh: unexpected argument $1" >&2; exit 2; }; ROOT="$1" ;;
  esac
  shift
done
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "usage: ensure-dashboard-port.sh [--dry-run] <project_root>" >&2; exit 2; }
ROOT="$(cd "$ROOT" && pwd)"

# Allocator lookup: next to this wrapper (monorepo checkout, .claude/ or .agents/ mirror), then the
# consumer install layout, relative to the current directory and to the target project.
ALLOC=""
for c in "$here/dashboard-port.sh" \
         "$PWD/node_modules/@jenga-ai/agent/scripts/dashboard-port.sh" \
         "$ROOT/node_modules/@jenga-ai/agent/scripts/dashboard-port.sh"; do
  if [ -f "$c" ]; then ALLOC="$c"; break; fi
done
if [ -z "$ALLOC" ]; then
  echo "dashboard-port: skipped (dashboard-port.sh not found)"
  exit 0
fi

tree=""
for t in project .project; do
  [ -f "$ROOT/$t/configs/workflow.json" ] && { tree="$t"; break; }
done
if [ -z "$tree" ]; then
  echo "dashboard-port: skipped (no $ROOT/project/configs/workflow.json; not a Jenga project)"
  exit 0
fi

export JENGA_PROJECT_ROOT="$ROOT"

if port="$(bash "$ALLOC" get 2>/dev/null)"; then
  echo "dashboard-port: kept $port"
  exit 0
fi

file="$ROOT/$tree/configs/dashboard-config.json"
state="generated"
if [ -f "$file" ] && command -v jq >/dev/null 2>&1 && jq -e 'type == "object" and has("dashboard_port")' "$file" >/dev/null 2>&1; then
  state="repaired"
fi

if [ "$DRY" -eq 1 ]; then
  echo "dashboard-port: would $([ "$state" = repaired ] && echo repair || echo generate)"
  exit 0
fi

if port="$(bash "$ALLOC" ensure 2>/dev/null)"; then
  echo "dashboard-port: $state $port"
  exit 0
fi
echo "dashboard-port: failed to $([ "$state" = repaired ] && echo repair || echo generate) a port in $file" >&2
exit 6
