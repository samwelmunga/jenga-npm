---
id: E25_S02_T02
story_id: E25_S02
epic_id: E25
title: Board artifact node extraction — Epic, Story, Task
status: Passed
date_created: 2026-07-23
date_started: 2026-07-23
date_completed: 2026-07-23
dates_previously_completed:
reopened_on:
reopened_reason:
---

# Task: Board artifact node extraction — Epic, Story, Task

## Description

Implement node extraction for the three core board artifact types by walking `project/board/{epics,stories,tasks}/*.md` and parsing YAML frontmatter.

**Epic node** fields: `id`, `type="Epic"`, `title`, `status`, `path`, `date_created`, `date_started`, `date_completed`, `stories` (list of story IDs)

**Story node** fields: `id`, `type="Story"`, `title`, `status`, `path`, `epic_id`, `date_created`, `date_started`, `date_completed`, `tasks` (list of task IDs)

**Task node** fields: `id`, `type="Task"`, `title`, `status`, `path`, `story_id`, `epic_id`, `date_created`, `date_started`, `date_completed`

Optional frontmatter keys (`mentions_skills`, `mentions_agents`, `depends_on`) should be parsed if present — stored on the node for use in T04 edge derivation. Missing keys must never raise an error.

Also derive the `contains` edge for each Epic→Story and Story→Task relationship (from the `stories:` and `tasks:` frontmatter lists).

**Degradation rule**: if a frontmatter key is missing, use `None`/`null`; if YAML parsing fails for a file, log a warning to stderr and skip that file.

**Note**: use Python's `re` + string slicing to extract YAML frontmatter (the `---` block at the top), not an external YAML library, unless `pyyaml` is confirmed available in the environment.

## Acceptance Criteria
- [ ] `board-index graph::nodes --type Epic` returns all epics with correct fields
- [ ] `board-index graph::nodes --type Story` returns all stories
- [ ] `board-index graph::nodes --type Task` returns all tasks
- [ ] `board-index graph::edges --type contains` returns Epic→Story and Story→Task edges
- [ ] Missing optional frontmatter keys produce no error (empty list / null values)
- [ ] Unparseable frontmatter files are skipped with a stderr warning
- [ ] Node count for Epic/Story/Task matches real-board measurement counts (±10%): ~25 epics, ~102 stories, ~172 tasks

## Definition of Done
- [ ] Epic, Story, Task nodes extracted with all required fields
- [ ] `contains` edges derived
- [ ] Tolerant of missing/malformed frontmatter
