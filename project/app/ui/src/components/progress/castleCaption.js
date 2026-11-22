/**
 * castleCaption - E92_S13_T03. The words of one tower, shared by the two castle designs (the citadel and the facade), so a
 * tower has the same aria label and tooltip in both. `label(key)` gives the payload's word (en or sv, with the English
 * fallback of DependencyTree.jsx) and `fill(template, ...args)` fills its placeholders. Every figure (done, total, failed) is
 * the payload's, carried on the tower as `facts`; nothing is counted here.
 */
export function towerCaption(t, label, fill) {
  const fx = t.facts
  const name = `${t.storyId}${t.title ? ' ' + t.title : ''}`
  if (t.undecomposed) return fill(label('castle_tower_undecomposed'), name)
  if (!fx) return name
  return fx.failed > 0 ? fill(label('castle_tower_failed'), t.storyId, fx.done, fx.total, fx.failed) : fill(label('castle_tower'), t.storyId, fx.done, fx.total)
}
