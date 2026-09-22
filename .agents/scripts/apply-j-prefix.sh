#!/usr/bin/env bash
# scripts/apply-j-prefix.sh — mechanical j. prefix rename for skill invocation
#
# Implements the mechanism decided in docs/skill-authoring.md's "Invocation Convention"
# section (E50_S01_T01), with the separator corrected from ":" to "." in E50_S07_T01:
#
#   1. Frontmatter-only rename. For every skills/<name>/SKILL.md, rewrites the
#      frontmatter `name:` field from `<name>` to `j.<name>`. Directory names are
#      left untouched — neither ":" nor "." is worth putting in a path here, and
#      Claude Code's native skill resolution is a literal-string match against the
#      discovery-path directory name, independent of frontmatter content (see the
#      docs section for the full investigation and citation).
#   2. Bare-form prose rewrite. For every agents/*.md file, rewrites bare
#      "/<name>" invocation mentions in prose to "j.<name>", for every skill name
#      discovered in step 1 — longest-name-first, boundary-safe (skill names
#      contain hyphens, so a naive `\b` regex would misfire — e.g. it would
#      falsely match "/doc" inside "/doc-sync"; this only rewrites a match when
#      the character immediately before/after it is not itself an identifier
#      character: letter, digit, "-", or ":").
#
# Separator history (E50_S07): this script originally emitted "j:<name>". GitHub
# Copilot CLI validates the frontmatter `name:` VALUE and rejects anything outside
# [A-Za-z0-9], hyphen, underscore, dot, and space — so the colon made every skill
# fail to load there. The separator is now "." which is on that allow-list. The
# namespace intent of E50 is unchanged; only the separator character moved.
#
# This script does NOT remove or disable the old bare "/<name>" form. The
# migration decision recorded alongside the mechanism above is "alias" — both
# forms keep resolving. This script only ever writes inside skills/ and
# agents/; it never touches .claude/ or .agents/ (generated mirrors — see
# CLAUDE.md's Source of Truth rule) and makes no other filesystem change.
#
# Usage:
#   scripts/apply-j-prefix.sh [--dry-run] [--skills-only | --agents-only]
#
#   --dry-run       Print the full change list without writing anything.
#                    Exit code is 0 whether or not changes were found (unless
#                    --skills-only/--agents-only surface a hard error, e.g. a
#                    frontmatter `name:` that doesn't match its directory).
#   --skills-only   Only process skills/*/SKILL.md frontmatter (step 1).
#   --agents-only   Only process agents/*.md prose (step 2).
#
# Idempotent: already-migrated skills (name already starts with "j.") are
# silently skipped, not re-applied or reported as an error. Skills still carrying
# the legacy "j:<name>" form are REPAIRED to "j.<name>" rather than skipped —
# skipping them would silently leave a Copilot-breaking name in place.
#
# Retire-or-fix decision (E50_S14_T02, 2026-09-19): kept, not retired — see
# docs/skill-authoring.md's "The Canonical Naming Contract" > "Generation" subsection
# for the full reasoning. Fixed in place for E50_S10's settled contract (canonical
# directory skills/j-<name>/, frontmatter name: j.<name> — NOT j.j-<name>):
#   - Step 1's directory-name<->frontmatter-name check no longer requires exact
#     string equality; it strips a "j-" directory prefix before comparing, so the
#     settled j-<name>/j.<name> pairing is accepted rather than always rejected.
#   - Step 2's prose rewrite strips a discovered "j-<name>" directory's "j-" prefix
#     before emitting "j.<name>", so it never emits the doubled "j.j-<name>" form.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# E50_S14_T02: disabled rather than left as an accepted info-level finding — this
# script's AC requires a clean default-level shellcheck run, and the sourced file does
# exist; shellcheck simply will not follow it without -x (same fix already applied to
# scripts/build-pages-site.sh).
# shellcheck source=lib/resolve-project-dir.sh disable=SC1091
source "$SCRIPT_DIR/../lib/resolve-project-dir.sh"

