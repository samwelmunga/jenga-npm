# Test-to-Architecture Linking Spike (E83_S01)

Spike document for story `E83_S01`. This file is written in two parts: **Findings** (task `E83_S01_T01`) and
**Decision** (task `E83_S01_T02`, starting at "Decision" below). Findings record facts only; every count is followed
by the command that produced it. The Findings commands were run from the repository root on 2026-10-25 against
`main` at `30372d0ff`. The Decision part re-checked the counts that matter on the session integration branch
(`jenga/e76-e78-e83-e86`) on 2026-10-26; where a number differs from Findings the difference is stated (for example
`ls tests/*.bats | wc -l` now prints 214, not 189, because other epics have added bats files since; no finding
depends on the exact count).

## Findings

### 1. Test shapes

| Shape | Count | Command |
|---|---|---|
| `tests/*.bats` files | 189 | `ls tests/*.bats \| wc -l` |
| `@test` blocks inside them | 3860 | `grep -c '^@test' tests/*.bats \| awk -F: '{s+=$2} END{print s}'` |
| bats files with zero `@test` | 0 | `grep -c '^@test' tests/*.bats \| awk -F: '$2==0' \| wc -l` |
| Plain-Node tests in `project/app/api/parsers/*.test.js` | 7 | `ls project/app/api/parsers/*.test.js \| wc -l` |
| Plain-Node test in `project/app/api/parsers/lib/` | 1 | `ls project/app/api/parsers/lib/*.test.js \| wc -l` |
| Plain-Node test in `project/app/api/lib/*.test.js` | 1 | `ls project/app/api/lib/*.test.js \| wc -l` |
| Plain-Node (ESM) tests in `scripts/*.test.js` | 2 | `ls scripts/*.test.js \| wc -l` |
| Any `*.test.js`/`*.spec.js` outside `node_modules` and dot-directories | 11 | `find . \( -name node_modules -o -name .git -o -name fixtures \) -prune -o \( -name '*.test.js' -o -name '*.test.jsx' -o -name '*.spec.js' \) -print \| grep -v '^\./\.' \| wc -l` |
| `*.bats` files outside `tests/` (fixtures excluded) | 0 | `find . \( -name node_modules -o -name .git -o -name fixtures \) -prune -o -name '*.bats' -print \| grep -v '^\./tests/[^/]*\.bats$' \| grep -v '^\./\.'` (empty output) |
| `test_*.py`, `*_test.go`, `*.test.sh`, `*-test.sh` | 0 | same `find`, with those name patterns (empty output) |

The epic and story text say 191 bats files; the live count is **189** (the story figure was stale when written).

There are therefore **two real shapes** (bats, plain Node) plus a sub-variant of plain Node:

- **bats (`tests/*.bats`).** Unit of identity is the `@test "title"` line (3860 titles, e.g.
  `@test "REPO_ROOT resolves correctly from the script's real source location (skills/j-todo/scripts/)" {`).
  A `#` comment can be placed anywhere at file scope and directly above any `@test` line; the file header comment is
  already conventional (`grep -l '^# ' tests/*.bats \| wc -l` gives 189, all of them). Stable per-test name: **yes**,
  the `@test` title. Bats 1.14.0 is installed (`bats --version`) and supports `# bats test_tags=...` annotations, but
  the repo uses none today (`grep -n 'bats test_tags' tests/*.bats` returns nothing).
- **Plain Node, CommonJS, hand-rolled `test(name, fn)` helper** (`knowledge-graph.test.js`: 18 calls,
  `documentation.test.js`: 6, `rapports.test.js`: 6, `board.external-refs.test.js`: 6, `resolve-project-root.test.js`: 9;
  count per file with `grep -cE '^\s*test\(' <file>`). A `/** @file ... */` JSDoc header comment exists in every file
  and a `//` comment can sit above any `test(` call. Stable per-test name: **yes**, the first string argument of `test()`.
- **Plain Node with no named tests** (`ideas.test.js`, `security.test.js`, `todo.test.js`: `grep -cE '^\s*test\(' <file>`
  gives 0 for each). These are straight-line `assert` sequences (`ideas.test.js` is one async IIFE; `security.test.js`
  and `todo.test.js` use local helper functions, not a registered test name). Comments can be placed anywhere, but there is
  **no stable per-test name**; the file is the only stable unit.
- **Plain Node, ESM** (`scripts/populate-knowledge-graph.*.test.js`, `import assert from 'node:assert'`, a local
  `test(name, fn)` registrar: 14 and 11 calls). Same comment and naming situation as the CommonJS helper shape.

`describe`/`it` is **not used anywhere** in the repo (`grep -c '\bdescribe(' <each file>` is 0 for all 11 Node files; `it(` likewise).
No test runner (jest, mocha, vitest) is configured; the Node files run directly with `node <file>`.

How the Node files are reached: `project/app/api/package.json` line 9 chains nine files with `&&`
(`node parsers/knowledge-graph.test.js && node lib/resolve-project-root.test.js && ... && node parsers/security.test.js`;
command: `grep -n '"test' project/app/api/package.json`). The two `scripts/*.test.js` files are **in no chain and in no
`package.json` script**: they are run only by hand (`node scripts/populate-knowledge-graph.staleness.test.js`, per their own header).

`discover-tests.sh` output (command: `bash skills/j-test/scripts/discover-tests.sh --root . > /tmp/e83_discover.txt`;
this run took 0.36 s wall-clock, not the 25-35 s the task estimated, so no timing concern applies) reports **5 suites,
2 warnings** (`jq '.suites\|length' /tmp/e83_discover.txt`):

| id | type | ecosystem | paths |
|---|---|---|---|
| `bats:tests` | unit | bats | `tests/*.bats` |
| `config:bats:integration` | integration | config | `tests/*.bats` |
| `config:scripts/audit-deps.sh:vulnerability` | vulnerability | config | none |
| `npm:test` | unit | npm | none (opaque) |
| `shellcheck:all` | sast | shellcheck | none |

