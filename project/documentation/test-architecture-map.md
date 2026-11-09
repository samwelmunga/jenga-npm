# Test-to-Architecture Map

Maintainer-internal feature document for epic `E83`. Everything below describes what exists in the tree today; where
this document and a script disagree, the script wins. Section 7 documents the refresh flow (keeping the links file
current), section 8 troubleshooting and section 9 the deferred interactivity.

## 1. Overview

The test-to-architecture map is a read-only overlay on the dashboard's Architecture tab. A test file carries
`arch-node:` comment annotations naming the architecture node ids it covers; `scripts/extract-test-links.sh` reads those
annotations and writes the derived file `project/knowledge-graph/test-links.json`; the dashboard API attaches each node's
tests to the architecture payload, and the tab shows a count badge on covered nodes, a hover tooltip listing their tests,
and a "Test coverage" table. The overlay only draws nodes that the map already renders, and it does not move, filter or
open anything. Why annotation in the test file was chosen over a separate manifest, and the other decisions behind the
link record and the node basis, are in
[`project/documentation/test-architecture-linking-spike.md`](test-architecture-linking-spike.md).

## 2. How to link a test

The method is an annotation comment in the test file, one line per link:

```
<leader> arch-node: <node-id>[,<node-id>...] type=<type>
```

`<leader>` is `#` (bats, shell) or `//` (Node). `type=` is required and is one value of the validator's type vocabulary
(see the header of `scripts/validate-test-links.sh`). The full grammar (binding, malformed forms, scan set) is in the
header of `scripts/extract-test-links.sh`.

A comment directly above a test declaration links that one test (test-level); a comment anywhere else links the whole file
(file-level). Worked example, from `tests/populate-knowledge-graph.bats` (linked by `E83_S02_T04`):

```
$ sed -n '1,3p;204,207p' tests/populate-knowledge-graph.bats
#!/usr/bin/env bats
# arch-node: E20_S09 type=unit
#

# arch-node: E20_S09,E20 type=integration
@test "containment edge is written from a story's own epic_id" {
  write_epic "E90" "Test Epic Alpha" "Alpha purpose."
```

Line 2 is a file-level link (its next non-blank line is a comment, not a test), giving one record for `E20_S09` with
`line` 2. Line 205 is directly above the `@test` on line 206, so it is a test-level link to two nodes and yields two
records, one per node, both with `line` 206 and `test_id`
`tests/populate-knowledge-graph.bats::containment edge is written from a story's own epic_id`. The record for `E20` as it
sits in `project/knowledge-graph/test-links.json`:

```json
{
  "node_id": "E20",
  "test_id": "tests/populate-knowledge-graph.bats::containment edge is written from a story's own epic_id",
  "type": "integration",
  "name": "containment edge is written from a story's own epic_id",
  "file": "tests/populate-knowledge-graph.bats",
  "line": 206
}
```

**Finding a node id.** A link may name any id that exists in `graph.json`. List them with:

```bash
jq -r '.nodes[] | "\(.id)\t\(.label)"' project/knowledge-graph/graph.json
```

**Regenerating the links file** after adding or editing annotations (this is the only writer of the file; never edit it by hand):

```bash
bash scripts/extract-test-links.sh
```

Scripts in this repository are mode 644 and are always called as `bash <script>`. Malformed annotations are reported on
stderr as `<file>:<line>: ...` and skipped (exit 3).

## 3. The links file

Location: `project/knowledge-graph/test-links.json`, next to `graph.json`. It is derived: write it only with
`scripts/extract-test-links.sh`.

- Top level: `schema_version` (the integer 1), `generated_from`, `links`.
- Each record in `links` has the fields `node_id`, `test_id`, `type`, `name`, `file` and `line`. There is one record per
  (test, node) pair. `test_id` is `<file>::<name>` for a test-level link and `<file>` for a file-level link.
- `generated_from` is the hash block: `graph_sha256` is the SHA-256 of `graph.json` (or the literal `absent`), and `tests`
  maps each test file that carries at least one valid link to the SHA-256 of that file's bytes. It records what the file was
  generated from, so a later edit to the graph or to a linked test can be detected.

The schema's source of truth is the header of `scripts/validate-test-links.sh`: its field rules, the allowed `type`
vocabulary and the ordered rule list live there and are deliberately not copied here.

