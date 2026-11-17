/**
 * lib/progress/scope.js - the `scope <E## | E##_S##>` view of the Node progress renderers (E92_S08_T05)
 *
 * The scoped `j.status` view in the design of the E92 design image, replacing skills/j-status/scripts/render-status-scope-view.sh
 * as the default (that script stays on disk for --legacy):
 *
 *   header        <id> · <title> and the percent: for an epic the epic percent the script states in `epic_progress` (E92_S09_T04,
 *                 section 5.1 of progress-visualisation.md), never recomputed, with "decomposed/stories" before it while some
 *                 stories have no task; for a story the story's own task percent, as before
 *   milestone     for an epic: the stories of the epic in the order the payload lists them (one stop per story), the epic as the
 *                 goal flag at the end, a label under each stop; then one line with the message and "Ready to take"
 *   run bar       the hatched run bar of bar.js with n/total
 *   bands         one band per story (tree-text.js): ● done, ◉ ready, ◐ in progress, ○ locked, ? a done task whose
 *                 dependency is not done (E92_S11_T02), arrows between dependent nodes
 *   lists         "Ready to take: ..." and one "<task> unlocked by <what it waits for>" line per locked node, then one
 *                 "? <task>: Done although dependency <id> is not done - ..." line per flagged done task (E92_S11_T02)
 *
 * "Current" and "next" follow the rules render-status-scope-view.sh already uses, and no new rule is added:
 *   - a story's stop is the `stop` the payload states (done, in_progress, failed, else pending; no tasks: rejected glyph); the
 *     CURRENT milestone is a story whose stop is in_progress, its label in bold and its glyph ◉ (the old track's ◉ stop);
 *   - the message is chosen from the stated percent and the number of unfinished stories exactly as the bash view does
 *     (complete; last story; at least 80 %; at least 50 %; above 0; else the start line); for an epic (E92_S09_T04) the
 *     percent is epic_progress.percent, "complete" is its goal_reached and an undecomposed story counts as unfinished, so
 *     an epic whose tasks are all done is not called complete while a story has no task yet; the milestone goal flag turns
 *     to the star on goal_reached too. The run bar stays the epic's task bar (tasks.totals, its own n/total). While a story
 *     of the epic has failed by its own status (epic_progress.failed_stories, E92_S10_T02) the script states no goal and
 *     at most 99 %; at the cap the message names the failed story (labels goal_failed / goal_failed_more) instead of the
 *     done message, before the last-story and percent messages; below 99 % the messages are unchanged.
 *   - "next" is the old `readynext`: "Ready to take: " and the first two ids of the payload's `ready`, "(+N)" for the rest.
 *   A story id gets the header without the track, and without a message unless the story is complete, as before. The track is
 *   dropped under 50 columns or when it does not fit (the old formula: width min(cols, 64), at most 10 cells per story).
 *
 * Structure only from dependency-structure.js, which builds the bands, start nodes and goal for every epic with at least one
 * task, with or without dependency edges (E92_S09_T01 removed the one-column fallback this file used to carry for edge-free
 * epics); its structure is empty only for an epic with no tasks, which this view already reports as a warning.
 * Counts only from `board-progress.sh --graph --within <id>`. Every word from the label table. An unknown id, an empty epic
 * or a failing script is one warning value (cli.js prints one line on stderr, nothing on stdout, exit 0); a task id or a
 * malformed id is a usage error.
 *
 * ESM; Node >= 14.13.1.
 */
import { DEFAULT_CELLS, renderBarLine, validTotals } from "./bar.js";
import { buildDependencyStructure, fillUnlockedBy, goalFailedText, unfinishedDepText } from "./dependency-structure.js";
import { clean, listName, renderBands, renderLine, toAscii, wrapItems } from "./tree-text.js";
import { displayWidth, truncate } from "./width.js";

const SCOPE_ID = /^E[0-9]+(?:_S[0-9]+)?$/;
const TASK_ID = /^E[0-9]+_S[0-9]+_T[0-9]+$/;
/** Gradient of the milestone line (xterm 256 colours, teal to green, as the design image). */
const GRADIENT = [50, 49, 48, 47, 46, 82, 118];
const TRACK_MAX = 64;
const NEEDED = [
  "goal",
  "ready_to_take",
  "nothing_ready",
  "nothing",
  "unlocked_by",
  "group_tasks",
  "sc_msg_done",
  "sc_msg_last",
  "sc_msg_almost",
  "sc_msg_half",
  "sc_msg_going",
  "sc_msg_start",
  "sc_no_stories",
];

