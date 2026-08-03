---
id: E05_S04_T01
story_id: E05_S04
epic_id: E05
title: Implement Git Log Reader
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Implement Git Log Reader

## Description
Create a git log reader module (`api/parsers/git-log.js`) that executes `git log` as a child process (no GitHub API) and returns a structured array of commit entries.

The module must:
- Run `git log --format="%H|%an|%aI|%s|%b" -- ` (or equivalent delimiter-safe format) using Node's `child_process.execSync` or `spawnSync`
- Parse each line into: `{ type: "git_commit", sha, author, date (ISO 8601), subject, body }`
- Work from the project root (use `cwd` option pointing to the working directory)
- Return an empty array (not throw) if the directory is not a git repo

## Prerequisites
- None (pure Node.js, no external dependencies beyond stdlib)

## Acceptance Criteria
- [ ] Module returns an array of `git_commit` entries
- [ ] Each entry includes `sha`, `author`, `date`, `subject`, and `body` fields
- [ ] `date` is a valid ISO 8601 string
- [ ] Non-git directories return `[]` without throwing
- [ ] No GitHub API or external network calls are made
