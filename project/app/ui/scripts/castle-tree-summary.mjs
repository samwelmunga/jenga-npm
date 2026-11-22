// E92_S13_T06: the one function that turns a --graph payload into the facts the castle and the seasons tree are recorded by in
// tests/fixtures/progress/dependency-tree-parity.json (key `castleTree`). Used by dependency-structure-parity.test.cjs (to compare)
// and by record-castle-tree-parity.mjs (to record), so the two cannot drift apart. It reads what the dashboard model builds
// (dependencyTreeModel.js: model.castle.source is the castle model, model.castle.tree the seasons tree layout) and keeps STRUCTURE only:
// what stands on what, which layers and clumps exist in which state, the stage, the surroundings thresholds. No pixel number is recorded,
// so a layout tweak that moves things does not break the recording, while a change of what is drawn does.
import { buildDependencyTreeModel } from '../src/components/progress/dependencyTreeModel.js'

const countBy = (items, key) => {
  const out = {}
  for (const it of items) out[key(it)] = (out[key(it)] || 0) + 1
  return out
}

export function summariseCastleAndTree(graph, epicId) {
  const model = buildDependencyTreeModel(graph, epicId, undefined)
  if (model.empty || !model.castle) return { empty: true }
  const src = model.castle.source
  const tree = model.castle.tree
  return {
    // castle (citadel and facade draw this one object)
    castle: {
      order: src.order,
      trunk: src.trunk,
      levels: src.levels,
      wall: src.wall,
      towers: src.towers.map(t => ({
        id: t.storyId,
        stacking: t.stacking,
        top: t.top,
        status: t.status,
        lean: t.lean,
        undecomposed: t.undecomposed,
        finished: t.finished,
        leaf: t.leaf,
        cycle: t.cycle,
        level: t.level,
        plan: t.plan,
        layers: t.layers.map(l => `${l.direction}:${l.blocks}:${l.state}`),
        loose: t.loose,
      })),
      bridges: src.bridges,
    },
    // seasons tree (per-story data of the model, then the layout's structural output)
    tree: {
      stories: src.stories.map(s => ({ id: s.storyId, tree: s.tree, dependsOn: s.dependsOn, redundantDeps: s.redundantDeps, externalDeps: s.externalDeps })),
      growth: { percent: tree.growth.percent, stage: tree.growth.stage, reached: tree.growth.reached, effects: tree.growth.effects },
      stages: tree.stages.map(s => `${s.id}:${s.percent}`),
      trunkStory: tree.trunk.storyId,
      branches: tree.branches.map(b => ({ id: b.storyId, parent: b.parent, depth: b.depth, snow: b.snow, droops: b.droops, undecomposed: b.undecomposed })),
      clumps: countBy(tree.clumps, c => `${c.storyId}:${c.state}`),
      stubs: tree.stubs.map(s => s.storyId),
      vines: tree.vines.map(v => v.storyId),
      labels: tree.labels.map(l => `${l.storyId}|${l.text}`),
      stonesLifted: tree.surroundings.stones.filter(s => s.lifted).map(s => s.at),
      mushrooms: tree.surroundings.mushrooms.length > 0,
      effects: { active: tree.effects.active, swing: !!tree.effects.swing, spirits: tree.effects.spirits.length, petals: tree.effects.petals.length > 0 },
    },
  }
}
