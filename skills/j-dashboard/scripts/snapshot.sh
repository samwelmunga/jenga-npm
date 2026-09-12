#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# skills/j-dashboard/scripts/snapshot.sh
#
# Orchestrates `j.dashboard --snapshot` (E47_S04_T03): runs E47_S04_T02's capture
# step, then bundles the UI into a single self-contained HTML file with that
# captured data embedded inline, and reports the final output path.
#
# Step 1 — capture: node project/app/api/scripts/capture-snapshot.js writes a
#   single JSON artifact ({schema_version, captured_at, project_root, routes})
#   by calling /v1/board, /v1/history, /v1/architecture exactly once each via a
#   short-lived ad-hoc server. Run from the ORIGINAL invocation directory
#   (captured before any `cd` below) so its own resolveProjectRoot() walk-up
#   resolves the *invoking* project's root (E47_S02's contract) — not this
#   framework repo's, and not project/app/ui's.
#
# Step 2 — bundle: npm run build:snapshot (vite build --mode snapshot) inside
#   project/app/ui, with SNAPSHOT_DATA_FILE pointed at the captured JSON.
#   vite.config.js's snapshot-mode-only plugins inject that JSON as an inline
#   <script id="jenga-dashboard-data"> tag and inline all JS/CSS
#   (vite-plugin-singlefile) into a single index.html.
#
# Either step failing hard-fails this script (set -e) with no output file
# written — matching capture-snapshot.js's own "no partial artifact" contract.
#
# Usage:
#   snapshot.sh [--out <path>] [--project-root <path>]
#
#   --out <path>            Final output HTML path. Default: <cwd>/jenga.html
#                            (cwd at invocation time, i.e. the invoking project's
#                            own directory — same directory --project-root would
#                            otherwise need to point at).
#   --project-root <path>   Forwarded unchanged to capture-snapshot.js's own
#                            --project-root override. Default: let
#                            capture-snapshot.js resolve it from the invocation
#                            cwd (no override).
# -----------------------------------------------------------------------------

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: snapshot.sh [--out <path>] [--project-root <path>]

  --out <path>            Final output HTML path. Default: <cwd>/jenga.html
  --project-root <path>   Forwarded to capture-snapshot.js's --project-root override.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

OUT_PATH=""
PROJECT_ROOT_ARG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --out)
      [ $# -ge 2 ] || die "--out requires a value"
      OUT_PATH="$2"
      shift 2
      ;;
    --project-root)
      [ $# -ge 2 ] || die "--project-root requires a value"
      PROJECT_ROOT_ARG="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
done

# Capture the invocation cwd BEFORE any `cd` below — this is what
# capture-snapshot.js's own resolveProjectRoot() walk-up must see, per E47_S02's
# "resolve against the invoking project, not this repo" contract.
ORIG_CWD="$(pwd)"

if [ -z "$OUT_PATH" ]; then
  OUT_PATH="$ORIG_CWD/jenga.html"
fi
# Resolve OUT_PATH to an absolute path up front, since later steps `cd` elsewhere
# and a relative --out would otherwise silently resolve against the wrong directory.
case "$OUT_PATH" in
  /*) ;;
  *) OUT_PATH="$ORIG_CWD/$OUT_PATH" ;;
esac

# -----------------------------------------------------------------------------
# Locate script + repo root (symlink-resolved SCRIPT_DIR -> SKILL_DIR -> REPO_ROOT)
# Same pattern as launch.sh — behaves identically whether invoked directly or
# via a symlink, and whether run from this monorepo or a mirrored/distributed copy.
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

REPO_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || die "could not locate repo root (git rev-parse failed from $SKILL_DIR)"

API_DIR="$REPO_ROOT/project/app/api"
UI_DIR="$REPO_ROOT/project/app/ui"

[ -f "$API_DIR/scripts/capture-snapshot.js" ] || die "capture script not found at $API_DIR/scripts/capture-snapshot.js"
[ -f "$UI_DIR/package.json" ] || die "dashboard UI not found at $UI_DIR (expected project/app/ui/package.json). If this is a consumer install, the dashboard may not yet be shipped in this package version (see epic E47_S01)."

# -----------------------------------------------------------------------------
# Scratch workspace — always cleaned up, success or failure.
# -----------------------------------------------------------------------------

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SNAPSHOT_JSON="$TMP_DIR/dashboard-snapshot-data.json"
SNAPSHOT_DIST="$TMP_DIR/dist-snapshot"

# -----------------------------------------------------------------------------
# Step 1 — capture (from ORIG_CWD, not REPO_ROOT/UI_DIR — see header comment)
# -----------------------------------------------------------------------------

CAPTURE_ARGS=(--out "$SNAPSHOT_JSON")
if [ -n "$PROJECT_ROOT_ARG" ]; then
  CAPTURE_ARGS+=(--project-root "$PROJECT_ROOT_ARG")
fi

(cd "$ORIG_CWD" && node "$API_DIR/scripts/capture-snapshot.js" "${CAPTURE_ARGS[@]}")

[ -f "$SNAPSHOT_JSON" ] || die "capture step reported success but no artifact was written to $SNAPSHOT_JSON"

# -----------------------------------------------------------------------------
# Step 2 — bundle: single-file build with the captured data embedded inline.
# -----------------------------------------------------------------------------

(
  cd "$UI_DIR" && \
  SNAPSHOT_DATA_FILE="$SNAPSHOT_JSON" \
  npm run build:snapshot -- --outDir "$SNAPSHOT_DIST" --emptyOutDir
)

[ -f "$SNAPSHOT_DIST/index.html" ] || die "bundling step reported success but no index.html was produced in $SNAPSHOT_DIST"

# -----------------------------------------------------------------------------
# Step 3 — place the final artifact and report its path.
# -----------------------------------------------------------------------------

mkdir -p "$(dirname "$OUT_PATH")"
cp "$SNAPSHOT_DIST/index.html" "$OUT_PATH"

echo "Snapshot dashboard written to: $OUT_PATH"
