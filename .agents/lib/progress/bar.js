/**
 * lib/progress/bar.js - the run bar of the Node progress renderers (E92_S08_T04)
 *
 * Node port of scripts/render-progress-bar.sh in the hatched design of the E92 design image: done cells are filled
 * parallelograms (glyphs.runFull), in-progress cells shaded (glyphs.runInProgress), failed cells crosses (glyphs.cross)
 * and not-started cells outlined parallelograms (glyphs.runEmpty), so no state relies on colour alone (E92_S11_T01). One line:
 *
 *   [<id>  ]<bar><goal> <done>/<denominator>[ · <n> in progress][ · <n> red][ · <n> unknown][ · ⊘ <n> rejected (not counted)]
 *
 * The renderer COUNTS NOTHING. The numbers are the `levels.<level>.totals` of scripts/board-progress.sh (read through
 * data.js), every word is a label of the label table (labels.js) and every glyph is a charset.js entry, so this file
 * holds no status name, no user-visible word and no glyph.
 *
 * Rules carried over unchanged from the bash renderer (the contract, not choices):
 *   - Cells are allocated by largest remainder over done, in progress, failed and pending ONLY; Rejected is excluded
 *     from the denominator and never drawn, only noted (E92 decision 3). A non-zero bucket never rounds to zero cells
 *     while another has more than one, and the bar is full only when nothing is open.
 *   - Colour (E92 decision 2): done green, in progress yellow, failed red, pending grey, the rejected note a muted
 *     blue-grey. Filled cells are the work touched (done, in progress, failed), outlined cells are not started, so the
 *     colour carries the status and the text carries every number: the line is complete without colour.
 *   - Narrow terminals: the bar shrinks to the room left (never above --cells, default 10); below MIN_BAR_CELLS the bar
 *     is dropped and the text alone is printed; text that is still too wide loses segments from the lowest priority
 *     up (unknown, the rejected note, in progress), and only then is cut to width-1 cells plus one ellipsis. done/den
 *     and the failed count are never dropped. No line is ever wider than the width (display width, ANSI not counted).
 *
 * ESM; Node >= 14.13.1.
 */
import { formatLabel } from "./labels.js";
import { GLYPHS } from "./charset.js";
import { SGR } from "./color.js";
import { displayWidth } from "./width.js";

export const MIN_BAR_CELLS = 4;
export const DEFAULT_CELLS = 10;
export const MAX_CELLS = 500;

/**
 * The colour names of color.js's palette, as written by that table: COLOUR.failed is "failed". Renderers paint with
 * these, so a colour name is never retyped here (and never mistaken for a label word).
 */
export const COLOUR = Object.keys(SGR).reduce((all, name) => {
  all[name] = name;
  return all;
}, {});

// The three level names and their default order (the first present wins when none is asked for).
const BOLD = "bold";
const LEVEL_ORDER = "tasks stories epics".split(" ");
const LEVEL_RE = /^(?:tasks|stories|epics)$/;
const EACH_RE = /^(?:epics|stories)$/;

/** True when `value` names one of the three board levels. */
export const isLevel = (value) => typeof value === "string" && LEVEL_RE.test(value);
/** True when `value` is a valid --each key. */
export const isEachKey = (value) => typeof value === "string" && EACH_RE.test(value);
/** True when `value` is a --cells value: an integer from 1 to MAX_CELLS. */
export const isCells = (value) => /^[0-9]{1,3}$/.test(String(value)) && Number(value) >= 1 && Number(value) <= MAX_CELLS;

const isCount = (n) => typeof n === "number" && isFinite(n) && n >= 0 && Math.floor(n) === n;
const TOTAL_KEYS = "done in_progress failed pending rejected unknown denominator".split(" ");

/** True when `totals` holds the seven non-negative integers of the contract. */
export function validTotals(totals) {
  return !!totals && typeof totals === "object" && TOTAL_KEYS.every((k) => isCount(totals[k]));
}

/**
 * Largest-remainder allocation of `cells` over [done, in progress, failed, pending]. Returns four counts that sum to
 * `cells`. A tie goes to the bucket that understates progress (failed, in progress, pending, then done).
 */
export function allocateCells(buckets, cells) {
  const b = buckets.slice(0, 4);
  const total = b[0] + b[1] + b[2] + b[3];
  if (total === 0) return [0, 0, 0, cells];
  const floor = [];
  const rest = [];
  let used = 0;
  for (let k = 0; k < 4; k++) {
    const p = b[k] * cells;
    floor[k] = Math.floor(p / total);
    rest[k] = p % total;
    used += floor[k];
  }
  const c = floor.slice();
  const tieOrder = [2, 1, 3, 0];
  for (let left = cells - used; left > 0; left--) {
    let best = -1;
    let bestRest = -1;
    for (let i = 0; i < 4; i++) {
      const k = tieOrder[i];
      if (rest[k] > bestRest) {
        best = k;
        bestRest = rest[k];
      }
    }
    if (best < 0) break;
    c[best]++;
    rest[best] = -1;
  }
  // A non-zero bucket never rounds to zero cells while another bucket has more than one.
  for (let i = 0; i < 4; i++) {
    const k = tieOrder[i];
    if (b[k] > 0 && c[k] === 0) {
      let donor = -1;
      let most = 1;
      for (let j = 0; j < 4; j++) {
        if (c[j] > most) {
          donor = j;
          most = c[j];
        }
      }
      if (donor >= 0) {
        c[donor]--;
        c[k]++;
      }
    }
  }
  // Never a full bar while work is open (only reachable with one cell, where the minimum rule has no donor).
  if (c[0] === cells && b[1] + b[2] + b[3] > 0) {
    for (const k of [2, 1, 3]) {
      if (b[k] > 0) {
        c[0]--;
        c[k]++;
        break;
      }
    }
  }
  return c;
}

