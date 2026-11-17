// tests/lib-progress-parity.test.mjs - cross-renderer parity of the bash (--legacy) and Node progress renderers (E92_S08_T08)
//
// Run: node tests/lib-progress-parity.test.mjs   (tests/lib-progress-parity.bats wraps it so `j.test` discovers it)
//
// One fixture board (one epic, two stories, eleven tasks in every bucket, task and story dependencies giving ready and
// locked tasks) is drawn through the real entry points, once on the bash path (`--legacy`) and once on the Node default,
// in English and Swedish. The two must state the same NUMBERS (done, in progress, failed, rejected, denominator, the
// ready list, the unlocked-by pairs) and the same LABEL WORDS. Glyphs and layout are not compared.
//
//   numbers per story   run-progress.sh --legacy            against  run-progress.sh (Node after-task lines)
//                       j.status --legacy (story rows)      against  j.status <story> (Node scope run bar)
//   numbers per epic    the legacy story rows, summed       against  j.status (Node overview) and j.status <epic>
//   ready list          j.status --legacy <epic>            against  j.status <epic> (list line and message line)
//   unlocked-by pairs   The Node scope view prints one "X unlocked by Y + Z" line per LOCKED task, from its
//                       blocked_by. The bash renderer that prints that same fact is render-status-scope-view.sh
//                       ("Unlocks after: X <- Y, Z"), so those two are compared. The --legacy block
//                       (render-status-scope.sh) prints a different fact, one "X unlocked by Y" line per task that
//                       already HAS an unlocked_by; it is compared with the Node side of that fact, the shared structure
//                       module's `unlocked` list (lib/progress/dependency-structure.js buildDependencyStructure).
//   label words         the exact label-table text of in_progress, failed, rejected_note, ready_to_take and the fixed
//                       part of unlocked_by, in both outputs, en and sv
//
// Every expected number is ALSO written below from the fixture (EXPECT), so a change that moves both renderers the same
// way is caught as well. The controls at the end prove the comparison can fail: a count or a label word changed in
// either renderer's captured output, and one fixture value (a task status) changed for the Node run only.
//
// Speed: the Node runs get their label tables through JENGA_PROGRESS_SCRIPTS_DIR (the E92_S08_T04 seam): a scripts
// directory whose progress-labels-json.sh serves the tables captured ONCE from the real scripts/progress-labels-json.sh
// at the start of this file, and whose board-progress.sh execs the real one. Counts and words still come from the real
// sources; only the per-call fork cost of the label script is saved. The bash renderers run unchanged with a UTF-8
// locale (in LANG=C they transliterate the words, which is a charset effect, not a label difference). The Node runs
// get LANG and LC_ALL empty, as the agent's Bash tool has them.
//
//   scope-view arrows   (E92_S10_T03, rapport E92_S08_T08) the Node scope view's bands on this fixture: exact text at 120
//                       columns, and every arrow walked back to a dependency edge, every incoming edge shown as an arrow or
//                       a reference, the goal arrow exactly after the goal edges (horizontal, vertical, utf8, ascii); a
//                       control proves the walk rejects the old drawing
//
// No test framework: a plain runner on node's `assert`, printing TAP lines, exit code 1 when any test fails. Node >= 14.13.1.

import assert from "assert";
import { spawnSync } from "child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "fs";
import fsModule from "fs";
import { tmpdir } from "os";
import { dirname, join, resolve } from "path";
import { fileURLToPath } from "url";

import { buildDependencyStructure } from "../lib/progress/dependency-structure.js";
import { glyphsFor } from "../lib/progress/charset.js";
import { checkBand, walkBand } from "./helpers/scope-arrow-walk.mjs";

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const SCRIPTS = join(REPO, "scripts");
const RP = join(REPO, "skills", "j-break", "scripts", "run-progress.sh");
const RESOLVER = join(REPO, "skills", "j-status", "scripts", "resolve-status-mode.sh");
const SCOPE_VIEW = join(REPO, "skills", "j-status", "scripts", "render-status-scope-view.sh");
const ESC = "\u001b";
const COLS = "120";

// fs.rmSync came in Node 14.14; the floor is 14.13.1, where rmdirSync with recursive is the way.
const removeTree = (d) =>
  typeof fsModule.rmSync === "function" ? fsModule.rmSync(d, { recursive: true, force: true }) : fsModule.rmdirSync(d, { recursive: true });

// ---------------------------------------------------------------------------
// harness
// ---------------------------------------------------------------------------

const tests = [];
const test = (name, fn) => tests.push({ name, fn });
const temps = [];
const tmp = () => {
  const d = mkdtempSync(join(tmpdir(), "progress-parity-"));
  temps.push(d);
  return d;
};

// ---------------------------------------------------------------------------
// fixture board
// ---------------------------------------------------------------------------

// [id, status, title, depends_on]. Titles are short and unique, so a Node line (which names tasks by title) maps back
// to the id. E01_S02 depends on E01_S01, so its tasks are also blocked by that story.
const ITEMS = [
  ["E01", "In Progress", "Parity epic", ""],
  ["E01_S01", "In Progress", "Story one", ""],
  ["E01_S02", "Pending", "Story two", "E01_S01"],
  ["E01_S01_T01", "Passed", "Alpha", ""],
  ["E01_S01_T02", "Passed with remarks", "Bravo", ""],
  ["E01_S01_T03", "In Progress", "Charlie", "E01_S01_T01"],
  ["E01_S01_T04", "Failed", "Delta", ""],
  ["E01_S01_T05", "Rejected", "Echo", ""],
  ["E01_S01_T06", "Pending", "Foxtrot", "E01_S01_T03"],
  ["E01_S01_T07", "Pending", "Golf", "E01_S01_T01"],
  ["E01_S01_T08", "Pending", "Hotel", ""],
  ["E01_S02_T01", "Pending", "India", "E01_S01_T06"],
  ["E01_S02_T02", "Pending", "Juliet", "E01_S01_T04, E01_S01_T02"],
  ["E01_S02_T03", "Passed", "Kilo", ""],
];
const ID_OF_TITLE = {};
ITEMS.forEach(([id, , title]) => (ID_OF_TITLE[title] = id));

