#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/check-publicignore-match.sh
#
# Classify one or more repo-relative paths as PUBLIC (would ship to the
# public mirror repo) or BLOCKED (excluded by .publicignore), using the
# exact same rsync --exclude-from=.publicignore matching semantics as
# skills/mirror-public/scripts/mirror.sh's --dry-run "ship list" computation
# (see the SHIP_LIST_FILE block in that script). A file classified as
# "would be blocked" by `/mirror-public --dry-run` is guaranteed to be
# classified as BLOCKED here too, and vice versa for PUBLIC.
#
# This does NOT touch the network, clone the public repo, or require
# /mirror-public to be configured (skills/mirror-public/assets/config.json
# is never read) — it only needs a .publicignore file at the repo root.
# Rsync's include/exclude filter evaluation does not depend on destination
# state (destination state only affects delete/itemize-flag details for
# files already present there), so probing against an empty scratch temp
# directory yields an identical "would ship" set to probing against
# mirror.sh's real public-clone destination.
#
# Callers (e.g. /doc-sync step 4, and the E36 changelog generator's
# .publicignore-awareness) are expected to skip invoking this script
# entirely when .publicignore does not exist at the repo root — that is
# the established no-op-when-absent precedent, and it stays owned by each
# caller rather than being silently absorbed here.
#
# Usage:
#   check-publicignore-match.sh <path> [<path> ...]
#
# Paths are interpreted relative to the repo root (same convention as
# `git ls-files`). Output: one "STATUS<TAB>path" line per input path, in
# input order. STATUS is PUBLIC or BLOCKED.
#
# Note: a path that does not exist on disk is classified BLOCKED (it will
# not appear in rsync's transfer list regardless of .publicignore). Callers
# such as /doc-sync only ever pass paths already confirmed to exist as
# real new-in-source candidates, so this does not arise in practice — but
# it is not the same guarantee as ".publicignore explicitly matched it".
#
# Exit codes:
#   0  classification completed (regardless of individual PUBLIC/BLOCKED results)
#   1  usage error
#   2  repo root not found, .publicignore missing, or rsync unavailable
# ---------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

die() {
  printf 'check-publicignore-match.sh: error: %s\n' "$*" >&2
  exit 2
}

if [ "$#" -eq 0 ]; then
  printf 'usage: check-publicignore-match.sh <path> [<path> ...]\n' >&2
  exit 1
fi

SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -h "$SCRIPT_PATH" ]; do
  LINK_TARGET="$(readlink "$SCRIPT_PATH")"
  case "$LINK_TARGET" in
    /*) SCRIPT_PATH="$LINK_TARGET" ;;
    *)  SCRIPT_PATH="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/$LINK_TARGET" ;;
  esac
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || die "could not locate repo root (git rev-parse failed from $SCRIPT_DIR)"

PUBLICIGNORE="$REPO_ROOT/.publicignore"
[ -f "$PUBLICIGNORE" ] || die "no .publicignore at $PUBLICIGNORE (caller should skip invoking this script when absent — that is the no-op case, not an error the caller should surface)"

command -v rsync >/dev/null 2>&1 || die "rsync not installed"

TMP_DEST="$(mktemp -d)"
SHIP_LIST_FILE="$(mktemp)"
cleanup() {
  rm -rf "$TMP_DEST"
  rm -f "$SHIP_LIST_FILE"
}
trap cleanup EXIT

# Same rsync flags + itemize/awk filter as mirror.sh's --dry-run ship-list
# computation (kept in lockstep with that block intentionally), targeted at
# an empty scratch dir instead of a real public clone.
rsync -a --delete \
  --exclude-from="$PUBLICIGNORE" \
  --exclude=".git" \
  --dry-run --itemize-changes --out-format='%i %n' \
  "$REPO_ROOT/" \
  "$TMP_DEST/" \
  | awk '{
      flag = $1;
      first  = substr(flag, 1, 1);
      second = substr(flag, 2, 1);
      # Skip directories — public tree recreates them implicitly.
      if (second == "d") next;
      # Keep only entries that transfer or create a file/symlink/hardlink.
      keep = 0;
      if (first == ">" || first == "<") keep = 1;   # file transfer
      else if (first == "c" && second == "L") keep = 1;  # create symlink
      else if (first == "h") keep = 1;              # hard link
      if (!keep) next;
      $1 = "";
      sub(/^ /, "");
      sub(/\/$/, "");
      if (length($0) > 0) print $0;
    }' \
  | LC_ALL=C sort -u > "$SHIP_LIST_FILE"

for candidate in "$@"; do
  # Normalize a single leading "./" if present, so callers can pass either form.
  norm="${candidate#./}"
  if LC_ALL=C grep -Fxq "$norm" "$SHIP_LIST_FILE"; then
    printf 'PUBLIC\t%s\n' "$candidate"
  else
    printf 'BLOCKED\t%s\n' "$candidate"
  fi
done
