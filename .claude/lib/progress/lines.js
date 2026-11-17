/**
 * lib/progress/lines.js - the after-task and after-story lines of the Node progress renderers (E92_S08_T04)
 *
 * after-task    the line printed after a finished task (E92_S06_T22). It ALWAYS shows the story the finished task
 *               belongs to, never its epic and never the whole run: `after-task --task <id>[,<id>...]` resolves each
 *               task to its own `story_id`, then prints one run-bar line per DISTINCT story, in the order each story is
 *               first seen (a wave that finishes tasks of several stories prints one line per story). The line is the run
 *               bar of bar.js led by the story id. `--story <id>[,<id>...]` names the stories directly and skips the
 *               task lookup.
 * after-story   the story-finished line (E92_S06_T23): id, bar, goal mark, `n/total · pct %`, then the counts of work in
 *               progress, failed, ready and rejected, which wrap under the bar instead of being cut. This command only
 *               DRAWS the line it is asked to draw: whether a story has finished, and the once-per-completion ledger,
 *               stay in skills/j-break/scripts/story-finished.sh.
 *
 * Port of scripts/render-story-bar.sh (renderStoryLine) in the hatched design. Numbers come only from
 * scripts/board-progress.sh through the cli context (`ctx.readData`); a task is mapped to its story by the `story_id`
 * that `board-progress.sh --graph` prints for it, so this file counts nothing and reads no board file. Words come from
 * the label table, glyphs from charset.js.
 *
 * A problem (an unknown id, an empty story, a script that fails, no label table) is a warning value, never a throw:
 * every id is resolved before anything is drawn, so a bad id prints nothing at all (cli.js then prints one warning on
 * stderr, nothing on stdout, and exits 0).
 *
 * ESM; Node >= 14.13.1.
 */
import { COLOUR, DEFAULT_CELLS, allocateCells, paintCells, pickLevel, renderBarLine } from "./bar.js";
import { displayWidth, truncate } from "./width.js";

export const MIN_STORY_CELLS = 8;
export const MAX_STORY_CELLS = 30;
export const TEXT_ONLY_BELOW = 40;

const TASK_ID = /^E[0-9]+_S[0-9]+_T[0-9]+$/;
const STORY_ID = /^E[0-9]+_S[0-9]+$/;

/** Ids of a comma separated list (a space around a comma is fine), empty elements dropped. */
const splitIds = (text) =>
  String(text || "")
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s !== "");

/** The width-normalised key of an id: E01_S02 and E1_S2 are the same item, as in board-progress.sh. */
const idKey = (id) => id.replace(/[0-9]+/g, (n) => String(Number(n)));

/** `id` once per distinct key, in first-seen order. */
function distinct(ids) {
  const seen = {};
  return ids.filter((id) => {
    const key = idKey(id);
    if (Object.prototype.hasOwnProperty.call(seen, key)) return false;
    seen[key] = true;
    return true;
  });
}

// ---------------------------------------------------------------------------
// the story line
// ---------------------------------------------------------------------------

const widthOf = (text) => displayWidth(text);

/**
 * Render the story-finished line for `totals`. opts: { id, glyphs, painter, labels, width, ready }. Returns the text of
 * one line, or of several (the counts wrapped under the bar) joined with newlines; no line is wider than `width`.
 */
