# Evaluation Rapport: instructions-dedicated-location

## Goal
`_INSTRUCTIONS.md` files should be stored in a dedicated location that contains only instructions, separate from the task board files.

## References
- `agents/developer.md` (Task Intake step 5, Secrets Management section)
- `.agents/skills/do/SKILL.md` (Step 7 — post-completion check)
- `.agents/skills/commit/SKILL.md` (Step 1 — prerequisite verification)

---

## Observations

### `agents/developer.md`
The developer is instructed to write `_INSTRUCTIONS.md` files to `project/board/tasks/<E##_S##_T##>_INSTRUCTIONS.md`. This places user-facing prerequisite instructions directly inside the board's task directory — a directory whose primary purpose is tracking work items (task status, acceptance criteria, story linkage). Instructions files serve a completely different audience and purpose: they are consumed by the human user, not the agents. Co-locating them with task files creates an implicit coupling between the board schema and the instructions delivery mechanism. Any reader of `project/board/tasks/` must now distinguish between board-schema files and user-action files by filename pattern alone.

### `.agents/skills/do/SKILL.md`
Step 7 scans `project/board/tasks/` for `_INSTRUCTIONS.md` files matching a task ID. The `/do` skill must reach into the board directory — which it otherwise treats as read-only input — to surface user-facing content. This is a layer violation: the execution skill is querying what is logically a "user instructions registry" from inside the authoritative scrum board store.

### `.agents/skills/commit/SKILL.md`
Step 1 checks `project/board/tasks/<E##_S##_T##>_INSTRUCTIONS.md` before committing. Same structural problem: the commit skill's prerequisite check depends on a path that lives inside the board directory, not in a location dedicated to prerequisite/instruction tracking.

---

## Gaps & Issues

- **Mixed concerns in `project/board/tasks/`** — The tasks directory conflates two distinct types of files: board items (scrum schema files) and user instructions (human-readable action checklists). These have different consumers (agents vs. users), different lifecycles, and different ownership.
- **No single source of truth for instructions** — There is no dedicated registry or directory for instructions files. Their existence must be inferred by scanning `project/board/tasks/` using a filename convention (`_INSTRUCTIONS.md` suffix).
- **Fragile discovery** — Both `/do` and `/commit` find instructions by scanning a directory that was not designed to hold them. If the naming convention changes or a file is misnamed, instructions go silently undetected.
- **No instructions index** — There is no manifest or index of outstanding instructions. The only way to know what user actions are pending is to glob `project/board/tasks/*_INSTRUCTIONS.md`.
- **Path inconsistency risk** — If the board path in `workflow.json` changes, instructions files move with it, even though their purpose is independent of the board structure.

---

## Score
**Score**: 2/5
**Justification**: Instructions files are functional but structurally misplaced — they live inside a directory that serves a different purpose, discovered by filename convention rather than by a dedicated location, and coupled to the board path without reason.

---

## Summary
`_INSTRUCTIONS.md` files are currently embedded in `project/board/tasks/`, a directory whose purpose is scrum board state management. This creates a layer violation: user-facing prerequisite instructions are mixed with agent-facing work items. A dedicated `project/instructions/` directory (or `project/board/instructions/`) would give instructions files a first-class home, simplify discovery, and decouple the instructions lifecycle from the board schema. All three touch-points — the developer agent, `/do`, and `/commit` — reference the same co-located path and would need updating.
