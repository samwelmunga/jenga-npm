// tests/lib-progress-overview-scope.test.mjs - tests for the Node overview and scope views (E92_S08_T05)
//
// Run: node tests/lib-progress-overview-scope.test.mjs   (tests/lib-progress-overview-scope.bats wraps it so `j.test` discovers it)
//
// Covers: widths 80, 60 and 40 (no line wider than the width, ANSI stripped) for a wide fixture with a five-column chain; the
// three layouts (horizontal truncates with the ellipsis and never changes the row count, vertical draws indented trees, auto keeps
// a band that fits horizontal and turns only the overflowing one vertical, on one fixture holding both); the milestone line against
// render-status-scope-view.sh (stop markers, message, "Ready to take") and the overview against render-status-overview.sh (numbers);
// the terminal tree against the dashboard tree built from the same payload; folding; the epic with no dependency edge; charset,
// colour and language; id forms; the never-fail warnings and the usage errors. E92_S10_T03: every arrow of a band is a real
// dependency edge and every incoming edge is shown as an arrow or a reference, on generated bands with a folded group, in both
// layouts and charsets, with the width and auto rules holding.
//
// No test framework: a plain runner on node's `assert`, TAP lines, exit code 1 when any test fails. Every fixture lives under a fresh
// temp directory; this repository's own project/ is never read or written.

import assert from "assert";
import { spawnSync } from "child_process";
import { existsSync, mkdirSync, mkdtempSync, writeFileSync } from "fs";
import fsModule from "fs";
import { tmpdir } from "os";
import { dirname, join, resolve } from "path";
import { fileURLToPath, pathToFileURL } from "url";

import { run } from "../lib/progress/cli.js";
import { stripAnsi } from "../lib/progress/color.js";
import { formatLabel, loadLabels } from "../lib/progress/labels.js";
import { glyphsFor } from "../lib/progress/charset.js";
import { checkBand, walkBand } from "./helpers/scope-arrow-walk.mjs";
import { buildDependencyStructure } from "../lib/progress/dependency-structure.js";
import { displayWidth } from "../lib/progress/width.js";

// fs.rmSync came in Node 14.14; the floor is 14.13.1 (package.json engines), where a named import of it fails to link and
// the whole file would not run. rmdirSync with recursive exists there (deprecated later, so it is only the fallback).
const removeTree = (d) =>
  typeof fsModule.rmSync === "function" ? fsModule.rmSync(d, { recursive: true, force: true }) : fsModule.rmdirSync(d, { recursive: true });

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const CLI = join(REPO, "lib", "progress", "cli.js");
const SCRIPTS = join(REPO, "scripts");
const STATUS_SCRIPTS = join(REPO, "skills", "j-status", "scripts");
const ESC = "\u001b";

const tests = [];
const test = (name, fn) => tests.push({ name, fn });
const temps = [];
function tmp() {
  const d = mkdtempSync(join(tmpdir(), "jenga-progress-scope-"));
  temps.push(d);
  return d;
}

const EN = loadLabels({ lang: "en", cwd: tmpdir() }).labels;
const SV = loadLabels({ lang: "sv", cwd: tmpdir() }).labels;

// ---------------------------------------------------------------------------
// fixtures: --graph payloads written the way scripts/board-progress.sh states them
// ---------------------------------------------------------------------------

const BUCKET = { done: "done", in_progress: "in_progress", failed: "failed", ready: "pending", locked: "pending", rejected: "rejected" };
const BUCKET_KEYS = ["done", "in_progress", "failed", "pending", "rejected", "unknown"];

function totalsOf(tasks) {
  const t = { done: 0, in_progress: 0, failed: 0, pending: 0, rejected: 0, unknown: 0 };
  tasks.forEach((x) => t[BUCKET[x.state]]++);
  t.denominator = t.done + t.in_progress + t.failed + t.pending;
  return t;
}

/** stories = [{ id, title, tasks: [{ id, title, state, deps }] }]; `within` limits the payload to one story, as --within does. */
function graphDoc(epicId, epicTitle, stories, within) {
  const all = [];
  stories.forEach((s) => s.tasks.forEach((t) => all.push(Object.assign({ story: s.id }, t))));
  const stateOf = new Map(all.map((t) => [t.id, t.state]));
  const tasks = all.map((t) => {
    const deps = t.deps || [];
    const doneDeps = deps.filter((d) => stateOf.get(d) === "done");
    return {
      id: t.id,
      story_id: t.story,
      epic_id: epicId,
      title: t.title,
      status: t.state,
      bucket: BUCKET[t.state],
      state: t.state,
      depends_on: deps,
      blocked_by: t.state === "locked" ? deps.filter((d) => stateOf.get(d) !== "done") : [],
      unlocked_by: ["ready", "in_progress", "done"].indexOf(t.state) >= 0 && doneDeps.length > 0 ? doneDeps[doneDeps.length - 1] : null,
    };
  });
  const storyEntry = (s) => {
    const totals = totalsOf(all.filter((t) => t.story === s.id));
    const stop = totals.denominator > 0 && totals.done === totals.denominator ? "done" : totals.failed > 0 ? "failed" : totals.in_progress > 0 || totals.done > 0 ? "in_progress" : "pending";
    return { id: s.id, epic_id: epicId, title: s.title, depends_on: [], totals, complete: totals.denominator > 0 && totals.done === totals.denominator, stop, ready_count: 0 };
  };
  const scoped = within ? stories.filter((s) => s.id === within) : stories;
  const keep = new Set(scoped.map((s) => s.id));
  const epicTotals = totalsOf(all);
  // E92_S09_T04: the epic_progress object board-progress.sh states for these stories (section 5.1): every fixture story
  // is counted, a story with at least one counted task is decomposed, percent is the floor of the user's formula.
  const decomposed = stories.filter((s) => totalsOf(all.filter((t) => t.story === s.id)).denominator > 0);
  const dTot = totalsOf(all.filter((t) => decomposed.some((s) => s.id === t.story)));
  const n = stories.length;
  const epicProgress = {
    stories: n,
    decomposed: decomposed.length,
    tasks_done: dTot.done,
    tasks_denominator: dTot.denominator,
    percent: n > 0 && decomposed.length > 0 ? Math.floor((100 * dTot.done * decomposed.length) / (dTot.denominator * n)) : 0,
    goal_reached: n > 0 && decomposed.length === n && dTot.done === dTot.denominator,
  };
  return {
    schema_version: 1,
    scope: within ? { type: "graph", within } : { type: "graph", within: epicId },
    epics: within ? [] : [{ id: epicId, title: epicTitle, depends_on: [], stories: { totals: totalsOf([]), complete: 0 }, tasks: { totals: epicTotals }, epic_progress: epicProgress, ready_count: 0 }],
    stories: scoped.map(storyEntry),
    tasks: tasks.filter((t) => keep.has(t.story_id)),
    ready: tasks.filter((t) => t.state === "ready" && keep.has(t.story_id)).map((t) => t.id),
    external: [],
    warnings: [],
  };
}

const T = (id, title, state, deps) => ({ id, title, state, deps: deps || [] });
const chain = (sid, names, states) => names.map((n, i) => T(`${sid}_T0${i + 1}`, n, states[i], i > 0 ? [`${sid}_T0${i}`] : []));

/** WIDE: a band with a three-column chain (fits 80) and a band with a five-column chain (does not), as the design's last row. */
const WIDE = () =>
  graphDoc("E01", "Launch the app", [
    { id: "E01_S01", title: "Design", tasks: chain("E01_S01", ["Research", "Wireframes", "UI-design"], ["done", "done", "ready"]) },
    { id: "E01_S02", title: "Go-to-market", tasks: chain("E01_S02", ["Plan", "Build", "Landing page", "Beta-test", "Launch"], ["done", "done", "ready", "locked", "locked"]) },
  ]);

/** MILE: four stories whose stops are done, in progress, failed and pending. */
const MILE = () =>
  graphDoc("E01", "Ship it", [
    { id: "E01_S01", title: "Alpha", tasks: [T("E01_S01_T01", "A one", "done")] },
    { id: "E01_S02", title: "Beta", tasks: [T("E01_S02_T01", "B one", "done"), T("E01_S02_T02", "B two", "ready", ["E01_S02_T01"])] },
    { id: "E01_S03", title: "Gamma", tasks: [T("E01_S03_T01", "C one", "failed")] },
    { id: "E01_S04", title: "Delta", tasks: [T("E01_S04_T01", "D one", "locked", ["E01_S03_T01"])] },
  ]);

