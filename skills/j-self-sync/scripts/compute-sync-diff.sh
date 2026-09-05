#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-self-sync/scripts/compute-sync-diff.sh
#
# Computes "what COPY_SET-scoped source has changed since the last time this
# ticket-matching pipeline processed a /self-sync run" — the input E51_S02_T02
# needs to decide which closed tickets are now safe to mark `Merged`.
#
# Marker: a LOCAL git tag, `last-self-sync`, analogous to
# skills/mirror-public/scripts/mirror.sh's `last-mirror-sync` tag, but
# adapted for a same-repo mirror instead of a remote push — there is no
# remote involved here at all, so unlike `last-mirror-sync` this tag is never
# pushed anywhere. It is purely local bookkeeping that must survive across
# script invocations without a separate state file (the established pattern
# for that in this repo — see mirror.sh).
#
# Scope: the diff is scoped to the exact same COPY_SET paths /self-sync
# itself mirrors (skills/j-self-sync/scripts/run.js's `COPY_SET` constant:
# bin/, lib/, scripts/, agents/, hooks/, mcp/, skills/, templates/,
# settings.json). That list is read directly out of run.js (see
# extract_copy_set below) rather than duplicated by hand here, so the two
# can never silently drift apart.
#
# Behavior:
#   - First run (no `last-self-sync` tag yet): create the tag at current
#     HEAD, print nothing on stdout (empty diff), exit 0. No attempt is made
#     to backfill or guess prior history — mirrors mirror.sh's case-1
#     "genuine first-run, proceed with no ceremony" behavior.
#   - Subsequent runs (tag already present): compute
#     `git diff --name-only <marker>..HEAD`, scoped to the COPY_SET paths,
#     and print the result to stdout, one changed path per line.
#
# This script ONLY computes and reports the diff — it never advances the
# `last-self-sync` tag itself. Marker advancement is the caller's
# responsibility (E51_S02_T02), performed only after that caller has
# successfully finished processing this diff, so a downstream failure (e.g.
# a lock timeout writing a board file) can retry against the same,
# still-valid diff rather than silently losing it because the marker moved
# regardless of outcome.
#
# Output contract:
#   stdout — machine-parseable: one changed path per line, or nothing if
#            there is no diff (including the first-run bootstrap case).
#   stderr — all human-readable log/diagnostic output.
#
# Exit codes:
#   0  success (tag created and/or diff computed, including an empty diff)
#   1  error (see stderr message)
# ---------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

TAG_NAME="last-self-sync"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

die() {
  printf 'compute-sync-diff.sh: error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf 'compute-sync-diff.sh: %s\n' "$*" >&2
}

usage() {
  cat <<'EOF'
Usage: compute-sync-diff.sh [-h|--help]

Reads (or, on first run, creates) the local `last-self-sync` git tag and
prints the COPY_SET-scoped `git diff --name-only <marker>..HEAD` to stdout,
one changed path per line. On first run (no tag yet), creates the tag at
current HEAD and prints an empty diff. Never advances an existing tag —
that is the caller's responsibility once it has finished processing the
diff successfully.

All log output goes to stderr; stdout carries only the path list (or
nothing), so it can be consumed directly by a downstream script.
EOF
}

if [ $# -gt 0 ]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
fi

# -----------------------------------------------------------------------------
# Locate script + repo root
#
# Same symlink-resolution + repo-root derivation pattern as
# skills/mirror-public/scripts/mirror.sh, so this script behaves identically
# whether invoked directly or via a symlink.
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

REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || die "could not locate repo root (git rev-parse failed from $SCRIPT_DIR)"

RUN_JS="$SCRIPT_DIR/run.js"
[ -f "$RUN_JS" ] || die "expected sibling file not found: $RUN_JS (skills/j-self-sync/scripts/run.js)"

command -v node >/dev/null 2>&1 || die "node not installed (required to read COPY_SET out of $RUN_JS)"

# -----------------------------------------------------------------------------
# extract_copy_set
#
# Reads the COPY_SET path list directly out of run.js's literal
# `const COPY_SET = [ ... ];` array, one entry per line, so this script's
# scoping can never hand-drift from run.js's own constant (AC4). Uses `node`
# (already a hard dependency of /self-sync itself — run.js is a Node script)
# to regex-extract and parse just that array out of the file's source text,
# WITHOUT importing/executing run.js — importing it would run its
# unconditional top-level `main()` call.
#
# NOTE for future editors: if run.js's COPY_SET ever stops being a literal
# `const COPY_SET = [ 'a', 'b', ... ];` array of single/double-quoted string
# literals (e.g. moved to a JSON file or computed dynamically), this
# extraction must be updated to match.
# -----------------------------------------------------------------------------

extract_copy_set() {
  node -e '
    const fs = require("fs");
    const src = fs.readFileSync(process.argv[1], "utf8");
    const m = src.match(/const COPY_SET = \[([\s\S]*?)\];/);
    if (!m) {
      process.stderr.write("could not find a COPY_SET array in " + process.argv[1] + "\n");
      process.exit(1);
    }
    const items = m[1]
      .split(",")
      .map((s) => s.trim())
      .filter((s) => s.length > 0)
      .map((s) => s.replace(/^[\x27"]|[\x27"]$/g, ""));
    if (items.length === 0) {
      process.stderr.write("COPY_SET array in " + process.argv[1] + " parsed as empty\n");
      process.exit(1);
    }
    items.forEach((i) => console.log(i));
  ' "$RUN_JS" || die "failed to extract COPY_SET from $RUN_JS"
}

COPY_SET=()
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  COPY_SET+=("$entry")
done < <(extract_copy_set)

[ "${#COPY_SET[@]}" -gt 0 ] || die "extracted an empty COPY_SET from $RUN_JS"

log "repo root: $REPO_ROOT"
# Join with plain spaces for a readable log line, regardless of the script's
# own IFS=$'\n\t' (which would otherwise make `${COPY_SET[*]}` join on
# newlines and print one entry per line).
COPY_SET_DISPLAY="$(IFS=' '; printf '%s' "${COPY_SET[*]}")"
log "COPY_SET (from $(basename "$RUN_JS")): $COPY_SET_DISPLAY"

# -----------------------------------------------------------------------------
# Read or bootstrap the last-self-sync marker
# -----------------------------------------------------------------------------

MARKER_SHA="$(git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$TAG_NAME" 2>/dev/null || true)"

if [ -z "$MARKER_SHA" ]; then
  HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  log "no $TAG_NAME tag found — first-run bootstrap, creating it at current HEAD ($HEAD_SHA)"
  # Deliberately non-forcing: this branch only ever runs when the tag is
  # absent (per the -z check above), so a plain `git tag` fails closed
  # instead of silently overwriting anything if that assumption is ever
  # violated by a race. This script never advances an EXISTING tag (AC3).
  git -C "$REPO_ROOT" tag "$TAG_NAME" "$HEAD_SHA"
  log "created $TAG_NAME at $HEAD_SHA — reporting empty diff (no history backfill)"
  exit 0
fi

log "$TAG_NAME marker found at $MARKER_SHA"

# -----------------------------------------------------------------------------
# Compute the scoped diff since the marker
#
# `git diff --name-only <marker>..HEAD -- <COPY_SET pathspecs>` — paths are
# printed relative to $REPO_ROOT (git's default for --name-only), matching
# the board's file-path convention elsewhere in this repo.
# -----------------------------------------------------------------------------

git -C "$REPO_ROOT" diff --name-only "$MARKER_SHA..HEAD" -- "${COPY_SET[@]}"