## 4. Scripts

Both text blocks below are copied from the scripts' header comments (the `USAGE` and `EXIT CODES` sections).

### `scripts/extract-test-links.sh`

Usage:

```
  extract-test-links.sh [--root <dir>] [--out <file>] [--stdout]
  extract-test-links.sh -h | --help       print this usage on stdout, exit 0

  --root <dir>   the directory to scan; default: the project root from scripts/resolve-root.sh root. Also --root=<dir>.
                 The project tree name (project or .project) used for the default paths comes from resolve-root.sh
                 too (for an explicit --root it is resolved from inside that directory, ignoring JENGA_PROJECT_ROOT,
                 and falls back to "project").
  --out <file>   where to write the links file; default: <root>/<tree>/knowledge-graph/test-links.json (normally
                 <root>/project/knowledge-graph/test-links.json). Also --out=<file>. The directory is created.
  --stdout       print the JSON on stdout and write no file. Cannot be combined with --out.

The graph whose hash is recorded is <root>/<tree>/knowledge-graph/graph.json. The script never modifies a test file or
graph.json, and writes nothing but the output file (plus its temporary file and lock directory, both removed).
Compatible with macOS bash 3.2 (no mapfile, no associative arrays, no case-modifying expansions); needs jq, awk, find,
sort and `shasum -a 256` or `sha256sum`, whichever exists.

```

Exit codes:

```
  0   ok: every annotation was valid; the links file was written (or printed with --stdout)
  1   the extracted JSON failed scripts/validate-test-links.sh (the validator's one-line verdict is printed on stderr),
      or the output could not be moved into place: the previous output file is left exactly as it was, and with
      --stdout nothing is printed
  2   usage error (unknown flag, flag without a value, --stdout together with --out, positional argument), the root is
      missing or unreadable, a scanned test file is unreadable, a required tool (jq, a SHA-256 tool) is missing, or the
      type vocabulary cannot be read from the validator header
  3   ok with skipped entries: at least one malformed (or duplicate) annotation was reported on stderr as
      "<file>:<line>: ..." and skipped; every valid link was still extracted and written

```

### `scripts/validate-test-links.sh`

Usage:

```
  validate-test-links.sh [--graph <graph.json>] [<links-file>]

  <links-file>      the links file to check. When omitted, the resolved default
                    <root>/<tree>/knowledge-graph/test-links.json is used, where <root> and <tree> come from
                    scripts/resolve-root.sh (normally project/knowledge-graph/test-links.json).
  --graph <file>    also check every link's node_id against the nodes of this graph.json (rule dangling-node).
                    Also --graph=<file>. Without it, node ids are not checked.

The script reads only its arguments and the resolved default above, writes no file, and compiles against macOS bash 3.2
(it needs jq).

```

Exit codes:

```
  0   the file conforms; nothing is printed
  1   a rule is violated; ONE line is printed on stdout naming the FIRST violated rule (rule order below), in the form
      "<path> <problem> (rule <name>)", for example "links[3].node_id missing (rule field-missing)"
  2   usage error (unknown flag, --graph without a value, more than one links file), or the links file or the --graph
      file is missing, unreadable, not valid JSON, or not the expected top-level shape (the links file must be a
      JSON object; the graph must carry a .nodes array); one line on stderr says which

```

Observed beyond the headers: `validate-test-links.sh` has no `--help` text; `-h` or `--help` prints its one usage line on
stderr and exits 2. `extract-test-links.sh --help` prints its usage line on stdout and exits 0, as its header says. A
read-only check of the committed file against the graph:

```bash
bash scripts/validate-test-links.sh --graph project/knowledge-graph/graph.json
```

`tests/test-links-repo-integrity.bats` is the repository guard around the committed file: it checks the file against the
validator and the graph, checks that every linked file exists, and checks that `bash scripts/extract-test-links.sh --stdout`
is byte-identical to the committed file (so editing a linked test, an annotation or the graph without regenerating the file
makes it fail, and its failure message names the script to run).

## 5. The overlay on the Architecture tab

**What is shown.** All of it is read-only display; none of it is a control.

- **Covered-node badge.** A small circle at the top-left of a rendered node holding the number of tests that cover it
  (`SADMap.jsx`). It appears only on a real, verified (`human` or `ast`) node with at least one test; a ghost stub (an
  unverified node shown dimmed for edge continuity) and a collapsed type-cluster node are never badged.
