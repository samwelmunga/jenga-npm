/**
 * lib/progress/width.js - terminal width and display width for the Node progress renderers (E92_S08_T03)
 *
 * Width of the terminal, first match wins:  --cols N, then COLUMNS (a positive integer, else ignored), then the
 * TTY's own column count when stdout is a terminal, then 80 (the design width).
 *
 * Display width: a glyph counts as ONE cell and ANSI sequences count as zero. There is deliberately no
 * Intl.Segmenter and no wcwidth dependency: the glyph set (charset.js) is fixed and single-width, and
 * tests/lib-progress-core.test.mjs pins that every glyph of both tables is one cell, so a future double-width
 * glyph fails loudly instead of silently breaking a layout. Text is counted per code point, so a glyph above the
 * BMP is still one cell.
 *
 * ESM; Node >= 14.13.1.
 */
import { stripAnsi } from "./color.js";

export const DEFAULT_COLS = 80;
export const MIN_COLS = 1;
export const MAX_COLS = 10000;

/** A positive integer within MIN_COLS..MAX_COLS from a string or number, else null. */
export function parseCols(value) {
  const text = typeof value === "number" ? String(value) : value;
  if (typeof text !== "string" || !/^[0-9]+$/.test(text) || text.length > 6) return null;
  const n = Number(text);
  return n >= MIN_COLS && n <= MAX_COLS ? n : null;
}

/**
 * Resolve the width. `inputs` = { flag, env, ttyColumns }: `flag` is the --cols value (string or number), `env` an
 * environment object of which only COLUMNS is read, `ttyColumns` the column count of a TTY stdout (pass undefined
 * when stdout is not a terminal). Returns { value, source: "flag" | "env" | "tty" | "default" }. An invalid flag
 * is skipped here; cli.js rejects it as a usage error before it gets this far.
 */
export function resolveWidth(inputs) {
  const i = inputs || {};
  const fromFlag = parseCols(i.flag);
  if (fromFlag !== null) return { value: fromFlag, source: "flag" };
  const fromEnv = parseCols((i.env || {}).COLUMNS);
  if (fromEnv !== null) return { value: fromEnv, source: "env" };
  const fromTty = parseCols(i.ttyColumns);
  if (fromTty !== null) return { value: fromTty, source: "tty" };
  return { value: DEFAULT_COLS, source: "default" };
}

/** Number of terminal cells `text` occupies: ANSI stripped, one cell per code point. */
export function displayWidth(text) {
  return Array.from(stripAnsi(text)).length;
}

/** `text` padded on the right with spaces to `width` cells (plain text; never shortened). */
export function padEnd(text, width) {
  const missing = width - displayWidth(text);
  return missing > 0 ? text + " ".repeat(missing) : text;
}

/**
 * Plain `text` cut to at most `width` cells; when it is cut, it ends in `ellipsis` (pass the glyph of the active
 * charset, GLYPHS[charset].ellipsis; none when omitted). Does not handle ANSI: truncate first, paint after.
 */
export function truncate(text, width, ellipsis) {
  const mark = ellipsis === undefined ? "" : String(ellipsis);
  const chars = Array.from(text);
  if (chars.length <= width) return text;
  if (width <= 0) return "";
  const room = Math.max(0, width - Array.from(mark).length);
  return chars.slice(0, room).join("") + mark;
}
