#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# tests/workflow-capture-import.bats - j.workflow-capture import: verified, review-first package import (E103_S05_T03)
#
# Pins:
#   1. Round trip: export from one fixture project, inspect and install into another; the imported definition
#      passes validate-workflow.sh, its compute commands resolve there and the loader lists it as a project workflow.
#   2. A manifest hash or size mismatch, an unlisted or missing member, a link member or an unsafe member name
#      aborts with exit 4 and nothing written.
#   3. inspect writes nothing and shows every file verbatim; install without --confirm writes nothing (exit 8).
#   4. An id collision with a project workflow needs rename or replace (exit 5 otherwise); a builtin id only rename.
#   5. A failed validation in the target rolls back everything written, restoring a replaced workflow.
#   6. Template conflicts and refused template destinations exit 7; a package without scripts/ still imports.
#   7. Nothing here touches the active-recording pointer; capture-sources.sh reports import available.
# Every project tree lives under $BATS_TEST_TMPDIR.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
EP="$REPO_ROOT/skills/j-workflow-capture/scripts/export-package.sh"
IP="$REPO_ROOT/skills/j-workflow-capture/scripts/import-package.sh"
CS="$REPO_ROOT/skills/j-workflow-capture/scripts/capture-sources.sh"
VALIDATE="$REPO_ROOT/scripts/workflow/validate-workflow.sh"
RESOLVE_CMD="$REPO_ROOT/scripts/workflow/resolve-compute-command.sh"
LOADER="$REPO_ROOT/scripts/workflow/load-workflows.sh"

new_project() {
  mkdir -p "$1/project/configs" "$1/project/.workflows"
  printf '%s\n' '{"paths":{"workflows":"project/.workflows"}}' > "$1/project/configs/workflow.json"
}

setup() {
  T="$BATS_TEST_TMPDIR"
  A="$T/a"; B="$T/b"
  new_project "$A"; new_project "$B"
  WA="$A/project/.workflows"; WB="$B/project/.workflows"
  unset JENGA_WORKFLOWS_TEST_ROOT
  export JENGA_RECORDING_STATE_DIR="$T/state"
  export JENGA_RECORDING_SESSION_ID="capture-import-$BATS_TEST_NUMBER"
  export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"
  PKG="$T/pkg.tar.gz"
}

# A workflow in project A: one compute step on its own wrapper script, one render step on a template.
make_workflow() {
  local id="$1"
  mkdir -p "$WA/scripts/$id/lib" "$WA/templates"
  printf '#!/usr/bin/env bash\necho "%s ran"\n' "$id" > "$WA/scripts/$id/run.sh"
  chmod +x "$WA/scripts/$id/run.sh"
  printf 'helper() { :; }\n' > "$WA/scripts/$id/lib/helper.sh"
  printf '# Notes for %s\n' "$id" > "$WA/templates/$id.md"
  printf '{"id":"%s","name":"%s","description":"fixture","steps":[{"id":"a","type":"compute","command":"project/.workflows/scripts/%s/run.sh"},{"id":"r","type":"render","template":"project/.workflows/templates/%s.md","inputs":{}}]}\n' \
    "$id" "$id" "$id" "$id" > "$WA/$id.json"
}