- **Hover text.** The node's SVG `<title>` gets one extra line per test, `<type> · <name> · <file>:<line>`, after the node's
  own title; more than 8 tests show the first 8 and a final `+N more` line (`coverageOverlay.js`).
- **Legend.** One line under the map, "The number on a node is how many tests cover it. Hover a node to list them.", shown
  only when at least one visible node is covered.
- **"Test coverage" table.** A section below the map (`TestCoverageTable.jsx`) with the columns Node, Type, Test and
  Location, one row per (covered node, test), sorted by node label and then test name. Location is plain `file:line` text.
  A summary line, `N of M rendered nodes covered by tests`, sits above it and is omitted when no node is rendered.

**When a node is not rendered, or no links exist.** A link whose node is not a full verified rendered node (a `board`
node, a ghost stub, or an id absent from the graph) draws nothing: no badge, no change to any node, and it never makes a
hidden node visible. It is counted in `coverage.testLinksUnrendered`. With no covered node, the "Test coverage" section
shows one sentence instead of the table: `No test links recorded for the nodes on this map.`, followed, when
`testLinksUnrendered` is above 0, by `N test links exist for nodes that are not shown on this map (board-sourced or
unverified).` A missing or malformed links file reads as no links: every node gets `tests: []`, `testCovered` and
`testLinksUnrendered` are 0, and nothing errors.

**How the data reaches the UI.**

1. `readTestLinks()` (`project/app/api/parsers/test-links.js`) reads `project/knowledge-graph/test-links.json`, groups the
   links by `node_id` (keeping `name`, `type`, `file`, `line`) and never throws.
2. `readSADMap()` (`project/app/api/parsers/knowledge-graph.js`) gives every rendered node a `tests` array (ghost stubs
   always `[]`) and adds `testCovered` and `testLinksUnrendered` to `coverage`, computed in the same pass as `shown`.
3. `parseArchitecture()` (`project/app/api/parsers/architecture.js`) returns that map as `sad_map`, and
   `GET /v1/architecture` (`project/app/api/routes/architecture.js`) serves it.
4. `project/app/ui/src/tabs/ArchitectureTab.jsx` fetches `/v1/architecture` and passes `sad_map.nodes`, `sad_map.edges` and
   `sad_map.coverage` to `SADMap` and the nodes and coverage to `TestCoverageTable`.

**Snapshot.** The overlay ships in `j.dashboard --snapshot`: the capture step
(`project/app/api/scripts/capture-snapshot.js`, run by `skills/j-dashboard/scripts/snapshot.sh`) calls `/v1/architecture`
once, so the same `sad_map` data is embedded in the single HTML file. `tests/dashboard-test-links-overlay.bats` is the
end-to-end fixture test: it builds a fixture project with one `human` and one `board` node, drives the real API parser and
the snapshot script, and checks the covered test's name appears in the export, and that with no links file both paths still
succeed with `testCovered` 0.

The overlay adds no interaction. There is no click-through from a node or a table row to its tests, no filter by test type,
and no jump to test code; those are not built.

## 6. Known limits

- **Only rendered nodes are drawn.** `readSADMap()` renders only nodes whose `source` is `human` or `ast`
  (`VERIFIED_SOURCES`); `board` nodes are hidden. A link may still name a `board` node (with `--graph` the validator checks only that the id
  exists in `graph.json`); it is counted in `testLinksUnrendered` and shown nowhere on the map.
- **The overlay shows no covered node today.** `graph.json` holds 346 nodes, all `source: board` (0 `human`, 0 `ast`;
  `jq '[.nodes[]|select(.source=="human" or .source=="ast")]|length' project/knowledge-graph/graph.json` prints 0). All 8
  records in `test-links.json` name `board` nodes (`E06_S05`, `E08_S05`, `E20`, `E20_S09`, `E35`, `E44_S01`, `E44_S02`; each
  is `source: board`). `readSADMap()` therefore returns 0 nodes with
  `coverage` `{"shown":0,"hidden":346,"total":346,"needsRevalidation":0,"testCovered":0,"testLinksUnrendered":8}`: the
  Architecture Map shows its empty state, there is no badge, and the "Test coverage" section shows the one-sentence empty
  state with `8 test links exist for nodes that are not shown on this map (board-sourced or unverified).` The links start
  to show unchanged once a linked id becomes a `human` or `ast` node (for example through `j.uncharted`).
