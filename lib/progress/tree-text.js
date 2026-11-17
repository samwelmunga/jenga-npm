/**
 * lib/progress/tree-text.js - the terminal layout of the shared dependency structure (E92_S08_T05)
 *
 * lib/progress/dependency-structure.js decides WHAT the tree is (depth columns, bands, gate and mark per task, folded
 * groups, the edges). This file decides how it is drawn in character cells; it counts nothing, derives no state and holds
 * no user-visible word (the words it prints come in through `labels`, the glyphs through `glyphs`).
 *
 * A line is a list of segments [text, style]; a style is "" or one or more of the names below joined with "+":
 *   bold, dim, a colour name of color.js (done, ready, in_progress, failed, pending, rejected, locked), or gNNN, a raw
 *   256-colour index (the gradient of the milestone line). Width is measured on the plain text (width.js), so a line is
 *   clipped before it is painted and no painted line is ever wider than the width.
 *
 * Every arrow is an edge (E92_S10_T03): an arrow is drawn before a node only from its drawn parent, a node of the same
 * band in the column directly to its left with a dependency edge to it; every other incoming edge is a reference after
 * the name (`back shaft ids`); see "the bands" below for the full rule.
 *
 * Layouts (E92_S08 Decisions 1): `horizontal`, `vertical` or `auto` (default).
 *   horizontal  the band's drawn-parent forest walked depth first: a first child continues its parent's row, every
 *               further child opens a row below, joined by a fork; one column per depth column. A column is ARROW_W cells
 *               of arrow, the mark, a space and a name of NAME_W cells (the design width: three columns fit 80 columns, a
 *               fifth overflows, as the last row of the design image does), plus, in a band column that carries a
 *               reference, the widest reference of that column. A longer title ends in the ellipsis glyph. Forced
 *               horizontal shrinks the name width (never below one cell) until every band fits, so the row count never
 *               changes, only the titles get shorter.
 *   vertical    the same forest as an indented tree: one line per node, indented by its depth in the tree, `tee` or
 *               `corner shaft head` before a child, `vert` on the lines between two siblings, the title and the
 *               reference cut to the room left.
 *   auto        a band is drawn vertical ONLY when its longest horizontal row (at NAME_W) is wider than the terminal; every
 *               other band stays horizontal.
 *
 * ESM; Node >= 14.13.1.
 */
import { formatLabel } from "./labels.js";
import { SGR } from "./color.js";
import { displayWidth, truncate } from "./width.js";

export const LAYOUTS = ["horizontal", "vertical", "auto"];
export const ARROW_W = 4;
export const NAME_W = 14;
export const INDENT = 2;
/** Longest a title is shown in a list line (ready, unlocked by). */
export const LIST_NAME_W = 24;

/** True when `value` names a layout. */
export const isLayout = (value) => typeof value === "string" && LAYOUTS.indexOf(value) >= 0;

/** A title as one plain line: control characters become a space. */
export const clean = (text) => String(text === null || text === undefined ? "" : text).replace(/[\u0000-\u001f\u007f]+/g, " ").trim();

// ---------------------------------------------------------------------------
// segments, width, painting
// ---------------------------------------------------------------------------

export const segsWidth = (segs) => segs.reduce((w, s) => w + displayWidth(s[0]), 0);

/** `segs` cut to `width` cells; a cut ends in `ellipsis` (the glyph of the active charset). */
export function clipSegs(segs, width, ellipsis) {
  if (segsWidth(segs) <= width) return segs;
  const mark = Array.from(ellipsis).length;
  const room = Math.max(0, width - mark);
  const out = [];
  let used = 0;
  for (let i = 0; i < segs.length; i++) {
    const chars = Array.from(segs[i][0]);
    if (used + chars.length <= room) {
      out.push(segs[i]);
      used += chars.length;
      continue;
    }
    const take = room - used;
    if (take > 0) out.push([chars.slice(0, take).join(""), segs[i][1]]);
    break;
  }
  out.push([width >= mark ? ellipsis : "", ""]);
  return out;
}

const RAW_COLOUR = /^g([0-9]{1,3})$/;

/** One segment painted: colours first, then bold, then dim. A disabled painter returns the text unchanged. */
export function applyStyle(painter, style, text) {
  if (!style || text === "" || !painter.enabled) return text;
  let out = text;
  let bold = false;
  let dim = false;
  style.split("+").forEach((part) => {
    if (part === "bold") bold = true;
    else if (part === "dim") dim = true;
    else if (RAW_COLOUR.test(part)) out = `\u001b[38;5;${part.slice(1)}m${out}\u001b[0m`;
    else if (Object.prototype.hasOwnProperty.call(SGR, part)) out = painter.paint(part, out);
  });
  if (bold) out = painter.bold(out);
  if (dim) out = painter.dim(out);
  return out;
}