/** The label of the scope id as board-progress.sh takes it: E3_S5 stays E3_S5 (the script normalises the width). */
export function normaliseScopeId(text) {
  const t = String(text || "").trim();
  if (TASK_ID.test(t.toUpperCase())) return { usage: `'${t}' is a task id; give an epic or a story id` };
  if (!SCOPE_ID.test(t.toUpperCase())) return { usage: `malformed id '${t}' (expected E<digits> or E<digits>_S<digits>)` };
  return { id: t.toUpperCase() };
}

const pct = (t) => (t && t.denominator > 0 ? Math.round((t.done * 100) / t.denominator) : 0);
const storyNo = (id) => {
  const m = /_(S[0-9]+)$/.exec(String(id));
  return m ? m[1] : String(id);
};

// ---------------------------------------------------------------------------
// the milestone line
// ---------------------------------------------------------------------------

function stopGlyph(story, glyphs) {
  if (!story.totals || !(story.totals.denominator > 0)) return [glyphs.rejected, "dim"];
  if (story.stop === "done") return [glyphs.done, "done"];
  if (story.stop === "in_progress") return [glyphs.ready, "bold+in_progress"];
  if (story.stop === "failed") return [glyphs.cross, "failed"];
  return [glyphs.locked, "locked"];
}

/** The epic's `epic_progress` as the script states it, read and never recomputed; zeros when the payload has none. */
function epicProgressOf(epic) {
  const ep = epic && epic.epic_progress && typeof epic.epic_progress === "object" ? epic.epic_progress : {};
  const whole = (v) => (typeof v === "number" && isFinite(v) && v > 0 ? Math.floor(v) : 0);
  const failedStories = Array.isArray(ep.failed_stories) ? ep.failed_stories.filter((id) => typeof id === "string" && id) : [];
  return { percent: Math.min(100, whole(ep.percent)), stories: whole(ep.stories), decomposed: whole(ep.decomposed), reached: ep.goal_reached === true, failedStories };
}

/** The two lines of the milestone track (cells and labels) as segments; [] when there is no room. allDone: the goal is reached. */
function trackLines(stories, allDone, goalLabel, cols, glyphs, painterOn) {
  const n = stories.length;
  const w = Math.max(Math.min(Math.floor((Math.min(cols, TRACK_MAX) - 4) / Math.max(n, 1)) - 1, 10), 1);
  const total = 4 + n * (w + 1);
  if (n === 0 || cols < 50 || total > cols) return [];
  const at = (pos) => `g${GRADIENT[Math.min(GRADIENT.length - 1, Math.floor((pos / (total - 1)) * (GRADIENT.length - 1)))]}`;
  const cells = [[glyphs.done, at(0)]];
  let pos = 1;
  const stops = [];
  stories.forEach((s) => {
    const den = s.totals && s.totals.denominator > 0 ? s.totals.denominator : 0;
    const fill = den > 0 ? Math.round((s.totals.done * w) / den) : 0;
    for (let i = 0; i < w; i++, pos++) cells.push(i < fill ? [glyphs.full, at(pos)] : [glyphs.empty, "pending"]);
    stops.push(pos);
    cells.push(stopGlyph(s, glyphs));
    pos++;
  });
  cells.push([(allDone ? glyphs.full : glyphs.empty).repeat(2), allDone ? "done" : "pending"]);
  cells.push([allDone ? glyphs.star : glyphs.flag, allDone ? "bold+done" : "bold+in_progress"]);

  // labels under the stops, left aligned at the stop; a title that does not fit in w cells gives way to its story number
  const compact = w + 1 < 4;
  const labels = [];
  let col = 0;
  const put = (text, style, at0) => {
    const from = col > 0 ? Math.max(at0, col + 1) : at0;
    if (from > col) labels.push([" ".repeat(from - col), ""]);
    labels.push([text, style]);
    col = from + displayWidth(text);
  };
  if (compact) {
    put(`${storyNo(stories[0].id)} ${glyphs.ellipsis} ${storyNo(stories[n - 1].id)}`, "", 0);
  } else {
    stories.forEach((s, k) => {
      const title = clean(s.title);
      const text = title !== "" && displayWidth(title) <= w ? title : storyNo(s.id);
      const style = s.stop === "in_progress" ? "bold" : s.stop === "failed" ? "failed" : s.stop === "done" ? "" : "dim";
      put(truncate(text, w, glyphs.ellipsis), style, stops[k]);
    });
    if (displayWidth(goalLabel) <= cols - (n * (w + 1) + 3)) put(goalLabel, "", n * (w + 1) + 3);
  }
  return [cells, labels];
}

