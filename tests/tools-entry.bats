#!/usr/bin/env bats
#
# Coverage for skills/j-tools/scripts/tools-entry.sh (E66_S03_T03).
#
# Every test runs against temp files: HOME points at a temp directory, the user layer is
# selected with JENGA_USER_TOOLS_FILE, and the project layer lives in a temp project selected
# with JENGA_PROJECT_ROOT. Nothing here reads or writes the real ~/.jenga/ or the real
# project/configs/preferred-tools.json (one test proves that). The real descriptor directory
# is only read.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ENTRY="$REPO_ROOT/skills/j-tools/scripts/tools-entry.sh"
REAL_PROJECT_FILE="$REPO_ROOT/project/configs/preferred-tools.json"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"

  USER_FILE="$BATS_TEST_TMPDIR/userdir/tools.json" # directory deliberately absent
  export JENGA_USER_TOOLS_FILE="$USER_FILE"

  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/project/configs"
  printf '{"paths":{"configs":"project/configs"}}\n' > "$PROJ/project/configs/workflow.json"
  PROJECT_FILE="$PROJ/project/configs/preferred-tools.json"
  export JENGA_PROJECT_ROOT="$PROJ"
  unset JENGA_DESCRIPTORS_DIR

  if [ -e "$REAL_PROJECT_FILE" ]; then
    REAL_PROJECT_SUM="$(cksum < "$REAL_PROJECT_FILE")"
  else
    REAL_PROJECT_SUM="absent"
  fi
}

# layer_file <layer>: path of that layer's file in the sandbox.
layer_file() {
  case "$1" in
    user) printf '%s' "$USER_FILE" ;;
    project) printf '%s' "$PROJECT_FILE" ;;
  esac
}

entry() { run --separate-stderr bash "$ENTRY" "$@"; }

# A hand-written registry: an extra top-level key, an unknown entry key, a suppress list, an
# extended category, and three entries in a non-canonical key order.
write_hand_file() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'JSON'
{
  "registry_version": 1,
  "x_comment": {"owner": "me", "list": [1, 2, 3]},
  "categories": ["docs"],
  "suppress": ["old-tool"],
  "tools": [
    {"name": "keep-a", "category": "runtime", "enforcement": "required", "rationale": "ra",
     "alternatives": [{"name": "alt", "why_not": "nope"}], "version": ">=1.5",
     "install_hint": {"descriptor": "github", "text": "brew install a"}, "x_note": "hand written"},
    {"version": "*", "name": "keep-b", "rationale": "rb", "enforcement": "recommended",
     "category": "docs", "alternatives": [], "install_hint": {"text": "see site"}},
    {"name": "keep-c", "category": "lint", "enforcement": "recommended", "rationale": "rc",
     "alternatives": [], "version": "^20", "install_hint": {"text": "npm i c"}}
  ]
}
JSON
}

# valid_file <path>: the validator accepts it.
valid_file() { bash "$REPO_ROOT/scripts/validate-tools-registry.sh" "$1"; }

# canon <path>: canonical (sorted-key) compact JSON of a file.
canon() { jq -S -c . "$1"; }

# same_entry <before-file> <after-file> <name>: that entry is unchanged between the two files.
same_entry() {
  local a b
  a="$(jq -S -c --arg n "$3" '.tools[] | select(.name == $n)' "$1")"
  b="$(jq -S -c --arg n "$3" '.tools[] | select(.name == $n)' "$2")"
  [ -n "$a" ] && [ "$a" = "$b" ]
}

# add_basic <layer> <name>: a minimal valid add.
add_basic() {
  entry add --layer "$1" --name "$2" --category lint --enforcement recommended \
    --rationale "why $2" --version ">=1.0" --install-text "install $2"
}

no_temp_files() { [ -z "$(find "$1" -name '.tools-entry.*' 2>/dev/null)" ]; }

# --- add ----------------------------------------------------------------------

