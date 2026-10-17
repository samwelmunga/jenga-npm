#!/usr/bin/env bash
# scripts/build-pages-site.sh
#
# Deterministically (re)generates the wiki-derived pages of the GitHub Pages
# documentation site (site/guides/*.md and site/reference/*.md) from the
# existing wiki mirror under
# project/.wiki/. This is the sync mechanism behind E41_S13_T01's
# source-of-truth decision ("restructure from the wiki, keep both in sync"):
# project/.wiki/ stays the canonical, doc-sync-maintained content; this
# script is the deterministic transform from that content into the
# multi-page, navigable Pages site.
#
# WHEN TO RE-RUN: after `j.doc-sync` (or any manual edit) updates
# project/.wiki/documentation.md, project/.wiki/intro-guide.md, or
# project/.wiki/concepts/*.md, re-run this script to refresh the Pages site
# so it doesn't silently drift from the wiki the way README.md and the wiki
# itself have drifted from each other before (see skills/j-doc-sync/SKILL.md
# for the doc-sync side of this convention).
#
# WHAT THIS SCRIPT DOES NOT TOUCH (4 hand-authored files):
#   - site/_config.yml, site/index.md — hand-authored site structure/config,
#     not derived from wiki content. Edit these directly if the page set or
#     nav changes.
#   - site/guides/preflight-checklists.md — hand-authored consumer authoring
#     reference (E67_S06_T01), not wiki-derived.
#   - site/reference/jenga-config.md — hand-maintained reference for
#     jenga.cli.json, not wiki-derived.
#   The site's maintainer-facing decision record is
#   project/documentation/site-decisions.md, outside the site source entirely
#   (it was docs/README.md until E70_S02_T01).
#
# WHAT THIS SCRIPT REGENERATES (always overwritten, never hand-edit these):
#   - site/guides/getting-started.md   <- project/.wiki/intro-guide.md
#   - site/guides/concepts.md          <- project/.wiki/concepts/*.md
#                                          (concatenated)
#   - site/reference/skills.md         <- project/.wiki/documentation.md
#                                          "## Skills"
#   - site/reference/agents.md         <- project/.wiki/documentation.md
#                                          "## Agents"
#   - site/reference/hooks.md          <- project/.wiki/documentation.md
#                                          "## Hooks"
#   - site/reference/mcp-tools.md      <- project/.wiki/documentation.md
#                                          "## MCP Tools"
#   - site/reference/reference.md      <- project/.wiki/documentation.md
#                                          "## Directory Structure" +
#                                          "## Agent Communication Contract"
#                                          (plus a short hand-authored index
#                                          blurb linking to
#                                          skills/agents/hooks/mcp-tools)
#
# OUTPUT LAYOUT (E70_S02_T03): the 7 pages above are split across two
# subdirectories, but every permalink stays FLAT — site/reference/skills.md
# still publishes at /skills.html, never /reference/skills.html. The output
# path moved one level down; the published URL did not move at all. Do not add
# a directory segment to any write_page permalink argument below.
#
# KNOWN LIMITATION: this is a structural transform, not a fact-checker. It
# ports project/.wiki/documentation.md's content as-is, including whatever
# is currently stale in that file (e.g. it documents ~30 skills under the
# old bare `/<name>` invocation form and does not yet list every skill in
# skills/, including the `j-<name>` twins — a pre-existing wiki staleness
# gap, not something introduced by this script). Fixing the wiki's own
# staleness is doc-sync's job, not this script's — this script only keeps
# the Pages site faithful to whatever the wiki currently says.
#
# HEADING-STABILITY ASSUMPTION: section extraction below is keyed to exact
# top-level ("## ") heading text in documentation.md (Agents, Skills, MCP
# Tools, Hooks, Directory Structure, Agent Communication Contract). If any
# of those headings are renamed, update the `case` statement in
# extract_sections() to match.
#
# Usage: scripts/build-pages-site.sh [<output-dir> | --print-output-dir]
#
# OUTPUT DIRECTORY (E70_S01_T01, default repointed by E70_S02_T03): the output
# directory is an *opt-in* override that defaults to <repo root>/site.
# Resolution order:
#
#   1. $1                        — first positional argument, if given
#   2. $BUILD_PAGES_OUTPUT_DIR   — environment variable, if set and non-empty
#   3. <repo root>/site          — the default
#
# Whatever directory is resolved, the guides/ and reference/ subdirectories are
# created inside it, so an overridden run reproduces the real layout rather
# than a flat one — which is what keeps the dry-run harness's comparison
# meaningful.
#
# `--print-output-dir` prints the resolved output directory and exits without
# generating anything, so a caller (or a test) can confirm the resolution
# without writing a single file. This exists so that proving the default is
# unchanged does not require adding a line of output to a normal run.
#
# The override is what makes a read-only dry run possible: see
# scripts/dryrun-pages-site-diff.sh, which generates into a fresh `mktemp -d`
# directory and diffs the result against the committed site/ copies without
# ever writing into site/.
#
# Safe to re-run any number of times — every run fully overwrites its
# output files from the current wiki content (no partial/incremental state).

