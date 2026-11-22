/**
 * seasonsTreeEntry — the one import of the seasons tree (TreeGoal.jsx, with its stylesheet) by the rest of the app.
 *
 * The seasons tree is not part of the public build while it is being refined (user decision 2026-11-18, task
 * E92_S13_T09). goalDesigns.js imports it only through this file, and vite.config.js points this specifier at
 * seasonsTreeEntry.off.js unless JENGA_UI_SEASONS_TREE=1 is set for the build or the dev server. A normal build
 * (the package's prepack, `--snapshot`) therefore carries neither the renderer nor seasons-tree.css, and the tree
 * is absent from the goal design selector.
 *
 * Outside Vite (the Node UI tests bundle the real files with esbuild) this file is what resolves, so the tests
 * still exercise the tree.
 */
export { default } from './TreeGoal'