export_from_a() { rm -f "$PKG"; (cd "$T" && JENGA_PROJECT_ROOT="$A" bash "$EP" --out "$PKG" "$1" 2>/dev/null) >/dev/null; }
in_b() { (cd "$B" && JENGA_PROJECT_ROOT="$B" "$@"); }
tree_of() { (cd "$1" && find . -print | LC_ALL=C sort); }
unpack() { rm -rf "$T/x"; mkdir -p "$T/x"; tar -xzf "$PKG" -C "$T/x"; }
repack() { (cd "$T/x" && COPYFILE_DISABLE=1 tar -czf "$PKG" $(ls)); }
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }
# Rewrites the manifest entry for member $1 so its sha256 and size match the (edited) unpacked file.
reseal() {
  local s z; s="$(sha "$T/x/$1")"; z="$(wc -c < "$T/x/$1" | tr -d ' ')"
  jq --arg p "$1" --arg s "$s" --argjson z "$z" '(.files[] | select(.path == $p)) |= (.sha256 = $s | .size = $z)' \
    "$T/x/manifest.json" > "$T/x/m" && mv "$T/x/m" "$T/x/manifest.json"
}
# Crafts a package from the unpacked tree plus one extra member named $1 of tar type $2 (file|symlink|hardlink).
craft() {
  python3 -I - "$T/x" "$PKG" "$1" "$2" <<'PY'
import io, os, sys, tarfile
src, out, name, kind = sys.argv[1:5]
with tarfile.open(out, "w:gz") as tf:
    for root, dirs, files in os.walk(src):
        for f in sorted(files):
            p = os.path.join(root, f)
            tf.add(p, arcname=os.path.relpath(p, src))
    ti = tarfile.TarInfo(name)
    if kind == "symlink":
        ti.type = tarfile.SYMTYPE; ti.linkname = "/etc/passwd"; tf.addfile(ti)
    elif kind == "hardlink":
        ti.type = tarfile.LNKTYPE; ti.linkname = "manifest.json"; tf.addfile(ti)
    else:
        data = b"x\n"; ti.size = len(data); tf.addfile(ti, io.BytesIO(data))
PY
}

@test "the script passes bash -n and --help exits 0 with usage" {
  run bash -n "$IP"
  [ "$status" -eq 0 ]
  run bash "$IP" --help
  [ "$status" -eq 0 ]
  assert_output_contains "usage:"
  assert_output_contains "inspect"
  assert_output_contains "--confirm"
  run bash "$IP"
  [ "$status" -eq 2 ]
  run bash "$IP" install "$PKG" --rename x --replace
  [ "$status" -eq 2 ]
}

@test "round trip: export from one project, import into another; validated, commands resolve, listed as project" {
  make_workflow release-notes
  export_from_a release-notes
  before="$(tree_of "$B")"
  run --separate-stderr in_b bash "$IP" inspect "$PKG"
  [ "$status" -eq 0 ]
  [ "$(tree_of "$B")" = "$before" ]
  assert_output_contains "installs-as  release-notes"
  assert_output_contains "collision    none"
  assert_output_contains "command      a project/.workflows/scripts/release-notes/run.sh"
  # Every file verbatim between sha-stamped markers.
  assert_output_contains "===== BEGIN scripts/run.sh sha256:$(sha "$WA/scripts/release-notes/run.sh") ====="
  assert_output_contains 'echo "release-notes ran"'
  assert_output_contains "helper() { :; }"
  assert_output_contains "# Notes for release-notes"
  assert_output_contains "===== BEGIN definition/release-notes.json"

  run --separate-stderr in_b bash "$IP" install "$PKG" --confirm
  [ "$status" -eq 0 ]
  [ "$output" = "$(cd "$B" && pwd -P)/project/.workflows/release-notes.json" ]
  cmp "$WA/release-notes.json" "$WB/release-notes.json"
  cmp "$WA/scripts/release-notes/run.sh" "$WB/scripts/release-notes/run.sh"
  cmp "$WA/scripts/release-notes/lib/helper.sh" "$WB/scripts/release-notes/lib/helper.sh"
  cmp "$WA/templates/release-notes.md" "$WB/templates/release-notes.md"
  [ -x "$WB/scripts/release-notes/run.sh" ]
  [ ! -x "$WB/scripts/release-notes/lib/helper.sh" ]
  [ ! -x "$WB/templates/release-notes.md" ]
  # The imported definition validates and its compute commands resolve in the target project.
  run bash "$VALIDATE" "$WB/release-notes.json"
  [ "$status" -eq 0 ]
  cmd="$(jq -r '.steps[] | select(.type == "compute") | .command' "$WB/release-notes.json")"
  run in_b bash "$RESOLVE_CMD" "$cmd"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cd "$WB/scripts/release-notes" && pwd -P)/run.sh" ]
  run --separate-stderr in_b bash "$LOADER" lookup release-notes
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .source)" = "project" ]
  # No temporary file is left in the project.
  [ -z "$(find "$B" -name '.import-package.*')" ]
}

