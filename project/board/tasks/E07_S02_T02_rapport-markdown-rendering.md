---
id: E07_S02_T02
story_id: E07_S02
epic_id: E07
title: Add markdown-to-HTML rendering for rapport content in detail panel
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Add markdown-to-HTML rendering for rapport content in detail panel

## Description
Integrate a markdown-to-HTML renderer so that rapport content is displayed as formatted HTML inside the detail panel rather than as raw markdown text. Use an existing lightweight library (e.g. marked or similar) already available in the project if one exists, otherwise add one.

## Prerequisites
- E07_S02_T01 — detail panel component must exist

## Acceptance Criteria
- [ ] Rapport content is rendered as HTML (headings, lists, bold/italic, code blocks) inside the panel
- [ ] Raw markdown is not shown to the user
- [ ] Git commit entries are unaffected by this change
- [ ] No XSS vulnerabilities are introduced (output is sanitised or the library handles it safely)
