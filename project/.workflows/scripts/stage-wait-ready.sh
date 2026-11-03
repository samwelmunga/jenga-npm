#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# stage-wait-ready.sh - wait until the version on HEAD is staged on the registry and
# print its stage id.
#
# stdout is EXACTLY the stage id and nothing else: the workflow feeds this output
# straight into st-test-run.sh's argv, so every human-readable detail goes to stderr
# (run-compute.sh passes stderr through and captures only stdout).
#
# Two sources, in order, re-checked on every poll:
#   1. project/logs/publish-history.json - the `staged` ledger entry that
#      npm_stage_pipeline.sh writes for this version once the Actions stage job has
#      finished. The most reliable source, and the one the dispatch step produces.
#   2. `npm stage list <pkg> --json` - the registry's own view, used when the ledger
#      has no entry yet (for instance when the stage was dispatched outside this
#      workflow). Falls back to a plain-text scan when --json is unavailable.
# A candidate id is accepted only once `npm stage view <id>` succeeds, so a stage
# that exists but is not yet inspectable keeps the loop going.
#
# Usage: stage-wait-ready.sh [<timeout-minutes>] [<poll-seconds>]  (defaults 30, 20)
#
# Exit: 0 the id is on stdout; 1 the timeout elapsed; 2 setup error.
# ---------------------------------------------------------------------------
set -uo pipefail

TIMEOUT_MINUTES="${1:-30}"
POLL_SECONDS="${2:-20}"

die() { printf 'stage-wait-ready: %s\n' "$1" >&2; exit "${2:-2}"; }
note() { printf 'stage-wait-ready: %s\n' "$1" >&2; }

command -v npm >/dev/null 2>&1 || die "npm not installed"
command -v node >/dev/null 2>&1 || die "node not installed"
command -v git >/dev/null 2>&1 || die "git not installed"
case "$TIMEOUT_MINUTES" in ''|*[!0-9]*) die "timeout-minutes must be a whole number, got '$TIMEOUT_MINUTES'" ;; esac
case "$POLL_SECONDS" in ''|*[!0-9]*) die "poll-seconds must be a whole number, got '$POLL_SECONDS'" ;; esac
[ "$TIMEOUT_MINUTES" -gt 0 ] || die "timeout-minutes must be greater than 0"
[ "$POLL_SECONDS" -gt 0 ] || die "poll-seconds must be greater than 0"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git work tree"
cd "$ROOT" || die "cannot cd to the repo root"
[ -f package.json ] || die "no package.json at $ROOT"

VERSION="$(node -p "require('./package.json').version" 2>/dev/null)" || die "cannot read the version from package.json"
PKG="$(node -p "require('./package.json').name" 2>/dev/null)" || die "cannot read the name from package.json"
LEDGER="$ROOT/project/logs/publish-history.json"

# The newest `staged` stage_id recorded for this version, or empty.
id_from_ledger() {
  [ -f "$LEDGER" ] || return 0
  node -e '
    const fs = require("fs");
    const [file, version] = process.argv.slice(1);
    let data;
    try { data = JSON.parse(fs.readFileSync(file, "utf8")); } catch { process.exit(0); }
    const rows = Array.isArray(data) ? data : (data.entries || data.records || []);
    const match = rows
      .filter(r => r && r.stage_id && r.platform_state === "staged")
      .filter(r => String(r.version || "").replace(/^v/, "") === version);
    if (match.length) process.stdout.write(String(match[match.length - 1].stage_id));
  ' "$LEDGER" "$VERSION" 2>/dev/null
}

# The newest stage id the registry reports for this version, or empty.
id_from_registry() {
  local json text
  if json="$(npm stage list "$PKG" --json 2>/dev/null)" && [ -n "$json" ]; then
    printf '%s' "$json" | node -e '
      const chunks = [];
      process.stdin.on("data", c => chunks.push(c));
      process.stdin.on("end", () => {
        const version = process.argv[1];
        let data;
        try { data = JSON.parse(chunks.join("")); } catch { return; }
        const rows = Array.isArray(data) ? data : (data.stages || data.results || []);
        const hit = rows.filter(r => r && String(r.version || "").replace(/^v/, "") === version);
        const row = hit.length ? hit[hit.length - 1] : null;
        const id = row && (row.id || row.stageId || row.stage_id);
        if (id) process.stdout.write(String(id));
      });
    ' "$VERSION" 2>/dev/null
    return 0
  fi
  # Plain-text fallback: a line mentioning the version, from which a uuid is taken.
  text="$(npm stage list "$PKG" 2>/dev/null)" || return 0
  printf '%s' "$text" \
    | grep -F "$VERSION" 2>/dev/null \
    | grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
    | tail -n 1
}

note "waiting for ${PKG}@${VERSION} to be staged (timeout ${TIMEOUT_MINUTES}m, polling every ${POLL_SECONDS}s)"

DEADLINE_SECONDS=$((TIMEOUT_MINUTES * 60))
WAITED=0

while :; do
  CANDIDATE="$(id_from_ledger)"
  SOURCE="ledger"
  if [ -z "$CANDIDATE" ]; then
    CANDIDATE="$(id_from_registry)"
    SOURCE="npm stage list"
  fi

  if [ -n "$CANDIDATE" ]; then
    if VIEW="$(npm stage view "$CANDIDATE" 2>&1)"; then
      note "stage $CANDIDATE (from $SOURCE) is ready after ${WAITED}s"
      note "npm stage view output:"
      printf '%s\n' "$VIEW" >&2
      printf '%s' "$CANDIDATE"
      exit 0
    fi
    note "stage id $CANDIDATE found via $SOURCE but 'npm stage view' is not happy yet; still waiting"
  fi

  [ "$WAITED" -ge "$DEADLINE_SECONDS" ] && break
  sleep "$POLL_SECONDS"
  WAITED=$((WAITED + POLL_SECONDS))
  if [ $((WAITED % 120)) -lt "$POLL_SECONDS" ]; then
    note "still waiting for a ready stage of ${VERSION} (${WAITED}s of ${DEADLINE_SECONDS}s)"
  fi
done

note "no ready stage for ${PKG}@${VERSION} within ${TIMEOUT_MINUTES} minutes"
note "check the Actions run (gh run list --workflow npm-publish.yml) and 'npm stage list ${PKG}'"
exit 1