/** A line of segments as a painted string, clipped to `width` first. */
export function renderLine(segs, painter, width, ellipsis) {
  return clipSegs(segs, width, ellipsis)
    .map((s) => applyStyle(painter, s[1], s[0]))
    .join("");
}

/**
 * Greedy wrap of `items` (each a list of segments) after `lead`, joined by `sep` segments; a continuation line starts with
 * the plain text `cont`. Returns lines of segments.
 */
export function wrapItems(lead, items, sep, width, cont) {
  const lines = [];
  let cur = lead.slice();
  let n = 0;
  items.forEach((item) => {
    const add = (n > 0 ? sep : []).concat(item);
    if (n > 0 && segsWidth(cur) + segsWidth(add) > width) {
      lines.push(cur);
      cur = [[cont, ""]].concat(item);
      n = 1;
    } else {
      cur = cur.concat(add);
      n++;
    }
  });
  lines.push(cur);
  return lines;
}

/**
 * Pure ASCII for a whole rendering under --charset ascii: accents are dropped (å becomes a), any other character above
 * 0x7f becomes "?". Escape sequences are ASCII already. Each character stays one cell, so no width changes.
 */
export function toAscii(text) {
  return String(text)
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/[^\u0000-\u007f]/g, "?");
}

// ---------------------------------------------------------------------------
// nodes
// ---------------------------------------------------------------------------

// state -> [glyph name, mark colour, name style]. Every state has its own mark, so colour is never the only difference
// (E92_S11_T01, user decision 2026-11-15): `in_progress` has the half dot ◐ (ascii %), as in the dashboard, not the ready ◉.
const STATE_VIEW = {
  done: ["done", "done", ""],
  ready: ["ready", "ready", "bold+ready"],
  in_progress: ["inProgress", "in_progress", "in_progress"],
  failed: ["cross", "failed", "failed"],
  rejected: ["rejected", "rejected", "rejected"],
};
const LOCKED_VIEW = ["locked", "locked", "dim"];

// A done task whose dependency is not done (the structure's unfinishedDeps, from board-progress.sh's unfinished_deps,
// E92_S11_T02, user decision 2026-11-15) shows "?" in the in-progress colour in place of its own mark, where a ready task
// shows its mark; its name keeps its state's style (it still counts as done). Without the key the node looks as before.
const UNFINISHED_VIEW = ["unfinished", "in_progress"];

/** How a node (a task or a folded group) looks: { mark, markStyle, name, nameStyle } with the name cut to `maxName`. */
export function nodeView(node, labels, glyphs, maxName) {
  const v = Object.prototype.hasOwnProperty.call(STATE_VIEW, node.state) ? STATE_VIEW[node.state] : LOCKED_VIEW;
  const flagged = Array.isArray(node.unfinishedDeps) && node.unfinishedDeps.length > 0;
  const m = flagged ? UNFINISHED_VIEW : v;
  const text = node.kind === "group" ? formatLabel(labels.group_tasks, node.count) : clean(node.title) || node.id;
  return { mark: glyphs[m[0]], markStyle: m[1], name: truncate(text, maxName, glyphs.ellipsis), nameStyle: v[2] };
}

/** The name a list line uses for a task id (its title, cut), else the id itself. */
export function listName(title, id, glyphs) {
  const t = clean(title);
  return t === "" ? id : truncate(t, LIST_NAME_W, glyphs.ellipsis);
}

// ---------------------------------------------------------------------------
// the bands
// ---------------------------------------------------------------------------
//
// Every arrow is an edge (E92_S10_T03, user decision 2026-11-15: "jag skapar en task som ritar om så att varje pil
// motsvarar ett verkligt beroende"). An arrow `▸` before a node is drawn only from its DRAWN PARENT: the first node, in
// band order (column, then slot), of the same band that sits in the column directly to its left and has a `dependency`
// edge to it in structure.edges (a folded group stands for its members, so its edges are theirs). The drawn parents make
// one forest per band; the rows are a depth-first walk of it, so a first child continues its parent's row and every
// further child opens a row below the parent's subtree, joined to the parent by a fork (`─┬─▸`, then ` ├─▸` / ` └─▸`, with
// ` │` on the rows in between). Every other incoming `dependency` or `boundary` edge of a node is a REFERENCE after its
// name, `◂─ T03,S01_T06` (ASCII `<- ...`): ids are written relative to the node (own story: `T03`; another story of the
// epic: `S01_T06`; outside the epic: the full id), and a group source names the members the node depends on. A node with
// a `goal` edge gets `───▸⚑`: a task with one has no dependent in the epic, so it always ends its row; a group with both a
// goal edge and drawn children gets a last branch ` └─▸⚑`.

