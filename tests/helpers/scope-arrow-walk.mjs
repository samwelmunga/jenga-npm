// tests/helpers/scope-arrow-walk.mjs - read the arrows, references and goal arrows back out of a rendered scope-view band
// and check them against the shared structure's edges (E92_S10_T03).
//
// The rule under test (user decision 2026-11-15: every arrow is a real dependency, no in-scope dependency is invisible):
//   1. every arrow drawn before a node comes from a node that has a `dependency` edge to it in structure.edges;
//   2. every incoming `dependency` or `boundary` edge of a node is shown, as that arrow or as a reference after the name;
//   3. a reference names only real dependencies of the node;
//   4. the goal arrow is drawn after exactly the nodes that have a `goal` edge.
//
// The walker reads plain text (no colour), one band at a time, in the layout and charset it is told. It finds a node by
// `<mark> <name>`, where `names` maps every name the band draws to its node id, so the fixtures use short unique titles.
//   horizontal  the arrow cells are the ARROW_W (4) cells before the mark: `───▸` or `─┬─▸` take the node to the left
//               on the same row as the parent; ` ├─▸` / ` └─▸` walk up the fork's vertical to the `┬` and take the node
//               left of it. `───▸⚑` belongs to the node to its left, ` └─▸⚑` to the fork's node.
//   vertical    `├─▸ ` / `└─▸ ` right before the mark; the parent is the nearest line above whose node starts two cells
//               to the left (its connector, or its mark for a root). ` →⚑` at the end of the line is the goal arrow.
// A reference is `◂─ <ids>` (ASCII `<- <ids>`) and belongs to the node to its left.
//
// Node >= 14.13.1, no dependency.

const ARROW_W = 4;
const reEscape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/**
 * The node marks of a band row: [{ id, at (index of the mark), end (index after the name) }], left to right. Every state
 * mark of the tree counts, including the in-progress half dot (glyphs.inProgress, E92_S11_T01: in progress no longer
 * shares the ready mark) and the "?" of a done task whose dependency is not done (glyphs.unfinished, E92_S11_T02).
 */
function nodesIn(line, names, glyphs) {
  const marks = [glyphs.done, glyphs.ready, glyphs.inProgress, glyphs.unfinished, glyphs.locked, glyphs.cross, glyphs.rejected].map(reEscape).join("|");
  const found = [];
  names.forEach((id, name) => {
    const re = new RegExp(`(${marks}) ${reEscape(name)}(?= |$)`, "g");
    let m;
    while ((m = re.exec(line)) !== null) found.push({ id, at: m.index, end: m.index + m[0].length });
  });
  return found.sort((a, b) => a.at - b.at);
}

/** References `back shaft ids` on a row: [{ at, ids }]. */
function refsIn(line, glyphs) {
  const re = new RegExp(`${reEscape(glyphs.back + glyphs.shaft)} ([A-Za-z0-9_,]+)`, "g");
  const out = [];
  let m;
  while ((m = re.exec(line)) !== null) out.push({ at: m.index, ids: m[1].split(",") });
  return out;
}

const chars = (line) => Array.from(line);

/**
 * Walk one band. rows: the band's text rows (below its header), plain. Returns
 * { nodes: [id], arrows: [{ from, to }], refs: { id: [short id] }, goals: [id] }; throws on an arrow it cannot read.
 */