// What the fixture states, written by hand from ITEMS (Rejected is outside the denominator, E92 decision 3).
const EXPECT = {
  stories: {
    E01_S01: { done: 2, denominator: 7, in_progress: 1, failed: 1, rejected: 1 },
    E01_S02: { done: 1, denominator: 3, in_progress: 0, failed: 0, rejected: 0 },
  },
  epic: { done: 3, denominator: 10, in_progress: 1, failed: 1, rejected: 1 },
  ready: ["E01_S01_T07", "E01_S01_T08"],
  // locked task <- what it waits for (blocked_by: open task dependencies, plus the unfinished story it depends on)
  lockedPairs: ["E01_S01_T06<-E01_S01_T03", "E01_S02_T01<-E01_S01", "E01_S02_T01<-E01_S01_T06", "E01_S02_T02<-E01_S01", "E01_S02_T02<-E01_S01_T04"],
  // task <- the task that unlocked it (unlocked_by)
  unlockedPairs: ["E01_S01_T03<-E01_S01_T01", "E01_S01_T07<-E01_S01_T01"],
};

/** Writes the fixture board under a new root; `override` maps an id to a different status. */
function board(override) {
  const root = tmp();
  ["epics", "stories", "tasks"].forEach((d) => mkdirSync(join(root, "project", "board", d), { recursive: true }));
  mkdirSync(join(root, "project", "configs"), { recursive: true });
  writeFileSync(join(root, "project", "configs", "workflow.json"), "{}\n");
  ITEMS.forEach(([id, status, title, deps]) => {
    const isTask = /_T[0-9]+$/.test(id);
    const isStory = !isTask && /_S[0-9]+$/.test(id);
    const lines = ["---", `id: ${id}`];
    if (isTask) lines.push(`story_id: ${id.replace(/_T[0-9]+$/, "")}`);
    if (isTask || isStory) lines.push(`epic_id: ${id.split("_")[0]}`);
    lines.push(`title: "${title}"`, `status: ${(override && override[id]) || status}`);
    if (deps) lines.push(`depends_on: [${deps}]`);
    lines.push("---", "", `# ${title}`, "");
    writeFileSync(join(root, "project", "board", isTask ? "tasks" : isStory ? "stories" : "epics", `${id}_fixture.md`), lines.join("\n"));
  });
  return root;
}

// ---------------------------------------------------------------------------
// running the two paths
// ---------------------------------------------------------------------------

function sh(args, env) {
  const r = spawnSync("bash", args, { env, cwd: tmpdir(), encoding: "utf8" });
  assert.strictEqual(r.status, 0, `bash ${args.join(" ")} exited ${r.status}: ${r.stderr}`);
  assert.strictEqual(r.stderr, "", `bash ${args.join(" ")} warned: ${r.stderr}`);
  return r.stdout;
}

const baseEnv = (root, lang) => {
  const env = { PATH: process.env.PATH, HOME: process.env.HOME || tmpdir(), JENGA_PROJECT_ROOT: root };
  if (lang) env.JENGA_PROGRESS_LANG = lang;
  return env;
};

/** The label table of one language, read from the real script. */
function realLabels(lang) {
  const r = spawnSync("bash", [join(SCRIPTS, "progress-labels-json.sh")], { env: baseEnv(tmpdir(), lang), encoding: "utf8" });
  assert.strictEqual(r.status, 0, r.stderr);
  const doc = JSON.parse(r.stdout);
  assert.strictEqual(doc.lang, lang || "en");
  return doc.labels;
}

const LABELS = { en: realLabels(""), sv: realLabels("sv") };

/** The scripts directory the Node runs use: label tables from LABELS, board-progress.sh = the real one. */
const NODE_SCRIPTS = (() => {
  const dir = tmp();
  writeFileSync(join(dir, "labels-en.json"), JSON.stringify({ lang: "en", labels: LABELS.en }));
  writeFileSync(join(dir, "labels-sv.json"), JSON.stringify({ lang: "sv", labels: LABELS.sv }));
  writeFileSync(
    join(dir, "progress-labels-json.sh"),
    ['#!/usr/bin/env bash', 'dir="$(cd "$(dirname "$0")" && pwd)"', 'case "${JENGA_PROGRESS_LANG:-en}" in sv) cat "$dir/labels-sv.json" ;; *) cat "$dir/labels-en.json" ;; esac', ""].join("\n")
  );
  writeFileSync(join(dir, "board-progress.sh"), `#!/usr/bin/env bash\nexec bash "${join(SCRIPTS, "board-progress.sh")}" "$@"\n`);
  return dir;
})();

/** The bash path: a UTF-8 locale, so the words come out as the label table writes them. */
const bashEnv = (root, lang) => Object.assign(baseEnv(root, lang), { LC_ALL: "en_US.UTF-8", LANG: "en_US.UTF-8" });
/** The Node path: no locale at all, as in the agent's Bash tool. */
const nodeEnv = (root, lang) => Object.assign(baseEnv(root, lang), { LANG: "", LC_ALL: "", JENGA_PROGRESS_SCRIPTS_DIR: NODE_SCRIPTS });

