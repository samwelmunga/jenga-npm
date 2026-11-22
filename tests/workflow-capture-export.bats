#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# tests/workflow-capture-export.bats - j.workflow-capture export: one package per workflow (E103_S05_T02)
#
# Pins:
#   1. export-package.sh <id> writes one package (tar.gz) holding manifest.json, and the manifest lists every other
#      member with a sha256 that matches both the packaged and the source file.
#   2. An unknown workflow id exits non-zero with a message and writes nothing; a malformed id is a usage error.
#   3. The package holds only the definition, <workflows>/scripts/<id>/ and the render templates it references:
#      another workflow's files are never included, and a template or script that would reach outside is refused.
#   4. A workflow with no wrapper-script directory (E103_S04 not landed) still exports, with a valid manifest.
#   5. Nothing here reads or writes the active-recording pointer; capture-sources.sh reports export available.
# Every project tree lives under $BATS_TEST_TMPDIR.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
EP="$REPO_ROOT/skills/j-workflow-capture/scripts/export-package.sh"
CS="$REPO_ROOT/skills/j-workflow-capture/scripts/capture-sources.sh"

setup() {
  T="$BATS_TEST_TMPDIR"
  PROJ="$T/proj"
  mkdir -p "$PROJ/project/configs" "$T/out"
  printf '%s\n' '{"paths":{"workflows":"project/.workflows"}}' > "$PROJ/project/configs/workflow.json"
  WF="$PROJ/project/.workflows"
  mkdir -p "$WF"
  unset JENGA_WORKFLOWS_TEST_ROOT
  export JENGA_PROJECT_ROOT="$PROJ"
  export JENGA_RECORDING_STATE_DIR="$T/state"
  export JENGA_RECORDING_SESSION_ID="capture-export-$BATS_TEST_NUMBER"
  OUT="$T/out/pkg.tar.gz"
}

sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }

# A definition with one compute step and the render steps given as JSON objects in $2 (default: none).
write_def() {
  local id="$1" renders="${2:-}"
  printf '{"id":"%s","name":"%s","steps":[{"id":"a","type":"compute","command":"project/.workflows/scripts/%s/run.sh"}%s]}\n' \
    "$id" "$id" "$id" "${renders:+,$renders}" > "$WF/$id.json"
}

# The full fixture: release-notes has a wrapper directory (nested, one executable) and two templates, one of them
# referenced from a nested step; other-flow and an unreferenced template sit beside it and must never be packaged.
full_fixture() {
  mkdir -p "$WF/scripts/release-notes/lib" "$WF/templates" "$WF/scripts/other-flow" "$PROJ/docs/tpl"
  printf '#!/usr/bin/env bash\necho run\n' > "$WF/scripts/release-notes/run.sh"
  chmod +x "$WF/scripts/release-notes/run.sh"
  printf 'helper() { :; }\n' > "$WF/scripts/release-notes/lib/helper.sh"
  printf '# Notes {{inputs.version}}\n' > "$WF/templates/notes.md"
  printf '{"x": 1}\n' > "$PROJ/docs/tpl/data.json"
  printf 'unused\n' > "$WF/templates/unused.md"
  printf 'echo other\n' > "$WF/scripts/other-flow/run.sh"
  write_def other-flow
  write_def release-notes '{"id":"r1","type":"render","template":"project/.workflows/templates/notes.md","inputs":{}},
    {"id":"g","type":"group","steps":[{"id":"r2","type":"render","template":"docs/tpl/data.json","inputs":{}}]},
    {"id":"r3","type":"render","template":"project/.workflows/templates/notes.md","inputs":{}}'
}

manifest() { tar -xzOf "$OUT" manifest.json; }
members() { tar -tzf "$OUT" | grep -v '/$' | LC_ALL=C sort; }

@test "the script passes bash -n and --help exits 0 with usage" {
  run bash -n "$EP"
  [ "$status" -eq 0 ]
  run bash "$EP" --help
  [ "$status" -eq 0 ]
  assert_output_contains "usage:"
  assert_output_contains "jenga-workflow-package"
}

