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
# Step 2 — bundle: project/app/ui/scripts/build-snapshot-html.cjs inlines the
#   built dist/ (JS + CSS) into a single index.html and injects the captured
#   JSON as an inline <script id="jenga-dashboard-data"> tag. Zero dependencies
#   and no build tooling, so it behaves identically in this monorepo and in a
#   consumer install, which only ever receives the prebuilt dist/. Where the UI
#   sources and node_modules are available, dist/ is rebuilt first so a
#   snapshot is never taken from a stale build.
#
# project/app itself is located by resolve-app-dir.sh, which also knows to look
#   inside node_modules/@jenga-ai/agent — this script previously assumed the
#   repo root, which is wrong for every consumer install.
#
# Either step failing hard-fails this script (set -e) with no output file
# written — matching capture-snapshot.js's own "no partial artifact" contract.
#
# --data-url (E47_S04_T04): remote-delivery mode for sessions that cannot
#   assume a shared filesystem with the user. After the existing build/copy
#   step, base64-encodes the final output HTML and prints a
#   `data:text/html;base64,...` URI to stdout, additive to (not a replacement
#   for) the existing "Snapshot dashboard written to: <path>" line. Refuses
#   (hard-fail, no partial output) if the post-encoding size exceeds
#   MAX_DATA_URL_BYTES (default ~25MB, overridable via
#   SNAPSHOT_MAX_DATA_URL_BYTES for testing/tuning). No effect at all on the
#   plain-path behavior when --data-url is not passed.
#
# Usage:
#   snapshot.sh [--out <path>] [--project-root <path>] [--data-url]
#
#   --out <path>            Final output HTML path. Default: <cwd>/jenga.html
#                            (cwd at invocation time, i.e. the invoking project's
#                            own directory — same directory --project-root would
#                            otherwise need to point at).
#   --project-root <path>   Forwarded unchanged to capture-snapshot.js's own
#                            --project-root override. Default: let
#                            capture-snapshot.js resolve it from the invocation
#                            cwd (no override).
#   --data-url               After writing --out, also print a
#                            `data:text/html;base64,...` URI of the same file
#                            to stdout. Refuses (non-zero exit, no URI printed)
#                            if the base64-encoded size exceeds
#                            SNAPSHOT_MAX_DATA_URL_BYTES (default ~25MB).
# -----------------------------------------------------------------------------

set -euo pipefail

# Post-encoding size threshold for --data-url, in bytes. Overridable via
# SNAPSHOT_MAX_DATA_URL_BYTES (used by tests to exercise the refusal path
# without generating a real multi-megabyte fixture).
MAX_DATA_URL_BYTES="${SNAPSHOT_MAX_DATA_URL_BYTES:-26214400}" # 25 * 1024 * 1024

usage() {
  cat <<'EOF'
Usage: snapshot.sh [--out <path>] [--project-root <path>] [--data-url]

  --out <path>            Final output HTML path. Default: <cwd>/jenga.html
  --project-root <path>   Forwarded to capture-snapshot.js's --project-root override.
  --data-url              Also print a data:text/html;base64,... URI of the
                          output file to stdout (for remote/no-shared-filesystem
                          sessions). Refuses if the encoded size exceeds ~25MB
                          (SNAPSHOT_MAX_DATA_URL_BYTES).
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

OUT_PATH=""
PROJECT_ROOT_ARG=""
DATA_URL=0

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
    --data-url)
      DATA_URL=1
      shift
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

# project/app is NOT always at the repo root: in a consumer install it ships
# inside the package, under node_modules/@jenga-ai/agent/. resolve-app-dir.sh
# owns that whole search (and is shared with launch.sh) — see its header.
# Invoked via `bash`, not executed directly: a shipped script losing its
# executable bit is exactly the packaging defect this change also fixes, and
# resolving the app dir must not be the thing that breaks when it happens.
APP_DIR="$(bash "$SCRIPT_DIR/resolve-app-dir.sh" --marker "api/scripts/capture-snapshot.js" --from "$ORIG_CWD")" \
  || die "could not locate the dashboard app directory (see message above)"

API_DIR="$APP_DIR/api"
UI_DIR="$APP_DIR/ui"