const TASK_LIST = "E01_S01_T01,E01_S02_T03";
const run = {
  legacyLines: (root, lang) => sh([RP, "--scope", "story", "--task", TASK_LIST, "--legacy", "--color", "never", "--cols", COLS], bashEnv(root, lang)),
  nodeLines: (root, lang) => sh([RP, "--scope", "story", "--task", TASK_LIST, "--charset", "utf8", "--color", "never", "--cols", COLS], nodeEnv(root, lang)),
  legacyOverview: (root, lang) => sh([RESOLVER, "render", "--legacy", "--color", "never", "--cols", COLS, "--root", root], bashEnv(root, lang)),
  nodeOverview: (root, lang) => sh([RESOLVER, "render", "--charset", "utf8", "--color", "never", "--cols", COLS, "--root", root], nodeEnv(root, lang)),
  legacyScope: (root, lang, id) => sh([RESOLVER, "render", "--legacy", id, "--color", "never", "--cols", COLS, "--root", root], bashEnv(root, lang)),
  nodeScope: (root, lang, id) => sh([RESOLVER, "render", id, "--charset", "utf8", "--color", "never", "--cols", COLS, "--root", root], nodeEnv(root, lang)),
  scopeView: (root, lang, id) => sh([SCOPE_VIEW, id, "--color", "never", "--cols", COLS, "--root", root], bashEnv(root, lang)),
  graph: (root) => JSON.parse(sh([join(SCRIPTS, "board-progress.sh"), "--graph", "--within", "E01", "--root", root], baseEnv(root))),
};

// ---------------------------------------------------------------------------
// parsing: everything is read through the label table of the language, so a changed word is a missing count
// ---------------------------------------------------------------------------

const reEscape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
/** A label with %d as a number group. */
const labelRe = (label) => new RegExp(reEscape(label).replace(/%d/g, "([0-9]+)"));

/** The counts one progress line states: { done, denominator, in_progress, failed, rejected }. */
function counts(line, L) {
  assert.ok(line.indexOf(ESC) < 0, `colour in an uncoloured run: ${JSON.stringify(line)}`);
  const frac = /([0-9]+)\/([0-9]+)/.exec(line);
  assert.ok(frac, `no n/total in ${JSON.stringify(line)}`);
  const n = (re) => {
    const m = re.exec(line);
    return m ? Number(m[1]) : 0;
  };
  return {
    done: Number(frac[1]),
    denominator: Number(frac[2]),
    in_progress: n(new RegExp(`([0-9]+) ${reEscape(L.in_progress)}(?![^ \u00b7|-])`)),
    failed: n(new RegExp(`([0-9]+) ${reEscape(L.failed)}(?![^ \u00b7|-])`)),
    rejected: n(labelRe(L.rejected_note)),
  };
}

const sum = (list) =>
  list.reduce((a, c) => ({ done: a.done + c.done, denominator: a.denominator + c.denominator, in_progress: a.in_progress + c.in_progress, failed: a.failed + c.failed, rejected: a.rejected + c.rejected }), {
    done: 0,
    denominator: 0,
    in_progress: 0,
    failed: 0,
    rejected: 0,
  });

const nonEmpty = (out) => out.split("\n").filter((l) => l.trim() !== "");

/** Legacy after-task lines are unlabelled bars in first-seen story order; Node lines lead with the story id. */
function linesPerStory(legacyOut, nodeOut, L) {
  const stories = ["E01_S01", "E01_S02"];
  const legacy = nonEmpty(legacyOut);
  const node = nonEmpty(nodeOut);
  assert.strictEqual(legacy.length, stories.length, `legacy lines: ${legacyOut}`);
  assert.strictEqual(node.length, stories.length, `node lines: ${nodeOut}`);
  const out = {};
  stories.forEach((s, i) => {
    assert.ok(node[i].indexOf(`${s} `) === 0, `Node line ${i + 1} does not lead with ${s}: ${node[i]}`);
    out[s] = { legacy: counts(legacy[i], L), node: counts(node[i], L) };
  });
  return out;
}

/** The legacy overview's story rows: { E01_S01: counts, ... } (rows lead with the id and a tab). */
function legacyStoryRows(out, L) {
  const rows = {};
  nonEmpty(out).forEach((l) => {
    const m = /^(E[0-9]+_S[0-9]+)\t/.exec(l);
    if (m) rows[m[1]] = counts(l, L);
  });
  return rows;
}

/** The run bar line of a Node scope view: the line that leads with the scope id and two spaces. */
function nodeScopeBar(out, id, L) {
  const line = nonEmpty(out).filter((l) => l.indexOf(`${id}  `) === 0)[0];
  assert.ok(line, `no run bar for ${id} in: ${out}`);
  return counts(line, L);
}

/** The Node overview's total run bar: the first indented line with n/total. */
function nodeOverviewBar(out, L) {
  const line = nonEmpty(out).filter((l) => /^\s+\S.*[0-9]+\/[0-9]+/.test(l))[0];
  assert.ok(line, `no total bar in: ${out}`);
  return counts(line, L);
}

const toId = (token) => {
  const t = token.trim();
  if (/^E[0-9]+(_S[0-9]+(_T[0-9]+)?)?$/.test(t)) return t;
  assert.ok(ID_OF_TITLE[t], `unknown title in a Node line: ${JSON.stringify(t)}`);
  return ID_OF_TITLE[t];
};