@test "add, user layer: creates the missing file (and its directory) as a minimal valid registry" {
  [ ! -e "$USER_FILE" ]
  entry add --layer user --name shellcheck --category lint --enforcement required \
    --rationale "CI gate" --version ">=0.9" --alternative "bashate::weaker" \
    --alternative "none::n/a" --descriptor github --install-text "brew install shellcheck"
  [ "$status" -eq 0 ]
  [ -f "$USER_FILE" ]
  valid_file "$USER_FILE"
  [ "$(jq -r '.registry_version' "$USER_FILE")" = "1" ]
  [ "$(jq -r '.tools | length' "$USER_FILE")" = "1" ]
  [ "$(jq -r '.tools[0].name' "$USER_FILE")" = "shellcheck" ]
  [ "$(jq -r '.tools[0].enforcement' "$USER_FILE")" = "required" ]
  [ "$(jq -r '.tools[0].version' "$USER_FILE")" = ">=0.9" ]
  [ "$(jq -r '.tools[0].alternatives | length' "$USER_FILE")" = "2" ]
  [ "$(jq -r '.tools[0].alternatives[0].why_not' "$USER_FILE")" = "weaker" ]
  [ "$(jq -r '.tools[0].install_hint.descriptor' "$USER_FILE")" = "github" ]
  [ "$(jq -r '.ok' <<<"$output")" = "true" ]
  [ "$(jq -r '.layer' <<<"$output")" = "user" ]
  [ "$(jq -r '.path' <<<"$output")" = "$USER_FILE" ]
  [ -z "$stderr" ]
}

@test "add, project layer: creates the missing file at the resolved configs path" {
  [ ! -e "$PROJECT_FILE" ]
  add_basic project shellcheck
  [ "$status" -eq 0 ]
  valid_file "$PROJECT_FILE"
  [ "$(jq -r '.tools[0].name' "$PROJECT_FILE")" = "shellcheck" ]
  [ "$(jq -r '.path' <<<"$output")" = "$PROJECT_FILE" ]
}

@test "add, project layer follows a relocated configs path, not a hardcoded project/ literal" {
  mkdir -p "$PROJ/custom/cfg"
  printf '{"paths":{"configs":"custom/cfg"}}\n' > "$PROJ/project/configs/workflow.json"
  add_basic project shellcheck
  [ "$status" -eq 0 ]
  [ -f "$PROJ/custom/cfg/preferred-tools.json" ]
  [ ! -e "$PROJECT_FILE" ]
}

@test "add: the project layer is found from the working directory when JENGA_PROJECT_ROOT is unset" {
  unset JENGA_PROJECT_ROOT
  cd "$PROJ"
  add_basic project shellcheck
  [ "$status" -eq 0 ]
  [ -f "$PROJECT_FILE" ]
}

@test "add: defaults version to * and alternatives to an empty list" {
  entry add --layer user --name t --category infra --enforcement recommended --rationale r --install-text i
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tools[0].version' "$USER_FILE")" = "*" ]
  [ "$(jq -c '.tools[0].alternatives' "$USER_FILE")" = "[]" ]
}

@test "add: a name already present in the layer is refused and the file is untouched" {
  add_basic user dup
  cp "$USER_FILE" "$BATS_TEST_TMPDIR/before.json"
  add_basic user dup
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "already exists"
  cmp "$USER_FILE" "$BATS_TEST_TMPDIR/before.json"
}

@test "add: the same name may exist in the other layer" {
  add_basic user both
  add_basic project both
  [ "$status" -eq 0 ]
  valid_file "$USER_FILE"
  valid_file "$PROJECT_FILE"
}

@test "add --add-category: declares a new category in the layer and uses it" {
  entry add --layer user --name d --category docs --add-category --enforcement recommended \
    --rationale r --install-text i
  [ "$status" -eq 0 ]
  [ "$(jq -c '.categories' "$USER_FILE")" = '["docs"]' ]
  [ "$(jq -r '.tools[0].category' "$USER_FILE")" = "docs" ]
  valid_file "$USER_FILE"
}

@test "add --add-category: a base category is not added to categories" {
  entry add --layer user --name d --category lint --add-category --enforcement recommended \
    --rationale r --install-text i
  [ "$status" -eq 0 ]
  [ "$(jq -c '.categories' "$USER_FILE")" = "[]" ]
}

