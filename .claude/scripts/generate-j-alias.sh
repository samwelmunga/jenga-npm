#!/usr/bin/env bash
# scripts/generate-j-alias.sh — generate/sync a j-<name> polyfill alias skill directory
#
# Mechanizes the hand-maintained pattern that produced skills/j-init/ (E50_S04): a
# literal-directory-name duplicate of skills/<name>/ that gives a guaranteed-unshadowed
# way to reach a skill even when a host tool's own built-in command of the same name
# would otherwise shadow the bare /<name> form. Per CLAUDE.md's Skill Implementation
# Principle, this must not be repeated by hand across every skill — this script performs
# both the initial generation and any later resync-after-source-change as a single
# deterministic command (E50_S05_T01).
#
# For the given <skill-name>, this script:
#   1. Copies the full skills/<skill-name>/ tree into skills/j-<skill-name>/, overwriting
#      the destination on re-run (the sync case).
#   2. Rewrites every self-referential "skills/<skill-name>/" path reference inside the
#      copied SKILL.md and any copied scripts to "skills/j-<skill-name>/" — including the
#      .claude/skills/<skill-name>/ and .agents/skills/<skill-name>/ mirrored-install
#      fallback paths, which fall out of the same literal substring replace.
#   3. Rewrites the copied SKILL.md's frontmatter: name: j:<skill-name> -> name:
#      j:j-<skill-name>; description: reframed as a polyfill alias; keywords: gets
#      j-<skill-name> and polyfill appended (existing keywords preserved, list created
#      if absent); examples: gets a "j-<skill-name>" example appended if the list exists.
#   4. Inserts a short, programmatically generated lockstep/duplicate-alias note near the
#      top of the body.
#
# Idempotent: the target directory is always fully rebuilt from the source on every run
# (never incrementally patched), so two runs against an unchanged source produce a
# byte-identical result, and a source change is picked up in full on the next run.
#
# Exclusions:
#   - Only operates on directories containing a SKILL.md (skips e.g. skills/index/,
#     which has no SKILL.md and is not part of skill routing) — enforced as a hard error,
#     not a silent no-op, so a typo'd or non-skill argument fails clearly.
#   - Refuses to touch the skills/init/ <-> skills/j-init/ pair — that pair already
#     exists, is hand-maintained, and is explicitly out of scope for this story.
#
# This is a single-skill generator only. Running it across every skill in the repo is a
# separate task (E50_S05_T02) — deliberately not built here.
#
# Usage:
#   scripts/generate-j-alias.sh <skill-name>
#
# Examples:
#   scripts/generate-j-alias.sh status      # generates/syncs skills/j-status/
#   scripts/generate-j-alias.sh close-story # generates/syncs skills/j-close-story/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/resolve-project-dir.sh
source "$SCRIPT_DIR/../lib/resolve-project-dir.sh"

PROJECT_DIR="$JENGA_PROJECT_DIR"
SKILLS_DIR="$PROJECT_DIR/skills"

usage() {
  echo "Usage: $(basename "$0") <skill-name>" >&2
  echo "  Generates/syncs skills/j-<skill-name>/ as a polyfill alias of skills/<skill-name>/." >&2
}

if [ "$#" -ne 1 ]; then
  usage
  exit 1
fi

case "$1" in
  -h|--help)
    usage
    exit 0
    ;;
esac

SKILL_NAME="$1"