/** Ready ids of the legacy scope block: the id lines under the ready_to_take heading. */
function legacyReady(out, L) {
  const lines = out.split("\n");
  const at = lines.indexOf(L.ready_to_take);
  assert.ok(at >= 0, `no "${L.ready_to_take}" heading in: ${out}`);
  const ids = [];
  for (let i = at + 1; i < lines.length && lines[i].trim() !== ""; i++) {
    const m = /(E[0-9]+_S[0-9]+_T[0-9]+)/.exec(lines[i]);
    if (m) ids.push(m[1]);
  }
  return ids;
}

/** Ready ids of the Node scope view: the list line (titles) and, in an epic view, the message line (ids). */
function nodeReady(out, L, glyphSep) {
  const head = `${L.ready_to_take}: `;
  const list = out.split("\n").filter((l) => l.indexOf(head) === 0)[0];
  assert.ok(list, `no "${head}" list line in: ${out}`);
  const fromList = list.slice(head.length).split(` ${glyphSep} `).map(toId);
  const msg = out.split("\n").filter((l) => l.indexOf(head) > 0)[0];
  const fromMessage = msg ? msg.slice(msg.indexOf(head) + head.length).split(", ").map((s) => s.replace(/ \(\+[0-9]+\)$/, "").trim()) : null;
  return { fromList, fromMessage };
}

/** The fixed text between the two %s of unlocked_by ("unlocked by" in en). */
const unlockedMid = (L) => {
  const parts = L.unlocked_by.split("%s");
  assert.strictEqual(parts.length, 3, `unlocked_by has not two %s: ${L.unlocked_by}`);
  return parts[1];
};

/** "X<-Y" pairs from the Node scope view's unlocked-by lines (one line per locked task, blockers joined by " + "). */
function nodeLockedPairs(out, L) {
  const mid = unlockedMid(L);
  const pairs = [];
  nonEmpty(out).forEach((l) => {
    const at = l.indexOf(mid);
    if (at <= 0 || l.indexOf(`${L.ready_to_take}`) === 0) return;
    const left = toId(l.slice(0, at));
    l.slice(at + mid.length)
      .split(" + ")
      .forEach((y) => pairs.push(`${left}<-${toId(y)}`));
  });
  return pairs.sort();
}

/** "X<-Y" pairs from render-status-scope-view.sh's sc_unlocks_after section ("  X <- Y, Z"; the arrow is a glyph). */
function scopeViewLockedPairs(out, L) {
  const lines = out.split("\n");
  const at = lines.indexOf(L.sc_unlocks_after);
  assert.ok(at >= 0, `no "${L.sc_unlocks_after}" section in: ${out}`);
  const pairs = [];
  for (let i = at + 1; i < lines.length && lines[i].trim() !== ""; i++) {
    const m = /^\s*(\S+) (?:<-|\u2190) (.+)$/.exec(lines[i]);
    assert.ok(m, `unexpected line: ${lines[i]}`);
    m[2].split(", ").forEach((y) => pairs.push(`${m[1]}<-${y.trim()}`));
  }
  return pairs.sort();
}

/** "X<-Y" pairs from the --legacy block's "X unlocked by Y" lines (ids on both sides). */
function legacyUnlockedPairs(out, L) {
  const mid = unlockedMid(L);
  return nonEmpty(out)
    .map((l) => l.trim())
    .filter((l) => /^E[0-9]+_S[0-9]+_T[0-9]+ /.test(l) && l.indexOf(mid) > 0)
    .map((l) => `${l.slice(0, l.indexOf(mid))}<-${l.slice(l.indexOf(mid) + mid.length)}`)
    .sort();
}

/** The same fact from the Node side: the shared structure module's `unlocked` list, through the same label. */
function structureUnlockedPairs(graph, L) {
  const s = buildDependencyStructure(graph, "E01", L);
  const mid = unlockedMid(L);
  return s.unlocked.map((u) => `${u.text.slice(0, u.text.indexOf(mid))}<-${u.text.slice(u.text.indexOf(mid) + mid.length)}`).sort();
}

// ---------------------------------------------------------------------------
// the comparison (pure, so the controls can feed it changed outputs)
// ---------------------------------------------------------------------------

