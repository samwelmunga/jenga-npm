/**
 * lib/progress/overview.js - the `overview` view of the Node progress renderers (E92_S08_T05)
 *
 * The default `j.status` overview in the design of the E92 design image, replacing skills/j-status/scripts/render-status-overview.sh as
 * the default (that script stays on disk for --legacy). From `board-progress.sh --graph --counts-only` it prints:
 *
 *   1. a total line (epics, done/total tasks, percent) and the hatched run bar with n/total;
 *   2. only the epics that are not complete, in four groups (needs attention, in progress, started, not started), by percent
 *      (highest first), ties by the numbers of the id; one row per epic: id, bar, done/total, percent, a failed or in-progress
 *      marker and the title cut to the width;
 *   3. the complete epics as ONE line, epics with only rejected tasks or no tasks as one more line;
 *   4. a footer hint.
 *
 * The board total line and run bar are each epic's `tasks.totals`, summed for the board (percent round(done * 100 /
 * denominator)), as the bash renderer prints them (the board-level line stays a task count, E92_S09_T03). Each epic ROW
 * shows the epic percent instead (E92_S09_T04): `epic_progress.percent` as board-progress.sh states it, never recomputed,
 * with its tasks_done/tasks_denominator beside it and, while decomposed < stories, a dim "decomposed/stories" note (label
 * epic_decomposed), so the counts never contradict the percent (section 5.1 of progress-visualisation.md). The rows sort by
 * that percent, and an epic is "complete" only when its goal_reached is true (all tasks done with an undecomposed story
 * left is an open epic). The row bar keeps the task buckets of `tasks.totals`. An epic with a failed story (its own status,
 * epic_progress.failed_stories, E92_S10_T02) is never complete and stops at 99 %; at that cap its row names the failed
 * story before the title (labels goal_failed / goal_failed_more), the place of the congratulation it would have had. Nothing is counted here, every word
 * is a label of the label table and every glyph a charset.js entry. `--all` is the legacy full list, handled by the caller: the
 * flag is accepted and prints nothing, as the bash renderer does. An empty board is one warning (cli.js), never a failure.
 *
 * ESM; Node >= 14.13.1.
 */
import { allocateCells, paintCells, renderBarLine, rejectedNote } from "./bar.js";
import { goalFailedText } from "./dependency-structure.js";
import { clean, renderLine, segsWidth, toAscii, wrapItems } from "./tree-text.js";
import { displayWidth, padEnd, truncate } from "./width.js";

const NEEDED = [
  "ov_board",
  "ov_epics",
  "ov_tasks",
  "ov_pending",
  "ov_group_attention",
  "ov_group_progress",
  "ov_group_started",
  "ov_group_notstarted",
  "ov_complete",
  "ov_hidden",
  "ov_rejected_empty",
  "ov_footer_scope",
  "ov_footer_all",
  "in_progress",
  "failed",
  "rejected_note",
];
const KEYS = ["done", "in_progress", "failed", "pending", "rejected", "denominator"];

const num = (v) => (typeof v === "number" && isFinite(v) && v >= 0 ? v : 0);
const pct = (t) => (t.denominator > 0 ? Math.round((t.done * 100) / t.denominator) : 0);
const lpad = (text, n) => " ".repeat(Math.max(0, n - displayWidth(text))) + text;
/** The digit groups of an id as numbers, compared one by one (E10 after E9). */
const idNumbers = (id) => (String(id).match(/[0-9]+/g) || []).map(Number);
function byPercentThenId(a, b) {
  if (a.p !== b.p) return b.p - a.p;
  const x = idNumbers(a.id);
  const y = idNumbers(b.id);
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const d = (x[i] === undefined ? -1 : x[i]) - (y[i] === undefined ? -1 : y[i]);
    if (d !== 0) return d;
  }
  return 0;
}

/**
 * Render the overview of a `--graph --counts-only` payload. Returns { out } or { warning }.
 * opts: { glyphs, painter, labels, width, charset }.
 */