function messageLine(isStory, stories, T, labels, ep) {
  // a story: its unfinished stories (none or itself) and its task percent, as before; an epic: the epic_progress figures
  const left = isStory
    ? stories.filter((s) => s.totals && s.totals.denominator > 0 && s.complete !== true).length
    : Math.max(0, ep.stories - stories.filter((s) => s.complete === true).length);
  const allComplete = isStory ? stories.length > 0 && left === 0 && T.denominator > 0 : ep.reached;
  const p = isStory ? pct(T) : ep.percent;
  const fill = (text) => String(text).replace("%d", String(left));
  // E92_S10_T02: where the congratulation would have been (goal not reached, percent at the cap of 99, a failed story
  // stated), the failed story is named instead; decided by the script, only worded here.
  const failedText = isStory ? "" : goalFailedText(labels, ep);
  let text = null;
  if (isStory) text = allComplete ? labels.sc_msg_done : null;
  else if (stories.length === 0) text = null;
  else if (allComplete) text = labels.sc_msg_done;
  else if (failedText !== "") return [failedText, "failed"];
  else if (left === 1) text = labels.sc_msg_last;
  else if (p >= 80) text = fill(labels.sc_msg_almost);
  else if (p >= 50) text = fill(labels.sc_msg_half);
  else if (p > 0) text = fill(labels.sc_msg_going);
  else text = labels.sc_msg_start;
  return text === null ? null : [text, allComplete ? "done" : "in_progress"];
}

// ---------------------------------------------------------------------------
// the view
// ---------------------------------------------------------------------------

/**
 * Render the scope view of a `--graph --within <id>` payload. Returns { out } or { warning }.
 * opts: { glyphs, painter, labels, width, layout, id (the id as typed) }.
 */
