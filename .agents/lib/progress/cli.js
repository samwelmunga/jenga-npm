/**
 * lib/progress/cli.js - the entry point of the Node progress renderers (E92_S08_T03)
 *
 *   node lib/progress/cli.js [shared flags] <command> [command arguments]
 *
 * Shared flags, accepted anywhere on the command line, as `--flag value` or `--flag=value`:
 *
 *   --charset utf8|ascii        glyph set; flag, then JENGA_PROGRESS_CHARSET, then config progress_charset, then utf8
 *   --color auto|always|never   colour;    flag, then JENGA_PROGRESS_COLOR,   then config progress_color,   then auto
 *   --cols N                    width;     flag, then COLUMNS, then the TTY width, then 80
 *   --root <dir>                the project root; becomes JENGA_PROJECT_ROOT, as board-progress.sh's --root does
 *   --lang <code>               label language; becomes JENGA_PROGRESS_LANG for the label script (default en)
 *   --help, -h                  print this usage on stdout and exit 0
 *
 * Charset and colour are never inferred from LC_ALL, LC_CTYPE or LANG, and never from "is this a terminal" beyond
 * the documented `auto` colour rule (see charset.js and color.js).
 *
 * THE NEVER-FAIL RULE (story E92_S08): a progress problem (unknown id, missing script, a script that fails, an
 * invalid config value, an unexpected exception) prints ONE `cli.js: warning: ...` line on stderr, nothing on
 * stdout, and exits 0, so a progress line can never fail the run it decorates. Only a usage error exits 2 (an
 * unknown flag or command, a flag without its value, an invalid flag value), with the problem and the usage on
 * stderr and nothing on stdout.
 *
 * The words of this file are developer diagnostics (usage, warnings), not rendered output. Everything a renderer
 * shows the user comes from the label table (labels.js) and the glyph tables (charset.js).
 *
 * COMMANDS is the sub-command table. E92_S08_T04 (run bar, after-task and after-story lines) and E92_S08_T05
 * (overview and scope views) add their entries; the three below are core diagnostics that exercise the settings,
 * the data loader and the label loader. An entry is { summary, flags?, passthrough?, run(ctx) }:
 *
 *   flags        { "--name": { value: true, check?(v) } } the command's own flags (unknown ones exit 2)
 *   passthrough  true: every token that is not a shared flag goes to ctx.rest unchanged (used by `data`)
 *   run(ctx)     returns a string (stdout), { out } or { warning }; a throw is turned into a warning
 *
 * ctx = { settings, glyphs, painter, env, cwd, flags, positionals, rest, labels(), readData(args) }.
 * run(ctx) may also return { usage } (a usage error of the command: nothing on stdout, the message and the usage on
 * stderr, exit 2).
 *
 * EPIPE: when this file is the main module, a reader that closes the pipe early (`| head -c1`) is not an error:
 * process.stdout gets an error handler that ignores EPIPE, so the exit code stays 0 (never-fail rule).
 *
 * ESM, Node built-ins only; Node >= 14.13.1.
 */
import { resolve } from "path";
import { isMainModule } from "../config/paths.js";
import { barCommand, isCells, isEachKey, isLevel } from "./bar.js";
import { glyphsFor, isCharset, resolveCharset } from "./charset.js";
import { SGR, createPainter, isColorMode, resolveColor } from "./color.js";
import { readProgressConfig } from "./config.js";
import { findScriptsDir, readBoardProgress } from "./data.js";
import { afterStoryCommand, afterTaskCommand } from "./lines.js";
import { loadLabels } from "./labels.js";
import { overviewCommand } from "./overview.js";
import { scopeCommand } from "./scope.js";
import { isLayout } from "./tree-text.js";
import { parseCols, resolveWidth } from "./width.js";

export const EXIT_OK = 0;
export const EXIT_USAGE = 2;

const oneLine = (text) => String(text).replace(/[\u0000-\u001f\u007f]+/g, " ").trim();

/** The shared flags: parsed key, validation and the text of the usage error. */
const SHARED = {
  "--charset": { key: "charset", check: isCharset, expect: "utf8 or ascii" },
  "--color": { key: "color", check: isColorMode, expect: "auto, always or never" },
  "--cols": { key: "cols", check: (v) => parseCols(v) !== null, expect: "an integer from 1 to 10000" },
  "--root": { key: "root", check: (v) => v !== "", expect: "a directory" },
  "--lang": { key: "lang", check: (v) => /^[A-Za-z][A-Za-z0-9_-]*$/.test(v), expect: "a language code such as en or sv" },
};

// ---------------------------------------------------------------------------
// The sub-command table
// ---------------------------------------------------------------------------