export function renderStoryLine(totals, opts) {
  const { glyphs, painter, labels, id, width } = opts;
  const t = totals;
  const ready = opts.ready || 0;
  const pct = t.denominator > 0 ? Math.floor((t.done * 100 + Math.floor(t.denominator / 2)) / t.denominator) : 0;
  const all = t.denominator > 0 && t.done === t.denominator;
  const finished = t.denominator > 0 && t.pending === 0 && t.in_progress === 0;

  const ratio = `${t.done}/${t.denominator}`;
  const tail = ` ${ratio} ${glyphs.sep} ${pct} %`;
  const tailW = widthOf(tail);
  const headW = widthOf(id) + 2;

  // The counts, in display order: [plain, colour name].
  const extras = [];
  if (t.in_progress > 0) extras.push([`${glyphs.head} ${t.in_progress} ${labels.in_progress}`, COLOUR.in_progress]);
  if (t.failed > 0) extras.push([`${glyphs.cross} ${t.failed} ${t.failed === 1 ? labels.sl_failed_one : labels.sl_failed_many}`, COLOUR.failed]);
  if (ready > 0) extras.push([`${glyphs.ready} ${ready} ${labels.sl_ready}`, COLOUR.ready]);
  if (t.rejected > 0) extras.push([`${glyphs.rejected} ${t.rejected} ${labels.sl_rejected}`, COLOUR.rejected]);
  const extrasW = extras.reduce((sum, [text], i) => sum + widthOf(text) + (i === 0 ? 0 : 2), 0);

  const textOnly = () => {
    let plain = `${id} ${ratio} ${glyphs.sep} ${pct} %`;
    if (widthOf(plain) > width) {
      plain = truncate(plain, width, glyphs.ellipsis);
      if (widthOf(plain) > width) plain = truncate(plain, width);
      return plain;
    }
    return `${painter.bold(id)} ${painter.bold(ratio)} ${glyphs.sep} ${pct} %`;
  };

  if (width < TEXT_ONLY_BELOW) return textOnly();

  // The bar leaves room for the counts when they can share the line, then is clamped to 8..30 cells.
  let fixed = headW + 1 + tailW;
  if (extras.length > 0) fixed += 2 + extrasW;
  let cells = width - fixed;
  if (cells < MIN_STORY_CELLS) cells = MIN_STORY_CELLS;
  if (cells > MAX_STORY_CELLS) cells = MAX_STORY_CELLS;
  if (headW + cells + 1 + tailW > width) return textOnly();

  // A finished story ends in a star: green when everything is done, red when it holds failed work. Otherwise a flag.
  const mark = all || finished ? glyphs.star : glyphs.flag;
  const markColour = all ? COLOUR.done : finished ? COLOUR.failed : COLOUR.pending;
  const counts = allocateCells([t.done, t.in_progress, t.failed, t.pending], cells);
  const line = `${painter.bold(id)}  ${paintCells(counts, glyphs, painter)}${painter.paint(markColour, mark)} ${painter.bold(ratio)} ${glyphs.sep} ${pct} %`;

  if (extras.length === 0) return line;
  const baseW = headW + cells + 1 + tailW;
  if (baseW + 2 + extrasW <= width) return `${line}${extras.map(([text, colour]) => `  ${painter.paint(colour, text)}`).join("")}`;

  // The counts do not fit beside the bar: wrap them under it, indented, greedily and never dropped. A single count wider
  // than the room is clipped as a last resort so that no line exceeds the width.
  const lines = [line];
  const indent = " ".repeat(headW);
  const room = width - headW;
  let current = "";
  let currentW = 0;
  extras.forEach(([text, colour]) => {
    let shown = text;
    let shownW = widthOf(text);
    if (shownW > room) {
      shown = truncate(text, room, glyphs.ellipsis);
      shownW = widthOf(shown);
    }
    if (current !== "" && currentW + 2 + shownW > room) {
      lines.push(`${indent}${current}`);
      current = "";
      currentW = 0;
    }
    current = current === "" ? painter.paint(colour, shown) : `${current}  ${painter.paint(colour, shown)}`;
    currentW += (currentW === 0 ? 0 : 2) + shownW;
  });
  if (current !== "") lines.push(`${indent}${current}`);
  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// the sub-commands
// ---------------------------------------------------------------------------

/**
 * The totals of one story, read through `board-progress.sh --story <id>`. Returns { ok: true, totals } or
 * { ok: false, warning } (an unknown id exits 2 there, an empty story exits 3; both become the warning).
 */
function storyTotals(ctx, id) {
  const data = ctx.readData(["--story", id]);
  if (!data.ok) return { ok: false, warning: data.warning };
  const picked = pickLevel(data.data, "");
  return picked.ok ? picked : { ok: false, warning: `${id}: ${picked.warning}` };
}

/** The distinct stories of `after-task`: the --story ids, then the parent story of every task. Returns { stories } or { warning }. */
function resolveStories(ctx) {
  const taskIds = splitIds(ctx.flags.task).concat(ctx.positionals.reduce((all, p) => all.concat(splitIds(p)), []));
  const storyIds = splitIds(ctx.flags.story);
  const badTask = taskIds.filter((id) => !TASK_ID.test(id))[0];
  if (badTask !== undefined) return { warning: `unknown task id: ${badTask}` };
  const badStory = storyIds.filter((id) => !STORY_ID.test(id))[0];
  if (badStory !== undefined) return { warning: `unknown story id: ${badStory}` };

  const owner = {};
  if (taskIds.length > 0) {
    const graph = ctx.readData(["--graph"]);
    if (!graph.ok) return { warning: graph.warning };
    const rows = graph.data && Array.isArray(graph.data.tasks) ? graph.data.tasks : [];
    rows.forEach((row) => {
      if (row && typeof row.id === "string" && typeof row.story_id === "string" && row.story_id !== "") owner[idKey(row.id)] = row.story_id;
    });
  }
  const stories = storyIds.slice();
  for (let i = 0; i < taskIds.length; i++) {
    const story = owner[idKey(taskIds[i])];
    if (story === undefined) return { warning: `unknown task id, or it names no story: ${taskIds[i]}` };
    stories.push(story);
  }
  return { stories: distinct(stories) };
}

/** Draw `render(id, totals)` for every story, all or nothing: one failing story means one warning and no output. */
function drawStories(ctx, stories, render) {
  const labels = ctx.labels();
  if (!labels.ok) return { warning: labels.warning };
  const lines = [];
  for (let i = 0; i < stories.length; i++) {
    const r = storyTotals(ctx, stories[i]);
    if (!r.ok) return { warning: r.warning };
    lines.push(render(stories[i], r.totals, labels.labels));
  }
  return { out: lines.join("\n") };
}

/** `after-task --task <id>[,<id>...] | --story <id>[,<id>...] [--cells N]` (bare ids are task ids). */
export function afterTaskCommand(ctx) {
  const given = ctx.flags.task || ctx.flags.story || ctx.positionals.length > 0;
  if (!given) return { usage: "after-task needs --task <id>[,<id>...] (or --story <id>[,<id>...])" };
  const resolved = resolveStories(ctx);
  if (resolved.warning) return { warning: resolved.warning };
  const cells = ctx.flags.cells ? Number(ctx.flags.cells) : DEFAULT_CELLS;
  return drawStories(ctx, resolved.stories, (id, totals, labels) =>
    renderBarLine(totals, { glyphs: ctx.glyphs, painter: ctx.painter, labels, width: ctx.settings.width.value, cells, id })
  );
}

/** `after-story --story <id>[,<id>...] [--ready N]` (bare ids are story ids). */
export function afterStoryCommand(ctx) {
  const ids = splitIds(ctx.flags.story).concat(ctx.positionals.reduce((all, p) => all.concat(splitIds(p)), []));
  if (ids.length === 0) return { usage: "after-story needs --story <id>[,<id>...]" };
  const bad = ids.filter((id) => !STORY_ID.test(id))[0];
  if (bad !== undefined) return { warning: `unknown story id: ${bad}` };
  const ready = ctx.flags.ready ? Number(ctx.flags.ready) : 0;
  return drawStories(ctx, distinct(ids), (id, totals, labels) =>
    renderStoryLine(totals, { id, glyphs: ctx.glyphs, painter: ctx.painter, labels, width: ctx.settings.width.value, ready })
  );
}