- **Verified by fixture, not on the real graph.** The badge, tooltip, legend and table code paths are exercised by
  `tests/dashboard-test-links-overlay.bats` against a fixture graph. A visual check of the real tab in a browser was not
  performed (`project/rapports/problems/E83_S03_T05-visual-check-of-architecture-tab-not-performed.md`).
- **Node-level only.** A link says a test covers a node. There are no links to edges, functions or lines of code, no
  measured coverage, no inferred links, and no weights. Test type comes from the annotation's `type=`, not from
  `skills/j-test/scripts/discover-tests.sh`.
- **File-level links for unnamed tests.** A test file with no stable per-test name (for example `todo.test.js`) is linked at
  file level, so the table lists the file path as the test name.
- **Scan set.** The extractor reads `tests/*.bats` (direct children) and every `*.test.js` under the root, excluding
  `node_modules`, `.git`, directories named `fixtures` and dot-directories. An annotation in any other file is ignored.
- **The links file is a snapshot.** It is correct for the graph and the test files as they were when it was generated; an
  edit to a linked test (even an annotation line) or to `graph.json` leaves it out of date until `scripts/extract-test-links.sh`
  is run again, and `tests/test-links-repo-integrity.bats` fails until then. Section 7 describes the flow that detects this.

## 7. Refresh flow

The `test-links-refresh` workflow (`project/.workflows/test-links-refresh.json`, epic `E83_S04`) checks whether the links
file is still true to `graph.json` and the test files, regenerates it, and reports what changed. It has four steps:
`check` (`scripts/test-links-refresh-check.sh`), `extract` (`scripts/extract-test-links.sh`), `diff`
(`scripts/test-links-refresh-diff.sh`) and `report` (a markdown render of
`project/.workflows/templates/test-links-refresh-report.md`). It takes no inputs.

**Run it.** From a Claude Code session in the repository:

```
j.workflow run test-links-refresh
```

`/j-workflow run test-links-refresh` is the same command; bare `j.workflow` lists the definitions as a numbered picker.
Without the skill (as the end-to-end suite `tests/test-links-refresh-workflow.bats` does), all four steps are `compute` or
`render`, so one `next-step.sh` call takes the run to `"signal":"complete"`:

```bash
RUN=$(bash scripts/workflow/run-state.sh start test-links-refresh)
bash scripts/workflow/next-step.sh "$RUN"
```

**Where the output lands.** `project/knowledge-graph/test-links.json` is rewritten in place; commit it. The report and the
step outputs are published under `project/data/workflow-artifacts/test-links-refresh/<run_id>/`, one file per output,
the report being the file named `report` (no extension); run state is `project/data/workflow-runs/<run_id>.json`. Read the
newest completed run's report with:

```bash
cat "$(bash scripts/workflow/artifacts.sh latest test-links-refresh report --path)"
```

The artifacts directory is tracked in git (see "Git treatment" in `project/documentation/workflows.md`). The report's
"Before the refresh" block is the verdict from before `extract` ran, not a verdict on the result; run
`bash scripts/check-test-links.sh` afterwards to see what is left.

**Staleness reasons and what to do.** `scripts/check-test-links.sh` reports `stale` (exit 1) with at least one of these
typed reasons, or `fresh` (exit 0). A refresh clears a reason only where the table says so.

| Reason | Meaning | Corrective action |
|---|---|---|
| `graph-changed` | `graph.json` differs from the hash recorded in the links file | Regenerate: the refresh records the new hash. |
| `test-changed` | a linked test file's bytes differ from the recorded hash (any edit, even an annotation line) | Regenerate: the refresh re-reads its annotations. |
| `test-removed` | a linked test file no longer exists | Regenerate: its links are dropped and the report lists them under "Removed". |
| `node-missing` | a link names an id that is not a node of `graph.json` | Regeneration does not clear it: the extractor warns `node id N2 is not in graph.json (link still written)`. Fix the link: correct the id in the annotation, then regenerate. |
| `node-superseded` | the node exists with `status: superseded`; `superseded_by` names its replacement (`null` when the graph omits it) | Regeneration does not clear it. Retarget: change the annotation to the superseding node, then regenerate. |
| `no-links-file` | the links file does not exist | Regenerate: the file is created and every link is reported as added. |