export const COMMANDS = {
  // Core diagnostics (E92_S08_T03).
  info: {
    summary: "print the resolved settings and the active glyph table",
    run(ctx) {
      const s = ctx.settings;
      const lines = [
        `charset=${s.charset.value} source=${s.charset.source}`,
        `color=${s.color.value} enabled=${s.color.enabled} source=${s.color.source}`,
        `cols=${s.width.value} source=${s.width.source}`,
        `lang=${ctx.flags.lang || ctx.env.JENGA_PROGRESS_LANG || ""}`,
      ];
      Object.keys(ctx.glyphs).forEach((name) => lines.push(`glyph\t${name}\t${ctx.painter.paint("done", ctx.glyphs[name])}`));
      Object.keys(SGR).forEach((name) => lines.push(`color\t${name}\t${ctx.painter.paint(name, ctx.glyphs.block)}`));
      return lines.join("\n");
    },
  },
  data: {
    summary: "run scripts/board-progress.sh with the given arguments and print its JSON",
    passthrough: true,
    run(ctx) {
      const r = ctx.readData(ctx.rest);
      return r.ok ? JSON.stringify(r.data) : { warning: r.warning };
    },
  },
  labels: {
    summary: "print the label table for the effective language",
    run(ctx) {
      const r = ctx.labels();
      if (!r.ok) return { warning: r.warning };
      return [`lang=${r.lang}`].concat(Object.keys(r.labels).map((k) => `${k}\t${r.labels[k]}`)).join("\n");
    },
  },
  // E92_S08_T04: run bar, after-task line, after-story line.
  bar: {
    summary: "one run-bar line for a scope (--epic, --story, --ids or bare ids, --all, --backlog), or one per epic or story",
    flags: {
      "--level": { value: true, check: isLevel, expect: "tasks, stories or epics" },
      "--cells": { value: true, check: isCells, expect: "an integer from 1 to 500" },
      "--each": { value: true, check: isEachKey, expect: "epics or stories" },
      "--epic": { value: true },
      "--story": { value: true },
      "--ids": { value: true },
      "--all": {},
      "--backlog": {},
    },
    run: barCommand,
  },
  "after-task": {
    summary: "the line of the story a finished task belongs to: --task <id>[,<id>...] (one line per distinct story)",
    flags: {
      "--task": { value: true },
      "--story": { value: true },
      "--cells": { value: true, check: isCells, expect: "an integer from 1 to 500" },
    },
    run: afterTaskCommand,
  },
  "after-story": {
    summary: "the story-finished line: --story <id>[,<id>...] [--ready N] (the ledger stays in story-finished.sh)",
    flags: {
      "--story": { value: true },
      "--ready": { value: true, check: (v) => /^[0-9]{1,6}$/.test(v), expect: "a non-negative integer" },
    },
    run: afterStoryCommand,
  },
  // E92_S08_T05: overview view, scope view (--layout horizontal|vertical|auto).
  overview: {
    summary: "the board overview: totals, the run bar and the epics still in progress (--all is the caller's legacy list)",
    flags: { "--all": {} },
    run: overviewCommand,
  },
  scope: {
    summary: "the scope view of one epic or story id: milestone line, run bar, story bands, ready and locked nodes",
    flags: { "--layout": { value: true, check: isLayout, expect: "horizontal, vertical or auto" } },
    run: scopeCommand,
  },
};

// ---------------------------------------------------------------------------
// Usage and argument parsing
// ---------------------------------------------------------------------------

export function usage() {
  const names = Object.keys(COMMANDS);
  const width = names.reduce((w, n) => Math.max(w, n.length), 0) + 2;
  return [
    "usage: cli.js [options] <command> [command arguments]",
    "",
    "options (anywhere on the line):",
    "  --charset utf8|ascii       glyph set (default utf8; env JENGA_PROGRESS_CHARSET; config progress_charset)",
    "  --color auto|always|never  colour (default auto; env JENGA_PROGRESS_COLOR; config progress_color)",
    "  --cols N                   width in columns (default COLUMNS, then the terminal, then 80)",
    "  --root <dir>               project root (sets JENGA_PROJECT_ROOT)",
    "  --lang <code>              label language (sets JENGA_PROGRESS_LANG; default en)",
    "  -h, --help                 print this usage",
    "",
    "commands:",
  ]
    .concat(names.map((n) => `  ${n}${" ".repeat(width - n.length)}${COMMANDS[n].summary}`))
    .concat(["", "exit codes: 0 ok (also when progress is unavailable: one warning on stderr), 2 usage error"])
    .join("\n");
}

/**
 * Parse argv. Returns { help, error, command, flags, positionals, rest }. `error` is a message (the first usage
 * problem found) or null; `help` is true when -h or --help was given.
 */