/** Every number and word the two paths must agree on, for one language. Throws on the first difference. */
function compare(o, L) {
  // per story: the after-task lines
  const per = linesPerStory(o.legacyLines, o.nodeLines, L);
  Object.keys(EXPECT.stories).forEach((s) => {
    assert.deepStrictEqual(per[s].node, per[s].legacy, `after-task line of ${s}: Node and --legacy disagree`);
    assert.deepStrictEqual(per[s].node, EXPECT.stories[s], `after-task line of ${s}: not what the fixture states`);
  });
  // per story: the legacy overview rows against the Node scope view's run bar
  const rows = legacyStoryRows(o.legacyOverview, L);
  Object.keys(EXPECT.stories).forEach((s) => {
    assert.ok(rows[s], `no legacy overview row for ${s}`);
    if (o.nodeScopes[s]) assert.deepStrictEqual(nodeScopeBar(o.nodeScopes[s], s, L), rows[s], `j.status ${s}: Node and --legacy disagree`);
    assert.deepStrictEqual(rows[s], EXPECT.stories[s], `legacy overview row ${s}: not what the fixture states`);
  });
  // per epic: the story rows summed against the Node overview and the Node epic view
  const epic = sum(Object.keys(EXPECT.stories).map((s) => rows[s]));
  assert.deepStrictEqual(nodeOverviewBar(o.nodeOverview, L), epic, "j.status overview total: Node and the --legacy rows disagree");
  assert.deepStrictEqual(nodeScopeBar(o.nodeScopes.E01, "E01", L), epic, "j.status E01 run bar: Node and the --legacy rows disagree");
  assert.deepStrictEqual(epic, EXPECT.epic, "epic totals: not what the fixture states");
  // ready list
  const lr = legacyReady(o.legacyScope, L);
  const nr = nodeReady(o.nodeScopes.E01, L, o.sep);
  assert.deepStrictEqual(nr.fromList, lr, "ready list: Node and --legacy disagree");
  assert.deepStrictEqual(nr.fromMessage, lr, "ready ids of the Node message line and the --legacy list disagree");
  assert.deepStrictEqual(lr, EXPECT.ready, "ready list: not what the fixture states");
  // unlocked-by pairs
  const np = nodeLockedPairs(o.nodeScopes.E01, L);
  assert.deepStrictEqual(np, scopeViewLockedPairs(o.scopeView, L), "unlocked-by pairs of locked tasks: Node and render-status-scope-view.sh disagree");
  assert.deepStrictEqual(np, EXPECT.lockedPairs.slice().sort(), "unlocked-by pairs of locked tasks: not what the fixture states");
  const lp = legacyUnlockedPairs(o.legacyScope, L);
  assert.deepStrictEqual(lp, structureUnlockedPairs(o.graph, L), "unlocked_by pairs: the --legacy block and the shared structure module disagree");
  assert.deepStrictEqual(lp, EXPECT.unlockedPairs.slice().sort(), "unlocked_by pairs: not what the fixture states");
  // label words, verbatim from the table, in both paths
  const word = (key, text) => [text, key];
  [word("in_progress", ` ${L.in_progress}`), word("failed", ` ${L.failed}`), word("rejected_note", L.rejected_note.replace("%d", "1"))].forEach(([w, key]) => {
    assert.ok(o.legacyLines.indexOf(w) >= 0, `--legacy lines lack the ${key} label ${JSON.stringify(w)}`);
    assert.ok(o.nodeLines.indexOf(w) >= 0, `Node lines lack the ${key} label ${JSON.stringify(w)}`);
    assert.ok(o.legacyOverview.indexOf(w) >= 0, `--legacy overview lacks the ${key} label ${JSON.stringify(w)}`);
    assert.ok(o.nodeScopes.E01.indexOf(w) >= 0, `Node scope view lacks the ${key} label ${JSON.stringify(w)}`);
  });
  [word("ready_to_take", L.ready_to_take), word("unlocked_by", unlockedMid(L))].forEach(([w, key]) => {
    assert.ok(o.legacyScope.indexOf(w) >= 0, `--legacy scope block lacks the ${key} label ${JSON.stringify(w)}`);
    assert.ok(o.nodeScopes.E01.indexOf(w) >= 0, `Node scope view lacks the ${key} label ${JSON.stringify(w)}`);
  });
}

// ---------------------------------------------------------------------------
// the runs, done once per language and shared by the tests
// ---------------------------------------------------------------------------

const ROOT = board();
const GRAPH = run.graph(ROOT);
const UTF8_SEP = "\u00b7"; // the list separator of the utf8 glyph table (charset.js GLYPHS.utf8.sep)

function outputs(root, lang, withStoryScopes) {
  const o = {
    legacyLines: run.legacyLines(root, lang),
    nodeLines: run.nodeLines(root, lang),
    legacyOverview: run.legacyOverview(root, lang),
    nodeOverview: run.nodeOverview(root, lang),
    legacyScope: run.legacyScope(root, lang, "E01"),
    scopeView: run.scopeView(root, lang, "E01"),
    nodeScopes: { E01: run.nodeScope(root, lang, "E01") },
    graph: GRAPH,
    sep: UTF8_SEP,
  };
  if (withStoryScopes) Object.keys(EXPECT.stories).forEach((s) => (o.nodeScopes[s] = run.nodeScope(root, lang, s)));
  return o;
}

const OUT = { en: outputs(ROOT, "", true), sv: outputs(ROOT, "sv", false) };

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

test("the fixture graph is what EXPECT says: ready list, blocked_by and unlocked_by as written by hand", () => {
  assert.deepStrictEqual(GRAPH.ready, EXPECT.ready);
  const locked = [];
  const unlocked = [];
  GRAPH.tasks.forEach((t) => {
    if (t.state === "locked") (t.blocked_by || []).forEach((b) => locked.push(`${t.id}<-${b}`));
    if (t.unlocked_by) unlocked.push(`${t.id}<-${t.unlocked_by}`);
  });
  assert.deepStrictEqual(locked.sort(), EXPECT.lockedPairs.slice().sort());
  assert.deepStrictEqual(unlocked.sort(), EXPECT.unlockedPairs.slice().sort());
});

test("the two paths really differ in drawing (so the comparison is between two renderers, not one twice)", () => {
  assert.notStrictEqual(OUT.en.nodeLines, OUT.en.legacyLines);
  assert.ok(/^E01_S01  /.test(OUT.en.nodeLines) && !/^E01_S01/.test(OUT.en.legacyLines));
  assert.notStrictEqual(OUT.en.nodeScopes.E01, OUT.en.legacyScope);
});

test("en: the same numbers (done, in progress, failed, rejected, denominator, ready list, unlocked-by pairs) and label words in both renderers", () => {
  compare(OUT.en, LABELS.en);
});

test("sv: the same numbers and the same Swedish label words in both renderers", () => {
  assert.notStrictEqual(LABELS.sv.in_progress, LABELS.en.in_progress, "the sv table is not Swedish");
  compare(OUT.sv, LABELS.sv);
  // the English words are not in the Swedish output of either path
  [OUT.sv.legacyLines, OUT.sv.nodeLines, OUT.sv.nodeScopes.E01, OUT.sv.legacyScope].forEach((o) => assert.ok(o.indexOf(LABELS.en.ready_to_take) < 0 && o.indexOf(` ${LABELS.en.in_progress}`) < 0));
});