[ -f "$API_DIR/scripts/capture-snapshot.js" ] || die "capture script not found at $API_DIR/scripts/capture-snapshot.js"
# The built UI, not its sources: bundling no longer needs vite (see Step 2).
[ -f "$UI_DIR/dist/index.html" ] || die "dashboard UI has not been built — no $UI_DIR/dist/index.html. In this monorepo run: npm run ui:build --prefix project/app. In a consumer install this means the package shipped without project/app/ui/dist (a packaging regression)."

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
#
# Two sub-steps, deliberately split so the second one is identical everywhere:
#
#   2a. If the UI sources AND its node_modules are present (i.e. this monorepo,
#       or a dev checkout), refresh dist/ first so a snapshot never silently
#       ships a stale build. Skipped entirely in a consumer install, which has
#       only the prebuilt dist/ the package shipped — and needs nothing more.
#       If sources are present but node_modules/vite isn't (so the rebuild
#       above can't run), a dev checkout still refuses to bundle a dist/ that
#       looks older than its own sources — see the staleness check below.
#   2b. Inline that dist/ into one self-contained HTML file with the captured
#       JSON embedded, via the dependency-free build-snapshot-html.cjs.
#
# This used to be `npm run build:snapshot` (vite build --mode snapshot), which
# only ever worked here: the tarball ships dist/ and scripts/ but no
# package.json, vite.config.js, or src/, so there was no vite to run on any
# consumer. Inlining a prebuilt dist needs no build tooling, so one code path
# now serves both — and every local run exercises the consumer path too.
# -----------------------------------------------------------------------------

if [ -f "$UI_DIR/package.json" ] && [ -d "$UI_DIR/node_modules/vite" ]; then
  (cd "$UI_DIR" && npm run build)
  [ -f "$UI_DIR/dist/index.html" ] || die "UI rebuild reported success but produced no $UI_DIR/dist/index.html"
elif [ -d "$UI_DIR/src" ]; then
  # This is a dev checkout (it has UI sources, unlike a consumer install which
  # only ships prebuilt dist/ + scripts/), but node_modules/vite isn't present
  # right now to rebuild with -- e.g. `npm install` hasn't been (re-)run for
  # this package. The rebuild above was skipped, so dist/ may already be
  # stale relative to src/. A stale snapshot must never ship silently (this is
  # exactly how a fixed bug re-appeared in a previously-generated jenga.html):
  # fail loudly instead of trusting an on-disk dist/ of unknown age.
  STALE_SRC="$(find "$UI_DIR/src" -type f -newer "$UI_DIR/dist/index.html" -print -quit 2>/dev/null)"
  if [ -n "$STALE_SRC" ]; then
    die "$UI_DIR/dist is older than UI sources (e.g. $STALE_SRC) and node_modules/vite is not installed here to rebuild it -- refusing to bundle a possibly-stale snapshot. Run 'npm install' in $UI_DIR (or otherwise rebuild dist/), then retry."
  fi
fi

mkdir -p "$SNAPSHOT_DIST"
node "$UI_DIR/scripts/build-snapshot-html.cjs" \
  --dist "$UI_DIR/dist" \
  --data "$SNAPSHOT_JSON" \
  --out "$SNAPSHOT_DIST/index.html"

[ -f "$SNAPSHOT_DIST/index.html" ] || die "bundling step reported success but no index.html was produced in $SNAPSHOT_DIST"

# -----------------------------------------------------------------------------
# Step 3 — place the final artifact and report its path.
# -----------------------------------------------------------------------------

mkdir -p "$(dirname "$OUT_PATH")"
cp "$SNAPSHOT_DIST/index.html" "$OUT_PATH"

echo "Snapshot dashboard written to: $OUT_PATH"

# -----------------------------------------------------------------------------
# Step 4 — optional data: URL delivery mode (E47_S04_T04).
#
# For sessions that cannot assume a shared filesystem with the user (e.g. a
# remote/cloud agent session), base64-encode the just-written output file and
# print a data:text/html;base64,... URI any browser can open directly — no
# hosting, third-party service, or git round-trip required. Additive to the
# plain-path report above, never a replacement for it.
# -----------------------------------------------------------------------------

if [ "$DATA_URL" -eq 1 ]; then
  [ -f "$OUT_PATH" ] || die "--data-url: expected output file missing at $OUT_PATH after write step"

  # `base64` without newline-wrapping flags (GNU's -w0 and BSD/macOS's -b are
  # not portable across each other), then strip embedded newlines with `tr` --
  # portable everywhere and avoids the platform-specific flag entirely.
  ENCODED="$(base64 <"$OUT_PATH" | tr -d '\n')"
  ENCODED_BYTES="${#ENCODED}"

  if [ "$ENCODED_BYTES" -gt "$MAX_DATA_URL_BYTES" ]; then
    die "--data-url: encoded size ($ENCODED_BYTES bytes) for $OUT_PATH exceeds the $MAX_DATA_URL_BYTES-byte threshold; refusing to emit an oversized data: URI. Use the plain --out file path instead, or raise SNAPSHOT_MAX_DATA_URL_BYTES if you understand the tradeoff."
  fi

  echo "data:text/html;base64,${ENCODED}"
fi
