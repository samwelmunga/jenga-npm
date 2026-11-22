#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# The sync-time merge of required checklist ids into an existing project instance (E99_S04_T05).
#
# Decision E99_S04_T02 (option 3): scripts/checklist.sh reads the project instance (<configs>/checklists.json) whole
# when it exists, so an instance that predates the ids a shipped script hard-requires (templates/
# checklist-required-ids.json) keeps failing that script; foreground-preflight.sh exits 12. postinstall and
# `jenga sync` (lib/sync.js, step 7) run scripts/checklist-required-merge.sh, which adds ONLY those ids, copied from
# the shipped default, and changes no other byte of the instance.
#
# What is pinned here
#   1. the script: both ids added / one id added; every other item and top-level key unchanged in content and order
#      (and the original bytes kept as a prefix and suffix); an id the instance already holds keeps its own fields;
#      a non-required shipped item the project removed stays removed; no instance creates nothing; --dry-run prints
#      "would add" and writes nothing; a second run prints and writes nothing; an invalid instance, malformed JSON,
#      a shipped default lacking a required id, a candidate that fails validation and a held lock each leave the
#      instance byte-identical and exit non-zero; a configs directory whose physical path leaves the consumer root
#      (".." in paths.configs, or a symlinked directory) is refused with exit 1 and nothing is written outside; a
#      configs symlink to a directory inside the root is allowed; a symlinked checklists.json is never followed; a
#      configs path the OS cannot resolve ("missing/../link", "link" an outside symlink) holds no instance: exit 0,
#      nothing written
#   2. lib/sync.js: `jenga sync` adds the ids and reports them, --dry-run lists them, a failure is recorded without
#      aborting later steps, and after a sync foreground-preflight.sh gate no longer exits 12
#
# Fixtures live only under $BATS_TEST_TMPDIR: a fixture package (templates/ only) for the script cases, and for the
# sync cases a private copy of the package's shipped directories, never this repository's own .claude/, .agents/ or
# project/configs/checklists.json. Every script call has stdin from /dev/null.

load helpers/assertions

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
MERGE="$REPO_ROOT/scripts/checklist-required-merge.sh"
CHECKIN_ID="checkin-run-before-dispatch"
COST_ID="dispatch-cost-and-cadence"

setup() {
  # Nothing may point the resolver, the registry or the tick store at another project (inside a Claude Code session
  # CLAUDE_PROJECT_DIR names this repository).
  unset JENGA_PROJECT_ROOT JENGA_PROJECT_DIR CLAUDE_PROJECT_DIR JENGA_CHECKLISTS_FILE JENGA_CHECKLISTS_DEFAULT_FILE
  unset JENGA_CHECKLIST_STATE_DIR JENGA_CHECKLIST_MARKER_DIR JENGA_CHECKLIST_SESSION_ID JENGA_SESSION_ID
  unset JENGA_CHECKLIST_RUN_ID JENGA_CHECKLIST_ACTOR JENGA_RESOLVE_STRICT
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"

  PKGT="$BATS_TEST_TMPDIR/pkg-templates"
  mkdir -p "$PKGT/templates"
  cp "$REPO_ROOT/templates/checklists.json" "$REPO_ROOT/templates/checklist-required-ids.json" "$PKGT/templates/"

  C="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$C/project/configs"
  INST="$C/project/configs/checklists.json"
}

# make_instance <drop-id>...: an instance seeded from the shipped default without the named ids, with one authored
# item and one extra top-level key appended, written in a different style (indent 2, arrays expanded) from the
# shipped file so the copied text has to be re-indented.
make_instance() {
  python3 - "$PKGT/templates/checklists.json" "$INST" "$@" <<'PY'
import json, sys
src, dst, drop = sys.argv[1], sys.argv[2], set(sys.argv[3:])
d = json.load(open(src))
d["items"] = [i for i in d["items"] if i["id"] not in drop]
d["items"].append({"id": "my-own-item", "text": "An item this project wrote.", "situations": ["pre-commit"],
                   "kind": "judgment", "enforcement": "advisory", "tick_scope": "run",
                   "provenance": {"source": "authored"}})
d["x_project_note"] = {"kept": True}
with open(dst, "w") as h:
    json.dump(d, h, indent=2)
    h.write("\n")
PY
  cp "$INST" "$BATS_TEST_TMPDIR/orig.json"
}

