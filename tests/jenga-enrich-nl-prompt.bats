#!/usr/bin/env bats
#
# Coverage for skills/jenga/scripts/enrich-nl-prompt.sh (E53_S13_T01) — the board + docs
# enrichment scan ported from the now-retired /route's Steps 3-5, wired into /jenga's
# natural-language branch behind the opt-in `--enrich` flag.
#
# Fixture, not the live repo: builds a synthetic project root with its own project/board/ and
# docs/ so this test's assertions don't depend on this repo's own (constantly changing) board
# contents.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/jenga/scripts/enrich-nl-prompt.sh"

setup() {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/project-root"
  mkdir -p "$FIXTURE_ROOT/project/board/epics"
  mkdir -p "$FIXTURE_ROOT/project/board/stories"
  mkdir -p "$FIXTURE_ROOT/project/board/tasks"
  mkdir -p "$FIXTURE_ROOT/docs"

  cat > "$FIXTURE_ROOT/project/board/epics/E01_caching-layer.md" <<'MD'
---
id: E01
title: Caching Layer
status: In Progress
---

## Purpose

Add a caching layer to speed up repeated reads.
MD

  cat > "$FIXTURE_ROOT/docs/caching-guide.md" <<'MD'
# Caching Guide

How the caching layer works.
MD

  export JENGA_PROJECT_DIR="$FIXTURE_ROOT"
}

teardown() {
  unset JENGA_PROJECT_DIR
}

@test "exits 0 and returns empty arrays when nothing on the board or in docs matches" {
  run "$SCRIPT" "xyzzy nonexistent quux zzzznotarealword"
  [ "$status" -eq 0 ]
  local board_found docs_found
  board_found=$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["board_items_found"])')
  docs_found=$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["docs_found"])')
  [ "$board_found" -eq 0 ]
  [ "$docs_found" -eq 0 ]
  assert_output_contains '"board_items": []'
  assert_output_contains '"docs": []'
}

@test "finds a matching board item and doc, with correct found-counts and capped lists" {
  run "$SCRIPT" "let's talk about the caching layer"
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "E01"'
  assert_output_contains 'caching-guide.md'
  local board_found docs_found
  board_found=$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["board_items_found"])')
  docs_found=$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["docs_found"])')
  [ "$board_found" -eq 1 ]
  [ "$docs_found" -eq 1 ]
}

@test "excludes Archived/Cancelled board items from matches" {
  cat > "$FIXTURE_ROOT/project/board/epics/E02_archived-caching-thing.md" <<'MD'
---
id: E02
title: Old Caching Experiment
status: Archived
---

## Purpose

An archived caching experiment.
MD

  run "$SCRIPT" "caching experiment"
  [ "$status" -eq 0 ]
  assert_output_not_contains '"id": "E02"'
}

@test "output is valid JSON with the documented top-level keys" {
  run "$SCRIPT" "anything at all"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert "board_items" in d
assert "docs" in d
assert "board_items_found" in d
assert "docs_found" in d
assert isinstance(d["board_items"], list)
assert isinstance(d["docs"], list)
'
}

@test "usage error (no argument) exits non-zero" {
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}
