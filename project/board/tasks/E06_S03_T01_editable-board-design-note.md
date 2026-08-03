---
id: E06_S03_T01
story_id: E06_S03
epic_id: E06
title: Write design note for editable board spike
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Write design note for editable board spike

## Description
Research and produce a design note document saved to `project/documentation/editable-board-design-note.md`. The note must address all five spike questions:

1. **API contract changes** — What new endpoints or request methods (PATCH, PUT) would be needed? What would the request/response shape look like for status changes, reordering, and field updates?
2. **Safe server-side writes to markdown** — How should the API server write changes back to markdown files atomically? Consider: file locking, write-then-rename, parsing/serialising frontmatter, and preserving body content.
3. **Optimistic vs pessimistic updates** — Evaluate both strategies in the context of this app. Consider latency, conflict risk, and UX. Make a recommendation with rationale.
4. **Minimum editable field set** — Identify the smallest set of fields worth supporting for a v1 editable board (e.g. task status, story status). Explain why other fields are deferred.
5. **Locking concerns** — Analyse the risk of simultaneous writes from the CLI and the dashboard. Propose a lightweight mitigation strategy (e.g. file locks, last-write-wins, optimistic concurrency tokens).

No code is produced. Output is the design note document only.

## Prerequisites
- Read E06_S02 stories and tasks to understand the current read-only board shape.
- Review existing markdown file conventions in `project/board/` to inform write-safety analysis.

## Acceptance Criteria
- [ ] `project/documentation/editable-board-design-note.md` exists
- [ ] Document answers all five spike questions with sufficient detail to inform implementation
- [ ] A clear recommendation is made for optimistic vs pessimistic updates with rationale
- [ ] Minimum editable field set is explicitly listed
- [ ] Locking/concurrency mitigation strategy is proposed
- [ ] Document is written in plain markdown, readable without additional tooling
