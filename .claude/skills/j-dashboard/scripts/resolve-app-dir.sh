#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# skills/j-dashboard/scripts/resolve-app-dir.sh
#
# Prints the absolute path of the dashboard's `project/app` directory, or exits
# non-zero with a clear message if it cannot be found.
#
# Why this script exists
# ----------------------
# launch.sh and snapshot.sh both used to hard-code
#
#     APP_DIR="$(git rev-parse --show-toplevel)/project/app"
#
# which is only ever correct inside this monorepo. In a CONSUMER install the
# dashboard does not live at the consumer repo root at all — it ships inside the
# package, at <consumer>/node_modules/@jenga-ai/agent/project/app — so both
# scripts died with "capture script not found" / "dashboard app not found" on
# every consumer, no matter how well the package was built. Centralizing the
# resolution here means that fallback exists once, for both callers, instead of
# being duplicated (or, as it was, missing entirely).
#
# Resolution order — first candidate whose <candidate>/<marker> exists wins:
#
#   1. Package-root-relative: this script lives at
#      <root>/skills/j-dashboard/scripts/, so <root>/project/app is three
#      levels up. Covers the monorepo invoked directly AND the package invoked
#      in place from node_modules/@jenga-ai/agent/skills/j-dashboard/scripts/.
#   2. Git repo root: covers the monorepo invoked through a mirrored copy under
#      .claude/skills/ or .agents/skills/, where (1) resolves to the mirror
#      directory rather than the repo root.
#   3. Git repo root + node_modules/@jenga-ai/agent: the consumer install case —
#      the skill was mirrored into <consumer>/.claude/skills/ by postinstall, so
#      neither (1) nor (2) can see the packaged app.
#   4. Walk up from --from (default: cwd), checking both project/app and
#      node_modules/@jenga-ai/agent/project/app at each level. Covers consumers
#      that are not git repositories at all, where (2) and (3) are unavailable.
#
# Usage:
#   resolve-app-dir.sh --marker <relative-path> [--from <dir>]
#
#   --marker <relative-path>  File that must exist under project/app for a
#                             candidate to be accepted. Callers pass whatever
#                             they actually need, so a half-shipped package is
#                             rejected here rather than failing later with a
#                             confusing error: launch.sh passes `package.json`,
#                             snapshot.sh passes `api/scripts/capture-snapshot.js`.
#   --from <dir>              Starting directory for the walk-up candidate.
#                             Default: the current working directory.
#
# Exit codes: 0 (path printed to stdout), 2 (bad usage), 1 (not found).
# -----------------------------------------------------------------------------

set -euo pipefail

die() {
  echo "Error: $*" >&2
  exit 1
}

MARKER=""
START_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --marker)
      [ $# -ge 2 ] || { echo "Error: --marker requires a value" >&2; exit 2; }
      MARKER="$2"
      shift 2
      ;;
    --from)
      [ $# -ge 2 ] || { echo "Error: --from requires a value" >&2; exit 2; }
      START_DIR="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '/^# Usage:/,/^# Exit codes/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

[ -n "$MARKER" ] || { echo "Error: --marker is required" >&2; exit 2; }
[ -n "$START_DIR" ] || START_DIR="$(pwd)"

# -----------------------------------------------------------------------------
# Locate this script (symlink-resolved), matching launch.sh/snapshot.sh's own
# pattern so behavior is identical however the skill directory was reached.
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

# The installed package name, kept in one place so a rename only touches here.
PKG_SUBPATH="node_modules/@jenga-ai/agent"

# Accepts a candidate base directory if <base>/project/app/<marker> exists.
# Prints the resolved app dir and returns 0; returns 1 otherwise.
try_base() {
  local base="$1"
  [ -n "$base" ] || return 1
  local app="$base/project/app"
  [ -f "$app/$MARKER" ] || return 1
  (cd "$app" && pwd)
}

CANDIDATES_TRIED=()

# ── 1. Package-root-relative (monorepo direct, or package invoked in place) ────
PKG_ROOT="$(cd "$SCRIPT_DIR/../../.." 2>/dev/null && pwd || true)"
if [ -n "$PKG_ROOT" ]; then
  CANDIDATES_TRIED+=("$PKG_ROOT/project/app")
  if RESOLVED="$(try_base "$PKG_ROOT")"; then
    echo "$RESOLVED"
    exit 0
  fi
fi

# ── 2 & 3. Git repo root, then the package inside it (consumer install) ───────
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$REPO_ROOT" ]; then
  CANDIDATES_TRIED+=("$REPO_ROOT/project/app" "$REPO_ROOT/$PKG_SUBPATH/project/app")
  if RESOLVED="$(try_base "$REPO_ROOT")"; then
    echo "$RESOLVED"
    exit 0
  fi
  if RESOLVED="$(try_base "$REPO_ROOT/$PKG_SUBPATH")"; then
    echo "$RESOLVED"
    exit 0
  fi
fi

# ── 4. Walk up from --from, for consumers that are not git repositories ───────
# Bounded by reaching "/" so it always terminates, and checks the packaged
# location at every level because node_modules may sit above the invoking dir.
#
# Deliberately checks ONLY $PKG_SUBPATH/project/app here, never a bare
# project/app. An installed package is unambiguous evidence that this dashboard
# belongs to this project; a bare project/app in some ancestor directory is not
# — it is just as likely to be an unrelated checkout that happens to sit higher
# up the tree, and silently rendering THAT project's board would be worse than
# failing. Bare project/app is only ever accepted via candidates 1 and 2, which
# are anchored to this script's own location rather than the caller's cwd.
DIR="$(cd "$START_DIR" 2>/dev/null && pwd || true)"
while [ -n "$DIR" ]; do
  if RESOLVED="$(try_base "$DIR/$PKG_SUBPATH")"; then
    echo "$RESOLVED"
    exit 0
  fi
  [ "$DIR" = "/" ] && break
  DIR="$(dirname "$DIR")"
done

die "dashboard app not found (looked for project/app/$MARKER). Tried: ${CANDIDATES_TRIED[*]:-none}, and walked up from $START_DIR checking both project/app and $PKG_SUBPATH/project/app. If this is a consumer install, reinstall @jenga-ai/agent with install scripts enabled (npm approve-scripts @jenga-ai/agent) so the dashboard is present."
