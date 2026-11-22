#!/usr/bin/env bash
# skills/j-workflow-recorder/scripts/check-recorder-hook.sh - is the recorder's UserPromptSubmit hook registered?
# SHIM: it holds no hook-matching logic. The check is scripts/settings-doctor.sh --fragment workflow-recorder
# (epic E100, task E100_S05_T03); this script only keeps the contract j.workflow-recorder start relies on.
#
# Usage: check-recorder-hook.sh [--project-dir <dir>] [--home <dir>]
#
# Exit 0 and "registered: <file>" on stdout when the hook is registered in a layer Claude Code reads.
# Exit 1 and a plain explanation with the fix when it is not. Exit 2 on a usage error, or when the doctor or jq
# cannot be found (never reported as registered). Layers and matching rules: the header of settings-doctor.sh.
# smoke-invoke: --help
set -uo pipefail

SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT=""; HOME_DIR="${HOME:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir) PROJECT="${2:-}"; shift 2 ;;
    --home)        HOME_DIR="${2:-}"; shift 2 ;;
    -h|--help)     sed -n '2,/^# smoke-invoke/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "check-recorder-hook.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

ROOT=""
if [[ -f "$SELF/../../index/scripts/package-root.sh" ]]; then
  . "$SELF/../../index/scripts/package-root.sh" 2>/dev/null
  ROOT="$(jenga_package_root "$SELF" 2>/dev/null)" || ROOT=""
fi
DOCTOR="$ROOT/scripts/settings-doctor.sh"
if [[ -z "$ROOT" || ! -f "$DOCTOR" ]]; then
  echo "check-recorder-hook.sh: settings-doctor.sh not found (is @jenga-ai/agent installed?)" >&2; exit 2
fi

[[ -n "$PROJECT" ]] || PROJECT="${CLAUDE_PROJECT_DIR:-}"
[[ -n "$PROJECT" ]] || PROJECT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

OUT="$(bash "$DOCTOR" --fragment workflow-recorder --project-dir "$PROJECT" --home "$HOME_DIR" 2>/dev/null)"; RC=$?
case "$RC" in
  0) FILE="$(printf '%s\n' "$OUT" | sed -n 's/.*: active (\(.*\))$/\1/p' | head -n 1)"
     [[ -n "$FILE" ]] || { echo "check-recorder-hook.sh: the doctor reported no active layer" >&2; exit 2; }
     echo "registered: $FILE"; exit 0 ;;
  1) cat <<MSG
The recorder's UserPromptSubmit hook (on_recording_step.sh) is not registered, so a recording started now would
capture nothing. Checked: $PROJECT/.claude/settings.json $PROJECT/.claude/settings.local.json ${HOME_DIR:+$HOME_DIR/.claude/settings.json}
To fix it, run:  npx jenga sync   (it adds the missing hook to $PROJECT/.claude/settings.json and leaves your own hooks alone)
Then restart Claude Code: hooks are read at session start. The restart loses this session's recording pointer, so
run j.workflow-recorder start again afterwards.
MSG
     exit 1 ;;
  *) echo "check-recorder-hook.sh: the settings doctor failed (exit $RC)" >&2; exit 2 ;;
esac
