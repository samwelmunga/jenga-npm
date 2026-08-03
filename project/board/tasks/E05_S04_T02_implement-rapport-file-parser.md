---
id: E05_S04_T02
story_id: E05_S04
epic_id: E05
title: Implement Rapport File Parser
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Implement Rapport File Parser

## Description
Create a rapport parser module (`api/parsers/rapports.js`) that reads markdown files from `project/rapports/` and returns structured rapport entries.

The module must:
- List all `.md` files in `project/rapports/`
- For each file, extract:
  - `filename` — the base filename
  - `date` — parsed from the filename (expected pattern `YYYY-MM-DD_<slug>.md`) or from frontmatter `date` field as fallback
  - `content_summary` — the first non-empty paragraph of the markdown body (after frontmatter), trimmed to ≤ 300 characters
- Return entries as `{ type: "rapport", filename, date (ISO 8601), content_summary }`
- Return `[]` (not throw) if the `project/rapports/` directory does not exist

## Prerequisites
- None

## Acceptance Criteria
- [ ] Module returns an array of `rapport` entries for each `.md` file in `project/rapports/`
- [ ] Each entry has `type`, `filename`, `date`, and `content_summary` fields
- [ ] `date` is a valid ISO 8601 string
- [ ] `content_summary` is ≤ 300 characters
- [ ] Missing `project/rapports/` directory returns `[]` without throwing