@test "a manifest hash mismatch aborts the import with nothing written" {
  make_workflow flow
  export_from_a flow
  unpack
  printf 'echo injected\n' >> "$T/x/scripts/run.sh"
  repack
  before="$(tree_of "$B")"
  for mode in inspect "install --confirm"; do
    run --separate-stderr in_b bash "$IP" $mode "$PKG"
    [ "$status" -eq 4 ]
    assert_contains "$stderr" "sha256 mismatch for scripts/run.sh"
    [ -z "$output" ]
  done
  [ "$(tree_of "$B")" = "$before" ]
}

@test "a size mismatch, an unlisted member and a missing member each abort with exit 4" {
  make_workflow flow
  export_from_a flow
  before="$(tree_of "$B")"
  unpack
  jq '(.files[] | select(.path == "scripts/run.sh") | .size) += 1' "$T/x/manifest.json" > "$T/x/m" && mv "$T/x/m" "$T/x/manifest.json"
  repack
  run --separate-stderr in_b bash "$IP" install "$PKG" --confirm
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "size mismatch"
  export_from_a flow
  unpack
  printf 'extra\n' > "$T/x/scripts/extra.sh"
  repack
  run --separate-stderr in_b bash "$IP" install "$PKG" --confirm
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "does not list"
  export_from_a flow
  unpack
  rm "$T/x/scripts/lib/helper.sh"
  repack
  run --separate-stderr in_b bash "$IP" install "$PKG" --confirm
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "does not hold"
  [ "$(tree_of "$B")" = "$before" ]
}

@test "link members and unsafe member names are refused before anything is unpacked into the project" {
  make_workflow flow
  export_from_a flow
  before="$(tree_of "$B")"
  local spec
  for spec in "scripts/evil:symlink" "scripts/hard:hardlink" "../escape.sh:file" "/abs.sh:file" \
              "scripts/../../x.sh:file" "other/x.sh:file"; do
    export_from_a flow
    unpack
    craft "${spec%%:*}" "${spec##*:}"
    run --separate-stderr in_b bash "$IP" inspect "$PKG"
    [ "$status" -eq 4 ] || { echo "$spec: status $status ($stderr)"; false; }
    [ -z "$output" ]
  done
  [ "$(tree_of "$B")" = "$before" ]
  [ ! -e "$T/escape.sh" ]
}

@test "not a package: a missing file, a non-gzip file and an archive without a manifest exit 3" {
  run --separate-stderr in_b bash "$IP" inspect "$T/missing.tar.gz"
  [ "$status" -eq 3 ]
  printf 'plain\n' > "$T/plain.tar.gz"
  run --separate-stderr in_b bash "$IP" inspect "$T/plain.tar.gz"
  [ "$status" -eq 3 ]
  mkdir -p "$T/nm/definition"; printf '{}\n' > "$T/nm/definition/x.json"
  (cd "$T/nm" && tar -czf "$T/nm.tar.gz" definition)
  run --separate-stderr in_b bash "$IP" inspect "$T/nm.tar.gz"
  [ "$status" -eq 3 ]
}

@test "install without --confirm writes nothing" {
  make_workflow flow
  export_from_a flow
  before="$(tree_of "$B")"
  run --separate-stderr in_b bash "$IP" install "$PKG"
  [ "$status" -eq 8 ]
  assert_contains "$stderr" "--confirm"
  [ "$(tree_of "$B")" = "$before" ]
}

