---
id: E22_S05_T01
story_id: E22_S05
epic_id: E22
title: Release notes generator — git log + board enrichment
status: Passed
date_created: 2026-07-11
date_started:
date_completed: 2026-07-11
assigned_to: developer
---

# Task: Release notes generator — git log + board enrichment

## Description
Implement the release notes generation engine at `skills/publish/scripts/generate_release_notes.sh`.

**"Last publish tag" resolution**:
- Scan semver tags matching `v*.*.*` on the current branch
- For each candidate tag (newest first), check if a matching `version` entry exists in `project/logs/publish-history.json`
- The first match is the "last publish tag"
- If no match found: use the full git history; prepend a note: `> First release — full history included`

**Git log extraction**:
- `git log <last_tag>..HEAD --pretty=format:"- %s (%h)"` (or full history if no tag)
- Group commits into sections: `### Features`, `### Bug Fixes`, `### Other` using commit prefix patterns (`feat:`, `fix:`, `chore:`/`docs:`/etc.)
- Format as a markdown draft

**Board task enrichment (best-effort, never fails the command)**:
- Read `project/board/tasks/` for tasks with `status: Passed` and `date_completed` after the last tag's commit date
- Append as a `### Completed tasks` section with task IDs and titles
- If board directory doesn't exist or tasks can't be read → skip silently

**Output**:
- Write draft to a temp file path returned as stdout (or to `--output <path>` if specified)
- Print: `📝 Release notes draft written to <path>`

**Invocation contract**:
```
generate_release_notes.sh [--target <name>] [--from-tag <tag>] [--to-ref <git-ref>] [--output <path>] [<publish_json_path>]
```

## Prerequisites
None (git and the existing publish-history.json are sufficient).

## Acceptance Criteria
- [ ] `skills/publish/scripts/generate_release_notes.sh` exists and is executable
- [ ] Correctly resolves "last publish tag" from `publish-history.json` + semver git tags
- [ ] Falls back to full history with "First release" note when no prior tag found
- [ ] Commit groups: Features, Bug Fixes, Other
- [ ] Board enrichment section appended when closed tasks exist; silently skipped otherwise
- [ ] Draft written to output path; path printed to stdout
