// tests/lib-progress-bar.test.mjs - tests for the Node run bar and the after-task / after-story lines (E92_S08_T04)
//
// Run: node tests/lib-progress-bar.test.mjs   (tests/lib-progress-bar.bats wraps it so `j.test` discovers it)
//
// Covers: number parity of `cli.js bar` with scripts/render-progress-bar.sh for every fixture shape of
// tests/render-progress-bar.bats (ascii, colour never, numbers not glyphs), the default UTF-8 uncoloured output with
// LANG empty and a pipe, --color always, --charset ascii, Rejected handling, the narrow-terminal rules at 80, 60 and 40
// columns and a sweep, after-task story selection (the story, never the epic) and after-story, Swedish labels, the
// never-fail warnings (empty scope, unknown id, missing board-progress.sh), usage errors and the EPIPE exit code.
//
// No test framework: a plain runner on node's `assert`, TAP lines, exit code 1 when any test fails. Every fixture lives
// under a fresh temp directory; this repository's own project/ is never read or written.

import assert from "assert";
import { spawnSync } from "child_process";
import { copyFileSync, mkdirSync, mkdtempSync, writeFileSync } from "fs";
import fsModule from "fs";
import { tmpdir } from "os";
import { dirname, join, resolve } from "path";
import { fileURLToPath } from "url";

import { glyphsFor } from "../lib/progress/charset.js";
import { createPainter, stripAnsi } from "../lib/progress/color.js";
import { MIN_BAR_CELLS, allocateCells, isCells, isEachKey, isLevel, pickLevel, renderBarLine, validTotals } from "../lib/progress/bar.js";
import { run } from "../lib/progress/cli.js";
import { renderStoryLine } from "../lib/progress/lines.js";
import { loadLabels } from "../lib/progress/labels.js";
import { displayWidth } from "../lib/progress/width.js";

// fs.rmSync came in Node 14.14; the floor is 14.13.1 (package.json engines), where a named import of it fails to link and
// the whole file would not run. rmdirSync with recursive exists there (deprecated later, so it is only the fallback).
const removeTree = (d) =>
  typeof fsModule.rmSync === "function" ? fsModule.rmSync(d, { recursive: true, force: true }) : fsModule.rmdirSync(d, { recursive: true });

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const CLI = join(REPO, "lib", "progress", "cli.js");
const SCRIPTS = join(REPO, "scripts");
const ESC = "\u001b";

const tests = [];
const test = (name, fn) => tests.push({ name, fn });
const temps = [];
function tmp() {
  const d = mkdtempSync(join(tmpdir(), "jenga-progress-bar-"));
  temps.push(d);
  return d;
}

// ---------------------------------------------------------------------------
// fixtures: a board whose stories hold a chosen number of tasks per bucket
// ---------------------------------------------------------------------------

const STATUS = { done: "Passed", in_progress: "In Progress", failed: "Failed", pending: "Pending", rejected: "Rejected", unknown: "Bogus Status" };
const BUCKETS = Object.keys(STATUS);

/** spec = { E01_S01: { done: 8, in_progress: 1, ... }, ... }; the epic of every story is E01. */
function board(spec) {
  const root = tmp();
  mkdirSync(join(root, "project", "configs"), { recursive: true });
  for (const d of ["epics", "stories", "tasks"]) mkdirSync(join(root, "project", "board", d), { recursive: true });
  writeFileSync(join(root, "project", "configs", "workflow.json"), "{}\n");
  const file = (dir, id, body) => writeFileSync(join(root, "project", "board", dir, `${id}_x.md`), `---\nid: ${id}\n${body}title: "Fixture ${id}"\n---\n\n# ${id}\n`);
  file("epics", "E01", "status: In Progress\n");
  Object.keys(spec).forEach((story) => {
    file("stories", story, "epic_id: E01\nstatus: In Progress\n");
    let n = 0;
    BUCKETS.forEach((b) => {
      for (let i = 0; i < (spec[story][b] || 0); i++) {
        n++;
        file("tasks", `${story}_T${String(n).padStart(3, "0")}`, `story_id: ${story}\nepic_id: E01\nstatus: ${STATUS[b]}\n`);
      }
    });
  });
  return root;
}

function cli(args, opts) {
  const o = opts || {};
  const env = Object.assign({ PATH: process.env.PATH, HOME: process.env.HOME || tmpdir() }, o.env || {});
  if (o.root) env.JENGA_PROJECT_ROOT = o.root;
  const r = spawnSync(process.execPath, [CLI].concat(args), { env, cwd: o.cwd || tmpdir(), encoding: "buffer" });
  return { status: r.status, stdout: r.stdout, out: r.stdout.toString("utf8"), err: r.stderr.toString("utf8") };
}

/**
 * A scripts directory for JENGA_PROGRESS_SCRIPTS_DIR. Its progress-labels-json.sh serves the label tables read ONCE
 * from the real script (the real one forks per label and takes seconds, which would be paid by every CLI call of this
 * file); its board-progress.sh answers canned documents by argument string, or, with `real`, runs the real script.
 */
function stub(entries, real) {
  const dir = tmp();
  mkdirSync(join(dir, "stub"), { recursive: true });
  writeFileSync(join(dir, "labels-en.json"), JSON.stringify({ lang: "en", labels: EN }));
  writeFileSync(join(dir, "labels-sv.json"), JSON.stringify({ lang: "sv", labels: SV }));
  writeFileSync(
    join(dir, "progress-labels-json.sh"),
    ['#!/usr/bin/env bash', 'dir="$(cd "$(dirname "$0")" && pwd)"', 'case "${JENGA_PROGRESS_LANG:-en}" in sv) cat "$dir/labels-sv.json" ;; *) cat "$dir/labels-en.json" ;; esac', ""].join("\n")
  );
  const canned = [
    "#!/usr/bin/env bash",
    'dir="$(cd "$(dirname "$0")" && pwd)/stub"',
    "name=\"$(printf '%s' \"$*\" | tr -c 'A-Za-z0-9_.-' '_')\"",
    'if [ -f "$dir/$name.json" ]; then cat "$dir/$name.json"; exit 0; fi',
    'if [ -f "$dir/$name.exit" ]; then echo "board-progress.sh: $(cat "$dir/$name.msg")" >&2; exit "$(cat "$dir/$name.exit")"; fi',
    'echo "board-progress.sh: unknown id: $*" >&2; exit 2',
    "",
  ];
  writeFileSync(join(dir, "board-progress.sh"), real ? `#!/usr/bin/env bash\nexec bash "${SCRIPTS}/board-progress.sh" "$@"\n` : canned.join("\n"));
  Object.keys(entries || {}).forEach((key) => {
    const base = join(dir, "stub", key.replace(/[^A-Za-z0-9_.-]/g, "_"));
    const v = entries[key];
    if (v && v.exit) {
      writeFileSync(`${base}.exit`, String(v.exit));
      writeFileSync(`${base}.msg`, v.msg || "failed");
    } else {
      writeFileSync(`${base}.json`, JSON.stringify(v));
    }
  });
  return dir;
}