(`jq -r '.suites[]\|"\(.id) \(.type) paths=\(.paths\|length)"' /tmp/e83_discover.txt`.) The discoverer only reads the
**root** `package.json` (`grep -n '"test' package.json` gives `"test": "bats tests/*.bats"`); the nine-file Node chain in
`project/app/api/package.json` and the two `scripts/*.test.js` files are **not discovered at all**. So both bats-wrapping
suites cover the same 189 files twice, and every plain-Node test file (11 of them) is invisible to `discover-tests.sh`.

### 2. Test type source

- **Vocabulary** (header comment of `skills/j-test/scripts/discover-tests.sh`, line 28): `unit | integration | e2e | sast | vulnerability | performance | coverage | unknown`.
  The task's shorter list (`unit`, `integration`, `e2e`, `coverage`, `unknown`) is the npm-suffix subset; `sast`,
  `vulnerability`, `performance` come from the overlay and linters.
- **Where a type is assigned** (`grep -n 'type' skills/j-test/scripts/discover-tests.sh`): (a) npm detector, lines 300-302:
  bare `test` is `unit`, suffixes `unit|integration|e2e|coverage` map to themselves, any other `test:<x>` is `unknown`;
  (b) the bats detector hard-codes `unit`; (c) shellcheck is `sast`; (d) the `project/configs/test-config.json` overlay
  (lines 514-553) retypes a detected suite or adds a `config:<tool>:<type>` suite. The repo's overlay lists bats as both
  `unit` and `integration`, which is why one bats directory yields two suites (`jq '.tools[]\|"\(.tool_name) \(.type)"' project/configs/test-config.json`).
- **Granularity:** per **suite**, never per file and never per test. A suite's `paths` is a glob (`tests/*.bats`) that
  both the `unit` and `integration` suites share, so no individual bats file or `@test` is "unit" or "integration"
  according to this source. The same 189 files are simultaneously both.
- **Counts today:** `jq -r '.suites\|group_by(.type)\|map("\(.[0].type)=\(length)")\|join(" ")' /tmp/e83_discover.txt` gives
  `integration=1 sast=1 unit=2 vulnerability=1`; `jq '[.suites[]\|select(.type=="unknown")]\|length' /tmp/e83_discover.txt` gives `0`.
- **Which shapes end up `unknown`:** none are reported `unknown` today. By construction `unknown` arises only from an
  npm script named `test:<unrecognised suffix>`. The shapes with **no type at all** (not `unknown`, simply absent from the
  output) are the 11 plain-Node test files. If they were ever surfaced via an npm script they would be `unit` (bare `test`)
  with `paths: []`, so they would still not be attributable to a file.

Conclusion for the decision step: the existing source gives a suite-level type that is ambiguous for bats (unit and
integration share files) and absent for Node. It cannot, as it stands, give a per-test type.

### 3. Graph node population

Source: `project/knowledge-graph/graph.json` (tracked: `git ls-files project/knowledge-graph`).

| Question | Result | Command |
|---|---|---|
| Node count | 346 | `jq '.nodes\|length' project/knowledge-graph/graph.json` |
| Nodes by `source` | `board` 346 | `jq -r '.nodes\|group_by(.source)\|map("\(.[0].source) \(length)")[]' project/knowledge-graph/graph.json` |
| Nodes by `type` | `epic` 57, `story` 289 | `jq -r '.nodes\|group_by(.type)\|map("\(.[0].type) \(length)")[]' project/knowledge-graph/graph.json` |
| **`human` or `ast` nodes** | **0** | `jq '[.nodes[]\|select(.source=="human" or .source=="ast")]\|length' project/knowledge-graph/graph.json` |
| `status` field values | all `null` (absent), so none superseded | `jq -r '[.nodes[].status]\|group_by(.)\|map("\(.[0]):\(length)")\|join(" ")' project/knowledge-graph/graph.json` |
| Nodes with `needs_revalidation` | 0 | `jq '[.nodes[]\|select(.needs_revalidation)]\|length' project/knowledge-graph/graph.json` |
| Edges | 356 (`contains` 289, `depends-on` 67) | `jq '.edges\|length' ...`; `jq -r '.edges\|group_by(.type)\|map("\(.[0].type) \(length)")[]' ...` |

**Statement: no `human` node and no `ast` node exists today. No rendered (verified) node exists today.** Every one of the
346 nodes is `source: board`.

Id shape per type (`jq '.nodes[0]' ...`, plus regex counts):

- `epic`: bare board id `E##`, e.g. `E01` (57 match `^E[0-9]+$`: `jq '[.nodes[]\|select(.id\|test("^E[0-9]+$"))]\|length' ...`).
- `story`: board story id `E##_S##`, e.g. `E01_S01` (289 match `^E[0-9]+_S[0-9]+$`).
- No `task`-typed node exists, so no `E##_S##_T##` id appears in the graph.
- Edge ids are `board:contains:<from>:<to>` / `board:depends-on:...` (`jq '.edges[0]' ...`).
- The on-disk schema (`project/knowledge-graph/STUB_SCHEMA.md`) shows `human`/`ast` ids as free-form (`node-042`,
  `node-091`), i.e. **not** board ids. Producers of `human`/`ast` nodes are the `j.uncharted` flows (`skills/j-uncharted/SKILL.md`);
  none has run against this repo's graph.

What `readSADMap()` (`project/app/api/parsers/knowledge-graph.js`, lines 91-161) renders on this data. Command:
`cd project/app/api && node -e "console.log(JSON.stringify(require('./parsers/knowledge-graph').readSADMap()))"`, result:

- `nodes`: **`[]`** (0 full nodes; `VERIFIED_SOURCES` is `{human, ast}`, line 43, and `board` is filtered out).
- Ghost stubs: **0**. A board node earns a ghost slot only when it is an edge endpoint whose *other* endpoint is verified
  (`considerGhostEndpoint`, lines 114-119); with no verified node there is no ghost.
- `edges`: **356**, i.e. every raw edge is passed through unfiltered (line 143-147), even though no node is rendered. Note
  that this means the payload already carries edges that reference no rendered node.
- `coverage`: `{"shown":0,"hidden":346,"total":346,"needsRevalidation":0}`.
- UI consequence (`project/app/ui/src/components/architecture/SADMap.jsx`, lines 300-308): `nodes.length === 0` takes the
  empty-state branch ("No verified architecture data yet for this area", with the hidden count). A test linked to any
  of today's 346 graph ids would therefore not be visible on the map.

### 4. Overlay seam

Where link data would enter the existing payload (read-only trace; nothing was changed):

1. `readSADMap()` returns `{ nodes, edges, coverage }`, with per-node props `id, label, type, verified, source, needsRevalidation`
   (full nodes, lines 124-131) and the same set minus staleness for ghosts (lines 132-141). It is a pure reader of
   `GRAPH_JSON_PATH = <root>/project/knowledge-graph/graph.json` (line 22) and never throws (returns the empty map on error).
   The natural seam for per-node link data is here: a sibling reader of a derived links file, merged by node `id` onto the
   verified-node and ghost-node objects built in this function.
2. `parseArchitecture()` (`project/app/api/parsers/architecture.js`, lines 31-65) returns `{ tech_stack, dependencies, sad_map: readSADMap(), _sources }`.
   `sad_map` is the one field that carries node data; adding a field here (for example a `test_links` sibling of `sad_map`) would leave the
   `sad_map` contract untouched.
3. Route: `project/app/api/routes/architecture.js` (`GET /`), mounted in `project/app/api/server.js` at line 63 as
   `app.use('/v1/architecture', architectureRouter)`. It does `res.json(successResponse(await parseArchitecture()))`, so no route change is
   needed for data added inside `parseArchitecture()`. The snapshot path (`project/app/api/scripts/capture-snapshot.js`) also references
   the architecture parser and must be checked when the payload grows.
4. UI consumer: `project/app/ui/src/tabs/ArchitectureTab.jsx` (lines 43-46) passes only `nodes`, `edges`, `coverage` from `data.sad_map` into
   `<SADMap>`. `SADMap({ nodes, edges, coverage })` (line 219) declares its props in a header comment as `nodes [{ id, label, type }]`;
   per-node data already read inside the component: `n.verified` (ghost styling, line 427), `needsRevalidation` (stale marker), `type`
   (collapse groups) and `coverage.*` (indicator). No prop carries per-node test data today, and the component has no tooltip or detail
   panel that would host it (click on a full node opens isolate-neighbours; ghost click does not).
5. Test coverage of the seam: `project/app/api/parsers/knowledge-graph.test.js` exercises `readSADMap()` with a fixture graph via
   `JENGA_PROJECT_ROOT`; `ROOT` is resolved once at module load (`resolveProjectRoot()`, line 21), so any new reader must follow the same
   module-load or injectable-root convention to be testable with a scratch root.

### Open facts for the Decision step (T02)

- Bats (189 files, 3860 titles) and CommonJS/ESM Node (11 files) both have comment sites and, except 3 CommonJS files
  (`ideas`, `security`, `todo`), a stable per-test name.
- Test type is suite-level and absent for Node; it is not derivable per test from `discover-tests.sh` alone.
- The map renders zero nodes today and `readSADMap()` still emits all 356 edges.
- A link whose target id is a `board` epic/story id (the only ids that exist) will never reach a rendered node until `human`/`ast` nodes are created.

## Decision

Chosen method: **annotation in the test file**, one comment line per link, extracted by a script into a derived
file. The rest of this part follows the six sections the task asks for: D1 comparison, D2 link record, D3 fidelity,
D4 node basis, D5 interactivity, D6 downstream changes.

### D1. Comparison: annotation versus manifest

**The two candidates, concretely.**

- *Annotation.* A comment line next to the test:
  `# arch-node: <id>[,<id>...] type=<type>` in bats, `// arch-node: <id>[,<id>...] type=<type>` in Node. A line
  directly above a test declaration links that one test; any other position links the whole file (grammar in D2).
- *Manifest.* A committed `project/knowledge-graph/test-manifest.json`, `{"links":[{"node_ids":[...],"file":...,
  "test":"<title, optional>","type":...}]}`, that the extractor reads instead of the test files.

**Scratch setup (nothing below is committed).** Three real tests were copied under `$TMPDIR` and linked both ways,
using ids that exist in `graph.json` (`jq -r '.nodes[]|select(.id=="E20_S09" or .id=="E08_S05" or .id=="E06_S05")|.id+" "+.type+" "+.source' project/knowledge-graph/graph.json`
prints `E08_S05 story board`, `E06_S05 story board`, `E20_S09 story board`):

| # | Real test | Shape | Link |
|---|---|---|---|
| 1 | `tests/populate-knowledge-graph.bats` (439 lines) | bats; `@test` titles | file-level `E20_S09` `unit`, plus test-level `E20_S09,E20` `integration` on `@test "containment edge is written from a story's own epic_id"` |
| 2 | `project/app/api/parsers/knowledge-graph.test.js` (353 lines) | Node CommonJS, `test('title', ...)` helper | test-level `E08_S05` `unit` on `test('transforms a fixture graph.json into the {nodes, edges} UI shape'` |
| 3 | `project/app/api/parsers/todo.test.js` (379 lines) | Node CommonJS, **no named tests** (T01 finding) | file-level `E06_S05` `unit` |

