#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# skills/j-dashboard-share/scripts/upload-snapshot.sh
#
# Uploads a local dashboard snapshot HTML file (as produced by j-dashboard's
# `scripts/snapshot.sh`) to a configured rclone remote via `rclone copyto`, at
# a templated, Drive-side (remote-side) destination path:
#
#   JengaAI/<repo-directory-name>/<datetime>-board-snapshot.html
#
#   - <repo-directory-name> is the basename of the repository root, derived
#     via `basename "$(git rev-parse --show-toplevel)"` — never hardcoded to
#     any specific project.
#   - <datetime> is the actual UTC run time, formatted `%Y%m%dT%H%M%SZ`
#     (compact ISO 8601-ish, sortable, filesystem/URL-safe).
#
# This destination path is entirely independent of the LOCAL snapshot
# filename (whatever `snapshot.sh --out` wrote it as) — this script only
# reads the local file's bytes and uploads them under its own remote-side
# name.
#
# Before attempting any upload, this script verifies the target rclone
# remote is actually configured (present in `rclone listremotes`). If it is
# not, this script does NOT attempt the upload and does NOT let rclone
# surface its own raw error — it dies with an actionable message pointing
# the user at `j.cloud-connect` (E60_S01) to configure a remote first.
#
# HARD SCOPE BOUNDARY: this script uploads ONLY. It never invokes
# `rclone link` or any other link-creating/sharing subcommand, anywhere in
# its logic — that is a deliberate, separate, manual action reserved for the
# user (see E47_S05's story decision). Do not add one.
#
# This script does not create or wire up the `j-dashboard-share` skill
# itself (SKILL.md) — that is a separate task (E47_S05_T02). It assumes a
# remote has already been configured via `j.cloud-connect`
# (skills/j-cloud-connect/scripts/{install-rclone.sh,configure-backend.sh},
# E60_S01) and that `rclone` is already on PATH.
#
# Invoked via `bash`, not executed directly: this script intentionally ships
# without the executable bit, matching the convention already documented in
# skills/j-cloud-connect/scripts/install-rclone.sh and
# skills/j-dashboard/scripts/resolve-app-dir.sh. Whatever wires this into the
# j-dashboard-share skill (E47_S05_T02) should invoke it as
# `bash skills/j-dashboard-share/scripts/upload-snapshot.sh`.
#
# Usage:
#   upload-snapshot.sh --file <local-snapshot-path> --remote <remote-name>
#
#   --file <path>     Path to the local snapshot HTML file to upload (e.g.
#                      the output of `j.dashboard --snapshot`). Must exist
#                      and be non-empty.
#   --remote <name>   Name of an already-configured rclone remote (without a
#                      trailing colon), e.g. `gdrive`. Checked against
#                      `rclone listremotes` before any upload is attempted.
#
# Exit codes:
#   0  Upload succeeded. The full remote destination path is printed on
#      stdout as the last line.
#   1  Any failure: bad arguments, missing/empty local file, `rclone` not on
#      PATH, not inside a git repository, the target remote is not
#      configured (points the user at `j.cloud-connect`), or `rclone copyto`
#      itself failed. A human-readable reason is always printed to stderr.
# -----------------------------------------------------------------------------

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: upload-snapshot.sh --file <local-snapshot-path> --remote <remote-name>

Uploads a local dashboard snapshot HTML file to a configured rclone remote
via `rclone copyto`, at the templated destination path:

  JengaAI/<repo-directory-name>/<datetime>-board-snapshot.html

  --file <path>     Path to the local snapshot HTML file to upload. Must
                     exist and be non-empty.
  --remote <name>   Name of an already-configured rclone remote (no
                     trailing colon). If not configured, this script tells
                     you to run j.cloud-connect instead of attempting the
                     upload.

Upload only — never runs `rclone link` or any other sharing/link-creating
command.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

# -----------------------------------------------------------------------------
# Argument parsing.
# -----------------------------------------------------------------------------

LOCAL_FILE=""
REMOTE_NAME=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --file)
      [ "$#" -ge 2 ] || die "--file requires a value"
      LOCAL_FILE="$2"
      shift 2
      ;;
    --remote)
      [ "$#" -ge 2 ] || die "--remote requires a value"
      REMOTE_NAME="$2"
      shift 2
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "$LOCAL_FILE" ] || { usage >&2; die "--file is required"; }
[ -n "$REMOTE_NAME" ] || { usage >&2; die "--remote is required"; }

# -----------------------------------------------------------------------------
# Preflight — local file, rclone availability, git repository.
# -----------------------------------------------------------------------------

[ -f "$LOCAL_FILE" ] || die "local snapshot file not found: $LOCAL_FILE"
[ -s "$LOCAL_FILE" ] || die "local snapshot file is empty: $LOCAL_FILE"

command -v rclone >/dev/null 2>&1 || die "rclone is not on PATH. Install it first (see skills/j-cloud-connect/scripts/install-rclone.sh) and re-run."

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository — cannot derive <repo-directory-name> for the destination path. Run this script from within the project's repository."
REPO_DIR_NAME="$(basename "$REPO_ROOT")"

# -----------------------------------------------------------------------------
# Step 1 — Verify the target remote is actually configured BEFORE attempting
# any upload. Never let a raw rclone error surface for "remote not
# configured" — point the user at j.cloud-connect instead.
# -----------------------------------------------------------------------------

REMOTES_OUTPUT="$(rclone listremotes 2>&1)" || die "'rclone listremotes' failed: $REMOTES_OUTPUT"

if ! printf '%s\n' "$REMOTES_OUTPUT" | grep -Fxq "${REMOTE_NAME}:"; then
  die "remote '$REMOTE_NAME' is not configured in rclone. Run j.cloud-connect first to set it up, then re-run this upload."
fi

# -----------------------------------------------------------------------------
# Step 2 — Build the templated destination path.
# -----------------------------------------------------------------------------

DATETIME="$(date -u +%Y%m%dT%H%M%SZ)"
DEST_RELATIVE_PATH="JengaAI/${REPO_DIR_NAME}/${DATETIME}-board-snapshot.html"
DEST="${REMOTE_NAME}:${DEST_RELATIVE_PATH}"

# -----------------------------------------------------------------------------
# Step 3 — Upload. stdio inherited (no capture/reformatting), matching this
# repo's j-cloud-connect script conventions. Upload only: this script never
# calls `rclone link` or any other sharing/link-creating command.
# -----------------------------------------------------------------------------

echo "Uploading '$LOCAL_FILE' to '$DEST'..."

COPY_EXIT=0
rclone copyto "$LOCAL_FILE" "$DEST" || COPY_EXIT=$?
if [ "$COPY_EXIT" -ne 0 ]; then
  die "'rclone copyto $LOCAL_FILE $DEST' exited with status $COPY_EXIT. Upload did not succeed — see rclone's output above for the reason."
fi

echo "Upload succeeded."
echo "$DEST"
