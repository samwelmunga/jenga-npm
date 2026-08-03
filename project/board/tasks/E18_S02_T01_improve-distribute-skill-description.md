---
id: E18_S02_T01
story_id: E18_S02
epic_id: E18
title: Improve /distribute skill description across SKILL.md and wiki
status: Passed
date_created: 2026-07-10
date_started:
date_completed: 2026-07-10
---

# Task: Improve /distribute skill description across SKILL.md and wiki

## Description

The `/distribute` skill is currently undiscoverable to new users because its descriptions across SKILL.md, `project/.wiki/documentation.md`, and the intro guide treat it as a power-user command rather than explaining the underlying mental model, when to reach for it, or how to configure it.

This task rewrites those surfaces so a first-time user understands what `/distribute` is, when to use it, and how to set it up.

## Files to Edit

1. `.agents/skills/distribute/SKILL.md` — improve the frontmatter `description` field
2. `project/.wiki/documentation.md` — expand the `/distribute` entry with concept, setup, and when-to-use guidance

## Acceptance Criteria

- [ ] `SKILL.md` frontmatter `description` is rewritten to be concept-first: explains the distributed-workflow model in plain language before mentioning implementation details
- [ ] `documentation.md` `/distribute` entry includes a **"What it is"** paragraph explaining the distributed-workflow mental model (single master workflow repo → N consumer projects, versioned snapshots)
- [ ] `documentation.md` `/distribute` entry includes a **"Setup"** section covering: (1) create `.jenga_paths` with one absolute path per line pointing to project directories, (2) each consumer project needs a `jenga.config.json` with `target_dir` and `workflow_version`, (3) optionally create `.jenga_ignore` per consumer to exclude files — and references `.jenga_paths.example`
- [ ] `documentation.md` `/distribute` entry includes clear **"When to use"** guidance distinguishing `amend` (quietly onboard new projects or fix missed files, no version bump) from `patch/minor/major` (broadcast versioned upgrade to all registered consumers)
- [ ] All existing content about release types and the example output trace is preserved
- [ ] No broken links introduced

## Reference

Evaluation rapport: `project/rapports/analysis/improve-distribute-skill-description-eval.md`