PROJECT_DIR="$JENGA_PROJECT_DIR"
SKILLS_DIR="$PROJECT_DIR/skills"
AGENTS_DIR="$PROJECT_DIR/agents"

DRY_RUN=0
DO_SKILLS=1
DO_AGENTS=1

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --skills-only) DO_AGENTS=0 ;;
    --agents-only) DO_SKILLS=0 ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--dry-run] [--skills-only | --agents-only]"
      exit 0
      ;;
    *)
      echo "❌ Unknown argument: $arg" >&2
      echo "Usage: $(basename "$0") [--dry-run] [--skills-only | --agents-only]" >&2
      exit 1
      ;;
  esac
done

export DRY_RUN DO_SKILLS DO_AGENTS SKILLS_DIR AGENTS_DIR

python3 - <<'PY'
import os
import re
import sys

skills_dir = os.environ["SKILLS_DIR"]
agents_dir = os.environ["AGENTS_DIR"]
dry_run = os.environ["DRY_RUN"] == "1"
do_skills = os.environ["DO_SKILLS"] == "1"
do_agents = os.environ["DO_AGENTS"] == "1"

changes = []
errors = []

# ---- Step 1: discover skills + (optionally) rewrite frontmatter name: field ----
skill_names = []  # bare directory names, in sorted order
name_re = re.compile(r'^name:\s*(.+?)\s*$')

if os.path.isdir(skills_dir):
    for entry in sorted(os.listdir(skills_dir)):
        skill_path = os.path.join(skills_dir, entry, "SKILL.md")
        if not os.path.isfile(skill_path):
            continue  # not a skill dir (e.g. skills/index/ has no SKILL.md)

        with open(skill_path, "r", encoding="utf-8") as f:
            lines = f.readlines()

        if not lines or lines[0].strip() != "---":
            errors.append(f"{skill_path}: no frontmatter block found")
            continue

        close_idx = None
        for i in range(1, len(lines)):
            if lines[i].strip() == "---":
                close_idx = i
                break
        if close_idx is None:
            errors.append(f"{skill_path}: unterminated frontmatter block")
            continue

        name_idx = None
        current_name = None
        for i in range(1, close_idx):
            m = name_re.match(lines[i])
            if m:
                name_idx = i
                current_name = m.group(1).strip('"\'')
                break

        if name_idx is None:
            errors.append(f"{skill_path}: no 'name:' field in frontmatter")
            continue

        skill_names.append(entry)

        if current_name.startswith("j."):
            continue  # already migrated — not an error, nothing to do

        # Legacy "j:<name>" form (emitted by this script before E50_S07_T01).
        # The colon is rejected by GitHub Copilot CLI's skill-name validator, so
        # this is repaired to "j.<name>" rather than skipped as "already migrated".
        base_name = current_name[2:] if current_name.startswith("j:") else current_name

        # E50_S14_T02: under E50_S10's settled contract the canonical skill directory
        # carries a "j-" prefix (skills/j-<name>/) while its frontmatter name is the
        # UNPREFIXED "j.<name>" — deliberately not "j.j-<name>" (see
        # docs/skill-authoring.md's "The Canonical Naming Contract"). A plain
        # base_name != entry equality would reject every "j-<name>" directory by
        # construction (e.g. directory "j-commit", frontmatter "commit", stripped
        # "commit" != "j-commit"). expected_base strips that one directory-name prefix
        # before comparing, so the check still catches a genuine mismatch (a
        # frontmatter name that matches neither the bare nor the "j-"-stripped
        # directory name) without hard-failing on the settled pairing itself.
        expected_base = entry[2:] if entry.startswith("j-") else entry

        if base_name != expected_base:
            errors.append(
                f"{skill_path}: frontmatter name '{current_name}' does not match "
                f"directory name '{entry}' (expected base '{expected_base}') — skipped for safety"
            )
            continue

        if not do_skills:
            continue

        new_line = f"name: j.{expected_base}\n"
        changes.append({
            "type": "frontmatter",
            "file": skill_path,
            "before": lines[name_idx].rstrip("\n"),
            "after": new_line.rstrip("\n"),
        })

        if not dry_run:
            lines[name_idx] = new_line
            with open(skill_path, "w", encoding="utf-8") as f:
                f.writelines(lines)
