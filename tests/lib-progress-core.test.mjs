// tests/lib-progress-core.test.mjs - tests for the Node render core under lib/progress (E92_S08_T03)
//
// Run: node tests/lib-progress-core.test.mjs   (tests/lib-progress-core.bats wraps it so `j.test` discovers it)
//
// Covers: charset and colour precedence (flag, environment variable, config key, default) for both settings,
// LANG and LC_* never consulted, the one-cell width pin for every glyph of both tables, labels (en and sv) read from
// scripts/progress-labels-json.sh, data.js against board-progress.sh, the never-fail rule and the usage exit code of
// cli.js, and a scan that bans post-Node-14 APIs and user-visible words under lib/progress/.
//
// No test framework: a plain runner on node's `assert`, printing TAP lines, exit code 1 when any test fails. Every
// fixture lives under a fresh temp directory; this repository's own project/ is never read or written.

import assert from "assert";
import { spawnSync } from "child_process";
import { copyFileSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from "fs";
import fsModule from "fs";
import { tmpdir } from "os";
import { dirname, join, resolve } from "path";
import { fileURLToPath } from "url";

import { CHARSETS, GLYPHS, glyphsFor, resolveCharset } from "../lib/progress/charset.js";
import { COLOR_MODES, SGR, createPainter, resolveColor, stripAnsi } from "../lib/progress/color.js";
import { COMMANDS, run } from "../lib/progress/cli.js";
import { readProgressConfig, resolveChoice } from "../lib/progress/config.js";
import { findScriptsDir, readBoardProgress, runScript } from "../lib/progress/data.js";
import { formatLabel, loadLabels } from "../lib/progress/labels.js";
import { displayWidth, padEnd, parseCols, resolveWidth, truncate } from "../lib/progress/width.js";

// fs.rmSync came in Node 14.14; the floor is 14.13.1 (package.json engines), where a named import of it fails to link and
// the whole file would not run. rmdirSync with recursive exists there (deprecated later, so it is only the fallback).
const removeTree = (d) =>
  typeof fsModule.rmSync === "function" ? fsModule.rmSync(d, { recursive: true, force: true }) : fsModule.rmdirSync(d, { recursive: true });

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const CLI = join(REPO, "lib", "progress", "cli.js");
const SCRIPTS = join(REPO, "scripts");
const PROGRESS_DIR = join(REPO, "lib", "progress");
const ESC = "\u001b";

// ---------------------------------------------------------------------------
// harness
// ---------------------------------------------------------------------------

const tests = [];
const test = (name, fn) => tests.push({ name, fn });
const temps = [];

function tmp() {
  const d = mkdtempSync(join(tmpdir(), "jenga-progress-core-"));
  temps.push(d);
  return d;
}

/** A project root with a registry, an optional dashboard-config.json and a three-task board. */
function fixtureProject(config) {
  const root = tmp();
  mkdirSync(join(root, "project", "configs"), { recursive: true });
  for (const d of ["epics", "stories", "tasks"]) mkdirSync(join(root, "project", "board", d), { recursive: true });
  writeFileSync(join(root, "project", "configs", "workflow.json"), "{}\n");
  if (config !== undefined) {
    const text = typeof config === "string" ? config : `${JSON.stringify(config, null, 2)}\n`;
    writeFileSync(join(root, "project", "configs", "dashboard-config.json"), text);
  }
  const item = (dir, id, extra) =>
    writeFileSync(join(root, "project", "board", dir, `${id}_x.md`), `---\nid: ${id}\n${extra}title: "Fixture ${id}"\n---\n\n# ${id}\n`);
  item("epics", "E01", "status: In Progress\n");
  item("stories", "E01_S01", "epic_id: E01\nstatus: In Progress\n");
  item("tasks", "E01_S01_T01", "story_id: E01_S01\nepic_id: E01\nstatus: Passed\n");
  item("tasks", "E01_S01_T02", "story_id: E01_S01\nepic_id: E01\nstatus: In Progress\n");
  item("tasks", "E01_S01_T03", "story_id: E01_S01\nepic_id: E01\nstatus: Pending\ndepends_on: [E01_S01_T01]\n");
  return root;
}

/** Run the real CLI in a clean environment (no inherited locale or colour variables), stdout a pipe. */
function cli(args, opts) {
  const o = opts || {};
  const env = Object.assign({ PATH: process.env.PATH, HOME: process.env.HOME || tmpdir() }, o.env || {});
  if (o.root) env.JENGA_PROJECT_ROOT = o.root;
  const r = spawnSync(process.execPath, [CLI].concat(args), { env, cwd: o.cwd || tmpdir(), encoding: "buffer" });
  return { status: r.status, stdout: r.stdout, stderr: r.stderr, out: r.stdout.toString("utf8"), err: r.stderr.toString("utf8") };
}

/**
 * Run cli.js in-process with injected io (needed for a TTY, which a spawned pipe cannot be). The working directory is
 * a fixture project without the progress keys, so a developer's own dashboard-config.json can never leak in.
 */
let inProcessCwd = null;
function inProcess(args, io) {
  if (inProcessCwd === null) inProcessCwd = fixtureProject({ dashboard_port: 58150 });
  const out = [];
  const err = [];
  const base = { out: (s) => out.push(s), err: (s) => err.push(s), env: { PATH: process.env.PATH }, cwd: inProcessCwd };
  const code = run(args, Object.assign(base, io || {}));
  return { code, out: out.join(""), err: err.join(""), errLines: err.join("").split("\n").filter((l) => l !== "") };
}

const hasEsc = (text) => text.indexOf(ESC) >= 0;
const allAscii = (buf) => Array.from(buf).every((b) => b < 0x80);
const settingsLine = (out, name) => out.split("\n").find((l) => l.indexOf(`${name}=`) === 0);
const GLYPH_NAMES = Object.keys(GLYPHS.utf8);

// ---------------------------------------------------------------------------
// charset: defaults, ASCII purity, locale independence
// ---------------------------------------------------------------------------

test("glyph tables: ascii and utf8 have the same keys; every ascii byte is below 0x80; utf8 has non-ASCII glyphs", () => {
  assert.deepStrictEqual(Object.keys(GLYPHS.ascii), GLYPH_NAMES);
  for (const name of GLYPH_NAMES) {
    assert.ok(allAscii(Buffer.from(GLYPHS.ascii[name], "utf8")), `ascii glyph ${name} is not ASCII`);
    assert.ok(GLYPHS.ascii[name].length > 0 && GLYPHS.utf8[name].length > 0, `glyph ${name} is empty`);
  }
  assert.ok(GLYPH_NAMES.some((n) => !allAscii(Buffer.from(GLYPHS.utf8[n], "utf8"))));
  assert.strictEqual(glyphsFor("ascii"), GLYPHS.ascii);
  assert.strictEqual(glyphsFor("utf8"), GLYPHS.utf8);
  assert.strictEqual(glyphsFor("nonsense"), GLYPHS.utf8);
  assert.ok(Object.isFrozen(GLYPHS) && Object.isFrozen(GLYPHS.utf8) && Object.isFrozen(GLYPHS.ascii));
});

test("with LANG and LC_ALL empty and stdout a pipe, cli.js uses the UTF-8 glyphs and no colour", () => {
  const r = cli(["info"], { env: { LANG: "", LC_ALL: "" } });
  assert.strictEqual(r.status, 0);
  assert.strictEqual(r.err, "");
  assert.strictEqual(settingsLine(r.out, "charset"), "charset=utf8 source=default");
  assert.ok(r.out.indexOf("\tfull\t━") >= 0, "the UTF-8 full cell is missing");
  assert.ok(!hasEsc(r.out), "colour was emitted on a pipe");
  assert.ok(settingsLine(r.out, "color").indexOf("enabled=false") > 0);
});

test("with --charset ascii every byte of cli.js output is below 0x80 and every ascii glyph is shown", () => {
  const r = cli(["info", "--charset", "ascii"], { env: { LANG: "", LC_ALL: "" } });
  assert.strictEqual(r.status, 0);
  assert.ok(allAscii(r.stdout), "a byte at or above 0x80 was written");
  for (const name of GLYPH_NAMES) assert.ok(r.out.indexOf(`glyph\t${name}\t${GLYPHS.ascii[name]}\n`) >= 0, `glyph ${name} missing`);
});

test("LC_ALL=C and LC_ALL=en_US.UTF-8 (and LANG, LC_CTYPE) produce byte-identical output, for both charsets", () => {
  for (const cs of ["utf8", "ascii"]) {
    const variants = [
      {},
      { LC_ALL: "C" },
      { LC_ALL: "en_US.UTF-8" },
      { LANG: "sv_SE.ISO-8859-1" },
      { LC_CTYPE: "POSIX", LANG: "C" },
      { LC_ALL: "C", LANG: "en_US.UTF-8", LC_CTYPE: "en_US.UTF-8" },
    ];
    const outs = variants.map((env) => cli(["info", "--charset", cs, "--color", "never"], { env }));
    outs.forEach((o) => assert.strictEqual(o.status, 0));
    outs.forEach((o) => assert.ok(o.stdout.equals(outs[0].stdout), `${cs}: output differs under some locale`));
  }
});

test("LANG, LC_ALL and LC_CTYPE are never consulted: an env that throws on them resolves every setting", () => {
  const trap = new Proxy({ JENGA_PROGRESS_CHARSET: "ascii", COLUMNS: "70" }, {
    get(target, prop) {
      if (prop === "LANG" || prop === "LC_ALL" || prop === "LC_CTYPE") throw new Error(`read ${String(prop)}`);
      return target[prop];
    },
  });
  assert.strictEqual(resolveCharset({ env: trap }).value, "ascii");
  assert.strictEqual(resolveColor({ env: trap, isTTY: true }).value, "auto");
  assert.strictEqual(resolveWidth({ env: trap }).value, 70);
  const none = new Proxy({}, { get(t, p) { if (p === "LANG" || p === "LC_ALL" || p === "LC_CTYPE") throw new Error(`read ${String(p)}`); return undefined; } });
  assert.strictEqual(resolveCharset({ env: none }).value, "utf8");
});

// ---------------------------------------------------------------------------
// charset and colour: precedence flag > env > config > default
// ---------------------------------------------------------------------------

const SETTINGS = [
  {
    name: "charset", flag: "--charset", envName: "JENGA_PROGRESS_CHARSET", key: "progress_charset", line: "charset",
    def: "utf8", other: ["ascii", "utf8"], bad: "latin1",
  },
  {
    name: "color", flag: "--color", envName: "JENGA_PROGRESS_COLOR", key: "progress_color", line: "color",
    def: "auto", other: ["never", "always"], bad: "sometimes",
  },
];

for (const s of SETTINGS) {
  const [low, high] = s.other; // low: the config value, high: the environment value; a third value is the flag
  const flagValue = s.name === "charset" ? "ascii" : "auto";
  const valueOf = (r) => settingsLine(r.out, s.line).split(" ")[0].split("=")[1];
  const sourceOf = (r) => settingsLine(r.out, s.line).split("source=")[1];

  test(`${s.name}: default, then config, then env, then flag (spawned cli, fixture dashboard-config.json)`, () => {
    // default: no config file at all, then a file without the key
    assert.strictEqual(valueOf(cli(["info"], { root: fixtureProject() })), s.def);
    assert.strictEqual(sourceOf(cli(["info"], { root: fixtureProject() })), "default");
    assert.strictEqual(valueOf(cli(["info"], { root: fixtureProject({ dashboard_port: 58150 }) })), s.def);
    // config key
    const root = fixtureProject({ dashboard_port: 58150, [s.key]: low });
    const c = cli(["info"], { root });
    assert.strictEqual(valueOf(c), low);
    assert.strictEqual(sourceOf(c), "config");
    // env overrides config
    const e = cli(["info"], { root, env: { [s.envName]: high } });
    assert.strictEqual(valueOf(e), high);
    assert.strictEqual(sourceOf(e), "env");
    // flag overrides env and config
    const f = cli(["info", s.flag, flagValue], { root, env: { [s.envName]: high } });
    assert.strictEqual(valueOf(f), flagValue);
    assert.strictEqual(sourceOf(f), "flag");
    for (const r of [c, e, f]) assert.strictEqual(r.err, "", "a valid layer must not warn");
  });

  test(`${s.name}: an empty environment variable is treated as unset`, () => {
    const root = fixtureProject({ [s.key]: low });
    const r = cli(["info"], { root, env: { [s.envName]: "" } });
    assert.strictEqual(valueOf(r), low);
    assert.strictEqual(sourceOf(r), "config");
    assert.strictEqual(r.err, "");
  });

  test(`${s.name}: an invalid config value gives the default and exactly one stderr warning`, () => {
    const r = cli(["info"], { root: fixtureProject({ [s.key]: s.bad }) });
    assert.strictEqual(r.status, 0);
    assert.strictEqual(valueOf(r), s.def);
    assert.strictEqual(sourceOf(r), "default");
    const lines = r.err.split("\n").filter((l) => l !== "");
    assert.strictEqual(lines.length, 1, r.err);
    assert.ok(lines[0].indexOf("cli.js: warning: ") === 0 && lines[0].indexOf(s.key) > 0, lines[0]);
  });

  test(`${s.name}: an invalid config value that a higher layer overrides is not examined, so it does not warn`, () => {
    const root = fixtureProject({ [s.key]: s.bad });
    const r = cli(["info"], { root, env: { [s.envName]: high } });
    assert.strictEqual(valueOf(r), high);
    assert.strictEqual(r.err, "");
  });

  test(`${s.name}: an invalid environment value is ignored with one warning and the config key still applies`, () => {
    const root = fixtureProject({ [s.key]: low });
    const r = cli(["info"], { root, env: { [s.envName]: s.bad } });
    assert.strictEqual(valueOf(r), low);
    assert.strictEqual(r.err.split("\n").filter((l) => l !== "").length, 1, r.err);
    assert.ok(r.err.indexOf(s.envName) >= 0);
  });

  test(`${s.name}: a config value of the wrong type (number, null) is invalid, not coerced`, () => {
    for (const bad of [1, null, true, ["utf8"]]) {
      const r = cli(["info"], { root: fixtureProject({ [s.key]: bad }) });
      assert.strictEqual(valueOf(r), s.def);
      assert.strictEqual(r.err.split("\n").filter((l) => l !== "").length, 1, `${JSON.stringify(bad)}: ${r.err}`);
    }
  });
}

test("an unreadable dashboard-config.json (invalid JSON) gives the defaults with one warning", () => {
  const r = cli(["info"], { root: fixtureProject("{ not json") });
  assert.strictEqual(r.status, 0);
  assert.strictEqual(settingsLine(r.out, "charset"), "charset=utf8 source=default");
  assert.strictEqual(r.err.split("\n").filter((l) => l !== "").length, 1, r.err);
});

test("a project root that cannot be resolved gives the defaults silently", () => {
  const r = cli(["info"], { root: join(tmp(), "no-registry-here") });
  assert.strictEqual(r.status, 0);
  assert.strictEqual(settingsLine(r.out, "charset"), "charset=utf8 source=default");
  assert.strictEqual(r.err, "");
});

test("readProgressConfig reads only the two progress keys and resolveChoice walks the layers in order", () => {
  const root = fixtureProject({ dashboard_port: 1, progress_charset: "ascii", progress_color: "never", other: 2 });
  const r = readProgressConfig({ env: { PATH: process.env.PATH, JENGA_PROJECT_ROOT: root }, cwd: tmp() });
  assert.deepStrictEqual(r.values, { progress_charset: "ascii", progress_color: "never" });
  assert.deepStrictEqual(r.warnings, []);
  const choice = (o) => resolveChoice(Object.assign({ envName: "E", configKey: "k", allowed: ["a", "b", "c"], fallback: "a" }, o));
  assert.deepStrictEqual(choice({}), { value: "a", source: "default", warnings: [] });
  assert.strictEqual(choice({ configValue: "b" }).source, "config");
  assert.strictEqual(choice({ configValue: "b", envValue: "c" }).value, "c");
  assert.strictEqual(choice({ configValue: "b", envValue: "c", flag: "a" }).source, "flag");
  assert.strictEqual(choice({ flag: "zzz", envValue: "c" }).value, "c");
  assert.strictEqual(choice({ flag: "zzz", envValue: "c" }).warnings.length, 1);
});

test("the config layer wins over the default by being read from the file the project really has (config set round trip)", () => {
  const root = fixtureProject({ dashboard_port: 58150 });
  const set = spawnSync(process.execPath, [join(REPO, "bin", "jenga.js"), "config", "set", "dashboard-config.progress_charset", "ascii"], {
    env: { PATH: process.env.PATH, JENGA_PROJECT_ROOT: root }, encoding: "utf8",
  });
  assert.strictEqual(set.status, 0, set.stderr);
  const r = cli(["info"], { root });
  assert.strictEqual(settingsLine(r.out, "charset"), "charset=ascii source=config");
  assert.ok(allAscii(r.stdout));
});

// ---------------------------------------------------------------------------
// colour semantics
// ---------------------------------------------------------------------------

test("--color always emits ANSI even when NO_COLOR is set and stdout is not a TTY", () => {
  const r = cli(["info", "--color", "always"], { env: { NO_COLOR: "1" } });
  assert.strictEqual(r.status, 0);
  assert.ok(hasEsc(r.out));
  assert.ok(settingsLine(r.out, "color").indexOf("enabled=true") > 0);
});

test("--color never emits no ANSI even on a TTY; auto follows the TTY and NO_COLOR (empty NO_COLOR counts as unset)", () => {
  const tty = (args, env) => inProcess(args, { isTTY: true, columns: 100, env: Object.assign({ PATH: process.env.PATH }, env || {}) });
  assert.ok(!hasEsc(tty(["info", "--color", "never"]).out));
  assert.ok(hasEsc(tty(["info", "--color", "auto"]).out));
  assert.ok(hasEsc(tty(["info"]).out), "auto is the default");
  assert.ok(!hasEsc(tty(["info", "--color", "auto"], { NO_COLOR: "1" }).out));
  assert.ok(hasEsc(tty(["info", "--color", "auto"], { NO_COLOR: "" }).out));
  assert.ok(hasEsc(tty(["info", "--color", "always"], { NO_COLOR: "1" }).out));
  assert.ok(!hasEsc(inProcess(["info", "--color", "auto"], { isTTY: false }).out));
  assert.ok(!hasEsc(inProcess(["info", "--color", "never"], { isTTY: false }).out));
  // and the same through the environment variable and the width of a TTY
  assert.ok(!hasEsc(tty(["info"], { JENGA_PROGRESS_COLOR: "never" }).out));
  assert.strictEqual(settingsLine(tty(["info"]).out, "cols"), "cols=100 source=tty");
});

test("resolveColor: the mode table is exactly auto, always, never; enabled follows the documented rule", () => {
  assert.deepStrictEqual(COLOR_MODES, ["auto", "always", "never"]);
  assert.deepStrictEqual(CHARSETS, ["utf8", "ascii"]);
  const on = (o) => resolveColor(o).enabled;
  assert.strictEqual(on({ env: {}, isTTY: true }), true);
  assert.strictEqual(on({ env: {}, isTTY: false }), false);
  assert.strictEqual(on({ env: {} }), false);
  assert.strictEqual(on({ env: { NO_COLOR: "x" }, isTTY: true }), false);
  assert.strictEqual(on({ env: { NO_COLOR: "x" }, isTTY: false, flag: "always" }), true);
  assert.strictEqual(on({ env: {}, isTTY: true, flag: "never" }), false);
});

test("painter: the E92 decision 2 palette, runs closed with ESC[0m, off means identity, ANSI strips cleanly", () => {
  assert.deepStrictEqual(
    { done: SGR.done, in_progress: SGR.in_progress, failed: SGR.failed, pending: SGR.pending },
    { done: "32", in_progress: "33", failed: "31", pending: "90" }
  );
  assert.ok(/^(38;5;\d+|2;34|34)$/.test(SGR.rejected), "rejected is a muted blue-grey");
  const p = createPainter(true);
  assert.strictEqual(p.paint("done", "x"), `${ESC}[32mx${ESC}[0m`);
  assert.strictEqual(p.bold("x"), `${ESC}[1mx${ESC}[0m`);
  assert.strictEqual(p.dim("x"), `${ESC}[2mx${ESC}[0m`);
  assert.strictEqual(p.paint("done", ""), "");
  assert.strictEqual(p.paint("no-such-colour", "x"), "x");
  const q = createPainter(false);
  assert.strictEqual(q.paint("done", "x"), "x");
  assert.strictEqual(q.bold("x") + q.dim("x"), "xx");
  for (const name of Object.keys(SGR)) assert.strictEqual(stripAnsi(p.paint(name, "abc")), "abc");
  assert.strictEqual(stripAnsi(`${p.bold(p.paint("failed", "a"))}b${p.dim("c")}`), "abc");
});

// ---------------------------------------------------------------------------
// width
// ---------------------------------------------------------------------------

// Ranges of East Asian Wide and Fullwidth characters and of emoji presentation: a glyph in any of them may take two
// cells in a terminal, which would break every layout that counts glyphs.
const WIDE_RANGES = [
  [0x1100, 0x115f], [0x2e80, 0xa4cf], [0xac00, 0xd7a3], [0xf900, 0xfaff], [0xfe30, 0xfe6f], [0xff00, 0xff60],
  [0xffe0, 0xffe6], [0x1f300, 0x1faff], [0x20000, 0x3fffd],
];
const ZERO_WIDTH = [[0x0300, 0x036f], [0x200b, 0x200f], [0x2060, 0x2064], [0xfe00, 0xfe0f], [0x20d0, 0x20ff]];
const inRanges = (cp, ranges) => ranges.some(([lo, hi]) => cp >= lo && cp <= hi);

test("width pin: every glyph of both tables is exactly one cell, with and without ANSI around it", () => {
  const painter = createPainter(true);
  for (const charset of CHARSETS) {
    for (const name of GLYPH_NAMES) {
      const g = GLYPHS[charset][name];
      const cps = Array.from(g);
      assert.strictEqual(cps.length, 1, `${charset}.${name} is not a single code point`);
      assert.strictEqual(g.length, 1, `${charset}.${name} is outside the BMP or multi-unit`);
      assert.strictEqual(displayWidth(g), 1, `${charset}.${name} is not one cell`);
      const cp = g.codePointAt(0);
      assert.ok(!inRanges(cp, WIDE_RANGES), `${charset}.${name} (U+${cp.toString(16)}) is in a double-width range`);
      assert.ok(!inRanges(cp, ZERO_WIDTH), `${charset}.${name} (U+${cp.toString(16)}) is zero-width or combining`);
      assert.strictEqual(displayWidth(painter.paint("done", g)), 1, `${charset}.${name} with colour`);
      assert.strictEqual(displayWidth(painter.bold(painter.paint("failed", g))), 1);
    }
  }
});

test("displayWidth counts glyphs not bytes, ignores ANSI, and the helpers use it", () => {
  assert.strictEqual(displayWidth(""), 0);
  assert.strictEqual(displayWidth("abc"), 3);
  assert.strictEqual(displayWidth(`${ESC}[31mabc${ESC}[0m`), 3);
  assert.strictEqual(displayWidth("━━╌╌"), 4);
  assert.strictEqual(displayWidth(`${ESC}[1m${ESC}[38;5;67m◉ ○${ESC}[0m`), 3);
  assert.strictEqual(padEnd("◉", 4), "◉   ");
  assert.strictEqual(padEnd("abcdef", 3), "abcdef");
  assert.strictEqual(truncate("abcdef", 4, "…"), "abc…");
  assert.strictEqual(truncate("abc", 4, "…"), "abc");
  assert.strictEqual(truncate("abcdef", 4, "~"), "abc~");
  assert.strictEqual(truncate("abcdef", 4), "abcd");
  assert.strictEqual(displayWidth(truncate("━━━━━━━━", 5, GLYPHS.utf8.ellipsis)), 5);
});

test("resolveWidth: --cols, then COLUMNS, then the TTY width, then 80; invalid values are skipped", () => {
  assert.deepStrictEqual(resolveWidth({}), { value: 80, source: "default" });
  assert.deepStrictEqual(resolveWidth({ ttyColumns: 132 }), { value: 132, source: "tty" });
  assert.deepStrictEqual(resolveWidth({ env: { COLUMNS: "100" }, ttyColumns: 132 }), { value: 100, source: "env" });
  assert.deepStrictEqual(resolveWidth({ flag: "60", env: { COLUMNS: "100" }, ttyColumns: 132 }), { value: 60, source: "flag" });
  assert.deepStrictEqual(resolveWidth({ flag: 60 }), { value: 60, source: "flag" });
  for (const bad of ["", "0", "-5", "abc", "1.5", "10001", "1e3", " 80"]) {
    assert.strictEqual(parseCols(bad), null, `parseCols(${JSON.stringify(bad)})`);
    assert.strictEqual(resolveWidth({ env: { COLUMNS: bad } }).value, 80, `COLUMNS=${JSON.stringify(bad)}`);
  }
  assert.strictEqual(parseCols("10000"), 10000);
  assert.strictEqual(parseCols("1"), 1);
});

test("cli.js width: --cols beats COLUMNS; COLUMNS is read on a pipe; the TTY width only counts for a TTY", () => {
  assert.strictEqual(settingsLine(cli(["info"]).out, "cols"), "cols=80 source=default");
  assert.strictEqual(settingsLine(cli(["info"], { env: { COLUMNS: "120" } }).out, "cols"), "cols=120 source=env");
  assert.strictEqual(settingsLine(cli(["info", "--cols", "70"], { env: { COLUMNS: "120" } }).out, "cols"), "cols=70 source=flag");
  assert.strictEqual(settingsLine(inProcess(["info"], { isTTY: false, columns: 150 }).out, "cols"), "cols=80 source=default");
  assert.strictEqual(settingsLine(inProcess(["info"], { isTTY: true, columns: 150 }).out, "cols"), "cols=150 source=tty");
});

// ---------------------------------------------------------------------------
// labels
// ---------------------------------------------------------------------------

function labelsDirect(lang) {
  const env = Object.assign({}, process.env);
  delete env.JENGA_PROGRESS_LANG;
  if (lang) env.JENGA_PROGRESS_LANG = lang;
  const r = spawnSync("bash", [join(SCRIPTS, "progress-labels-json.sh")], { env, encoding: "utf8" });
  assert.strictEqual(r.status, 0, r.stderr);
  return JSON.parse(r.stdout);
}

test("labels: English by default, Swedish with JENGA_PROGRESS_LANG=sv or lang sv, both equal to the bash script's own table", () => {
  const baseEnv = Object.assign({}, process.env);
  delete baseEnv.JENGA_PROGRESS_LANG;
  const en = loadLabels({ env: baseEnv });
  assert.strictEqual(en.ok, true);
  assert.strictEqual(en.lang, "en");
  assert.deepStrictEqual({ lang: en.lang, labels: en.labels }, labelsDirect(""));
  assert.strictEqual(en.labels.ready_to_take, "Ready to take");
  const sv = loadLabels({ env: Object.assign({}, baseEnv, { JENGA_PROGRESS_LANG: "sv" }) });
  assert.strictEqual(sv.lang, "sv");
  assert.deepStrictEqual({ lang: sv.lang, labels: sv.labels }, labelsDirect("sv"));
  assert.strictEqual(sv.labels.ready_to_take, "Redo att ta");
  const viaOption = loadLabels({ env: baseEnv, lang: "sv" });
  assert.deepStrictEqual(viaOption.labels, sv.labels);
  assert.notDeepStrictEqual(en.labels, sv.labels);
  assert.strictEqual(loadLabels({ env: Object.assign({}, baseEnv, { JENGA_PROGRESS_LANG: "xx" }) }).lang, "en");
});

test("labels through the cli: --lang sv beats JENGA_PROGRESS_LANG, and LANG does not choose the language", () => {
  const en = cli(["labels"], { env: { LANG: "sv_SE.UTF-8", LC_ALL: "sv_SE.UTF-8" } });
  assert.ok(en.out.indexOf("lang=en\n") === 0);
  const sv = cli(["labels"], { env: { JENGA_PROGRESS_LANG: "sv" } });
  assert.ok(sv.out.indexOf("lang=sv\n") === 0);
  const flag = cli(["labels", "--lang", "en"], { env: { JENGA_PROGRESS_LANG: "sv" } });
  assert.ok(flag.out.indexOf("lang=en\n") === 0);
  const flagSv = cli(["--lang=sv", "labels"]);
  assert.ok(flagSv.out.indexOf("lang=sv\n") === 0 && flagSv.out.indexOf("Redo att ta") > 0);
});

test("labels: a missing labels script is a returned warning, not a throw", () => {
  const r = loadLabels({ env: Object.assign({}, process.env, { JENGA_PROGRESS_SCRIPTS_DIR: tmp() }) });
  assert.strictEqual(r.ok, false);
  assert.ok(r.warning.indexOf("progress-labels-json.sh") >= 0);
});

test("formatLabel fills %d and %s in order and keeps %% literal", () => {
  assert.strictEqual(formatLabel("⊘ %d rejected (not counted)", 2), "⊘ 2 rejected (not counted)");
  assert.strictEqual(formatLabel("%s unlocked by %s", "A", "B"), "A unlocked by B");
  assert.strictEqual(formatLabel("%d of %d stories complete, %d%% of tasks done", 1, 4, 25), "1 of 4 stories complete, 25% of tasks done");
  assert.strictEqual(formatLabel("%s and %d"), " and 0");
});

// ---------------------------------------------------------------------------
// data
// ---------------------------------------------------------------------------

function directBoardProgress(root, args) {
  const r = spawnSync("bash", [join(SCRIPTS, "board-progress.sh")].concat(args), { env: { PATH: process.env.PATH, JENGA_PROJECT_ROOT: root }, encoding: "utf8" });
  assert.strictEqual(r.status, 0, r.stderr);
  return JSON.parse(r.stdout);
}

test("data.js returns exactly the parsed board-progress.sh JSON for the same arguments (story, epic, ids, graph, within)", () => {
  const root = fixtureProject();
  const env = { PATH: process.env.PATH, JENGA_PROJECT_ROOT: root };
  const argSets = [
    ["--story", "E01_S01"],
    ["--epic", "E01", "--items"],
    ["--ids", "E01_S01_T01,E01_S01_T02"],
    ["--graph"],
    ["--graph", "--within", "E01"],
    ["--graph", "--counts-only"],
  ];
  for (const args of argSets) {
    const r = readBoardProgress(args, { env, cwd: tmp() });
    assert.strictEqual(r.ok, true, JSON.stringify(r));
    assert.deepStrictEqual(r.data, directBoardProgress(root, args), args.join(" "));
  }
  const g = readBoardProgress(["--story", "E01_S01"], { env, cwd: tmp() });
  assert.deepStrictEqual(g.data.levels.tasks.totals, { done: 1, in_progress: 1, failed: 0, pending: 1, rejected: 0, unknown: 0, denominator: 3 });
});

test("data.js: a non-zero exit of the script is a returned warning naming the exit status and the script's message", () => {
  const env = { PATH: process.env.PATH, JENGA_PROJECT_ROOT: fixtureProject() };
  const r = readBoardProgress(["--story", "E99_S99"], { env, cwd: tmp() });
  assert.strictEqual(r.ok, false);
  assert.ok(/board-progress\.sh exited 2: /.test(r.warning), r.warning);
  assert.ok(r.warning.indexOf("E99_S99") > 0, r.warning);
  assert.ok(r.warning.indexOf("\n") < 0, "a warning is one line");
  const usage = readBoardProgress([], { env, cwd: tmp() });
  assert.strictEqual(usage.ok, false);
  const empty = readBoardProgress(["--backlog"], { env: Object.assign({ JENGA_TODO_FILE: join(tmp(), "none.md") }, env), cwd: tmp() });
  assert.strictEqual(empty.ok, false);
  assert.ok(/exited 3/.test(empty.warning), empty.warning);
});

test("data.js: a missing script, a script that fails, and a script that prints non-JSON are all warnings, never throws", () => {
  const base = { PATH: process.env.PATH };
  const missing = readBoardProgress(["--all"], { env: Object.assign({}, base, { JENGA_PROGRESS_SCRIPTS_DIR: tmp() }), cwd: tmp() });
  assert.strictEqual(missing.ok, false);
  assert.ok(missing.warning.indexOf("board-progress.sh was not found") === 0, missing.warning);

  const fake = tmp();
  writeFileSync(join(fake, "board-progress.sh"), "#!/usr/bin/env bash\necho 'boom on purpose' >&2\nexit 7\n");
  const failing = readBoardProgress(["--all"], { env: Object.assign({}, base, { JENGA_PROGRESS_SCRIPTS_DIR: fake }), cwd: tmp() });
  assert.strictEqual(failing.ok, false);
  assert.ok(failing.warning.indexOf("exited 7: boom on purpose") > 0, failing.warning);

  writeFileSync(join(fake, "board-progress.sh"), "#!/usr/bin/env bash\necho 'not json'\n");
  const garbled = readBoardProgress(["--all"], { env: Object.assign({}, base, { JENGA_PROGRESS_SCRIPTS_DIR: fake }), cwd: tmp() });
  assert.strictEqual(garbled.ok, false);
  assert.ok(garbled.warning.indexOf("not JSON") > 0, garbled.warning);

  assert.strictEqual(runScript("board-progress.sh", [], { scriptsDir: join(tmp(), "gone") }).ok, false);
});

test("data.js finds the scripts directory: package-relative scripts/ by default; JENGA_PROGRESS_SCRIPTS_DIR is then the only candidate", () => {
  const cwd = tmp();
  const env = { PATH: process.env.PATH };
  assert.strictEqual(findScriptsDir({ env, cwd }), SCRIPTS);
  assert.strictEqual(findScriptsDir({ env, cwd, needs: "resolve-root.sh" }), SCRIPTS);
  assert.strictEqual(findScriptsDir({ env, cwd, needs: "no-such-script.sh" }), null);
  // an installed copy (node_modules/@jenga-ai/agent/scripts) works through the override, script plus its lib
  const installed = join(cwd, "node_modules", "@jenga-ai", "agent", "scripts");
  mkdirSync(join(installed, "lib"), { recursive: true });
  copyFileSync(join(SCRIPTS, "progress-labels-json.sh"), join(installed, "progress-labels-json.sh"));
  copyFileSync(join(SCRIPTS, "lib", "progress-labels.sh"), join(installed, "lib", "progress-labels.sh"));
  const via = Object.assign({ JENGA_PROGRESS_SCRIPTS_DIR: "node_modules/@jenga-ai/agent/scripts" }, env);
  assert.strictEqual(findScriptsDir({ env: via, cwd, needs: "progress-labels-json.sh" }), installed, "a relative override is resolved against the working directory");
  const r = runScript("progress-labels-json.sh", [], { env: via, cwd });
  assert.strictEqual(r.ok, true);
  assert.strictEqual(JSON.parse(r.stdout).lang, "en");
  // the override is exclusive: a script it lacks is not found in the package scripts/
  assert.strictEqual(findScriptsDir({ env: via, cwd, needs: "board-progress.sh" }), null);
  assert.strictEqual(runScript("progress-labels-json.sh", [], { env: Object.assign({ JENGA_PROGRESS_SCRIPTS_DIR: tmp() }, env), cwd }).ok, false);
});

// ---------------------------------------------------------------------------
// cli: never-fail rule and usage errors
// ---------------------------------------------------------------------------

test("cli.js data: the board JSON on stdout for a real id, through --root, run from a directory that is no project", () => {
  const root = fixtureProject();
  const r = cli(["data", "--story", "E01_S01"], { root: undefined, cwd: tmp(), env: {} });
  assert.strictEqual(r.status, 0, "no root at all must still exit 0");
  const withRoot = cli(["--root", root, "data", "--story", "E01_S01"], { cwd: tmp() });
  assert.strictEqual(withRoot.status, 0);
  assert.strictEqual(withRoot.err, "");
  assert.deepStrictEqual(JSON.parse(withRoot.out), directBoardProgress(root, ["--story", "E01_S01"]));
  const rel = cli(["--root=./proj", "info"], { cwd: dirname(root) });
  assert.strictEqual(rel.status, 0, "a relative --root is resolved against the working directory without failing");
});

test("cli.js: --root names the project whose dashboard-config.json is read, as JENGA_PROJECT_ROOT would", () => {
  const root = fixtureProject({ progress_charset: "ascii" });
  const r = cli(["info", "--root", root], { cwd: tmp() });
  assert.strictEqual(settingsLine(r.out, "charset"), "charset=ascii source=config");
});

test("never-fail: an unknown id exits 0 with one stderr warning line and empty stdout", () => {
  const root = fixtureProject();
  for (const args of [["data", "--story", "E99_S99"], ["data", "--epic", "E77"], ["data", "--ids", "E01_S01_T99"], ["data", "--story", "bad id"]]) {
    const r = cli(args, { root });
    assert.strictEqual(r.status, 0, args.join(" "));
    assert.strictEqual(r.out, "", args.join(" "));
    const lines = r.err.split("\n").filter((l) => l !== "");
    assert.strictEqual(lines.length, 1, r.err);
    assert.ok(lines[0].indexOf("cli.js: warning: board-progress.sh exited 2") === 0, lines[0]);
  }
});

test("never-fail: a missing script exits 0 with one stderr warning line and empty stdout (data and labels)", () => {
  const root = fixtureProject();
  for (const cmd of [["data", "--all"], ["labels"]]) {
    const r = cli(cmd, { root, env: { JENGA_PROGRESS_SCRIPTS_DIR: tmp() } });
    assert.strictEqual(r.status, 0);
    assert.strictEqual(r.out, "");
    const lines = r.err.split("\n").filter((l) => l !== "");
    assert.strictEqual(lines.length, 1, r.err);
    assert.ok(lines[0].indexOf("cli.js: warning: ") === 0 && lines[0].indexOf("was not found") > 0, lines[0]);
  }
});

test("never-fail: a handler that throws, or that returns nothing, still exits 0 (one warning at most, nothing on stdout)", () => {
  COMMANDS.__boom = { summary: "test only", run: () => { throw new Error("kaboom\nsecond line"); } };
  COMMANDS.__quiet = { summary: "test only", run: () => undefined };
  try {
    const boom = inProcess(["__boom"]);
    assert.strictEqual(boom.code, 0);
    assert.strictEqual(boom.out, "");
    assert.deepStrictEqual(boom.errLines, ["cli.js: warning: kaboom second line"]);
    const quiet = inProcess(["__quiet"]);
    assert.strictEqual(quiet.code, 0);
    assert.strictEqual(quiet.out + quiet.err, "");
  } finally {
    delete COMMANDS.__boom;
    delete COMMANDS.__quiet;
  }
});

test("usage errors exit 2 with nothing on stdout: unknown flag, missing flag value, invalid flag value, unknown or missing command", () => {
  const cases = [
    ["info", "--bogus"],
    ["--bogus", "info"],
    ["info", "-x"],
    ["info", "--charset"],
    ["info", "--color"],
    ["info", "--cols"],
    ["info", "--root"],
    ["info", "--lang"],
    ["--charset", "--color", "never", "info"],
    ["info", "--charset", "latin1"],
    ["info", "--charset=UTF8"],
    ["info", "--color", "sometimes"],
    ["info", "--cols", "abc"],
    ["info", "--cols", "0"],
    ["info", "--cols=10001"],
    ["info", "--lang", "1x"],
    ["nosuchcommand"],
    [],
    ["info", "extra-positional-is-fine-but-this-flag-is-not", "--nope"],
  ];
  for (const args of cases) {
    const r = cli(args);
    assert.strictEqual(r.status, 2, `cli.js ${args.join(" ")} -> ${r.status}`);
    assert.strictEqual(r.out, "", `cli.js ${args.join(" ")} wrote to stdout`);
    assert.ok(r.err.indexOf("cli.js: ") === 0, r.err);
    assert.ok(r.err.indexOf("usage: cli.js") > 0, "usage follows the message");
  }
  assert.strictEqual(cli(["info", "--charset=ascii", "--cols=70", "--color=never", "--lang=sv", "--root=" + tmp()]).status, 0);
});

test("--help prints the usage on stdout and exits 0, wherever it appears; the sub-command table is listed", () => {
  for (const args of [["--help"], ["-h"], ["info", "--help"], ["--bogus", "--help"], ["--charset", "--help"]]) {
    const r = cli(args);
    assert.strictEqual(r.status, 0, args.join(" "));
    assert.strictEqual(r.err, "");
    assert.ok(r.out.indexOf("usage: cli.js") === 0);
    for (const flag of ["--charset", "--color", "--cols", "--root", "--lang"]) assert.ok(r.out.indexOf(flag) > 0, `${flag} missing from the usage`);
    for (const name of Object.keys(COMMANDS)) assert.ok(r.out.indexOf(`  ${name}`) > 0, `${name} missing from the usage`);
  }
});

test("the sub-command table is a table of { summary, run } entries, ready for E92_S08_T04 and E92_S08_T05", () => {
  const names = Object.keys(COMMANDS);
  for (const core of ["info", "data", "labels"]) assert.ok(names.indexOf(core) >= 0, `${core} missing`);
  for (const name of names) {
    assert.strictEqual(typeof COMMANDS[name].summary, "string", name);
    assert.strictEqual(typeof COMMANDS[name].run, "function", name);
  }
});

test("command flags and passthrough: a command's own flags are accepted after the command, unknown ones exit 2", () => {
  COMMANDS.__flagged = {
    summary: "test only",
    flags: { "--layout": { value: true, check: (v) => ["horizontal", "vertical", "auto"].indexOf(v) >= 0, expect: "horizontal, vertical or auto" }, "--all": {} },
    run: (ctx) => `layout=${ctx.flags.layout} all=${ctx.flags.all === true} positionals=${ctx.positionals.join(",")}`,
  };
  try {
    const ok = inProcess(["__flagged", "--layout", "vertical", "--all", "E01", "--charset", "ascii"]);
    assert.strictEqual(ok.code, 0);
    assert.strictEqual(ok.out, "layout=vertical all=true positionals=E01\n");
    assert.strictEqual(inProcess(["__flagged", "--layout", "diagonal"]).code, 2);
    assert.strictEqual(inProcess(["__flagged", "--layout"]).code, 2);
    assert.strictEqual(inProcess(["__flagged", "--nope"]).code, 2);
    assert.strictEqual(inProcess(["info", "--layout", "vertical"]).code, 2, "another command's flag is unknown here");
  } finally {
    delete COMMANDS.__flagged;
  }
});

// ---------------------------------------------------------------------------
// scans of lib/progress/
// ---------------------------------------------------------------------------

const progressFiles = () => readdirSync(PROGRESS_DIR).filter((n) => n.endsWith(".js")).sort();

/** Source with the comment-only lines removed: a comment may name a banned API to say it is banned. */
function codeLines(file) {
  const out = [];
  let inBlock = false;
  for (const line of readFileSync(join(PROGRESS_DIR, file), "utf8").split("\n")) {
    const t = line.trim();
    if (inBlock) {
      if (t.indexOf("*/") >= 0) inBlock = false;
      continue;
    }
    if (t.indexOf("/*") === 0) {
      if (t.indexOf("*/") < 0) inBlock = true;
      continue;
    }
    if (t.indexOf("//") === 0) continue;
    out.push(line);
  }
  return out;
}

test("the module set the task names exists under lib/progress/", () => {
  for (const f of ["charset", "color", "width", "labels", "data", "config", "cli"]) assert.ok(progressFiles().indexOf(`${f}.js`) >= 0, `${f}.js missing`);
});

test("Node-14 safe: no replaceAll, .at(, ??=, ||=, &&=, Object.hasOwn, structuredClone, node:test or global fetch under lib/progress/", () => {
  const banned = [
    ["replaceAll", /\breplaceAll\b/],
    [".at(", /\.at\s*\(/],
    ["??=", /\?\?=/],
    ["||=", /\|\|=/],
    ["&&=", /&&=/],
    ["Object.hasOwn", /\bObject\s*\.\s*hasOwn\b/],
    ["structuredClone", /\bstructuredClone\b/],
    ["node:test", /node:test/],
    ["global fetch", /(^|[^.\w])fetch\s*\(|globalThis\s*\.\s*fetch/],
  ];
  assert.ok(progressFiles().length >= 7);
  for (const f of progressFiles()) {
    for (const line of codeLines(f)) {
      for (const [label, re] of banned) assert.ok(!re.test(line), `${f} uses ${label}: ${line.trim()}`);
    }
  }
  // the scan itself bites: a planted line is caught by the same patterns
  assert.ok(/\breplaceAll\b/.test("s.replaceAll('a','b')") && /\.at\s*\(/.test("xs.at(-1)") && /\?\?=/.test("a ??= 1"));
});

test("LANG, LC_ALL and LC_CTYPE are not read anywhere under lib/progress/ (code lines)", () => {
  for (const f of progressFiles()) {
    for (const line of codeLines(f)) assert.ok(!/\bLC_(ALL|CTYPE)\b|\bLANG\b|\bLC_MESSAGES\b/.test(line), `${f} reads a locale variable: ${line.trim()}`);
  }
});

test("no user-visible word outside the glyph tables: no label value of either language appears as a string literal under lib/progress/", () => {
  const values = new Set();
  for (const lang of ["", "sv"]) Object.values(labelsDirect(lang).labels).forEach((v) => values.add(v));
  assert.ok(values.size >= 20, "the label table is unexpectedly small");
  const literals = [];
  // dependency-structure.js is the pure data module shared with the dashboard (E92_S08_T02): it writes the
  // board-progress payload's bucket and state names ("failed", "unknown", ...) as identifiers and renders no text,
  // so those words are keys there, not user-visible labels. Every file that draws anything stays scanned.
  const DATA_ONLY = new Set(["dependency-structure.js"]);
  // E92_S08_T08: a drawing module also writes identifiers that happen to equal a label word: the style names of the
  // painter (color.js SGR keys such as "pending", plus "bold" and "dim") and the board-progress bucket keys
  // ("done", "in_progress", "failed", "pending", "rejected", "unknown", "denominator"). overview.js passes "pending" as
  // a segment style and lists the bucket keys, which made this scan fail on main once it landed (E92_S08_T05) although
  // nothing user-visible was hard-coded. A literal that is EXACTLY one of those identifiers is skipped here; whether such
  // a word is ever PRINTED is checked on the rendered output instead, which this source scan cannot do:
  // tests/lib-progress-parity.test.mjs draws every command with sentinel labels and fails on any real label word.
  const IDENTIFIERS = new Set(Object.keys(SGR).concat(["bold", "dim", "done", "in_progress", "failed", "pending", "rejected", "unknown", "denominator"]));
  for (const f of progressFiles()) {
    if (DATA_ONLY.has(f)) continue;
    for (const line of codeLines(f)) {
      const re = /"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|`((?:[^`\\]|\\.)*)`/g;
      let m;
      while ((m = re.exec(line)) !== null) {
        const text = m[1] !== undefined ? m[1] : m[2] !== undefined ? m[2] : m[3];
        if (!IDENTIFIERS.has(text)) literals.push({ f, text });
      }
    }
  }
  for (const v of values) {
    const words = v.replace(/%[ds%]/g, "").trim();
    if (words.length < 4) continue; // "red" and such: too short to tell from an identifier
    // a literal that IS a label, or (for a long label) contains it; short labels like "tasks" are only caught whole
    for (const l of literals) {
      assert.ok(l.text !== words && !(words.length >= 12 && l.text.indexOf(words) >= 0), `${l.f} writes the label text ${JSON.stringify(words)} itself`);
    }
  }
  // the literals found are real, so the scan above looked at something
  assert.ok(literals.length > 50);
});

test("glyphs are written only in charset.js: no other file under lib/progress/ holds a non-ASCII string literal", () => {
  for (const f of progressFiles()) {
    if (f === "charset.js") continue;
    for (const line of codeLines(f)) {
      const re = /"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|`((?:[^`\\]|\\.)*)`/g;
      let m;
      while ((m = re.exec(line)) !== null) {
        const text = m[1] !== undefined ? m[1] : m[2] !== undefined ? m[2] : m[3];
        // glyphs belong in the table: a non-ASCII literal elsewhere is a hard-coded glyph (an ellipsis default, say)
        assert.ok(allAscii(Buffer.from(text, "utf8")), `${f} hard-codes a non-ASCII literal outside the glyph tables: ${text}`);
      }
    }
  }
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