@test "add: an extended category without --add-category is rejected" {
  entry add --layer user --name d --category docs --enforcement recommended --rationale r --install-text i
  [ "$status" -eq 4 ]
  assert_contains "$stderr" 'unknown category "docs"'
  [ ! -e "$USER_FILE" ]
}

# --- edit ---------------------------------------------------------------------

@test "edit, both layers: changes only the supplied fields" {
  local layer f
  for layer in user project; do
    add_basic "$layer" tool
    [ "$status" -eq 0 ]
    f="$(layer_file "$layer")"
    cp "$f" "$BATS_TEST_TMPDIR/before-$layer.json"
    entry edit --layer "$layer" --name tool --enforcement required --version "^2"
    [ "$status" -eq 0 ]
    valid_file "$f"
    [ "$(jq -r '.tools[0].enforcement' "$f")" = "required" ]
    [ "$(jq -r '.tools[0].version' "$f")" = "^2" ]
    [ "$(jq -r '.tools[0].rationale' "$f")" = "why tool" ]
    [ "$(jq -r '.tools[0].category' "$f")" = "lint" ]
    [ "$(jq -c '.tools[0].install_hint' "$f")" = '{"text":"install tool"}' ]
  done
}

@test "edit: --alternative replaces the whole list and --clear-alternatives empties it" {
  add_basic user tool
  entry edit --layer user --name tool --alternative "a::1" --alternative "b::2"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tools[0].alternatives | length' "$USER_FILE")" = "2" ]
  entry edit --layer user --name tool --alternative "c::3"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.tools[0].alternatives' "$USER_FILE")" = '[{"name":"c","why_not":"3"}]' ]
  entry edit --layer user --name tool --clear-alternatives
  [ "$status" -eq 0 ]
  [ "$(jq -c '.tools[0].alternatives' "$USER_FILE")" = "[]" ]
}

@test "edit: install hint parts are set and cleared independently; clearing both is rejected" {
  add_basic user tool
  entry edit --layer user --name tool --descriptor github
  [ "$status" -eq 0 ]
  [ "$(jq -c '.tools[0].install_hint' "$USER_FILE")" = '{"text":"install tool","descriptor":"github"}' ]
  entry edit --layer user --name tool --clear-install-text
  [ "$status" -eq 0 ]
  [ "$(jq -c '.tools[0].install_hint' "$USER_FILE")" = '{"descriptor":"github"}' ]
  cp "$USER_FILE" "$BATS_TEST_TMPDIR/before.json"
  entry edit --layer user --name tool --clear-descriptor
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "install_hint needs a descriptor and/or text"
  cmp "$USER_FILE" "$BATS_TEST_TMPDIR/before.json"
}

@test "edit: an absent name is refused with exit 1 and nothing is written" {
  add_basic user other
  cp "$USER_FILE" "$BATS_TEST_TMPDIR/before.json"
  entry edit --layer user --name ghost --rationale x
  [ "$status" -eq 1 ]
  assert_contains "$stderr" 'no tool named "ghost"'
  cmp "$USER_FILE" "$BATS_TEST_TMPDIR/before.json"
}

@test "edit with no field flag is a usage error" {
  add_basic user tool
  entry edit --layer user --name tool
  [ "$status" -eq 2 ]
}

# --- remove -------------------------------------------------------------------

@test "remove, both layers: drops only the named entry" {
  local layer f
  for layer in user project; do
    add_basic "$layer" gone
    add_basic "$layer" stays
    f="$(layer_file "$layer")"
    cp "$f" "$BATS_TEST_TMPDIR/before-$layer.json"
    entry remove --layer "$layer" --name gone
    [ "$status" -eq 0 ]
    valid_file "$f"
    [ "$(jq -r '.tools | length' "$f")" = "1" ]
    [ "$(jq -r '.tools[0].name' "$f")" = "stays" ]
    same_entry "$BATS_TEST_TMPDIR/before-$layer.json" "$f" stays
  done
}