/** FLAT: one story of seven ready tasks and no dependency at all (folds; the shared structure still draws it, E92_S09_T01). */
const FLAT = () =>
  graphDoc("E01", "Flat epic", [{ id: "E01_S01", title: "Many", tasks: [1, 2, 3, 4, 5, 6, 7].map((n) => T(`E01_S01_T0${n}`, `Task ${n}`, "ready")) }]);

/**
 * A scripts directory for JENGA_PROGRESS_SCRIPTS_DIR (also a JENGA_BOARD_PROGRESS seam for the bash renderers): its label script
 * serves the tables read once from the real script, its board-progress.sh answers canned documents by argument string.
 */
function stub(entries) {
  const dir = tmp();
  mkdirSync(join(dir, "stub"), { recursive: true });
  writeFileSync(join(dir, "labels-en.json"), JSON.stringify({ lang: "en", labels: EN }));
  writeFileSync(join(dir, "labels-sv.json"), JSON.stringify({ lang: "sv", labels: SV }));
  writeFileSync(
    join(dir, "progress-labels-json.sh"),
    ['#!/usr/bin/env bash', 'dir="$(cd "$(dirname "$0")" && pwd)"', 'case "${JENGA_PROGRESS_LANG:-en}" in sv) cat "$dir/labels-sv.json" ;; *) cat "$dir/labels-en.json" ;; esac', ""].join("\n")
  );
  writeFileSync(
    join(dir, "board-progress.sh"),
    [
      "#!/usr/bin/env bash",
      'dir="$(cd "$(dirname "$0")" && pwd)/stub"',
      "name=\"$(printf '%s' \"$*\" | tr -c 'A-Za-z0-9_.-' '_')\"",
      'if [ -f "$dir/$name.json" ]; then cat "$dir/$name.json"; exit 0; fi',
      'echo "board-progress.sh: unknown id: $*" >&2; exit 2',
      "",
    ].join("\n")
  );
  Object.keys(entries).forEach((key) => writeFileSync(join(dir, "stub", `${key.replace(/[^A-Za-z0-9_.-]/g, "_")}.json`), JSON.stringify(entries[key])));
  return dir;
}

/** cli.js in-process against a stub scripts directory: { status, out, err }. */
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

const scopeStub = (doc, id) => stub({ [`--graph --within ${id || "E01"}`]: doc });
const lines = (text) => text.split("\n");
const widths = (text) => lines(text).map((l) => displayWidth(l));
const allAscii = (buf) => Array.from(buf).every((b) => b < 0x80);
const MARKS = /[●◉◐○✕⊘]/g; // ◐: the in-progress mark of E92_S11_T01 (it shared ◉ with ready before)
const markCount = (l) => (l.match(MARKS) || []).length;

/** The lines of one band (below its header, up to the blank line), found by the upper-cased title. */
function band(out, title) {
  const ls = lines(out);
  const at = ls.findIndex((l) => l.indexOf(title) === 0);
  assert.ok(at >= 0, `no band ${title} in:\n${out}`);
  const rows = [];
  for (let i = at + 1; i < ls.length && ls[i] !== ""; i++) rows.push(ls[i]);
  return rows;
}

// ---------------------------------------------------------------------------
// scope: widths and layouts
// ---------------------------------------------------------------------------

[80, 60, 40].forEach((cols) =>
  test(`scope --layout auto at ${cols} columns: no line is wider than the width, with and without colour`, () => {
    const dir = scopeStub(WIDE());
    ["never", "always"].forEach((color) => {
      const r = inProc(["scope", "E01", "--cols", String(cols), "--color", color], dir);
      assert.strictEqual(r.status, 0, r.err);
      assert.strictEqual(r.err, "");
      const plain = stripAnsi(r.out);
      assert.ok(Math.max(...widths(plain)) <= cols, `a line is wider than ${cols}:\n${plain}`);
      assert.ok(plain.indexOf("DESIGN") >= 0 && plain.indexOf("GO-TO-MARKET") >= 0);
    });
  })
);

test("scope --layout auto on the mixed fixture: the band that fits stays horizontal, the overflowing band goes vertical", () => {
  const r = inProc(["scope", "E01", "--cols", "80"], scopeStub(WIDE()));
  const fits = band(r.out, "DESIGN");
  assert.ok(fits.some((l) => markCount(l) >= 2 && l.indexOf("─▸") >= 0), `DESIGN is not horizontal:\n${fits.join("\n")}`);
  const over = band(r.out, "GO-TO-MARKET");
  assert.strictEqual(over.length, 5);
  assert.ok(over.every((l) => markCount(l) === 1), `GO-TO-MARKET is not a vertical tree:\n${over.join("\n")}`);
  assert.ok(over.slice(1).every((l) => l.indexOf("└─▸") >= 0));
  assert.ok(Math.max(...widths(r.out)) <= 80);
});

test("scope --layout vertical draws every band as an indented tree, deeper columns further right", () => {
  const r = inProc(["scope", "E01", "--cols", "80", "--layout", "vertical"], scopeStub(WIDE()));
  const rows = band(r.out, "DESIGN");
  assert.strictEqual(rows.length, 3);
  assert.ok(rows.every((l) => markCount(l) === 1));
  const indent = (l) => l.search(/[└●◉○]/);
  assert.ok(indent(rows[0]) < indent(rows[1]) && indent(rows[1]) < indent(rows[2]), rows.join("\n"));
  assert.ok(band(r.out, "GO-TO-MARKET").every((l) => markCount(l) === 1));
});

test("scope --layout horizontal never changes the row count, truncates titles with the ellipsis, and fits the width", () => {
  const dir = scopeStub(WIDE());
  const wide = inProc(["scope", "E01", "--cols", "200", "--layout", "horizontal"], dir).out;
  assert.strictEqual(wide.indexOf("…"), -1, "nothing is truncated at 200 columns");
  const rowCounts = (out) => [band(out, "DESIGN").length, band(out, "GO-TO-MARKET").length];
  assert.deepStrictEqual(rowCounts(wide), [1, 1]);
  [80, 60, 40].forEach((cols) => {
    const r = inProc(["scope", "E01", "--cols", String(cols), "--layout", "horizontal"], dir);
    assert.deepStrictEqual(rowCounts(r.out), [1, 1], `row count changed at ${cols}`);
    assert.ok(Math.max(...widths(r.out)) <= cols, `a line is wider than ${cols}:\n${r.out}`);
  });
  const narrow = inProc(["scope", "E01", "--cols", "60", "--layout", "horizontal"], dir).out;
  assert.ok(band(narrow, "GO-TO-MARKET")[0].indexOf("…") >= 0, "titles end in the ellipsis glyph");
  assert.ok(band(narrow, "GO-TO-MARKET")[0].indexOf("Plan") >= 0);
});

test("scope: stacked nodes of one column print as rows (a cell with two nodes has two text rows)", () => {
  const doc = graphDoc("E01", "Stacked", [
    {
      id: "E01_S01",
      title: "Design",
      tasks: [T("E01_S01_T01", "Research", "done"), T("E01_S01_T02", "Wireframes", "done", ["E01_S01_T01"]), T("E01_S01_T03", "UI-design", "ready", ["E01_S01_T02"]), T("E01_S01_T04", "Design system", "ready", ["E01_S01_T02"])],
    },
  ]);
  const rows = band(inProc(["scope", "E01", "--cols", "100"], scopeStub(doc)).out, "DESIGN");
  assert.strictEqual(rows.length, 2);
  assert.ok(rows[0].indexOf("Research") >= 0 && rows[0].indexOf("UI-design") >= 0);
  assert.ok(rows[1].indexOf("Design system") >= 0 && rows[1].indexOf("─▸") >= 0);
});

// ---------------------------------------------------------------------------
// scope: every arrow is a real dependency edge (E92_S10_T03)
// ---------------------------------------------------------------------------
//
// User decision 2026-11-15 (rapport E92_S08_T08): every arrow of a band is an edge of structure.edges from the node it
// starts at, every incoming dependency or boundary edge is shown (as that arrow or as a reference after the name), and the
// goal arrow follows exactly the nodes with a goal edge. tests/helpers/scope-arrow-walk.mjs reads the rendered rows back;
// the rapport's own E01 fixture is the regression case in tests/lib-progress-parity.test.mjs.

/**
 * A generated epic: three stories of 6 to 10 tasks with random states, dependencies on earlier tasks of the same story and
 * on tasks of an earlier story (a deterministic generator, one seed per run), plus a fourth story whose six done tasks
 * fold into one group that has both a goal edge and drawn children. Titles are short and unique (N01, N02, ...).
 */
