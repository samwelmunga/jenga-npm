#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# E92_S08_T02: the shared graph-structure module lib/progress/dependency-structure.js and the Node-14 rule for lib/progress/.
#
# 1. The dashboard model must stay deep-equal to what it was before the split. The parity test
#    (project/app/ui/scripts/dependency-structure-parity.test.cjs) compares the split code with outputs recorded from the
#    single-file model (tests/fixtures/progress/dependency-tree-parity.json); this file runs it so `j.test` discovers it.
# 2. Everything under lib/progress/ ships to consumers on Node >= 14.13.1 (package.json engines), so none of it may use an
#    API newer than that. The scan strips comments first, so prose may name the APIs; the controls plant each banned name
#    and prove the scan can fail. Raising `engines` is a separate, user-approved change.
# 3. E92_S09_T01 (user request 2026-11-15): the shared module builds the tree for every epic with at least one task, with
#    or without dependency edges, and returns the empty structure only for an epic with zero tasks.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
PARITY="$REPO_ROOT/project/app/ui/scripts/dependency-structure-parity.test.cjs"
PROGRESS_LIB="$REPO_ROOT/lib/progress"

# Banned API names, "label<TAB>extended regex", one per entry.
BANNED=(
  $'replaceAll\t\\.replaceAll\\b'
  $'Array at\t\\.at[[:space:]]*\\('
  $'logical assignment\t(\\?\\?|\\|\\||&&)='
  $'Object.hasOwn\t\\bObject\\.hasOwn\\b'
  $'structuredClone\t\\bstructuredClone\\b'
  $'node:test\tnode:test'
  $'fetch\t(^|[^[:alnum:]_$])fetch[[:space:]]*\\('
)

# strip_comments <file>: the file without block comments and whole-line // comments.
strip_comments() {
  perl -0777 -pe 's{/\*.*?\*/}{}gs; s{^[ \t]*//.*$}{}gm' "$1"
}

# scan_dir <dir>: prints "<file>: <label>" per hit and returns 1 when there is any.
scan_dir() {
  local dir="$1" f entry label re hits=0
  while IFS= read -r f; do
    for entry in "${BANNED[@]}"; do
      label="${entry%%$'\t'*}"
      re="${entry#*$'\t'}"
      if strip_comments "$f" | grep -Eq -- "$re"; then
        echo "${f#"$REPO_ROOT"/}: $label"
        hits=1
      fi
    done
  done < <(find "$dir" -type f \( -name '*.js' -o -name '*.cjs' -o -name '*.mjs' \) | sort)
  return "$hits"
}

@test "parity: the dashboard tree model is deep-equal to the recorded pre-split output" {
  command -v node >/dev/null 2>&1 || skip "node is not installed"
  [ -f "$REPO_ROOT/project/app/ui/src/components/progress/dependencyTreeModel.js" ] || skip "the dashboard sources are not part of this tree"
  run node "$PARITY"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"tests passed"* ]]
}

@test "node 14: lib/progress/ uses no API newer than Node 14.13.1" {
  [ -d "$PROGRESS_LIB" ]
  run scan_dir "$PROGRESS_LIB"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "node 14: the shared structure module exists and is scanned" {
  [ -f "$PROGRESS_LIB/dependency-structure.js" ]
  run find "$PROGRESS_LIB" -type f -name '*.js'
  [[ "$output" == *"dependency-structure.js"* ]]
}

@test "node 14 control: each banned API planted in a scratch file is reported" {
  mkdir -p "$BATS_TEST_TMPDIR/ctl"
  local plants=(
    "const a = 'x'.replaceAll('a', 'b')"
    "const b = [1].at(-1)"
    "let c; c ??= 1"
    "let d; d ||= 1"
    "let e; e &&= 1"
    "const f = Object.hasOwn({}, 'k')"
    "const g = structuredClone({})"
    "import t from 'node:test'"
    "const h = fetch('http://localhost')"
    "const i = await fetch ('http://localhost')"
  )
  local p
  for p in "${plants[@]}"; do
    rm -f "$BATS_TEST_TMPDIR/ctl"/*.js
    printf '%s\n' "$p" > "$BATS_TEST_TMPDIR/ctl/planted.js"
    run scan_dir "$BATS_TEST_TMPDIR/ctl"
    [ "$status" -ne 0 ] || { echo "not reported: $p"; false; }
  done
}

@test "node 14 control: names inside comments and ordinary words are not reported" {
  mkdir -p "$BATS_TEST_TMPDIR/ok"
  cat > "$BATS_TEST_TMPDIR/ok/clean.js" <<'JS'
/** no replaceAll, no .at( and no ??= here, nor Object.hasOwn, structuredClone, node:test or fetch( */
// fetch( replaceAll .at( ??=
const prefetched = 1 // a trailing comment is kept, but this line has no banned call
const atom = [1, 2].map(x => x ?? 0)
const when = 'a'.replace(/a/g, 'b')
JS
  run scan_dir "$BATS_TEST_TMPDIR/ok"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "E92_S09_T01: an epic with tasks but no dependency edge gets its tree; only an epic with zero tasks is empty" {
  command -v node >/dev/null 2>&1 || skip "node is not installed"
  run node --input-type=module -e '
    import { pathToFileURL } from "url";
    const { buildDependencyStructure } = await import(pathToFileURL(process.argv[1]).href);
    const T = (id, sid, state) => ({ id, story_id: sid, epic_id: "E05", title: id, status: "Pending", bucket: state === "done" ? "done" : "pending", state, depends_on: [], unlocked_by: null });
    // E92_S09_T04: the goal reads the epic percent the script states (epic_progress); the fixture states it for 1 of 3 done.
    const graph = { epics: [{ id: "E05", title: "Edge-free", epic_progress: { stories: 2, decomposed: 2, tasks_done: 1, tasks_denominator: 3, percent: 33, goal_reached: false } }], stories: [{ id: "E05_S01", title: "One" }, { id: "E05_S02", title: "Two" }],
      tasks: [T("E05_S01_T01", "E05_S01", "done"), T("E05_S01_T02", "E05_S01", "ready"), T("E05_S02_T01", "E05_S02", "ready")] };
    const s = buildDependencyStructure(graph, "E05", {});
    const z = buildDependencyStructure({ ...graph, tasks: [] }, "E05", {});
    console.log(JSON.stringify({
      empty: s.empty, columns: s.columns, bands: s.bands.map((b) => b.start.id),
      cells: s.tasks.map((t) => t.column + ":" + t.gate).join(","),
      kinds: [...new Set(s.edges.map((e) => e.kind))].sort().join(","), goal: [s.goal.id, s.goal.done, s.goal.total],
      zeroEmpty: z.empty, zeroBands: z.bands.length,
    }));
  ' "$PROGRESS_LIB/dependency-structure.js"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = '{"empty":false,"columns":1,"bands":["story:E05_S01","story:E05_S02"],"cells":"0:none,0:none,0:none","kinds":"goal,start","goal":["E05",1,3],"zeroEmpty":true,"zeroBands":0}' ]
}
