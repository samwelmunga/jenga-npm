#!/usr/bin/env bash
# scripts/check-site-links.sh
#
# Verifies every intra-site link in the GitHub Pages site source. A link is
# resolved against the pages' *declared* `permalink:` front matter, not against
# a filename guess, and an `#anchor` is resolved against the target page's
# actual headings.
#
# WHY THIS EXISTS (E70_S01_T04): the site's intra-site links were written three
# different ways (`](./x.md)`, `](x.md)`, `](x.html)`), which meant E70_S02's
# repoint into site/ could not be a pure path move. They are now normalised to
# one form, and this script is what keeps them that way:
#
#   - E70_S01_T04 proves the normalisation resolved cleanly
#   - E70_S02 repoints these same pages into site/ and re-runs this
#   - E70_S05 verifies published URLs after the cutover and re-runs this
#
# THE ONE CORRECT LINK FORM is a bare relative `<name>.html`, matching each
# page's own `permalink: /<name>.html`. Every permalink is root-level, so every
# page is served as a sibling of every other page and a bare relative link
# resolves identically no matter which source directory the file lives in —
# that is what makes the E70_S02 move a pure path move.
#
# A root-absolute `/<name>.html` is NOT equivalent and is rejected: the site's
# _config.yml sets no `baseurl`, and the site is served from a GitHub Pages
# project site under a path prefix, so a leading slash drops the prefix and
# 404s. This script flags the root-absolute form so nobody "tidies" the links
# into it later.
#
# WHAT COUNTS AS A SITE PAGE: a markdown file whose first line is `---`, i.e.
# one Jekyll renders. A markdown file with no front matter is reported as
# skipped rather than checked. (Historically that meant docs/README.md and
# docs/jenga-config.md; E70_S02_T01 moved the former out of the site source
# entirely and E70_S02_T02 gave the latter front matter, so the site currently
# has no skipped file.)
#
# THE SITE SOURCE IS NESTED (E70_S02_T02): pages live in site/guides/ and
# site/reference/, not at the source root, so the page walk below recurses.
# A depth-1 walk would find only site/index.md. Pages are still keyed by
# basename, which is unique across all 10 markdown pages; the subdirectory a
# page lives in is deliberately irrelevant to link resolution, because every
# permalink is flat.
#
# ANCHOR SLUGS follow kramdown-parser-gfm's `generate_gfm_header_id`, because
# Jekyll defaults to `kramdown: input: GFM`: downcase, drop every character
# outside [word character, space, hyphen], then whitespace to hyphen. Note this
# KEEPS leading digits (unlike plain kramdown's generator, which strips leading
# non-letters) — getting-started.md's numbered table of contents depends on it.
#
# Both passes are fence-aware: `#` lines and `](...)` links inside ``` fences
# are ignored, so shell comments in example blocks do not invent heading slugs
# and illustrative links in code samples are not checked.
#
# Usage:
#   scripts/check-site-links.sh [--site-dir <dir>] [--quiet]
#
#     --site-dir <dir>  Site source to check. Default: <repo root>/site
#     --quiet           Print only the summary and any failures.
#     -h, --help        Print this usage block and exit 0.
#
# Exit codes:
#   0  every intra-site link and anchor resolves
#   1  usage error, or the site directory has no pages
#   2  at least one broken link, unresolved anchor, or un-normalised link form

set -euo pipefail

# shellcheck source=lib/resolve-project-dir.sh disable=SC1091
source "$(git rev-parse --show-toplevel)/lib/resolve-project-dir.sh"