function GENERATED(seed) {
  let x = seed;
  const rnd = (n) => {
    x = (x * 1103515245 + 12345) % 2147483648;
    return Math.floor(x / 65536) % n;
  };
  const states = ["done", "ready", "locked", "failed", "in_progress", "rejected"];
  const pad = (n) => (n < 10 ? `0${n}` : String(n));
  const stories = [];
  let k = 0;
  for (let s = 1; s <= 3; s++) {
    const sid = `E01_S0${s}`;
    const tasks = [];
    const n = 6 + rnd(5);
    for (let i = 1; i <= n; i++) {
      const deps = [];
      for (let j = 1; j < i; j++) if (rnd(4) === 0) deps.push(`${sid}_T${pad(j)}`);
      if (s > 1 && rnd(3) === 0) deps.push(`E01_S0${1 + rnd(s - 1)}_T0${1 + rnd(5)}`);
      k++;
      tasks.push(T(`${sid}_T${pad(i)}`, `N${pad(k)}`, states[rnd(states.length)], deps));
    }
    stories.push({ id: sid, title: `Band ${s}`, tasks });
  }
  const g = "E01_S04";
  const folded = [1, 2, 3, 4, 5, 6].map((i) => T(`${g}_T0${i}`, `G0${i}`, "done"));
  folded.push(T(`${g}_T07`, "G07", "ready", [`${g}_T01`, `${g}_T02`]), T(`${g}_T08`, "G08", "locked", [`${g}_T03`, `${g}_T07`]), T(`${g}_T09`, "G09", "locked", ["E01_S01_T01"]));
  stories.push({ id: g, title: "Folded", tasks: folded });
  return graphDoc("E01", "Generated", stories);
}

/** Every name a band draws, mapped to its node id (a folded group is drawn as its group_tasks label). */
function bandNames(band) {
  const names = new Map();
  band.cells.forEach((cell) =>
    cell.slots.forEach((slot) => {
      if (slot.type !== "node") return;
      const n = slot.node;
      names.set(n.kind === "group" ? formatLabel(EN.group_tasks, n.count) : n.title, n.id);
    })
  );
  return names;
}

const SEEDS = [1, 7, 42, 2026, 31337];

test("E92_S10_T03: on generated bands (with a folded group) every arrow is a dependency edge, every incoming edge is an arrow or a reference, the goal arrow follows exactly the goal edges (horizontal and vertical, utf8 and ascii)", () => {
  let arrows = 0;
  let refs = 0;
  let forks = 0;
  SEEDS.forEach((seed) => {
    const graph = GENERATED(seed);
    const s = buildDependencyStructure(graph, "E01", EN);
    const group = s.nodes.find((n) => n.kind === "group");
    assert.ok(group && s.edges.some((e) => e.from === group.id && e.kind === "goal"), "the fixture has a folded group with a goal edge");
    const dir = scopeStub(graph);
    ["horizontal", "vertical"].forEach((layout) =>
      ["utf8", "ascii"].forEach((charset) => {
        const r = inProc(["scope", "E01", "--cols", "400", "--layout", layout, "--charset", charset, "--color", "never"], dir);
        assert.strictEqual(r.status, 0, r.err);
        if (charset === "ascii") assert.ok(allAscii(r.stdout), r.out);
        s.bands.forEach((b) => {
          const title = s.stories.find((x) => x.storyId === b.storyId).title.toUpperCase();
          const walk = walkBand(band(r.out, title), layout, glyphsFor(charset), bandNames(b));
          assert.deepStrictEqual(checkBand(walk, s, b), [], `seed ${seed}, ${layout} ${charset}, ${b.storyId}:\n${band(r.out, title).join("\n")}`);
          arrows += walk.arrows.length;
          Object.keys(walk.refs).forEach((id) => (refs += walk.refs[id].length));
        });
        if (layout === "horizontal" && charset === "utf8") forks += (r.out.match(/┬/g) || []).length;
      })
    );
  });
  // the generated bands exercise all three forms: straight arrows, forks and references
  assert.ok(arrows > 40 && refs > 20 && forks > 5, `arrows ${arrows}, references ${refs}, forks ${forks}`);
});

test("E92_S10_T03: a folded group with drawn children and a goal edge gets a last goal branch; a reference into a group names the member", () => {
  const graph = GENERATED(1);
  const r = inProc(["scope", "E01", "--cols", "200", "--layout", "horizontal"], scopeStub(graph));
  const rows = band(r.out, "FOLDED");
  assert.deepStrictEqual(rows.slice(0, 2), [
      // column 1 is wider by the widest reference in it (G09's "◂─ S01_T01" two rows down), column 2 by G08's
      "      ● 6 tasks       ─┬─▸◉ G07                       ───▸○ G08            ◂─ T03 ───▸⚑",
      "                       └─▸⚑",
    ], rows.join("\n"));
  const v = band(inProc(["scope", "E01", "--cols", "200", "--layout", "vertical"], scopeStub(graph)).out, "FOLDED");
  assert.deepStrictEqual(v.slice(0, 3), ["  ● 6 tasks →⚑", "    └─▸ ◉ G07", "      └─▸ ○ G08 ◂─ T03 →⚑"], v.join("\n"));
});

test("E92_S10_T03: widths 80, 100 and 50 hold with references, and auto draws a band horizontal exactly when its natural horizontal rows fit (E92_S08 decision 1)", () => {
  SEEDS.forEach((seed) => {
    const graph = GENERATED(seed);
    const s = buildDependencyStructure(graph, "E01", EN);
    const dir = scopeStub(graph);
    const natural = inProc(["scope", "E01", "--cols", "10000", "--layout", "horizontal"], dir).out;
    [80, 100, 50].forEach((cols) => {
      const out = {};
      ["auto", "horizontal", "vertical"].forEach((layout) => {
        ["never", "always"].forEach((color) => {
          const r = inProc(["scope", "E01", "--cols", String(cols), "--layout", layout, "--color", color], dir);
          assert.strictEqual(r.status, 0, r.err);
          assert.ok(Math.max(...widths(stripAnsi(r.out))) <= cols, `seed ${seed} ${layout} ${color} at ${cols}:\n${stripAnsi(r.out)}`);
          if (color === "never") {
            assert.strictEqual(r.out.indexOf(ESC), -1);
            out[layout] = r.out;
          }
        });
      });
      s.stories.forEach((st) => {
        const title = st.title.toUpperCase();
        const nat = band(natural, title);
        const fits = Math.max(...nat.map((l) => displayWidth(l))) <= cols;
        assert.deepStrictEqual(band(out.auto, title), fits ? nat : band(out.vertical, title), `seed ${seed} at ${cols}: ${title} should be ${fits ? "horizontal" : "vertical"}`);
      });
      // forced horizontal never adds a row
      s.stories.forEach((st) => assert.strictEqual(band(out.horizontal, st.title.toUpperCase()).length, band(natural, st.title.toUpperCase()).length));
    });
  });
});

// ---------------------------------------------------------------------------
// scope: content
// ---------------------------------------------------------------------------

test("scope prints the header, the milestone line with the epic as goal flag, the run bar, bands with done/total and the lists", () => {
  const r = inProc(["scope", "E01", "--cols", "80"], scopeStub(MILE()));
  assert.strictEqual(r.status, 0, r.err);
  const ls = lines(r.out);
  assert.ok(ls[0].indexOf("E01 · Ship it") === 0 && /40 %$/.test(ls[0]), ls[0]);
  assert.ok(ls[1].indexOf("⚑") > 0 && ls[1].indexOf("●") === 0, ls[1]);
  assert.ok(/Alpha\s+Beta\s+Gamma\s+Delta\s+Goal/.test(ls[2]), ls[2]);
  assert.ok(r.out.indexOf("▰") >= 0 && r.out.indexOf("2/5") >= 0, "the hatched run bar with n/total");
  assert.ok(/^ALPHA 1\/1$/m.test(r.out));
  assert.ok(/^BETA 1\/2$/m.test(r.out) && /^GAMMA 0\/1$/m.test(r.out) && /^DELTA 0\/1$/m.test(r.out));
  assert.ok(r.out.indexOf("● A one") >= 0 && r.out.indexOf("◉ B two") >= 0 && r.out.indexOf("○ D one") >= 0 && r.out.indexOf("✕ C one") >= 0);
  assert.ok(r.out.indexOf(`${EN.ready_to_take}: B two`) >= 0);
  assert.ok(r.out.indexOf("D one unlocked by C one") >= 0, "one unlocked-by line for the locked node");
});

