#!/usr/bin/env bash
# scripts/build-pages-site.sh
#
# Deterministically (re)generates the wiki-derived pages of the GitHub Pages
# documentation site (docs/*.md) from the existing wiki mirror under
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
# itself have drifted from each other before (see skills/doc-sync/SKILL.md
# for the doc-sync side of this convention).
#
# WHAT THIS SCRIPT DOES NOT TOUCH:
#   - docs/_config.yml, docs/index.md — hand-authored site structure/config,
#     not derived from wiki content. Edit these directly if the page set or
#     nav changes.
#   - docs/README.md — maintainer-facing decision record, not a rendered
#     Jekyll page and not wiki-derived content.
#
# WHAT THIS SCRIPT REGENERATES (always overwritten, never hand-edit these):
#   - docs/getting-started.md   <- project/.wiki/intro-guide.md
#   - docs/concepts.md          <- project/.wiki/concepts/*.md (concatenated)
#   - docs/skills.md            <- project/.wiki/documentation.md "## Skills"
#   - docs/agents.md            <- project/.wiki/documentation.md "## Agents"
#   - docs/hooks.md             <- project/.wiki/documentation.md "## Hooks"
#   - docs/mcp-tools.md         <- project/.wiki/documentation.md "## MCP Tools"
#   - docs/reference.md         <- project/.wiki/documentation.md
#                                   "## Directory Structure" +
#                                   "## Agent Communication Contract"
#                                   (plus a short hand-authored index blurb
#                                   linking to skills/agents/hooks/mcp-tools)
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
# Usage: scripts/build-pages-site.sh
# Safe to re-run any number of times — every run fully overwrites its
# output files from the current wiki content (no partial/incremental state).

set -euo pipefail

# shellcheck source=lib/resolve-project-dir.sh disable=SC1091
source "$(git rev-parse --show-toplevel)/lib/resolve-project-dir.sh"

REPO_ROOT="$JENGA_PROJECT_DIR"
WIKI_DIR="$REPO_ROOT/project/.wiki"
DOCS_DIR="$REPO_ROOT/docs"
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

# --- 2. docs/agents.md, docs/hooks.md, docs/mcp-tools.md -------------------
# Straight ports — no internal markdown links were found in these sections
# of documentation.md, so no link rewriting is needed beyond the front
# matter wrapper.
write_page "$DOCS_DIR/agents.md" "Agents" "/agents.html" "$WORK/section-agents.md"
write_page "$DOCS_DIR/hooks.md" "Hooks" "/hooks.html" "$WORK/section-hooks.md"
write_page "$DOCS_DIR/mcp-tools.md" "MCP Tools" "/mcp-tools.html" "$WORK/section-mcp-tools.md"

# --- 3. docs/skills.md ------------------------------------------------------
# Single reference page (matches the story's own suggested top-level
# category list: Getting Started / Concepts / Skills reference / Agents /
# Hooks / MCP Tools — "Skills reference" is one page, not one page per
# skill). Category (### ) and per-skill (#### ) structure is preserved
# as-is from the source.
write_page "$DOCS_DIR/skills.md" "Skills Reference" "/skills.html" "$WORK/section-skills.md"

# --- 4. docs/reference.md ---------------------------------------------------
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

- **[Skills Reference](./skills.md)** — every skill, grouped by Setup &
  Planning, Execution, Status & Review, and Committing & Maintenance.
- **[Agents](./agents.md)** — Scrum Master, Developer, Tester: roles,
  ownership, and responsibilities.
- **[Hooks](./hooks.md)** — session lifecycle hooks and what they run.
- **[MCP Tools](./mcp-tools.md)** — Model Context Protocol tools available
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
write_page "$DOCS_DIR/reference.md" "Reference" "/reference.html" "$WORK/reference-body.md"

# --- 5. docs/getting-started.md ---------------------------------------------
# Port of intro-guide.md verbatim (drop the leading H1 — front matter
# supplies the page title instead), with its two links into the
# now-restructured reference/concepts pages rewritten.
tail -n +2 "$INTRO_MD" > "$WORK/intro-body.md"
# NOTE on delimiter choice: sed's `s<delim>pattern<delim>replacement<delim>`
# breaks if the replacement text itself contains the delimiter character.
# Several replacements below contain a literal "#" (anchor fragments), so
# "#" cannot be used as the delimiter here — "|" is used instead, since
# none of these paths/anchors contain a literal "|".
sed -i.bak \
  -e 's|\[documentation\.md\](\./documentation\.md)|[reference.md](./reference.md)|g' \
  -e 's|(\./concepts/role-separation\.md)|(./concepts.md#role-separation)|g' \
  -e 's|(\./concepts/board-hierarchy\.md)|(./concepts.md#board-hierarchy)|g' \
  -e 's|(\./concepts/session-continuity\.md)|(./concepts.md#session-continuity)|g' \
  -e 's|(\./concepts/first-feature\.md)|(./concepts.md#your-first-feature)|g' \
  -e 's|(\./concepts/multi-session-work\.md)|(./concepts.md#working-across-sessions)|g' \
  -e 's|(\./concepts/mid-flow-capture\.md)|(./concepts.md#capturing-mid-flow-ideas)|g' \
  -e 's|(\./concepts/parallel-tasks\.md)|(./concepts.md#parallel-tasks)|g' \
  "$WORK/intro-body.md"
rm -f "$WORK/intro-body.md.bak"
write_page "$DOCS_DIR/getting-started.md" "Getting Started" "/getting-started.html" "$WORK/intro-body.md"

# --- 6. docs/concepts.md -----------------------------------------------------
# Concatenates all 7 project/.wiki/concepts/*.md files into one page:
#   - each file's H1 becomes an H2 section heading (slug listed below must
#     stay in sync with each file's actual title text — GitHub Pages/kramdown
#     slugifies headings to lowercase-hyphenated automatically)
#   - all other headings are demoted one level (## -> ###, ### -> ####)
#   - sibling/parent links are rewritten to point within the merged page
#     and at the sibling getting-started.md / reference.md pages
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
        -e 's|\[documentation\.md\](\.\./documentation\.md)|[reference.md](./reference.md)|g' \
        -e 's|(\.\./intro-guide\.md)|(./getting-started.md)|g' \
        -e 's|(\.\./documentation\.md)|(./reference.md)|g' \
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

write_page "$DOCS_DIR/concepts.md" "Concepts" "/concepts.html" "$WORK/concepts-body.md"

echo "build-pages-site.sh: regenerated docs/{getting-started,concepts,skills,agents,hooks,mcp-tools,reference}.md from project/.wiki/*"