// ---- every word the Node renderer prints comes from the label table -------------------------------------------------
//
// The behavioural form of "the Node code holds no user-visible word" (E92_S08 acceptance criterion "Data and labels
// unchanged"). The source scan in tests/lib-progress-core.test.mjs (test 50) cannot tell a bucket or style key such as
// "pending" from the label word "pending"; this test can: every command draws the fixture board with a label table whose
// values are sentinels (`<<key>>`, placeholders kept), and no word of the real en or sv table may appear in the output.

const SENTINEL_LABELS = (() => {
  const out = {};
  Object.keys(LABELS.en).forEach((k) => {
    const holes = String(LABELS.en[k]).match(/%[ds%]/g) || [];
    out[k] = k === "unlocked_by" ? `%s <<${k}>> %s` : `<<${k}>>${holes.map((h) => ` ${h}`).join("")}`;
  });
  return out;
})();

const SENTINEL_SCRIPTS = (() => {
  const dir = tmp();
  writeFileSync(join(dir, "labels.json"), JSON.stringify({ lang: "en", labels: SENTINEL_LABELS }));
  writeFileSync(join(dir, "progress-labels-json.sh"), '#!/usr/bin/env bash\ncat "$(cd "$(dirname "$0")" && pwd)/labels.json"\n');
  writeFileSync(join(dir, "board-progress.sh"), `#!/usr/bin/env bash\nexec bash "${join(SCRIPTS, "board-progress.sh")}" "$@"\n`);
  return dir;
})();

test("every word the Node renderer prints comes from the label table: with sentinel labels no en or sv label word is left (all commands)", () => {
  const CLI = join(REPO, "lib", "progress", "cli.js");
  const env = Object.assign(baseEnv(ROOT), { LANG: "", LC_ALL: "", JENGA_PROGRESS_SCRIPTS_DIR: SENTINEL_SCRIPTS });
  const calls = [
    ["overview"],
    ["scope", "E01"],
    ["scope", "E01", "--layout", "vertical"],
    ["scope", "E01", "--layout", "horizontal"],
    ["scope", "E01_S01"],
    ["scope", "E01_S02"],
    ["bar", "--epic", "E01"],
    ["bar", "--each", "stories"],
    ["after-task", "--story", "E01_S01,E01_S02"],
    ["after-story", "--story", "E01_S01", "--ready", "2"],
  ];
  const fixtureWords = new Set();
  ITEMS.forEach(([id, , title]) => (id + " " + title).split(/[^A-Za-z]+/).forEach((w) => fixtureWords.add(w.toLowerCase())));
  // the words of both real tables, placeholders and glyphs removed; short words cannot be told from an id fragment
  const words = new Set();
  ["en", "sv"].forEach((lang) =>
    Object.keys(LABELS[lang]).forEach((k) =>
      String(LABELS[lang][k])
        .replace(/%[ds%]/g, " ")
        .split(/[^A-Za-z\u00c0-\u00ff]+/)
        .filter((w) => w.length >= 4 && !fixtureWords.has(w.toLowerCase()))
        .forEach((w) => words.add(w))
    )
  );
  assert.ok(words.size >= 40, `the label tables look too small: ${words.size} words`);
  const hit = (w, text) => new RegExp(`(^|[^A-Za-z\u00c0-\u00ff])${w}($|[^A-Za-z\u00c0-\u00ff])`, "i").test(text);
  // the scan bites: a hard-coded "pending" (a bucket key AND an en label word) or a Swedish word would be found
  assert.ok(words.has("pending") && hit("pending", "  \u25cb 5 pending") && hit("p\u00e5g\u00e5r", "1 p\u00e5g\u00e5r \u00b7"));
  let sentinels = 0;
  calls.forEach((args) => {
    const r = spawnSync(process.execPath, [CLI, "--charset", "utf8", "--color", "never", "--cols", COLS, "--root", ROOT].concat(args), { env, cwd: tmpdir(), encoding: "utf8" });
    assert.strictEqual(r.status, 0, `${args.join(" ")}: ${r.stderr}`);
    assert.strictEqual(r.stderr, "", `${args.join(" ")} warned: ${r.stderr}`);
    assert.ok(r.stdout.trim() !== "", `${args.join(" ")} drew nothing`);
    const found = (r.stdout.match(/<<[a-z_]+>>/g) || []).length;
    sentinels += found;
    const text = r.stdout.replace(/<<[a-z_]+>>/g, " "); // a sentinel key itself holds words such as "progress"
    words.forEach((w) => assert.ok(!hit(w, text), `${args.join(" ")} prints the word ${JSON.stringify(w)} that is not from the label table:\n${r.stdout}`));
  });
  assert.ok(sentinels >= calls.length, `only ${sentinels} sentinel labels were drawn: the table was not used`);
});

// ---- E92_S10_T03: the scope view draws an arrow only along a real dependency edge -------------------------------------
//
// Regression case of rapport project/rapports/problems/E92_S08_T08-scope-view-arrows-imply-edges-that-do-not-exist.md:
// on this fixture the old layout drew "Hotel -> Charlie", "Delta -> Golf" and "Kilo -> Juliet -> India" (no such edges)
// and showed neither Alpha -> Golf nor the cross-story dependencies of Juliet and India. User decision 2026-11-15: every
// arrow is a real dependency and no in-scope dependency is invisible. The rule and the reference form are in
// project/documentation/progress-visualisation.md section 30.5; tests/helpers/scope-arrow-walk.mjs reads the arrows back.