SITE_DIR="$JENGA_PROJECT_DIR/site"
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --site-dir)
      [ $# -ge 2 ] || { echo "check-site-links.sh: --site-dir needs a value" >&2; exit 1; }
      SITE_DIR="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help)
      sed -n '/^# Usage:/,$p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "check-site-links.sh: unknown argument: $1" >&2
      echo "Usage: scripts/check-site-links.sh [--site-dir <dir>] [--quiet]" >&2
      exit 1 ;;
  esac
done

if [ ! -d "$SITE_DIR" ]; then
  echo "check-site-links.sh: site directory not found: $SITE_DIR" >&2
  exit 1
fi

SITE_DIR="$(cd "$SITE_DIR" && pwd)"
export SITE_DIR QUIET

python3 - <<'PY'
import os, re, sys, glob

site_dir = os.environ["SITE_DIR"]
quiet = os.environ.get("QUIET") == "1"

FENCE = re.compile(r'^\s*(```|~~~)')
HEADING = re.compile(r'^(#{1,6})\s+(.*?)\s*#*\s*$')
# Markdown inline links: ](target)
LINK = re.compile(r'\]\(\s*([^)\s]+?)\s*(?:\s+"[^"]*")?\)')
PERMALINK = re.compile(r'^permalink:\s*(\S+)\s*$')


def gfm_slug(text):
    """kramdown-parser-gfm's generate_gfm_header_id (Jekyll's default)."""
    # Strip inline markdown emphasis/code markers the way the renderer would,
    # by dropping the characters outright in the class filter below.
    s = text.strip().lower()
    # Drop every character that is not a word character, whitespace or hyphen.
    s = re.sub(r'[^\w\s\-]', '', s, flags=re.UNICODE)
    s = re.sub(r'\s', '-', s)
    return s


def read_page(path):
    """Return (has_front_matter, permalink_or_None, slugs, links)."""
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().split("\n")
    if not lines or lines[0].strip() != "---":
        return False, None, set(), []

    permalink = None
    # Front matter runs to the next bare '---'.
    body_start = len(lines)
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            body_start = i + 1
            break
        m = PERMALINK.match(lines[i].strip())
        if m:
            permalink = m.group(1).strip().strip('"').strip("'")

    slugs = {}
    links = []
    in_fence = False
    for n, line in enumerate(lines[body_start:], start=body_start + 1):
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        hm = HEADING.match(line)
        if hm:
            slug = gfm_slug(hm.group(2))
            # Duplicate headings get -1, -2 suffixes, as the renderer does.
            if slug in slugs:
                k = 1
                while f"{slug}-{k}" in slugs:
                    k += 1
                slugs[f"{slug}-{k}"] = n
            else:
                slugs[slug] = n
            continue
        for lm in LINK.finditer(line):
            links.append((n, lm.group(1)))
    return True, permalink, set(slugs), links


pages = {}      # basename -> dict
skipped = []
# Recursive: the site source is nested (site/guides/, site/reference/). Keyed
# by basename because every page's permalink is flat, so which subdirectory a
# page lives in has no bearing on how a link to it resolves.
md_paths = sorted(glob.glob(os.path.join(site_dir, "**", "*.md"), recursive=True))
dupes = {}
for path in md_paths:
    dupes.setdefault(os.path.basename(path), []).append(path)
collisions = {b: ps for b, ps in dupes.items() if len(ps) > 1}
if collisions:
    for b, ps in sorted(collisions.items()):
        print(f"check-site-links.sh: duplicate page basename '{b}': "
              + ", ".join(os.path.relpath(x, site_dir) for x in ps), file=sys.stderr)
    print("check-site-links.sh: basenames must be unique across the site source, "
          "because permalinks are flat and links are resolved by basename.",
          file=sys.stderr)
    sys.exit(1)
for path in md_paths:
    base = os.path.basename(path)
    has_fm, permalink, slugs, links = read_page(path)
    if not has_fm:
        skipped.append(base)
        continue
    pages[base] = {
        "path": path,
        "permalink": permalink,
        "slugs": slugs,
        "links": links,
    }

if not pages:
    print(f"check-site-links.sh: no front-mattered pages found in {site_dir}",
          file=sys.stderr)
    sys.exit(1)

# Resolve a link target to a page. A target is accepted in its bare relative
# form (the one correct form) and recognised-but-flagged in its root-absolute
# form.
by_permalink = {}      # '/x.html' -> basename
for base, p in pages.items():
    if p["permalink"]:
        by_permalink[p["permalink"]] = base

site_page_stems = {os.path.splitext(b)[0] for b in pages} | {
    os.path.splitext(b)[0] for b in skipped
}

errors = []
warnings = []
checked = 0
anchors_checked = 0

for base in sorted(pages):
    page = pages[base]
    page_lines = []
    for lineno, target in page["links"]:
        if re.match(r'^(https?:|mailto:|//)', target):
            continue
        if target.startswith("#"):
            # In-page anchor.
            frag = target[1:]
            checked += 1
            anchors_checked += 1
            if frag not in page["slugs"]:
                errors.append(
                    f"{base}:{lineno}: in-page anchor '#{frag}' matches no heading in {base}")
            else:
                page_lines.append(f"    ok  {target}")
            continue

        bare = target.split("#", 1)
        path_part = bare[0]
        frag = bare[1] if len(bare) > 1 else None

        if path_part.endswith(".md"):
            stem = os.path.splitext(os.path.basename(path_part))[0]
            if stem in site_page_stems:
                checked += 1
                errors.append(
                    f"{base}:{lineno}: un-normalised intra-site link '{target}' "
                    f"— use the permalink form '{stem}.html'"
                    + (f"{'#' + frag if frag else ''}"))
            else:
                # A link out of the site (e.g. ../project/...): existence only.
                resolved = os.path.normpath(
                    os.path.join(os.path.dirname(page["path"]), path_part))
                if not os.path.exists(resolved):
                    warnings.append(
                        f"{base}:{lineno}: link out of the site does not exist on disk: '{target}'")
            continue

        if not path_part.endswith(".html"):
            # Not an intra-site page link (asset, directory, external path).
            continue

        checked += 1
        if path_part.startswith("/"):
            errors.append(
                f"{base}:{lineno}: root-absolute link '{target}' — _config.yml sets no "
                f"baseurl, so a leading slash drops the project-site path prefix and 404s; "
                f"use the bare relative form '{path_part.lstrip('/')}'"
                + (f"#{frag}" if frag else ""))
            continue

        stem = os.path.splitext(os.path.basename(path_part))[0]
        want = "/" + os.path.basename(path_part)
        target_page = by_permalink.get(want)
        if target_page is None:
            errors.append(
                f"{base}:{lineno}: link '{target}' resolves to no declared permalink "
                f"(no site page declares 'permalink: {want}')")
            continue

        if frag:
            anchors_checked += 1
            if frag not in pages[target_page]["slugs"]:
                errors.append(
                    f"{base}:{lineno}: link '{target}' resolves to {target_page}, "
                    f"but '#{frag}' matches no heading there")
                continue
        page_lines.append(f"    ok  {target} -> {target_page} (permalink {want})")

    if not quiet:
        print(f"  {base}  [permalink: {page['permalink'] or '(none)'}]")
        if page_lines:
            for l in page_lines:
                print(l)
        else:
            print("    (no intra-site links)")

print()
print(f"site dir          : {site_dir}")
print(f"pages checked     : {len(pages)}")
print(f"intra-site links  : {checked}")
print(f"anchors resolved  : {anchors_checked}")
if skipped:
    print(f"skipped (no front matter, not rendered): {', '.join(skipped)}")

for w in warnings:
    print(f"warning: {w}")

if errors:
    print()
    print(f"FAIL: {len(errors)} broken intra-site link(s):")
    for e in errors:
        print(f"  - {e}")
    sys.exit(2)

print()
print("OK: no broken intra-site link.")
PY
