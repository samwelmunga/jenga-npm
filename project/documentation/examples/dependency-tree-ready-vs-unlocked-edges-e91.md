# Dependency tree: ready edge vs solid green edge vs open padlock on a locked task (E91)

Context: the Progress dependency tree (`project/app/ui/src/components/progress/`), looking at E91.

## What it is

Each task card in the tree has a **state** (`done`, `in_progress`, `ready`, `locked`, ...) and an **open/closed padlock** gate. Each edge is coloured from the state of the *dependent* (the task on the right). The state is decided by `scripts/board-progress.sh --graph`; the UI only draws it (`DependencyTree.jsx`, `dependency-tree.css`).

## Why it exists

To show at a glance what you can start now (ready) versus what is merely waiting (locked), without recomputing dependency rules in the UI.

## How it works

| Piece | Rule | Source |
|---|---|---|
| `ready` | task is Pending AND every id in its own `depends_on` AND its **story's** `depends_on` is done/rejected | `board-progress.sh` header, lines 35-39, 690-694 |
| `locked` | Pending with at least one unsatisfied id (own or story) | same |
| edge colour | by the dependent's state: `ready` -> `dt-edge-ready`; `done` -> done; locked dependent -> green if the dependency is done, else grey | `edgeState()` in `DependencyTree.jsx` |
| `dt-edge-ready` | grey, dashed `6 6`, animated flow (`dt-flow`) | `dependency-tree.css:47, 133` |
| ready card | dashed border, pulsing ring (`dt-ring-pulse`), plus mark | `dependency-tree.css:63, 83, 134` |
| padlock gate | `open` when the task's **own** `depends_on` are all done, else `locked` (does NOT look at the story's `depends_on`) | `dependency-structure.js:207` |
| dotted edge | `dt-edge-cross`: the two ends are in different stories | `dependency-tree.css:51` |

## Example 1: E91_S01_T01 -> E91_S01_T02 (grey flowing line, dashed pulsing card, plus)

T02 was Pending, `depends_on: [E91_S01_T01]` (done), and its story E91_S01 has no blocking story dependency. So state = `ready`. That gives the grey dashed flowing edge, the dashed pulsing border and the plus.

## Example 2: E91_S04_T01 -> E91_S04_T03 (plain solid green line)

The edge is solid green because T03's own dependency (T01) is done, and T03 is not `ready`, so it falls to the last rule: locked dependent + done dependency = green. Solid because both ends are in S04 (same story).

## Example 3: why E91_S04_T02 and E91_S04_T03 get no pulsing border or plus

Both have open green padlocks, which suggests "unlocked", but their state is `locked`, with `blocked_by: ["E91_S03"]`. Story E91_S04 declares `depends_on: [E91_S03]`, and E91_S03 is still Pending. Readiness counts the story's dependency; the padlock does not. So:

- the padlock reads "my own task dependencies are done" (open),
- the card state reads "the story I belong to is still waiting on E91_S03" (locked, so no ring, no plus, and no flowing grey edge).

T02's green dotted line from E91_S01_T01 is the same case: dependency done, dependent locked (green), crossing stories (dotted).

## Note on the screenshot

The screenshot predates the tester verdict on E91_S01_T02, which is now `Merged` (done). Current `--graph --within E91` output: `ready: ["E91_S01_T03"]`, so the pulse and plus have moved to T03.

## When this matters

If the open padlock on a story-blocked task is confusing, the fix is to make the gate in `lib/progress/dependency-structure.js` (line 207) also account for the story's `depends_on`. This was not changed.
