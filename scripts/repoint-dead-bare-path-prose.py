#!/usr/bin/env python3
"""
E50_S22_T03 — Repoint the remaining dead bare skills/<name>/ prose references and
fix two stale scripts/generate-j-alias.sh comments in mirror.sh.

Context: the story's Findings table counted 81 dead bare-skills/<name>/ references
across skills/j-*/SKILL.md bodies. T01 (frontmatter) and T02 (body preamble
rewrite) already resolved 79 of those 81 as a side effect of rewriting the exact
text blocks that contained them — T02's replacement text reintroduces one bare
reference per file, but explicitly in past tense ("was previously generated from
a bare `skills/<name>/SKILL.md` source; `E50_S15` deleted that directory"), which
is deliberate historical narration this task's own AC requires preserving.

Of the remaining references, only two required an actual fix:
  1. skills/j-do/SKILL.md's illustrative example "(e.g. `skills/do/SKILL.md`)" —
     not historical narration, just an example that should use the current path.
  2. Two comments in skills/j-mirror-public/scripts/mirror.sh (L1363, L1523) that
     still describe scripts/generate-j-alias.sh as a live generator.

Both are exact string replacements, verified present verbatim before substitution
so a mismatch fails loudly rather than silently no-op'ing.

Usage: scripts/repoint-dead-bare-path-prose.py [--dry-run]
Run from the repository root.
"""
import sys

REPLACEMENTS = [
    (
        "skills/j-do/SKILL.md",
        "(e.g. `skills/do/SKILL.md`).",
        "(e.g. `skills/j-do/SKILL.md`).",
    ),
    (
        "skills/j-mirror-public/scripts/mirror.sh",
        "# skills/j-<name>/ twins are generated (scripts/generate-j-alias.sh) with",
        "# skills/j-<name>/ twins were generated (scripts/generate-j-alias.sh, retired by E50_S14) with",
    ),
    (
        "skills/j-mirror-public/scripts/mirror.sh",
        'log "orphaned-twin rewrite: frontmatter scripts/generate-j-alias.sh currently writes."',
        'log "orphaned-twin rewrite: standard hand-authored frontmatter shape (scripts/generate-j-alias.sh was retired by E50_S14)."',
    ),
]


def main():
    dry_run = "--dry-run" in sys.argv
    changed = []

    for path, old, new in REPLACEMENTS:
        with open(path, encoding="utf-8") as f:
            content = f.read()
        count = content.count(old)
        if count == 0:
            print(f"ERROR: expected text not found verbatim in {path}:", file=sys.stderr)
            print(repr(old), file=sys.stderr)
            sys.exit(1)
        if count > 1:
            print(
                f"ERROR: expected text matched {count} times in {path} (expected exactly 1) — "
                "refusing to guess which one:",
                file=sys.stderr,
            )
            print(repr(old), file=sys.stderr)
            sys.exit(1)
        if old == new:
            continue
        new_content = content.replace(old, new, 1)
        if not dry_run:
            with open(path, "w", encoding="utf-8") as f:
                f.write(new_content)
        changed.append(path)

    print(f"Changed {len(changed)} file(s):")
    for p in changed:
        print(f"  {p}")


if __name__ == "__main__":
    main()