@test "a workflow with no wrapper-script directory and no template exports the definition and a valid manifest" {
  write_def solo
  run --separate-stderr bash "$EP" --out "$OUT" solo
  [ "$status" -eq 0 ]
  [ "$output" = "$OUT" ]
  [ -f "$OUT" ]
  [ "$(members | tr '\n' ' ')" = "definition/solo.json manifest.json " ]
  [ "$(manifest | jq -r '.format, .format_version, .workflow_id' | tr '\n' ' ')" = "jenga-workflow-package 1 solo " ]
  [ "$(manifest | jq '.files | length')" = "1" ]
  [ "$(manifest | jq -r '.files[0] | "\(.path) \(.role) \(.origin) \(.origin_base) \(.executable)"')" = \
    "definition/solo.json definition solo.json workflows false" ]
  [ "$(manifest | jq -r '.files[0].sha256')" = "$(sha "$WF/solo.json")" ]
  [ "$(manifest | jq -r '.files[0].size')" = "$(wc -c < "$WF/solo.json" | tr -d ' ')" ]
}

@test "the full package lists every member with a sha256 matching the packaged and the source file" {
  full_fixture
  run --separate-stderr bash "$EP" --out "$OUT" release-notes
  [ "$status" -eq 0 ]
  # Exactly the definition, the two wrapper files and the two referenced templates (the duplicate reference once).
  [ "$(members | tr '\n' ' ')" = "definition/release-notes.json manifest.json scripts/lib/helper.sh scripts/run.sh templates/docs/tpl/data.json templates/project/.workflows/templates/notes.md " ]
  # The manifest lists every member but itself, sorted, and nothing else.
  [ "$(manifest | jq -r '.files[].path' | tr '\n' ' ')" = "$(members | grep -v '^manifest.json$' | tr '\n' ' ')" ]
  mkdir -p "$T/x"
  tar -xzf "$OUT" -C "$T/x"
  local p src
  while IFS=$'\t' read -r p src; do
    [ "$(manifest | jq -r --arg p "$p" '.files[] | select(.path == $p) | .sha256')" = "$(sha "$T/x/$p")" ]
    [ "$(sha "$T/x/$p")" = "$(sha "$src")" ]
  done <<EOF
definition/release-notes.json	$WF/release-notes.json
scripts/run.sh	$WF/scripts/release-notes/run.sh
scripts/lib/helper.sh	$WF/scripts/release-notes/lib/helper.sh
templates/project/.workflows/templates/notes.md	$WF/templates/notes.md
templates/docs/tpl/data.json	$PROJ/docs/tpl/data.json
EOF
  [ "$(manifest | jq -r '.files[] | select(.path == "scripts/run.sh") | "\(.role) \(.origin) \(.origin_base) \(.executable)"')" = \
    "script scripts/release-notes/run.sh workflows true" ]
  [ "$(manifest | jq -r '.files[] | select(.path == "templates/docs/tpl/data.json") | "\(.role) \(.origin) \(.origin_base)"')" = \
    "template docs/tpl/data.json anchor" ]
  [ -x "$T/x/scripts/run.sh" ]
  # No absolute path of the exporting machine leaks into the manifest.
  assert_not_contains "$(manifest)" "$T"
}

@test "another workflow's files and an unreferenced template are never packaged" {
  full_fixture
  run --separate-stderr bash "$EP" --out "$OUT" release-notes
  [ "$status" -eq 0 ]
  assert_not_contains "$(tar -tzf "$OUT")" "other-flow"
  assert_not_contains "$(tar -tzf "$OUT")" "unused.md"
  run --separate-stderr bash "$EP" --out "$T/out/other.tar.gz" other-flow
  [ "$status" -eq 0 ]
  [ "$(tar -tzf "$T/out/other.tar.gz" | grep -v '/$' | LC_ALL=C sort | tr '\n' ' ')" = "definition/other-flow.json manifest.json scripts/run.sh " ]
}

@test "an unknown workflow id exits 3 with a message and writes nothing" {
  write_def solo
  run --separate-stderr bash "$EP" --out "$OUT" no-such-flow
  [ "$status" -eq 3 ]
  assert_contains "$stderr" 'no workflow "no-such-flow"'
  [ ! -e "$OUT" ]
  [ -z "$(ls -A "$T/out")" ]
}