export function parseArgs(argv) {
  const out = { help: false, error: null, command: null, flags: {}, positionals: [], rest: [] };
  const fail = (message) => {
    if (out.error === null) out.error = message;
  };
  const spec = () => (out.command ? COMMANDS[out.command] : null);

  for (let i = 0; i < argv.length; i++) {
    const tok = argv[i];
    if (tok === "--help" || tok === "-h") {
      out.help = true;
      continue;
    }
    if (tok.charAt(0) !== "-" || tok === "-") {
      if (out.command === null) {
        if (!Object.prototype.hasOwnProperty.call(COMMANDS, tok)) fail(`unknown command: ${tok}`);
        out.command = tok;
      } else if (spec() && spec().passthrough) {
        out.rest.push(tok);
      } else {
        out.positionals.push(tok);
      }
      continue;
    }

    const eq = tok.indexOf("=");
    const name = eq > 0 ? tok.slice(0, eq) : tok;
    const inline = eq > 0 ? tok.slice(eq + 1) : undefined;
    const shared = Object.prototype.hasOwnProperty.call(SHARED, name) ? SHARED[name] : null;
    const own = spec() && spec().flags && Object.prototype.hasOwnProperty.call(spec().flags, name) ? spec().flags[name] : null;
    const def = shared || own;
    if (!def) {
      if (spec() && spec().passthrough) out.rest.push(tok);
      else fail(`unknown flag: ${name}`);
      continue;
    }
    if (own && !shared && own.value !== true) {
      out.flags[name.slice(2)] = true;
      continue;
    }
    let value = inline;
    if (value === undefined) {
      const next = argv[i + 1];
      if (next === undefined || next.slice(0, 2) === "--") {
        fail(`${name} needs a value`);
        continue;
      }
      value = next;
      i++;
    }
    if (typeof def.check === "function" && !def.check(value)) {
      fail(`${name} must be ${def.expect || "a valid value"} (got: ${value})`);
      continue;
    }
    out.flags[shared ? shared.key : name.slice(2)] = value;
  }
  return out;
}

// ---------------------------------------------------------------------------
// run
// ---------------------------------------------------------------------------

function defaultIo() {
  return {
    env: process.env,
    cwd: process.cwd(),
    isTTY: process.stdout.isTTY === true,
    columns: process.stdout.columns,
    out: (s) => process.stdout.write(s),
    err: (s) => process.stderr.write(s),
  };
}

/**
 * Run the CLI. `argv` excludes node and the script. `io` may override { env, cwd, isTTY, columns, out(s), err(s) }
 * (tests, and the `jenga progress` command of E92_S08_T10). Returns the exit code (0 or 2); never throws.
 */
export function run(argv, io) {
  const io2 = Object.assign(defaultIo(), io || {});
  const warn = (message) => io2.err(`cli.js: warning: ${oneLine(message)}\n`);

  const parsed = parseArgs(argv);
  if (parsed.help) {
    io2.out(`${usage()}\n`);
    return EXIT_OK;
  }
  if (parsed.error === null && parsed.command === null) parsed.error = "no command given";
  if (parsed.error !== null) {
    io2.err(`cli.js: ${oneLine(parsed.error)}\n${usage()}\n`);
    return EXIT_USAGE;
  }

  try {
    const env = Object.assign({}, io2.env);
    if (parsed.flags.root) env.JENGA_PROJECT_ROOT = resolve(io2.cwd, parsed.flags.root);
    if (parsed.flags.lang) env.JENGA_PROGRESS_LANG = parsed.flags.lang;

    const scriptsDir = findScriptsDir({ env, cwd: io2.cwd }) || undefined;
    const cfg = readProgressConfig({ env, cwd: io2.cwd, scriptsDir });
    const charset = resolveCharset({ flag: parsed.flags.charset, env, config: cfg.values.progress_charset });
    const color = resolveColor({ flag: parsed.flags.color, env, config: cfg.values.progress_color, isTTY: io2.isTTY });
    const width = resolveWidth({ flag: parsed.flags.cols, env, ttyColumns: io2.isTTY ? io2.columns : undefined });
    cfg.warnings.concat(charset.warnings, color.warnings).forEach(warn);

    let labelCache = null;
    const ctx = {
      settings: { charset, color, width },
      glyphs: glyphsFor(charset.value),
      painter: createPainter(color.enabled),
      env,
      cwd: io2.cwd,
      flags: parsed.flags,
      positionals: parsed.positionals,
      rest: parsed.rest,
      labels: () => {
        if (labelCache === null) labelCache = loadLabels({ lang: parsed.flags.lang, env, cwd: io2.cwd, scriptsDir });
        return labelCache;
      },
      readData: (args) => readBoardProgress(args, { env, cwd: io2.cwd, scriptsDir }),
    };

    const result = COMMANDS[parsed.command].run(ctx);
    const res = typeof result === "string" ? { out: result } : result || {};
    if (res.usage) {
      io2.err(`cli.js: ${oneLine(res.usage)}\n${usage()}\n`);
      return EXIT_USAGE;
    }
    if (res.warning) {
      warn(res.warning);
    } else if (typeof res.out === "string" && res.out !== "") {
      io2.out(res.out.slice(-1) === "\n" ? res.out : `${res.out}\n`);
    }
  } catch (e) {
    warn(e && e.message ? e.message : "unexpected error");
  }
  return EXIT_OK;
}

if (isMainModule(import.meta.url)) {
  // A reader that closes the pipe early (`| head -c1`) makes the next write fail with EPIPE; that is not a failure of
  // the render, so the error is swallowed here (only when run as a program, never in tests that call run()).
  process.stdout.on("error", (e) => {
    if (!e || e.code !== "EPIPE") process.stderr.write(`cli.js: warning: ${oneLine(e && e.message ? e.message : "stdout error")}\n`);
  });
  process.exitCode = run(process.argv.slice(2));
}