export function renderOverview(graph, opts) {
  const { glyphs, painter, labels, width } = opts;
  const missing = NEEDED.filter((k) => typeof labels[k] !== "string" || labels[k] === "")[0];
  if (missing) return { warning: `the label table has no ${missing}` };
  const list = graph && Array.isArray(graph.epics) ? graph.epics.filter((e) => e && typeof e.id === "string") : [];
  if (list.length === 0) return { warning: "the board has no epics" };

  const epics = list.map((e) => {
    const raw = (e.tasks && e.tasks.totals) || {};
    const t = {};
    KEYS.forEach((k) => {
      t[k] = num(raw[k]);
    });
    // E92_S09_T04: the row's percent and counts are the script's epic_progress, read as stated (absent: 0 and 0/0).
    const ep = e.epic_progress && typeof e.epic_progress === "object" ? e.epic_progress : {};
    const whole = (v) => Math.floor(num(v));
    const ev = {
      percent: Math.min(100, whole(ep.percent)),
      done: whole(ep.tasks_done),
      den: whole(ep.tasks_denominator),
      stories: whole(ep.stories),
      decomposed: whole(ep.decomposed),
      reached: ep.goal_reached === true,
      // E92_S10_T02: the failed stories the script states; at the 99 % cap the row names them before its title
      failedStories: Array.isArray(ep.failed_stories) ? ep.failed_stories.filter((id) => typeof id === "string" && id) : [],
    };
    return { id: e.id, title: clean(e.title), t, ev, p: ev.percent, failedText: goalFailedText(labels, ev) };
  });
  const tot = {};
  KEYS.forEach((k) => {
    tot[k] = epics.reduce((s, e) => s + e.t[k], 0);
  });
  // The run bar reads the same keys as board-progress.sh's levels totals; `unknown` is not part of an epic's task totals here.
  const barTotals = Object.assign({ unknown: 0 }, tot);

  const line = (segs) => renderLine(segs, painter, width, glyphs.ellipsis);
  const sep = ` ${glyphs.sep} `;
  const out = [];

  // 1. the total line, the run bar and the counts
  const full = `${labels.ov_board}${sep}${epics.length} ${labels.ov_epics}${sep}${tot.done}/${tot.denominator} ${labels.ov_tasks}${sep}${pct(tot)} %`;
  const short = `${labels.ov_board} ${epics.length}${sep}${tot.done}/${tot.denominator}${sep}${pct(tot)} %`;
  out.push(line([[displayWidth(full) <= width ? full : short, "bold"]]));
  if (width >= 50 && tot.denominator > 0) {
    out.push("  " + renderBarLine(barTotals, { glyphs, painter, labels, width: width - 2, cells: Math.max(10, Math.min(width - 4, 40) - 14) }));
  }
  // The run bar's own text already counts in progress, red and rejected; the line below adds what it leaves out (pending), or all
  // four when the terminal is too narrow for a bar.
  const withBar = width >= 50 && tot.denominator > 0;
  const counts = [];
  if (!withBar && tot.in_progress > 0) counts.push([[`${glyphs.ready} ${tot.in_progress} ${labels.in_progress}`, "in_progress"]]);
  if (!withBar && tot.failed > 0) counts.push([[`${glyphs.cross} ${tot.failed} ${labels.failed}`, "failed"]]);
  if (tot.pending > 0) counts.push([[`${glyphs.locked} ${tot.pending} ${labels.ov_pending}`, "pending"]]);
  if (!withBar && tot.rejected > 0) counts.push([[rejectedNote(labels, glyphs, tot.rejected), "dim"]]);
  if (counts.length > 0) wrapItems([["  ", ""]], counts, [["  ", ""]], width, "  ").forEach((l) => out.push(line(l)));
  out.push("");

  // 2. the open epics in four groups
  const complete = epics.filter((e) => e.t.denominator > 0 && e.ev.reached);
  const empty = epics.filter((e) => e.t.denominator === 0);
  const open = epics.filter((e) => e.t.denominator > 0 && !e.ev.reached);
  const failing = open.filter((e) => e.t.failed > 0);
  const busy = open.filter((e) => e.t.failed === 0 && e.t.in_progress > 0);
  const begun = open.filter((e) => e.t.failed === 0 && e.t.in_progress === 0 && e.t.done > 0);
  const untouched = open.filter((e) => e.t.failed === 0 && e.t.in_progress === 0 && e.t.done === 0);

  const marker = (t) => (t.failed > 0 ? [`${glyphs.cross}${t.failed}`, "failed"] : t.in_progress > 0 ? [`${glyphs.ready}${t.in_progress}`, "in_progress"] : ["", ""]);
  const group = (name, style, items) => {
    if (items.length === 0) return;
    const sorted = items.slice().sort(byPercentThenId);
    const idW = Math.max(3, ...sorted.map((e) => displayWidth(e.id)));
    const cntW = Math.max(...sorted.map((e) => `${e.ev.done}/${e.ev.den}`.length));
    // the "decomposed/stories" note beside the percent, only while some stories have no task (E92_S09_T04)
    const note = (e) =>
      e.ev.decomposed < e.ev.stories && typeof labels.epic_decomposed === "string" && labels.epic_decomposed !== ""
        ? labels.epic_decomposed.replace("%d", String(e.ev.decomposed)).replace("%d", String(e.ev.stories))
        : "";
    const pctW = Math.max(...sorted.map((e) => `${e.p} %`.length));
    const mkW = Math.max(...sorted.map((e) => displayWidth(marker(e.t)[0])));
    const barW = width >= 80 ? 14 : width >= 60 ? 10 : 6;
    out.push(line([[`${name} (${items.length})`, style]]));
    sorted.forEach((e) => {
      const mk = marker(e.t);
      const segs = [["  ", ""], [padEnd(e.id, idW), "bold"], [" ", ""]];
      if (width >= 50) {
        segs.push([paintCells(allocateCells([e.t.done, e.t.in_progress, e.t.failed, e.t.pending], barW), glyphs, painter), ""], [" ", ""]);
      }
      segs.push([lpad(`${e.ev.done}/${e.ev.den}`, cntW), ""], [" ", ""], [lpad(`${e.p} %`, pctW), ""]);
      if (note(e) !== "") segs.push(["  ", ""], [note(e), "dim"]);
      const room = width - segsWidth(segs) - 2 - mkW - 2;
      if (room >= 4) {
        segs.push(["  ", ""], [padEnd(mk[0], mkW), mk[1]], ["  ", ""]);
        // E92_S10_T02: a failed story keeps the epic at 99 % without the goal; the row names it before the title
        const ft = e.failedText !== "" ? truncate(e.failedText, room, glyphs.ellipsis) : "";
        const rest = room - displayWidth(ft) - (ft !== "" ? displayWidth(sep) : 0);
        if (ft !== "") segs.push([ft, "failed"]);
        if (ft === "") segs.push([truncate(e.title, room, glyphs.ellipsis), "dim"]);
        else if (rest >= 4) segs.push([sep, "dim"], [truncate(e.title, rest, glyphs.ellipsis), "dim"]);
      } else if (mk[0] !== "") segs.push(["  ", ""], mk);
      out.push(line(segs));
    });
    out.push("");
  };
  group(labels.ov_group_attention, "bold+failed", failing);
  group(labels.ov_group_progress, "bold+in_progress", busy);
  group(labels.ov_group_started, "bold+in_progress", begun);
  group(labels.ov_group_notstarted, "bold+pending", untouched);

  // 3. the collapsed epics
  if (complete.length > 0) {
    const tasks = complete.reduce((s, e) => s + e.t.done, 0);
    out.push(line([[`${glyphs.star} ${labels.ov_complete} (${complete.length})`, "bold+done"], [`  ${tasks} ${labels.ov_tasks}${sep}${labels.ov_hidden}`, "dim"]]));
  }
  if (empty.length > 0) {
    out.push(line([[`${glyphs.rejected} ${labels.ov_rejected_empty} (${empty.length}): ${empty.map((e) => e.id).join(", ")}`, "pending"]]));
  }
  out.push("");

  // 4. the footer
  const one = `${labels.ov_footer_scope}  ${glyphs.sep}  ${labels.ov_footer_all}`;
  if (displayWidth(one) <= width) out.push(line([[one, "dim"]]));
  else {
    out.push(line([[labels.ov_footer_scope, "dim"]]));
    out.push(line([[labels.ov_footer_all, "dim"]]));
  }

  const text = out.join("\n");
  return { out: opts.charset === "ascii" ? toAscii(text) : text };
}

/** `overview [--all]` */
export function overviewCommand(ctx) {
  if (ctx.positionals.length > 0) return { usage: `overview takes no id (got ${ctx.positionals[0]}); scope <id> shows one epic or story` };
  if (ctx.flags.all) return { out: "" };
  const data = ctx.readData(["--graph", "--counts-only"]);
  if (!data.ok) return { warning: data.warning };
  const lab = ctx.labels();
  if (!lab.ok) return { warning: lab.warning };
  return renderOverview(data.data, { glyphs: ctx.glyphs, painter: ctx.painter, labels: lab.labels, width: ctx.settings.width.value, charset: ctx.settings.charset.value });
}
