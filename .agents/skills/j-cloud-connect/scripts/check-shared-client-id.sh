#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# skills/j-cloud-connect/scripts/check-shared-client-id.sh   (E89_S06_T08)
#
# Detects configured rclone remotes that still use rclone's shared Google
# Drive client_id, which rclone has announced it is retiring during 2026
# ("This remote uses rclone's shared Google Drive client_id, which is being
# retired and will stop working during 2026").
#
# A drive remote with no client_id of its own falls back to that shared id,
# so "type=drive and client_id empty/absent" is the signal. The legacy shared
# id itself, if written into the config explicitly, counts too.
#
# SECRET SAFETY: this script never reads, echoes, logs or stores a
# client_secret. `rclone config dump` output is piped straight into a jq
# filter that projects ONLY the remote name, its type and a boolean "has own
# client_id"; no other field ever leaves jq, and nothing is written to disk.
#
# Usage:
#   check-shared-client-id.sh            report drive remotes using the shared id
#   check-shared-client-id.sh --survey   also list, for EVERY configured remote,
#                                        its type and whether it sets its own
#                                        client_id (name/type/boolean only)
#   check-shared-client-id.sh -h|--help
#
# Exit codes:
#   0  no drive remote uses the shared client_id (or none configured)
#   1  rclone/jq missing, or the config could not be read
#   3  at least one drive remote uses the shared client_id (guidance printed)
# -----------------------------------------------------------------------------

set -euo pipefail

DOC_URL="https://rclone.org/drive/#making-your-own-client-id"
# rclone's built-in shared Google Drive client id (public, not a secret).
LEGACY_SHARED_ID="202264815644.apps.googleusercontent.com"

die() { echo "Error: $*" >&2; exit 1; }

usage() {
  echo "Usage: check-shared-client-id.sh [--survey]"
  echo "Reports Google Drive remotes using rclone's retiring shared client_id."
  echo "Exit 0: none, 1: error, 3: at least one remote uses the shared id."
}

SURVEY=0
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --survey) SURVEY=1 ;;
  "") ;;
  *) die "unknown argument '$1' (expected --survey or --help)" ;;
esac

command -v rclone >/dev/null 2>&1 || die "rclone is not on PATH."
command -v jq >/dev/null 2>&1 || die "jq is not on PATH."

# Project to name/type/own-id boolean only. client_secret is never selected.
PROJECTED="$(rclone config dump 2>/dev/null | jq -c --arg legacy "$LEGACY_SHARED_ID" '
  to_entries | map({
    name: .key,
    type: (.value.type // ""),
    own_client_id: (((.value.client_id // "") != "") and ((.value.client_id // "") != $legacy))
  })')" || die "could not read the rclone configuration ('rclone config dump' failed)."

if [ "$SURVEY" -eq 1 ]; then
  echo "Configured remotes (name, type, sets its own client_id):"
  printf '%s' "$PROJECTED" | jq -r '.[] | "  \(.name)\t\(.type)\t\(if .own_client_id then "own client_id" else "no own client_id" end)"'
fi

SHARED="$(printf '%s' "$PROJECTED" | jq -r '.[] | select(.type == "drive" and (.own_client_id | not)) | .name')"

if [ -z "$SHARED" ]; then
  echo "OK: no Google Drive remote uses rclone's shared client_id."
  exit 0
fi

echo "WARNING: these Google Drive remotes use rclone's shared client_id, which rclone is retiring"
echo "and which will stop working during 2026:"
printf '%s\n' "$SHARED" | sed 's/^/  - /'
echo ""
echo "Create your own client_id in the Google API console and point rclone at it:"
echo "  $DOC_URL"
echo "Then run 'rclone config', edit the remote, and enter your client_id and client_secret"
echo "yourself when rclone asks. Jenga never asks for, reads or stores the client_secret."
echo "After the retirement an upload to such a remote fails with an auth error from Google;"
echo "that is an expired upstream credential, not a Jenga defect."
exit 3