export function walkBand(rows, layout, glyphs, names) {
  const nodes = [];
  const arrows = [];
  const refs = {};
  const goals = [];
  const cells = rows.map(chars);
  const perRow = rows.map((l) => nodesIn(l, names, glyphs));
  // the indexes above are UTF-16 offsets; the glyphs used here are all in the BMP, so they equal cell positions
  const leftOf = (r, x) => perRow[r].filter((n) => n.at < x).pop();
  const addRefs = (r) =>
    refsIn(rows[r], glyphs).forEach((ref) => {
      const owner = leftOf(r, ref.at);
      if (!owner) throw new Error(`a reference with no node to its left: ${rows[r]}`);
      refs[owner.id] = (refs[owner.id] || []).concat(ref.ids);
    });

  if (layout === "horizontal") {
    const shaft = glyphs.shaft;
    const forkOwner = (r, x) => {
      for (let u = r - 1; u >= 0; u--) {
        const ch = cells[u][x];
        if (ch === glyphs.fork && cells[u][x - 1] === shaft) {
          const owner = leftOf(u, x - 1);
          if (!owner) throw new Error(`a fork with no node to its left: ${rows[u]}`);
          return owner;
        }
        if (ch !== glyphs.vert && ch !== glyphs.tee) throw new Error(`a branch at row ${r} cell ${x} does not reach a fork:\n${rows.join("\n")}`);
      }
      throw new Error(`a branch at row ${r} has no fork above it`);
    };
    perRow.forEach((list, r) => {
      list.forEach((n) => {
        nodes.push(n.id);
        const region = cells[r].slice(n.at - ARROW_W, n.at).join("");
        if (region.trim() === "") return;
        const head = region[3] === glyphs.head;
        let parent;
        if (head && region[0] === shaft && region[2] === shaft && (region[1] === shaft || region[1] === glyphs.fork)) parent = leftOf(r, n.at - ARROW_W);
        else if (head && region[0] === " " && (region[1] === glyphs.tee || region[1] === glyphs.corner) && region[2] === shaft) parent = forkOwner(r, n.at - ARROW_W + 1);
        else throw new Error(`unreadable arrow cells ${JSON.stringify(region)} before ${n.id}: ${rows[r]}`);
        if (!parent) throw new Error(`an arrow with no node to its left before ${n.id}: ${rows[r]}`);
        arrows.push({ from: parent.id, to: n.id });
      });
      addRefs(r);
      const straightGoal = shaft.repeat(ARROW_W - 1) + glyphs.head + glyphs.flag;
      const branchGoal = ` ${glyphs.corner}${shaft.repeat(ARROW_W - 3)}${glyphs.head}${glyphs.flag}`;
      let at = rows[r].indexOf(straightGoal);
      while (at >= 0) {
        const owner = leftOf(r, at);
        if (!owner) throw new Error(`a goal arrow with no node to its left: ${rows[r]}`);
        goals.push(owner.id);
        at = rows[r].indexOf(straightGoal, at + 1);
      }
      at = rows[r].indexOf(branchGoal);
      if (at >= 0 && list.every((n) => n.at > at)) goals.push(forkOwner(r, at + 1).id);
    });
  } else {
    const starts = [];
    perRow.forEach((list, r) => {
      if (list.length !== 1) throw new Error(`a vertical line holds ${list.length} nodes: ${rows[r]}`);
      const n = list[0];
      nodes.push(n.id);
      const c = cells[r];
      const conn = c[n.at - 4];
      const isChild = n.at >= 4 && (conn === glyphs.tee || conn === glyphs.corner) && c[n.at - 3] === glyphs.shaft && c[n.at - 2] === glyphs.head && c[n.at - 1] === " ";
      const start = isChild ? n.at - 4 : n.at;
      if (isChild) {
        let u = r - 1;
        while (u >= 0 && starts[u] !== start - 2) u--;
        if (u < 0) throw new Error(`no parent line above ${n.id}:\n${rows.join("\n")}`);
        arrows.push({ from: perRow[u][0].id, to: n.id });
      } else if (rows[r].slice(0, n.at).trim() !== "") throw new Error(`unreadable cells before ${n.id}: ${rows[r]}`);
      starts.push(start);
      addRefs(r);
      if (rows[r].endsWith(` ${glyphs.arrow}${glyphs.flag}`)) goals.push(n.id);
    });
  }
  return { nodes, arrows, refs, goals };
}

/** A short reference id back to the full id, relative to the node it is drawn after. */
export function fullRef(short, storyId, epicId) {
  if (/^T[0-9]+$/.test(short)) return `${storyId}_${short}`;
  if (/^S[0-9]+(_T[0-9]+)?$/.test(short)) return `${epicId}_${short}`;
  return short;
}

/**
 * Check a walked band against the structure; returns a list of problems (empty when the rule holds). `band` is the
 * structure band the rows were drawn from.
 */
export function checkBand(walk, structure, band) {
  const problems = [];
  const epicId = structure.goal.id;
  const visible = new Map(structure.nodes.map((n) => [n.id, n]));
  const visibleOf = new Map();
  structure.nodes.forEach((n) => (n.kind === "group" ? n.members : [n.id]).forEach((id) => visibleOf.set(id, n.id)));
  const bandIds = [];
  band.cells.forEach((cell) => cell.slots.forEach((s) => s.type === "node" && bandIds.push(s.node.id)));
  const edge = (from, to, kinds) => structure.edges.some((e) => e.from === from && e.to === to && kinds.indexOf(e.kind) >= 0);

  if (walk.nodes.slice().sort().join() !== bandIds.slice().sort().join()) problems.push(`drawn nodes ${walk.nodes} are not the band's ${bandIds}`);
  walk.arrows.forEach((a) => {
    if (!edge(a.from, a.to, ["dependency"])) problems.push(`arrow ${a.from} -> ${a.to} is not a dependency edge`);
  });
  bandIds.forEach((id) => {
    const node = visible.get(id);
    const expected = structure.edges.filter((e) => e.to === id && (e.kind === "dependency" || e.kind === "boundary")).map((e) => e.from);
    const shown = walk.arrows.filter((a) => a.to === id).map((a) => a.from);
    if (shown.length > 1) problems.push(`${id} has ${shown.length} arrows`);
    (walk.refs[id] || []).forEach((short) => {
      const full = fullRef(short, node.storyId, epicId);
      if ((node.dependsOn || []).indexOf(full) < 0) problems.push(`${id} references ${full}, which it does not depend on`);
      shown.push(visibleOf.has(full) ? visibleOf.get(full) : full);
    });
    const a = Array.from(new Set(expected)).sort().join();
    const b = Array.from(new Set(shown)).sort().join();
    if (a !== b) problems.push(`${id}: incoming edges [${a}] but shown [${b}]`);
    const goal = structure.edges.some((e) => e.from === id && e.kind === "goal");
    const drawn = walk.goals.filter((g) => g === id).length;
    if (drawn !== (goal ? 1 : 0)) problems.push(`${id}: goal edge ${goal}, goal arrows drawn ${drawn}`);
  });
  return problems;
}
