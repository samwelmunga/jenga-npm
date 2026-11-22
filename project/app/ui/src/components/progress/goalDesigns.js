/**
 * goalDesigns — E92_S13_T05. The renderer registry of the goal designs: a map from a design id of GOAL_DESIGNS
 * (goalDesignModel.js, the one ordered list) to its renderer. The renderer contract is documented in StarGoal.jsx.
 *
 * A design is REGISTERED by one line here. Until then it is absent from the selector and cannot be chosen:
 *   star     E92_S13_T05 (this task): the existing Goal node, a star in a disc with a progress ring
 *   citadel  E92_S13_T02: the isometric Jenga castle, registered here; it is the default (DEFAULT_GOAL_DESIGN)
 *   facade   E92_S13_T03: the flat facade of the same castle model, registered here
 *   tree     E92_S13_T07: the seasons tree, registered here
 * An id that is not in GOAL_DESIGNS is ignored, whatever is registered under it.
 */
import CitadelGoal from './CitadelGoal'
import FacadeGoal from './FacadeGoal'
import StarGoal from './StarGoal'
import SeasonsTree from './seasonsTreeEntry'

// E92_S13_T09: the seasons tree is registered only when it was built in (JENGA_UI_SEASONS_TREE=1, see
// seasonsTreeEntry.js and vite.config.js). In a normal build SeasonsTree is null and the design is absent.
export const GOAL_RENDERERS = Object.freeze({
  star: StarGoal,
  citadel: CitadelGoal,
  facade: FacadeGoal,
  ...(SeasonsTree ? { tree: SeasonsTree } : {}),
})