test("scope on a story id: header without the milestone line, the band, the lists", () => {
  const dir = stub({ "--graph --within E01_S02": graphDoc("E01", "Ship it", MILE_STORIES(), "E01_S02") });
  const r = inProc(["scope", "E01_S02", "--cols", "80"], dir);
  assert.strictEqual(r.status, 0, r.err);
  assert.ok(r.out.indexOf("E01_S02 · Beta") === 0, r.out);
  assert.ok(lines(r.out)[1].indexOf("╌") === -1 && lines(r.out)[1].indexOf("━") === -1, "no milestone track for a story");
  assert.ok(/^BETA 1\/2$/m.test(r.out));
});
function MILE_STORIES() {
  return [
    { id: "E01_S01", title: "Alpha", tasks: [T("E01_S01_T01", "A one", "done")] },
    { id: "E01_S02", title: "Beta", tasks: [T("E01_S02_T01", "B one", "done"), T("E01_S02_T02", "B two", "ready", ["E01_S02_T01"])] },
  ];
}

test("scope: more than five tasks of one state in one column fold into one node with a count (and an epic with no edge still draws its bands, from the shared module, E92_S09_T01)", () => {
  const graph = FLAT();
  const flat = buildDependencyStructure(graph, "E01", EN);
  assert.strictEqual(flat.empty, false);
  assert.deepStrictEqual(flat.bands.map((b) => b.storyId), ["E01_S01"]);
  assert.strictEqual(flat.columns, 1);
  assert.ok(flat.tasks.every((t) => t.column === 0 && t.gate === "none"));
  const r = inProc(["scope", "E01", "--cols", "80"], scopeStub(graph));
  assert.strictEqual(r.status, 0, r.err);
  const rows = band(r.out, "MANY");
  assert.strictEqual(rows.length, 1);
  assert.ok(rows[0].indexOf("◉ 7 tasks") >= 0, rows[0]);
  assert.strictEqual(r.out.indexOf("Task 3"), r.out.lastIndexOf("Task 3"), "members are listed once, in the ready list");
});

test("scope: every ready title and every task state of the structure appears in the terminal output", () => {
  const graph = WIDE();
  const s = buildDependencyStructure(graph, "E01", EN);
  const out = inProc(["scope", "E01", "--cols", "100", "--layout", "vertical"], scopeStub(graph)).out;
  s.ready.forEach((x) => assert.ok(out.indexOf(x.title) >= 0, x.title));
  s.tasks.forEach((t) => assert.ok(out.indexOf(t.title.slice(0, 10)) >= 0, t.title));
});

/**
 * READY (E92_S09_T02): story E01_S01 has a done task, a ready task that never had a dependency and a ready task whose dependency
 * is done; story E01_S02 depends on E01_S01 (unfinished), so its task without depends_on and its task whose own dependency is
 * done are both locked through the story, with blocked_by ["E01_S01"] as board-progress.sh prints it.
 */
function READY() {
  const doc = graphDoc("E01", "Ready rule", [
    { id: "E01_S01", title: "First", tasks: [T("E01_S01_T01", "Done one", "done"), T("E01_S01_T02", "Free start", "ready"), T("E01_S01_T03", "After done", "ready", ["E01_S01_T01"])] },
    { id: "E01_S02", title: "Second", tasks: [T("E01_S02_T01", "Story waits", "locked"), T("E01_S02_T02", "Own dep waits", "locked", ["E01_S01_T01"])] },
  ]);
  doc.stories[1].depends_on = ["E01_S01"];
  doc.tasks.filter((t) => t.story_id === "E01_S02").forEach((t) => (t.blocked_by = ["E01_S01"]));
  return doc;
}

test("scope (E92_S09_T02): every startable task shows ◉ in the ready colour and is listed under 'Ready to take', with or without dependencies", () => {
  const graph = READY();
  const s = buildDependencyStructure(graph, "E01", EN);
  const gate = (id) => s.tasks.find((t) => t.id === id).gate;
  assert.deepStrictEqual(["E01_S01_T02", "E01_S01_T03", "E01_S02_T01", "E01_S02_T02"].map(gate), ["none", "open", "locked", "locked"]);
  const dir = scopeStub(graph);
  ["horizontal", "vertical"].forEach((layout) => {
    const r = inProc(["scope", "E01", "--cols", "120", "--layout", layout, "--color", "always"], dir);
    assert.strictEqual(r.status, 0, r.err);
    const ready = `${ESC}[36m◉${ESC}[0m`;
    const first = band(stripAnsi(r.out), "FIRST");
    const firstPainted = lines(r.out).filter((l) => /Free start|After done/.test(stripAnsi(l)));
    ["Free start", "After done"].forEach((title) => {
      const row = first.find((l) => l.indexOf(title) >= 0);
      assert.ok(row, `${layout}: ${title} drawn`);
      const painted = firstPainted.filter((l) => stripAnsi(l).indexOf(title) >= 0 && stripAnsi(l).indexOf("Ready to take") < 0)[0];
      assert.ok(painted, `${layout}: ${title} row`);
      // the mark right before the title is the ready glyph in the ready colour (cyan, SGR 36), not the in-progress yellow
      const at = painted.indexOf(title);
      const before = painted.slice(0, at);
      assert.ok(before.lastIndexOf(ready) >= 0 && before.lastIndexOf(ready) > before.lastIndexOf("○"), `${layout}: ${title} has the ready ◉:\n${painted}`);
    });
    // the two tasks locked through their story are drawn locked, never with the ready glyph
    const second = band(stripAnsi(r.out), "SECOND");
    ["Story waits", "Own dep waits"].forEach((title) => {
      const row = second.find((l) => l.indexOf(title) >= 0);
      assert.ok(row && row.indexOf("○ " + title) >= 0, `${layout}: ${title} locked:\n${row}`);
    });
    // "Ready to take" lists both startable tasks and neither locked one
    const plain = stripAnsi(r.out);
    const list = lines(plain).filter((l) => l.indexOf(`${EN.ready_to_take}: `) === 0).join("\n");
    assert.ok(list.indexOf("Free start") >= 0 && list.indexOf("After done") >= 0, list);
    assert.ok(list.indexOf("Story waits") < 0 && list.indexOf("Own dep waits") < 0, list);
  });
});

/**
 * STATES (E92_S11_T01): one story with one task in every state the tree draws: done, ready, in progress, failed, rejected and
 * locked (behind the failed task). With colour off only the glyph can tell the states apart.
 */
const STATES = () =>
  graphDoc("E01", "Every state", [
    {
      id: "E01_S01",
      title: "States",
      tasks: [
        T("E01_S01_T01", "Done one", "done"),
        T("E01_S01_T02", "Ready one", "ready"),
        T("E01_S01_T03", "Busy one", "in_progress"),
        T("E01_S01_T04", "Broken one", "failed"),
        T("E01_S01_T05", "Dropped one", "rejected"),
        T("E01_S01_T06", "Waiting one", "locked", ["E01_S01_T04"]),
      ],
    },
  ]);

test("E92_S11_T01: with --color never the in-progress tree mark is the half dot (◐ / %), distinct from ready and done; the other marks are unchanged", () => {
  const dir = scopeStub(STATES());
  const want = {
    utf8: { "Done one": "●", "Ready one": "◉", "Busy one": "◐", "Broken one": "✕", "Dropped one": "⊘", "Waiting one": "○" },
    ascii: { "Done one": "*", "Ready one": "@", "Busy one": "%", "Broken one": "x", "Dropped one": "x", "Waiting one": "o" },
  };
  ["utf8", "ascii"].forEach((charset) => {
    const g = glyphsFor(charset);
    assert.strictEqual(g.inProgress, charset === "utf8" ? "◐" : "%");
    assert.ok(g.inProgress !== g.ready && g.inProgress !== g.done && g.inProgress !== g.locked && g.inProgress !== g.cross, `${charset}: the in-progress mark is shared`);
    ["horizontal", "vertical"].forEach((layout) => {
      const r = inProc(["scope", "E01", "--cols", "160", "--layout", layout, "--charset", charset, "--color", "never"], dir);
      assert.strictEqual(r.status, 0, r.err);
      assert.ok(r.out.indexOf("\u001b") < 0, "colour with --color never");
      const rows = band(r.out, "STATES").join("\n");
      Object.keys(want[charset]).forEach((title) => {
        const mark = want[charset][title];
        assert.ok(rows.indexOf(`${mark} ${title}`) >= 0, `${charset} ${layout}: ${title} is not drawn with ${mark}:\n${rows}`);
      });
      // the in-progress task is never drawn with the ready mark
      assert.ok(rows.indexOf(`${g.ready} Busy one`) < 0, `${charset} ${layout}: in progress drawn as ready:\n${rows}`);
    });
  });
});