/** Incoming dependency and boundary edges per node id, the ids with a goal edge, the visible nodes by id, the epic id. */
function edgeIndex(structure) {
  const incoming = new Map();
  const goal = new Set();
  structure.edges.forEach((e) => {
    if (e.kind === "goal") goal.add(e.from);
    else if (e.kind === "dependency" || e.kind === "boundary") {
      if (!incoming.has(e.to)) incoming.set(e.to, []);
      incoming.get(e.to).push(e);
    }
  });
  const nodeById = new Map(structure.nodes.map((n) => [n.id, n]));
  return { incoming, goal, nodeById, epicId: (structure.goal && structure.goal.id) || "" };
}

/** A band as a grid: cols (column -> nodes, top to bottom), the number of rows, the nodes in column order and by id. */
function bandGrid(band) {
  const cols = new Map();
  const nodes = [];
  let rows = 0;
  band.cells.forEach((cell) => {
    const list = cell.slots.filter((s) => s.type === "node").map((s) => s.node);
    cols.set(cell.column, list);
    list.forEach((n) => nodes.push(n));
    rows = Math.max(rows, list.length);
  });
  return { cols, rows, nodes, byId: new Map(nodes.map((n) => [n.id, n])) };
}

const arrowStyle = (node) => (node.gate === "open" ? "done" : "locked");

/** `id` written relative to a node of story `storyId` in epic `epicId`: T03, S01_T06 or the full id. */
export function shortRef(id, storyId, epicId) {
  if (storyId && id.indexOf(`${storyId}_`) === 0) return id.slice(storyId.length + 1);
  if (epicId && id.indexOf(`${epicId}_`) === 0) return id.slice(epicId.length + 1);
  return id;
}

/** The ids a node shows as references: every incoming dependency or boundary edge except the drawn parent's, sorted. */
function referenceIds(node, parentId, idx) {
  const ids = [];
  (idx.incoming.get(node.id) || []).forEach((e) => {
    if (e.from === parentId) return;
    const src = idx.nodeById.get(e.from);
    if (src && src.kind === "group") {
      const deps = new Set(node.dependsOn || []);
      const named = src.members.filter((m) => deps.has(m));
      (named.length > 0 ? named : src.members).forEach((m) => ids.push(m));
    } else ids.push(e.from);
  });
  return Array.from(new Set(ids)).sort();
}

/**
 * The forest of one band: [{ node, kids, refs, goal }] for the roots, in band order. A node's drawn parent is the first
 * band node in column - 1 with a dependency edge to it; columns grow along a parent link, so the forest has no cycle.
 */
function bandTrees(grid, idx, glyphs) {
  const order = new Map(grid.nodes.map((n, i) => [n.id, i]));
  const parentOf = new Map();
  grid.nodes.forEach((n) => {
    const from = (idx.incoming.get(n.id) || [])
      .filter((e) => e.kind === "dependency" && order.has(e.from) && grid.byId.get(e.from).column === n.column - 1)
      .map((e) => e.from)
      .sort((a, b) => order.get(a) - order.get(b));
    if (from.length > 0) parentOf.set(n.id, from[0]);
  });
  const trees = new Map();
  grid.nodes.forEach((n) => {
    const ids = referenceIds(n, parentOf.get(n.id), idx);
    const ref = ids.length > 0 ? `${glyphs.back}${glyphs.shaft} ${ids.map((id) => shortRef(id, n.storyId, idx.epicId)).join(",")}` : "";
    trees.set(n.id, { node: n, kids: [], ref, goal: idx.goal.has(n.id) });
  });
  const roots = [];
  grid.nodes.forEach((n) => {
    const p = parentOf.get(n.id);
    if (p) trees.get(p).kids.push(trees.get(n.id));
    else roots.push(trees.get(n.id));
  });
  return roots;
}

/**
 * The text rows of a forest: [{ items: [{ tree, conn }], pass: [column], goalAt }]. conn is the connector in the arrow
 * cells before the node: null (a root), "straight", "fork" (first of several branches), "tee" or "last"; `pass` lists the
 * columns whose arrow cells carry the vertical of a fork; goalAt is the column of a goal branch (a group's), else -1.
 */