/**
 * The cells as a painted string, in the order done, in progress, failed, pending. Each state has its own glyph as well
 * as its own colour (E92_S11_T01), so the bar reads the same with colour off: done runFull (▰ / #), in progress
 * runInProgress (▒ / =), failed cross (✕ / x), pending runEmpty (▱ / -).
 */
export function paintCells(counts, glyphs, painter) {
  return (
    painter.paint(COLOUR.done, glyphs.runFull.repeat(counts[0])) +
    painter.paint(COLOUR.in_progress, glyphs.runInProgress.repeat(counts[1])) +
    painter.paint(COLOUR.failed, glyphs.cross.repeat(counts[2])) +
    painter.paint(COLOUR.pending, glyphs.runEmpty.repeat(counts[3]))
  );
}

/** The rejected note: the label with its own glyph swapped for the active charset's. */
export function rejectedNote(labels, glyphs, n) {
  return formatLabel(labels.rejected_note, n).split(GLYPHS.utf8.rejected).join(glyphs.rejected);
}

/** Text of a line cut to `width` cells: at most width-1 cells, a dangling separator trimmed, one ellipsis. */
function cutWithEllipsis(text, width, glyphs) {
  const room = Math.max(0, width - Array.from(glyphs.ellipsis).length);
  let chars = Array.from(text).slice(0, room);
  for (;;) {
    const last = chars[chars.length - 1];
    if (last === " ") chars = chars.slice(0, -1);
    else if (last === glyphs.sep && chars[chars.length - 2] === " ") chars = chars.slice(0, -2);
    else break;
  }
  return chars.join("") + glyphs.ellipsis;
}

/**
 * Render one run-bar line from `totals`.
 *
 * opts: { glyphs, painter, labels, width, cells, id }
 *   glyphs, painter   from the cli context (charset.js, color.js)
 *   labels            the label table (labels.js loadLabels().labels)
 *   width             the terminal width in columns
 *   cells             the largest bar width (default 10)
 *   id                an optional scope id printed before the bar (the after-task line names its story)
 * Returns the line without a trailing newline.
 */
export function renderBarLine(totals, opts) {
  const { glyphs, painter, labels } = opts;
  const width = opts.width;
  const maxCells = opts.cells || DEFAULT_CELLS;
  const t = totals;
  const sep = ` ${glyphs.sep} `;

  // The text, as segments [plain text, colour name or "bold" or null], in display order. Segments that can be dropped on a
  // narrow terminal are keyed so the drop order below is explicit.
  const seg = {
    lead: opts.id ? [`${opts.id} `, BOLD] : null,
    base: [`${t.done}/${t.denominator}`, BOLD],
    nothing: t.denominator === 0 ? [`${sep}${labels.nothing}`, null] : null,
    prog: t.in_progress > 0 ? [`${sep}${t.in_progress} ${labels.in_progress}`, COLOUR.in_progress] : null,
    fail: t.failed > 0 ? [`${sep}${t.failed} ${labels.failed}`, COLOUR.failed] : null,
    unk: t.unknown > 0 ? [`${sep}${t.unknown} ${labels.unknown}`, null] : null,
    rej: t.rejected > 0 ? [`${sep}${rejectedNote(labels, glyphs, t.rejected)}`, COLOUR.rejected] : null,
  };
  const order = ["lead", "base", "nothing", "prog", "fail", "unk", "rej"];
  const keep = { lead: false, base: true, nothing: true, prog: true, fail: true, unk: true, rej: true };
  const parts = () => order.filter((k) => seg[k] && keep[k]).map((k) => seg[k]);
  const plain = (list) => list.map((p) => p[0]).join("");
  const paintParts = (list) =>
    list
      .map(([text, colour]) => {
        if (colour === BOLD) {
          const word = text.replace(/ +$/, "");
          return painter.bold(word) + text.slice(word.length);
        }
        return colour ? painter.paint(colour, text) : text;
      })
      .join("");

  // The goal mark: a star when the scope is fully complete, a flag while work remains, none for 0/0.
  let mark = "";
  let markColour = null;
  if (t.denominator > 0) {
    const complete = t.in_progress + t.failed + t.pending + t.unknown === 0 && t.done === t.denominator;
    mark = complete ? glyphs.star : glyphs.flag;
    markColour = complete ? COLOUR.done : COLOUR.pending;
  }

  const textW = displayWidth(plain(parts()));
  const leadW = opts.id ? displayWidth(`${opts.id}  `) : 0;
  let cells = maxCells;
  if (leadW + cells + 1 + displayWidth(mark) + textW > width) {
    const room = width - leadW - 1 - displayWidth(mark) - textW;
    cells = room >= MIN_BAR_CELLS ? room : 0;
  }

  if (cells > 0) {
    const counts = allocateCells([t.done, t.in_progress, t.failed, t.pending], cells);
    const head = opts.id ? `${painter.bold(opts.id)}  ` : "";
    return `${head}${paintCells(counts, glyphs, painter)}${painter.paint(markColour, mark)} ${paintParts(parts())}`;
  }

  // Text only. Drop the lowest priority segments first: unknown, the rejected note, in progress.
  keep.lead = !!opts.id;
  let list = parts();
  for (const drop of ["unk", "rej", "prog"]) {
    if (displayWidth(plain(list)) <= width) break;
    keep[drop] = false;
    list = parts();
  }
  if (displayWidth(plain(list)) > width) return cutWithEllipsis(plain(list), width, glyphs);
  return paintParts(list);
}

