#!/usr/bin/env bash
# conventions-suggest.sh - the non-blocking "run j.conventions" tip shown at the end of j.init and `j.uncharted onboard`
# (E69_S05_T06).
#
# Usage:
#   scripts/conventions-suggest.sh
#
# Prints ONE line, `Tip: run j.conventions to record this project's conventions (commit format, naming, formatting,
# ...).`, when no "<configs>/conventions.json" exists; prints nothing when one does. <configs> is located through
# scripts/resolve-root.sh get configs (JENGA_PROJECT_ROOT honoured). If the configs path cannot be resolved the
# script cannot know whether conventions are recorded, so it prints nothing.
#
# It ALWAYS exits 0. Every error (an unresolvable path, an unreadable or garbled configs directory, a missing
# resolver, anything unexpected) is swallowed, so calling it can never change the exit status of the skill that calls
# it, and nothing it does can halt that skill. It reads one path's existence and writes nothing.
#
# Compatible with macOS bash 3.2.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

suggest() {
  local cfg
  [ -n "$here" ] || return 0
  cfg="$(bash "$here/resolve-root.sh" get configs 2>/dev/null)" || return 0
  [ -n "$cfg" ] || return 0
  if [ ! -e "$cfg/conventions.json" ]; then
    printf '%s\n' "Tip: run j.conventions to record this project's conventions (commit format, naming, formatting, ...)."
  fi
  return 0
}

suggest 2>/dev/null || true
exit 0