merge() { bash "$MERGE" --consumer-root "$C" --package-root "$PKGT" "$@" < /dev/null; }

unchanged() { cmp -s "$BATS_TEST_TMPDIR/orig.json" "$INST"; }

ids_of() { jq -r '.items[].id' "$1"; }

# preserved <n-added>: the original items and top-level keys are unchanged in content and order, the original bytes
# survive as a prefix (up to the end of the last original item) and a suffix, and exactly <n-added> items follow.
preserved() {
  python3 - "$BATS_TEST_TMPDIR/orig.json" "$INST" "$1" <<'PY'
import json, sys
o_text, n_text = open(sys.argv[1]).read(), open(sys.argv[2]).read()
o, n, k = json.loads(o_text), json.loads(n_text), int(sys.argv[3])
assert list(n.keys()) == list(o.keys()), "top-level key order"
assert all(n[x] == o[x] for x in o if x != "items"), "top-level values"
assert n["items"][:len(o["items"])] == o["items"], "existing items"
assert len(n["items"]) == len(o["items"]) + k, "added count"
cut = o_text.rindex("}", 0, o_text.rindex("]")) + 1
assert n_text.startswith(o_text[:cut]), "prefix bytes"
assert n_text.endswith(o_text[cut:]), "suffix bytes"
PY
}

shipped_item() { jq -c --arg id "$1" '.items[] | select(.id == $id)' "$PKGT/templates/checklists.json"; }
inst_item() { jq -c --arg id "$1" '.items[] | select(.id == $id)' "$INST"; }

# -- the script -----------------------------------------------------------------------------------------------------

@test "--help prints the usage and the exit codes" {
  run bash "$MERGE" --help < /dev/null
  [ "$status" -eq 0 ]
  assert_output_contains "--consumer-root"
  assert_output_contains "Exit codes:"
  run bash "$MERGE" --bogus < /dev/null
  [ "$status" -eq 2 ]
}