/** A board-progress document with one tasks level. */
const doc = (totals, id) => ({ schema_version: 1, scope: { type: "story", ids: [id || "E01_S01"] }, levels: { tasks: { counts: {}, totals } }, warnings: [] });
/** The `--graph` document of tasks: [[task id, story id], ...]. */
const graph = (pairs) => ({ schema_version: 1, scope: { type: "graph" }, epics: [], stories: [], tasks: pairs.map(([id, story_id]) => ({ id, story_id, epic_id: "E01" })), warnings: [] });

/** cli.js in-process against a stub scripts directory: { status, out, err }. Extra env entries are merged. */
function inProc(args, scriptsDir, env) {
  const out = [];
  const err = [];
  const status = run(args, {
    out: (x) => out.push(x),
    err: (x) => err.push(x),
    env: Object.assign({ PATH: process.env.PATH, JENGA_PROGRESS_SCRIPTS_DIR: scriptsDir }, env || {}),
    cwd: tmpdir(),
    isTTY: false,
  });
  return { status, out: out.join(""), err: err.join(""), stdout: Buffer.from(out.join(""), "utf8") };
}

/** The bash chain on the same board: board-progress.sh | render-progress-bar.sh (ascii glyphs, no colour, wide). */
function bash(root, scopeArgs, renderArgs) {
  const script = `bash "${SCRIPTS}/board-progress.sh" ${scopeArgs} | bash "${SCRIPTS}/render-progress-bar.sh" --cols 1000 --color never ${renderArgs || ""}`;
  const r = spawnSync("bash", ["-c", script], { env: { PATH: process.env.PATH, HOME: process.env.HOME || tmpdir(), LC_ALL: "C", JENGA_PROJECT_ROOT: root }, encoding: "utf8" });
  assert.strictEqual(r.status, 0, r.stderr);
  return r.stdout.replace(/\n$/, "");
}

const allAscii = (buf) => Array.from(buf).every((b) => b < 0x80);
const hasEsc = (text) => text.indexOf(ESC) >= 0;
const lines = (text) => text.split("\n").filter((l) => l !== "");
/** The integers of a line from its `done/denominator` on: the numbers, whatever the glyphs around them. */
function numbers(line) {
  const at = line.search(/[0-9]+\/[0-9]+/);
  assert.ok(at >= 0, `no n/total in: ${line}`);
  return line.slice(at).match(/[0-9]+/g).map(Number);
}

const EN = loadLabels({ lang: "en", cwd: tmpdir() }).labels;
const SV = loadLabels({ lang: "sv", cwd: tmpdir() }).labels;
const UTF = glyphsFor("utf8");
const ASC = glyphsFor("ascii");
const plainPainter = createPainter(false);
const colourPainter = createPainter(true);
const T = (done, prog, fail, pend, rej, unk, den) => ({ done, in_progress: prog, failed: fail, pending: pend, rejected: rej, unknown: unk, denominator: den });
const bar = (totals, over) => renderBarLine(totals, Object.assign({ glyphs: UTF, painter: plainPainter, labels: EN, width: 1000, cells: 10 }, over || {}));
const story = (totals, over) => renderStoryLine(totals, Object.assign({ id: "E01_S01", glyphs: UTF, painter: plainPainter, labels: EN, width: 80, ready: 0 }, over || {}));

// ---------------------------------------------------------------------------
// cell allocation (the port of the bash arithmetic)
// ---------------------------------------------------------------------------

test("allocateCells: the cells always sum to the width and a bar is full only when nothing is open", () => {
  for (let cells = 1; cells <= 24; cells++) {
    for (let d = 0; d <= 6; d++) for (let p = 0; p <= 4; p++) for (let f = 0; f <= 3; f++) for (let n = 0; n <= 5; n++) {
      const c = allocateCells([d, p, f, n], cells);
      assert.strictEqual(c.reduce((a, b) => a + b, 0), cells, `sum for ${[d, p, f, n]} at ${cells}`);
      assert.ok(c.every((x) => x >= 0));
      if (c[0] === cells) assert.ok(p + f + n === 0, `full bar with open work: ${[d, p, f, n]} at ${cells}`);
    }
  }
  assert.deepStrictEqual(allocateCells([0, 0, 0, 0], 7), [0, 0, 0, 7]);
});

test("allocateCells: 99 of 100 is never full and 1 of 100 still shows one filled cell, at any width", () => {
  for (let cells = 2; cells <= 60; cells++) {
    assert.ok(allocateCells([99, 0, 0, 1], cells)[0] < cells, `99/100 full at ${cells}`);
    assert.ok(allocateCells([1, 0, 0, 99], cells)[0] >= 1, `1/100 empty at ${cells}`);
  }
});

// ---------------------------------------------------------------------------
// parity of the numbers with the bash renderer, fixture by fixture
// ---------------------------------------------------------------------------

// The shapes of the fixtures of tests/render-progress-bar.bats: done, in progress, failed, pending, rejected, unknown.
const FIXTURES = {
  allpass: [10, 0, 0, 0, 0, 0],
  mixed: [8, 1, 1, 0, 0, 0],
  failures_only: [6, 0, 2, 2, 0, 0],
  rejections: [8, 1, 1, 0, 2, 0],
  all_rejected_extra: [4, 0, 0, 0, 3, 0],
  rejected_many: [3, 1, 1, 5, 9, 0],
  unknown_statuses: [5, 0, 0, 3, 0, 2],
  nothing_started: [0, 0, 0, 0, 0, 0],
  near_complete: [99, 0, 0, 1, 0, 0],
  barely_started: [1, 0, 0, 99, 0, 0],
  wide: [8, 1, 1, 0, 2, 3],
};

