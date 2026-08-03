---
id: E23_S03
epic: E23
title: /pickup skill — agent resumption after manual work
status: Pending
date_created: 2026-07-11
date_started:
date_completed:
tasks: []
---

# Story: /pickup skill — agent resumption after manual work

## Goal
Create a `/pickup` skill that lets the agent resume a task after the user has done
some or all of the remaining work manually. The skill reconciles the handoff document
(skip list of what's done) with the original task spec (source of truth for what must
be done), cross-checks against actual git state, surfaces any discrepancies to the
user, then either continues the remaining steps or routes directly to the Tester if
the task is fully complete.

## Acceptance Criteria
- [ ] `skills/pickup/SKILL.md` created with correct frontmatter (`name`, `description`, `keywords`, `examples`)
- [ ] Skill lists all files in `project/handoffs/` with status `in_progress` and lets user select one
- [ ] After selection, skill:
  1. Reads the handoff file (completed steps, remaining steps, worktree path, last commit)
  2. Reads the original task spec from `project/board/tasks/<task-id>.md`
  3. Reads `git log` in the worktree since `last_commit` to identify what was actually committed manually
  4. Presents reconciliation summary to user: what handoff says is done, what git shows was committed, any gaps between task spec and actual state
  5. Asks user to confirm before proceeding: "Does this look right?"
- [ ] If task is **fully complete** (all task spec acceptance criteria addressed): route to Tester via Developer agent sender object
- [ ] If task is **partially complete**: agent resumes in the same worktree, skipping steps listed in handoff's `completed_steps`, executing remaining steps from task spec, then routes to Tester
- [ ] Tester always validates the work — manual completion is not a bypass
- [ ] On Tester pass: handoff file status updated to `completed`, then archived (moved to `project/handoffs/archive/`)
- [ ] Skill listed in `/help` output with keywords: `pickup`, `resume`, `manual`, `handoff`, `take over`

## Notes
- Trust hierarchy: task spec = ground truth; handoff = skip list; git log = verification of what actually happened
- Discrepancies between handoff and git log should be surfaced clearly — e.g. "Handoff says X was done but no related commit found"
- If the worktree no longer exists (user merged and deleted it), skill creates a fresh worktree from the current branch before resuming
