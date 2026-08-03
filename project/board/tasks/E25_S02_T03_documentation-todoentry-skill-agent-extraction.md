---
id: E25_S02_T03
story_id: E25_S02
epic_id: E25
title: Documentation, TodoEntry, Skill, and Agent node extraction
status: Passed
date_created: 2026-07-23
date_started: 2026-07-23
date_completed: 2026-07-23
dates_previously_completed:
reopened_on:
reopened_reason:
---

# Task: Documentation, TodoEntry, Skill, and Agent node extraction

## Description

Implement node extraction for the remaining five node types: `Plan`, `Summary`, `Doc`, `TodoEntry`, `Skill`, `Agent`.

### Plan nodes
Walk `project/documentation/plans/*.md`. Parse frontmatter. Fields: `id` (filename stem), `type="Plan"`, `path`, `title` (from frontmatter or filename), `story_id`/`task_id` (infer from filename pattern `E##_S##[_T##]-plan.md`).

### Summary nodes
Walk `project/documentation/summaries/*.md`. Same as Plan but `type="Summary"`, infer from `E##_S##[_T##]-summary.md`.

### Doc nodes
Walk `project/documentation/examples/*.md` and any loose `.md` files in `project/documentation/` not covered by plans/summaries. Fields: `id`, `type="Doc"`, `path`, `parent_doc` (from frontmatter, optional).

### TodoEntry nodes
Parse `project/todo.md` line by line:
- Skip blank lines and HTML comment blocks (`<!-- ... -->`)
- For each non-comment, non-blank line, extract the `board_ref` by matching pattern `E\d+_S\d+(_T\d+)?` at end of line
- Node `id` = the board_ref if present, else SHA-256 hex of normalised line content (strip leading/trailing whitespace, collapse internal whitespace to single space)
- Fields: `type="TodoEntry"`, `text` (full line content), `board_ref` (or null)

### Skill nodes
Walk `.agents/skills/*/SKILL.md` (and `skills/*/SKILL.md` in root). Fields: `id` (directory name), `type="Skill"`, `path`, `description` (first non-empty line after frontmatter `description:` key, or first non-frontmatter paragraph, or empty string).

### Agent nodes
Walk `.agents/*.md` (and `agents/*.md` in root). Fields: `id` (filename stem), `type="Agent"`, `path`, `description` (first non-empty line of file body, or empty string).

Also derive:
- `plans` edges: Plan → target Story or Task (from filename inference)
- `summarizes` edges: Summary → target Story or Task (from filename inference)
- `queued_as` edges: TodoEntry → Story/Task (from `board_ref`)

## Acceptance Criteria
- [ ] `board-index graph::nodes --type Plan` returns all plan docs
- [ ] `board-index graph::nodes --type Summary` returns all summary docs
- [ ] `board-index graph::nodes --type TodoEntry` returns one node per non-blank, non-comment line in todo.md
- [ ] `board-index graph::nodes --type Skill` returns one node per skill with id, path, and description
- [ ] `board-index graph::nodes --type Agent` returns one node per agent with id, path, and description
- [ ] `board-index graph::edges --type plans` returns Plan→target edges
- [ ] `board-index graph::edges --type summarizes` returns Summary→target edges
- [ ] `board-index graph::edges --type queued_as` returns TodoEntry→board-item edges
- [ ] TodoEntry without a board_ref uses SHA-256 of normalised content as id (not null)
- [ ] All extractions tolerate missing files gracefully (empty directory returns `[]`)

## Definition of Done
- [ ] All five remaining node types extracted
- [ ] `plans`, `summarizes`, `queued_as` edges derived
- [ ] TodoEntry identity rule implemented (board_ref or SHA-256 fallback)
- [ ] Skill/Agent nodes include description field