/**
 * The totals of one level of a board-progress document. `level` is the level asked for, or "" for the default: tasks,
 * else the first present of tasks, stories, epics. Returns { ok: true, totals } or { ok: false, warning }.
 */
export function pickLevel(doc, level) {
  const levels = doc && doc.levels && typeof doc.levels === "object" ? doc.levels : null;
  if (!levels) return { ok: false, warning: "the progress data has no levels object" };
  let name = level;
  if (!name) name = LEVEL_ORDER.filter((l) => Object.prototype.hasOwnProperty.call(levels, l))[0];
  if (!name || !Object.prototype.hasOwnProperty.call(levels, name)) {
    return { ok: false, warning: name ? `level ${name} is not present in the progress data` : "the progress data has no tasks, stories or epics level" };
  }
  const totals = levels[name] && levels[name].totals;
  if (!validTotals(totals)) return { ok: false, warning: `the totals of level ${name} are not non-negative integers` };
  return { ok: true, totals };
}

// ---------------------------------------------------------------------------
// the `bar` sub-command
// ---------------------------------------------------------------------------

/** The board-progress.sh arguments of a command's scope flags. Returns { args } or { usage }. */
export function scopeArgs(ctx, allowNone) {
  const f = ctx.flags;
  const given = [];
  if (f.epic) given.push(["--epic", f.epic]);
  if (f.story) given.push(["--story", f.story]);
  if (f.ids || ctx.positionals.length > 0) given.push(["--ids", [f.ids].concat(ctx.positionals).filter(Boolean).join(",")]);
  if (f.all) given.push(["--all"]);
  if (f.backlog) given.push(["--backlog"]);
  if (given.length > 1) return { usage: "give one scope: --epic, --story, --ids (or bare ids), --all or --backlog" };
  if (given.length === 0) return allowNone ? { args: ["--all"] } : { usage: "no scope given" };
  return { args: given[0] };
}

/**
 * `bar [--level tasks|stories|epics] [--cells N] [--each epics|stories] [scope]`
 * The scope is one of --epic <id>, --story <id>, --ids <list> (or bare ids), --all (the default) or --backlog. With
 * --each every epic or story of the board gets its own `<id><TAB><line>`, from one `--by-parent` call.
 */
export function barCommand(ctx) {
  const f = ctx.flags;
  const hasScope = f.epic || f.story || f.ids || f.all || f.backlog || ctx.positionals.length > 0;
  if (f.each && f.level) return { usage: "--level cannot be combined with --each" };
  if (f.each && hasScope) return { usage: "--each renders the whole board and takes no scope" };
  const scope = f.each ? { args: ["--by-parent"] } : scopeArgs(ctx, true);
  if (scope.usage) return { usage: scope.usage };

  const data = ctx.readData(scope.args);
  if (!data.ok) return { warning: data.warning };
  const labels = ctx.labels();
  if (!labels.ok) return { warning: labels.warning };
  const base = { glyphs: ctx.glyphs, painter: ctx.painter, labels: labels.labels, width: ctx.settings.width.value, cells: f.cells ? Number(f.cells) : DEFAULT_CELLS };

  if (f.each) {
    const rows = data.data && data.data[f.each];
    if (!Array.isArray(rows)) return { warning: `the progress data has no ${f.each} array` };
    const bad = rows.filter((r) => !r || typeof r.id !== "string" || r.id === "" || !validTotals(r.totals))[0];
    if (bad !== undefined) return { warning: "an element of the progress data is not {id, totals} with non-negative integer totals" };
    return { out: rows.map((r) => `${r.id}\t${renderBarLine(r.totals, base)}`).join("\n") };
  }
  const picked = pickLevel(data.data, f.level || "");
  if (!picked.ok) return { warning: picked.warning };
  return { out: renderBarLine(picked.totals, base) };
}