Beyond the reasons, `check-test-links.sh` prints informational `unlinked-new-test` lines: a test file of the scanned shapes
that is in none of the links and has no `arch-node:` annotation. They never change the verdict or the exit code. Action:
add an annotation (section 2), then regenerate. The list is capped at 20 names plus a count of the rest, and on this
repository it is long, because most test files carry no link and that is allowed.

**Limits.**

- It runs on demand only. There is no file watcher, scheduler or hook that starts it; a stale file stays stale until
  someone runs it.
- It does not create links. A new test is only reported as `unlinked-new-test`; a human adds the annotation.
- It never edits a test file or `graph.json`. Its only writes are the links file, the registry output files and the run
  state.
- It does not fix `node-missing` or `node-superseded` (table above); those need an annotation edit.
- It does not commit anything.

## 8. Troubleshooting

**Run the pieces by hand, without the workflow.** `check-test-links.sh` writes nothing; `extract-test-links.sh` writes only
the links file. Both take `--root <dir>` to work on a copy:

```bash
bash scripts/check-test-links.sh          # fresh/stale summary; exit 0 fresh, 1 stale, 2 error
bash scripts/extract-test-links.sh        # regenerate the links file (exit 3 = ok with skipped annotations)
```

**Read `check-test-links.sh --json`.** It prints one object, `{"status", "reasons", "informational"}`, and the same exit
status as the plain form. Every entry of `reasons` has a `type` from the table above plus its own fields (`file`,
`recorded` and `current` hashes, `node_id`, `test_id`, `superseded_by`). For example, the files that need a re-run:

```bash
bash scripts/check-test-links.sh --json | jq -r '.reasons[] | select(.type=="test-changed") | .file'
```

`scripts/test-links-refresh-check.sh` wraps it for the workflow and always exits 0: it prints
`{"status","reasons","snapshot"}` with `status` `fresh`, `stale` or `error`. Run by hand it leaves its `snapshot` temp file
behind (the `diff` step deletes it), so remove that file.

**The check says `error`, or the run halts at `diff`.** `check-test-links.sh` exits 2 when the links file is not valid
(for example malformed JSON). The wrapper turns that into `status: error`, `extract` still rewrites the file, but `diff`
then fails because the snapshot of the old file is not valid JSON: the run ends `failed` with no report. The links file is
already regenerated; confirm with `bash scripts/check-test-links.sh`.

**`tests/test-links-repo-integrity.bats` case 3 fails** ("`scripts/extract-test-links.sh --stdout` equals the committed
links file"). After a linked test file changes, the committed `project/knowledge-graph/test-links.json` is stale until
you rerun `bash scripts/extract-test-links.sh` and commit the result; the case compares a fresh extraction with the
committed file byte for byte, so any edit to a linked file fails it (its recorded hash changes). Regenerate, commit the
file, and the case passes. `check-test-links.sh` shows the same condition as `test-changed`.

## 9. Deferred

The first version of the map is read-only and static: the overlay shows a badge, a tooltip and a table, and it responds
to nothing else. Three interactive features were left out of epic `E83` on purpose. None of them is available, and none
is partly implemented. Each would use data the first version already stores on every record of
`project/knowledge-graph/test-links.json`, as decision D5 (interactivity) of
[`project/documentation/test-architecture-linking-spike.md`](test-architecture-linking-spike.md) records.

| Deferred feature | What it would do | Stored field it would use |
|---|---|---|
| Clickable nodes | Clicking a covered node opens that node's test list. | `node_id` on every record; `readTestLinks()` already groups the records by it. |
| Per-type filters | Show only the nodes covered by unit, integration or e2e tests. | `type` on every record, a value from the `discover-tests.sh` vocabulary. |
| Jump to test code | Go from a covered node to the test's code. | `file` (repo-relative) and `line`, with `name` and `test_id` as fallback, and the `generated_from.tests` file hash to detect a stale line. |

Each one is tracked as an entry in `project/ideas.md` (they mention `E83`), not as a board item: no epic, story or task
exists for them. To promote one, run `j.brainstorm` on its idea entry; until then it stays an idea.