/**
 * UNFINISHED (E92_S11_T02): "Write docs" is done although its dependency "Build it" was reopened (failed); "Ship it" is done
 * with two unfinished dependencies (its own and its story's); "Plan" is a plain done task. unfinished_deps is set as
 * board-progress.sh --graph states it (the graphDoc helper predates the key).
 */
function UNFINISHED(withKey) {
  const doc = graphDoc("E01", "Contradiction", [
    { id: "E01_S01", title: "First", tasks: [T("E01_S01_T01", "Plan", "done"), T("E01_S01_T02", "Build it", "failed", ["E01_S01_T01"]), T("E01_S01_T03", "Write docs", "done", ["E01_S01_T02"])] },
    { id: "E01_S02", title: "Second", tasks: [T("E01_S02_T01", "Ship it", "done", ["E01_S01_T02"])] },
  ]);
  doc.stories[1].depends_on = ["E01_S01"];
  const stated = { E01_S01_T03: ["E01_S01_T02"], E01_S02_T01: ["E01_S01_T02", "E01_S01"] };
  if (withKey) doc.tasks.forEach((t) => (t.unfinished_deps = stated[t.id] || []));
  return doc;
}

test("E92_S11_T02: a done task whose dependency is not done shows ? in the in-progress colour, with a line naming the dependency (utf8 and ascii)", () => {
  const dir = scopeStub(UNFINISHED(true));
  ["utf8", "ascii"].forEach((charset) => {
    const g = glyphsFor(charset);
    assert.strictEqual(g.unfinished, "?");
    ["horizontal", "vertical"].forEach((layout) => {
      const r = inProc(["scope", "E01", "--cols", "160", "--layout", layout, "--charset", charset, "--color", "never"], dir);
      assert.strictEqual(r.status, 0, r.err);
      const first = band(r.out, "FIRST").join("\n");
      const second = band(r.out, "SECOND").join("\n");
      assert.ok(first.indexOf("? Write docs") >= 0 && second.indexOf("? Ship it") >= 0, `${charset} ${layout}:\n${r.out}`);
      assert.ok(first.indexOf(`${g.done} Plan`) >= 0, `${charset} ${layout}: a plain done task keeps its mark:\n${first}`);
      assert.ok(first.indexOf(`${g.done} Write docs`) < 0, `${charset} ${layout}: the ? replaces the done mark`);
      assert.ok(r.out.indexOf(`? Write docs: ${formatLabel(EN.dep_unfinished, "E01_S01_T02")}`) >= 0, r.out);
      assert.ok(r.out.indexOf(`? Ship it: ${EN.dep_unfinished_more.replace("%s", "E01_S01_T02").replace("%d", "1")}`) >= 0, r.out);
      if (charset === "ascii") assert.ok(allAscii(Buffer.from(r.out, "utf8")), r.out);
    });
  });
  // colour on: the ? is painted in the in-progress yellow (SGR 33), the name keeps the done style
  const painted = inProc(["scope", "E01", "--cols", "160", "--layout", "vertical", "--color", "always"], dir).out;
  assert.ok(painted.indexOf(`${ESC}[33m?${ESC}[0m`) >= 0, painted);
  // it still counts as done: the band totals and the run bar are the same as without the key
  const plain = inProc(["scope", "E01", "--cols", "160", "--color", "never"], scopeStub(UNFINISHED(false))).out;
  const flagged = inProc(["scope", "E01", "--cols", "160", "--color", "never"], dir).out;
  assert.ok(/^FIRST 2\/3$/m.test(flagged) && /^SECOND 1\/1$/m.test(flagged), flagged);
  const barOf = (o) => lines(o).find((l) => /^E01 {2}/.test(l));
  assert.strictEqual(barOf(flagged), barOf(plain));
  assert.strictEqual(lines(flagged)[0], lines(plain)[0], "the header percent is unchanged");
});

test("E92_S11_T02: a payload without unfinished_deps (an older script) renders exactly as before; Swedish words come from the table", () => {
  const plain = inProc(["scope", "E01", "--cols", "160", "--color", "never"], scopeStub(UNFINISHED(false))).out;
  assert.ok(plain.indexOf("?") < 0 && plain.indexOf("● Write docs") >= 0, plain);
  const empty = UNFINISHED(false);
  empty.tasks.forEach((t) => (t.unfinished_deps = []));
  assert.strictEqual(inProc(["scope", "E01", "--cols", "160", "--color", "never"], scopeStub(empty)).out, plain);
  const sv = inProc(["scope", "E01", "--cols", "160", "--color", "never", "--lang", "sv"], scopeStub(UNFINISHED(true))).out;
  assert.ok(sv.indexOf(`? Write docs: ${formatLabel(SV.dep_unfinished, "E01_S01_T02")}`) >= 0, sv);
  assert.ok(SV.dep_unfinished.indexOf("Klar trots att beroendet") === 0, SV.dep_unfinished);
});

// ---------------------------------------------------------------------------
// the shared structure: terminal tree versus dashboard tree
// ---------------------------------------------------------------------------

test("the terminal tree and the dashboard tree built from one payload agree on state, gate, ready and unlocked_by", async () => {
  const modelPath = join(REPO, "project", "app", "ui", "src", "components", "progress", "dependencyTreeModel.js");
  if (!existsSync(modelPath)) return; // the dashboard sources are not part of a consumer install
  const { buildDependencyTreeModel } = await import(pathToFileURL(modelPath).href);
  [WIDE(), MILE(), FLAT(), READY()].forEach((graph) => {
    const terminal = buildDependencyStructure(graph, "E01", EN);
    const dash = buildDependencyTreeModel(graph, "E01", EN);
    // FLAT has no dependency edge: since E92_S09_T01 both views draw it, so it is compared like the others
    assert.strictEqual(dash.empty, false);
    assert.strictEqual(terminal.empty, false);
    const facts = (m) => m.tasks.map((t) => ({ id: t.id, state: t.state, gate: t.gate, mark: t.mark, dependsOn: t.dependsOn, unlocks: t.unlocks, column: t.column, row: t.row }));
    assert.deepStrictEqual(facts(terminal), facts(dash));
    assert.deepStrictEqual(terminal.ready, dash.ready);
    assert.deepStrictEqual(terminal.unlocked, dash.unlocked);
    const goalFacts = (g) => ({ id: g.id, title: g.title, fraction: g.fraction, percent: g.percent, done: g.done, total: g.total, reached: g.reached });
    assert.deepStrictEqual(goalFacts(terminal.goal), goalFacts(dash.goal));
    const unlockedBy = (g) => g.tasks.filter((t) => t.unlocked_by).map((t) => `${t.id}<${t.unlocked_by}`);
    assert.deepStrictEqual(
      terminal.unlocked.map((u) => u.taskId),
      unlockedBy(graph).map((x) => x.split("<")[0])
    );
  });
});

// ---------------------------------------------------------------------------
// parity with the bash renderers
// ---------------------------------------------------------------------------

function bashView(script, args, dir) {
  const r = spawnSync("bash", [join(STATUS_SCRIPTS, script)].concat(args, ["--cols", "80", "--color", "never"]), {
    env: { PATH: process.env.PATH, HOME: process.env.HOME || tmpdir(), LANG: "en_US.UTF-8", JENGA_BOARD_PROGRESS: join(dir, "board-progress.sh") },
    encoding: "utf8",
  });
  assert.strictEqual(r.status, 0, r.stderr);
  return r.stdout;
}

test("scope: the milestone line carries the stop markers, the message and the 'next' of render-status-scope-view.sh (parity on the markers)", () => {
  const dir = scopeStub(MILE());
  const bash = bashView("render-status-scope-view.sh", ["E01"], dir);
  const node = inProc(["scope", "E01", "--cols", "80"], dir).out;
  const stops = (text, startGlyph) => {
    const track = lines(text).find((l) => l.indexOf(startGlyph) === 0);
    assert.ok(track, `no track in:\n${text}`);
    return (track.slice(1).match(/[●◉✕○⊘]/g) || []).join("");
  };
  assert.strictEqual(stops(node, "●"), "●◉✕○");
  assert.strictEqual(stops(node, "●"), stops(bash, "▸"));
  const tail = (text, sep) => lines(text).find((l) => l.indexOf(EN.ready_to_take + ": ") >= 0 && l.indexOf(sep) > 0);
  const nodeLine = tail(node, "  ▸  ");
  const bashLine = tail(bash, "  ›  ");
  assert.ok(nodeLine && bashLine, `${nodeLine} / ${bashLine}`);
  assert.strictEqual(nodeLine.split("  ▸  ")[0], bashLine.split("  ›  ")[0]);
  assert.strictEqual(nodeLine.split("  ▸  ")[1], bashLine.split("  ›  ")[1]);
  assert.strictEqual(nodeLine.split("  ▸  ")[0], EN.sc_msg_going.replace("%d", "3"));
  // the percent of the header
  assert.strictEqual(lines(node)[0].match(/([0-9]+) %/)[1], lines(bash)[0].match(/([0-9]+) %/)[1]);
});