elif do_skills:
    errors.append(f"skills directory not found: {skills_dir}")

# ---- Step 2: rewrite bare "/<name>" prose mentions in agents/*.md ----
if do_agents and os.path.isdir(agents_dir):
    # Longest name first so "/jenga-permission-level" is matched (and
    # consumed) before the shorter "/jenga" gets a chance to.
    ordered_names = sorted(skill_names, key=len, reverse=True)
    boundary_chars = set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-:"
    )

    def canonical_prose_name(discovered_name):
        """E50_S14_T02: skill_names includes every directory under skills/ that has a
        SKILL.md, which — under E50_S10's settled contract — includes "j-<name>"
        canonical directories alongside the three bare-name exceptions (jenga,
        jenga-permission-level; index has no SKILL.md and never reaches this list).
        A literal prose mention of "/j-<name>" is matched on the RAW discovered name
        (so the pattern still finds it), but the emitted replacement must strip the
        "j-" directory prefix before prepending "j." — otherwise this would emit the
        doubled "j.j-<name>" form the settled contract rejects (see
        docs/skill-authoring.md's "The Canonical Naming Contract"). Bare names
        without a "j-" prefix (including the jenga/jenga-permission-level
        exceptions, which never carry one) are returned unchanged.
        """
        return discovered_name[2:] if discovered_name.startswith("j-") else discovered_name

    for entry in sorted(os.listdir(agents_dir)):
        if not entry.endswith(".md"):
            continue
        agent_path = os.path.join(agents_dir, entry)
        if not os.path.isfile(agent_path):
            continue

        with open(agent_path, "r", encoding="utf-8") as f:
            text = f.read()

        file_changes = 0

        for name in ordered_names:
            pattern = re.compile(r"/" + re.escape(name))
            matches = []
            for m in pattern.finditer(text):
                start, end = m.start(), m.end()
                if start > 0 and text[start - 1] in boundary_chars:
                    continue  # part of a longer token, e.g. "x/status"
                if end < len(text) and text[end] in boundary_chars:
                    continue  # e.g. "/doc" inside "/doc-sync"
                matches.append((start, end))
            for start, end in reversed(matches):
                text = text[:start] + f"j.{canonical_prose_name(name)}" + text[end:]
                file_changes += 1

        if file_changes:
            changes.append({
                "type": "agent-prose",
                "file": agent_path,
                "count": file_changes,
            })
            if not dry_run:
                with open(agent_path, "w", encoding="utf-8") as f:
                    f.write(text)
elif do_agents and not os.path.isdir(agents_dir):
    errors.append(f"agents directory not found: {agents_dir}")

# ---- report ----
mode = "DRY RUN — no files written" if dry_run else "APPLIED"
print(f"apply-j-prefix.sh — {mode}")
print(f"Skills discovered: {len(skill_names)}")
print()

if not changes:
    print("No changes.")
else:
    for c in changes:
        if c["type"] == "frontmatter":
            print(f"[frontmatter] {c['file']}")
            print(f"    - {c['before']}")
            print(f"    + {c['after']}")
        else:
            print(f"[agent-prose] {c['file']} — {c['count']} occurrence(s) rewritten")
    print()
    print(f"Total: {len(changes)} change group(s)")

if errors:
    print()
    print("Errors / skipped:")
    for e in errors:
        print(f"  ⚠ {e}")
    sys.exit(1)

sys.exit(0)
PY