@test "remove: an absent name is refused with exit 1 and the file is untouched" {
  add_basic user a
  cp "$USER_FILE" "$BATS_TEST_TMPDIR/before.json"
  entry remove --layer user --name ghost
  [ "$status" -eq 1 ]
  cmp "$USER_FILE" "$BATS_TEST_TMPDIR/before.json"
}

# --- suppress / unsuppress -----------------------------------------------------

@test "suppress, both layers: adds the name to suppress and the file stays valid" {
  local layer f
  for layer in user project; do
    entry suppress --layer "$layer" --name doctl
    [ "$status" -eq 0 ]
    f="$(layer_file "$layer")"
    valid_file "$f"
    [ "$(jq -c '.suppress' "$f")" = '["doctl"]' ]
    [ "$(jq -r '.changed' <<<"$output")" = "true" ]
  done
}

@test "suppress is idempotent: a second call changes nothing and reports changed false" {
  entry suppress --layer project --name doctl
  cp "$PROJECT_FILE" "$BATS_TEST_TMPDIR/before.json"
  entry suppress --layer project --name doctl
  [ "$status" -eq 0 ]
  [ "$(jq -r '.changed' <<<"$output")" = "false" ]
  cmp "$PROJECT_FILE" "$BATS_TEST_TMPDIR/before.json"
}

@test "suppress hides a shipped entry from the effective list; unsuppress brings it back" {
  shipped_name="$(jq -r '.tools[0].name' "$REPO_ROOT/skills/j-tools/assets/shipped-tools.json")"
  run --separate-stderr bash "$REPO_ROOT/scripts/resolve-tools.sh"
  [ "$(jq -r --arg n "$shipped_name" '[.tools[] | select(.name == $n)] | length' <<<"$output")" = "1" ]

  entry suppress --layer project --name "$shipped_name"
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$REPO_ROOT/scripts/resolve-tools.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r --arg n "$shipped_name" '[.tools[] | select(.name == $n)] | length' <<<"$output")" = "0" ]

  entry unsuppress --layer project --name "$shipped_name"
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$REPO_ROOT/scripts/resolve-tools.sh"
  [ "$(jq -r --arg n "$shipped_name" '[.tools[] | select(.name == $n)] | length' <<<"$output")" = "1" ]
}

@test "unsuppress: a name that is not suppressed is refused with exit 1" {
  entry unsuppress --layer user --name nothing
  [ "$status" -eq 1 ]
}

@test "an entry written by add is visible through the resolver with the right layer" {
  add_basic user from-user
  add_basic project from-project
  run --separate-stderr bash "$REPO_ROOT/scripts/resolve-tools.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tools[] | select(.name == "from-user") | .layer' <<<"$output")" = "user" ]
  [ "$(jq -r '.tools[] | select(.name == "from-project") | .layer' <<<"$output")" = "project" ]
}

# --- preservation of hand-written content -------------------------------------

@test "every write kind preserves unrelated hand-written entries and unknown keys, in both layers" {
  local layer f
  for layer in user project; do
    f="$(layer_file "$layer")"
    write_hand_file "$f"
    cp "$f" "$BATS_TEST_TMPDIR/orig-$layer.json"

    add_basic "$layer" brand-new
    [ "$status" -eq 0 ]
    entry edit --layer "$layer" --name brand-new --rationale "changed"
    [ "$status" -eq 0 ]
    entry suppress --layer "$layer" --name other-shipped
    [ "$status" -eq 0 ]
    entry remove --layer "$layer" --name brand-new
    [ "$status" -eq 0 ]
    entry unsuppress --layer "$layer" --name other-shipped
    [ "$status" -eq 0 ]

    # After adding and removing and un/suppressing, the parsed content equals the original.
    [ "$(canon "$f")" = "$(canon "$BATS_TEST_TMPDIR/orig-$layer.json")" ]
  done
}