test("scope: the current milestone (a story whose stop is in progress) is bold under --color always, the others are not", () => {
  const out = inProc(["scope", "E01", "--cols", "80", "--color", "always"], scopeStub(MILE())).out;
  assert.ok(out.indexOf(`${ESC}[1mBeta${ESC}[0m`) >= 0, "Beta is the current milestone");
  assert.strictEqual(out.indexOf(`${ESC}[1mAlpha`), -1);
  assert.strictEqual(out.indexOf(`${ESC}[1mDelta`), -1);
  assert.ok(out.indexOf(`${ESC}[38;5;`) >= 0, "the gradient of the track");
});

function overviewEpic(id, title, done, inProgress, failed, pending, rejected) {
  const den = done + inProgress + failed + pending;
  const zero = { done: 0, in_progress: 0, failed: 0, pending: 0, rejected: 0, unknown: 0, denominator: 0 };
  return {
    id,
    title,
    depends_on: [],
    stories: { totals: zero, complete: 0 },
    tasks: { totals: { done, in_progress: inProgress, failed, pending, rejected, unknown: 0, denominator: den } },
    // E92_S09_T04: one story holding every task, as board-progress.sh states it (the epic percent is the task share here)
    epic_progress: {
      stories: 1,
      decomposed: den > 0 ? 1 : 0,
      tasks_done: done,
      tasks_denominator: den,
      percent: den > 0 ? Math.floor((100 * done) / den) : 0,
      goal_reached: den > 0 && done === den,
    },
    ready_count: 0,
  };
}
const OVERVIEW = () => ({
  schema_version: 1,
  scope: { type: "graph" },
  epics: [
    overviewEpic("E10", "Failing epic ten", 3, 0, 1, 2, 0),
    overviewEpic("E12", "Failing epic twelve", 1, 0, 1, 2, 0),
    overviewEpic("E20", "Busy epic twenty", 2, 1, 0, 1, 0),
    overviewEpic("E21", "Busy epic twenty-one", 3, 1, 0, 0, 0),
    overviewEpic("E30", "Begun epic thirty", 1, 0, 0, 3, 0),
    overviewEpic("E40", "Untouched epic forty", 0, 0, 0, 5, 0),
    overviewEpic("E50", "Finished epic fifty", 3, 0, 0, 0, 0),
    overviewEpic("E51", "Finished epic fifty-one", 4, 0, 0, 0, 0),
    overviewEpic("E60", "Only rejected sixty", 0, 0, 0, 0, 3),
    overviewEpic("E61", "Empty epic sixty-one", 0, 0, 0, 0, 0),
  ],
  stories: [],
  warnings: [],
});

/** The numbers of an overview rendering: the total line, the group sizes, every epic row, the collapsed lines. */
function overviewNumbers(text) {
  const out = { rows: {}, groups: {}, total: null, complete: null, empty: null };
  lines(text).forEach((l) => {
    let m;
    if ((m = /^(Needs attention|In progress|Started|Not started) \(([0-9]+)\)$/.exec(l))) out.groups[m[1]] = Number(m[2]);
    else if ((m = /^\s+(E[0-9]+)\s.*?([0-9]+)\/([0-9]+)\s+([0-9]+) %/.exec(l))) out.rows[m[1]] = [m[2], m[3], m[4]].map(Number);
    else if ((m = /([0-9]+) epics\b.*?([0-9]+)\/([0-9]+) tasks.*?([0-9]+) %/.exec(l))) out.total = [m[1], m[2], m[3], m[4]].map(Number);
    else if ((m = /Complete \(([0-9]+)\)\s+([0-9]+) tasks/.exec(l))) out.complete = [m[1], m[2]].map(Number);
    else if ((m = /Only rejected or empty \(([0-9]+)\): (.*)$/.exec(l))) out.empty = [Number(m[1]), m[2]];
  });
  return out;
}

test("overview: totals, groups, every epic row and the collapsed lines carry the numbers render-status-overview.sh prints", () => {
  const dir = stub({ "--graph --counts-only": OVERVIEW() });
  const node = overviewNumbers(inProc(["overview", "--cols", "80"], dir).out);
  const bash = overviewNumbers(bashView("render-status-overview.sh", [], dir));
  assert.deepStrictEqual(node, bash);
  assert.deepStrictEqual(node.total, [10, 17, 34, 50]);
  assert.strictEqual(Object.keys(node.rows).length, 6, "only the epics still in progress have a row");
  assert.deepStrictEqual(node.complete, [2, 7]);
});

// E92_S09_T04: an epic of 5 stories, 3 decomposed (2 tasks each), 2 with no task yet. The overview row and the scope view
// show the epic percent of epic_progress: half the tasks done 30 %, all of them 60 % (not complete, the goal is not
// reached), every story decomposed and done 100 % (complete, the goal reached); bash --legacy states the same numbers.
const FIVE = (states, decomposeAll) =>
  graphDoc("E01", "Five stories", [1, 2, 3, 4, 5].map((k) => ({
    id: `E01_S0${k}`,
    title: `Story ${k}`,
    tasks: k <= 3 || decomposeAll ? [T(`E01_S0${k}_T01`, `T${k}a`, states[0]), T(`E01_S0${k}_T02`, `T${k}b`, states[1])] : [],
  })));

test("E92_S09_T04: 5 stories, 3 decomposed: the overview row and the scope view show 30 %, then 60 % (not reached), then 100 % (reached)", () => {
  const cases = [
    { doc: FIVE(["done", "ready"]), pct: 30, counts: "3/6", note: true, reached: false },
    { doc: FIVE(["done", "done"]), pct: 60, counts: "6/6", note: true, reached: false },
    { doc: FIVE(["done", "done"], true), pct: 100, counts: "10/10", note: false, reached: true },
  ];
  const noteText = EN.epic_decomposed.replace("%d", "3").replace("%d", "5");
  cases.forEach((c) => {
    assert.strictEqual(c.doc.epics[0].epic_progress.percent, c.pct, "the fixture states the script's figure");
    // the scope view: header percent, the note while stories are undecomposed, the message and the goal flag
    const dir = scopeStub(c.doc);
    const node = inProc(["scope", "E01", "--cols", "100"], dir).out;
    const head = lines(node)[0];
    assert.ok(new RegExp(`${c.pct} %$`).test(head), head);
    assert.strictEqual(head.indexOf(noteText) >= 0, c.note, head);
    assert.strictEqual(node.indexOf(EN.sc_msg_done) >= 0, c.reached, "the done message only when the goal is reached");
    const track = lines(node)[1];
    assert.strictEqual(track.indexOf("★") >= 0, c.reached, track);
    const bash = bashView("render-status-scope-view.sh", ["E01"], dir);
    assert.strictEqual(lines(bash)[0].match(/([0-9]+) %/)[1], String(c.pct), "--legacy shows the same percent");
    assert.strictEqual(lines(bash)[0].indexOf(noteText) >= 0, c.note);
    // the overview: the row (or the complete line) from epic_progress, the same numbers on the bash path
    const odir = stub({ "--graph --counts-only": { schema_version: 1, scope: { type: "graph" }, epics: c.doc.epics, stories: [], warnings: [] } });
    const ov = inProc(["overview", "--cols", "100"], odir).out;
    const nodeNums = overviewNumbers(ov);
    assert.deepStrictEqual(nodeNums, overviewNumbers(bashView("render-status-overview.sh", [], odir)));
    if (c.reached) {
      assert.deepStrictEqual(nodeNums.complete, [1, 10]);
      assert.deepStrictEqual(nodeNums.rows, {});
    } else {
      assert.deepStrictEqual(nodeNums.rows.E01, c.counts.split("/").map(Number).concat([c.pct]));
      assert.strictEqual(nodeNums.complete, null, "all tasks done is not complete while stories are undecomposed");
      assert.ok(ov.indexOf(noteText) >= 0, "the decomposed note beside the percent");
    }
  });
});

