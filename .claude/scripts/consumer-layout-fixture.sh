#!/usr/bin/env bash
# scripts/consumer-layout-fixture.sh — build (or refresh) a throwaway consumer project that has the same
# layout a real `npm install @jenga-ai/agent` leaves behind:
#
#   <dest>/node_modules/@jenga-ai/agent/   the whole package (scripts/, templates/, lib/, skills/, ...)
#   <dest>/.claude/{skills,agents}/        the postinstall mirror: ONLY skills/ and agents/
#   <dest>/.agents/{skills,agents}/        same, for non-Claude agents
#   <dest>/project/configs/workflow.json   a registry, so scripts that resolve the working tree find one
#
# It is the fast, offline stand-in for the real thing (`npm pack` + install + postinstall, which
# scripts/consumer-smoke-after-sync.sh does). Use it to check that a skill script run from `.claude/skills/`
# finds package assets in node_modules and not under `.claude/`.
#
# Usage:  consumer-layout-fixture.sh <dest> [<repo-root>]
# Output: the fixture path on stdout. Idempotent: re-running refreshes the copies in place (rsync --delete
# on the package and the mirrors; anything else already in <dest> is left alone).
# Exit:   0 ok, 2 usage / missing source.

set -u

dest="${1:-}"
[ -n "$dest" ] || { echo "usage: consumer-layout-fixture.sh <dest> [<repo-root>]" >&2; exit 2; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${2:-$(cd "$here/.." && pwd)}"
[ -d "$repo/skills" ] && [ -d "$repo/templates" ] || { echo "consumer-layout-fixture.sh: $repo is not a Jenga package root" >&2; exit 2; }
command -v rsync >/dev/null 2>&1 || { echo "consumer-layout-fixture.sh: rsync is required" >&2; exit 2; }

mkdir -p "$dest/node_modules/@jenga-ai/agent" "$dest/.claude" "$dest/.agents" "$dest/project/configs" || exit 2
dest="$(cd "$dest" && pwd -P)"

# What `npm pack` would ship is narrower than the repo, but a superset is the safe direction here: it can
# only hide a missing asset, never invent one, and the exclusions below cover everything private.
rsync -a --delete \
  --exclude node_modules --exclude .git --exclude .claude --exclude .agents \
  --exclude project --exclude site --exclude tests --exclude worktrees \
  "$repo/" "$dest/node_modules/@jenga-ai/agent/" || exit 2

for root in .claude .agents; do
  mkdir -p "$dest/$root/skills" "$dest/$root/agents"
  rsync -a --delete "$repo/skills/" "$dest/$root/skills/" || exit 2
  rsync -a --delete "$repo/agents/" "$dest/$root/agents/" || exit 2
done

if [ ! -f "$dest/project/configs/workflow.json" ]; then
  if [ -f "$repo/templates/workflow.json" ]; then cp "$repo/templates/workflow.json" "$dest/project/configs/workflow.json"
  elif [ -f "$repo/project/configs/workflow.json" ]; then cp "$repo/project/configs/workflow.json" "$dest/project/configs/workflow.json"
  else printf '{}\n' > "$dest/project/configs/workflow.json"; fi
fi
[ -d "$dest/.git" ] || git -C "$dest" init -q . 2>/dev/null || true

printf '%s\n' "$dest"