set -euo pipefail

# shellcheck source=lib/resolve-project-dir.sh disable=SC1091
source "$(git rev-parse --show-toplevel)/lib/resolve-project-dir.sh"

REPO_ROOT="$JENGA_PROJECT_DIR"
WIKI_DIR="$REPO_ROOT/project/.wiki"

# --- 0. Resolve the output directory (opt-in override, defaulted) ----------
DEFAULT_SITE_DIR="$REPO_ROOT/site"
PRINT_ONLY=0
case "${1:-}" in
  --print-output-dir)
    PRINT_ONLY=1
    shift
    ;;
  -h|--help)
    sed -n '/^# Usage:/,/^# Safe to re-run/p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  --*)
    echo "build-pages-site.sh: unknown option: $1" >&2
    echo "Usage: scripts/build-pages-site.sh [<output-dir> | --print-output-dir]" >&2
    exit 1
    ;;
esac
SITE_DIR="${1:-${BUILD_PAGES_OUTPUT_DIR:-$DEFAULT_SITE_DIR}}"
GUIDES_DIR="$SITE_DIR/guides"
REF_DIR="$SITE_DIR/reference"
if [ "$PRINT_ONLY" -eq 1 ]; then
  echo "$SITE_DIR"
  exit 0
fi

DOC_MD="$WIKI_DIR/documentation.md"
INTRO_MD="$WIKI_DIR/intro-guide.md"
CONCEPTS_DIR="$WIKI_DIR/concepts"

for f in "$DOC_MD" "$INTRO_MD"; do
  if [ ! -f "$f" ]; then
    echo "build-pages-site.sh: required source file not found: $f" >&2
    exit 1
  fi
done
if [ ! -d "$CONCEPTS_DIR" ]; then
  echo "build-pages-site.sh: required source directory not found: $CONCEPTS_DIR" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- 1. Split documentation.md into per-section scratch files -------------
# A line can only belong to one target section at a time; the generic
# "any other ## heading" rule resets `section` to "" so unrelated top-level
# sections (e.g. "## Table of Contents") are dropped rather than bleeding
# into whichever named section preceded them.
awk -v work="$WORK" '
  /^## Agents$/                             { section = "agents"; next }
  /^## Skills$/                             { section = "skills"; next }
  /^## MCP Tools$/                          { section = "mcp-tools"; next }
  /^## Hooks$/                              { section = "hooks"; next }
  /^## Directory Structure$/                { section = "directory-structure"; next }
  /^## Agent Communication Contract$/       { section = "contract"; next }
  /^## /                                    { section = "" }
  {
    if (section != "") {
      print >> (work "/section-" section ".md")
    }
  }
' "$DOC_MD"

for s in agents skills mcp-tools hooks directory-structure contract; do
  [ -f "$WORK/section-$s.md" ] || touch "$WORK/section-$s.md"
done

write_page() {
  # write_page <output-path> <title> <permalink> <body-file>
  local out="$1" title="$2" permalink="$3" body="$4"
  {
    printf -- '---\n'
    printf 'layout: page\n'
    printf 'title: %s\n' "$title"
    printf 'permalink: %s\n' "$permalink"
    printf -- '---\n\n'
    cat "$body"
  } > "$out"
}

# Both subdirectories are created unconditionally. `mkdir -p` on the parent
# alone is not enough: a nested target like site/guides is not created by
# `mktemp -d` for an overridden run, and a clean checkout (or a working tree
# where the subdirectories were deleted) would fail on the first redirect into
# a missing directory. `mkdir -p "$GUIDES_DIR"` also creates "$SITE_DIR" as a
# side effect; the bare parent mkdir is kept for any future output that lands
# at the source root.
mkdir -p "$SITE_DIR" "$GUIDES_DIR" "$REF_DIR"

