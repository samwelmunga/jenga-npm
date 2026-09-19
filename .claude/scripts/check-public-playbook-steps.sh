#!/usr/bin/env bash
#
# scripts/check-public-playbook-steps.sh — public playbook health guard
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
# blocked" is exactly the drift this repo has been bitten by before. This holds for EVERY source
# directory scanned below, including the project-local one added by E28_S14_T02.
#
# Playbook sources (E28_S14_T02): both directories `load-playbooks.sh` merges into one catalog,
# in the same order — the framework-owned BUILTIN source `skills/jenga/playbooks/`, and the
# project-owned PROJECT source `project/.playbooks/` (E53_S09_T01). A missing BUILTIN directory
# exits 0 with a message (there is nothing to guard at all); a missing PROJECT directory is a
# SILENT no-op, never an error, matching the loader's own behaviour for the common case of a
# project with no custom playbooks.
#
# As of E28_S14_T01 `.publicignore` blocks `project/.playbooks/` in full, so in this repo every
# project-local playbook classifies BLOCKED and is counted as private/skipped. That is the
# expected steady state. Scanning the directory anyway is the point: the invariant then holds
# MECHANICALLY rather than resting on the blocklist staying as it is — if anyone unblocks the
# directory later, the guard covers it with no further change here.
#
# Composed steps: a StepObject of the form {"playbook": "<id>"} composes another playbook. Its
# own steps are checked when that playbook is itself public; a public playbook composing a
# BLOCKED playbook is a violation in its own right, since the composed id will not resolve in
# the mirror (see tests/load-playbooks-composition.bats's nonexistent-playbook-id behaviour).
# A composed id is resolved against BOTH source directories in order, because load-playbooks.sh
# merges both into one catalog before resolving compositions — so a composed id can legally live
# in either, and a public playbook composing a (private) project-local one is a real violation.
#
# Terminal-step deny-list (E28_S14_T02, enforcing E53_S10's policy): "is this step blocklisted?"
# is a LOADABILITY question and cannot catch a publish step, because `j-publish` ships publicly.
# A public playbook chaining it therefore passes the blocklist check completely clean while
# violating the policy outright. The DATA block below closes that gap. See docs/skill-authoring.md
# ("Public Playbooks Terminate at `j-commit`") and docs/public-mirror-content-parity.md.
#
# Usage:
#   scripts/check-public-playbook-steps.sh [<repo-root>]
#
# Exit codes:
#   0  every public playbook's every step (and composed playbook) is public and policy-compliant
#   1  at least one violation — each is named on stdout
#   2  usage / environment error (bad root, missing helper, unparseable playbook)

set -euo pipefail

# ---------------------------------------------------------------------------
# DATA — terminal-step deny-list (E28_S14_T02)
#
# Standing product decision (user, 2026-09-17, E53_S10), quoted verbatim in every violation
# this list produces:
#
#   "No public playbook may contain a publishing or mirroring step; public build chains
#    terminate at `j-commit`."
#
# Rationale lives in docs/skill-authoring.md's "Public Playbooks Terminate at `j-commit`"
# section: most users would not want a playbook that publishes or pushes to a public destination
# on their behalf, so publishing stays an explicit, separately invoked act. Note the rule forbids
# publish/mirror STEPS — it is not a requirement that every playbook end at `j-commit`; a
# read-only or triage chain ending elsewhere publishes nothing and is compliant.
#
# TO ADD A SKILL: add one line to this array. That is the whole edit. Nothing in the checking
# logic below names any individual skill — it asks is_denylisted_step(), which loops this array.
#
# Both naming forms are listed on purpose. The canonical directory is `skills/j-<name>/`, but the
# bare-name directories still exist on disk (deleted by E50_S15), and a playbook step is matched
# by the directory name it references — so a step could legitimately be written either way until
# that cutover lands. Over-listing costs nothing here; under-listing is a policy hole.
# ---------------------------------------------------------------------------
DENYLISTED_STEPS=(
  j-publish
  publish
  j-mirror-public
  mirror-public
)

# The policy sentence, verbatim. Kept as data alongside the list it explains so a violation
# message never paraphrases the rule it is enforcing.
DENYLIST_POLICY='No public playbook may contain a publishing or mirroring step; public build chains terminate at `j-commit`.'

REPO_ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

if [ ! -d "$REPO_ROOT" ]; then
  echo "check-public-playbook-steps.sh: error: not a directory: $REPO_ROOT" >&2
  exit 2
fi