const STRUCTURE = buildDependencyStructure(GRAPH, "E01", LABELS.en);
const NAMES = new Map(ITEMS.filter(([id]) => /_T[0-9]+$/.test(id)).map(([id, , title]) => [title, id]));

/** cli.js scope E01 on the fixture board (Node path, no locale). */
function nodeScopeCli(args) {
  const r = spawnSync(process.execPath, [join(REPO, "lib", "progress", "cli.js"), "--color", "never", "--root", ROOT, "scope", "E01"].concat(args), { env: nodeEnv(ROOT, ""), cwd: tmpdir(), encoding: "utf8" });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.strictEqual(r.stderr, "");
  return r.stdout;
}

/** The text rows of one band (below its header line, up to the blank line). */
function bandRows(out, title) {
  const ls = out.split("\n");
  const at = ls.findIndex((l) => l.indexOf(`${title} `) === 0);
  assert.ok(at >= 0, `no band ${title} in:\n${out}`);
  const rows = [];
  for (let i = at + 1; i < ls.length && ls[i] !== ""; i++) rows.push(ls[i]);
  return rows;
}

// The E01 bands of `j.status E01` at 120 columns (auto layout: both bands fit, so both are horizontal).
// E92_S11_T01: Charlie is In Progress, so its mark is the in-progress half dot ◐ (it shared the ready ◉ before, told apart
// by colour only); Hotel and Golf are ready and keep ◉.
// E92_S11_T02: Kilo is Passed although its story (Story two) depends on Story one, which is In Progress, so
// board-progress.sh states unfinished_deps ["E01_S01"] for it and its mark is the "?" of a done task whose dependency is not
// done (it was ●); nothing else of the bands changes.
const EXPECT_BANDS = {
  "STORY ONE": [
    "      ◉ Hotel         ───▸⚑",
    "      ✕ Delta",
    "      ● Alpha         ─┬─▸◐ Charlie       ───▸○ Foxtrot",
    "                       └─▸◉ Golf          ───▸⚑",
    "      ● Bravo",
    "      ⊘ Echo          ───▸⚑",
  ],
  "STORY TWO": [
    "      ? Kilo          ───▸⚑",
    "                          ○ Juliet         ◂─ S01_T02,S01_T04 ───▸⚑",
    "                                                                                      ○ India          ◂─ S01_T06 ───▸⚑",
  ],
};

test("E92_S10_T03 regression (rapport E92_S08_T08): j.status E01 draws the bands with only real arrows, Alpha forks to Charlie and Golf, references for the cross-story dependencies", () => {
  Object.keys(EXPECT_BANDS).forEach((title) => assert.deepStrictEqual(bandRows(OUT.en.nodeScopes.E01, title), EXPECT_BANDS[title], `band ${title}:\n${OUT.en.nodeScopes.E01}`));
  const all = Object.keys(EXPECT_BANDS)
    .map((t) => bandRows(OUT.en.nodeScopes.E01, t).join("\n"))
    .join("\n");
  // the three false arrows of the rapport are gone
  [/Hotel\s*─+▸[◉◐] Charlie/, /Delta\s*─+▸◉ Golf/, /Kilo\s*─+▸○ Juliet/, /Juliet\s*─+▸○ India/].forEach((re) => assert.ok(!re.test(all), `still drawn: ${re}`));
});

test("E92_S10_T03: on the E01 fixture every arrow is a dependency edge, every incoming edge is an arrow or a reference, and the goal arrow follows exactly the goal edges (horizontal and vertical, utf8 and ascii)", () => {
  let checked = 0;
  ["horizontal", "vertical"].forEach((layout) =>
    ["utf8", "ascii"].forEach((charset) => {
      const out = nodeScopeCli(["--cols", "200", "--charset", charset, "--layout", layout]);
      if (charset === "ascii") assert.ok(Array.from(Buffer.from(out, "utf8")).every((b) => b < 0x80), `${layout} ascii is not pure ASCII:\n${out}`);
      const walks = {};
      STRUCTURE.bands.forEach((band) => {
        const title = STRUCTURE.stories.find((s) => s.storyId === band.storyId).title.toUpperCase();
        const walk = walkBand(bandRows(out, title), layout, glyphsFor(charset), NAMES);
        assert.deepStrictEqual(checkBand(walk, STRUCTURE, band), [], `${layout} ${charset} ${band.storyId}:\n${out}`);
        walks[band.storyId] = walk;
        checked += walk.arrows.length;
      });
      const arrows = walks.E01_S01.arrows.concat(walks.E01_S02.arrows).map((a) => `${a.from}>${a.to}`).sort();
      assert.deepStrictEqual(arrows, ["E01_S01_T01>E01_S01_T03", "E01_S01_T01>E01_S01_T07", "E01_S01_T03>E01_S01_T06"], `${layout} ${charset}`);
      assert.deepStrictEqual(walks.E01_S02.refs, { E01_S02_T02: ["S01_T02", "S01_T04"], E01_S02_T01: ["S01_T06"] }, `${layout} ${charset}`);
      // the goal arrows the old "last column of the row" rule hid (Hotel, Kilo, Juliet) are drawn
      ["E01_S01_T08", "E01_S02_T03", "E01_S02_T02"].forEach((id) => assert.ok(walks[id.slice(0, 7)].goals.indexOf(id) >= 0, `${layout} ${charset}: no goal arrow after ${id}`));
    })
  );
  assert.strictEqual(checked, 12, "three arrows in each of four renderings");
});

