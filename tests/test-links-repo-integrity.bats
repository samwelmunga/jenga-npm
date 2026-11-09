#!/usr/bin/env bats
# Repo integrity guard for the committed test-to-architecture links (E83_S02_T05).
#
# Unlike tests/extract-test-links.bats and tests/validate-test-links.bats, which build synthetic fixture trees, this file
# deliberately runs against THIS repository: it protects project/knowledge-graph/test-links.json from rotting. The file is
# derived (scripts/extract-test-links.sh is its only writer; scripts/validate-test-links.sh owns its schema), so every failure
# below names the script to run.
#
# Cases:
#   1. the committed links file passes scripts/validate-test-links.sh --graph <graph.json>
#   2. every `file` named by a link exists on disk
#   3. scripts/extract-test-links.sh --stdout is byte-identical to the committed file. The file records the SHA-256 of
#      graph.json and of every linked test file, so editing a linked test, a link's annotation (path or node id) or the
#      graph without regenerating the file fails this case until the extractor is re-run.
#
# Skips (never fails) when the subject is absent, per the public-mirror rule in .publicignore's header: every case skips
# when scripts/validate-test-links.sh is not in the tree or jq is not installed; case 3 also skips when
# scripts/extract-test-links.sh is not in the tree. Scripts are mode 644 and are always called as `bash <script>`.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
VALIDATOR="$REPO_ROOT/scripts/validate-test-links.sh"
EXTRACTOR="$REPO_ROOT/scripts/extract-test-links.sh"
GRAPH="$REPO_ROOT/project/knowledge-graph/graph.json"
LINKS="$REPO_ROOT/project/knowledge-graph/test-links.json"

FIX_HINT="fix: run bash scripts/extract-test-links.sh to regenerate the links file (correct the arch-node annotation, or the moved or renamed test, first if the extractor reports it)"

setup() {
  [ -f "$VALIDATOR" ] || skip "scripts/validate-test-links.sh is not in this tree"
  command -v jq >/dev/null 2>&1 || skip "jq is not installed (the validator and the file check need it)"
}

@test "the committed links file passes scripts/validate-test-links.sh --graph against graph.json" {
  rc=0
  out="$(bash "$VALIDATOR" --graph "$GRAPH" "$LINKS" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "validate-test-links.sh exited $rc: $out"
    echo "$FIX_HINT"
    false
  fi
}

@test "every file named by a link in the committed links file exists on disk" {
  missing=""
  files="$(jq -r '.links[].file' "$LINKS" | sort -u)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$REPO_ROOT/$f" ] || missing="$missing $f"
  done <<< "$files"
  if [ -n "$missing" ]; then
    echo "linked test file(s) missing from disk:$missing"
    echo "$FIX_HINT"
    false
  fi
}

@test "scripts/extract-test-links.sh --stdout equals the committed links file" {
  [ -f "$EXTRACTOR" ] || skip "scripts/extract-test-links.sh is not in this tree"

  actual="$BATS_TEST_TMPDIR/actual.json"
  errf="$BATS_TEST_TMPDIR/stderr"
  rc=0
  bash "$EXTRACTOR" --root "$REPO_ROOT" --stdout > "$actual" 2> "$errf" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "extract-test-links.sh exited $rc:"
    cat "$errf"
    echo "$FIX_HINT"
    false
  fi
  if ! cmp -s "$actual" "$LINKS"; then
    echo "project/knowledge-graph/test-links.json is out of date (diff: committed vs freshly extracted):"
    diff "$LINKS" "$actual" || true
    echo "$FIX_HINT"
    false
  fi
}