# Playbook source directories, repo-relative, in load-playbooks.sh's own merge order.
# Index 0 is the BUILTIN source and is required; every later entry is optional (silent no-op).
PLAYBOOK_SOURCE_DIRS=(
  "skills/jenga/playbooks"
  "project/.playbooks"
)

BUILTIN_PLAYBOOKS_DIR="$REPO_ROOT/${PLAYBOOK_SOURCE_DIRS[0]}"
MATCHER="$REPO_ROOT/scripts/check-publicignore-match.sh"

if [ ! -f "$REPO_ROOT/.publicignore" ]; then
  echo "check-public-playbook-steps.sh: no .publicignore at $REPO_ROOT — nothing to enforce, skipping"
  exit 0
fi

if [ ! -f "$MATCHER" ]; then
  echo "check-public-playbook-steps.sh: error: missing $MATCHER (the single source of blocklist semantics)" >&2
  exit 2
fi

if [ ! -d "$BUILTIN_PLAYBOOKS_DIR" ]; then
  echo "check-public-playbook-steps.sh: no playbooks directory at $BUILTIN_PLAYBOOKS_DIR — nothing to check"
  exit 0
fi

# classify <path-relative-to-repo-root> -> echoes PUBLIC or BLOCKED
classify() {
  bash "$MATCHER" "$1" 2>/dev/null | head -1 | cut -f1
}

# is_denylisted_step <step-name> -> exit 0 if the step is on DENYLISTED_STEPS, 1 otherwise.
# Deliberately the ONLY place the deny-list is consulted, and it names no skill itself.
is_denylisted_step() {
  local candidate="$1" entry
  for entry in "${DENYLISTED_STEPS[@]}"; do
    if [ "$entry" = "$candidate" ]; then
      return 0
    fi
  done
  return 1
}

# resolve_playbook_rel <playbook-id> -> echoes the repo-relative path of the first source
# directory containing <id>.json, or nothing if no source has it. Mirrors the fact that
# load-playbooks.sh merges every source into one catalog before resolving compositions.
resolve_playbook_rel() {
  local id="$1" dir
  for dir in "${PLAYBOOK_SOURCE_DIRS[@]}"; do
    if [ -f "$REPO_ROOT/$dir/$id.json" ]; then
      printf '%s/%s.json\n' "$dir" "$id"
      return 0
    fi
  done
  return 0
}

violations=0
checked=0
skipped_private=0

for source_dir in "${PLAYBOOK_SOURCE_DIRS[@]}"; do
  abs_source_dir="$REPO_ROOT/$source_dir"
  # A missing optional source (in practice project/.playbooks/) is a no-op, not an error —
  # the same silent behaviour load-playbooks.sh gives it. The required BUILTIN source was
  # already checked above.
  [ -d "$abs_source_dir" ] || continue

  for pb in "$abs_source_dir"/*.json; do
    [ -f "$pb" ] || continue
    base="$(basename "$pb")"
    # schema.json describes playbooks, it is not one.
    [ "$base" = "schema.json" ] && continue

    rel="$source_dir/$base"
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
          # Policy first, and exclusive: a deny-listed step yields exactly one violation even
          # when it is ALSO blocklisted (j-mirror-public is both). The policy breach is the more
          # fundamental statement about the playbook, so it is the one reported.
          if is_denylisted_step "$value"; then
            echo "VIOLATION  $rel -> step '$value': publishing/mirroring step in a public playbook — policy (E53_S10): \"$DENYLIST_POLICY\""
            violations=$((violations + 1))
            continue
          fi
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
          target="$(resolve_playbook_rel "$value")"
          if [ -z "$target" ]; then
            echo "VIOLATION  $rel -> composes '$value': no $value.json under ${PLAYBOOK_SOURCE_DIRS[*]}"
            violations=$((violations + 1))
          elif [ "$(classify "$target")" = "BLOCKED" ]; then
            echo "VIOLATION  $rel -> composes '$value': $target is blocklisted, so the composed id will not resolve in the mirror"
            violations=$((violations + 1))
          fi
          ;;
      esac
    done <<< "$steps"
  done
done

if [ "$violations" -gt 0 ]; then
  echo "check-public-playbook-steps.sh: $violations violation(s) across $checked public playbook(s) ($skipped_private private playbook(s) not checked)"
  exit 1
fi

echo "check-public-playbook-steps.sh: OK — $checked public playbook(s) checked, every step ships publicly ($skipped_private private playbook(s) skipped)"
exit 0
