/**
 * lib/progress/charset.js - explicit glyph set for the Node progress renderers (E92_S08_T03)
 *
 * Glyphs are an EXPLICIT choice, never a locale guess. The order is:
 *
 *   --charset utf8|ascii, then JENGA_PROGRESS_CHARSET, then the config key progress_charset
 *   (<configs dir>/dashboard-config.json), then the default utf8.
 *
 * LC_ALL, LC_CTYPE and LANG are never read here or anywhere in lib/progress/. The Bash tool an agent runs in has
 * LANG="" (locale C) and a pipe on stdout, which is what made the bash renderers fall back to ASCII; Node always
 * writes UTF-8, so the choice is data, not an inference.
 *
 * GLYPHS holds the two tables. Every entry is exactly ONE code point and ONE terminal cell in both tables, so a
 * layout counts glyphs, not bytes (width.js pins this with a test, so a double-width glyph added later fails
 * loudly). Every byte of the ascii table is below 0x80. The table key names are the contract renderers code
 * against; they are not words shown to the user.
 *
 * Every task state has its own glyph, so a state is never told apart by colour alone (E92_S11_T01, user decision
 * 2026-11-15). Run-bar cells: done runFull, in progress runInProgress, failed cross, pending runEmpty. Tree marks: done
 * done, ready ready, in progress inProgress, failed cross, rejected rejected, locked locked. runInProgress shares its
 * utf8 glyph with hatch on purpose but is its own key, because the ascii glyphs differ (= versus :).
 * unfinished (E92_S11_T02) is the tree mark of a done task whose dependency is not done (board-progress.sh --graph
 * unfinished_deps): a "?" in both tables, drawn in the in-progress colour in place of the task's own mark.
 *
 * ESM, no dependency; Node >= 14.13.1.
 */
import { resolveChoice } from "./config.js";

export const CHARSETS = ["utf8", "ascii"];
export const DEFAULT_CHARSET = "utf8";
export const ENV_CHARSET = "JENGA_PROGRESS_CHARSET";
export const CONFIG_KEY_CHARSET = "progress_charset";

const UTF8 = {
  full: "━",
  empty: "╌",
  runFull: "▰",
  runEmpty: "▱",
  runInProgress: "▒",
  block: "█",
  hatch: "▒",
  done: "●",
  ready: "◉",
  inProgress: "◐",
  unfinished: "?",
  locked: "○",
  arrow: "→",
  shaft: "─",
  head: "▸",
  flag: "⚑",
  star: "★",
  rejected: "⊘",
  check: "✓",
  cross: "✕",
  sep: "·",
  ellipsis: "…",
  tee: "├",
  corner: "└",
  vert: "│",
  fork: "┬",
  back: "◂",
};

const ASCII = {
  full: "#",
  empty: "-",
  runFull: "#",
  runEmpty: "-",
  runInProgress: "=",
  block: "#",
  hatch: ":",
  done: "*",
  ready: "@",
  inProgress: "%",
  unfinished: "?",
  locked: "o",
  arrow: ">",
  shaft: "-",
  head: ">",
  flag: ">",
  star: "*",
  rejected: "x",
  check: "+",
  cross: "x",
  sep: "-",
  ellipsis: "~",
  tee: "+",
  corner: "+",
  vert: "|",
  fork: "+",
  back: "<",
};

/** The two glyph tables, frozen: GLYPHS.utf8 and GLYPHS.ascii have the same keys. */
export const GLYPHS = Object.freeze({ utf8: Object.freeze(UTF8), ascii: Object.freeze(ASCII) });

/** True when `value` names a charset. */
export function isCharset(value) {
  return typeof value === "string" && CHARSETS.indexOf(value) >= 0;
}

/**
 * Resolve the charset. `inputs` = { flag, env, config } where `env` is an environment object (process.env) of which
 * only JENGA_PROGRESS_CHARSET is read, and `config` is the raw progress_charset value from the config file (or
 * undefined). Returns { value, source, warnings } (see resolveChoice).
 */
export function resolveCharset(inputs) {
  const i = inputs || {};
  const env = i.env || {};
  return resolveChoice({
    flag: i.flag,
    envValue: env[ENV_CHARSET],
    envName: ENV_CHARSET,
    configValue: i.config,
    configKey: CONFIG_KEY_CHARSET,
    allowed: CHARSETS,
    fallback: DEFAULT_CHARSET,
  });
}

/** The glyph table for a charset name; an unknown name gives the default table. */
export function glyphsFor(charset) {
  return charset === "ascii" ? GLYPHS.ascii : GLYPHS.utf8;
}
