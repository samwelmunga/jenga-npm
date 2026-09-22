#!/usr/bin/env python3
"""
E50_S22_T02 — Rewrite the 37 stale generator-era body preambles to the canonical
hand-edited framing.

37 of the skills/j-*/SKILL.md files open their body (directly under the H1) with a
two-paragraph preamble describing the retired twin-generation era: a bare
skills/<name>/ "source" this file was supposedly generated from, and a warning to
re-run scripts/generate-j-alias.sh instead of hand-editing. Both the bare
directories (E50_S15) and the generator itself (E50_S14) are gone.

This script:
  1. Replaces that two-paragraph block, per file, with the canonical/hand-edited
     framing already used by skills/j-do/SKILL.md and skills/j-dev-done/SKILL.md,
     name-substituted.
  2. Corrects skills/j-do/SKILL.md's and skills/j-dev-done/SKILL.md's own existing
     warning text, which predates E50_S15 landing and still claims a bare copy is
     "awaiting deletion" and warns against running a generator that no longer
     exists at all.
  3. Rewrites j-dev-done's "Known divergence" paragraph, which asserted (future
     tense) that the bare /dev-done form "still exhibits" old behavior "until
     E50_S15 deletes it" — E50_S15 already landed, so this is restated as a past-
     tense historical note.

Idempotent and safe to re-run (already-corrected files simply won't match and are
skipped). Fails loudly (non-zero exit) if a file containing the trigger phrase
"literal-directory-name duplicate" doesn't fit the fully-verified-uniform pattern,
rather than silently leaving it unrewritten.

Usage: scripts/rewrite-stale-skill-preambles.py [--dry-run]
Run from the repository root.
"""
import glob
import re
import sys

TRIGGER = "literal-directory-name duplicate"

STALE_PREAMBLE_RE = re.compile(
    r"This skill is a literal-directory-name duplicate of `skills/(?P<name>[a-z0-9-]+)/`\. "
    r"It exists so that `/j-(?P=name)` \(and `j\.j-(?P=name)`\) give a guaranteed-unshadowed "
    r"way to reach the same flow as `/(?P=name)`, even if a host tool's own built-in command "
    r"of the same name would otherwise shadow or override the bare `/(?P=name)` alias "
    r"\(Claude Code's native skill resolution is a literal-string, directory-name-based match "
    r"— see `docs/skill-authoring\.md`'s \"Invocation Convention\"\)\.\n\n"
    r"This file is generated/synced by `scripts/generate-j-alias\.sh (?P=name)` from "
    r"`skills/(?P=name)/SKILL\.md` — do not hand-edit it; re-run the generator instead to "
    r"pick up source changes\."
)


def canonical_replacement(name):
    return (
        f"`skills/j-{name}/` is the **canonical, hand-edited** directory for this skill, per "
        "CLAUDE.md's \"The Canonical Naming Contract\" (the `E50` reopening of 2026-09-09, "
        f"which promoted `skills/j-{name}/` from generated twin to sole canonical form). The "
        "`j-` prefix is there for collision safety — a real directory under a distinct name, so "
        "a host tool shipping its own same-named built-in command cannot shadow it (Claude "
        "Code's native skill resolution is a literal-string, directory-name-based match; see "
        "`docs/skill-authoring.md`'s \"Invocation Convention\").\n\n"
        "> ⚠️ **`scripts/generate-j-alias.sh` was retired by `E50_S14` and no longer exists — "
        "there is nothing to run.** This file was previously generated from a bare "
        f"`skills/{name}/SKILL.md` source; `E50_S15` deleted that directory. This file is now "
        "the sole canonical, hand-edited source for this skill — edit it directly."
    )


# --- j-do and j-dev-done: targeted corrections to their already-correct-model text ---

J_DO_OLD = (
    "> ⚠️ **Do not run `scripts/generate-j-alias.sh do` against this directory.** This file was\n"
    "> previously generated from `skills/do/SKILL.md`, and carried a banner saying so. That relationship\n"
    "> is inverted under the contract above: edits land here first, and `skills/do/` is the copy awaiting\n"
    "> deletion by `E50_S15`. Regenerating would overwrite this file from the stale bare directory.\n"
    "> CLAUDE.md states the same prohibition in general terms; this is the concrete instance of it."
)
J_DO_NEW = (
    "> ⚠️ **`scripts/generate-j-alias.sh` was retired by `E50_S14` and no longer exists — there is\n"
    "> nothing to run.** This file was previously generated from a bare `skills/do/SKILL.md` source;\n"
    "> `E50_S15` deleted that directory. This file is now the sole canonical, hand-edited source for\n"
    "> this skill — edit it directly."
)