# --- 2. reference/agents.md, reference/hooks.md, reference/mcp-tools.md ----
# Straight ports — no internal markdown links were found in these sections
# of documentation.md, so no link rewriting is needed beyond the front
# matter wrapper.
#
# The mcp-tools blockquote pointing at project/documentation/mcp-registration-decision.md
# comes from documentation.md's "## MCP Tools" section, where E70_S02_T03
# folded it in (disposition 2 of project/documentation/docs-site-drift-report.md).
# It was a hand-edit on the committed page before that, which this generator
# would have silently reverted. Its URL is deliberately an absolute GitHub URL,
# not an intra-site link: project/documentation/ is not published, so a
# relative link would 404. Do not normalise it.
write_page "$REF_DIR/agents.md" "Agents" "/agents.html" "$WORK/section-agents.md"
write_page "$REF_DIR/hooks.md" "Hooks" "/hooks.html" "$WORK/section-hooks.md"
write_page "$REF_DIR/mcp-tools.md" "MCP Tools" "/mcp-tools.html" "$WORK/section-mcp-tools.md"

# --- 3. reference/skills.md -------------------------------------------------
# Single reference page (matches the story's own suggested top-level
# category list: Getting Started / Concepts / Skills reference / Agents /
# Hooks / MCP Tools — "Skills reference" is one page, not one page per
# skill). Category (### ) and per-skill (#### ) structure is preserved
# as-is from the source.
write_page "$REF_DIR/skills.md" "Skills Reference" "/skills.html" "$WORK/section-skills.md"

# --- 4. reference/reference.md ----------------------------------------------
# Combines the two remaining documentation.md sections (Directory Structure,
# Agent Communication Contract) behind a short hand-authored index blurb
# that links out to the pages built above — this replaces documentation.md's
# original role as the single "full reference" entry point, now that its
# content is split across multiple pages.
{
  cat <<'EOF'
## Full Reference Index

This page is the entry point into the full reference material, split across
several pages so nothing requires scrolling through one giant file:

- **[Skills Reference](skills.html)** — every skill, grouped by Setup &
  Planning, Execution, Status & Review, and Committing & Maintenance.
- **[Agents](agents.html)** — Scrum Master, Developer, Tester: roles,
  ownership, and responsibilities.
- **[Hooks](hooks.html)** — session lifecycle hooks and what they run.
- **[MCP Tools](mcp-tools.html)** — Model Context Protocol tools available
  in a Claude Code session.

The rest of this page covers the repo's directory structure and the
inter-agent communication contract (the typed "sender object" every agent
call carries).

---

EOF
  cat "$WORK/section-directory-structure.md"
  printf '\n---\n\n'
  cat "$WORK/section-contract.md"
} > "$WORK/reference-body.md"
write_page "$REF_DIR/reference.md" "Reference" "/reference.html" "$WORK/reference-body.md"

# --- 5. guides/getting-started.md -------------------------------------------
# Port of intro-guide.md verbatim (drop the leading H1 — front matter
# supplies the page title instead), with its two links into the
# now-restructured reference/concepts pages rewritten.
tail -n +2 "$INTRO_MD" > "$WORK/intro-body.md"
# NOTE on delimiter choice: sed's `s<delim>pattern<delim>replacement<delim>`
# breaks if the replacement text itself contains the delimiter character.
# Several replacements below contain a literal "#" (anchor fragments), so
# "#" cannot be used as the delimiter here — "|" is used instead, since
# none of these paths/anchors contain a literal "|".
#
# LINK FORM (E70_S01_T04): the replacement text below emits the permalink
# `.html` form — a bare relative `<name>.html`, matching each page's own
# `permalink: /<name>.html` front matter. Every page's permalink is
# root-level, so a bare relative link resolves from any page and survives a
# move of the source directory unchanged (epic decision 8). A root-absolute
# `/<name>.html` would NOT work: site/_config.yml sets no `baseurl`, and the
# site is served under a GitHub Pages project-site path prefix, so a leading
# slash would drop the prefix and 404. Do not "fix" these to add one.
#
# The `[full reference](./documentation.md#skills)` rule below folds in the
# hand-edit catalogued as disposition 1 of
# project/documentation/docs-site-drift-report.md: the anchored variant at
# intro-guide.md:292 matches none of the other rules, so without it the
# generator reverts a committed fix to a link that points at a file the
# published site does not contain.
sed -i.bak \
  -e 's|\[full reference\](\./documentation\.md#skills)|[Skills Reference](skills.html)|g' \
  -e 's|\[documentation\.md\](\./documentation\.md)|[reference.md](reference.html)|g' \
  -e 's|(\./concepts/role-separation\.md)|(concepts.html#role-separation)|g' \
  -e 's|(\./concepts/board-hierarchy\.md)|(concepts.html#board-hierarchy)|g' \
  -e 's|(\./concepts/session-continuity\.md)|(concepts.html#session-continuity)|g' \
  -e 's|(\./concepts/first-feature\.md)|(concepts.html#your-first-feature)|g' \
  -e 's|(\./concepts/multi-session-work\.md)|(concepts.html#working-across-sessions)|g' \
  -e 's|(\./concepts/mid-flow-capture\.md)|(concepts.html#capturing-mid-flow-ideas)|g' \
  -e 's|(\./concepts/parallel-tasks\.md)|(concepts.html#parallel-tasks)|g' \
  "$WORK/intro-body.md"