@test "a malformed id is a usage error, so no path outside the workflows directory is read" {
  for id in ../solo solo/x Solo ""; do
    run --separate-stderr bash "$EP" --out "$OUT" "$id"
    [ "$status" -eq 2 ]
  done
  run --separate-stderr bash "$EP" --out "$OUT"
  [ "$status" -eq 2 ]
  [ ! -e "$OUT" ]
}

@test "a definition that is not JSON or has no steps array exits 4" {
  printf 'not json\n' > "$WF/broken.json"
  run --separate-stderr bash "$EP" --out "$OUT" broken
  [ "$status" -eq 4 ]
  printf '{"id":"nosteps"}\n' > "$WF/nosteps.json"
  run --separate-stderr bash "$EP" --out "$OUT" nosteps
  [ "$status" -eq 4 ]
  [ ! -e "$OUT" ]
}

@test "a template that would leave the project, is missing, is a reference or is a symlink is refused with exit 5" {
  printf 'outside\n' > "$T/outside.md"
  mkdir -p "$WF/templates"
  ln -s "$T/outside.md" "$WF/templates/link.md"
  ln -s "$T" "$PROJ/escape"
  local tpl
  for tpl in "../outside.md" "$T/outside.md" "project/.workflows/templates/missing.md" '${inputs.tpl}' \
             "project/.workflows/templates/link.md" "escape/outside.md"; do
    write_def bad "{\"id\":\"r\",\"type\":\"render\",\"template\":\"$tpl\",\"inputs\":{}}"
    run --separate-stderr bash "$EP" --out "$OUT" bad
    [ "$status" -eq 5 ] || { echo "template $tpl: status $status ($stderr)"; false; }
    [ ! -e "$OUT" ]
  done
  [ -z "$(ls -A "$T/out")" ]
}

@test "a symlink inside the wrapper-script directory is refused with exit 5" {
  write_def linked
  mkdir -p "$WF/scripts/linked"
  printf 'secret\n' > "$T/secret.txt"
  ln -s "$T/secret.txt" "$WF/scripts/linked/leak.txt"
  run --separate-stderr bash "$EP" --out "$OUT" linked
  [ "$status" -eq 5 ]
  assert_contains "$stderr" "symbolic link"
  [ ! -e "$OUT" ]
}

@test "an existing output file is refused with exit 7 unless --force" {
  write_def solo
  printf 'keep\n' > "$OUT"
  run --separate-stderr bash "$EP" --out "$OUT" solo
  [ "$status" -eq 7 ]
  [ "$(cat "$OUT")" = "keep" ]
  run --separate-stderr bash "$EP" --force --out "$OUT" solo
  [ "$status" -eq 0 ]
  [ "$(manifest | jq -r '.workflow_id')" = "solo" ]
  # No temporary file is left beside the package.
  [ "$(ls -A "$T/out")" = "pkg.tar.gz" ]
}

@test "the default output is ./<id>.workflow.tar.gz and the manifest is the same on a second export" {
  full_fixture
  cd "$T/out"
  run --separate-stderr bash "$EP" release-notes
  [ "$status" -eq 0 ]
  [ "$output" = "./release-notes.workflow.tar.gz" ]
  [ -f "$T/out/release-notes.workflow.tar.gz" ]
  first="$(tar -xzOf "$T/out/release-notes.workflow.tar.gz" manifest.json)"
  run --separate-stderr bash "$EP" --force release-notes
  [ "$status" -eq 0 ]
  [ "$(tar -xzOf "$T/out/release-notes.workflow.tar.gz" manifest.json)" = "$first" ]
}

@test "export never touches the active-recording pointer, and capture-sources reports export available" {
  full_fixture
  run --separate-stderr bash "$EP" --out "$OUT" release-notes
  [ "$status" -eq 0 ]
  [ ! -e "$T/state" ]
  run grep -n "active-recording.sh" "$EP"
  [ "$status" -eq 1 ]
  run bash "$CS" check export
  [ "$status" -eq 0 ]
  assert_output_contains "available"
}