The annotated copies were made with `awk` inserts into `$TMPDIR/e83_t02_scratch`; `node --check` accepted both
annotated Node files. The annotation is a plain `#` or `//` comment, which neither bash/bats nor Node interprets
(bats treats only `# bats test_tags=` specially; T01 found no use of it in the repo).

**Annotation extraction, working command.** Run from the scratch root. Step (a) is the pure-`grep` locator; step (b)
binds each annotation to the next test declaration (or to the file) with `awk` and shapes the records with `jq`.
`\047` is a single quote inside the `awk` program; the command ran on macOS (BSD `awk`).

```bash
# (a) locate the annotations
grep -nE '^[[:space:]]*(#|//)[[:space:]]*arch-node:[[:space:]]*[A-Za-z0-9_,.-]+[[:space:]]+type=[a-z]+[[:space:]]*$' \
  tests/populate-knowledge-graph.bats project/app/api/parsers/knowledge-graph.test.js project/app/api/parsers/todo.test.js
# (b) bind to the following test declaration and emit link records
for f in tests/populate-knowledge-graph.bats project/app/api/parsers/knowledge-graph.test.js project/app/api/parsers/todo.test.js; do
awk -v F="$f" '/^[[:space:]]*(#|\/\/)[[:space:]]*arch-node:/{sub(/^[^:]*arch-node:[[:space:]]*/,"");n=$1;t=$2;sub(/^type=/,"",t);al=NR;p=1;next} p&&/^[[:space:]]*$/{next} p&&(/^@test "/||/^[[:space:]]*test\(/){nm=$0;sub(/^@test "/,"",nm);sub(/^[[:space:]]*test\([\047"]/,"",nm);sub(/["\047][ ,{)].*$/,"",nm);print F"\t"NR"\t"n"\t"t"\ttest\t"nm;p=0;next} p{print F"\t"al"\t"n"\t"t"\tfile\t"F;p=0}' "$f"; done \
| jq -R -s -c 'split("\n")|map(select(length>0)|split("\t"))|map({file:.[0],line:(.[1]|tonumber),node_ids:(.[2]|split(",")),type:.[3],scope:.[4],name:.[5]})|map(.node_ids[] as $n|{node_id:$n,test_id:(if .scope=="test" then .file+"::"+.name else .file end),type,name,file,line})'
```

Output of (a):

```
tests/populate-knowledge-graph.bats:2:# arch-node: E20_S09 type=unit
tests/populate-knowledge-graph.bats:205:# arch-node: E20_S09,E20 type=integration
project/app/api/parsers/knowledge-graph.test.js:141:// arch-node: E08_S05 type=unit
project/app/api/parsers/todo.test.js:1:// arch-node: E06_S05 type=unit
```

Output of (b) (pretty-printed here; the command prints one line): five link records, one per (test, node) pair.
Tests 1 and 2 resolve to the test declaration line (`206`, `142`: the annotation line plus one), test 3 to the file.

```json
[{"node_id":"E20_S09","test_id":"tests/populate-knowledge-graph.bats","type":"unit","name":"tests/populate-knowledge-graph.bats","file":"tests/populate-knowledge-graph.bats","line":2},
 {"node_id":"E20_S09","test_id":"tests/populate-knowledge-graph.bats::containment edge is written from a story's own epic_id","type":"integration","name":"containment edge is written from a story's own epic_id","file":"tests/populate-knowledge-graph.bats","line":206},
 {"node_id":"E20","test_id":"tests/populate-knowledge-graph.bats::containment edge is written from a story's own epic_id","type":"integration","name":"containment edge is written from a story's own epic_id","file":"tests/populate-knowledge-graph.bats","line":206},
 {"node_id":"E08_S05","test_id":"project/app/api/parsers/knowledge-graph.test.js::transforms a fixture graph.json into the {nodes, edges} UI shape","type":"unit","name":"transforms a fixture graph.json into the {nodes, edges} UI shape","file":"project/app/api/parsers/knowledge-graph.test.js","line":142},
 {"node_id":"E06_S05","test_id":"project/app/api/parsers/todo.test.js","type":"unit","name":"project/app/api/parsers/todo.test.js","file":"project/app/api/parsers/todo.test.js","line":1}]
```

**Manifest extraction, working command.** Run from a second scratch root holding the *unmodified* test files and a
521-byte `project/knowledge-graph/test-manifest.json` with the same four links. `jq` lists the links, `grep -nF`
resolves the line from the stored title:

```bash
M=project/knowledge-graph/test-manifest.json
jq -r '.links[]|[(.node_ids|join(",")),.type,.file,(.test//"")]|@tsv' $M | while IFS=$'\t' read -r n t f nm; do
  if [ -n "$nm" ]; then l=$(grep -nF -- "$nm" "$f" | head -1 | cut -d: -f1); k=test; else l=1; k=file; nm=$f; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$f" "${l:-MISSING}" "$n" "$t" "$k" "$nm"; done
```

```
tests/populate-knowledge-graph.bats	1	E20_S09	unit	file	tests/populate-knowledge-graph.bats
tests/populate-knowledge-graph.bats	204	E20_S09,E20	integration	test	containment edge is written from a story's own epic_id
project/app/api/parsers/knowledge-graph.test.js	141	E08_S05	unit	test	transforms a fixture graph.json into the {nodes, edges} UI shape
project/app/api/parsers/todo.test.js	1	E06_S05	unit	file	project/app/api/parsers/todo.test.js
```

Both methods extract all three shapes with a command of this size, so **extraction by script is a tie**: neither
needs more than `grep`/`awk`/`jq`, both work for bats and for Node. The criteria that separate them follow.

**Drift test, run on the same three tests.** In each scratch tree, the bats file was renamed
(`mv tests/populate-knowledge-graph.bats tests/populate-kg.bats`), the test title was reworded
(`containment edge is written` to `containment edge gets written`), and five lines were inserted above the test.