@test "edit of one hand-written entry leaves its siblings and the unknown keys identical" {
  write_hand_file "$USER_FILE"
  cp "$USER_FILE" "$BATS_TEST_TMPDIR/orig.json"
  entry edit --layer user --name keep-b --enforcement required
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tools[] | select(.name == "keep-b") | .enforcement' "$USER_FILE")" = "required" ]
  same_entry "$BATS_TEST_TMPDIR/orig.json" "$USER_FILE" keep-a
  same_entry "$BATS_TEST_TMPDIR/orig.json" "$USER_FILE" keep-c
  [ "$(jq -S -c '.x_comment' "$USER_FILE")" = "$(jq -S -c '.x_comment' "$BATS_TEST_TMPDIR/orig.json")" ]
  [ "$(jq -c '.categories' "$USER_FILE")" = '["docs"]' ]
  [ "$(jq -c '.suppress' "$USER_FILE")" = '["old-tool"]' ]
  [ "$(jq -r '.tools[0].x_note' "$USER_FILE")" = "hand written" ]
  [ "$(jq -r '.tools | length' "$USER_FILE")" = "3" ]
}

@test "an existing file keeps its mode through a write" {
  add_basic user a
  chmod 600 "$USER_FILE"
  add_basic user b
  [ "$status" -eq 0 ]
  find "$USER_FILE" -perm 600 | grep -q .
}

# --- invalid input leaves the file untouched ----------------------------------

@test "invalid category: exit 4, validator message, file byte-identical, no temp files left" {
  write_hand_file "$USER_FILE"
  cp "$USER_FILE" "$BATS_TEST_TMPDIR/before.json"
  entry add --layer user --name bad --category nonsense --enforcement required --rationale r --install-text i
  [ "$status" -eq 4 ]
  assert_contains "$stderr" 'unknown category "nonsense"'
  assert_contains "$stderr" "$USER_FILE"
  cmp "$USER_FILE" "$BATS_TEST_TMPDIR/before.json"
  no_temp_files "$(dirname "$USER_FILE")"
  [ -z "$output" ]
}

@test "invalid enforcement value: exit 4 and file untouched, in both layers" {
  local layer f
  for layer in user project; do
    f="$(layer_file "$layer")"
    write_hand_file "$f"
    cp "$f" "$BATS_TEST_TMPDIR/before-$layer.json"
    entry add --layer "$layer" --name bad --category lint --enforcement maybe --rationale r --install-text i
    [ "$status" -eq 4 ]
    assert_contains "$stderr" "bad enforcement value"
    cmp "$f" "$BATS_TEST_TMPDIR/before-$layer.json"
  done
}

@test "malformed version constraint: exit 4 and file untouched" {
  add_basic user good
  cp "$USER_FILE" "$BATS_TEST_TMPDIR/before.json"
  entry edit --layer user --name good --version "v1.x"
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "malformed version constraint"
  cmp "$USER_FILE" "$BATS_TEST_TMPDIR/before.json"
}

@test "missing required fields on add are reported by the validator and nothing is written" {
  entry add --layer user --name incomplete
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "missing field: category"
  assert_contains "$stderr" "missing field: rationale"
  [ ! -e "$USER_FILE" ]
}

@test "a failed write to a missing file creates neither the file nor its directory" {
  [ ! -d "$(dirname "$USER_FILE")" ]
  entry add --layer user --name bad --category nonsense --enforcement required --rationale r --install-text i
  [ "$status" -eq 4 ]
  [ ! -e "$USER_FILE" ]
  [ ! -d "$(dirname "$USER_FILE")" ]
}

@test "an existing invalid file is refused with the validator messages and left untouched" {
  mkdir -p "$(dirname "$USER_FILE")"
  printf '{"registry_version":1,"tools":[{"name":"x"}]}\n' > "$USER_FILE"
  cp "$USER_FILE" "$BATS_TEST_TMPDIR/before.json"
  add_basic user other
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "missing field: category"
  cmp "$USER_FILE" "$BATS_TEST_TMPDIR/before.json"
}

