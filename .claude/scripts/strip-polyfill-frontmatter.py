#!/usr/bin/env python3
"""
E50_S22_T01 — Strip retired-era polyfill boilerplate from j-* skill frontmatter.

For every skills/j-*/SKILL.md file (excluding the 6 natively-authored skills, which
never carried this boilerplate), this script:

  1. Strips the leading prefix "Polyfill alias of the <name> skill under a
     collision-safe directory name. Identical behavior to /<name> — " from the
     frontmatter `description:` field, preserving everything after it verbatim.
  2. Strips the trailing generic clause "Use when the bare /<name> form is shadowed
     by another tool's own built-in command of the same name." if present verbatim.
     (skills/j-init/SKILL.md carries a different, substantive custom clause about a
     real GitHub Copilot collision — that one is intentionally left untouched.)
  3. Special-cases skills/j-idea/SKILL.md: also strips the leftover E50_S21
     "DEPRECATED - use the prefixed 'j-idea' skill instead. " clause.
  4. Removes any "  - polyfill" line from the frontmatter `keywords:` block.

Idempotent and safe to re-run. Reports every file it changes and fails loudly
(non-zero exit) if a file matching the target set doesn't fit the expected pattern,
rather than silently skipping it.

Usage: scripts/strip-polyfill-frontmatter.py [--dry-run]
Run from the repository root.
"""
import glob
import json
import re
import sys

try:
    import yaml
except ImportError:
    yaml = None

NATIVE_SKILLS = {
    "j-cloud-connect",
    "j-dashboard",
    "j-dashboard-share",
    "j-gitignore",
    "j-playbook",
    "j-playbook-new",
}

PREFIX_RE = re.compile(
    r"^description: Polyfill alias of the .+? skill under a collision-safe directory name\. "
    r"Identical behavior to /\S+ — "
)
GENERIC_SUFFIX_RE = re.compile(
    r" Use when the bare /\S+ form is shadowed by another tool's own built-in command of the same name\.$"
)
IDEA_DEPRECATED_RE = re.compile(
    r"^description: DEPRECATED - use the prefixed 'j-idea' skill instead\. "
)
# Matches the preceding newline too, so removal doesn't leave a blank line behind
# (whether "polyfill" sits mid-list or is the last entry right before the closing "---").
POLYFILL_KEYWORD_RE = re.compile(r"\n[ \t]*-[ \t]*polyfill[ \t]*(?=\n)")


def requote_if_unsafe(line):
    """
    Stripping the polyfill prefix can leave a plain-scalar description value that
    starts with a YAML-special character (e.g. j-deep-dive's substantive text is
    the literal ">.", which YAML reads as an invalid block-scalar indicator once it
    is no longer preceded by other text). If the resulting `description: <value>`
    line doesn't parse as valid YAML, re-render it as a double-quoted (JSON-style,
    which is also valid YAML) scalar instead, preserving the value verbatim.
    """
    if yaml is None or not line.startswith("description: "):
        return line
    value = line[len("description: ") :]
    try:
        yaml.safe_load(line)
        return line
    except yaml.YAMLError:
        return "description: " + json.dumps(value)


def process_file(path, dry_run=False):
    with open(path, encoding="utf-8") as f:
        content = f.read()

    if not content.startswith("---\n"):
        return None  # no frontmatter, nothing to do
    end = content.find("\n---", 4)
    if end == -1:
        return None
    frontmatter = content[: end + 4]
    rest = content[end + 4 :]

    lines = frontmatter.split("\n")
    changed = False
    desc_found = False

    for i, line in enumerate(lines):
        if line.startswith("description:"):
            desc_found = True
            original = line
            new_line = PREFIX_RE.sub("description: ", line)
            if new_line == line:
                # Not the polyfill-prefixed shape — leave untouched (native skills).
                continue
            new_line = GENERIC_SUFFIX_RE.sub("", new_line)
            if "/j-idea/" in path or path.endswith("j-idea/SKILL.md"):
                new_line = IDEA_DEPRECATED_RE.sub("description: ", new_line)
            new_line = requote_if_unsafe(new_line)
            if new_line != original:
                lines[i] = new_line
                changed = True

    new_frontmatter = "\n".join(lines)

    # Strip "  - polyfill" keyword lines (including their preceding newline, so no
    # blank line is left behind regardless of position in the list).
    if POLYFILL_KEYWORD_RE.search(new_frontmatter):
        new_frontmatter = POLYFILL_KEYWORD_RE.sub("", new_frontmatter)
        changed = True

    if not changed:
        return False

    new_content = new_frontmatter + rest
    if not dry_run:
        with open(path, "w", encoding="utf-8") as f:
            f.write(new_content)
    return True


def main():
    dry_run = "--dry-run" in sys.argv
    files = sorted(glob.glob("skills/j-*/SKILL.md"))
    changed_files = []
    unmatched_polyfill_prefix = []

    for path in files:
        skill_dir = path.split("/")[1]
        if skill_dir in NATIVE_SKILLS:
            continue

        with open(path, encoding="utf-8") as f:
            head = f.read(4000)
        has_prefix = "Polyfill alias of the" in head

        result = process_file(path, dry_run=dry_run)
        if has_prefix and result is False:
            unmatched_polyfill_prefix.append(path)
        elif result:
            changed_files.append(path)

    print(f"Changed {len(changed_files)} file(s):")
    for p in changed_files:
        print(f"  {p}")

    if unmatched_polyfill_prefix:
        print(
            f"\nERROR: {len(unmatched_polyfill_prefix)} file(s) contain 'Polyfill alias of the' "
            "but did not match the expected description pattern — investigate manually:",
            file=sys.stderr,
        )
        for p in unmatched_polyfill_prefix:
            print(f"  {p}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