- Annotation tree, re-running `grep -rnE '^[[:space:]]*(#|//)[[:space:]]*arch-node:' tests` and command (b) on the new path
  gives, with **zero edits to any link source**:
  `tests/populate-kg.bats	2	E20_S09	unit	file	...` and
  `tests/populate-kg.bats	211	E20_S09,E20	integration	test	containment edge gets written from a story's own epic_id`.
  Path, title and line (206 to 211) all followed the test.
- Manifest tree, the dangling check
  `jq -r '.links[]|select(.file)|[.file,(.test//"")]|@tsv' $M | while IFS=$'\t' read -r f nm; do [ -f "$f" ] || echo "DANGLING file: $f"; done`
  printed `DANGLING file: tests/populate-knowledge-graph.bats` **twice** (both entries for the file broke on the rename).
  Restoring the filename and keeping only the title change, the same loop with `grep -qF -- "$nm" "$f"` printed
  `DANGLING test: tests/populate-knowledge-graph.bats :: containment edge is written from a story's own epic_id`.

**Hash test, run on `todo.test.js`.** `shasum -a 256` of the unannotated copy begins `e7cf5c00e933`; of the annotated
copy `bccc188416f5`. Adding or changing an annotation changes the hash of the test file that carries it, which is
exactly the signal the `generated_from.tests` block needs. Editing the manifest changes no test-file hash.

**Authoring size, measured.** The four links cost **137 bytes** of annotation lines (`grep -rh 'arch-node' ... | wc -c`)
versus **521 bytes** of manifest (`wc -c`), and the manifest restates the file path of every link and the full title of
every test-level link.

**Title ambiguity, measured on all bats files.** No `tests/*.bats` file has two identical `@test` titles
(`for f in tests/*.bats; do grep '^@test' "$f" | sed 's/ {$//' | sort | uniq -d; done | wc -l` prints `0`), but **7
titles are a substring of another title in the same file** (loop with `awk` `index()`; prints `7`), so the manifest's
`grep -nF` first-match resolution above can attach a link to the wrong test.

**Criteria table.**

| Criterion (from the story) | Annotation | Manifest | Edge |
|---|---|---|---|
| Authoring cost | one 30-odd-character comment line next to the test; needs the test file to be editable; 137 B for 4 links | one JSON object per link restating path and (for test-level) title; no test file touched; 521 B for 4 links | annotation for a single link; manifest if someone must link many tests in bulk without touching them |
| Drift on rename or move | none: link, path and line are re-read from the file each run (path 2 and line 206 to 211 above) | path key dangles on a move (2 `DANGLING file`), title key dangles on a reword (1 `DANGLING test`); a human must edit the manifest | annotation |
| Support for bats and Node alike | yes: `#` and `//` comment, same grammar; all 214 current bats files start with the shebang and have a `#` on line 2, and Node files already carry header comments (T01) | yes: path plus title; but needs a title-resolution step and mis-resolves up to 7 prefix-colliding bats titles | tie on coverage, annotation on precision |
| Extraction by script | `grep` + `awk` + `jq`, command above | `jq` + `grep -nF`, command above | tie |
| Refresh-flow friendliness | link edits change the test file's SHA-256, which the E83_S02 `generated_from.tests` block already records | link edits change no test hash, so staleness of the link source needs a manifest hash in `generated_from`, a field the E83_S02 spec does not have | annotation |

**Chosen: annotation.** Reasons the manifest was rejected, each tied to a finding or a command above:

1. **It drifts on rename and move.** The rename test left both manifest entries dangling and the title reword left a
   third; the annotation followed the file and the title with no edit. T01 counted 189 bats files and 3860 titles
   (214 files on the integration branch today), so any link file keyed by path has many entries exposed to a
   file move; one that breaks silently on a rename would turn the E83_S04 refresh flow into a permanent source of
   `test-removed` noise.
2. **It cannot use the staleness mechanism E83_S02 already specifies.** `generated_from` records the hash of
   `graph.json` and of every linked test file. An annotation edit changes a recorded hash (`e7cf5c00e933` versus
   `bccc188416f5`), so `check-test-links.sh` sees it for free. A manifest edit changes none of them, so the manifest
   would need its own hash entry and a new `check` reason (`manifest-changed`), adding schema, validator rule and test
   for no benefit.
3. **Title-keyed test links are ambiguous.** The manifest has to restate each title and resolve it by text; 7 bats
   titles are a substring of another title in the same file, so `grep -nF` can bind a link to the wrong test, and the
   three Node files without named tests (T01: `ideas`, `security`, `todo`) force the manifest to special-case "no
   title" anyway. The annotation binds to the declaration line structurally: no title is restated and none is searched.
4. **It would duplicate the derived file.** The manifest's fields (node ids, file, test title, type) are nearly the
   derived `test-links.json` itself (D2). Two hand-maintained or semi-generated JSON files with overlapping content,
   one of them edited by every author who links a test, is a second source of truth and a merge-conflict hot spot;
   annotations keep the single authoritative source in the test and the single derived file under script control.

**What the annotation costs (stated so the decision is not one-sided).** It edits the test file, so it needs the
file to be ours to edit (all 200+ candidate tests are), and every link edit shows as a changed test file in the
refresh flow (`test-changed`), which cannot tell a link edit from a logic edit. Both are accepted: the first is the
point of co-location, the second is a false-positive refresh, not a missed one, and the refresh is cheap.

### D2. Link record

**Annotation grammar (the only link source).**

```
<leader> arch-node: <node-id>[,<node-id>...] type=<type>
```

- `<leader>` is `#` (bats and any shell) or `//` (Node, CommonJS or ESM), optionally indented.
- `<node-id>` matches `[A-Za-z0-9_.-]+` (board ids such as `E20_S09` and the free-form `human`/`ast` ids of
  `STUB_SCHEMA.md` such as `node-042` both fit); several ids are comma-separated with no spaces.