// E92_S10_T02 (user decision 2026-11-15: "'Goal reached' när en story är Failed: hindra det"): an epic whose stories are all
// decomposed with every task done, but one story's own status is in the failed bucket (Failed or Blocked). The real
// board-progress.sh states no goal, the percent capped at 99 and failed_stories; every terminal view reads it: no "Goal reached",
// no 100 %, and the failed story named where the congratulation was. With the story Passed the goal is reached as before.
function failedStoryBoard(storyStatus) {
  const root = tmp();
  mkdirSync(join(root, "project", "configs"), { recursive: true });
  for (const d of ["epics", "stories", "tasks"]) mkdirSync(join(root, "project", "board", d), { recursive: true });
  writeFileSync(join(root, "project", "configs", "workflow.json"), "{}\n");
  const file = (dir, id, body) => writeFileSync(join(root, "project", "board", dir, `${id}_x.md`), `---\nid: ${id}\n${body}title: "Fixture ${id}"\n---\n\n# ${id}\n`);
  file("epics", "E01", "status: In Progress\n");
  file("stories", "E01_S01", "epic_id: E01\nstatus: Passed\n");
  file("stories", "E01_S02", `epic_id: E01\nstatus: ${storyStatus}\n`);
  file("tasks", "E01_S01_T01", "story_id: E01_S01\nepic_id: E01\nstatus: Passed\n");
  file("tasks", "E01_S02_T01", "story_id: E01_S02\nepic_id: E01\nstatus: Passed\n");
  file("tasks", "E01_S02_T02", "story_id: E01_S02\nepic_id: E01\nstatus: Merged\ndepends_on: [E01_S02_T01]\n");
  return root;
}
const statedGraph = (root, args) => {
  const r = spawnSync("bash", [join(SCRIPTS, "board-progress.sh"), "--root", root].concat(args), { encoding: "utf8" });
  assert.strictEqual(r.status, 0, r.stderr);
  return JSON.parse(r.stdout);
};

test("E92_S10_T02: a Failed or Blocked story: scope and overview (Node and --legacy) show 99 %, no goal, and name the story", () => {
  const named = EN.goal_failed.replace("%s", "E01_S02");
  ["Failed", "Blocked"].forEach((status) => {
    const root = failedStoryBoard(status);
    const ep = statedGraph(root, ["--graph", "--within", "E01"]).epics[0].epic_progress;
    assert.deepStrictEqual([ep.percent, ep.goal_reached, ep.failed_stories], [99, false, ["E01_S02"]], `${status}: the script decides`);
    // Node scope view through the real script
    const sc = cliProc(["scope", "E01", "--cols", "100", "--color", "never"], root);
    assert.strictEqual(sc.status, 0, sc.err);
    const ls = lines(sc.out);
    assert.ok(/ 99 %$/.test(ls[0]), ls[0]);
    assert.strictEqual(sc.out.indexOf("100 %"), -1, sc.out);
    assert.strictEqual(sc.out.indexOf(EN.sc_msg_done), -1, "no congratulation");
    assert.strictEqual(ls[3], named, "the message line names the failed story");
    assert.strictEqual(ls[1].indexOf("★"), -1, "the milestone goal flag is not the star");
    // Node overview through the real script: an open row at 99 % that names the story, nothing complete
    const ov = cliProc(["overview", "--cols", "120", "--color", "never"], root);
    assert.strictEqual(ov.status, 0, ov.err);
    const row = lines(ov.out).filter((l) => /^\s+E01\s/.test(l))[0] || "";
    assert.ok(/ 99 %/.test(row) && row.indexOf(named) >= 0, row);
    assert.deepStrictEqual(overviewNumbers(ov.out).complete, null, "not complete");
    // --legacy reads the same stated payload and says the same
    const dir = stub({ "--graph --within E01": statedGraph(root, ["--graph", "--within", "E01"]), "--graph --counts-only": statedGraph(root, ["--graph", "--counts-only"]) });
    const bash = lines(bashView("render-status-scope-view.sh", ["E01"], dir));
    assert.ok(/ 99 %$/.test(bash[0]), bash[0]);
    assert.strictEqual(bash[3], named);
    const bov = bashView("render-status-overview.sh", [], dir);
    assert.deepStrictEqual(overviewNumbers(bov), overviewNumbers(inProc(["overview", "--cols", "80"], dir).out));
    assert.ok(bov.indexOf("E01_S02") >= 0 && bov.indexOf(EN.sc_msg_done) === -1);
  });
  // Swedish words for the same line
  const sv = cliProc(["--lang", "sv", "scope", "E01", "--cols", "100", "--color", "never"], failedStoryBoard("Failed"));
  assert.strictEqual(lines(sv.out)[3], SV.goal_failed.replace("%s", "E01_S02"));
  // the same story Passed: the goal as before (100 %, the done message, the star)
  const ok = cliProc(["scope", "E01", "--cols", "100", "--color", "never"], failedStoryBoard("Passed"));
  assert.ok(/ 100 %$/.test(lines(ok.out)[0]), lines(ok.out)[0]);
  assert.ok(ok.out.indexOf(EN.sc_msg_done) >= 0 && lines(ok.out)[1].indexOf("★") >= 0);
});

test("E92_S10_T02: two failed stories name the first and the count of the others; below 99 % the messages are unchanged", () => {
  const doc = FIVE(["done", "done"], true);
  doc.epics[0].epic_progress = Object.assign({}, doc.epics[0].epic_progress, { percent: 99, goal_reached: false, failed_stories: ["E01_S02", "E01_S04"] });
  const out = inProc(["scope", "E01", "--cols", "100"], scopeStub(doc)).out;
  assert.ok(out.indexOf(EN.goal_failed_more.replace("%s", "E01_S02").replace("%d", "1")) >= 0, out);
  assert.strictEqual(out.indexOf(EN.sc_msg_done), -1);
  // 60 %: the stated failed story does not replace the existing percent message
  const low = FIVE(["done", "done"]);
  low.epics[0].epic_progress = Object.assign({}, low.epics[0].epic_progress, { failed_stories: ["E01_S02"] });
  const lowOut = inProc(["scope", "E01", "--cols", "100"], scopeStub(low)).out;
  assert.strictEqual(lowOut.indexOf("Goal not reached"), -1, lowOut);
  assert.ok(lowOut.indexOf(EN.sc_msg_half.replace("%d", "2")) >= 0, lowOut);
});

test("overview: widths 80, 60 and 40 hold, the run bar shows n/total, and --all prints nothing (the caller's legacy list)", () => {
  const dir = stub({ "--graph --counts-only": OVERVIEW() });
  [80, 60, 40].forEach((cols) => {
    const r = inProc(["overview", "--cols", String(cols), "--color", "always"], dir);
    assert.strictEqual(r.err, "");
    assert.ok(Math.max(...widths(stripAnsi(r.out))) <= cols, `wider than ${cols}`);
  });
  const r = inProc(["overview", "--cols", "80"], dir);
  assert.ok(r.out.indexOf("▰") >= 0 && r.out.indexOf("17/34") >= 0);
  const all = inProc(["overview", "--all"], dir);
  assert.strictEqual(all.out, "");
  assert.strictEqual(all.status, 0);
});

// ---------------------------------------------------------------------------
// charset, colour, language, ids, warnings, usage
// ---------------------------------------------------------------------------

test("default output is UTF-8 and uncoloured when piped (LANG empty); --charset ascii is pure ASCII including arrows and the flag", () => {
  const dir = scopeStub(WIDE());
  const plain = inProc(["scope", "E01", "--cols", "80"], dir, { LANG: "" });
  assert.ok(plain.out.indexOf("●") >= 0 && plain.out.indexOf("⚑") >= 0 && plain.out.indexOf(ESC) === -1);
  const ascii = inProc(["scope", "E01", "--cols", "80", "--charset", "ascii"], dir, { LANG: "" });
  assert.ok(allAscii(ascii.stdout), ascii.out);
  assert.ok(ascii.out.indexOf("->") >= 0 || ascii.out.indexOf("+->") >= 0);
  const horizontal = inProc(["scope", "E01", "--cols", "200", "--charset", "ascii", "--layout", "horizontal"], dir);
  assert.ok(allAscii(horizontal.stdout) && horizontal.out.indexOf("--->") >= 0);
  const ov = inProc(["overview", "--charset", "ascii", "--lang", "sv"], stub({ "--graph --counts-only": OVERVIEW() }));
  assert.ok(allAscii(ov.stdout), ov.out);
  const sv = inProc(["scope", "E01", "--charset", "ascii", "--lang", "sv"], scopeStub(MILE()));
  assert.ok(allAscii(sv.stdout), sv.out);
});