@test "an instance missing both required ids gets both, copied from the shipped default, and nothing else changes" {
  make_instance "$CHECKIN_ID" "$COST_ID"
  run --separate-stderr merge
  echo "status=$status out=$output err=$stderr"
  [ "$status" -eq 0 ]
  [ "$output" = "added $CHECKIN_ID
added $COST_ID" ]
  preserved 2
  [ "$(ids_of "$INST" | tail -2 | tr '\n' ' ')" = "$CHECKIN_ID $COST_ID " ]
  [ "$(inst_item "$CHECKIN_ID")" = "$(shipped_item "$CHECKIN_ID")" ]
  [ "$(inst_item "$COST_ID")" = "$(shipped_item "$COST_ID")" ]
  # No provenance is invented for a copied item.
  [ "$(jq --arg id "$COST_ID" '.items[] | select(.id == $id) | has("provenance")' "$INST")" = "false" ]
  run bash "$REPO_ROOT/scripts/validate-checklists.sh" "$INST" < /dev/null
  [ "$status" -eq 0 ]
  # No candidate or lock is left behind.
  [ "$(ls -A "$C/project/configs")" = "checklists.json" ]
}

@test "an instance missing one id gets only that one; an id it holds with different fields keeps its own version" {
  make_instance "$COST_ID"
  # The project's own version of the check-in item, as this repository's instance has (monorepo-relative verify).
  python3 - "$INST" "$CHECKIN_ID" <<'PY'
import json, sys
p, cid = sys.argv[1], sys.argv[2]
d = json.load(open(p))
for i in d["items"]:
    if i["id"] == cid:
        i["verify"] = "bash skills/j-check-in/scripts/checkin-gate.sh"
json.dump(d, open(p, "w"), indent=2)
open(p, "a").write("\n")
PY
  cp "$INST" "$BATS_TEST_TMPDIR/orig.json"
  local own
  own="$(inst_item "$CHECKIN_ID")"
  run --separate-stderr merge
  [ "$status" -eq 0 ]
  [ "$output" = "added $COST_ID" ]
  preserved 1
  [ "$(inst_item "$CHECKIN_ID")" = "$own" ]
  [ "$(jq -r --arg id "$CHECKIN_ID" '.items[] | select(.id == $id) | .verify' "$INST")" = "bash skills/j-check-in/scripts/checkin-gate.sh" ]
  [ "$(ids_of "$INST" | grep -c "^$CHECKIN_ID\$")" -eq 1 ]
}

@test "a shipped item the project removed that is not required stays removed" {
  make_instance "$CHECKIN_ID" "$COST_ID" no-env-files-staged no-conflict-markers-staged
  # Precondition: both are shipped and not declared required.
  [ -n "$(shipped_item no-env-files-staged)" ]
  [ -z "$(jq -r '.required[].id' "$PKGT/templates/checklist-required-ids.json" | grep -x no-env-files-staged)" ]
  run --separate-stderr merge
  [ "$status" -eq 0 ]
  [ -z "$(inst_item no-env-files-staged)" ]
  [ -z "$(inst_item no-conflict-markers-staged)" ]
  preserved 2
}

@test "no instance: nothing is created, nothing printed" {
  local before
  before="$(find "$C" | LC_ALL=C sort)"
  run --separate-stderr merge
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$INST" ]
  [ "$(find "$C" | LC_ALL=C sort)" = "$before" ]
  # Not even the configs directory, when the project has none.
  local bare="$BATS_TEST_TMPDIR/bare"
  mkdir -p "$bare"
  run --separate-stderr bash "$MERGE" --consumer-root "$bare" --package-root "$PKGT" < /dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$(ls -A "$bare")" ]
}

@test "--dry-run prints would add lines and writes nothing" {
  make_instance "$CHECKIN_ID" "$COST_ID"
  run --separate-stderr merge --dry-run
  [ "$status" -eq 0 ]
  [ "$output" = "would add $CHECKIN_ID
would add $COST_ID" ]
  unchanged
  [ "$(ls -A "$C/project/configs")" = "checklists.json" ]
}

@test "a second run is a no-op: no output, instance byte-identical" {
  make_instance "$CHECKIN_ID" "$COST_ID"
  run merge
  [ "$status" -eq 0 ]
  cp "$INST" "$BATS_TEST_TMPDIR/orig.json"
  run --separate-stderr merge
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  unchanged
  run --separate-stderr merge --dry-run
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an empty items array gets the ids and stays valid" {
  printf '{\n  "checklist_version": 1,\n  "items": []\n}\n' > "$INST"
  run --separate-stderr merge
  [ "$status" -eq 0 ]
  [ "$(ids_of "$INST" | tr '\n' ' ')" = "$CHECKIN_ID $COST_ID " ]
  run bash "$REPO_ROOT/scripts/validate-checklists.sh" "$INST" < /dev/null
  [ "$status" -eq 0 ]
}

@test "malformed JSON in the instance: left untouched, exit 4, no leftover files" {
  printf '{ "checklist_version": 1, "items": [ {"id": "x",, } ' > "$INST"
  cp "$INST" "$BATS_TEST_TMPDIR/orig.json"
  run --separate-stderr merge
  echo "status=$status err=$stderr"
  [ "$status" -eq 4 ]
  unchanged
  [ "$(ls -A "$C/project/configs")" = "checklists.json" ]
}

@test "a schema-invalid instance: left untouched, exit 4" {
  make_instance "$CHECKIN_ID" "$COST_ID"
  jq '.items[0].enforcement = "sometimes"' "$INST" > "$TMPDIR/bad.json"
  cp "$TMPDIR/bad.json" "$INST"
  cp "$INST" "$BATS_TEST_TMPDIR/orig.json"
  run --separate-stderr merge
  [ "$status" -eq 4 ]
  unchanged
}

@test "a shipped default lacking a required id (packaging regression): instance untouched, exit 3" {
  make_instance "$CHECKIN_ID" "$COST_ID"
  jq --arg id "$COST_ID" '.items |= map(select(.id != $id))' "$PKGT/templates/checklists.json" > "$TMPDIR/s.json"
  cp "$TMPDIR/s.json" "$PKGT/templates/checklists.json"
  run --separate-stderr merge
  echo "err=$stderr"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"$COST_ID"* ]]
  unchanged
}