- `type=<type>` is **required**; `<type>` is one value of the vocabulary of `skills/j-test/scripts/discover-tests.sh`
  (header, line 28: `unit | integration | e2e | sast | vulnerability | performance | coverage | unknown`).
- **Binding.** If the next non-blank line after the annotation is a test declaration (`@test "..."` at column 0 in bats;
  `test('...'` or `test("..."` in Node, the shapes T01 found), the link is **test-level**: `name` is the title, `line` is
  the declaration line. Anything else (a header comment, code, end of file) makes it **file-level**: `name` is the file
  path, `line` is the annotation line. Consecutive annotation lines above one declaration are allowed and each links
  its own ids.
- **Malformed** (reported with file and line, skipped, exit code 3 per `E83_S02_T02`): no `type=`, an unknown token
  after the ids, an empty id list, or a test declaration whose title is not a plain string literal.
- The grammar is deliberately strict: extra `key=value` tokens are reserved for later fidelity levels (D3) and are
  malformed in version 1, so a future grammar change cannot be confused with a typo.

**One link, field by field** (one element of `links[]`; one record per (test, node) pair, so a test linked to three
nodes is three records):

| Field | Type | Required | Rule |
|---|---|---|---|
| `node_id` | string | yes | non-empty; an id in `graph.json` of any `source` (D4); existence is checked only by `validate-test-links.sh --graph` (rule `dangling-node`) |
| `test_id` | string | yes | stable identity of the test: `<file>::<name>` for a test-level link, `<file>` for a file-level link. The pair (`node_id`, `test_id`) is the link's key; two records with the same key are the duplicate the validator rejects |
| `type` | string | yes | one value of the `discover-tests.sh` vocabulary above; copied verbatim from the annotation |
| `name` | string | yes | the test title (test-level) or the file path (file-level); this is the "test name" the overlay shows |
| `file` | string | yes | repository-root-relative POSIX path of the test file; no leading `./`, no `..`; must also be a key of `generated_from.tests` |
| `line` | integer | yes | `>= 1`; the test declaration line (test-level) or the annotation line (file-level) at extraction time |

`test_id` is named in this task's list but absent from the `E83_S02` task text (which lists node id, test type, test
name, file and line); it is kept because `name` alone is not unique across files, and the deferred features (D5) need
a stable key. Whether a link is
test-level or file-level is derivable from `test_id` containing `::`, so no separate `scope` field is stored.

**The derived links file, field by field.**

```json
{
  "schema_version": 1,
  "generated_from": {
    "graph_sha256": "<64 lowercase hex, or the literal absent>",
    "tests": { "<file>": "<64 lowercase hex SHA-256 of that file's bytes>" }
  },
  "links": [
    { "node_id": "E20_S09", "test_id": "tests/x.bats::title", "type": "integration", "name": "title", "file": "tests/x.bats", "line": 206 }
  ]
}
```

| Path | Type | Rule |
|---|---|---|
| `schema_version` | integer | required, `1`; added so a later grammar or record change is detectable (the `E83_S02_T01` text does not name it) |
| `generated_from.graph_sha256` | string | required; SHA-256 of `<root>/project/knowledge-graph/graph.json`, or the literal `absent` when the graph does not exist (never empty) |
| `generated_from.tests` | object | required; path to SHA-256 for **every file that carries at least one valid link**, and for no other file; keys sorted |
| `links` | array | required (may be empty); sorted by `node_id`, then `file`, then `line`, then `test_id`; each element as in the table above |

Determinism: fixed key order exactly as written, no timestamp, trailing newline, so two runs on unchanged input are
byte-identical. Additional validator rules implied by the schema, beyond those already in `E83_S02_T01`: `file` is a
key of `generated_from.tests` (rule `unhashed-file`); `generated_from.tests` has no key that no link uses
(rule `orphan-hash`); `type` is in the vocabulary (rule `type`); `file` is relative and normalised (rule `file-path`).

**Location: confirmed, `project/knowledge-graph/test-links.json`.** Reasons: (1) it sits next to `graph.json`, whose hash
it records, in a directory that is already tracked (`git ls-files project/knowledge-graph` lists `graph.json` and
`STUB_SCHEMA.md`); (2) the dashboard reader will resolve it the way `readSADMap()` resolves `graph.json`
(`resolveProjectRoot()` plus a fixed relative path, T01 Findings section 4), so it needs no new configuration key;
(3) the directory has no `.publicignore` rule today (`grep -n knowledge .publicignore` prints nothing), so the links
file follows `graph.json`'s visibility and `E83_S02_T05`'s mirror-skip guard is the right place to handle absence.
The annotations themselves live in the test files and need no location.

### D3. Fidelity

**First-version level: node level.** A link says "this test covers this architecture node". It is test-level (one
named test) or file-level (a whole test file, used where there is no stable per-test name, such as the three Node
files `ideas`, `security`, `todo` from T01). **One test may link to many nodes** (comma-separated ids, one record per
pair, shown with `E20_S09,E20` above) and one node may be linked by many tests.

**Explicitly out of the first version:**

- links to an **edge** (a relationship between two nodes) and to a **function, symbol or source line** of the code
  under test;
- **measured coverage**: line, branch or percentage coverage, and any claim of how much of a node a test exercises;
- **inferred links**: deriving links from imports, call graphs, file-name similarity or the AST (`j.uncharted`
  territory); every link is written by a person or agent;
- link **weights, confidence, direction, or "negative" links** (a test asserting a node is absent);
- links from a test to another test, or from a node to a whole directory (node-to-glob);
- nested or per-assertion granularity inside a single test.

Reserved extension point: later levels add `key=value` tokens after `type=` (D2), so they are additive.

