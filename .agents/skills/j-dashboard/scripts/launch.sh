#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# skills/j-dashboard/scripts/launch.sh
#
# Thin wrapper around project/app's `dashboard:start` / `dashboard:open` npm
# scripts (which themselves run project/app/ui/scripts/dashboard-start.cjs).
# It resolves the app directory and forwards flags unchanged; it introduces NO
# server-launch logic of its own.
#
# Usage:
#   launch.sh start [--port <n>] [--api-only]
#   launch.sh open  [--port <n>]
#
# `start` serves the UI alongside the API unless --api-only is given. `open`
# does the same and also opens the dashboard in the browser.
#
# Same symlink-resolution + repo-root derivation pattern used elsewhere in this
# skill library (e.g. skills/j-mirror-public/scripts/compute-publicize-diff.sh),
# so this script behaves identically whether invoked directly or via a symlink,
# and whether run from this monorepo or a mirrored/distributed copy.
# -----------------------------------------------------------------------------

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: launch.sh <start|open> [--port <n>] [--api-only]

  start       Run `npm run dashboard:start` in project/app (API + UI).
  open        Run `npm run dashboard:open` in project/app (API + UI, then the browser).

  --port <n>       Forwarded unchanged to the underlying npm script.
  --api-only       Forwarded unchanged; launches the API without the UI.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

if [ $# -lt 1 ]; then
  usage >&2
  die "missing mode argument"
fi

MODE="$1"
shift

case "$MODE" in
  start|open) ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; die "unknown mode: $MODE (expected start|open)" ;;
esac

# -----------------------------------------------------------------------------
# Locate script + repo root (symlink-resolved SCRIPT_DIR -> SKILL_DIR -> REPO_ROOT)
# -----------------------------------------------------------------------------

SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -h "$SCRIPT_PATH" ]; do
  LINK_TARGET="$(readlink "$SCRIPT_PATH")"
  case "$LINK_TARGET" in
    /*) SCRIPT_PATH="$LINK_TARGET" ;;
    *)  SCRIPT_PATH="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/$LINK_TARGET" ;;
  esac
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

# project/app is NOT always at the repo root: in a consumer install it ships
# inside the package, under node_modules/@jenga-ai/agent/. resolve-app-dir.sh
# owns that whole search (and is shared with snapshot.sh) — see its header.
# Invoked via `bash`, not executed directly: a shipped script losing its
# executable bit is exactly the packaging defect this change also fixes, and
# resolving the app dir must not be the thing that breaks when it happens.
APP_DIR="$(bash "$SCRIPT_DIR/resolve-app-dir.sh" --marker "package.json" --from "$(pwd)")" \
  || die "could not locate the dashboard app directory (see message above)"

# Forwarded verbatim via the "${FORWARD_ARGS[@]:-}" default-expansion form, not
# the bare "${FORWARD_ARGS[@]}" form: on bash < 4.4 (macOS's stock /bin/bash 3.2
# included), expanding an empty array under `set -u` throws "unbound variable".
FORWARD_ARGS=("$@")

case "$MODE" in
  start)
    (cd "$APP_DIR" && npm run dashboard:start -- "${FORWARD_ARGS[@]:-}")
    ;;
  open)
    (cd "$APP_DIR" && npm run dashboard:open -- "${FORWARD_ARGS[@]:-}")
    ;;
esac