@test "a project id collision needs a choice; rename installs under the new id with rewritten commands" {
  make_workflow flow
  export_from_a flow
  printf '{"id":"flow","name":"mine","description":"existing","steps":[{"id":"c","type":"confirm","prompt":"ok?"}]}\n' > "$WB/flow.json"
  cp "$WB/flow.json" "$T/orig.json"
  run --separate-stderr in_b bash "$IP" inspect "$PKG"
  [ "$status" -eq 5 ]
  assert_output_contains "collision    project"
  assert_output_contains "===== BEGIN scripts/run.sh"
  assert_contains "$stderr" "rename, replace or cancel"
  run --separate-stderr in_b bash "$IP" install "$PKG" --confirm
  [ "$status" -eq 5 ]
  [ ! -e "$WB/scripts/flow" ]
  cmp "$WB/flow.json" "$T/orig.json"
  # Rename to an id that also collides is refused.
  run --separate-stderr in_b bash "$IP" install "$PKG" --confirm --rename flow
  [ "$status" -eq 5 ]
  run --separate-stderr in_b bash "$IP" install "$PKG" --confirm --rename "Bad_Id"
  [ "$status" -eq 2 ]
  run --separate-stderr in_b bash "$IP" install "$PKG" --confirm --rename flow-copy
  [ "$status" -eq 0 ]
  cmp "$WB/flow.json" "$T/orig.json"
  [ "$(jq -r .id "$WB/flow-copy.json")" = "flow-copy" ]
  [ "$(jq -r '.steps[0].command' "$WB/flow-copy.json")" = "project/.workflows/scripts/flow-copy/run.sh" ]
  [ -x "$WB/scripts/flow-copy/run.sh" ]
  run in_b bash "$RESOLVE_CMD" project/.workflows/scripts/flow-copy/run.sh
  [ "$status" -eq 0 ]
}

@test "replace overwrites the project workflow; a failed validation restores it" {
  make_workflow flow
  export_from_a flow
  mkdir -p "$WB/scripts/flow"
  printf '{"id":"flow","name":"mine","description":"existing","steps":[{"id":"c","type":"confirm","prompt":"ok?"}]}\n' > "$WB/flow.json"
  printf 'old\n' > "$WB/scripts/flow/old.sh"
  cp "$WB/flow.json" "$T/orig.json"
  before="$(tree_of "$B")"
  # A package whose script lost its executable bit installs, then fails resolve-compute-command.sh: rolled back.
  unpack
  chmod -x "$T/x/scripts/run.sh"
  jq '(.files[] | select(.path == "scripts/run.sh") | .executable) = false' "$T/x/manifest.json" > "$T/x/m" && mv "$T/x/m" "$T/x/manifest.json"
  repack
  run --separate-stderr in_b bash "$IP" install "$PKG" --confirm --replace
  [ "$status" -eq 9 ]
  assert_contains "$stderr" "resolve-compute-command.sh"
  assert_contains "$stderr" "rolled back"
  [ "$(tree_of "$B")" = "$before" ]
  cmp "$WB/flow.json" "$T/orig.json"
  [ "$(cat "$WB/scripts/flow/old.sh")" = "old" ]
  # The intact package replaces the definition and the scripts directory.
  export_from_a flow
  run --separate-stderr in_b bash "$IP" inspect "$PKG" --replace
  [ "$status" -eq 0 ]
  assert_output_contains "choice       replace"
  assert_output_contains "[replaces]"
  run --separate-stderr in_b bash "$IP" install "$PKG" --confirm --replace
  [ "$status" -eq 0 ]
  cmp "$WA/flow.json" "$WB/flow.json"
  [ ! -e "$WB/scripts/flow/old.sh" ]
  [ -x "$WB/scripts/flow/run.sh" ]
}

@test "a definition that fails validate-workflow.sh is refused before anything is written" {
  make_workflow flow
  export_from_a flow
  unpack
  jq 'del(.description)' "$T/x/definition/flow.json" > "$T/x/d" && mv "$T/x/d" "$T/x/definition/flow.json"
  reseal definition/flow.json
  repack
  before="$(tree_of "$B")"
  run --separate-stderr in_b bash "$IP" install "$PKG" --confirm
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "validate-workflow.sh"
  [ "$(tree_of "$B")" = "$before" ]
}