@test "a candidate that fails validate-checklists.sh is discarded: instance untouched, exit 5, no leftover files" {
  make_instance "$CHECKIN_ID" "$COST_ID"
  # The instance declares no extension situations; a shipped required item that uses one cannot validate there.
  # Every instance item that itself uses an extension situation (the shipped default carries some, e.g. a
  # pre-publish item) is dropped too, so the instance validates and only the candidate fails.
  jq 'del(.situations)
      | .items |= map(select(((.situations // []) - ["pre-commit","pre-task","pre-release","pre-reconcile"]) | length == 0))' \
    "$INST" > "$TMPDIR/i.json"
  cp "$TMPDIR/i.json" "$INST"
  cp "$INST" "$BATS_TEST_TMPDIR/orig.json"
  run bash "$REPO_ROOT/scripts/validate-checklists.sh" "$INST" < /dev/null
  echo "pre-validation status=$status output=$output"
  [ "$status" -eq 0 ]
  jq --arg id "$COST_ID" '(.items[] | select(.id == $id) | .situations) = ["pre-publish"]' \
    "$PKGT/templates/checklists.json" > "$TMPDIR/s.json"
  cp "$TMPDIR/s.json" "$PKGT/templates/checklists.json"
  run --separate-stderr merge
  echo "status=$status err=$stderr"
  [ "$status" -eq 5 ]
  unchanged
  [ "$(ls -A "$C/project/configs")" = "checklists.json" ]
}

@test "the write runs under with-lock.sh: a held lock means exit 6 and an untouched instance" {
  make_instance "$CHECKIN_ID" "$COST_ID"
  mkdir "$INST.lock.d"
  echo "$$" > "$INST.lock.d/pid"
  WITH_LOCK_TIMEOUT_SECONDS=1 run --separate-stderr merge
  echo "status=$status err=$stderr"
  [ "$status" -eq 6 ]
  unchanged
}

# tree_state <dir>: every path under <dir> and the checksum of every file, so "nothing was written" is checkable.
tree_state() { ( cd "$1" && find . | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort ); }

@test "paths.configs \"../escape\" resolves outside the consumer root: exit 1, nothing written outside" {
  make_instance "$CHECKIN_ID" "$COST_ID"
  local out="$BATS_TEST_TMPDIR/escape"
  mkdir -p "$out"
  mv "$INST" "$out/checklists.json"
  printf '{"paths":{"configs":"../escape"}}\n' > "$C/project/configs/workflow.json"
  local before_out before_c
  before_out="$(tree_state "$out")"; before_c="$(tree_state "$C")"
  run --separate-stderr merge
  echo "status=$status out=$output err=$stderr"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"outside the consumer root"* ]]
  [ "$(tree_state "$out")" = "$before_out" ]
  [ "$(tree_state "$C")" = "$before_c" ]
  run --separate-stderr merge --dry-run
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "a project/configs symlink to a directory outside the consumer root: exit 1, nothing written outside" {
  make_instance "$CHECKIN_ID" "$COST_ID"
  local out="$BATS_TEST_TMPDIR/outside-configs"
  mkdir -p "$out"
  mv "$INST" "$out/checklists.json"
  printf '{}\n' > "$out/workflow.json"
  rmdir "$C/project/configs"
  ln -s "$out" "$C/project/configs"
  local before_out before_c
  before_out="$(tree_state "$out")"; before_c="$(tree_state "$C")"
  run --separate-stderr merge
  echo "status=$status out=$output err=$stderr"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"outside the consumer root"* ]]
  [ "$(tree_state "$out")" = "$before_out" ]
  [ "$(tree_state "$C")" = "$before_c" ]
  [ -L "$C/project/configs" ]
}

@test "a project/configs symlink to a directory inside the consumer root is allowed: the ids land in the real file" {
  make_instance "$CHECKIN_ID" "$COST_ID"
  local real="$C/shared-configs"
  mkdir -p "$real"
  mv "$INST" "$real/checklists.json"
  printf '{}\n' > "$real/workflow.json"
  rmdir "$C/project/configs"
  ln -s ../shared-configs "$C/project/configs"
  run --separate-stderr merge
  echo "status=$status out=$output err=$stderr"
  [ "$status" -eq 0 ]
  [ "$output" = "added $CHECKIN_ID
added $COST_ID" ]
  [ -L "$C/project/configs" ]
  [ -f "$real/checklists.json" ]
  [ ! -L "$real/checklists.json" ]
  preserved 2
  [ "$(ls -A "$real" | LC_ALL=C sort | tr '\n' ' ')" = "checklists.json workflow.json " ]
}

@test "a checklists.json that is itself a symlink is never followed: exit 4, target untouched" {
  make_instance "$CHECKIN_ID" "$COST_ID"
  local target="$C/elsewhere.json"
  mv "$INST" "$target"
  ln -s ../../elsewhere.json "$INST"
  run --separate-stderr merge
  echo "status=$status err=$stderr"
  [ "$status" -eq 4 ]
  [ -L "$INST" ]
  cmp -s "$BATS_TEST_TMPDIR/orig.json" "$target"
}

# missing_then_link <paths.configs>: <consumer>/link is a symlink to an outside directory that holds an instance
# lacking both ids, and paths.configs names a missing component followed by ".." and then "link". The operating
# system cannot resolve that path (it fails on the missing component), so it holds no instance: exit 0, nothing
# printed, nothing written outside or inside. A text-normalised tail would drop "missing/.." and write the outside file.
missing_then_link() {
  make_instance "$CHECKIN_ID" "$COST_ID"
  local out="$BATS_TEST_TMPDIR/outside-link-target"
  mkdir -p "$out"
  mv "$INST" "$out/checklists.json"
  ln -s "$out" "$C/link"
  printf '{"paths":{"configs":"%s"}}\n' "$1" > "$C/project/configs/workflow.json"
  [ ! -e "$C/$1" ]   # the OS itself cannot resolve the configs path
  [ -f "$C/link/checklists.json" ]   # while the link alone does reach the outside instance
  local before_out before_c sum_before
  before_out="$(tree_state "$out")"; before_c="$(tree_state "$C")"; sum_before="$(cksum < "$out/checklists.json")"
  run --separate-stderr merge
  echo "status=$status out=$output err=$stderr"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cksum < "$out/checklists.json")" = "$sum_before" ]
  cmp -s "$BATS_TEST_TMPDIR/orig.json" "$out/checklists.json"
  [ "$(tree_state "$out")" = "$before_out" ]
  [ "$(tree_state "$C")" = "$before_c" ]
  run --separate-stderr merge --dry-run
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(tree_state "$out")" = "$before_out" ]
}

@test "paths.configs \"missing/../link\" with an outside link: the OS cannot resolve it, exit 0, nothing written" {
  missing_then_link "missing/../link"
}

@test "paths.configs \"project/missing/../../link\" with an outside link: the OS cannot resolve it, exit 0, nothing written" {
  missing_then_link "project/missing/../../link"
}

# -- lib/sync.js (jenga sync and postinstall share syncConsumer) -----------------------------------------------------

# make_package: a private copy of what the installed package carries (a real sync rewrites lib/skill-allow-list.json
# inside it), under $BATS_TEST_TMPDIR.
make_package() {
  PKG="$BATS_TEST_TMPDIR/pkg"
  mkdir -p "$PKG"
  local d
  for d in lib scripts templates skills agents hooks bin; do
    cp -R "$REPO_ROOT/$d" "$PKG/$d"
  done
  cp "$REPO_ROOT/package.json" "$PKG/package.json"
  PKGT="$PKG"
}

jenga() { ( cd "$C" && node "$PKG/bin/jenga.js" "$@" < /dev/null ); }

@test "jenga sync adds the missing required ids, reports them, and a second sync leaves the instance alone" {
  make_package
  make_instance "$CHECKIN_ID" "$COST_ID"
  run jenga sync
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "required item(s) added: $CHECKIN_ID, $COST_ID"
  preserved 2
  cp "$INST" "$BATS_TEST_TMPDIR/orig.json"
  run jenga sync
  [ "$status" -eq 0 ]
  assert_output_not_contains "required item(s)"
  assert_output_contains "Nothing changed"
  unchanged
}

@test "jenga sync --dry-run lists the instance as a pending change and writes nothing to it" {
  make_package
  make_instance "$CHECKIN_ID" "$COST_ID"
  run jenga sync --dry-run
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "would add required checklist ids to  project/configs/checklists.json"
  unchanged
}

@test "jenga sync records a merge failure without aborting the later steps" {
  make_package
  printf '{ not json' > "$INST"
  cp "$INST" "$BATS_TEST_TMPDIR/orig.json"
  run jenga sync
  echo "$output"
  [ "$status" -eq 1 ]
  assert_output_contains "Could not add the required checklist ids"
  assert_output_contains "checklist-required: merge failed (exit 4)"
  unchanged
  # Step 8 still ran.
  [ -f "$C/.jenga-version" ]
}

@test "after jenga sync, foreground-preflight.sh gate no longer exits 12 in the consumer" {
  make_package
  make_instance "$CHECKIN_ID" "$COST_ID"
  mkdir -p "$C/project/logs"
  : > "$C/project/logs/events.json"
  export CLAUDE_CODE_SESSION_ID="sess-e99s04t05"
  local key run_id
  key="$(cd "$C" && bash "$PKG/scripts/checklist-marker.sh" session-key < /dev/null)"
  [ -n "$key" ]
  printf '{"event": "checkin", "agent": "orchestrator", "session_key": "%s", "date": "2026-11-21T14:00:00Z"}\n' \
    "$key" >> "$C/project/logs/events.json"

  # Control: the instance lacks both ids, so the gate fails to record its tick.
  run_id="$(bash "$PKG/scripts/foreground-preflight.sh" mint < /dev/null)"
  run --separate-stderr bash -c 'cd "$1" && bash "$2" gate --run "$3" --via do --user-yes < /dev/null' _ \
    "$C" "$PKG/scripts/foreground-preflight.sh" "$run_id"
  echo "control status=$status err=$stderr"
  [ "$status" -eq 12 ]

  run jenga sync
  [ "$status" -eq 0 ]

  run_id="$(bash "$PKG/scripts/foreground-preflight.sh" mint < /dev/null)"
  run --separate-stderr bash -c 'cd "$1" && bash "$2" gate --run "$3" --via do --user-yes < /dev/null' _ \
    "$C" "$PKG/scripts/foreground-preflight.sh" "$run_id"
  echo "after sync status=$status err=$stderr"
  [ "$status" -ne 12 ]
  [ "$status" -eq 0 ]
}