@test "an existing file that is not JSON is refused and left untouched" {
  mkdir -p "$(dirname "$USER_FILE")"
  printf '{"registry_version":1,\n' > "$USER_FILE"
  cp "$USER_FILE" "$BATS_TEST_TMPDIR/before.json"
  add_basic user other
  [ "$status" -eq 4 ]
  cmp "$USER_FILE" "$BATS_TEST_TMPDIR/before.json"
}

# --- descriptor links ---------------------------------------------------------

@test "bad descriptor link is rejected and the file is untouched" {
  add_basic user good
  cp "$USER_FILE" "$BATS_TEST_TMPDIR/before.json"
  entry add --layer user --name linked --category lint --enforcement required --rationale r --descriptor not-a-descriptor
  [ "$status" -eq 4 ]
  assert_contains "$stderr" 'install_hint.descriptor "not-a-descriptor" names no file'
  cmp "$USER_FILE" "$BATS_TEST_TMPDIR/before.json"
}

@test "a real descriptor link is accepted without any free-text hint" {
  entry add --layer user --name linked --category CI --enforcement required --rationale r --descriptor github
  [ "$status" -eq 0 ]
  [ "$(jq -c '.tools[0].install_hint' "$USER_FILE")" = '{"descriptor":"github"}' ]
}

@test "descriptors lists exactly the ids present on disk" {
  expected="$(find "$REPO_ROOT/skills/j-connect/descriptors" -maxdepth 1 -name '*.json' | sed -e 's|.*/||' -e 's|\.json$||' | LC_ALL=C sort)"
  [ -n "$expected" ]
  entry descriptors
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
  entry descriptors --format json
  [ "$status" -eq 0 ]
  [ "$(jq -r '. | join("\n")' <<<"$output")" = "$expected" ]
}

@test "descriptors honours JENGA_DESCRIPTORS_DIR, and an empty or absent directory lists nothing" {
  mkdir -p "$BATS_TEST_TMPDIR/desc"
  printf '{}\n' > "$BATS_TEST_TMPDIR/desc/zeta.json"
  printf '{}\n' > "$BATS_TEST_TMPDIR/desc/alpha.json"
  printf 'x\n' > "$BATS_TEST_TMPDIR/desc/README.md"
  JENGA_DESCRIPTORS_DIR="$BATS_TEST_TMPDIR/desc" entry descriptors
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'alpha\nzeta')" ]
  JENGA_DESCRIPTORS_DIR="$BATS_TEST_TMPDIR/none" entry descriptors --format json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "a descriptor id that exists only under JENGA_DESCRIPTORS_DIR validates against that directory" {
  mkdir -p "$BATS_TEST_TMPDIR/desc"
  printf '{}\n' > "$BATS_TEST_TMPDIR/desc/custom.json"
  JENGA_DESCRIPTORS_DIR="$BATS_TEST_TMPDIR/desc" entry add --layer user --name c --category lint \
    --enforcement required --rationale r --descriptor custom
  [ "$status" -eq 0 ]
}

# --- check --------------------------------------------------------------------

@test "check validates each input kind with the validator's own message" {
  entry check category lint
  [ "$(jq -r '.valid' <<<"$output")" = "true" ]
  entry check category nonsense
  [ "$(jq -r '.valid' <<<"$output")" = "false" ]
  assert_contains "$(jq -r '.reason' <<<"$output")" "allowed: runtime, testing, lint, CI, infra"
  [ "$(jq -r '.extendable' <<<"$output")" = "true" ]
  entry check category "9bad"
  [ "$(jq -r '.extendable' <<<"$output")" = "false" ]
  entry check enforcement required
  [ "$(jq -r '.valid' <<<"$output")" = "true" ]
  entry check enforcement mandatory
  [ "$(jq -r '.valid' <<<"$output")" = "false" ]
  entry check version ">=18 <22"
  [ "$(jq -r '.valid' <<<"$output")" = "true" ]
  entry check version "1.x"
  [ "$(jq -r '.valid' <<<"$output")" = "false" ]
  entry check descriptor github
  [ "$(jq -r '.valid' <<<"$output")" = "true" ]
  entry check descriptor nope
  [ "$(jq -r '.valid' <<<"$output")" = "false" ]
  [ "$status" -eq 0 ]
}