function treeRows(roots) {
  const rows = [];
  const newRow = () => {
    const r = { items: [], pass: [], goalAt: -1 };
    rows.push(r);
    return r;
  };
  const emit = (t, row, conn) => {
    row.items.push({ tree: t, conn });
    const total = t.kids.length + (t.goal && t.kids.length > 0 ? 1 : 0);
    const col = t.node.column + 1;
    let prev = rows.indexOf(row);
    const branch = () => {
      const r = newRow();
      for (let j = prev + 1; j < rows.length - 1; j++) rows[j].pass.push(col);
      prev = rows.length - 1;
      return r;
    };
    t.kids.forEach((k, i) => {
      const more = i < total - 1;
      if (i === 0) emit(k, row, more ? "fork" : "straight");
      else emit(k, branch(), more ? "tee" : "last");
    });
    if (total > t.kids.length) branch().goalAt = col;
  };
  roots.forEach((t) => emit(t, newRow(), null));
  return rows;
}

/** The arrow cells before a node (ARROW_W wide). */
function connector(conn, glyphs, node) {
  const tail = glyphs.shaft.repeat(ARROW_W - 3) + glyphs.head;
  if (conn === "straight") return [glyphs.shaft.repeat(ARROW_W - 1) + glyphs.head, arrowStyle(node)];
  if (conn === "fork") return [glyphs.shaft + glyphs.fork + tail, arrowStyle(node)];
  if (conn === "tee") return [` ${glyphs.tee}${tail}`, arrowStyle(node)];
  if (conn === "last") return [` ${glyphs.corner}${tail}`, arrowStyle(node)];
  return [" ".repeat(ARROW_W), ""];
}

/** Widest reference per column of a band (0 when the column has none). */
function referenceWidths(rows) {
  const w = new Map();
  rows.forEach((r) =>
    r.items.forEach((it) => {
      const c = it.tree.node.column;
      w.set(c, Math.max(w.get(c) || 0, displayWidth(it.tree.ref)));
    })
  );
  return w;
}

function horizontalRows(grid, ctx, nameW) {
  const { glyphs, labels } = ctx;
  const refW = grid.refW;
  // a column that carries a reference is wider by a space, its widest reference and a space before the next arrow
  const extra = (c) => (refW.get(c) > 0 ? 2 + refW.get(c) : 0);
  const pad = (text, w) => text + " ".repeat(Math.max(0, w - displayWidth(text)));
  return grid.layout.map((row) => {
    const at = new Map(row.items.map((it) => [it.tree.node.column, it]));
    const last = row.items.reduce((m, it) => Math.max(m, it.tree.node.column), row.goalAt);
    const segs = [[" ".repeat(INDENT), ""]];
    for (let c = 0; c <= last; c++) {
      if (c === row.goalAt) {
        segs.push([` ${glyphs.corner}${glyphs.shaft.repeat(ARROW_W - 3)}${glyphs.head}`, "locked"], [glyphs.flag, "bold+in_progress"]);
        continue;
      }
      const it = at.get(c);
      if (!it) {
        const w = ARROW_W + 2 + nameW + extra(c);
        if (row.pass.indexOf(c) >= 0) segs.push([` ${glyphs.vert}`, "locked"], [" ".repeat(w - 2), ""]);
        else segs.push([" ".repeat(w), ""]);
        continue;
      }
      const node = it.tree.node;
      const v = nodeView(node, labels, glyphs, nameW);
      const goal = it.tree.goal && it.tree.kids.length === 0;
      const followed = c < last || goal;
      segs.push(connector(it.conn, glyphs, node));
      segs.push([v.mark, v.markStyle], [" ", ""]);
      if (it.tree.ref) {
        segs.push([pad(v.name, nameW), v.nameStyle], [" ", ""], [followed ? pad(it.tree.ref, refW.get(c) + 1) : it.tree.ref, arrowStyle(node)]);
      } else segs.push([followed ? pad(v.name, nameW + extra(c)) : v.name, v.nameStyle]);
      if (goal) segs.push([glyphs.shaft.repeat(ARROW_W - 1) + glyphs.head, "locked"], [glyphs.flag, "bold+in_progress"]);
    }
    return segs;
  });
}