export function renderScope(graph, opts) {
  const { glyphs, painter, labels, width } = opts;
  const layout = opts.layout || "auto";
  const missing = NEEDED.filter((k) => typeof labels[k] !== "string" || labels[k] === "")[0];
  if (missing) return { warning: `the label table has no ${missing}` };
  if (!graph || typeof graph !== "object" || !Array.isArray(graph.tasks)) return { warning: "the progress graph has no tasks array" };

  const stories = (graph.stories || []).filter((s) => s && typeof s.id === "string");
  const epics = (graph.epics || []).filter((e) => e && typeof e.id === "string");
  const scopeId = clean((graph.scope && graph.scope.within) || opts.id);
  const isStory = /_S[0-9]+$/.test(scopeId);
  const epicId = (epics[0] && epics[0].id) || (graph.tasks[0] && graph.tasks[0].epic_id) || "";
  if (graph.tasks.length === 0 || epicId === "") return { warning: `${scopeId} has no tasks; there is nothing to draw` };

  let T = null;
  if (isStory && stories.length > 0) T = stories[0].totals;
  else if (epics.length > 0) T = epics[0].tasks && epics[0].tasks.totals;
  if (!validTotals(T)) return { warning: "the progress graph has no valid totals for this scope" };
  const title = clean(isStory ? (stories[0] && stories[0].title) || scopeId : epics[0] && epics[0].title) || scopeId;

  const structure = buildDependencyStructure(graph, epicId, labels);
  const stopOf = (sid) => {
    const s = stories.filter((x) => x.id === sid)[0];
    return s ? s.stop : undefined;
  };
  const line = (segs) => renderLine(segs, painter, width, glyphs.ellipsis);
  const out = [];

  // 1. header: scope, title and percent (an epic: the epic percent, with decomposed/stories while lower)
  const ep = epicProgressOf(epics[0]);
  const decomposedNote =
    !isStory && ep.decomposed < ep.stories && typeof labels.epic_decomposed === "string" && labels.epic_decomposed !== ""
      ? `${labels.epic_decomposed.replace("%d", String(ep.decomposed)).replace("%d", String(ep.stories))} ${glyphs.sep} `
      : "";
  const percent = `${decomposedNote}${isStory ? pct(T) : ep.percent} %`;
  const pw = Math.min(width, TRACK_MAX);
  const head = truncate(`${scopeId} ${glyphs.sep} ${title}`, Math.max(1, width - percent.length - 2), glyphs.ellipsis);
  out.push(line([[head, "bold"], [" ".repeat(Math.max(2, pw - displayWidth(head) - percent.length)), ""], [percent, "bold+done"]]));

  // 2. the milestone track (an epic only) and its labels
  if (!isStory) trackLines(stories, ep.reached, labels.goal, width, glyphs, painter.enabled).forEach((l) => out.push(line(l)));

  // 3. the message and "next": the first two ready ids
  const ready = graph.ready || [];
  const parts = [];
  const msg = messageLine(isStory, stories, T, labels, ep);
  if (msg) parts.push([msg]);
  if (ready.length > 0) {
    const more = ready.length > 2 ? ` (+${ready.length - 2})` : "";
    parts.push([[`${labels.ready_to_take}: ${ready.slice(0, 2).map(clean).join(", ")}${more}`, "ready"]]);
  }
  if (parts.length > 0) {
    const segs = [];
    parts.forEach((p, i) => {
      if (i > 0) segs.push([`  ${glyphs.head}  `, "dim"]);
      p.forEach((x) => segs.push(x));
    });
    out.push(line(segs));
  }
  out.push("");

  // 4. the run bar
  out.push(renderBarLine(T, { glyphs, painter, labels, width, cells: Math.max(DEFAULT_CELLS, 20), id: (isStory ? stories[0] && stories[0].id : epics[0].id) || scopeId }));
  out.push("");

  // 5. the bands
  if (structure.bands.length === 0) out.push(line([["  " + labels.sc_no_stories, "dim"]]));
  else renderBands(structure, { glyphs, labels, width, layout, stopOf }).forEach((l) => out.push(line(l)));
  out.push("");

  // 6. ready to take, and one "unlocked by" line per locked node
  const titleOf = new Map();
  graph.tasks.forEach((t) => titleOf.set(t.id, t.title));
  const nameOf = (id) => listName(titleOf.get(id), id, glyphs);
  const sep = [[` ${glyphs.sep} `, "dim"]];
  if (structure.ready.length === 0) out.push(line([[labels.nothing_ready, "dim"]]));
  else {
    const items = structure.ready.map((r) => [[listName(r.title, r.id, glyphs), "bold+ready"]]);
    wrapItems([[`${labels.ready_to_take}: `, "dim"]], items, sep, width, "  ").forEach((l) => out.push(line(l)));
  }
  graph.tasks
    .filter((t) => t.state === "locked")
    .forEach((t) => {
      const waits = (t.blocked_by && t.blocked_by.length > 0 ? t.blocked_by : t.depends_on || []).map(nameOf).join(" + ");
      out.push(line([[fillUnlockedBy(labels.unlocked_by, nameOf(t.id), waits), "dim"]]));
    });
  // 7. one line per done task whose dependency is not done (E92_S11_T02): its "?" mark, its name and the words naming the
  // dependency, in the in-progress colour. Only for a payload that states unfinished_deps; none otherwise.
  structure.tasks
    .filter((t) => Array.isArray(t.unfinishedDeps) && t.unfinishedDeps.length > 0)
    .forEach((t) => {
      const text = unfinishedDepText(labels, t.unfinishedDeps);
      if (text) out.push(line([[`${glyphs.unfinished} ${nameOf(t.id)}: ${text}`, "in_progress"]]));
    });

  const text = out.join("\n");
  return { out: opts.charset === "ascii" ? toAscii(text) : text };
}

/** `scope <id> [--layout horizontal|vertical|auto]` */
export function scopeCommand(ctx) {
  if (ctx.positionals.length !== 1) return { usage: ctx.positionals.length === 0 ? "scope needs an epic or story id" : "scope takes one id" };
  const id = normaliseScopeId(ctx.positionals[0]);
  if (id.usage) return { usage: id.usage };
  const data = ctx.readData(["--graph", "--within", id.id]);
  if (!data.ok) return { warning: data.warning };
  const lab = ctx.labels();
  if (!lab.ok) return { warning: lab.warning };
  return renderScope(data.data, {
    glyphs: ctx.glyphs,
    painter: ctx.painter,
    labels: lab.labels,
    width: ctx.settings.width.value,
    layout: ctx.flags.layout || "auto",
    charset: ctx.settings.charset.value,
    id: id.id,
  });
}
