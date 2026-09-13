#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# skills/j-dashboard/scripts/launch.sh
#
# Thin wrapper around project/app's existing `dashboard:start` / `dashboard:open`
# npm scripts (which themselves shell into
# project/app/ui/scripts/dashboard-start.cjs / dashboard-open.cjs). This script
# introduces NO server-launch, health-check, or browser-open logic of its own —
# it only resolves paths and forwards flags to those existing scripts, per
# E47_S04_T01's scope (the default, no-`--snapshot` launch mode of `j.dashboard`).
#
# Usage:
#   launch.sh start [--port <n>] [--serve-app]
#   launch.sh open  [--port <n>]
#   launch.sh both  [--port <n>] [--serve-app]
#
# `both` starts the server in the background (it is long-running / blocking by
# design — see dashboard-start.cjs), waits briefly, then runs `open`, which
# itself health-checks before opening the browser and always exits 0 regardless
# of outcome (dashboard-open.cjs's own documented contract).
#
# Same symlink-resolution + repo-root derivation pattern used elsewhere in this
# skill library (e.g. skills/j-mirror-public/scripts/compute-publicize-diff.sh),
# so this script behaves identically whether invoked directly or via a symlink,
# and whether run from this monorepo or a mirrored/distributed copy.
# -----------------------------------------------------------------------------

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: launch.sh <start|open|both> [--port <n>] [--serve-app]

  start       Run `npm run dashboard:start` in project/app.
  open        Run `npm run dashboard:open` in project/app.
  both        Start the server in the background, then open the browser.

  --port <n>       Forwarded unchanged to the underlying npm script.
  --serve-app      Forwarded unchanged to `dashboard:start` only (ignored by `open`).
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
  start|open|both) ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; die "unknown mode: $MODE (expected start|open|both)" ;;
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
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# project/app is NOT always at the repo root: in a consumer install it ships
# inside the package, under node_modules/@jenga-ai/agent/. resolve-app-dir.sh
# owns that whole search (and is shared with snapshot.sh) — see its header.
# Invoked via `bash`, not executed directly: a shipped script losing its
# executable bit is exactly the packaging defect this change also fixes, and
# resolving the app dir must not be the thing that breaks when it happens.
APP_DIR="$(bash "$SCRIPT_DIR/resolve-app-dir.sh" --marker "package.json" --from "$(pwd)")" \
  || die "could not locate the dashboard app directory (see message above)"

# Remaining args (--port <n>, --serve-app) are forwarded verbatim via the
# "${EXTRA_ARGS[@]:-}" default-expansion form, not the bare "${EXTRA_ARGS[@]}"
# form. On bash < 4.4 — notably including macOS's stock /bin/bash 3.2, which
# `#!/usr/bin/env bash` resolves to by default on that platform — expanding
# an empty array under `set -u` ("nounset") throws "unbound variable"; the
# `:-` default (even though the default itself is empty) is an explicit,
# nounset-safe form that keeps `set -u` in force everywhere in this script.
# This preserves the `-- ` separator unconditionally (npm run <script> --
# with nothing after it is a harmless no-op, and always including it avoids
# reintroducing the nested-npm-run flag-forwarding bug this epic already hit
# once — see epic E47's own history) rather than branching on argument count.
EXTRA_ARGS=("$@")

run_start() {
  (cd "$APP_DIR" && npm run dashboard:start -- "${EXTRA_ARGS[@]:-}")
}

run_open() {
  (cd "$APP_DIR" && npm run dashboard:open -- "${EXTRA_ARGS[@]:-}")
}

case "$MODE" in
  start)
    run_start
    ;;
  open)
    run_open
    ;;
  both)
    run_start &
    START_PID=$!
    echo "Started dashboard server in background (pid $START_PID)."
    sleep 1
    run_open
    ;;
esac