@test "check category honours the categories already declared in the layer file" {
  write_hand_file "$USER_FILE"
  entry check category docs --layer user
  [ "$(jq -r '.valid' <<<"$output")" = "true" ]
  entry check category docs --layer project
  [ "$(jq -r '.valid' <<<"$output")" = "false" ]
}

@test "check name reports an empty name and a name already in the layer" {
  write_hand_file "$USER_FILE"
  entry check name keep-a --layer user
  [ "$(jq -r '.valid' <<<"$output")" = "false" ]
  [ "$(jq -r '.exists' <<<"$output")" = "true" ]
  entry check name keep-a --layer project
  [ "$(jq -r '.valid' <<<"$output")" = "true" ]
  entry check name "" --layer user
  [ "$(jq -r '.valid' <<<"$output")" = "false" ]
  assert_contains "$(jq -r '.reason' <<<"$output")" "non-empty"
}

# --- show / path --------------------------------------------------------------

@test "path prints the layer file for each layer, and show prints an entry or the whole file" {
  entry path --layer user
  [ "$output" = "$USER_FILE" ]
  entry path --layer project
  [ "$output" = "$PROJECT_FILE" ]
  entry path --layer shipped
  [ "$output" = "$REPO_ROOT/skills/j-tools/assets/shipped-tools.json" ]
  write_hand_file "$USER_FILE"
  entry show --layer user --name keep-c
  [ "$status" -eq 0 ]
  [ "$(jq -r '.rationale' <<<"$output")" = "rc" ]
  entry show --layer user --name ghost
  [ "$status" -eq 1 ]
  entry show --layer project
  [ "$status" -eq 0 ]
  [ "$(jq -c '.tools' <<<"$output")" = "[]" ]
}

# --- usage and environment ----------------------------------------------------

@test "usage errors exit 2: no subcommand, unknown subcommand, bad layer, missing name, bad alternative" {
  entry
  [ "$status" -eq 2 ]
  entry frobnicate
  [ "$status" -eq 2 ]
  entry add --layer shipped --name x
  [ "$status" -eq 2 ]
  entry add --name x
  [ "$status" -eq 2 ]
  entry add --layer user
  [ "$status" -eq 2 ]
  entry add --layer user --name x --alternative "no-separator"
  [ "$status" -eq 2 ]
  entry add --layer user --name
  [ "$status" -eq 2 ]
  entry remove --layer user --name x stray
  [ "$status" -eq 2 ]
}

@test "--help prints usage and exits 0" {
  entry --help
  [ "$status" -eq 0 ]
  assert_contains "$stderr" "usage: tools-entry.sh"
}

@test "an unresolvable project root exits 5 and writes nothing" {
  export JENGA_PROJECT_ROOT="$BATS_TEST_TMPDIR/no-such-root"
  add_basic project x
  [ "$status" -eq 5 ]
  [ ! -e "$BATS_TEST_TMPDIR/no-such-root" ]
}

@test "runs under the system bash (3.2 on macOS) when it is available" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  run --separate-stderr /bin/bash "$ENTRY" add --layer user --name sysbash --category lint \
    --enforcement recommended --rationale r --install-text i
  [ "$status" -eq 0 ]
  valid_file "$USER_FILE"
  run --separate-stderr /bin/bash "$ENTRY" suppress --layer user --name something
  [ "$status" -eq 0 ]
}

@test "the package is not modified: the real project registry and the real HOME are untouched" {
  add_basic user a
  add_basic project b
  entry suppress --layer user --name c
  entry edit --layer user --name a --rationale changed
  entry remove --layer project --name b
  if [ -e "$REAL_PROJECT_FILE" ]; then
    [ "$(cksum < "$REAL_PROJECT_FILE")" = "$REAL_PROJECT_SUM" ]
  else
    [ "$REAL_PROJECT_SUM" = "absent" ]
    [ ! -e "$REAL_PROJECT_FILE" ]
  fi
  [ ! -e "$HOME/.jenga" ]
}