test("--color always paints the bands; NO_COLOR does not stop an explicit --color always, and auto on a pipe stays plain", () => {
  const dir = scopeStub(MILE());
  assert.ok(inProc(["scope", "E01", "--color", "always"], dir, { NO_COLOR: "1" }).out.indexOf(ESC) >= 0);
  assert.strictEqual(inProc(["scope", "E01"], dir).out.indexOf(ESC), -1);
  assert.strictEqual(inProc(["scope", "E01", "--color", "never"], dir).out.indexOf(ESC), -1);
});

test("every word comes from the label table: Swedish with --lang sv and with JENGA_PROGRESS_LANG=sv", () => {
  const dir = scopeStub(MILE());
  const viaFlag = inProc(["scope", "E01", "--lang", "sv"], dir).out;
  const viaEnv = inProc(["scope", "E01"], dir, { JENGA_PROGRESS_LANG: "sv" }).out;
  assert.strictEqual(viaFlag, viaEnv);
  assert.ok(viaFlag.indexOf(SV.ready_to_take) >= 0 && viaFlag.indexOf(SV.goal) >= 0);
  assert.ok(viaFlag.indexOf(SV.unlocked_by.replace("%s", "D one").replace("%s", "C one")) >= 0, viaFlag);
  assert.ok(viaFlag.indexOf(SV.sc_msg_going.replace("%d", "3")) >= 0);
  assert.strictEqual(viaFlag.indexOf(EN.ready_to_take), -1);
  const ov = inProc(["overview", "--lang", "sv"], stub({ "--graph --counts-only": OVERVIEW() })).out;
  assert.ok(ov.indexOf(SV.ov_group_attention) >= 0 && ov.indexOf(SV.ov_footer_scope) >= 0);
});

/** A real board for the id-form and warning tests: E01 with two stories (S01 has a dependency), E02 with no tasks. */
function realBoard() {
  const root = tmp();
  mkdirSync(join(root, "project", "configs"), { recursive: true });
  for (const d of ["epics", "stories", "tasks"]) mkdirSync(join(root, "project", "board", d), { recursive: true });
  writeFileSync(join(root, "project", "configs", "workflow.json"), "{}\n");
  const file = (dir, id, body) => writeFileSync(join(root, "project", "board", dir, `${id}_x.md`), `---\nid: ${id}\n${body}title: "Fixture ${id}"\n---\n\n# ${id}\n`);
  file("epics", "E01", "status: In Progress\n");
  file("epics", "E02", "status: Pending\n");
  file("stories", "E01_S01", "epic_id: E01\nstatus: In Progress\n");
  file("stories", "E01_S02", "epic_id: E01\nstatus: Pending\n");
  file("tasks", "E01_S01_T01", "story_id: E01_S01\nepic_id: E01\nstatus: Passed\n");
  file("tasks", "E01_S01_T02", "story_id: E01_S01\nepic_id: E01\nstatus: Pending\ndepends_on: [E01_S01_T01]\n");
  file("tasks", "E01_S02_T01", "story_id: E01_S02\nepic_id: E01\nstatus: Pending\ndepends_on: [E01_S01_T02]\n");
  return root;
}
function cliProc(args, root) {
  const r = spawnSync(process.execPath, [CLI].concat(args), { env: { PATH: process.env.PATH, HOME: process.env.HOME || tmpdir(), JENGA_PROJECT_ROOT: root }, cwd: tmpdir(), encoding: "utf8" });
  return { status: r.status, out: r.stdout, err: r.stderr };
}

test("short id forms resolve: E1_S1 prints the same view as E01_S01, and E1 the same as E01 (real board-progress.sh)", () => {
  const root = realBoard();
  const a = cliProc(["scope", "E1_S1"], root);
  const b = cliProc(["scope", "E01_S01"], root);
  assert.strictEqual(a.status, 0, a.err);
  assert.strictEqual(a.err, "");
  assert.ok(a.out.length > 0 && a.out.indexOf("E01_S01") >= 0);
  assert.strictEqual(a.out, b.out);
  const e1 = cliProc(["scope", "E1"], root);
  assert.strictEqual(e1.out, cliProc(["scope", "E01"], root).out);
  assert.ok(e1.out.indexOf("E01 · Fixture E01") === 0 && e1.out.indexOf(`${EN.ready_to_take}: Fixture E01_S01_T02`) >= 0, e1.out);
});

test("an unknown id and an empty epic print one warning on stderr, nothing on stdout, and exit 0", () => {
  const root = realBoard();
  ["E99", "E99_S01", "E02"].forEach((id) => {
    const r = cliProc(["scope", id], root);
    assert.strictEqual(r.status, 0, id);
    assert.strictEqual(r.out, "", id);
    assert.strictEqual(r.err.split("\n").filter((l) => l !== "").length, 1, `${id}: ${r.err}`);
    assert.ok(/warning/.test(r.err));
  });
  const empty = inProc(["scope", "E01"], scopeStub(graphDoc("E01", "Nothing", [])));
  assert.strictEqual(empty.status, 0);
  assert.strictEqual(empty.out, "");
  assert.strictEqual(empty.err.split("\n").filter((l) => l !== "").length, 1);
  const missing = inProc(["scope", "E01"], tmp());
  assert.strictEqual(missing.out, "");
  assert.strictEqual(missing.status, 0);
  assert.strictEqual(missing.err.split("\n").filter((l) => l !== "").length, 1);
  const noEpics = inProc(["overview"], stub({ "--graph --counts-only": { schema_version: 1, epics: [], stories: [], warnings: [] } }));
  assert.strictEqual(noEpics.out, "");
  assert.strictEqual(noEpics.status, 0);
  assert.strictEqual(noEpics.err.split("\n").filter((l) => l !== "").length, 1);
});

test("usage errors exit 2 with nothing on stdout: no id, a task id, a malformed id, two ids, a bad --layout, an id for overview", () => {
  const dir = scopeStub(MILE());
  [["scope"], ["scope", "E01_S01_T01"], ["scope", "banana"], ["scope", "E01", "E02"], ["scope", "E01", "--layout", "diagonal"], ["overview", "E01"], ["scope", "--layout"]].forEach((args) => {
    const r = inProc(args, dir);
    assert.strictEqual(r.status, 2, args.join(" "));
    assert.strictEqual(r.out, "", args.join(" "));
    assert.ok(r.err.length > 0);
  });
});

test("the usage lists the overview and scope commands and the --layout flag is accepted in any position", () => {
  const r = inProc(["--help"], tmp());
  assert.strictEqual(r.status, 0);
  ["overview", "scope"].forEach((name) => assert.ok(new RegExp(`^  ${name} `, "m").test(r.out), name));
  const dir = scopeStub(MILE());
  assert.strictEqual(inProc(["scope", "--layout", "vertical", "E01"], dir).out, inProc(["scope", "E01", "--layout=vertical"], dir).out);
  assert.strictEqual(inProc(["--cols", "70", "scope", "E01"], dir).out, inProc(["scope", "E01", "--cols=70"], dir).out);
});

test("a sweep of widths from 30 to 120 never produces a line wider than the width, for scope (all layouts) and overview", () => {
  const sc = scopeStub(WIDE());
  const ov = stub({ "--graph --counts-only": OVERVIEW() });
  for (let cols = 30; cols <= 120; cols += 7) {
    ["auto", "horizontal", "vertical"].forEach((layout) => {
      const r = inProc(["scope", "E01", "--cols", String(cols), "--layout", layout, "--color", "always"], sc);
      assert.ok(Math.max(...widths(stripAnsi(r.out))) <= cols, `scope ${layout} at ${cols}:\n${stripAnsi(r.out)}`);
    });
    const r = inProc(["overview", "--cols", String(cols), "--color", "always"], ov);
    assert.ok(Math.max(...widths(stripAnsi(r.out))) <= cols, `overview at ${cols}`);
  }
});

// ---------------------------------------------------------------------------
// run
// ---------------------------------------------------------------------------

let failed = 0;
console.log(`TAP version 13\n1..${tests.length}`);
for (let i = 0; i < tests.length; i++) {
  const t = tests[i];
  try {
    await t.fn();
    console.log(`ok ${i + 1} - ${t.name}`);
  } catch (e) {
    failed++;
    console.log(`not ok ${i + 1} - ${t.name}`);
    String(e && e.stack ? e.stack : e).split("\n").slice(0, 14).forEach((l) => console.log(`# ${l}`));
  }
}
temps.forEach((d) => {
  try {
    removeTree(d);
  } catch (e) {
    /* leave it to the OS */
  }
});
process.exitCode = failed > 0 ? 1 : 0;