rm -f "$WORK/intro-body.md.bak"
write_page "$GUIDES_DIR/getting-started.md" "Getting Started" "/getting-started.html" "$WORK/intro-body.md"

# --- 6. guides/concepts.md ---------------------------------------------------
# Concatenates all 7 project/.wiki/concepts/*.md files into one page:
#   - each file's H1 becomes an H2 section heading (slug listed below must
#     stay in sync with each file's actual title text — GitHub Pages/kramdown
#     slugifies headings to lowercase-hyphenated automatically)
#   - all other headings are demoted one level (## -> ###, ### -> ####)
#   - sibling/parent links are rewritten to point within the merged page
#     and at the sibling getting-started.html / reference.html pages, in the
#     permalink `.html` form (see the LINK FORM note in section 5 — bare
#     relative, never root-absolute)
#
{
  cat <<'EOF'
## Concepts

The ideas behind Jenga AI's structure, and the how-tos for using it day to
day. Jump to any section:

- [Role Separation](#role-separation)
- [Board Hierarchy](#board-hierarchy)
- [Session Continuity](#session-continuity)
- [Your First Feature](#your-first-feature)
- [Working Across Sessions](#working-across-sessions)
- [Capturing Mid-Flow Ideas](#capturing-mid-flow-ideas)
- [Parallel Tasks](#parallel-tasks)

---

EOF
} > "$WORK/concepts-body.md"

append_concept() {
  # append_concept <filename-stem> <section-title>
  local stem="$1"
  local title="$2"
  local src="$CONCEPTS_DIR/$stem.md"
  {
    printf '## %s\n\n' "$title"
    # NOTE on delimiter choice: same reasoning as the getting-started block
    # above — replacements here contain a literal "#" anchor character, so
    # "|" is used as the sed delimiter instead of "#".
    #
    # NOTE on heading demotion: a naive two-pass "## -> ###" then
    # "### -> ####" sed would double-demote lines that were originally
    # "## " (they'd match the first rule, becoming "### ", and then ALSO
    # match the second rule on the same pass, becoming "#### " — wrong).
    # The single extended-regex rule below captures the existing run of
    # 2-3 "#" characters and prepends exactly one more, so each line is
    # demoted exactly once regardless of its original level.
    tail -n +2 "$src" \
      | sed \
        -e 's|\[documentation\.md\](\.\./documentation\.md)|[reference.md](reference.html)|g' \
        -e 's|(\.\./intro-guide\.md)|(getting-started.html)|g' \
        -e 's|(\.\./documentation\.md)|(reference.html)|g' \
        -e 's|(\./role-separation\.md)|(#role-separation)|g' \
        -e 's|(\./board-hierarchy\.md)|(#board-hierarchy)|g' \
        -e 's|(\./session-continuity\.md)|(#session-continuity)|g' \
        -e 's|(\./first-feature\.md)|(#your-first-feature)|g' \
        -e 's|(\./multi-session-work\.md)|(#working-across-sessions)|g' \
        -e 's|(\./mid-flow-capture\.md)|(#capturing-mid-flow-ideas)|g' \
        -e 's|(\./parallel-tasks\.md)|(#parallel-tasks)|g' \
      | sed -E 's/^(#{2,3}) /#\1 /'
    printf '\n---\n\n'
  } >> "$WORK/concepts-body.md"
}

append_concept "role-separation" "Role Separation"
append_concept "board-hierarchy" "Board Hierarchy"
append_concept "session-continuity" "Session Continuity"
append_concept "first-feature" "Your First Feature"
append_concept "multi-session-work" "Working Across Sessions"
append_concept "mid-flow-capture" "Capturing Mid-Flow Ideas"
append_concept "parallel-tasks" "Parallel Tasks"

write_page "$GUIDES_DIR/concepts.md" "Concepts" "/concepts.html" "$WORK/concepts-body.md"

# The default-path message is kept byte-identical to its pre-E70_S01_T01 form
# so that an unparameterised run's output does not change; an overridden run
# names the directory it actually wrote to instead of claiming "docs/".
if [ "$SITE_DIR" = "$DEFAULT_SITE_DIR" ]; then
  echo "build-pages-site.sh: regenerated site/guides/{getting-started,concepts}.md and site/reference/{skills,agents,hooks,mcp-tools,reference}.md from project/.wiki/*"
else
  echo "build-pages-site.sh: regenerated guides/{getting-started,concepts}.md and reference/{skills,agents,hooks,mcp-tools,reference}.md under $SITE_DIR from project/.wiki/*"
fi