**Where test type comes from: the link, not `discover-tests.sh`.** T01 showed that `discover-tests.sh` types
**suites**, never files or tests; that `tests/*.bats` belongs to the `unit` suite and the `integration` suite at once
(`jq -r '.suites[]|"\(.id) \(.type)"'` lists `bats:tests unit` and `config:bats:integration integration` over the same
glob), so no bats file has a single type there; and that the 11 plain-Node files appear in no suite at all. A per-test
type therefore cannot be derived from it. The annotation carries `type=` (required), and `discover-tests.sh` stays
the owner of the **vocabulary** only, so the overlay's type names are the same words `j.test` and `test-config.json`
already use and a per-type filter (D5) lines up with the suite types. The extractor does not call `discover-tests.sh`
and holds no file-to-type table; the validator holds the allowed-value list (one list, copied from the
`discover-tests.sh` header, in the schema's source-of-truth header comment).

### D4. Node basis

**A link may name any node id that exists in `graph.json`, whatever its `source`** (`board`, `human` or `ast`).
`validate-test-links.sh --graph` enforces it (rule `dangling-node`); a link to an id absent from the graph is warned
about by the extractor and still written, as `E83_S02_T02` already says.

Why not "rendered `human`/`ast` nodes only": there are none. Re-checked today on the integration branch:
`jq '.nodes|length' project/knowledge-graph/graph.json` prints `346`; the source split prints `board 346`;
`jq '[.nodes[]|select(.source=="human" or .source=="ast")]|length'` prints `0`; and
`cd project/app/api && node -e "const m=require('./parsers/knowledge-graph').readSADMap(); console.log(m.nodes.length, m.edges.length, JSON.stringify(m.coverage))"`
prints `0 356 {"shown":0,"hidden":346,"total":346,"needsRevalidation":0}`. A rendered-only rule would make every link a
`dangling-node` today and `E83_S02_T04` ("at least 5 tests linked, every linked node id exists in `graph.json`")
unsatisfiable. It would also tie what a developer may write in a test to what the map happens to render on a given
day: the same annotation becomes visible the moment `j.uncharted` adds `human`/`ast` nodes with that id, with no edit to
the test.

**What the overlay shows for a link whose node is not rendered.** A "not rendered" link is any link whose `node_id` is
not a full, verified node in `readSADMap().nodes`: a `board` node (hidden by the provenance gate), a ghost stub
(`verified: false`, never counted as covered), or an id absent from the graph.

- On the map: nothing. No badge, no change to a node, no new node. (A link must never turn a hidden node into a rendered one.)
- In the data: `coverage.testLinksUnrendered`, the number of link records of that kind, is added next to `testCovered`.
- In the "Test coverage" section: the empty state names it, for example "No test links recorded for the nodes on this
  map. 5 test links exist for nodes that are not shown on this map (board-sourced or unverified)."

**Plain statement of the consequence: on today's graph the first overlay shows nothing on the map.** There are zero
rendered nodes, so the Architecture tab stays in its empty state ("No verified architecture data yet for this area"),
there is no node to badge, `coverage.testCovered` is `0`, and the "Test coverage" section shows only its empty state
plus the unrendered count. The overlay code path (badge, tooltip, legend, table) can be exercised only with a fixture
graph that holds `human` or `ast` nodes (`E83_S03_T05`) until such nodes exist in this repository's graph. The links
file itself is useful from day one: it is validated, committed and refreshed, and its entries light up unchanged once
a linked id becomes a rendered node.

**Open question 1 (needs a user decision; the downstream stories proceed on the default).**
*The first overlay is empty on this repository's real graph. Is that acceptable for version 1?*

1. **Default (recommended): accept it.** Link tests to the ids that exist today (board epic and story ids such as
   `E20_S09`, `E08_S05`, `E06_S05`), keep `readSADMap()`'s provenance gate and E08's rendering unchanged, and surface
   the hidden links through `testLinksUnrendered` so the user can see the links exist. The overlay becomes visible when
   `human`/`ast` nodes are added to the graph (for example by running `j.uncharted onboard`), which is a separate,
   already-existing workflow and not part of E83.
2. Link board nodes **and** change what the map renders (let `board` epic/story nodes through, or a subset). It makes
   the overlay visible today, but it reopens E08's design: `VERIFIED_SOURCES` is `{human, ast}`, and
   `knowledge-graph.test.js` has a test titled "excludes source: board nodes from the rendered output (provenance
   gate)"; the map would show up to 346 unverified nodes. Larger scope, a product decision.
3. Run `j.uncharted onboard` first so real `human`/`ast` nodes exist, then link to them. Gives a visible result but
   depends on running and reviewing an onboarding pass, which is outside E83's tasks.

If the user picks 2 or 3, the E83 task wording changes as listed in D6 under "if Open question 1 is not the default".

### D5. Interactivity

**Confirmed: the first version is static and read-only.** No click handler, filter, navigation or jump to test code
is added to the map; the existing SADMap interactions (click to isolate, type collapse, pan and zoom) are unchanged;
the overlay is a badge, a hover `<title>` and a plain-text table, delivered through the existing `/v1/architecture`
payload so it also works in the `j.dashboard --snapshot` export. Clickable nodes, per-type filters and jump to test
code stay deferred (recorded by `E83_S06`).

**Data captured now so the deferred features need no re-linking** (all of it already in the link record, D2):