J_DEV_DONE_OLD_WARNING = (
    "> ⚠️ **Do not run `scripts/generate-j-alias.sh dev-done` against this directory.** This file was\n"
    "> previously generated from `skills/dev-done/SKILL.md`, and carried a banner saying so. That\n"
    "> relationship is inverted under the contract above: edits land here first, and `skills/dev-done/` is\n"
    "> the copy awaiting deletion by `E50_S15`. Regenerating would overwrite this file from the stale bare\n"
    "> directory and silently drop the post-sync commit step below. CLAUDE.md states the same prohibition\n"
    "> in general terms; this is the concrete instance of it."
)
J_DEV_DONE_NEW_WARNING = (
    "> ⚠️ **`scripts/generate-j-alias.sh` was retired by `E50_S14` and no longer exists — there is\n"
    "> nothing to run.** This file was previously generated from a bare `skills/dev-done/SKILL.md`\n"
    "> source; `E50_S15` deleted that directory. This file is now the sole canonical, hand-edited\n"
    "> source for this skill — edit it directly."
)

J_DEV_DONE_OLD_DIVERGENCE = (
    "> **Known divergence:** `skills/dev-done/` does **not** carry the post-sync commit step. Until\n"
    "> `E50_S15` deletes it, the bare `/dev-done` form still exhibits the original\n"
    "> leaves-the-tree-dirty behavior. Invoke `/j-dev-done` to get the fix."
)
J_DEV_DONE_NEW_DIVERGENCE = (
    "> **Historical note:** before `E50_S15` deleted the bare `skills/dev-done/` directory, that\n"
    "> copy did not carry the post-sync commit step below — this canonical file was already ahead\n"
    "> of it. That divergence is now moot; there is no bare form left to diverge from."
)


def process_generic_file(path, dry_run=False):
    with open(path, encoding="utf-8") as f:
        content = f.read()
    if TRIGGER not in content:
        return None
    match = STALE_PREAMBLE_RE.search(content)
    if not match:
        return "unmatched"
    name = match.group("name")
    new_content = content[: match.start()] + canonical_replacement(name) + content[match.end() :]
    if not dry_run:
        with open(path, "w", encoding="utf-8") as f:
            f.write(new_content)
    return True


def process_special_file(path, old_new_pairs, dry_run=False):
    with open(path, encoding="utf-8") as f:
        content = f.read()
    changed = False
    for old, new in old_new_pairs:
        if old not in content:
            print(f"ERROR: expected text not found verbatim in {path}:", file=sys.stderr)
            print(repr(old), file=sys.stderr)
            sys.exit(1)
        content = content.replace(old, new, 1)
        changed = True
    if changed and not dry_run:
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
    return changed


def main():
    dry_run = "--dry-run" in sys.argv
    files = sorted(glob.glob("skills/j-*/SKILL.md"))
    changed_files = []
    unmatched = []

    for path in files:
        if path in ("skills/j-do/SKILL.md", "skills/j-dev-done/SKILL.md"):
            continue
        result = process_generic_file(path, dry_run=dry_run)
        if result == "unmatched":
            unmatched.append(path)
        elif result:
            changed_files.append(path)

    if process_special_file("skills/j-do/SKILL.md", [(J_DO_OLD, J_DO_NEW)], dry_run=dry_run):
        changed_files.append("skills/j-do/SKILL.md")

    if process_special_file(
        "skills/j-dev-done/SKILL.md",
        [
            (J_DEV_DONE_OLD_WARNING, J_DEV_DONE_NEW_WARNING),
            (J_DEV_DONE_OLD_DIVERGENCE, J_DEV_DONE_NEW_DIVERGENCE),
        ],
        dry_run=dry_run,
    ):
        changed_files.append("skills/j-dev-done/SKILL.md")

    print(f"Changed {len(changed_files)} file(s):")
    for p in sorted(changed_files):
        print(f"  {p}")

    if unmatched:
        print(
            f"\nERROR: {len(unmatched)} file(s) contain the trigger phrase but did not match the "
            "expected preamble pattern — investigate manually:",
            file=sys.stderr,
        )
        for p in unmatched:
            print(f"  {p}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