@test "a builtin id always wins: replace is refused and rename is the way" {
  builtin_id="$(jq -r .id "$REPO_ROOT/templates/workflows/epic-wrap-up.json")"
  make_workflow "$builtin_id"
  export_from_a "$builtin_id"
  run --separate-stderr in_b bash "$IP" inspect "$PKG"
  [ "$status" -eq 5 ]
  assert_output_contains "collision    builtin"
  assert_contains "$stderr" "--rename"
  run --separate-stderr in_b bash "$IP" install "$PKG" --confirm --replace
  [ "$status" -eq 5 ]
  [ ! -e "$WB/$builtin_id.json" ]
  run --separate-stderr in_b bash "$IP" install "$PKG" --confirm --rename my-wrap-up
  [ "$status" -eq 0 ]
  [ "$(jq -r .id "$WB/my-wrap-up.json")" = "my-wrap-up" ]
}

@test "templates: identical is left alone, a differing one is a conflict, a script-directory destination is refused" {
  make_workflow flow
  export_from_a flow
  mkdir -p "$WB/templates"
  printf 'my own notes\n' > "$WB/templates/flow.md"
  run --separate-stderr in_b bash "$IP" install "$PKG" --confirm
  [ "$status" -eq 7 ]
  [ "$(cat "$WB/templates/flow.md")" = "my own notes" ]
  [ ! -e "$WB/flow.json" ]
  cp "$WA/templates/flow.md" "$WB/templates/flow.md"
  run --separate-stderr in_b bash "$IP" inspect "$PKG"
  [ "$status" -eq 0 ]
  assert_output_contains "[unchanged]"
  # A template aimed at a compute script root.
  unpack
  mkdir -p "$T/x/templates/scripts"
  printf 'echo pwned\n' > "$T/x/templates/scripts/evil.sh"
  jq --arg s "$(sha "$T/x/templates/scripts/evil.sh")" '.files += [{"path":"templates/scripts/evil.sh","role":"template","origin":"scripts/evil.sh","origin_base":"anchor","sha256":$s,"size":11,"executable":false}]' \
    "$T/x/manifest.json" > "$T/x/m" && mv "$T/x/m" "$T/x/manifest.json"
  repack
  run --separate-stderr in_b bash "$IP" install "$PKG" --confirm --rename flow2
  [ "$status" -eq 7 ]
  [ ! -e "$B/scripts/evil.sh" ]
  [ ! -e "$WB/flow2.json" ]
}

@test "a package without a scripts directory (no wrappers yet) imports" {
  printf '{"id":"plain","name":"plain","description":"fixture","steps":[{"id":"c","type":"confirm","prompt":"ok?","options":["Yes","No"]}]}\n' > "$WA/plain.json"
  export_from_a plain
  [ -z "$(tar -tzf "$PKG" | grep '^scripts')" ]
  run --separate-stderr in_b bash "$IP" install "$PKG" --confirm
  [ "$status" -eq 0 ]
  cmp "$WA/plain.json" "$WB/plain.json"
  [ ! -e "$WB/scripts" ]
}

@test "a script with control characters is shown in cat -v notation" {
  make_workflow flow
  printf '#!/usr/bin/env bash\necho hidden\033[2K\necho shown\n' > "$WA/scripts/flow/run.sh"
  export_from_a flow
  run --separate-stderr in_b bash "$IP" inspect "$PKG"
  [ "$status" -eq 0 ]
  assert_output_contains "(control characters shown as ^X, in cat -v notation)"
  assert_output_contains 'echo hidden^[[2K'
}

@test "import never touches the active-recording pointer, and capture-sources reports import available" {
  make_workflow flow
  export_from_a flow
  run --separate-stderr in_b bash "$IP" install "$PKG" --confirm
  [ "$status" -eq 0 ]
  [ ! -e "$T/state" ]
  run grep -n "active-recording.sh" "$IP"
  [ "$status" -eq 1 ]
  run bash "$CS" check import
  [ "$status" -eq 0 ]
  assert_output_contains "available"
}