| Deferred feature | Data it needs | Captured as |
|---|---|---|
| Clickable nodes (show a node's tests) | node to tests relation | `node_id` on every record; `readTestLinks()` already groups by it |
| Per-type filters | the test type | `type`, a value of the `discover-tests.sh` vocabulary |
| Jump to test code | where the test is | `file` (repo-relative) and `line` (declaration or annotation line); `name`/`test_id` as fallback when a line has moved |
| Knowing when a line is trustworthy | whether the file changed since extraction | `generated_from.tests[<file>]` hash, so a jump can refuse or warn when the hash is stale |
| Finer fidelity later (edge, function) | a place in the annotation to say more | reserved extra `key=value` tokens (D2, D3); no existing link needs rewriting |

Because the link lives in the test file (D1), none of these features can orphan an existing link; adding them touches
the reader and the UI only.

### D6. Downstream changes

Tasks read in full: `E83_S02_T01` to `T05`, `E83_S03_T01` to `T05`, `E83_S04_T01` to `T04`. The scrum master applies
these amendments; the changes assume the **default** answer to Open question 1.

| Task | Change |
|---|---|
| `E83_S02_T01` | Record fields are `node_id`, `test_id`, `type`, `name`, `file`, `line` (add `test_id`; the text lists "node id, test type, test name, file, line"). Add the top-level `schema_version` (integer 1) and the shape of `generated_from` from D2. Add the rules `unhashed-file`, `orphan-hash`, `type` (vocabulary, list held in the script header) and `file-path`; duplicate means same (`node_id`, `test_id`). Add one bats case per new rule. Location `project/knowledge-graph/test-links.json` confirmed, no change. |
| `E83_S02_T02` | Method is **annotation**: replace "annotations in test files, or the manifest" and every "manifest" mention (including "never modifies ... the manifest") with the D2 grammar. Test type is the annotation's required `type=` field; delete the "or `discover-tests.sh` suite typing" alternative and keep "no second type table". State the **scan set** (the task is silent on it): `tests/*.bats` plus every `*.test.js` under the root excluding `node_modules`, `.git`, fixture directories and dot-directories (the `find` from Findings section 1). Malformed means the D2 list (no `type=`, unknown token, empty id list, non-literal title). `generated_from.tests` lists only files with at least one valid link. Output carries `schema_version`. |
| `E83_S02_T03` | Remove "and the manifest if the chosen method uses one". Fixture files must cover: bats file-level, bats test-level, Node CommonJS test-level, Node file with no named tests (file-level), and a multi-id annotation. Add cases: the annotation line's file moved or a test reworded changes `file`/`name`/`line` in the output with no other edit; each D2 malformed form is skipped with file:line and exit `3`; adding an annotation changes that file's hash. |
| `E83_S02_T04` | "annotation lines in those test files, or manifest entries" becomes annotation lines with a `type=` token. "use the node basis the spike decided" becomes: any id present in `graph.json`; today only `board` epic/story ids exist, so link to those (`E20_S09`, `E08_S05`, `E06_S05` verified to exist); do not invent `human`/`ast` ids. The 2-types requirement is met by the author's `type=` values (for example `unit` and `integration`). Add to the acceptance criteria: the task summary states that the overlay is expected to show no covered node on this repository's graph and reports the resulting `testLinksUnrendered` figure. |
| `E83_S02_T05` | None. Case 3 (`--stdout` equals the committed file) already relies on the byte-determinism that D2 specifies. |
| `E83_S03_T01` | None. `readTestLinks()` returns `{ byNode, total }` with `{name,type,file,line}`; `test_id` and `schema_version` are ignored by the reader, which already must tolerate fields it does not use. |
| `E83_S03_T02` | The conditional "if the spike decided to surface a count of them" is decided: **yes**. `coverage.testLinksUnrendered` is mandatory, defined as the number of link records whose `node_id` is not a full verified rendered node (board-sourced, ghost stub, or absent from the graph). Add cases: a link to a `board` node is counted and renders nothing; a link to a ghost is counted; `testLinksUnrendered` is `0` with no links file; `shown`/`hidden`/`total` unchanged. |
| `E83_S03_T03` | None. Badge, `<title>` lines and legend apply only to rendered covered nodes, as written. |
| `E83_S03_T04` | The empty state must include the count: with `testCovered` 0 and `testLinksUnrendered` greater than 0, "No test links recorded for the nodes on this map. N test links exist for nodes that are not shown on this map (board-sourced or unverified)."; with both 0, the original one-liner. The summary line "N of M rendered nodes covered" is not shown when `coverage.shown` is 0 (it would read "0 of 0"). Add an acceptance criterion for this repository's real graph (zero rendered nodes) showing the empty state with the count. |
| `E83_S03_T05` | Step 1 also asserts `coverage.testLinksUnrendered` equals 1 for the board-sourced link; step 3 asserts it is 0 with no links file. Everything else unchanged (the fixture already contains one `human` and one `board` node). |
| `E83_S04_T01` | `unlinked-new-test`: "in none of the links and not in the links source" becomes "in none of the links and carrying no `arch-node` annotation", using the same scan set as the extractor (reference it, do not redefine it). Note in the header that `test-changed` also fires when only an annotation line changed, by design (D1). No other change. |
| `E83_S04_T02` | Add one case: a fixture test file whose only change is an added or edited annotation line yields `test-changed`; and one case that an unannotated new test file appears under `unlinked-new-test` only. |
| `E83_S04_T03` | None. The report names links by `node_id` and `test_id`; use those field names in the template placeholders. |
| `E83_S04_T04` | None. Case 2 ("after editing a linked test file") already covers an annotation edit; the fixture's test files carry `arch-node` annotations because there is no manifest to copy. |

**If Open question 1 is not the default.** Option 2 (render `board` nodes): `E83_S03_T02` and `T04` lose the unrendered
framing for board ids, `T05`'s "the board-sourced link does not turn a hidden node into a rendered one" is replaced, and
a new E08-side task is needed (outside E83). Option 3 (onboard first): `E83_S02_T04` links to the new `human`/`ast` ids
instead of board ids and gains a dependency on the onboarding pass; no other E83 task changes.

**Outside the requested range, for the scrum master's re-read.** `E83_S05_T01` (the feature document) should describe the
annotation grammar from D2 and state the empty-on-day-one consequence from D4; `E83_S06` needs no change.