test("E92_S10_T03 control: the arrow walk rejects the old drawing of the rapport (false arrows, hidden edges, hidden goal arrows)", () => {
  const old = {
    E01_S01: [
      "      ◉ Hotel         ───▸◉ Charlie       ───▸○ Foxtrot",
      "      ✕ Delta         ───▸◉ Golf          ───▸⚑",
      "      ● Alpha",
      "      ● Bravo",
      "      ⊘ Echo          ───▸⚑",
    ],
    E01_S02: ["      ● Kilo          ───▸○ Juliet                            ───▸○ India         ───▸⚑"],
  };
  const problems = STRUCTURE.bands.map((band) => checkBand(walkBand(old[band.storyId], "horizontal", glyphsFor("utf8"), NAMES), STRUCTURE, band)).reduce((a, b) => a.concat(b), []);
  ["E01_S01_T08 -> E01_S01_T03", "E01_S01_T04 -> E01_S01_T07", "E01_S02_T03 -> E01_S02_T02", "E01_S02_T02 -> E01_S02_T01"].forEach((arrow) =>
    assert.ok(problems.some((p) => p.indexOf(`arrow ${arrow} is not a dependency edge`) === 0), `not caught: ${arrow}\n${problems.join("\n")}`)
  );
  assert.ok(problems.some((p) => /^E01_S02_T02: incoming edges \[E01_S01_T02,E01_S01_T04\]/.test(p)), problems.join("\n"));
  assert.ok(problems.some((p) => p === "E01_S01_T08: goal edge true, goal arrows drawn 0"), problems.join("\n"));
});

// ---- controls: the comparison fails when either renderer changes a count or a word, or sees other data ----------------

const clone = (o) => Object.assign({}, o, { nodeScopes: Object.assign({}, o.nodeScopes) });
// A control is only meaningful when the unchanged outputs pass: each one checks that first.
const baseline = () => {
  assert.doesNotThrow(() => compare(OUT.en, LABELS.en));
  assert.doesNotThrow(() => compare(OUT.sv, LABELS.sv));
};
const fails = (o, L, what) => assert.throws(() => compare(o, L), assert.AssertionError, `not caught: ${what}`);

test("control: a count changed in either renderer's output is caught (after-task line, overview row, epic bar)", () => {
  baseline();
  let o = clone(OUT.en);
  o.nodeLines = o.nodeLines.replace(" 2/7", " 3/7");
  fails(o, LABELS.en, "Node after-task done count");
  o = clone(OUT.en);
  o.legacyLines = o.legacyLines.replace(" 1 red", " 2 red");
  fails(o, LABELS.en, "--legacy after-task failed count");
  o = clone(OUT.en);
  o.legacyOverview = o.legacyOverview.replace("1/3", "1/4");
  fails(o, LABELS.en, "--legacy overview denominator");
  o = clone(OUT.en);
  o.nodeScopes.E01 = o.nodeScopes.E01.replace("3/10", "3/11");
  fails(o, LABELS.en, "Node epic run bar denominator");
});

test("control: a label word changed in either renderer's output is caught, en and sv", () => {
  baseline();
  let o = clone(OUT.en);
  o.nodeLines = o.nodeLines.split(" in progress").join(" in-progress");
  fails(o, LABELS.en, "Node in_progress word");
  o = clone(OUT.en);
  o.legacyScope = o.legacyScope.split("unlocked by").join("unblocked by");
  fails(o, LABELS.en, "--legacy unlocked_by word");
  o = clone(OUT.sv);
  o.nodeScopes.E01 = o.nodeScopes.E01.split(LABELS.sv.ready_to_take).join("Redo att tas");
  fails(o, LABELS.sv, "Node sv ready_to_take word");
  o = clone(OUT.sv);
  o.legacyLines = o.legacyLines.split(LABELS.sv.failed).join("rod");
  fails(o, LABELS.sv, "--legacy sv failed word");
});

test("control: a ready id or an unlocked-by pair changed in either renderer is caught", () => {
  baseline();
  let o = clone(OUT.en);
  o.nodeScopes.E01 = o.nodeScopes.E01.replace(`: Golf ${UTF8_SEP} Hotel`, ": Golf");
  fails(o, LABELS.en, "Node ready list shortened");
  o = clone(OUT.en);
  o.scopeView = o.scopeView.replace(/E01_S01_T06 (<-|\u2190) E01_S01_T03/, "E01_S01_T06 $1 E01_S01_T02");
  assert.notStrictEqual(o.scopeView, OUT.en.scopeView);
  fails(o, LABELS.en, "bash Unlocks after pair");
  o = clone(OUT.en);
  o.legacyScope = o.legacyScope.replace("E01_S01_T07 unlocked by E01_S01_T01", "E01_S01_T07 unlocked by E01_S01_T02");
  fails(o, LABELS.en, "--legacy unlocked by pair");
});

test("control: one fixture value changed for the Node run only (Delta Failed -> Passed) makes the comparison fail", () => {
  baseline();
  const mutated = board({ E01_S01_T04: "Passed" });
  const o = clone(OUT.en);
  o.nodeLines = run.nodeLines(mutated, "");
  assert.notStrictEqual(o.nodeLines, OUT.en.nodeLines, "the mutated board drew the same lines");
  fails(o, LABELS.en, "a fixture status changed for Node only");
});

// ---------------------------------------------------------------------------
// run
// ---------------------------------------------------------------------------

let failed = 0;
console.log(`TAP version 13\n1..${tests.length}`);
tests.forEach((t, i) => {
  try {
    t.fn();
    console.log(`ok ${i + 1} - ${t.name}`);
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