test("parity: every fixture shape of render-progress-bar.bats, drawn by `bar --each stories`, carries the numbers of `render-progress-bar.sh --each stories`", () => {
  const spec = {};
  Object.keys(FIXTURES).forEach((name, i) => {
    const id = `E01_S${String(i + 1).padStart(2, "0")}`;
    spec[id] = {};
    FIXTURES[name].forEach((n, k) => {
      spec[id][BUCKETS[k]] = n;
    });
  });
  const root = board(spec);
  const node = cli(["--charset", "ascii", "--color", "never", "--cols", "1000", "bar", "--each", "stories"], { root, env: { JENGA_PROGRESS_SCRIPTS_DIR: stub({}, true) } });
  assert.strictEqual(node.status, 0, node.err);
  assert.strictEqual(node.err, "");
  const expected = bash(root, "--by-parent", "--each stories");
  const rowsOf = (text) => lines(text).map((l) => l.split("\t"));
  const a = rowsOf(node.out);
  const b = rowsOf(expected);
  assert.deepStrictEqual(a.map((r) => r[0]), b.map((r) => r[0]));
  assert.strictEqual(a.length, Object.keys(FIXTURES).length);
  a.forEach((row, i) => assert.deepStrictEqual(numbers(row[1]), numbers(b[i][1]), `${row[0]}: node ${row[1]} bash ${b[i][1]}`));
  // the line of the Node bar has the bash bar's cell count (10) whatever the buckets. E92_S11_T01: the cells are now
  // # done, = in progress, x failed, - pending (in progress and failed were # before), so the leading run of cell glyphs
  // is counted instead of every # and - on the line (the text's " - " separators made up the difference before).
  a.forEach((row) => assert.strictEqual((row[1].match(/^[#=x-]+/) || [""])[0].length, 10, row[1]));
});

test("parity: the Swedish line carries the same numbers as the bash renderer in sv", () => {
  const root = board({ E01_S01: { done: 8, in_progress: 1, failed: 1, rejected: 2 } });
  const node = cli(["--charset", "ascii", "--color", "never", "--cols", "1000", "--lang", "sv", "bar", "--story", "E01_S01"], { root, env: { JENGA_PROGRESS_SCRIPTS_DIR: stub({}, true) } });
  const sv = spawnSync("bash", ["-c", `bash "${SCRIPTS}/board-progress.sh" --story E01_S01 | bash "${SCRIPTS}/render-progress-bar.sh" --cols 1000`], {
    env: { PATH: process.env.PATH, LC_ALL: "C", JENGA_PROGRESS_LANG: "sv", JENGA_PROJECT_ROOT: root }, encoding: "utf8",
  });
  assert.deepStrictEqual(numbers(node.out.trim()), numbers(sv.stdout.trim()));
  assert.ok(node.out.indexOf(SV.in_progress) > 0 && node.out.indexOf(SV.failed) > 0, node.out);
});

test("parity: --level stories (an epic scope) and --level epics (the whole board) read the levels of the same document", () => {
  const root = board({ E01_S01: { done: 2 }, E01_S02: { pending: 3 } });
  const real = { root, env: { JENGA_PROGRESS_SCRIPTS_DIR: stub({}, true) } };
  const stories = cli(["--charset", "ascii", "--color", "never", "--cols", "1000", "bar", "--epic", "E01", "--level", "stories"], real);
  assert.deepStrictEqual(numbers(stories.out.trim()), numbers(bash(root, "--epic E01", "--level stories")));
  const epics = cli(["--charset", "ascii", "--color", "never", "--cols", "1000", "bar", "--all", "--level", "epics"], real);
  assert.deepStrictEqual(numbers(epics.out.trim()), numbers(bash(root, "--all", "--level epics")));
});

test("--each stories prints id<TAB>line per story in input order, each equal to the single bar of that story; --each epics too", () => {
  const dir = stub({
    "--by-parent": { schema_version: 1, scope: { type: "by-parent" }, epics: [{ id: "E01", level: "stories", totals: T(1, 0, 0, 1, 0, 0, 2) }], stories: [{ id: "E01_S01", level: "tasks", totals: T(3, 0, 1, 0, 0, 0, 4) }, { id: "E01_S02", level: "tasks", totals: T(0, 0, 0, 2, 1, 0, 2) }], warnings: [] },
    "--story E01_S01": doc(T(3, 0, 1, 0, 0, 0, 4), "E01_S01"),
    "--story E01_S02": doc(T(0, 0, 0, 2, 1, 0, 2), "E01_S02"),
  });
  const each = inProc(["--charset", "ascii", "--color", "never", "bar", "--each", "stories"], dir);
  assert.strictEqual(each.status, 0, each.err);
  const rows = lines(each.out).map((l) => l.split("\t"));
  assert.deepStrictEqual(rows.map((r) => r[0]), ["E01_S01", "E01_S02"]);
  rows.forEach(([id, line]) => assert.strictEqual(line, inProc(["--charset", "ascii", "--color", "never", "bar", "--story", id], dir).out.trim(), id));
  const epics = inProc(["--charset", "ascii", "--color", "never", "bar", "--each", "epics"], dir);
  assert.deepStrictEqual(lines(epics.out).map((l) => l.split("\t")[0]), ["E01"]);
});

test("bar with no scope asks for --all; bare ids and --ids are an --ids scope; --epic and --backlog pass through", () => {
  const dir = stub({
    "--all": doc(T(1, 0, 0, 1, 0, 0, 2)),
    "--ids E01_S01_T001,E01_S01_T002": doc(T(2, 0, 0, 0, 0, 0, 2)),
    "--epic E01": doc(T(3, 0, 0, 0, 0, 0, 3)),
    "--backlog": doc(T(4, 0, 0, 0, 0, 0, 4)),
  });
  const n = (args) => numbers(inProc(["--color", "never", "bar"].concat(args), dir).out.trim()).slice(0, 2);
  assert.deepStrictEqual(n([]), [1, 2]);
  assert.deepStrictEqual(n(["E01_S01_T001,E01_S01_T002"]), [2, 2]);
  assert.deepStrictEqual(n(["--ids", "E01_S01_T001,E01_S01_T002"]), [2, 2]);
  assert.deepStrictEqual(n(["--epic", "E01"]), [3, 3]);
  assert.deepStrictEqual(n(["--backlog"]), [4, 4]);
});

// ---------------------------------------------------------------------------
// defaults, charset, colour
// ---------------------------------------------------------------------------

test("default output (LANG and LC_ALL empty, stdout a pipe, no flags) is UTF-8, hatched and uncoloured", () => {
  const dir = stub({ "--story E01_S01": doc(T(8, 1, 1, 0, 0, 0, 10)) });
  const r = cli(["bar", "--story", "E01_S01"], { env: { LANG: "", LC_ALL: "", JENGA_PROGRESS_SCRIPTS_DIR: dir } });
  assert.strictEqual(r.status, 0, r.err);
  // E92_S11_T01: the in-progress cell is runInProgress (▒) and the failed cell cross (✕); both were runFull (▰) before
  assert.strictEqual(r.out, `${UTF.runFull.repeat(8)}${UTF.runInProgress}${UTF.cross}${UTF.flag} 8/10 ${UTF.sep} 1 ${EN.in_progress} ${UTF.sep} 1 ${EN.failed}\n`);
  assert.ok(!hasEsc(r.out), "colour on a pipe");
  assert.ok(!allAscii(r.stdout), "no UTF-8 glyph written");
});

test("--charset ascii is pure ASCII for bar, after-task and after-story", () => {
  const dir = stub({ "--story E01_S01": doc(T(3, 1, 1, 2, 2, 0, 7)), "--graph": graph([["E01_S01_T001", "E01_S01"]]) });
  for (const args of [["bar", "--story", "E01_S01"], ["after-task", "--task", "E01_S01_T001"], ["after-story", "--story", "E01_S01", "--ready", "2"]]) {
    for (const color of ["never", "always"]) {
      const r = inProc(["--charset", "ascii", "--color", color].concat(args), dir, { LANG: "", LC_ALL: "" });
      assert.strictEqual(r.status, 0, r.err);
      assert.ok(r.out.length > 0);
      assert.ok(allAscii(r.stdout), `${args[0]} ${color}: ${JSON.stringify(r.out)}`);
    }
  }
  const utf = inProc(["--charset", "utf8", "after-story", "--story", "E01_S01"], dir);
  assert.ok(!allAscii(utf.stdout));
});

test("--color always colours with the E92 decision 2 colours; stripping the colour gives the uncoloured line", () => {
  const t = T(5, 2, 1, 3, 0, 0, 11);
  const coloured = bar(t, { painter: colourPainter });
  assert.ok(new RegExp(`\\u001b\\[32m${UTF.runFull}+\\u001b\\[0m`).test(coloured), "done is green");
  assert.ok(coloured.indexOf(`${ESC}[33m`) >= 0, "in progress is yellow");
  assert.ok(coloured.indexOf(`${ESC}[31m`) >= 0, "failed is red");
  assert.ok(coloured.indexOf(`${ESC}[90m`) >= 0, "pending is grey");
  assert.strictEqual(stripAnsi(coloured), bar(t));
  const dir = stub({ "--story E01_S01": doc(t) });
  const r = inProc(["--color", "always", "bar", "--story", "E01_S01"], dir);
  assert.ok(hasEsc(r.out) && r.out.indexOf(`${ESC}[32m`) >= 0);
  const never = inProc(["--color", "never", "bar", "--story", "E01_S01"], dir);
  assert.strictEqual(stripAnsi(r.out), never.out);
  assert.ok(!hasEsc(inProc(["bar", "--story", "E01_S01"], dir).out), "auto colour is off on a pipe");
  assert.ok(!hasEsc(inProc(["bar", "--story", "E01_S01"], dir, { NO_COLOR: "1" }).out));
});

// E92_S11_T01 (user decision 2026-11-15): every state has its own cell, so the bar reads the same with colour off.
test("E92_S11_T01: with colour off, 3 done, 1 in progress, 1 failed, 1 pending draws ▰▰▰▒✕▱ in utf8 and ###=x- in ascii", () => {
  const t = T(3, 1, 1, 1, 0, 0, 6);
  assert.strictEqual(bar(t, { cells: 6 }).split(UTF.flag)[0], "▰▰▰▒✕▱");
  assert.strictEqual(bar(t, { cells: 6, glyphs: ASC }).split(ASC.flag)[0], "###=x-");
  // the same through the cli, --color never, both charsets
  const dir = stub({ "--story E01_S01": doc(t) });
  const utf = inProc(["--charset", "utf8", "--color", "never", "bar", "--story", "E01_S01", "--cells", "6"], dir);
  const asc = inProc(["--charset", "ascii", "--color", "never", "bar", "--story", "E01_S01", "--cells", "6"], dir);
  assert.strictEqual(utf.status, 0, utf.err);
  assert.strictEqual(asc.status, 0, asc.err);
  assert.strictEqual(utf.out.indexOf(`▰▰▰▒✕▱${UTF.flag} 3/6 `), 0, utf.out);
  assert.strictEqual(asc.out.indexOf(`###=x-${ASC.flag} 3/6 `), 0, asc.out);
  assert.ok(!hasEsc(utf.out) && !hasEsc(asc.out));
});

test("E92_S11_T01: in-progress and failed cells differ from done (and from each other and pending) with colour never, in both charsets; colours are unchanged", () => {
  for (const g of [UTF, ASC]) {
    const cells = [g.runFull, g.runInProgress, g.cross, g.runEmpty];
    assert.strictEqual(new Set(cells).size, 4, `cell glyphs not distinct: ${cells.join(" ")}`);
    // one done task plus four of one other state: the done cell is runFull, the other four cells that state's own glyph
    const only = (k) => {
      const b = [1, 0, 0, 0];
      b[k] = 4;
      return bar(T(b[0], b[1], b[2], b[3], 0, 0, 5), { cells: 5, glyphs: g }).split(g.flag)[0];
    };
    assert.strictEqual(only(1), g.runFull + g.runInProgress.repeat(4));
    assert.strictEqual(only(2), g.runFull + g.cross.repeat(4));
    assert.strictEqual(only(3), g.runFull + g.runEmpty.repeat(4));
  }
  assert.strictEqual(UTF.runInProgress, "▒");
  assert.strictEqual(ASC.runInProgress, "=");
  assert.strictEqual(UTF.cross, "✕");
  assert.strictEqual(ASC.cross, "x");
  // colour on: each state's own glyph in its own colour (done green, in progress yellow, failed red, pending grey)
  const coloured = bar(T(3, 1, 1, 1, 0, 0, 6), { cells: 6, painter: colourPainter });
  assert.ok(coloured.indexOf(`${ESC}[32m▰▰▰${ESC}[0m${ESC}[33m▒${ESC}[0m${ESC}[31m✕${ESC}[0m${ESC}[90m▱${ESC}[0m`) === 0, JSON.stringify(coloured));
});

test("--color always: an empty bucket writes no escape, and every run is closed", () => {
  const coloured = bar(T(4, 0, 0, 0, 0, 0, 4), { painter: colourPainter });
  assert.ok(coloured.indexOf(`${ESC}[33m`) < 0 && coloured.indexOf(`${ESC}[31m`) < 0 && coloured.indexOf(`${ESC}[90m`) < 0);
  const opens = (coloured.match(/\u001b\[(?!0m)[0-9;]+m/g) || []).length;
  const closes = (coloured.match(/\u001b\[0m/g) || []).length;
  assert.strictEqual(opens, closes);
});

test("the goal mark: a star only when everything counted is done, a flag while work remains, none for 0/0", () => {
  assert.ok(bar(T(4, 0, 0, 0, 3, 0, 4)).indexOf(`${UTF.star} 4/4`) > 0);
  assert.ok(bar(T(3, 1, 0, 0, 0, 0, 4)).indexOf(`${UTF.flag} 3/4`) > 0);
  assert.ok(bar(T(3, 0, 1, 0, 0, 0, 4)).indexOf(UTF.star) < 0);
  const none = bar(T(0, 0, 0, 0, 0, 0, 0));
  assert.strictEqual(none, `${UTF.runEmpty.repeat(10)} 0/0 ${UTF.sep} ${EN.nothing}`);
  assert.strictEqual(bar(T(0, 0, 0, 0, 0, 0, 0), { labels: SV }).slice(-SV.nothing.length), SV.nothing);
});

// ---------------------------------------------------------------------------
// Rejected
// ---------------------------------------------------------------------------

test("Rejected never counts toward the denominator and is a note with the label of the table and its own glyph", () => {
  const dir = stub({ "--story E01_S01": doc(T(4, 0, 0, 0, 3, 0, 4)) });
  const r = inProc(["--color", "never", "bar", "--story", "E01_S01"], dir);
  assert.ok(r.out.indexOf(" 4/4 ") > 0, r.out);
  assert.ok(r.out.indexOf(`${UTF.rejected} 3 ${EN.rejected_note.replace(/^\S+ %d /, "")}`) > 0, r.out);
  const sv = inProc(["--color", "never", "--lang", "sv", "bar", "--story", "E01_S01"], dir);
  assert.ok(sv.out.indexOf(SV.rejected_note.replace("%d", "3")) > 0, sv.out);
  const asc = inProc(["--color", "never", "--charset", "ascii", "bar", "--story", "E01_S01"], dir);
  assert.ok(asc.out.indexOf(`${ASC.rejected} 3 `) > 0 && allAscii(asc.stdout), asc.out);
});

test("Rejected is never drawn: the bar is the same whatever the rejected count", () => {
  const cut = (line) => line.slice(0, line.search(/ [0-9]+\/[0-9]+/));
  assert.strictEqual(cut(bar(T(3, 1, 1, 5, 0, 0, 10))), cut(bar(T(3, 1, 1, 5, 99, 0, 10))));
});

test("in colour the rejected note is neither green, yellow, red nor grey; the after-story line colours it the same", () => {
  const rejected = `${ESC}[38;5;67m`;
  const note = bar(T(2, 0, 0, 0, 5, 0, 2), { painter: colourPainter });
  const run = note.slice(note.indexOf(rejected));
  assert.ok(note.indexOf(rejected) > 0 && run.indexOf(`${UTF.rejected} 5 `) > 0, note);
  assert.ok(!/\u001b\[(32|33|31|90)m/.test(run), run);
  const sl = story(T(2, 0, 0, 0, 5, 0, 2), { painter: colourPainter });
  assert.ok(sl.indexOf(`${rejected}${UTF.rejected} 5 ${EN.sl_rejected}${ESC}[0m`) > 0, sl);
});

// ---------------------------------------------------------------------------
// narrow terminals
// ---------------------------------------------------------------------------

const WIDE = T(8, 1, 1, 0, 2, 3, 10);

test("width 80, 60 and 40: no line is wider than the width, with colour on and off, through the CLI", () => {
  const dir = stub({ "--story E01_S01": doc(T(8, 1, 1, 0, 2, 3, 10)), "--graph": graph([["E01_S01_T001", "E01_S01"]]) });
  for (const w of [80, 60, 40]) {
    for (const color of ["never", "always"]) {
      for (const args of [["bar", "--story", "E01_S01"], ["after-task", "--task", "E01_S01_T001"], ["after-story", "--story", "E01_S01", "--ready", "2"]]) {
        const r = inProc(["--cols", String(w), "--color", color].concat(args), dir);
        assert.strictEqual(r.status, 0, r.err);
        assert.ok(lines(r.out).length >= 1);
        lines(r.out).forEach((l) => assert.ok(displayWidth(l) <= w, `${args[0]} at ${w} ${color}: ${displayWidth(l)} cells: ${stripAnsi(l)}`));
      }
    }
  }
  // COLUMNS is honoured when --cols is absent
  const viaEnv = inProc(["--color", "never", "bar", "--story", "E01_S01"], dir, { COLUMNS: "40" });
  assert.ok(displayWidth(viaEnv.out.trim()) <= 40);
});

test("width sweep 1..130: no run-bar, after-task or story line is wider than the width, colour on and off", () => {
  for (let w = 1; w <= 130; w++) {
    for (const painter of [plainPainter, colourPainter]) {
      for (const t of [WIDE, T(0, 0, 0, 0, 0, 0, 0), T(10, 0, 0, 0, 0, 0, 10), T(99, 0, 0, 1, 0, 0, 100)]) {
        const over = { width: w, painter };
        assert.ok(displayWidth(bar(t, over)) <= w, `bar at ${w}`);
        assert.ok(displayWidth(bar(t, Object.assign({ id: "E92_S06" }, over))) <= w, `bar with id at ${w}`);
        story(t, Object.assign({ ready: 4 }, over)).split("\n").forEach((l) => assert.ok(displayWidth(l) <= w, `story at ${w}: ${stripAnsi(l)}`));
      }
    }
  }
});

test("the bar drops cells before the text is cut: the whole text is intact whenever a bar is drawn, and it shrinks to the room", () => {
  const full = "8/10 · 1 in progress · 1 red · 3 unknown · ⊘ 2 rejected (not counted)";
  assert.strictEqual(bar(WIDE).slice(bar(WIDE).indexOf("8/10")), full);
  let sawShrunk = false;
  for (let w = 1; w <= 130; w++) {
    const line = bar(WIDE, { width: w });
    const drawn = line.indexOf(UTF.runFull) >= 0 || line.indexOf(UTF.runEmpty) >= 0;
    if (drawn) {
      assert.ok(line.endsWith(full), `text cut while a bar is drawn at ${w}: ${line}`);
      const cells = Array.from(line.slice(0, line.indexOf(UTF.flag))).length;
      assert.ok(cells >= MIN_BAR_CELLS && cells <= 10);
      if (cells < 10) sawShrunk = true;
    }
  }
  assert.ok(sawShrunk, "the bar never shrank");
  // the boundary: the room just fits MIN_BAR_CELLS cells, and one column less drops the bar
  const textW = displayWidth(full);
  assert.strictEqual(Array.from(bar(WIDE, { width: textW + 1 + 1 + MIN_BAR_CELLS }).split(UTF.flag)[0]).length, MIN_BAR_CELLS);
  assert.ok(bar(WIDE, { width: textW + 1 + 1 + MIN_BAR_CELLS - 1 }).indexOf(UTF.runFull) < 0);
});

test("segments drop in the order unknown, rejected note, in progress; done/denominator and failed stay", () => {
  const texts = [
    "8/10 · 1 in progress · 1 red · 3 unknown · ⊘ 2 rejected (not counted)",
    "8/10 · 1 in progress · 1 red · ⊘ 2 rejected (not counted)",
    "8/10 · 1 in progress · 1 red",
    "8/10 · 1 red",
  ];
  texts.forEach((text) => assert.strictEqual(bar(WIDE, { width: displayWidth(text) }), text));
  for (let i = 0; i < 3; i++) assert.strictEqual(bar(WIDE, { width: displayWidth(texts[i]) - 1 }), texts[i + 1]);
});

test("hard truncation keeps the start, ends with one ellipsis and trims a dangling separator; ASCII ends in a tilde", () => {
  const t = T(8, 1, 1, 0, 2, 0, 10);
  assert.strictEqual(bar(t, { width: 11 }), "8/10 · 1 r…");
  assert.strictEqual(bar(t, { width: 8 }), "8/10…");
  assert.strictEqual(bar(t, { width: 9 }), "8/10 · 1…");
  assert.strictEqual(bar(t, { width: 1 }), UTF.ellipsis);
  assert.strictEqual(bar(t, { width: 8, glyphs: ASC }), `8/10${ASC.ellipsis}`);
  assert.strictEqual(ASC.ellipsis, "~");
});

test("--cells sets the largest bar and an explicit value below the minimum that fits is kept", () => {
  assert.strictEqual(Array.from(bar(T(5, 0, 0, 5, 0, 0, 10), { cells: 20 }).split(" ")[0]).length, 21);
  assert.strictEqual(Array.from(bar(T(5, 0, 0, 5, 0, 0, 10), { cells: 2 }).split(" ")[0]).length, 3);
  const dir = stub({ "--story E01_S01": doc(T(5, 0, 0, 5, 0, 0, 10)) });
  const r = inProc(["--color", "never", "bar", "--story", "E01_S01", "--cells", "20"], dir);
  assert.strictEqual(Array.from(r.out.split(" ")[0]).length, 21);
});

test("the story line: 8..30 cells, text-only under 40 columns, counts wrap under the bar and are never cut", () => {
  const t = T(3, 1, 1, 5, 2, 0, 10);
  const wide = story(t, { width: 200, ready: 2 });
  assert.strictEqual(wide.split("\n").length, 1);
  // E92_S11_T01: in-progress (runInProgress) and failed (cross) cells have their own glyphs now, so they are counted too
  const cellGlyphs = [UTF.runFull, UTF.runInProgress, UTF.cross, UTF.runEmpty];
  assert.strictEqual(Array.from(wide.split("  ")[1].split(UTF.flag)[0]).filter((c) => cellGlyphs.indexOf(c) >= 0).length, 30);
  assert.strictEqual(story(t, { width: 39 }), "E01_S01 3/10 · 30 %");
  const wrapped = story(t, { width: 40, ready: 2 }).split("\n");
  assert.ok(wrapped.length > 1);
  assert.ok(wrapped.slice(1).every((l) => l.indexOf("         ") === 0), wrapped.join("\n"));
  const all = wrapped.join(" ");
  [`${UTF.head} 1 ${EN.in_progress}`, `${UTF.cross} 1 ${EN.sl_failed_one}`, `${UTF.ready} 2 ${EN.sl_ready}`, `${UTF.rejected} 2 ${EN.sl_rejected}`].forEach((x) => assert.ok(all.indexOf(x) >= 0, x));
});

// ---------------------------------------------------------------------------
// after-task and after-story
// ---------------------------------------------------------------------------

test("after-task shows the story of the finished task, never its epic; one line per distinct story, first-seen order", () => {
  const dir = stub({
    "--graph": graph([["E01_S01_T001", "E01_S01"], ["E01_S01_T002", "E01_S01"], ["E01_S02_T001", "E01_S02"], ["E01_S03_T001", "E01_S03"]]),
    "--story E01_S01": doc(T(2, 0, 0, 2, 0, 0, 4)),
    "--story E01_S02": doc(T(1, 0, 0, 0, 0, 0, 1)),
    "--story E01_S03": doc(T(0, 0, 1, 1, 0, 0, 2)),
    "--epic E01": doc(T(3, 0, 1, 3, 0, 0, 7)),
  });
  const one = inProc(["--color", "never", "after-task", "--task", "E01_S01_T001"], dir);
  assert.strictEqual(one.status, 0, one.err);
  assert.strictEqual(lines(one.out).length, 1);
  assert.ok(one.out.indexOf("E01_S01  ") === 0, one.out);
  assert.deepStrictEqual(numbers(one.out.trim()).slice(0, 2), [2, 4], "the numbers are the story's, not the epic's");
  // a wave: two tasks of S01, one of S03 and one of S02 -> three lines, S01 first
  const wave = inProc(["--color", "never", "after-task", "--task", "E01_S01_T001,E01_S03_T001, E01_S01_T002,E01_S02_T001"], dir);
  assert.deepStrictEqual(lines(wave.out).map((l) => l.split("  ")[0]), ["E01_S01", "E01_S03", "E01_S02"]);
  const bare = inProc(["--color", "never", "after-task", "E01_S02_T001"], dir);
  assert.strictEqual(bare.out.split("  ")[0], "E01_S02");
  const byStory = inProc(["--color", "never", "after-task", "--story", "E01_S03"], dir);
  assert.strictEqual(byStory.out.split("  ")[0], "E01_S03");
  // the epic id is never printed as the scope and the epic's totals never drawn
  [one.out, wave.out].forEach((o) => assert.ok(!/^E01 /m.test(o) && o.indexOf("3/7") < 0));
});

test("after-task: a width-padded id (E1_S1_T1) resolves to its story", () => {
  const dir = stub({ "--graph": graph([["E01_S01_T001", "E01_S01"]]), "--story E01_S01": doc(T(1, 0, 0, 1, 0, 0, 2)) });
  const r = inProc(["--color", "never", "after-task", "--task", "E1_S1_T1"], dir);
  assert.strictEqual(r.status, 0, r.err);
  assert.strictEqual(r.out.split("  ")[0], "E01_S01");
});

test("after-story draws the story line in the same hatched style: id, bar, star, n/total, percent", () => {
  const dir = stub({ "--story E01_S01": doc(T(4, 0, 0, 0, 0, 0, 4)), "--story E01_S02": doc(T(3, 0, 1, 0, 0, 0, 4)) });
  const r = inProc(["--color", "never", "after-story", "--story", "E01_S01,E01_S02"], dir);
  assert.strictEqual(r.status, 0, r.err);
  const [a, b] = lines(r.out);
  assert.strictEqual(a, `E01_S01  ${UTF.runFull.repeat(30)}${UTF.star} 4/4 ${UTF.sep} 100 %`);
  // E92_S11_T01: the failed task's cells are cross (✕) cells, not runFull (▰): 3 of 4 done gives 22 done and 8 failed cells
  assert.strictEqual(b.indexOf(`E01_S02  ${UTF.runFull.repeat(22)}${UTF.cross.repeat(8)}${UTF.star} 3/4 ${UTF.sep} 75 %`), 0, b);
  assert.ok(b.indexOf(`${UTF.cross} 1 ${EN.sl_failed_one}`) > 0, b);
  // a story finished with a failure ends in a red star, a fully done one in a green star
  const coloured = inProc(["--color", "always", "after-story", "--story", "E01_S01,E01_S02"], dir);
  assert.ok(coloured.out.indexOf(`${ESC}[32m${UTF.star}`) >= 0 && coloured.out.indexOf(`${ESC}[31m${UTF.star}`) >= 0);
  assert.ok(lines(r.out).every((l) => displayWidth(l) <= 80));
});

test("after-task and after-story read their words from the label table: English by default, Swedish with JENGA_PROGRESS_LANG=sv", () => {
  const dir = stub({ "--story E01_S01": doc(T(2, 1, 2, 0, 1, 0, 5)), "--graph": graph([["E01_S01_T001", "E01_S01"]]) });
  const en = inProc(["--color", "never", "after-task", "--task", "E01_S01_T001"], dir);
  assert.ok(en.out.indexOf(EN.in_progress) > 0 && en.out.indexOf(EN.failed) > 0, en.out);
  const sv = inProc(["--color", "never", "after-task", "--task", "E01_S01_T001"], dir, { JENGA_PROGRESS_LANG: "sv" });
  assert.ok(sv.out.indexOf(SV.in_progress) > 0 && sv.out.indexOf(SV.failed) > 0 && sv.out.indexOf(EN.in_progress) < 0, sv.out);
  const svFlag = inProc(["--color", "never", "--lang", "sv", "after-task", "--task", "E01_S01_T001"], dir);
  assert.strictEqual(svFlag.out, sv.out);
  const storyEn = inProc(["--color", "never", "after-story", "--story", "E01_S01", "--ready", "1"], dir);
  assert.ok(storyEn.out.indexOf(EN.sl_failed_many) > 0 && storyEn.out.indexOf(EN.sl_ready) > 0 && storyEn.out.indexOf(EN.sl_rejected) > 0, storyEn.out);
  const storySv = inProc(["--color", "never", "after-story", "--story", "E01_S01", "--ready", "1"], dir, { JENGA_PROGRESS_LANG: "sv" });
  assert.ok(storySv.out.indexOf(SV.sl_failed_many) > 0 && storySv.out.indexOf(SV.sl_ready) > 0 && storySv.out.indexOf(SV.sl_rejected) > 0, storySv.out);
});

// ---------------------------------------------------------------------------
// the never-fail rule and usage errors
// ---------------------------------------------------------------------------

function assertWarning(r, what) {
  assert.strictEqual(r.status, 0, `${what}: exit ${r.status}`);
  assert.strictEqual(r.out, "", `${what}: stdout not empty: ${r.out}`);
  const errLines = lines(r.err);
  assert.strictEqual(errLines.length, 1, `${what}: stderr lines: ${r.err}`);
  assert.ok(errLines[0].indexOf("cli.js: warning: ") === 0, `${what}: ${errLines[0]}`);
}

test("an empty scope prints one warning on stderr, nothing on stdout, and exits 0", () => {
  const dir = stub({ "--story E01_S02": { exit: 3, msg: "empty scope: story E01_S02 has no tasks" } });
  assertWarning(inProc(["bar", "--story", "E01_S02"], dir), "bar");
  assertWarning(inProc(["after-task", "--story", "E01_S02"], dir), "after-task");
  assertWarning(inProc(["after-story", "--story", "E01_S02"], dir), "after-story");
});

test("an unknown id prints one warning on stderr, nothing on stdout, and exits 0 (a bad id among good ones prints nothing at all)", () => {
  const dir = stub({ "--story E01_S01": doc(T(1, 0, 0, 0, 0, 0, 1)), "--graph": graph([["E01_S01_T001", "E01_S01"]]) });
  assertWarning(inProc(["bar", "--story", "E99_S99"], dir), "bar story");
  assertWarning(inProc(["bar", "--epic", "E99"], dir), "bar epic");
  assertWarning(inProc(["after-task", "--task", "E99_S99_T99"], dir), "after-task unknown task");
  assertWarning(inProc(["after-task", "--task", "E01_S01_T001,E01_S01_T099"], dir), "after-task one bad of two");
  assertWarning(inProc(["after-task", "--task", "not-an-id"], dir), "after-task malformed");
  assertWarning(inProc(["after-story", "--story", "E99_S99"], dir), "after-story unknown");
  assertWarning(inProc(["after-story", "--story", "E01_S01,E99_S99"], dir), "after-story one bad of two");
  assertWarning(inProc(["bar", "--story", "E01_S01", "--level", "epics"], dir), "a level the document lacks");
});

test("a missing board-progress.sh prints one warning on stderr, nothing on stdout, and exits 0", () => {
  const empty = tmp();
  assertWarning(inProc(["bar", "--story", "E01_S01"], empty), "bar");
  assertWarning(inProc(["after-task", "--task", "E01_S01_T001"], empty), "after-task");
  assertWarning(inProc(["after-story", "--story", "E01_S01"], empty), "after-story");
});

test("usage errors exit 2 with nothing on stdout: a bad flag value, a conflicting flag, a missing id, two scopes", () => {
  const dir = stub({});
  for (const args of [
    ["bar", "--level", "weeks"], ["bar", "--cells", "0"], ["bar", "--cells", "501"], ["bar", "--each", "tasks"],
    ["bar", "--each", "stories", "--level", "stories"], ["bar", "--each", "stories", "--story", "E01_S01"],
    ["bar", "--epic", "E01", "--story", "E01_S01"], ["after-task"], ["after-story"], ["after-story", "--ready", "x"], ["after-task", "--cells", "0"],
  ]) {
    const r = inProc(args, dir);
    assert.strictEqual(r.status, 2, `${args.join(" ")}: ${r.status}`);
    assert.strictEqual(r.out, "", args.join(" "));
    assert.ok(r.err.indexOf("cli.js:") === 0, r.err);
  }
});

test("the validators and pickLevel: level names, --each keys, cells, totals, default level order", () => {
  assert.ok(isLevel("stories") && !isLevel("story") && !isLevel(""));
  assert.ok(isEachKey("epics") && !isEachKey("tasks"));
  assert.ok(isCells("1") && isCells("500") && !isCells("0") && !isCells("501") && !isCells("x") && !isCells("1.5"));
  assert.ok(validTotals(T(1, 0, 0, 0, 0, 0, 1)) && !validTotals(T(-1, 0, 0, 0, 0, 0, 1)) && !validTotals({}) && !validTotals(null) && !validTotals(T(1.5, 0, 0, 0, 0, 0, 1)));
  const doc = { levels: { stories: { totals: T(1, 0, 0, 0, 0, 0, 1) }, epics: { totals: T(2, 0, 0, 0, 0, 0, 2) } } };
  assert.strictEqual(pickLevel(doc, "").totals.done, 1, "without tasks the first present level is used");
  assert.strictEqual(pickLevel(doc, "epics").totals.done, 2);
  assert.strictEqual(pickLevel(doc, "tasks").ok, false, "a named level that is absent is a problem");
  assert.strictEqual(pickLevel({}, "").ok, false);
  assert.strictEqual(pickLevel({ levels: { tasks: { totals: { done: "x" } } } }, "").ok, false);
});

// ---------------------------------------------------------------------------
// EPIPE
// ---------------------------------------------------------------------------

test("a reader that closes the pipe early does not make cli.js exit 1: EPIPE on stdout is ignored (exit 0)", () => {
  for (const cmd of ["info", "labels"]) {
    // `| true` exits at once, long before node has started, so the first write hits a closed pipe; pipefail reports node's status
    const r = spawnSync("bash", ["-c", `set -o pipefail; "${process.execPath}" "${CLI}" ${cmd} | true; echo "status=$?"`], {
      env: { PATH: process.env.PATH, HOME: process.env.HOME || tmpdir() }, encoding: "utf8",
    });
    assert.strictEqual(r.stdout.trim(), "status=0", `${cmd}: ${r.stdout} ${r.stderr}`);
    assert.ok(r.stderr.indexOf("EPIPE") < 0, `${cmd}: EPIPE leaked: ${r.stderr}`);
  }
});

// ---------------------------------------------------------------------------
// the module set
// ---------------------------------------------------------------------------

test("the commands are registered in cli.js and listed in its usage", () => {
  const r = cli(["--help"]);
  assert.strictEqual(r.status, 0);
  for (const name of ["bar", "after-task", "after-story"]) assert.ok(new RegExp(`^  ${name} `, "m").test(r.out), `${name} missing from the usage`);
});

// ---------------------------------------------------------------------------
// run
// ---------------------------------------------------------------------------

let failed = 0;
console.log(`TAP version 13\n1..${tests.length}`);
tests.forEach((t, i) => {
  const started = Date.now();
  try {
    t.fn();
    console.log(`ok ${i + 1} - ${t.name}`);
    if (process.env.PROGRESS_TEST_TIMING) console.error(`# ${Date.now() - started} ms: ${t.name}`);
  } catch (e) {
    failed++;
    console.log(`not ok ${i + 1} - ${t.name}`);
    String(e && e.stack ? e.stack : e).split("\n").slice(0, 8).forEach((l) => console.log(`# ${l}`));
  }
});
temps.forEach((d) => {
  try {
    removeTree(d);
  } catch (e) {
    /* leave it to the OS */
  }
});
process.exitCode = failed > 0 ? 1 : 0;
