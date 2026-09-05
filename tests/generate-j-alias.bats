#!/usr/bin/env bats
#
# Regression coverage for scripts/generate-j-alias.sh (E50_S05_T01).
#
# Added after the tester reproduced a path-traversal vulnerability: the
# script built SRC_DIR/TARGET_DIR by naive string concatenation of the
# unsanitized <skill-name> argument, with no character allowlist and no
# post-construction confinement check. A crafted skill-name (e.g.
# "../../../victim") could make TARGET_DIR — the script's unconditional
# rm -rf/shutil.rmtree + copytree target — resolve outside skills/,
# silently destroying pre-existing unrelated content before the one
# existing safety check (a frontmatter name: match) ever ran, since that
# check ran AFTER the destructive copy. Full writeup:
# project/rapports/problems/E50_S05_T01-generator-path-traversal.md
#
# The fix (this commit) adds two guards, both running before any
# destructive operation:
#   1. An allowlist on the raw skill-name argument (^[a-z0-9][a-z0-9_-]*$),
#      applied immediately after argument parsing.
#   2. A realpath-based confinement check on the constructed
#      SRC_DIR/TARGET_DIR paths, as defense in depth on top of (1).
#
# Every test below runs against a throwaway sandbox under $BATS_TEST_TMPDIR,
# with JENGA_PROJECT_DIR overridden to point at it (a supported override in
# lib/resolve-project-dir.sh) — never against this repository's own
# skills/ contents.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  # Sandbox layout mirrors the tester's rapport reproduction:
  #   $SANDBOX/a/victim/SKILL.md        -- stand-in "source" 3 levels above skills/
  #   $SANDBOX/a/b/project/              -- JENGA_PROJECT_DIR
  #     skills/close-story/              -- a synthetic, valid skill to generate from
  #     scripts/generate-j-alias.sh
  #     lib/resolve-project-dir.sh
  #   $SANDBOX/a/b/project/victim/       -- stand-in pre-existing, unrelated
  #                                          directory one level outside skills/
  #
  # The close-story fixture is synthesized here rather than copied from this
  # repo's own skills/close-story/ (E28_S12 follow-up, 2026-09-06): on a public
  # mirror checkout, E28_S09/E28_S10 strip the canonical bare-name directory
  # for every j-<name>-twinned skill, so a real repo skill is not guaranteed to
  # exist under its bare name there. Synthesizing the fixture decouples this
  # suite from whatever the mirror's blocklist currently does.
  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  PROJECT_DIR="$SANDBOX/a/b/project"

  mkdir -p "$PROJECT_DIR/skills/close-story"
  cat > "$PROJECT_DIR/skills/close-story/SKILL.md" <<'SKILL_EOF'
---
name: j:close-story
description: Fixture skill for generate-j-alias.sh regression coverage.
keywords:
  - close story
examples:
  - "close a story"
---
# Close Story

Fixture body — content is irrelevant to the generator's own logic, which only
cares about the frontmatter `name:`/`description:` fields and the presence of
this file.
SKILL_EOF
  mkdir -p "$PROJECT_DIR/scripts" "$PROJECT_DIR/lib"
  cp "$REPO_ROOT/scripts/generate-j-alias.sh" "$PROJECT_DIR/scripts/"
  cp "$REPO_ROOT/lib/resolve-project-dir.sh" "$PROJECT_DIR/lib/"

  mkdir -p "$SANDBOX/a/victim"
  echo "SKILL.md content" > "$SANDBOX/a/victim/SKILL.md"

  mkdir -p "$PROJECT_DIR/victim"
  echo "precious" > "$PROJECT_DIR/victim/precious.txt"
}

run_generator() {
  JENGA_PROJECT_DIR="$PROJECT_DIR" bash "$PROJECT_DIR/scripts/generate-j-alias.sh" "$1"
}

@test "rejects a ../-containing skill-name with a non-zero exit and no filesystem changes" {
  run run_generator "../../../victim"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a valid skill name"* ]]

  # The pre-existing unrelated content at the escaped target survives untouched.
  [ -f "$PROJECT_DIR/victim/precious.txt" ]
  [ "$(cat "$PROJECT_DIR/victim/precious.txt")" = "precious" ]

  # No j-.. or any other stray directory was materialized under skills/.
  run ls "$PROJECT_DIR/skills"
  [ "$status" -eq 0 ]
  [ "$output" = "close-story" ]

  # Nothing was ever written outside skills/ via the escaped path.
  [ ! -f "$SANDBOX/a/b/project/victim/SKILL.md" ]
}

@test "rejects other unsafe skill-name shapes (absolute path, embedded traversal, uppercase, leading dash)" {
  for bad in ".." "/etc/passwd" "foo/bar" "-x" "UPPER" "close-story/../../victim" "j-.."; do
    run run_generator "$bad"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a valid skill name"* ]]
  done

  # None of these attempts left any trace under skills/.
  run ls "$PROJECT_DIR/skills"
  [ "$status" -eq 0 ]
  [ "$output" = "close-story" ]
}

@test "still accepts a valid skill-name and generates skills/j-<name>/ (regression check on the happy path)" {
  run run_generator "close-story"
  [ "$status" -eq 0 ]
  [[ "$output" == *"generated/synced skills/j-close-story/"* ]]
  [ -f "$PROJECT_DIR/skills/j-close-story/SKILL.md" ]

  run grep "^name:" "$PROJECT_DIR/skills/j-close-story/SKILL.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"j:j-close-story"* ]]
}

@test "still no-ops on 'init' and 'j-init' (out-of-scope hand-maintained pair, unaffected by the new guards)" {
  run run_generator "init"
  [ "$status" -eq 0 ]
  [[ "$output" == *"refusing to touch 'init'"* ]]

  run run_generator "j-init"
  [ "$status" -eq 0 ]
  [[ "$output" == *"refusing to touch 'j-init'"* ]]
}

@test "hard-refuses 'jenga'/'jenga-permission-level' and their j- forms with a non-zero exit (E50_S06_T01)" {
  # Unlike the init/j-init no-op above (exit 0, a legitimate hand-maintained pair), jenga
  # and jenga-permission-level must never get a j-<name> twin at all, so this is a hard
  # error with a non-zero exit — see docs/skill-authoring.md's "j-<name> directory twins"
  # Exclusions paragraph and project/rapports (E50_S06) for the full rationale.
  for bad in "jenga" "j-jenga" "jenga-permission-level" "j-jenga-permission-level"; do
    run run_generator "$bad"
    [ "$status" -ne 0 ]
    [[ "$output" == *"hard-excluded from this generator"* ]]
  done

  # No stray j-jenga*/twin directories were materialized under skills/.
  run ls "$PROJECT_DIR/skills"
  [ "$status" -eq 0 ]
  [ "$output" = "close-story" ]
}
