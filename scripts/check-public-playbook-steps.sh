#!/usr/bin/env bash
#
# scripts/check-public-playbook-steps.sh — every public playbook's steps must ship publicly
#
# E50_S20_T01. Guards the invariant that a playbook shipped to the public mirror can actually
# run there: for each playbook JSON that `.publicignore` does NOT block, every step must resolve
# to a skill directory that `.publicignore` also does not block.
#
# Why this exists: `skills/jenga/scripts/load-playbooks.sh` requires every step's
# `skills/<dir>/SKILL.md` to exist, and silently SKIPS the whole playbook (stderr warning only)
# when one is missing. In the private repo every skill is present, so a playbook referencing a
# private-only skill looks perfectly healthy — the breakage appears only in the public mirror,
# where it surfaced as a stage-deploy gate failure rather than as a test failure (E50_S13).
# This check reproduces that condition statically, on the private side, before anything ships.
#
# Blocklist semantics are NOT re-derived here. Classification is delegated to
# scripts/check-publicignore-match.sh, which itself reuses /mirror-public's own
# `rsync --exclude-from=.publicignore` matching — a second, hand-rolled answer to "is this path
# blocked" is exactly the drift this repo has been bitten by before.
#
# Composed steps: a StepObject of the form {"playbook": "<id>"} composes another playbook. Its
# own steps are checked when that playbook is itself public; a public playbook composing a
# BLOCKED playbook is a violation in its own right, since the composed id will not resolve in
# the mirror (see tests/load-playbooks-composition.bats's nonexistent-playbook-id behaviour).
#
# Usage:
#   scripts/check-public-playbook-steps.sh [<repo-root>]
#
# Exit codes:
#   0  every public playbook's every step (and composed playbook) is public
#   1  at least one violation — each is named on stdout
#   2  usage / environment error (bad root, missing helper, unparseable playbook)

set -euo pipefail

REPO_ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

if [ ! -d "$REPO_ROOT" ]; then
  echo "check-public-playbook-steps.sh: error: not a directory: $REPO_ROOT" >&2
  exit 2
fi

PLAYBOOKS_DIR="$REPO_ROOT/skills/jenga/playbooks"
MATCHER="$REPO_ROOT/scripts/check-publicignore-match.sh"

if [ ! -f "$REPO_ROOT/.publicignore" ]; then
  echo "check-public-playbook-steps.sh: no .publicignore at $REPO_ROOT — nothing to enforce, skipping"
  exit 0
fi

if [ ! -f "$MATCHER" ]; then
  echo "check-public-playbook-steps.sh: error: missing $MATCHER (the single source of blocklist semantics)" >&2
  exit 2
fi

if [ ! -d "$PLAYBOOKS_DIR" ]; then
  echo "check-public-playbook-steps.sh: no playbooks directory at $PLAYBOOKS_DIR — nothing to check"
  exit 0
fi

# classify <path-relative-to-repo-root> -> echoes PUBLIC or BLOCKED
classify() {
  bash "$MATCHER" "$1" 2>/dev/null | head -1 | cut -f1
}

violations=0
checked=0
skipped_private=0

for pb in "$PLAYBOOKS_DIR"/*.json; do
  [ -f "$pb" ] || continue
  base="$(basename "$pb")"
  # schema.json describes playbooks, it is not one.
  [ "$base" = "schema.json" ] && continue

  rel="skills/jenga/playbooks/$base"
  if [ "$(classify "$rel")" = "BLOCKED" ]; then
    skipped_private=$((skipped_private + 1))
    continue
  fi

  checked=$((checked + 1))

  # Emit one "<kind>\t<value>" line per step. A bare string and {"skill": ...} are both skills;
  # {"playbook": ...} is a composition.
  steps="$(python3 -c '
import json, sys
with open(sys.argv[1]) as fh:
    pb = json.load(fh)
for s in pb.get("steps", []):
    if isinstance(s, str):
        print("skill\t" + s)
    elif isinstance(s, dict):
        if "skill" in s:
            print("skill\t" + str(s["skill"]))
        elif "playbook" in s:
            print("playbook\t" + str(s["playbook"]))
' "$pb")" || {
    echo "check-public-playbook-steps.sh: error: could not parse $rel" >&2
    exit 2
  }

  while IFS=$'\t' read -r kind value; do
    [ -n "${kind:-}" ] || continue
    case "$kind" in
      skill)
        target="skills/$value/SKILL.md"
        if [ ! -f "$REPO_ROOT/$target" ]; then
          echo "VIOLATION  $rel -> step '$value': no $target on disk"
          violations=$((violations + 1))
        elif [ "$(classify "$target")" = "BLOCKED" ]; then
          echo "VIOLATION  $rel -> step '$value': $target is blocklisted, so this public playbook cannot load in the mirror"
          violations=$((violations + 1))
        fi
        ;;
      playbook)
        target="skills/jenga/playbooks/$value.json"
        if [ ! -f "$REPO_ROOT/$target" ]; then
          echo "VIOLATION  $rel -> composes '$value': no $target on disk"
          violations=$((violations + 1))
        elif [ "$(classify "$target")" = "BLOCKED" ]; then
          echo "VIOLATION  $rel -> composes '$value': $target is blocklisted, so the composed id will not resolve in the mirror"
          violations=$((violations + 1))
        fi
        ;;
    esac
  done <<< "$steps"
done

if [ "$violations" -gt 0 ]; then
  echo "check-public-playbook-steps.sh: $violations violation(s) across $checked public playbook(s) ($skipped_private private playbook(s) not checked)"
  exit 1
fi

echo "check-public-playbook-steps.sh: OK — $checked public playbook(s) checked, every step ships publicly ($skipped_private private playbook(s) skipped)"
exit 0