# Security guard (E50_S05_T01 rework — see
# project/rapports/problems/E50_S05_T01-generator-path-traversal.md): validate
# the skill-name argument BEFORE any path is constructed from it, let alone
# before anything destructive runs. An unsanitized argument containing '/' or
# '..' segments previously let SRC_DIR/TARGET_DIR (built by plain string
# concatenation below) resolve outside $SKILLS_DIR, and the destructive
# rmtree-then-copytree step ran before the one existing safety check
# (frontmatter name match) ever fired. This allowlist alone closes that vector
# — it forbids '/' and '.' entirely — and runs first, ahead of every other
# check including the init/j-init special-case below.
if [[ ! "$SKILL_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
  echo "generate-j-alias.sh: error: '$SKILL_NAME' is not a valid skill name — must match ^[a-z0-9][a-z0-9_-]*\$ (lowercase letters, digits, '-', '_' only, starting with a letter or digit). Refusing to construct a path from it." >&2
  exit 1
fi

if [[ "$SKILL_NAME" == "init" || "$SKILL_NAME" == "j-init" ]]; then
  echo "generate-j-alias.sh: refusing to touch '$SKILL_NAME' — the skills/init/ <-> skills/j-init/ pair already exists and is hand-maintained (out of scope for this generator, E50_S05). No-op." >&2
  exit 0
fi

SRC_DIR="$SKILLS_DIR/$SKILL_NAME"
SRC_SKILL_MD="$SRC_DIR/SKILL.md"

if [ ! -f "$SRC_SKILL_MD" ]; then
  echo "generate-j-alias.sh: error: '$SRC_DIR' does not contain a SKILL.md — not a skill directory, refusing to generate skills/j-$SKILL_NAME/." >&2
  exit 1
fi

TARGET_DIR="$SKILLS_DIR/j-$SKILL_NAME"

# Defense in depth (belt and suspenders on top of the allowlist above):
# resolve SRC_DIR/TARGET_DIR to absolute canonical paths and hard-fail unless
# each is confined to a direct child of $SKILLS_DIR. This protects against the
# allowlist regex being weakened in a future edit, or $SKILLS_DIR itself
# containing a symlink that could redirect an otherwise-validated path outside
# skills/. Both checks below run before the python heredoc, i.e. strictly
# before any rmtree/copytree call.
REAL_SKILLS_DIR="$(realpath "$SKILLS_DIR")"
REAL_SRC_DIR="$(realpath "$SRC_DIR")"
if [ "$(dirname "$REAL_SRC_DIR")" != "$REAL_SKILLS_DIR" ]; then
  echo "generate-j-alias.sh: error: resolved source path '$REAL_SRC_DIR' escapes '$REAL_SKILLS_DIR' — refusing to proceed." >&2
  exit 1
fi

# TARGET_DIR may not exist yet (first-run generation case), and this
# platform's realpath has no -m/--canonicalize-missing option, so it can't be
# realpath'd directly when absent. Its parent is always $SKILLS_DIR by
# construction (SKILL_NAME is a single path component, and the allowlist above
# already forbids '/' and '..' in it), so check the literal parent/basename
# shape here, and additionally realpath the target itself when it already
# exists (the resync case) to catch a symlink planted at the target that
# points outside skills/.
TARGET_BASENAME="$(basename "$TARGET_DIR")"
if [[ "$TARGET_BASENAME" == "." || "$TARGET_BASENAME" == ".." || "$TARGET_BASENAME" == */* ]]; then
  echo "generate-j-alias.sh: error: computed target basename '$TARGET_BASENAME' is unsafe — refusing to proceed." >&2
  exit 1
fi
if [ "$(dirname "$TARGET_DIR")" != "$SKILLS_DIR" ]; then
  echo "generate-j-alias.sh: error: computed target path '$TARGET_DIR' does not resolve directly under '$SKILLS_DIR' — refusing to proceed." >&2
  exit 1
fi
if [ -e "$TARGET_DIR" ] || [ -L "$TARGET_DIR" ]; then
  REAL_TARGET_DIR="$(realpath "$TARGET_DIR")"
  if [ "$(dirname "$REAL_TARGET_DIR")" != "$REAL_SKILLS_DIR" ]; then
    echo "generate-j-alias.sh: error: resolved target path '$REAL_TARGET_DIR' escapes '$REAL_SKILLS_DIR' — refusing to proceed." >&2
    exit 1
  fi
fi

export SKILL_NAME SRC_DIR TARGET_DIR

python3 - <<'PY'
import os
import re
import shutil
import sys

skill_name = os.environ["SKILL_NAME"]
src_dir = os.environ["SRC_DIR"]
target_dir = os.environ["TARGET_DIR"]

old_ref = f"skills/{skill_name}/"
new_ref = f"skills/j-{skill_name}/"

# ---- 1. Copy the full tree, overwriting the destination (the sync case) ----
if os.path.lexists(target_dir):
    shutil.rmtree(target_dir)
shutil.copytree(src_dir, target_dir, symlinks=True)

# ---- 2. Rewrite self-referential paths in every copied file ----
for dirpath, _dirnames, filenames in os.walk(target_dir):
    for fn in filenames:
        fpath = os.path.join(dirpath, fn)
        try:
            with open(fpath, "r", encoding="utf-8") as fh:
                content = fh.read()
        except (UnicodeDecodeError, OSError):
            continue  # binary or unreadable — leave untouched
        if old_ref in content:
            with open(fpath, "w", encoding="utf-8") as fh:
                fh.write(content.replace(old_ref, new_ref))

# ---- 3. Rewrite SKILL.md frontmatter + insert the lockstep note ----
target_skill_md = os.path.join(target_dir, "SKILL.md")
with open(target_skill_md, "r", encoding="utf-8") as fh:
    lines = fh.readlines()

if not lines or lines[0].strip() != "---":
    sys.exit(f"generate-j-alias.sh: error: {target_skill_md} has no opening '---' frontmatter marker")

close_idx = None
for idx in range(1, len(lines)):
    if lines[idx].strip() == "---":
        close_idx = idx
        break
if close_idx is None:
    sys.exit(f"generate-j-alias.sh: error: {target_skill_md} has no closing '---' frontmatter marker")

# Parse the frontmatter into an ordered list of top-level fields. This is the same
# informal line-oriented approach scripts/apply-j-prefix.sh already uses elsewhere in
# this repo for SKILL.md frontmatter — not a full YAML parser, consistent with how
# frontmatter is already handled here.
key_re = re.compile(r'^([A-Za-z_][\w-]*):(.*)$')
fields = []
i = 1
while i < close_idx:
    line = lines[i]
    m = key_re.match(line)
    if not m:
        i += 1
        continue
    block = [line]
    j = i + 1
    if m.group(2).strip() == "":
        # possible nested block (list or mapping) — consume indented continuation lines
        while j < close_idx and lines[j].startswith(" "):
            block.append(lines[j])
            j += 1
    fields.append({"key": m.group(1), "lines": block})
    i = j


def find_field(key):
    for f in fields:
        if f["key"] == key:
            return f
    return None


name_field = find_field("name")
desc_field = find_field("description")

if name_field is None or len(name_field["lines"]) != 1:
    sys.exit(f"generate-j-alias.sh: error: {target_skill_md} has no single-line 'name:' field")
if desc_field is None or len(desc_field["lines"]) != 1:
    sys.exit(f"generate-j-alias.sh: error: {target_skill_md} has no single-line 'description:' field")

current_name = key_re.match(name_field["lines"][0]).group(2).strip().strip('"\'')
if current_name not in (f"j:{skill_name}", skill_name):
    sys.exit(
        f"generate-j-alias.sh: error: frontmatter name '{current_name}' in {target_skill_md} "
        f"does not match expected 'j:{skill_name}' (or bare '{skill_name}') — refusing to guess, aborting."
    )
name_field["lines"][0] = f"name: j:j-{skill_name}\n"

original_desc = key_re.match(desc_field["lines"][0]).group(2).strip().strip('"\'').rstrip(".")
new_desc = (
    f"Polyfill alias of the {skill_name} skill under a collision-safe directory name. "
    f"Identical behavior to /{skill_name} — {original_desc}. "
    f"Use when the bare /{skill_name} form is shadowed by another tool's own built-in "
    f"command of the same name."
)
desc_field["lines"][0] = f"description: {new_desc}\n"

keywords_field = find_field("keywords")
if keywords_field is not None:
    keywords_field["lines"].append(f"  - j-{skill_name}\n")
    keywords_field["lines"].append("  - polyfill\n")
else:
    fields.append({
        "key": "keywords",
        "lines": ["keywords:\n", f"  - j-{skill_name}\n", "  - polyfill\n"],
    })

examples_field = find_field("examples")
if examples_field is not None:
    examples_field["lines"].append(f'  - "j-{skill_name}"\n')
# if absent: per spec, do not fabricate an examples: list where none existed

new_frontmatter_lines = []
for f in fields:
    new_frontmatter_lines.extend(f["lines"])

body_lines = lines[close_idx + 1:]

note_text = (
    f"This skill is a literal-directory-name duplicate of `skills/{skill_name}/`. It exists so "
    f"that `/j-{skill_name}` (and `j:j-{skill_name}`) give a guaranteed-unshadowed way to reach "
    f"the same flow as `/{skill_name}`, even if a host tool's own built-in command of the same "
    f"name would otherwise shadow or override the bare `/{skill_name}` alias (Claude Code's "
    f"native skill resolution is a literal-string, directory-name-based match — see "
    f"`docs/skill-authoring.md`'s \"Invocation Convention\").\n\n"
    f"This file is generated/synced by `scripts/generate-j-alias.sh {skill_name}` from "
    f"`skills/{skill_name}/SKILL.md` — do not hand-edit it; re-run the generator instead to "
    f"pick up source changes."
)
note_block = []
for para in note_text.split("\n\n"):
    note_block.append(para + "\n")
    note_block.append("\n")

heading_idx = None
for idx, bl in enumerate(body_lines):
    if bl.startswith("# "):
        heading_idx = idx
        break

if heading_idx is not None:
    insert_at = heading_idx + 1
    if insert_at < len(body_lines) and body_lines[insert_at].strip() == "":
        insert_at += 1
    prefix = body_lines[:insert_at]
    if prefix and prefix[-1].strip() != "":
        prefix = prefix + ["\n"]
    new_body_lines = prefix + note_block + body_lines[insert_at:]
else:
    new_body_lines = note_block + body_lines

new_lines = [lines[0]] + new_frontmatter_lines + [lines[close_idx]] + new_body_lines

with open(target_skill_md, "w", encoding="utf-8") as fh:
    fh.writelines(new_lines)

print(f"generate-j-alias.sh: generated/synced skills/j-{skill_name}/ from skills/{skill_name}/")
PY