function verticalRows(grid, ctx, width) {
  const { glyphs, labels } = ctx;
  const dmax = Math.max(0, Math.floor((width - INDENT - ARROW_W - 2 - 8) / 2));
  const lead = (depth) => INDENT + 2 * Math.min(depth, dmax);
  const out = [];
  // trail[k] is true when the ancestor at depth k (k >= 1) has a later sibling, so its fork runs on through this line.
  const walk = (t, depth, isLast, trail) => {
    const cells = Array.from(" ".repeat(lead(depth)));
    for (let k = 1; k < depth; k++) if (trail[k] && cells[lead(k)] === " ") cells[lead(k)] = glyphs.vert;
    const segs = [];
    cells.forEach((ch) => {
      const style = ch === " " ? "" : "locked";
      if (segs.length > 0 && segs[segs.length - 1][1] === style) segs[segs.length - 1][0] += ch;
      else segs.push([ch, style]);
    });
    if (segs.length === 0) segs.push(["", ""]);
    const node = t.node;
    const arrow = depth > 0;
    const avail = width - lead(depth) - (arrow ? ARROW_W : 0) - 2 - (t.goal ? 3 : 0);
    if (arrow) segs.push([(isLast ? glyphs.corner : glyphs.tee) + glyphs.shaft + glyphs.head, arrowStyle(node)], [" ", ""]);
    let v = nodeView(node, labels, glyphs, Math.max(1, avail));
    if (t.ref) {
      const full = displayWidth(v.name);
      const nameRoom = Math.max(Math.min(full, 8), Math.min(full, avail - 1 - displayWidth(t.ref)), 1);
      v = nodeView(node, labels, glyphs, nameRoom);
      segs.push([v.mark, v.markStyle], [" ", ""], [v.name, v.nameStyle]);
      segs.push([" ", ""], [truncate(t.ref, Math.max(1, avail - displayWidth(v.name) - 1), glyphs.ellipsis), arrowStyle(node)]);
    } else segs.push([v.mark, v.markStyle], [" ", ""], [v.name, v.nameStyle]);
    if (t.goal) segs.push([" ", ""], [glyphs.arrow, "locked"], [glyphs.flag, "bold+in_progress"]);
    out.push(segs);
    t.kids.forEach((k, i) => walk(k, depth + 1, i === t.kids.length - 1, trail.concat([i < t.kids.length - 1])));
  };
  // trail is indexed by depth: trail[d] belongs to the node at depth d, filled in by its parent's walk
  grid.trees.forEach((t) => walk(t, 0, true, [false]));
  return out;
}

const STOP_STYLE = { done: "done", in_progress: "in_progress", failed: "failed" };

/**
 * The bands of a structure as lines of segments, a blank line between two bands.
 *
 * opts: { glyphs, labels, width, layout, stopOf(storyId) }   stopOf gives the story's `stop` (done, in_progress, ...) for the
 * colour of the band header; it may return undefined.
 */
export function renderBands(structure, opts) {
  const { glyphs, width } = opts;
  const layout = opts.layout || "auto";
  const ctx = { glyphs, labels: opts.labels, idx: edgeIndex(structure) };
  const grids = structure.bands.map((band) => {
    const grid = bandGrid(band);
    grid.trees = bandTrees(grid, ctx.idx, glyphs);
    grid.layout = treeRows(grid.trees);
    grid.refW = referenceWidths(grid.layout);
    return grid;
  });
  const widest = (rows) => rows.reduce((w, r) => Math.max(w, segsWidth(r)), 0);

  let nameW = NAME_W;
  if (layout === "horizontal") {
    while (nameW > 1 && grids.some((g) => widest(horizontalRows(g, ctx, nameW)) > width)) nameW--;
  }

  const lines = [];
  structure.bands.forEach((band, i) => {
    const grid = grids[i];
    const natural = horizontalRows(grid, ctx, NAME_W);
    const vertical = layout === "vertical" || (layout === "auto" && widest(natural) > width);
    const rows = vertical ? verticalRows(grid, ctx, width) : layout === "horizontal" ? horizontalRows(grid, ctx, nameW) : natural;

    const start = band.start;
    const count = ` ${start.done}/${start.total}`;
    const title = truncate((clean(start.title) || start.storyId).toUpperCase(), Math.max(1, width - count.length - 1), glyphs.ellipsis);
    const stop = opts.stopOf ? opts.stopOf(band.storyId) : undefined;
    if (i > 0) lines.push([]);
    lines.push([[title, `bold+${STOP_STYLE[stop] || "pending"}`], [count, "dim"]]);
    rows.forEach((r) => lines.push(r));
  });
  return lines;
}
